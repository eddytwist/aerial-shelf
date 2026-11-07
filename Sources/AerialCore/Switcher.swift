import Foundation

/// Restarts the macOS wallpaper service so it reads the store again.
public protocol WallpaperAgentControlling: Sendable {
    func restart() async throws
}

public enum AgentError: Error, Equatable, CustomStringConvertible {
    case notRestarted(Int32)

    public var description: String {
        switch self {
        case .notRestarted(let status): "The wallpaper service could not be restarted (killall exited with \(status))"
        }
    }
}

/// `WallpaperAgent` reads the store only at launch and is relaunched by the system right after it quits.
public struct SystemWallpaperAgent: WallpaperAgentControlling {
    public init() {}

    public func restart() async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["WallpaperAgent"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw AgentError.notRestarted(status) }
    }
}

public enum SwitchError: Error, Equatable, CustomStringConvertible {
    case unsafe(String, SafetyVerdict)
    case store(StoreError)
    case agent(AgentError)
    /// The agent kept the old setting twice; the previous store was put back.
    case notApplied(String)
    /// The agent replaced the store with something else (usually its defaults); the previous store was put back.
    case storeWasReset
    /// Another process (the app or `aerialctl`) was changing the wallpaper and didn't finish in time.
    case busy

    public var description: String {
        switch self {
        case .unsafe(let id, let verdict): "\(id) cannot be set without downloading (\(verdict))"
        case .store(let error): error.description
        case .agent(let error): error.description
        case .notApplied(let id): "macOS did not apply \(id); the previous wallpaper was restored"
        case .storeWasReset: "macOS rejected the change and reset the wallpaper; the previous settings were restored"
        case .busy: "another change of the wallpaper is in progress; try again in a moment"
        }
    }
}

public struct SwitchResult: Equatable, Sendable {
    public let assetID: String
    public let attempts: Int
}

/// Sets one downloaded aerial as the wallpaper, safely.
///
/// 1. Refuses videos that are not fully on disk (macOS would download them).
/// 2. Backs up the store, writes the change atomically, restarts the agent.
/// 3. Reads the store back. If the agent wrote the old store back while quitting, tries once more
///    from the same original. Anything else (a reset to defaults) puts the original back.
public struct Switcher: Sendable {
    public let paths: AerialPaths
    public let agent: WallpaperAgentControlling
    public let settleDelay: Duration

    public init(paths: AerialPaths, agent: WallpaperAgentControlling = SystemWallpaperAgent(), settleDelay: Duration = .milliseconds(1500)) {
        self.paths = paths
        self.agent = agent
        self.settleDelay = settleDelay
    }

    var store: WallpaperStore { WallpaperStore(url: paths.storeIndex) }
    var backups: BackupStore { BackupStore(paths: paths) }

    /// - Parameter onSuccess: runs before the lock is released, so another process that waits for the lock
    ///   (or checks it) never sees the new wallpaper without what the caller records about it.
    public func apply(
        assetID: String, catalog: Catalog, local: [String: LocalVideo],
        onSuccess: ((SwitchResult) -> Void)? = nil
    ) async throws -> SwitchResult {
        try await locked {
            let result = try await applyUnlocked(assetID: assetID, catalog: catalog, local: local)
            onSuccess?(result)
            return result
        }
    }

    /// Runs a change while holding the lock shared with the other process (app or `aerialctl`).
    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await FileLock(url: paths.switchLock).withLock(body)
        } catch is FileLock.LockError {
            throw SwitchError.busy
        }
    }

    private func applyUnlocked(assetID: String, catalog: Catalog, local: [String: LocalVideo]) async throws -> SwitchResult {
        let verdict = SafetyCheck.verdict(assetID: assetID, catalog: catalog, local: local)
        guard verdict.isSafe else { throw SwitchError.unsafe(assetID, verdict) }

        let before = try readStore()
        let beforeSnapshot = try? WallpaperStore.inspect(before)
        do { try backups.backUp(before) } catch {
            throw SwitchError.store(.writeFailed("backup: \(error.localizedDescription)"))
        }
        let edited: Data
        do { edited = try WallpaperStore.settingAerial(assetID, in: before) } catch let error as StoreError {
            throw SwitchError.store(error)
        }

        for attempt in 1...2 {
            try write(edited)
            try await restartAgent(restoringOnFailure: before)
            try? await Task.sleep(for: settleDelay)

            let after = try? store.snapshot()
            if after?.assetID == assetID, after?.provider == WallpaperStore.aerialsProvider {
                return SwitchResult(assetID: assetID, attempts: attempt)
            }
            // The agent saved the old settings while quitting: same store as before, try again.
            if let after, after == beforeSnapshot { continue }
            try await putBack(before)
            throw SwitchError.storeWasReset
        }
        try await putBack(before)
        throw SwitchError.notApplied(assetID)
    }

    /// Puts back the store from before the app's first change.
    /// The current store is backed up first; if macOS rejects the original, the current one is put back.
    public func restoreOriginal() async throws {
        try await locked { try await restoreOriginalUnlocked() }
    }

    private func restoreOriginalUnlocked() async throws {
        let original: Data
        do { original = try backups.original() } catch {
            throw SwitchError.store(.unreadable("no original copy: \(error.localizedDescription)"))
        }
        do { _ = try WallpaperStore.inspect(original) } catch let error as StoreError { throw SwitchError.store(error) }
        let current = try readStore()
        do { try backups.backUp(current) } catch {
            throw SwitchError.store(.writeFailed("backup: \(error.localizedDescription)"))
        }
        try write(original)
        try await restartAgent(restoringOnFailure: current)
        try? await Task.sleep(for: settleDelay)
        let expected = try? WallpaperStore.inspect(original)
        if let after = try? store.snapshot(), after == expected { return }
        try await putBack(current)
        throw SwitchError.storeWasReset
    }

    private func readStore() throws -> Data {
        do { return try store.readData() } catch let error as StoreError { throw SwitchError.store(error) }
    }

    private func write(_ data: Data) throws {
        do { try store.write(data) } catch let error as StoreError { throw SwitchError.store(error) }
    }

    private func restartAgent(restoringOnFailure previous: Data) async throws {
        do {
            try await agent.restart()
        } catch {
            // The file is already written; put the previous one back so nothing changes on the next launch.
            try? store.write(previous)
            if let agentError = error as? AgentError { throw SwitchError.agent(agentError) }
            throw SwitchError.agent(.notRestarted(-1))
        }
    }

    private func putBack(_ data: Data) async throws {
        try write(data)
        try await restartAgent(restoringOnFailure: data)
    }
}
