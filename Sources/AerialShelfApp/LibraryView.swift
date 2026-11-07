import AerialCore
import QuickLook
import SwiftUI

enum SidebarItem: Hashable {
    case downloaded
    case all
    /// The user's own videos.
    case custom
    case category(String)
    case playlist(UUID)
}

/// The library: Apple's whole aerial catalog, like System Settings, with downloads on request.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var selection: SidebarItem? = .downloaded
    @ViewState private var search = ""
    @ViewState private var renaming: Playlist?
    @ViewState private var newName = ""
    @ViewState private var deleting: Playlist?
    @FocusState private var sidebarFocused: Bool
    /// Videos that were downloaded when the section was opened. Sorting uses this instead of the live state,
    /// so a video that finishes downloading doesn't jump to the top under the pointer.
    @ViewState private var downloadedWhenOpened: Set<String> = []
    /// Files waiting for the one-time "show your own videos in macOS" confirmation; empty means the open panel.
    @ViewState private var pendingImport: [URL]?

    var body: some View {
        NavigationSplitView {
            sidebar
                .focused($sidebarFocused)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
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
        .onChange(of: selection, initial: true) {
            downloadedWhenOpened = Set(model.local.keys)
            search = ""
        }
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
            L.t("Delete “%@”?", deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L.t("Delete Playlist"), role: .destructive) {
                if let playlist = deleting {
                    if selection == .playlist(playlist.id) { selection = .downloaded }
                    model.deletePlaylist(playlist.id)
                }
                deleting = nil
            }
            Button(L.t("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L.t("The videos stay downloaded."))
        }
        .alert(model.windowError ?? "", isPresented: Binding(get: { model.windowError != nil }, set: { if !$0 { model.windowError = nil } })) {
            Button(L.t("OK"), role: .cancel) { model.windowError = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row(L.t("Downloaded"), "arrow.down.circle.fill", count: model.downloadedAssets.count,
                    rotating: model.state.mode == .allDownloaded)
                    .tag(SidebarItem.downloaded)
                row(L.t("All Aerials"), "square.grid.2x2.fill", count: model.catalog?.videoAssets.filter { !$0.isCustom }.count ?? 0)
                    .tag(SidebarItem.all)
                row(L.t("My Videos"), "film.stack.fill", count: model.custom.videos.count)
                    .tag(SidebarItem.custom)
                    .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
            } header: {
                sectionHeader(L.t("Library"))
            }
            Section {
                ForEach(model.catalog?.videoCategories ?? []) { category in
                    row(model.name(category), Self.icon(for: category.nameKey), count: count(in: category.id))
                        .tag(SidebarItem.category(category.id))
                }
            } header: {
                sectionHeader(L.t("Categories"))
            }
            Section {
                ForEach(model.state.playlists) { playlist in
                    row(playlist.name, "list.bullet.rectangle.fill", count: playlist.assetIDs.count,
                        rotating: model.state.mode == .playlist(playlist.id))
                        .tag(SidebarItem.playlist(playlist.id))
                        .dropDestination(for: String.self) { ids, _ in
                            model.add(ids, to: playlist.id)
                            return true
                        }
                        .contextMenu {
                            Button(L.t("Rotate This Playlist")) { Task { await model.setMode(.playlist(playlist.id)) } }
                            Button(L.t("Rename…")) { newName = playlist.name; renaming = playlist }
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
                    newName = playlist.name
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
        case "downloaded": .downloaded
        case "custom": .custom
        case "playlist": model.state.playlists.first.map { .playlist($0.id) } ?? .downloaded
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
            Text(L.t("Aerial Shelf points macOS to its own copy of Apple’s aerial catalog with your videos added. It uses a macOS setting Apple doesn’t document; you can turn this off in Settings."))
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
        if selectedPlaylistID != nil {
            ContentUnavailableView {
                Label(L.t("Empty Playlist"), systemImage: "list.bullet.rectangle")
            } description: {
                Text(L.t("Drag downloaded videos here, or right-click one and choose Add to Playlist."))
            }
        } else {
            ContentUnavailableView {
                Label(L.t("No Downloaded Videos"), systemImage: "arrow.down.circle")
            } description: {
                Text(L.t("Download the aerials you like. Only those will rotate."))
            } actions: {
                Button(L.t("Browse All Aerials")) { selection = .all }
            }
        }
    }

    private var selectedPlaylistID: UUID? {
        if case .playlist(let id) = selection { return id }
        return nil
    }

    private var visibleAssets: [AerialAsset] {
        let all = model.catalog?.videoAssets ?? []
        var assets: [AerialAsset]
        switch selection ?? .downloaded {
        case .downloaded:
            assets = all.filter { model.isDownloaded($0.id) }
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
        // Downloaded videos first (as they were when the section opened), then the rest;
        // each group alphabetical in the UI language.
        return assets.sorted { a, b in
            let aDownloaded = downloadedWhenOpened.contains(a.id), bDownloaded = downloadedWhenOpened.contains(b.id)
            if aDownloaded != bDownloaded { return aDownloaded }
            return model.name(a).localizedStandardCompare(model.name(b)) == .orderedAscending
        }
    }

    private var title: String {
        switch selection ?? .downloaded {
        case .downloaded: L.t("Downloaded")
        case .all: L.t("All Aerials")
        case .custom: L.t("My Videos")
        case .category(let id): model.catalog?.videoCategories.first { $0.id == id }.map(model.name) ?? ""
        case .playlist(let id): model.state.playlists.first { $0.id == id }?.name ?? ""
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
        return L.t("%@ · %ld downloaded · %@", L.videos(assets.count), downloaded.count, size)
    }
}

/// The rotation settings in the library toolbar: what rotates and how often.
struct RotationControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.isAppleShuffleOn {
                Button(L.t("Use Aerial Shelf Instead")) { Task { await model.replaceAppleShuffle() } }
            }
            if model.state.paused {
                Button(L.t("Resume Rotation")) { Task { await model.resumeRotation() } }
            }
            if model.isAppleShuffleOn || model.state.paused { Divider() }
            Picker(L.t("Rotate"), selection: Binding(get: { model.state.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                Text(L.t("All Downloaded (%ld)", model.poolCount(for: .allDownloaded))).tag(RotationMode.allDownloaded)
                ForEach(model.state.playlists) { playlist in
                    Text(L.t("%@ (%ld)", playlist.name, model.poolCount(for: .playlist(playlist.id)))).tag(RotationMode.playlist(playlist.id))
                }
                if let current = model.currentAssetID, model.isDownloaded(current) {
                    Text(L.t("Only This Video")).tag(RotationMode.single(current))
                }
                if case .single(let id) = model.state.mode, id != model.currentAssetID {
                    Text(L.t("Only “%@”", model.name(of: id) ?? id)).tag(RotationMode.single(id))
                }
            }
            .pickerStyle(.inline)
            if model.state.mode.rotates {
                Picker(L.t("Change"), selection: Binding(get: { model.state.interval }, set: { model.state.interval = $0 })) {
                    ForEach(RotationInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(model.statusLine, systemImage: model.state.paused ? "pause.circle" : "clock")
                .labelStyle(.titleAndIcon)
        }
        .help(L.t("Rotation"))
    }
}

/// Grid of video tiles. Like Finder, the grid takes keyboard focus as a whole: arrow keys move the selection,
/// Space opens Quick Look, Return sets the selected video (or offers to download it), ⌘⌫ moves it to the Trash,
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
                        VideoTile(
                            asset: asset,
                            playlistID: playlistID,
                            isSelected: selected,
                            showsFocus: selected && focused && usingKeyboard && windowState == .key,
                            activateRequest: selected ? activations : nil,
                            trashRequest: selected ? trashRequests : nil,
                            select: {
                                selectedID = asset.id
                                usingKeyboard = false
                                // After the click is handled, or the sidebar keeps the keyboard.
                                releaseSidebar()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
                            },
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
                usingKeyboard = true
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(next) }
                return .handled
            }
            .onKeyPress(.return) {
                // Keys act on the selection only while it is visible (after an arrow key), never on a hidden one.
                guard selectedID != nil, usingKeyboard else { return .ignored }
                activations += 1
                return .handled
            }
            .onKeyPress(keys: [.delete]) { press in
                // ⌘⌫ moves the selected video to the Trash, as in Finder (with the usual confirmation).
                guard press.modifiers.contains(.command), usingKeyboard, let id = selectedID, model.isDownloaded(id) else { return .ignored }
                trashRequests += 1
                return .handled
            }
            .onKeyPress(.space) {
                guard usingKeyboard, let id = selectedID, model.isDownloaded(id) else { return .ignored }
                preview(id)
                return .handled
            }
            .quickLookPreview($previewURL, in: previewList)
            .onChange(of: previewURL) { if previewURL == nil { model.removePreviewLinks() } }
            .onKeyPress(.escape) {
                selectedID = nil
                return .handled
            }
        }
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
