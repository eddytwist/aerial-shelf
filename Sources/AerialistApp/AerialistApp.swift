import AerialCore
import AppKit
import SwiftUI

@main
struct AerialistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
                .onAppear { delegate.model = model }
        } label: {
            MenuBarLabel(attention: model.needsAttention || Updater.shared.updateAvailable)
                .onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.menu)

        Window(L.t("Library"), id: "library") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1040, height: 680)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(model.isFirstLaunch || DebugOptions.opensLibrary ? .presented : .suppressed)

        Settings {
            SettingsView()
                .environment(model)
        }
        #if DEBUG
        // Debug builds also show the menu bar menu in the app's own menu bar, so UI tests that can't
        // click status items can reach every command. Visible only when the app runs as a regular app.
        .commands {
            CommandMenu("Shelf") { MenuContent().environment(model) }
        }
        #endif
    }
}

/// Handles reopening from Finder/Spotlight (shows the library) and quitting during downloads.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        WindowPolicy.observe()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in LibraryOpener.open() } }
        return true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveDownloads || model.importStatus != nil else { return .terminateNow }
        let alert = NSAlert()
        if model.hasActiveDownloads {
            alert.messageText = L.t("Quit and stop downloads?")
            alert.informativeText = L.t("Videos being downloaded now will not be saved.")
        } else {
            alert.messageText = L.t("Quit and stop adding videos?")
            alert.informativeText = L.t("Videos already added stay in My Videos.")
        }
        alert.addButton(withTitle: L.t("Quit"))
        alert.addButton(withTitle: L.t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.cancelAllDownloads()
        model.cancelImport()
        return .terminateNow
    }
}

/// A menu bar app (LSUIElement) has no Dock icon and isn't in Cmd+Tab. While one of its windows is open (the library,
/// Settings, the update window) it becomes a regular app, so it can be switched to like any other; when the last one
/// closes it goes back to the menu bar only.
@MainActor
enum WindowPolicy {
    static func observe() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in update() } }
        }
        // A closing window is still visible while it closes: look again a moment later.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { @MainActor in update() } }
        }
        update()
    }

    /// True when a real window is open: titled, normal level, not a panel or alert; a minimized one counts.
    static var hasOpenWindow: Bool {
        NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled)
                && !(window is NSPanel) && window.level == .normal
        }
    }

    static func update() {
        let wanted: NSApplication.ActivationPolicy = hasOpenWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // Becoming a regular app doesn't bring it forward by itself. Going back, its menus could stay in the menu bar
        // until another app is clicked: hiding hands the menu bar back to the app that was in front.
        if wanted == .regular { NSApp.activate() } else if NSApp.isActive { NSApp.hide(nil) }
    }
}

/// Opens the library window from places that have no SwiftUI environment.
@MainActor
enum LibraryOpener {
    static var openAction: (() -> Void)?
    static func open() {
        openAction?()
        NSApp.activate()
        bringToFront()
    }

    /// Raises the library in front of other apps' windows even when macOS doesn't let the app activate.
    static func bringToFront() {
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.frame.width > 700 && $0.styleMask.contains(.titled) }) else { return }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                // A window raised without activation never becomes key, so no notification comes.
                WindowPolicy.update()
            }
        }
    }
}

/// Opens Settings in front of other apps' windows. A menu bar app isn't active when its menu is used,
/// so `SettingsLink` alone opens the window behind whatever app is in front.
@MainActor
enum SettingsOpener {
    static var openAction: (() -> Void)?

    static func open() {
        openAction?()
        NSApp.activate()
        bringToFront()
    }

    /// Raises the Settings window once it exists (it is created asynchronously the first time).
    static func bringToFront() {
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = SettingsWindowTitle.window else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                // macOS may refuse to activate the app (it allows that only right after the user acts on it);
                // the window still comes in front of other apps' windows.
                window.orderFrontRegardless()
                WindowPolicy.update()
            }
        }
    }
}

/// The menu bar label. It appears at launch, before any window, so it also gives
/// Finder and Spotlight reopens a way to open the library, and the menu a way to open Settings.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let attention: Bool

    var body: some View {
        Image(nsImage: MenuBarIcon.image(attention: attention))
            .accessibilityLabel(AppInfo.name)
            .onAppear {
                LibraryOpener.openAction = { openWindow(id: "library") }
                SettingsOpener.openAction = { openSettings() }
            }
    }
}

/// The menu bar icon: a mountain, with a small dot in a cut-out corner when something needs a look.
enum MenuBarIcon {
    static func image(attention: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "mountain.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSImage() }
        let dot: CGFloat = 5
        let gap: CGFloat = 1.5
        // The canvas fits the whole symbol plus room for the dot, so nothing is clipped
        // and the icon keeps its width whether the dot is shown or not.
        let size = NSSize(width: ceil(symbol.size.width + dot / 2), height: max(16, ceil(symbol.size.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(x: 0, y: ((rect.height - symbol.size.height) / 2).rounded())
            symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            if attention {
                let dotRect = NSRect(x: rect.width - dot, y: rect.height - dot, width: dot, height: dot)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -gap, dy: -gap)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum AppInfo {
    /// Product name shown in the UI (from the bundle; `scripts/app.config` sets it).
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Aerialist"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let authorURL = URL(string: "https://eddytwist.com")!
}
