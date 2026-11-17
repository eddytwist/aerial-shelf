import AppKit
import Observation
import Sparkle

/// In-app updates with Sparkle.
///
/// Once a day (and when the user asks) Sparkle downloads `appcast.xml` from the latest GitHub release
/// (`SUFeedURL` in Info.plist). If it lists a newer build, Sparkle downloads that release's disk image,
/// checks its EdDSA signature against `SUPublicEDKey`, replaces the app and relaunches it.
///
/// A scheduled check never opens a window by itself: the menu bar icon gets its dot, and the menu and
/// Settings offer "Update to <version>…". Sparkle's window appears only when the user clicks that or
/// "Check for Updates…".
@MainActor
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// False in debug builds and when the bundle has no feed or key (`swift run`): Sparkle would only show an error.
    let isAvailable: Bool
    /// Whether a check can start now (Sparkle allows one session at a time).
    private(set) var canCheckForUpdates = false
    /// A scheduled check found an update the user hasn't looked at yet.
    private(set) var updateAvailable = false
    /// Its version, for "Update to 0.4.0…".
    private(set) var availableVersion: String?
    /// Sparkle stores this in the app's user defaults; mirrored here so SwiftUI sees changes.
    private(set) var automaticallyChecks = false
    /// When the feed was last checked, by schedule or by hand.
    private(set) var lastCheckDate: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private override init() {
        #if DEBUG
        // Debug builds (screenshots, UI checks) share the bundle ID; don't offer to replace them with a release.
        isAvailable = false
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        isAvailable = info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
        #endif
        super.init()
    }

    /// Starts Sparkle's schedule. Call once, when the app has finished launching.
    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Sparkle changes both on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
        ]
        controller.startUpdater()
        lastCheckDate = updater.lastUpdateCheckDate
    }

    func refreshLastCheckDate() {
        lastCheckDate = controller?.updater.lastUpdateCheckDate
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    /// Checks now and shows the result, or shows the update a scheduled check already found.
    func checkForUpdates() {
        guard let controller else { return }
        // Opened from the menu or Settings: Sparkle's window comes to the front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// "Update to 0.4.0…" when an update is waiting, otherwise "Check for Updates…".
    var buttonTitle: String {
        if updateAvailable, let availableVersion { return L.t("Update to %@…", availableVersion) }
        return L.t("Check for Updates…")
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { refreshLastCheckDate() }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates are never shown by Sparkle; the menu and Settings offer them instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let userInitiated = state.userInitiated
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !userInitiated {
                updateAvailable = true
                availableVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearAvailableUpdate() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearAvailableUpdate() }
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        availableVersion = nil
    }
}
