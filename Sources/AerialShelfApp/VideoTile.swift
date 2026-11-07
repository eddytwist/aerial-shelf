import AerialCore
import AVFoundation
import SwiftUI

/// One video in the library: preview, name, state and actions.
struct VideoTile: View {
    @Environment(AppModel.self) private var model
    let asset: AerialAsset
    let playlistID: UUID?
    let isSelected: Bool
    /// True when the grid has keyboard focus and this is the selected video.
    let showsFocus: Bool
    /// Grows each time Return is pressed in the grid while this video is selected; nil when it isn't selected.
    let activateRequest: Int?
    /// Grows each time ⌘⌫ is pressed in the grid while this video is selected; nil when it isn't selected.
    let trashRequest: Int?
    let select: () -> Void
    /// Opens Quick Look for a downloaded video.
    let preview: () -> Void

    @ViewState private var askingDownload = false
    @ViewState private var remoteSize: Int64?
    @ViewState private var askingTrash = false
    @ViewState private var hovering = false
    @ViewState private var renaming = false
    @ViewState private var askingRemove = false
    @ViewState private var newName = ""

    private var isDownloaded: Bool { model.isDownloaded(asset.id) }
    private var isCurrent: Bool { model.currentAssetID == asset.id }
    private var progress: Int? { model.downloadProgress[asset.id] }
    private var failed: Bool { model.failedDownloads.contains(asset.id) }
    private var outdated: Bool { isDownloaded && model.verdict(asset.id) == .outdatedFile }
    /// The user's own videos are never downloaded; Apple's are when missing or outdated.
    private var needsDownload: Bool { !asset.isCustom && (!isDownloaded || outdated) }
    /// One of the user's videos whose file was deleted outside the app.
    private var missingCustomFile: Bool { asset.isCustom && !isDownloaded }
    /// Can go on screen now (downloaded, current, and for the user's videos: My Videos are on).
    private var canSet: Bool { model.verdict(asset.id) == .safe }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // A 16:9 box sized by the grid column; the image fills it and is clipped to it.
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { Preview(assetID: asset.id, downloaded: isDownloaded) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // A click on the picture does the useful thing: watch a downloaded video, or offer to download it.
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // A single click only (no double-click), so Quick Look opens without waiting.
                .onTapGesture { select(); pictureAction() }
                .help(pictureHelp)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
                // Keyboard focus on the selected video, drawn to match the preview's corners.
                .overlay {
                    if showsFocus {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(-3)
                    }
                }
                .overlay(alignment: .bottomTrailing) { badge.padding(8) }
                .overlay(alignment: .bottom) {
                    if hovering, canSet, !isCurrent, progress == nil {
                        capsule(L.t("Set as Wallpaper"), systemImage: "photo") { setWallpaper() }
                            .padding(.bottom, 10)
                            .transition(.opacity)
                    }
                }

            HStack(spacing: 6) {
                Text(model.name(asset))
                    .font(.headline)
                    .lineLimit(1)
                    .help(model.name(asset))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(isCurrent || failed || outdated ? AnyShapeStyle(statusColor) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .monospacedDigit()
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onTapGesture { select() }
        .onChange(of: activateRequest) { old, new in
            if let old, let new, new > old { primaryAction() }
        }
        .onChange(of: trashRequest) { old, new in
            guard let old, let new, new > old, isDownloaded else { return }
            if model.isInUse(asset.id) { model.moveToTrash(asset.id) } else { askingTrash = true }
        }
        .contextMenu { menu }
        .modifier(DraggableWhen(enabled: isDownloaded, id: asset.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { primaryAction() }
        .accessibilityActions { accessibilityActionButtons }
        .confirmationDialog(L.t("Download “%@”?", model.name(asset)), isPresented: $askingDownload) {
            Button(outdated ? L.t("Download Again") : L.t("Download")) {
                Task { await model.download(asset, expectedSize: remoteSize) }
            }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(remoteSize.map { L.t("%@ from Apple’s server.", AppModel.size($0, language: model.language)) }
                 ?? L.t("From Apple’s server."))
        }
        .confirmationDialog(L.t("Move “%@” to the Trash?", model.name(asset)), isPresented: $askingTrash) {
            Button(L.t("Move to Trash"), role: .destructive) { model.moveToTrash(asset.id) }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(asset.isCustom
                 ? L.t("Aerial Shelf’s copy goes to the Trash. Your original file stays where it is.")
                 : L.t("You can download it again later."))
        }
        .confirmationDialog(L.t("Remove “%@” from My Videos?", model.name(asset)), isPresented: $askingRemove) {
            Button(L.t("Remove"), role: .destructive) { model.removeMissingCustomVideo(asset.id) }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("Its file is no longer on this Mac."))
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(title: L.t("Rename Video"), name: $newName) { name in
                Task { await model.renameCustomVideo(asset.id, to: name) }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var badge: some View {
        if let progress {
            Button { model.cancelDownload(asset.id) } label: {
                ZStack {
                    Circle().stroke(.primary.opacity(0.15), lineWidth: 2.5)
                    Circle().trim(from: 0, to: CGFloat(progress) / 100)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold))
                }
                .frame(width: 22, height: 22)
                .padding(5)
                .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L.t("Cancel Download"))
            .accessibilityLabel(L.t("Cancel Download"))
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .accessibilityHidden(true)
        } else if needsDownload {
            Button { startDownload() } label: {
                Image(systemName: failed ? "arrow.clockwise" : "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(failed ? L.t("Try Again") : (outdated ? L.t("Download Again") : L.t("Download from Apple’s server")))
            .accessibilityLabel(failed ? L.t("Try Again") : L.t("Download"))
        }
    }

    private func capsule(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                // A material capsule stays readable over any picture, in active and inactive windows.
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        if let progress { return L.t("Downloading… %ld%%", progress) }
        if missingCustomFile { return L.t("File Missing") }
        if failed { return L.t("Download Failed") }
        if outdated { return L.t("Update Available") }
        if isCurrent { return L.t("On Screen") }
        if let file = model.local[asset.id] { return AppModel.size(file.size, language: model.language) }
        return " "
    }

    private var statusColor: Color {
        if failed { return .red }
        return .accentColor
    }

    /// What VoiceOver reads: the name and the same state the tile shows.
    private var accessibilityText: String {
        var parts = [model.name(asset)]
        if isCurrent { parts.append(L.t("On Screen")) }
        if let progress { parts.append(L.t("Downloading… %ld%%", progress)) }
        else if failed { parts.append(L.t("Download Failed")) }
        else if outdated { parts.append(L.t("Update Available")) }
        else if missingCustomFile { parts.append(L.t("File Missing")) }
        else if let file = model.local[asset.id] { parts.append(AppModel.size(file.size, language: model.language)) }
        else { parts.append(L.t("Not downloaded")) }
        return parts.joined(separator: ", ")
    }

    /// Named VoiceOver actions that match what the tile can do right now.
    @ViewBuilder private var accessibilityActionButtons: some View {
        if progress != nil {
            Button(L.t("Cancel Download")) { model.cancelDownload(asset.id) }
        } else if missingCustomFile {
            Button(L.t("Remove from My Videos…")) { askingRemove = true }
        } else if needsDownload {
            Button(outdated ? L.t("Download Again…") : L.t("Download…")) { startDownload() }
        } else if canSet, !isCurrent {
            Button(L.t("Set as Wallpaper")) { setWallpaper() }
        }
        if isDownloaded, !model.isInUse(asset.id) {
            Button(L.t("Move to Trash…")) { askingTrash = true }
        }
    }

    @ViewBuilder private var menu: some View {
        if missingCustomFile {
            Button(L.t("Remove from My Videos…")) { askingRemove = true }
        } else if isDownloaded && !outdated {
            Button(L.t("Set as Wallpaper")) { setWallpaper() }
                .disabled(isCurrent || !canSet)
            Button(L.t("Only This Video")) { Task { await model.setMode(.single(asset.id)) } }
                .disabled(!canSet)
            Divider()
            Menu(L.t("Add to Playlist")) {
                ForEach(model.state.playlists) { playlist in
                    Button(playlist.name) { model.add([asset.id], to: playlist.id) }
                        .disabled(playlist.assetIDs.contains(asset.id))
                }
                if !model.state.playlists.isEmpty { Divider() }
                Button(L.t("New Playlist")) { model.createPlaylist(named: model.name(asset), with: [asset.id]) }
            }
        } else if progress != nil {
            Button(L.t("Cancel Download")) { model.cancelDownload(asset.id) }
        } else if needsDownload {
            Button(outdated ? L.t("Download Again…") : L.t("Download…")) { startDownload() }
        }
        if let playlistID {
            Button(L.t("Remove from Playlist")) { model.remove(asset.id, from: playlistID) }
        }
        if asset.isCustom, isDownloaded {
            Button(L.t("Rename…")) { newName = model.name(asset); renaming = true }
        }
        if isDownloaded {
            Divider()
            Button(L.t("Quick Look")) { preview() }
            Button(L.t("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([model.paths.videoFile(for: asset.id)])
            }
            Button(L.t("Move to Trash…"), role: .destructive) { askingTrash = true }
                .disabled(model.isInUse(asset.id))
        }
    }

    private func setWallpaper() { Task { await model.setWallpaper(asset.id, fromWindow: true) } }

    private func pictureAction() {
        if progress != nil { return }
        if needsDownload { startDownload() } else if isDownloaded { preview() }
    }

    private var pictureHelp: String {
        if progress != nil { return L.t("Downloading…") }
        if needsDownload { return outdated ? L.t("Download Again…") : L.t("Download…") }
        if missingCustomFile { return L.t("File Missing") }
        return L.t("Quick Look")
    }

    private func primaryAction() {
        select()
        if missingCustomFile { askingRemove = true; return }
        if canSet { setWallpaper() } else if needsDownload, progress == nil { startDownload() } else if isDownloaded { preview() }
    }

    /// Asks Apple's server for the size first, then shows the confirmation with it
    /// (a dialog's text doesn't change once it is shown).
    private func startDownload() {
        guard !askingDownload else { return }
        Task {
            remoteSize = await model.remoteSize(asset)
            askingDownload = true
        }
    }
}

/// Lets downloaded videos be dragged onto a playlist in the sidebar.
private struct DraggableWhen: ViewModifier {
    let enabled: Bool
    let id: String
    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}

/// Preview image: a sharp frame from the video when it is downloaded, Apple's small thumbnail otherwise.
struct Preview: View {
    @Environment(AppModel.self) private var model
    let assetID: String
    let downloaded: Bool
    @ViewState private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: "\(assetID)-\(downloaded)") {
            image = await FrameCache.shared.image(for: assetID, downloaded: downloaded, paths: model.paths)
        }
    }
}

/// Generates and caches 640 px frames of downloaded videos (Apple's thumbnails are only 214 px wide).
actor FrameCache {
    static let shared = FrameCache()
    private var memory: [String: NSImage] = [:]

    func image(for assetID: String, downloaded: Bool, paths: AerialPaths) async -> NSImage? {
        let key = "\(assetID)-\(downloaded)"
        if let cached = memory[key] { return cached }
        var result: NSImage?
        if downloaded, let frame = await frame(for: assetID, paths: paths) {
            result = NSImage(contentsOf: frame)
        }
        if result == nil { result = NSImage(contentsOf: paths.thumbnailFile(for: assetID)) }
        memory[key] = result
        return result
    }

    private func frame(for assetID: String, paths: AerialPaths) async -> URL? {
        let file = paths.frameCache.appending(path: "\(assetID).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: paths.videoFile(for: assetID)))
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.appliesPreferredTrackTransform = true
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: 6, preferredTimescale: 600)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        try? FileManager.default.createDirectory(at: paths.frameCache, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return file
    }
}
