import AerialCore
import AppKit
import SwiftUI

@main
struct AerialShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
                .onAppear { delegate.model = model }
        } label: {
            MenuBarLabel(attention: model.needsAttention)
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

/// Opens the library window from places that have no SwiftUI environment.
@MainActor
enum LibraryOpener {
    static var openAction: (() -> Void)?
    static func open() {
        openAction?()
        NSApp.activate()
    }
}

/// The menu bar label. It appears at launch, before any window, so it also gives
/// Finder and Spotlight reopens a way to open the library.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let attention: Bool

    var body: some View {
        Image(nsImage: MenuBarIcon.image(attention: attention))
            .accessibilityLabel(AppInfo.name)
            .onAppear { LibraryOpener.openAction = { openWindow(id: "library") } }
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
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Aerial Shelf"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let authorURL = URL(string: "https://eddytwist.com")!
}
