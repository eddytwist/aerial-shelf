import Foundation
import Testing
@testable import AerialCore

@Suite struct ShuffleRoundTests {
    @Test func noVideoGetsAFixedPlaceAcrossRounds() {
        let pool = ["a", "b", "c", "d", "e"]
        var bag: [String] = []
        var rng = SeededGenerator(state: 2026)
        var current: String? = nil
        var lastOfEachRound: [String] = []
        for round in 0..<12 {
            for index in 0..<pool.count {
                current = ShuffleBag.next(pool: pool, bag: &bag, current: current, using: &rng)
                if index == pool.count - 1 { lastOfEachRound.append(current!) }
            }
            #expect(bag.isEmpty, "round \(round) should end with an empty bag")
        }
        #expect(Set(lastOfEachRound).count > 1)
    }
}

@Suite struct ResumeTickModeTests {
    @Test func resumeKeepsAVideoFromTheRotation() {
        #expect(RotationPolicy.resume(current: "a", pool: ["a", "b"]) == .keep("a"))
    }

    @Test func resumeMovesOnFromAVideoOutsideTheRotation() {
        #expect(RotationPolicy.resume(current: "x", pool: ["a", "b"]) == .advance)
        #expect(RotationPolicy.resume(current: nil, pool: ["a"]) == .advance)
    }

    @Test func resumeWithNothingToRotateAcceptsTheScreen() {
        #expect(RotationPolicy.resume(current: "x", pool: []) == .accept("x"))
        #expect(RotationPolicy.resume(current: nil, pool: []) == .accept(nil))
    }

    @Test func tickAdvancesOnlyWhenDueAndPossible() {
        #expect(RotationPolicy.tick(isDue: false, pool: ["a", "b"], current: "a") == .wait)
        #expect(RotationPolicy.tick(isDue: true, pool: ["a", "b"], current: "a") == .advance)
        #expect(RotationPolicy.tick(isDue: true, pool: ["a"], current: "a") == .postpone)
        #expect(RotationPolicy.tick(isDue: true, pool: [], current: nil) == .postpone)
    }

    @Test func modeChangeShowsAVideoOnlyWhenNeeded() {
        #expect(RotationPolicy.afterModeChange(to: .single("b"), current: "a", pool: ["b"], paused: false) == .show("b"))
        #expect(RotationPolicy.afterModeChange(to: .single("a"), current: "a", pool: ["a"], paused: false) == .stay)
        #expect(RotationPolicy.afterModeChange(to: .allDownloaded, current: "x", pool: ["a"], paused: false) == .advance)
        #expect(RotationPolicy.afterModeChange(to: .allDownloaded, current: "x", pool: ["a"], paused: true) == .stay)
        #expect(RotationPolicy.afterModeChange(to: .allDownloaded, current: "a", pool: ["a", "b"], paused: false) == .stay)
        #expect(RotationPolicy.afterModeChange(to: .allDownloaded, current: "x", pool: [], paused: false) == .stay)
    }

    @Test func unreadableSettingsMakeEveryVideoInUse() {
        #expect(RotationPolicy.isInUse("a", current: "a", referenced: []))
        #expect(RotationPolicy.isInUse("b", current: "a", referenced: ["b"]))
        #expect(!RotationPolicy.isInUse("c", current: "a", referenced: ["b"]))
        #expect(RotationPolicy.isInUse("c", current: "a", referenced: nil))
    }

    @Test func failedChangesPauseRotation() {
        #expect(RotationPolicy.pausesAfterFailedChange)
    }
}

@Suite struct DamagedStateTests {
    @Test func oneDamagedPlaylistKeepsTheOthersAndACopy() throws {
        let box = try Sandbox()
        let good = UUID()
        let json = """
        {"interval":"week","playlists":[{"id":"\(good.uuidString)","name":"Good","assetIDs":["a"]}, 42,
         {"name":"No ID"}],"language":"ru"}
        """
        try FileManager.default.createDirectory(at: box.paths.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: box.paths.stateFile)
        let loaded = StateStore(paths: box.paths).load()
        #expect(loaded.state.interval == .week)
        #expect(loaded.state.language == "ru")
        #expect(loaded.state.playlists.map(\.name) == ["Good", "No ID"])
        #expect(loaded.state.playlists.first?.id == good)
        #expect(loaded.partial)
        let copy = try #require(loaded.corruptCopy)
        #expect(copy.lastPathComponent.hasPrefix("state.partial-"))
        #expect(FileManager.default.fileExists(atPath: box.paths.stateFile.path), "the original stays in place")
    }

    @Test func readingNeverMovesAFile() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: box.paths.stateFile)
        let store = StateStore(paths: box.paths)
        #expect(store.read() == nil)
        #expect(FileManager.default.fileExists(atPath: box.paths.stateFile.path))
        var state = RotationState()
        state.interval = .hours6
        try store.save(state)
        #expect(store.read()?.interval == .hours6)
        #expect(store.modificationDate() != nil)
    }
}

@Suite struct FileLockTests {
    @Test func secondHolderWaitsThenTimesOut() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "aerial-lock-\(UUID().uuidString)/switch.lock")
        let first = FileLock(url: url)
        let second = FileLock(url: url)
        #expect(!second.isHeld())
        try await first.withLock {
            #expect(second.isHeld())
            await #expect(throws: FileLock.LockError.self) {
                _ = try await second.withLock(timeout: .milliseconds(300)) {}
            }
        }
        #expect(!second.isHeld())
        // Free again once the first holder is done.
        let value = try await second.withLock(timeout: .milliseconds(300)) { 7 }
        #expect(value == 7)
    }
}

@Suite struct LanguageChoiceTests {
    private func decode(_ json: String) throws -> RotationState {
        try JSONDecoder.iso.decode(RotationState.self, from: Data(json.utf8))
    }

    @Test func newInstallsFollowTheSystem() {
        #expect(RotationState().language == RotationState.systemLanguage)
    }

    @Test func the010DefaultBecomesSystemButRussianStays() throws {
        #expect(try decode(#"{"language":"en"}"#).language == RotationState.systemLanguage)
        #expect(try decode(#"{"language":"ru"}"#).language == "ru")
        #expect(try decode(#"{}"#).language == RotationState.systemLanguage)
    }

    @Test func anExplicitChoiceIsKept() throws {
        #expect(try decode(#"{"uiLanguage":"en","language":"ru"}"#).language == "en")
        var state = RotationState()
        state.language = "en"
        let data = try JSONEncoder.iso.encode(state)
        #expect(String(decoding: data, as: UTF8.self).contains("\"uiLanguage\""))
        #expect(try JSONDecoder.iso.decode(RotationState.self, from: data).language == "en")
    }
}
