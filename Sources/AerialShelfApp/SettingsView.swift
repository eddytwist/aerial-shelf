import AerialCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var askingRestore = false
    @ViewState private var askingTrashKept = false

    var body: some View {
        Form {
            Section(L.t("General")) {
                Picker(L.t("Language"), selection: Binding(get: { model.state.language }, set: { model.setLanguage($0) })) {
                    Text(L.t("System Language")).tag(RotationState.systemLanguage)
                    Divider()
                    ForEach(L.supported, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Toggle(L.t("Open at Login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                if model.loginItemStatus == .requiresApproval {
                    LabeledContent(L.t("Needs approval in System Settings")) {
                        Button(L.t("Open")) { model.openLoginItemsSettings() }
                    }
                }
            }

            Section(L.t("Wallpaper")) {
                LabeledContent(L.t("On Screen")) {
                    Text(model.name(of: model.currentAssetID) ?? L.t("Not an aerial wallpaper"))
                        .foregroundStyle(.primary)
                }
                if model.hasPerDisplayOverrides {
                    Text(L.t("Some displays or Spaces have their own wallpaper. Aerial Shelf doesn’t change it there."))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L.t("Original Wallpaper")) {
                    Button(L.t("Restore…")) { askingRestore = true }
                        .disabled(!model.canRestoreOriginal)
                }
            }

            Section(L.t("My Videos")) {
                Toggle(L.t("Show My Videos in macOS"), isOn: Binding(
                    get: { model.state.customVideosEnabled },
                    set: { on in Task { await model.setCustomVideosEnabled(on) } }
                ))
                .disabled(model.custom.isEmpty && !model.state.customVideosEnabled)
                if !model.custom.isEmpty {
                    LabeledContent(L.t("Added")) {
                        Text(L.videos(model.custom.videos.count)).foregroundStyle(.primary)
                    }
                }
            }

            Section(L.t("Storage")) {
                Toggle(isOn: Binding(get: { model.state.streaming }, set: { on in Task { await model.setStreaming(on) } })) {
                    Text(L.t("Keep Only the Video on Screen"))
                    Text(streamingDescription)
                }
                LabeledContent(L.t("On Disk")) {
                    HStack(spacing: 10) {
                        Text("\(L.videos(model.local.count)) · \(AppModel.size(model.totalDownloadedBytes, language: model.language))")
                            .foregroundStyle(.primary)
                        Button(L.t("Show in Finder")) { NSWorkspace.shared.open(model.paths.videos) }
                    }
                }
                if model.state.streaming {
                    let saved = model.streamSavings
                    if saved.count > 0 {
                        LabeledContent(L.t("Space Saved")) {
                            Text("\(L.videos(saved.count)) · \(AppModel.size(saved.bytes, language: model.language))")
                                .foregroundStyle(.primary)
                        }
                    }
                    let kept = model.keptVideosToTrash
                    if !kept.isEmpty {
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text("\(L.videos(kept.count)) · \(AppModel.size(keptBytes, language: model.language))")
                                    .foregroundStyle(.primary)
                                Button(L.t("Move to Trash…")) { askingTrashKept = true }
                            }
                        } label: {
                            Text(L.t("Downloaded by You"))
                            Text(L.t("Not in use. If you remove them, the rotation downloads them again for their turn."))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Text("\(AppInfo.name) \(AppInfo.version) ·")
                    .foregroundStyle(.secondary)
                Link("eddytwist.com", destination: AppInfo.authorURL)
            }
            .font(.footnote)
            .padding(.bottom, 14)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            model.refresh()
            SettingsWindowTitle.apply()
        }
        .onChange(of: model.language) { SettingsWindowTitle.apply() }
        .confirmationDialog(L.t("Move %@ to the Trash?", L.videos(model.keptVideosToTrash.count)), isPresented: $askingTrashKept) {
            Button(L.t("Move to Trash"), role: .destructive) { Task { await model.trashKeptVideos() } }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("The video on screen and your own videos stay. Empty the Trash to free %@. If you turn off Keep Only the Video on Screen later, download them again to rotate them.", AppModel.size(keptBytes, language: model.language)))
        }
        .confirmationDialog(L.t("Restore the wallpaper you had before %@?", AppInfo.name), isPresented: $askingRestore) {
            Button(L.t("Restore")) { Task { await model.restoreOriginal() } }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(restoreMessage)
        }
        .alert(model.windowError ?? "", isPresented: Binding(get: { model.windowError != nil }, set: { if !$0 { model.windowError = nil } })) {
            Button(L.t("OK"), role: .cancel) { model.windowError = nil }
        }
    }

    private var keptBytes: Int64 { model.keptVideosToTrash.reduce(0) { $0 + $1.size } }

    private var streamingDescription: String {
        let month = AppModel.size(StreamPolicy.monthlyBytes(interval: model.state.interval), language: model.language)
        return L.t("Videos you haven’t downloaded can rotate too: each one is downloaded right before its turn, and the one it replaces is deleted. At your interval that’s about %@ a month. Automatic changes wait while Low Data Mode or Low Power Mode is on. Videos you downloaded yourself stay.", month)
    }

    private var restoreMessage: String {
        let what = model.originalDescription.map { L.t("It was: %@.", $0) } ?? ""
        let shuffleWarning = model.originalDescription == L.t("macOS Shuffle") ? " " + L.t("macOS will start downloading videos again.") : ""
        return [what + shuffleWarning, L.t("Rotation will be paused.")].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The Settings window title comes from macOS in the system language; set it in the app's language instead.
@MainActor
enum SettingsWindowTitle {
    static func apply() {
        DispatchQueue.main.async {
            let title = L.t("%@ Settings", AppInfo.name)
            for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true || window.title.contains(AppInfo.name) {
                if window.frame.width < 700 { window.title = title }
            }
        }
    }
}
