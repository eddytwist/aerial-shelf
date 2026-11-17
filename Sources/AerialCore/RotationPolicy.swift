import Foundation

/// Decisions the app makes about the wallpaper on screen, kept free of UI so they can be tested.
public enum RotationPolicy {
    /// What the app should do after reading the store.
    public enum Observation: Equatable, Sendable {
        /// Nothing unusual.
        case fine
        /// Apple's own shuffle is on: macOS will download new videos.
        case appleShuffle
        /// Someone picked another wallpaper outside the app (System Settings); respect it and pause.
        case changedOutside
    }

    /// - Parameters:
    ///   - lastAssetID: the video the app itself set last (`nil` if it never set one).
    ///   - paused: rotation is already paused (then an outside change needs no new pause).
    public static func observe(_ snapshot: StoreSnapshot, lastAssetID: String?, paused: Bool) -> Observation {
        if snapshot.isAerial, snapshot.isShuffle { return .appleShuffle }
        guard let lastAssetID, !paused else { return .fine }
        if !snapshot.isAerial || snapshot.assetID != lastAssetID { return .changedOutside }
        return .fine
    }

    /// On the very first launch Apple's shuffle is replaced at once: stopping its downloads is why the app was installed.
    public static func replacesAppleShuffleAtLaunch(isFirstLaunch: Bool, observation: Observation, poolCount: Int) -> Bool {
        isFirstLaunch && observation == .appleShuffle && poolCount > 0
    }

    /// Whether "Next Video" can show something new.
    public static func canAdvance(pool: [String], current: String?) -> Bool {
        pool.contains { $0 != current }
    }

    /// What Resume Rotation does.
    public enum ResumeAction: Equatable, Sendable {
        /// The video on screen belongs to the rotation: keep it and count the interval from now.
        case keep(String)
        /// Show the next video from the rotation now.
        case advance
        /// Nothing to rotate: accept what is on screen as the app's own, so it isn't reported as changed outside again.
        case accept(String?)
    }

    public static func resume(current: String?, pool: [String]) -> ResumeAction {
        if let current, pool.contains(current) { return .keep(current) }
        return pool.isEmpty ? .accept(current) : .advance
    }

    /// What the scheduled check does.
    public enum TickAction: Equatable, Sendable {
        /// Not due yet.
        case wait
        /// Due: show the next video.
        case advance
        /// Due, but there is nothing new to show: try again after one interval, silently.
        case postpone
    }

    public static func tick(isDue: Bool, pool: [String], current: String?) -> TickAction {
        guard isDue else { return .wait }
        return canAdvance(pool: pool, current: current) ? .advance : .postpone
    }

    /// What happens right after the rotation mode changes.
    public enum ModeChange: Equatable, Sendable {
        /// "Only this video" with a video that isn't on screen: show it.
        case show(String)
        /// The video on screen isn't in the new set: show one from it now.
        case advance
        /// Keep what is on screen.
        case stay
    }

    public static func afterModeChange(to mode: RotationMode, current: String?, pool: [String], paused: Bool) -> ModeChange {
        if case .single(let id) = mode { return id == current ? .stay : .show(id) }
        if let current, !pool.contains(current), !pool.isEmpty, !paused { return .advance }
        return .stay
    }

    /// Whether a video counts as in use, so it can't be moved to the Trash: on screen, referenced by any display,
    /// Space or screen saver, or unknown because the wallpaper settings couldn't be read (`referenced == nil`).
    public static func isInUse(_ id: String, current: String?, referenced: Set<String>?) -> Bool {
        guard let referenced else { return true }
        return id == current || referenced.contains(id)
    }

    /// A failed change pauses rotation: retrying every minute would restart the wallpaper service again and again.
    public static let pausesAfterFailedChange = true
}
