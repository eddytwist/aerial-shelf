import AerialCore
import QuickLook
import SwiftUI

enum SidebarItem: Hashable {
    case all
    /// The user's own videos.
    case custom
    case category(String)
    case playlist(UUID)
}

/// The library: My Aerials (what rotates) on top, then Apple's whole catalog like System Settings.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var selection: SidebarItem? = .playlist(Playlist.myAerialsID)
    @ViewState private var search = ""
    @ViewState private var renaming: Playlist?
    @ViewState private var newName = ""
    @ViewState private var deleting: Playlist?
    @FocusState private var sidebarFocused: Bool
    /// Files waiting for the one-time "show your own videos in macOS" confirmation; empty means the open panel.
    @ViewState private var pendingImport: [URL]?

    var body: some View {
        NavigationSplitView {
            sidebar
                .focused($sidebarFocused)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            detail
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .searchable(text: $search, placement: .toolbar, prompt: Text(L.t("Search")))
                .toolbar {
                    if selection == .custom {
                        ToolbarItem(placement: .primaryAction) {
                            Button { add(nil) } label: { Label(L.t("Add Videos…"), systemImage: "plus") }
                                .help(L.t("Add Videos…"))
                                .disabled(model.importStatus != nil)
                        }
                    }
                    if let ids = batchIDs {
                        ToolbarItem(placement: .primaryAction) { AddAllMenu(ids: ids, currentPlaylist: selectedPlaylistID) }
                    }
                    ToolbarItem(placement: .primaryAction) { RotationControl() }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.next() }
                        } label: {
                            Label(L.t("Next Video"), systemImage: "forward.end.fill")
                        }
                        .help(L.t("Next Video"))
                        .disabled(!model.canAdvance)
                    }
                }
        }
        // Start in the sidebar, like Finder and Mail, rather than on a random video.
        .defaultFocus($sidebarFocused, true)
        .onChange(of: selection, initial: true) { search = "" }
        .onAppear {
            LibraryOpener.openAction = { openWindow(id: "library") }
            model.refresh()
            if DebugOptions.opensSettings { openSettings() }
            if let section = DebugOptions.librarySection { selection = debugSection(section) }
            // defaultFocus alone can lose to the toolbar when keyboard navigation is on.
            DispatchQueue.main.async { sidebarFocused = true }
            DebugOptions.placeLibraryWindow()
        }
        .sheet(item: $renaming) { playlist in
            RenameSheet(title: L.t("Rename Playlist"), name: $newName) { model.rename(playlist.id, to: $0) }
        }
        .confirmationDialog(
            L.t("Delete “%@”?", deleting.map(model.playlistName) ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L.t("Delete Playlist"), role: .destructive) {
                if let playlist = deleting {
                    if selection == .playlist(playlist.id) { selection = .playlist(Playlist.myAerialsID) }
                    model.deletePlaylist(playlist.id)
                }
                deleting = nil
            }
            Button(L.t("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L.t("The videos stay in the library."))
        }
        .alert(model.windowError ?? "", isPresented: Binding(get: { model.windowError != nil }, set: { if !$0 { model.windowError = nil } })) {
            Button(L.t("OK"), role: .cancel) { model.windowError = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row(L.t("My Aerials"), "heart.fill", count: model.myAerialsIDs.count,
                    rotating: model.state.mode == RotationState.myAerialsMode && !model.showingAllInstead)
                    .tag(SidebarItem.playlist(Playlist.myAerialsID))
                    .help(L.t("What rotates. Add videos from any section."))
                    .dropDestination(for: String.self) { ids, _ in
                        model.add(ids, to: Playlist.myAerialsID)
                        return true
                    }
                    .contextMenu {
                        Button(L.t("Rotate My Aerials")) { Task { await model.setMode(RotationState.myAerialsMode) } }
                    }
                row(L.t("All Aerials"), "square.grid.2x2.fill", count: model.catalog?.videoAssets.filter { !$0.isCustom }.count ?? 0,
                    rotating: model.state.mode == .allAerials || model.showingAllInstead)
                    .tag(SidebarItem.all)
                    .contextMenu {
                        Button(L.t("Rotate All Aerials")) { Task { await model.setMode(.allAerials) } }
                    }
                row(L.t("My Videos"), "film.stack.fill", count: model.custom.videos.count)
                    .tag(SidebarItem.custom)
                    .help(L.t("Your own video files"))
                    .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
            } header: {
                sectionHeader(L.t("Library"))
            }
            Section {
                ForEach(model.catalog?.videoCategories ?? []) { category in
                    row(model.name(category), Self.icon(for: category.nameKey), count: count(in: category.id),
                        rotating: model.state.mode == .category(category.id))
                        .tag(SidebarItem.category(category.id))
                        .contextMenu {
                            Button(L.t("Rotate This Category")) { Task { await model.setMode(.category(category.id)) } }
                            Button(L.t("Add All to My Aerials")) {
                                model.add(model.catalog?.videoAssets.filter { $0.categoryIDs.contains(category.id) }.map(\.id) ?? [],
                                          to: Playlist.myAerialsID)
                            }
                        }
                }
            } header: {
                sectionHeader(L.t("Categories"))
            }
            Section {
                ForEach(model.otherPlaylists) { playlist in
                    row(model.playlistName(playlist), "list.bullet.rectangle.fill", count: playlist.assetIDs.count,
                        rotating: model.state.mode == .playlist(playlist.id))
                        .tag(SidebarItem.playlist(playlist.id))
                        .dropDestination(for: String.self) { ids, _ in
                            model.add(ids, to: playlist.id)
                            return true
                        }
                        .contextMenu {
                            Button(L.t("Rotate This Playlist")) { Task { await model.setMode(.playlist(playlist.id)) } }
                            Button(L.t("Rename…")) { newName = model.playlistName(playlist); renaming = playlist }
                            Divider()
                            Button(L.t("Delete Playlist…"), role: .destructive) { deleting = playlist }
                        }
                }
            } header: {
                sectionHeader(L.t("Playlists"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    let playlist = model.createPlaylist(named: L.t("New Playlist"))
                    selection = .playlist(playlist.id)
                    newName = model.playlistName(playlist)
                    renaming = playlist
                } label: {
                    Label(L.t("New Playlist"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help(L.t("New Playlist"))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// Section titles one step darker than the system default, for contrast.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary)
    }

    private func row(_ title: String, _ icon: String, count: Int, rotating: Bool = false) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                if rotating {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L.t("Rotating now"))
                        .accessibilityLabel(L.t("Rotating now"))
                }
            }
        } icon: {
            // Fit wide symbols (mountains, fish) into the same box as the others.
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 15)
        }
        .badge(count)
    }

    private func count(in categoryID: String) -> Int {
        (model.catalog?.videoAssets ?? []).filter { $0.categoryIDs.contains(categoryID) }.count
    }

    static func icon(for categoryKey: String) -> String {
        switch categoryKey {
        case "AerialCategoryLandscapes": "mountain.2.fill"
        case "AerialCategoryCities": "building.2.fill"
        case "AerialCategoryUnderwater": "fish.fill"
        case "AerialCategorySpace": "globe.europe.africa.fill"
        case "AerialCategoryMac": "desktopcomputer"
        default: "photo.fill"
        }
    }

    // MARK: Detail

    /// The section asked for with the debug option `-LibrarySection`.
    private func debugSection(_ value: String) -> SidebarItem? {
        switch value {
        case "all": .all
        case "downloaded", "mine": .playlist(Playlist.myAerialsID)
        case "custom": .custom
        case "playlist": model.otherPlaylists.first.map { .playlist($0.id) } ?? .playlist(Playlist.myAerialsID)
        default: model.catalog?.videoCategories.first { $0.id == value || $0.nameKey == value }.map { .category($0.id) }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.catalog == nil {
            ContentUnavailableView {
                Label(L.t("Can’t Find Apple’s Aerial Catalog"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(L.t("Open System Settings → Wallpaper once so macOS can download it, then try again."))
            } actions: {
                Button(L.t("Try Again")) { model.refresh() }
            }
        } else if visibleAssets.isEmpty && !search.isEmpty {
            // Own texts instead of ContentUnavailableView.search, which speaks the system language.
            ContentUnavailableView {
                Label(L.t("No Results for “%@”", search), systemImage: "magnifyingglass")
            } description: {
                Text(L.t("Check the spelling or try a new search."))
            }
        } else if selection == .custom {
            customSection
        } else if visibleAssets.isEmpty {
            emptyState
        } else {
            VideoGrid(assets: visibleAssets, playlistID: selectedPlaylistID) { sidebarFocused = false }
        }
    }

    /// The user's own videos: the grid, or how to add the first ones; files and folders can be dropped here.
    @ViewBuilder private var customSection: some View {
        Group {
            if visibleAssets.isEmpty && model.importStatus == nil {
                ContentUnavailableView {
                    Label(L.t("No Videos Yet"), systemImage: "film.stack")
                } description: {
                    Text(L.t("Add videos or drop them here. They rotate together with Apple’s and appear in System Settings."))
                } actions: {
                    Button(L.t("Add Videos…")) { add(nil) }
                }
            } else {
                VideoGrid(assets: visibleAssets, playlistID: nil) { sidebarFocused = false }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { customBanner }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
        .confirmationDialog(
            L.t("Show My Videos in macOS?"),
            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })
        ) {
            Button(L.t("Show in macOS")) {
                let urls = pendingImport ?? []
                pendingImport = nil
                if urls.isEmpty {
                    // Let this dialog close before the file panel opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.chooseVideosToAdd() }
                } else {
                    model.importVideos(urls)
                }
            }
            Button(L.t("Cancel"), role: .cancel) { pendingImport = nil }
        } message: {
            Text(L.t("Aerialist points macOS to its own copy of Apple’s aerial catalog with your videos added. It uses a macOS setting Apple doesn’t document; you can turn this off in Settings."))
        }
    }

    @ViewBuilder private var customBanner: some View {
        if let status = model.importStatus {
            HStack(spacing: 10) {
                ProgressView(value: status.overall)
                    .frame(width: 140)
                Text(L.t("Adding video %ld of %ld…", min(status.done + 1, status.total), status.total))
                    .monospacedDigit()
                Spacer()
                Button(L.t("Stop")) { model.cancelImport() }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        } else if !model.custom.isEmpty && !model.customVideosActive {
            HStack(spacing: 10) {
                Text(L.t("My Videos are off: they don’t rotate and aren’t in System Settings."))
                Spacer()
                Button(L.t("Turn On")) { Task { await model.setCustomVideosEnabled(true) } }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// Adds videos, asking once whether macOS may show them (nil opens the file panel).
    private func add(_ urls: [URL]?) {
        // Show the section, where the progress is.
        selection = .custom
        if model.state.customVideosEnabled {
            if let urls { model.importVideos(urls) } else { model.chooseVideosToAdd() }
        } else {
            pendingImport = urls ?? []
        }
    }

    @ViewBuilder private var emptyState: some View {
        if selectedPlaylistID == Playlist.myAerialsID {
            ContentUnavailableView {
                Label(L.t("Nothing in My Aerials Yet"), systemImage: "heart")
            } description: {
                Text(model.state.deleteShown
                     ? L.t("Add videos from any section with ＋ on a tile, or drag them here. Until then, all aerials rotate.")
                     : L.t("Add videos from any section with ＋ on a tile, or drag them here."))
            } actions: {
                Button(L.t("Browse All Aerials")) { selection = .all }
            }
        } else if selectedPlaylistID != nil {
            ContentUnavailableView {
                Label(L.t("Empty Playlist"), systemImage: "list.bullet.rectangle")
            } description: {
                Text(L.t("Drag videos here, or right-click one and choose Add to Playlist."))
            }
        } else {
            ContentUnavailableView {
                Label(L.t("No Videos"), systemImage: "photo.on.rectangle")
            } description: {
                Text(L.t("Add the aerials you like to My Aerials with ＋ on a tile."))
            } actions: {
                Button(L.t("Browse All Aerials")) { selection = .all }
            }
        }
    }

    /// What "Add All" adds: the videos shown in this section (after search), anywhere but My Aerials itself.
    private var batchIDs: [String]? {
        guard selectedPlaylistID != Playlist.myAerialsID, model.catalog != nil else { return nil }
        let ids = visibleAssets.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private var selectedPlaylistID: UUID? {
        if case .playlist(let id) = selection { return id }
        return nil
    }

    private var visibleAssets: [AerialAsset] {
        let all = model.catalog?.videoAssets ?? []
        var assets: [AerialAsset]
        switch selection ?? .playlist(Playlist.myAerialsID) {
        case .all:
            assets = all.filter { !$0.isCustom }
        case .custom:
            assets = model.customAssets
        case .category(let id):
            assets = all.filter { $0.categoryIDs.contains(id) }
        case .playlist(let id):
            let ids = model.state.playlists.first { $0.id == id }?.assetIDs ?? []
            assets = ids.compactMap { model.catalog?.asset($0) }
        }
        if !search.isEmpty {
            assets = assets.filter { model.name($0).localizedCaseInsensitiveContains(search) }
        }
        if case .playlist = selection { return assets }
        // Alphabetical in the interface language; what is on this Mac doesn't matter any more for what can rotate.
        return assets.sorted { model.name($0).localizedStandardCompare(model.name($1)) == .orderedAscending }
    }

    private var title: String {
        switch selection ?? .playlist(Playlist.myAerialsID) {
        case .all: L.t("All Aerials")
        case .custom: L.t("My Videos")
        case .category(let id): model.catalog?.videoCategories.first { $0.id == id }.map(model.name) ?? ""
        case .playlist(let id): model.state.playlists.first { $0.id == id }.map(model.playlistName) ?? ""
        }
    }

    private var subtitle: String {
        let assets = visibleAssets
        let downloaded = assets.filter { model.isDownloaded($0.id) }
        let bytes = downloaded.reduce(Int64(0)) { $0 + (model.local[$1.id]?.size ?? 0) }
        let size = AppModel.size(bytes, language: model.language)
        if assets.isEmpty { return L.videos(0) }
        if downloaded.count == assets.count { return "\(L.videos(assets.count)) · \(size)" }
        if downloaded.isEmpty { return L.videos(assets.count) }
        return L.t("%@ · on this Mac: %ld · %@", L.videos(assets.count), downloaded.count, size)
    }
}

/// The rotation settings in the library toolbar: what rotates and how often.
struct RotationControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.isAppleShuffleOn {
                Button(L.t("Use Aerialist Instead")) { Task { await model.replaceAppleShuffle() } }
            }
            if model.state.paused {
                Button(L.t("Resume Rotation")) { Task { await model.resumeRotation() } }
            }
            if model.streamTarget != nil {
                Button(L.t("Cancel Download")) { model.cancelStreamDownload() }
            }
            if model.isAppleShuffleOn || model.state.paused || model.streamTarget != nil { Divider() }
            RotationSourcePicker()
            if model.state.mode.rotates {
                Picker(L.t("Change"), selection: Binding(get: { model.state.interval }, set: { model.state.interval = $0 })) {
                    ForEach(RotationInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            // What rotates and when, so the section being browsed isn't mistaken for the rotation.
            Label {
                Text(verbatim: "\(model.sourceTitle) · \(model.statusLine)")
            } icon: {
                Image(systemName: model.state.paused ? "pause.circle" : "arrow.triangle.2.circlepath")
            }
            .labelStyle(.titleAndIcon)
        }
        .help(L.t("What rotates and how often"))
    }
}

/// "Add All" in the toolbar: every video shown in the section goes into My Aerials or a playlist at once.
struct AddAllMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    var currentPlaylist: UUID?

    var body: some View {
        Menu {
            AddToListsItems(ids: ids, currentPlaylist: currentPlaylist)
        } label: {
            Label(L.t("Add All"), systemImage: "heart.text.square")
        }
        .help(L.t("Add every video shown here to My Aerials or a playlist"))
    }
}

/// Add these videos to My Aerials / remove them, or add them to another playlist. Shared by "Add All" and the
/// context menu of several selected videos.
struct AddToListsItems: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    /// The playlist being shown, left out of "Add to Playlist".
    var currentPlaylist: UUID?

    var body: some View {
        let missing = ids.filter { !model.isInMyAerials($0) }
        if !missing.isEmpty {
            Button(L.t("Add %@ to My Aerials", L.videos(missing.count))) { model.add(missing, to: Playlist.myAerialsID) }
        }
        if missing.count < ids.count {
            Button(L.t("Remove %@ from My Aerials", L.videos(ids.count - missing.count))) {
                ids.forEach { model.remove($0, from: Playlist.myAerialsID) }
            }
        }
        let others = model.otherPlaylists.filter { $0.id != currentPlaylist }
        Menu(L.t("Add to Playlist")) {
            ForEach(others) { playlist in
                Button(model.playlistName(playlist)) { model.add(ids, to: playlist.id) }
            }
            if !others.isEmpty { Divider() }
            Button(L.t("New Playlist")) { model.createPlaylist(named: L.t("New Playlist"), with: ids) }
        }
    }
}

/// Grid of video tiles. Like Finder, the grid takes keyboard focus as a whole: arrow keys move the selection,
/// Space opens Quick Look, Return sets the selected video (downloading it first if needed), ⌘⌫ removes it from this Mac,
/// Escape clears the selection.
/// The selection is drawn only while moving with the keyboard; a click acts at once instead.
struct VideoGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var windowState
    let assets: [AerialAsset]
    let playlistID: UUID?
    /// Lets the library take the keyboard away from the sidebar when a video is clicked.
    var releaseSidebar: () -> Void = {}
    @ViewState private var selectedID: String?
    /// Several videos chosen with ⌘-click, ⇧-click or ⌘A; their context menu acts on all of them.
    @ViewState private var chosen: Set<String> = []
    @ViewState private var columnCount = 3
    @ViewState private var activations = 0
    @ViewState private var trashRequests = 0
    @ViewState private var usingKeyboard = false
    @ViewState private var previewURL: URL?
    @ViewState private var previewList: [URL] = []
    @FocusState private var focused: Bool

    private static let minimumWidth: CGFloat = 200
    private static let spacing: CGFloat = 18
    private static let padding: CGFloat = 20
    private let columns = [GridItem(.adaptive(minimum: minimumWidth, maximum: 260), spacing: spacing, alignment: .top)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(assets) { asset in
                        let selected = selectedID == asset.id
                        let marked = chosen.contains(asset.id)
                        let several = chosen.count > 1 && marked
                        VideoTile(
                            asset: asset,
                            playlistID: playlistID,
                            isSelected: selected || several,
                            showsFocus: marked || (selected && focused && usingKeyboard && windowState == .key),
                            selection: several ? assets.map(\.id).filter(chosen.contains) : nil,
                            activateRequest: selected ? activations : nil,
                            trashRequest: selected ? trashRequests : nil,
                            select: { choose(asset.id) },
                            preview: { preview(asset.id) }
                        )
                        .id(asset.id)
                    }
                }
                .padding(Self.padding)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    // Same rule as the adaptive grid: as many minimum-width columns as fit.
                    let available = width - Self.padding * 2
                    columnCount = max(1, Int((available + Self.spacing) / (Self.minimumWidth + Self.spacing)))
                }
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            // `.edit` lets a click anywhere in the grid take the keyboard, so arrow keys work right after a click.
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard let next = neighbour(of: press.key) else { return .ignored }
                selectedID = next
                chosen = []
                usingKeyboard = true
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(next) }
                return .handled
            }
            .onKeyPress(.return) {
                // Keys act on the selection only while it is visible (after an arrow key), never on a hidden one.
                guard selectedID != nil, usingKeyboard, chosen.count < 2 else { return .ignored }
                activations += 1
                return .handled
            }
            .onKeyPress(keys: [.delete]) { press in
                // ⌘⌫ moves the selected video to the Trash, as in Finder (with the usual confirmation).
                guard press.modifiers.contains(.command), usingKeyboard, chosen.count < 2, let id = selectedID, model.isDownloaded(id) else { return .ignored }
                trashRequests += 1
                return .handled
            }
            .onKeyPress(.space) {
                guard usingKeyboard, chosen.count < 2, let id = selectedID, model.isDownloaded(id) else { return .ignored }
                preview(id)
                return .handled
            }
            .quickLookPreview($previewURL, in: previewList)
            .onChange(of: previewURL) { if previewURL == nil { model.removePreviewLinks() } }
            .onKeyPress(.escape) {
                selectedID = nil
                chosen = []
                return .handled
            }
            .onKeyPress(characters: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selectAll()
                return .handled
            }
            // In the Dock (while a window is open) the app has an Edit menu whose Select All also sends ⌘A.
            .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll() }
            // Sections and searches share this grid: keep only what is still shown.
            .onChange(of: assets.map(\.id)) { _, ids in
                chosen.formIntersection(ids)
                if let id = selectedID, !ids.contains(id) { selectedID = nil }
            }
        }
    }

    /// A click on a tile: plain selects it alone, ⌘ adds or removes it, ⇧ selects the range from the last plain click.
    /// Returns true for a plain click, which may then do the tile's own action (Quick Look).
    private func choose(_ id: String) -> Bool {
        let flags = NSEvent.modifierFlags
        usingKeyboard = false
        defer {
            // After the click is handled, or the sidebar keeps the keyboard.
            releaseSidebar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
        if flags.contains(.command) {
            if chosen.isEmpty, let current = selectedID { chosen = [current] }
            if chosen.contains(id) {
                chosen.remove(id)
                selectedID = assets.first { chosen.contains($0.id) }?.id
            } else {
                chosen.insert(id)
                selectedID = id
            }
            return false
        }
        if flags.contains(.shift) {
            if let anchor = selectedID, let from = assets.firstIndex(where: { $0.id == anchor }),
               let to = assets.firstIndex(where: { $0.id == id }) {
                chosen = Set(assets[min(from, to)...max(from, to)].map(\.id))
            } else {
                chosen = [id]
                selectedID = id
            }
            return false
        }
        chosen = []
        selectedID = id
        return true
    }

    private func selectAll() {
        chosen = Set(assets.map(\.id))
        usingKeyboard = false
    }

    /// Opens Quick Look on a video; the arrow keys there move through the downloaded videos in grid order.
    private func preview(_ id: String) {
        guard model.isDownloaded(id) else { return }
        let ids = assets.map(\.id).filter(model.isDownloaded)
        let links = model.previewLinks(for: ids)
        previewList = ids.compactMap { links[$0] }
        previewURL = links[id]
    }

    private func neighbour(of key: KeyEquivalent) -> String? {
        guard !assets.isEmpty else { return nil }
        guard let id = selectedID, let index = assets.firstIndex(where: { $0.id == id }) else { return assets.first?.id }
        let step = switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -columnCount
        default: columnCount
        }
        let target = index + step
        return assets.indices.contains(target) ? assets[target].id : nil
    }
}
