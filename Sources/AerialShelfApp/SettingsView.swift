import AerialCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var askingRestore = false

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
                LabeledContent(L.t("On Disk")) {
                    HStack(spacing: 10) {
                        Text("\(L.videos(model.local.count)) · \(AppModel.size(model.totalDownloadedBytes, language: model.language))")
                            .foregroundStyle(.primary)
                        Button(L.t("Show in Finder")) { NSWorkspace.shared.open(model.paths.videos) }
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
