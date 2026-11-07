import Foundation
import Testing
@testable import AerialCore

/// Deterministic generator for shuffle tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite struct ShuffleBagTests {
    @Test func showsEveryVideoOnceBeforeRepeating() {
        let pool = (1...10).map { "v\($0)" }
        var bag: [String] = []
        var rng = SeededGenerator(state: 42)
        var current: String? = nil
        var seen: [String] = []
        for _ in 0..<10 {
            current = ShuffleBag.next(pool: pool, bag: &bag, current: current, using: &rng)
            seen.append(current!)
        }
        #expect(Set(seen).count == 10)
    }

    @Test func neverRepeatsTheSameVideoBackToBack() {
        let pool = ["a", "b", "c"]
        var bag: [String] = []
        var rng = SeededGenerator(state: 7)
        var current: String? = nil
        for _ in 0..<300 {
            let next = ShuffleBag.next(pool: pool, bag: &bag, current: current, using: &rng)
            #expect(next != current)
            current = next
        }
    }

    @Test func dropsVideosThatLeftThePool() {
        var bag = ["a", "gone", "b"]
        let next = ShuffleBag.next(pool: ["a", "b"], bag: &bag, current: nil)
        #expect(next == "a")
        #expect(bag == ["b"])
    }

    @Test func singleVideoPoolDoesNotReapplyTheVideoOnScreen() {
        var bag: [String] = []
        #expect(ShuffleBag.next(pool: ["only"], bag: &bag, current: "only") == nil)
        #expect(ShuffleBag.next(pool: ["only"], bag: &bag, current: "other") == "only")
        #expect(ShuffleBag.next(pool: [], bag: &bag, current: nil) == nil)
    }

    @Test func roundsCoverEveryVideoEvenAcrossTheBoundary() {
        let pool = (1...6).map { "v\($0)" }
        var bag: [String] = []
        var rng = SeededGenerator(state: 99)
        var current: String? = nil
        var picks: [String] = []
        for _ in 0..<18 {
            current = ShuffleBag.next(pool: pool, bag: &bag, current: current, using: &rng)
            picks.append(current!)
        }
        for round in stride(from: 0, to: 18, by: 6) {
            #expect(Set(picks[round..<round + 6]).count == 6)
        }
    }
}

@Suite struct ScheduleTests {
    @Test func firstRunDoesNotSwitchImmediately() {
        var state = RotationState()
        let now = Date()
        #expect(!state.isDue(now: now))
        state.startScheduleIfNeeded(now: now)
        #expect(!state.isDue(now: now))
        #expect(state.isDue(now: now.addingTimeInterval(24 * 3600)))
    }

    @Test func pauseAndSingleModeStopTheSchedule() {
        var state = RotationState()
        state.lastChange = Date(timeIntervalSince1970: 0)
        #expect(state.isDue())
        state.paused = true
        #expect(!state.isDue())
        state.paused = false
        state.mode = .single("x")
        #expect(!state.isDue())
    }

    @Test func intervalsMatchTheMenu() {
        #expect(RotationInterval.allCases.map(\.seconds) == [10_800, 21_600, 43_200, 86_400, 172_800, 604_800])
    }

    @Test func stateSurvivesSaveAndLoad() throws {
        let box = try Sandbox()
        var state = RotationState()
        state.mode = .playlist(UUID())
        state.playlists = [Playlist(name: "Favorites", assetIDs: [Sandbox.tahoeDay])]
        state.lastChange = Date(timeIntervalSince1970: 1_800_000_000)
        state.language = "ru"
        let store = StateStore(paths: box.paths)
        try store.save(state)
        #expect(store.load().state == state)
        #expect(store.load().corruptCopy == nil)
    }

    @Test func poolContainsOnlySafeDownloadedVideos() throws {
        let box = try Sandbox()
        let catalog = try box.catalog()
        let local = LocalLibrary.scan(paths: box.paths)
        let all = RotationPool.candidates(mode: .allDownloaded, playlists: [], catalog: catalog, local: local)
        #expect(all == [Sandbox.tahoeDay, Sandbox.goldenGateNight].sorted())
        let playlist = Playlist(name: "Mix", assetIDs: [Sandbox.goldenGateNight, Sandbox.notDownloaded])
        let fromPlaylist = RotationPool.candidates(mode: .playlist(playlist.id), playlists: [playlist], catalog: catalog, local: local)
        #expect(fromPlaylist == [Sandbox.goldenGateNight])
    }

    @Test func detectsVideosMacOSDownloadedOnItsOwn() throws {
        let box = try Sandbox()
        try box.makeVideo(Sandbox.notDownloaded)
        let local = LocalLibrary.scan(paths: box.paths)
        let found = RotationPool.unexpectedDownloads(
            known: [Sandbox.tahoeDay, Sandbox.goldenGateNight], local: local, downloadedByApp: []
        )
        #expect(found.map(\.assetID) == [Sandbox.notDownloaded])
        #expect(RotationPool.unexpectedDownloads(known: [Sandbox.tahoeDay, Sandbox.goldenGateNight], local: local, downloadedByApp: [Sandbox.notDownloaded]).isEmpty)
    }
}
