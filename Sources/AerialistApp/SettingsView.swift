import AerialCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    private let updater = Updater.shared
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

            if updater.isAvailable {
                Section(L.t("Updates")) {
                    Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) })) {
                        Text(L.t("Check for Updates Automatically"))
                        Text(L.t("Once a day, Aerialist asks GitHub for a newer version."))
                    }
                    LabeledContent(updateStatusText) {
                        Button(updater.buttonTitle) { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }

            Section(L.t("Wallpaper")) {
                LabeledContent(L.t("On Screen")) {
                    Text(model.name(of: model.currentAssetID) ?? L.t("Not an aerial wallpaper"))
                        .foregroundStyle(.primary)
                }
                if model.hasPerDisplayOverrides {
                    Text(L.t("Some displays or Spaces have their own wallpaper. Aerialist doesn’t change it there."))
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

            StorageSection()
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
            updater.refreshLastCheckDate()
            SettingsWindowTitle.apply()
            SettingsOpener.bringToFront()
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

    private var updateStatusText: String {
        if updater.updateAvailable, let version = updater.availableVersion {
            return L.t("Version %@ is available", version)
        }
        guard let date = updater.lastCheckDate else { return L.t("Not checked yet") }
        let formatted = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: model.language)))
        return L.t("Last checked: %@", formatted)
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
        DispatchQueue.main.async { window?.title = L.t("%@ Settings", AppInfo.name) }
    }

    /// The Settings window: the app's only small titled window (the library is wider than 700 points).
    static var window: NSWindow? {
        NSApp.windows.first { window in
            (window.identifier?.rawValue.contains("Settings") == true || window.title.contains(AppInfo.name))
                && window.frame.width < 700 && window.styleMask.contains(.titled)
        }
    }
}
