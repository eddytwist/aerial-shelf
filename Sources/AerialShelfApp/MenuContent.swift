import AerialCore
import SwiftUI

/// The menu bar menu: what is on screen, what happens next, and the two rotation settings.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.name(of: model.currentAssetID) ?? L.t("Not an aerial wallpaper")) { openLibrary() }
        Text(model.statusLine)
        if model.hasPerDisplayOverrides {
            Text(L.t("Some displays have their own wallpaper"))
        }

        Divider()

        if model.isAppleShuffleOn {
            Button(L.t("Use Aerial Shelf Instead")) { Task { await model.replaceAppleShuffle() } }
        }
        Button(L.t("Next Video")) { Task { await model.next() } }
            .keyboardShortcut("n")
            .disabled(!model.canAdvance)
        if model.state.paused {
            Button(L.t("Resume Rotation")) { Task { await model.resumeRotation() } }
        } else if model.state.mode.rotates {
            Button(L.t("Pause Rotation")) { model.pauseRotation() }
        }

        Divider()

        Menu(L.t("Rotate: %@", modeTitle(model.state.mode))) {
            Picker(selection: Binding(get: { model.state.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                Text(L.t("All Downloaded (%ld)", model.poolCount(for: .allDownloaded))).tag(RotationMode.allDownloaded)
                ForEach(model.state.playlists) { playlist in
                    Text(L.t("%@ (%ld)", playlist.name, model.poolCount(for: .playlist(playlist.id))))
                        .tag(RotationMode.playlist(playlist.id))
                }
                if let current = model.currentAssetID, model.isDownloaded(current) {
                    Text(L.t("Only This Video")).tag(RotationMode.single(current))
                }
                if case .single(let id) = model.state.mode, id != model.currentAssetID {
                    Text(L.t("Only “%@”", model.name(of: id) ?? id)).tag(RotationMode.single(id))
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        }
        if model.state.mode.rotates {
            Menu(model.state.interval.title) {
                Picker(selection: Binding(get: { model.state.interval }, set: { model.state.interval = $0 })) {
                    ForEach(RotationInterval.allCases, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            }
        }

        if !model.unexpected.isEmpty || model.notice != nil {
            Divider()
        }
        ForEach(model.unexpected, id: \.assetID) { video in
            Menu(L.t("macOS downloaded “%@”", model.name(of: video.assetID) ?? video.assetID)) {
                Text(AppModel.size(video.size, language: model.language))
                Button(L.t("Move to Trash")) { model.trashUnexpected(video.assetID) }
                Button(L.t("Keep in Library")) { model.keepUnexpected(video.assetID) }
            }
        }
        if let notice = model.notice {
            Menu(Self.shorten(notice)) {
                Text(notice)
                Button(L.t("Dismiss")) { model.notice = nil }
            }
        }

        Divider()

        Button(L.t("Open Library")) { openLibrary() }
            .keyboardShortcut("l")
        SettingsLink { Text(L.t("Settings…")) }
            .keyboardShortcut(",")

        Divider()

        Button(L.t("Quit %@", AppInfo.name)) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openLibrary() {
        LibraryOpener.openAction = { openWindow(id: "library") }
        openWindow(id: "library")
        NSApp.activate()
    }

    private func modeTitle(_ mode: RotationMode) -> String {
        switch mode {
        case .allDownloaded: L.t("All Downloaded")
        case .playlist(let id): model.state.playlists.first { $0.id == id }?.name ?? L.t("Playlist")
        case .single: L.t("One Video")
        }
    }

    /// Menu items do not wrap; long messages show their first words, the full text one level down.
    static func shorten(_ text: String, limit: Int = 48) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
}

extension RotationMode {
    var rotates: Bool { if case .single = self { false } else { true } }
}

extension RotationInterval {
    @MainActor var title: String {
        switch self {
        case .hours3: L.t("Every 3 Hours")
        case .hours6: L.t("Every 6 Hours")
        case .hours12: L.t("Every 12 Hours")
        case .day: L.t("Every Day")
        case .days2: L.t("Every 2 Days")
        case .week: L.t("Every Week")
        }
    }
}
