import AppKit

/// Launch options for testing and screenshots. They exist only in debug builds
/// (`scripts/build-app.sh --debug`); release builds ignore them.
///
///     -OpenLibraryAtLaunch YES     open the library at launch
///     -LibrarySection all          start the library on a section: all, downloaded, playlist
///                                  (the first playlist) or a category ID such as AerialCategoryLandscapes
///     -OpenSettingsAtLaunch YES    open Settings at launch
///     -OpenMenuAtLaunch YES        open the menu bar menu two seconds after launch
///     -LibraryAtTopRight YES       put the library under the menu bar menu
///     -ForceAppearance dark|light  force an appearance
///     -DebugRotateEverySeconds 40  rotate every N seconds instead of the chosen interval
///     -ImportPaths "/a.mov|/folder" add these videos and folders at launch (as if dropped on My Videos)
@MainActor
enum DebugOptions {
    #if DEBUG
    private static let defaults = UserDefaults.standard
    static var opensLibrary: Bool { defaults.bool(forKey: "OpenLibraryAtLaunch") }
    static var librarySection: String? { defaults.string(forKey: "LibrarySection") }
    static var opensSettings: Bool { defaults.bool(forKey: "OpenSettingsAtLaunch") }
    static var libraryAtTopRight: Bool { defaults.bool(forKey: "LibraryAtTopRight") }
    static var rotateEverySeconds: TimeInterval { defaults.double(forKey: "DebugRotateEverySeconds") }

    static func applyAtLaunch(model: AppModel) {
        if let style = defaults.string(forKey: "ForceAppearance") {
            NSApplication.shared.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
        }
        if let list = defaults.string(forKey: "ImportPaths") {
            let urls = list.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                model.importVideos(urls)
            }
        }
        if defaults.bool(forKey: "OpenMenuAtLaunch") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                statusItemButton()?.performClick(nil)
            }
        }
    }

    static func placeLibraryWindow() {
        guard libraryAtTopRight else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let window = NSApp.windows.first(where: { $0.frame.width > 700 }),
                  let screen = window.screen?.visibleFrame else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - window.frame.width - 8, y: screen.maxY - 8))
        }
    }

    private static func statusItemButton() -> NSButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let match = view as? NSStatusBarButton { return match }
        for subview in view.subviews { if let match = find(in: subview) { return match } }
        return nil
    }
    #else
    static let opensLibrary = false
    static let librarySection: String? = nil
    static let opensSettings = false
    static let rotateEverySeconds: TimeInterval = 0
    static func applyAtLaunch(model: AppModel) {}
    static func placeLibraryWindow() {}
    #endif
}
