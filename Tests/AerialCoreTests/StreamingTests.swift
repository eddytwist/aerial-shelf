import Foundation
import Testing
@testable import AerialCore

/// A catalog with Apple-hosted addresses, so videos can be streamed.
private func appleCatalog(customEnabled: Bool = false) -> Catalog {
    func asset(_ id: String, dynamic: Bool = false, custom: Bool = false, url: String? = nil) -> AerialAsset {
        var asset = AerialAsset(
            id: id, nameKey: id, fallbackName: id, categoryIDs: [dynamic ? Catalog.dynamicCategoryID : "landscape"],
            subcategoryIDs: [], preferredOrder: 0, includeInShuffle: true,
            remoteURL: URL(string: url ?? "https://sylvan.apple.com/Videos/\(id).mov"), isDynamic: dynamic
        )
        asset.isCustom = custom
        return asset
    }
    return Catalog(
        assets: [
            asset("kept"), asset("missing"), asset("old"), asset("dyn", dynamic: true),
            asset("own", custom: true), asset("ownGone", custom: true), asset("elsewhere", url: "https://evil.example/x.mov"),
        ],
        categories: [], strings: [:], customEnabled: customEnabled
    )
}

private func video(_ id: String, size: Int64 = 50_000_000, source: String? = nil) -> LocalVideo {
    LocalVideo(
        assetID: id, url: URL(fileURLWithPath: "/tmp/\(id).mov"), size: size,
        sourceURL: source ?? "https://sylvan.apple.com/Videos/\(id).mov", modified: Date()
    )
}

@Suite struct StreamPolicyTests {
    let catalog = appleCatalog(customEnabled: true)
    let local: [String: LocalVideo] = [
        "kept": video("kept"),
        "old": video("old", source: "https://sylvan.apple.com/Videos/old-v1.mov"),
        "own": video("own", source: nil),
    ]

    @Test func streamsOnlyApplesDownloadableVideos() {
        #expect(StreamPolicy.isStreamable("kept", catalog: catalog, local: local))
        #expect(StreamPolicy.isStreamable("missing", catalog: catalog, local: local))
        // Apple replaced the file: downloaded again for its turn.
        #expect(StreamPolicy.isStreamable("old", catalog: catalog, local: local))
        #expect(StreamPolicy.isStreamable("own", catalog: catalog, local: local))
        // The user's own videos are never downloaded; one whose file is gone can't rotate.
        #expect(!StreamPolicy.isStreamable("ownGone", catalog: catalog, local: local))
        #expect(!StreamPolicy.isStreamable("dyn", catalog: catalog, local: local))
        #expect(!StreamPolicy.isStreamable("elsewhere", catalog: catalog, local: local))
        #expect(!StreamPolicy.isStreamable("unknown", catalog: catalog, local: local))
    }

    @Test func needsDownloadOnlyWhenNotSafeOnDisk() {
        #expect(!StreamPolicy.needsDownload("kept", catalog: catalog, local: local))
        #expect(StreamPolicy.needsDownload("missing", catalog: catalog, local: local))
        #expect(StreamPolicy.needsDownload("old", catalog: catalog, local: local))
    }

    @Test func poolIncludesVideosNotOnDiskOnlyWhenStreaming() {
        let playlist = Playlist(name: "P", assetIDs: ["kept", "missing", "dyn", "ownGone", "missing"])
        let mode = RotationMode.playlist(playlist.id)
        #expect(RotationPool.candidates(mode: mode, playlists: [playlist], catalog: catalog, local: local) == ["kept"])
        #expect(RotationPool.candidates(mode: mode, playlists: [playlist], catalog: catalog, local: local, streaming: true)
                == ["kept", "missing"])
    }

    /// Apple's catalog plus the user's own videos on disk (they rotate with Apple's).
    @Test func allAerialsRotatesTheWholeCatalogOnlyWhenStreaming() {
        #expect(RotationPool.candidates(mode: .allAerials, playlists: [], catalog: catalog, local: local, streaming: true)
                == ["kept", "missing", "old", "own"])
        // Without streaming it falls back to what is safely on disk.
        #expect(RotationPool.candidates(mode: .allAerials, playlists: [], catalog: catalog, local: local) == ["kept", "own"])
    }

    @Test func deletesOnlyStreamedCopiesNothingUses() {
        let onDisk: Set = ["a", "b", "c", "d", "e"]
        let result = StreamPolicy.deletable(
            streamed: ["a", "b", "c", "d", "e", "gone"], current: "a", referenced: ["a", "b"], protected: ["c"], onDisk: onDisk
        )
        // a: on screen; b: the screen saver or another display uses it; c: protected; gone: no file.
        #expect(result == ["d", "e"])
    }

    @Test func deletesNothingWhenTheSettingsCantBeRead() {
        #expect(StreamPolicy.deletable(streamed: ["a"], current: nil, referenced: nil, protected: [], onDisk: ["a"]).isEmpty)
    }

    @Test func aFileTheUserHadStaysTheirs() {
        #expect(StreamPolicy.countsAsStreamed("x", wasOnDisk: false, streamed: []))
        #expect(!StreamPolicy.countsAsStreamed("x", wasOnDisk: true, streamed: []))
        #expect(StreamPolicy.countsAsStreamed("x", wasOnDisk: true, streamed: ["x"]))
    }

    @Test func failuresWaitAndRetryLater() {
        #expect(StreamPolicy.wait(after: DownloadError.cancelled) == nil)
        #expect(StreamPolicy.wait(after: DownloadError.constrainedNetwork) == .lowDataMode)
        #expect(StreamPolicy.wait(after: DownloadError.notEnoughSpace(needed: 1, available: 0)) == .diskSpace)
        #expect(StreamPolicy.wait(after: DownloadError.badResponse(404)) == .server)
        #expect(StreamPolicy.wait(after: DownloadError.failed("The network connection was lost.")) == .network)
        #expect(StreamPolicy.wait(after: URLError(.timedOut)) == .network)
        let delays = (1...6).map { StreamPolicy.retryDelay(failures: $0, reason: .network) / 60 }
        #expect(delays == [5, 15, 30, 60, 60, 60])
        #expect(StreamPolicy.retryDelay(failures: 4, reason: .lowPowerMode) == 15 * 60)
    }

    @Test func onlyTheScheduleWaitsForLowPowerMode() {
        #expect(StreamPolicy.waitsBeforeDownload(automatic: true, lowPowerMode: true) == .lowPowerMode)
        #expect(StreamPolicy.waitsBeforeDownload(automatic: false, lowPowerMode: true) == nil)
        #expect(StreamPolicy.waitsBeforeDownload(automatic: true, lowPowerMode: false) == nil)
    }

    @Test func lowDataModeIsReportedAsSuch() {
        let constrained = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.constrained.rawValue,
        ])
        #expect(AerialDownloader.downloadError(for: constrained) == .constrainedNetwork)
        let expensive = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.expensive.rawValue,
        ])
        #expect(AerialDownloader.downloadError(for: expensive) == .constrainedNetwork)
        #expect(AerialDownloader.downloadError(for: URLError(.cancelled)) == .cancelled)
        if case .failed = AerialDownloader.downloadError(for: URLError(.notConnectedToInternet)) {} else {
            Issue.record("a plain offline error should be a failure to retry")
        }
    }

    @Test func monthlyEstimateFollowsTheInterval() {
        #expect(StreamPolicy.monthlyBytes(interval: .day) == 30 * StreamPolicy.averageVideoBytes)
        #expect(StreamPolicy.monthlyBytes(interval: .hours3) == 240 * StreamPolicy.averageVideoBytes)
    }

    @Test func streamedCopiesAreNotReportedAsMacOSDownloads() {
        let found = RotationPool.unexpectedDownloads(known: [], local: ["s": video("s"), "x": video("x")],
                                                     downloadedByApp: [], streamed: ["s"])
        #expect(found.map(\.assetID) == ["x"])
    }
}

@Suite struct StreamingStateTests {
    @Test func olderStateFilesStartWithStreamingOff() throws {
        let json = #"{"interval":"day","mode":{"allDownloaded":{}},"paused":false,"playlists":[],"bag":[]}"#
        let state = try JSONDecoder.iso.decode(RotationState.self, from: Data(json.utf8))
        #expect(!state.streaming)
        #expect(state.streamedIDs.isEmpty)
        #expect(state.streamedSizes.isEmpty)
        #expect(state.unreadableKeys.isEmpty)
    }

    @Test func streamingStateSurvivesASave() throws {
        var state = RotationState()
        state.streaming = true
        state.mode = .allAerials
        state.streamedIDs = ["a"]
        state.streamedSizes = ["a": 123, "b": 456]
        let decoded = try JSONDecoder.iso.decode(RotationState.self, from: JSONEncoder.iso.encode(state))
        #expect(decoded == state)
    }

    @Test func aModeFromANewerVersionFallsBackWithoutLosingTheRest() throws {
        let json = #"{"mode":{"somethingNew":{}},"streaming":true,"streamedIDs":["a"],"playlists":[{"name":"P","assetIDs":["x"]}]}"#
        let state = try JSONDecoder.iso.decode(RotationState.self, from: Data(json.utf8))
        #expect(state.mode == .allDownloaded)
        #expect(state.streaming)
        #expect(state.streamedIDs == ["a"])
        #expect(state.playlists.count == 1)
        #expect(state.unreadableKeys == ["mode"])
    }
}

/// The whole cycle on a fake home folder: the old video stays until the new one is on screen, then goes.
@Suite struct StreamCacheTests {
    @Test func deletesTheReplacedCopyOnlyAfterTheNewVideoIsOnScreen() async throws {
        let box = try Sandbox()  // Tahoe Day on screen (the user's download), Golden Gate Night on disk.
        let agent = try FakeAgent(.keeps, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        // A streamed copy of Tahoe Night arrives and goes on screen.
        try box.makeVideo(Sandbox.notDownloaded)
        var streamed = [Sandbox.notDownloaded]
        _ = try await switcher.apply(assetID: Sandbox.notDownloaded, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))

        // While it is on screen it stays.
        var result = await StreamCache.prune(streamed: streamed, protected: [], paths: box.paths)
        #expect(result.deleted.isEmpty)
        #expect(result.remaining == streamed)
        streamed = result.remaining

        // The next video goes on screen; now the streamed copy goes, the user's own download stays.
        _ = try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        result = await StreamCache.prune(streamed: streamed, protected: [], paths: box.paths)
        #expect(result.deleted == [Sandbox.notDownloaded: 2_000_000])
        #expect(result.remaining.isEmpty)
        let left = Set(LocalLibrary.scan(paths: box.paths).keys)
        #expect(left == [Sandbox.tahoeDay, Sandbox.goldenGateNight])
        // Deleted for good, not moved to the Trash (where it would still take the space).
        #expect(!FileManager.default.fileExists(atPath: box.paths.videoFile(for: Sandbox.notDownloaded).path))
    }

    @Test func keepsEverythingWhenTheSettingsCantBeRead() async throws {
        let box = try Sandbox()
        try Data("garbage".utf8).write(to: box.paths.storeIndex)
        let result = await StreamCache.prune(streamed: [Sandbox.goldenGateNight], protected: [], paths: box.paths)
        #expect(result.deleted.isEmpty)
        #expect(result.remaining == [Sandbox.goldenGateNight])
        #expect(FileManager.default.fileExists(atPath: box.paths.videoFile(for: Sandbox.goldenGateNight).path))
    }

    @Test func keepsEverythingWhileAnotherChangeIsInProgress() async throws {
        let box = try Sandbox()
        let result = try await FileLock(url: box.paths.switchLock).withLock {
            await StreamCache.prune(streamed: [Sandbox.goldenGateNight], protected: [], paths: box.paths, lockTimeout: .milliseconds(200))
        }
        #expect(result.deleted.isEmpty)
        #expect(result.remaining == [Sandbox.goldenGateNight])
        #expect(FileManager.default.fileExists(atPath: box.paths.videoFile(for: Sandbox.goldenGateNight).path))
    }

    @Test func neverDeletesProtectedVideosAndKeepsTheOneBeingDownloadedListed() async throws {
        let box = try Sandbox()
        let result = await StreamCache.prune(
            streamed: [Sandbox.goldenGateNight, "IN-FLIGHT", "GONE"], protected: [Sandbox.goldenGateNight, "IN-FLIGHT"], paths: box.paths
        )
        #expect(result.deleted.isEmpty)
        #expect(result.remaining == [Sandbox.goldenGateNight, "IN-FLIGHT"])
    }

    @Test func keepsAVideoTheScreenSaverStillUses() async throws {
        let box = try Sandbox()
        // The store points at Tahoe Day; a streamed copy of it must stay even if the desktop moved on elsewhere.
        let result = await StreamCache.prune(streamed: [Sandbox.tahoeDay], protected: [], paths: box.paths)
        #expect(result.deleted.isEmpty)
    }
}

/// A server that drops the connection halfway through the file.
final class DroppingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "drop.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "4000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 1_000_000))
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {}
}

@Suite struct InterruptedStreamTests {
    @Test func aDroppedDownloadLeavesNoFileAndWaitsForTheNetwork() async throws {
        let box = try Sandbox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DroppingProtocol.self]
        let downloader = AerialDownloader(configuration: configuration, allowedHostSuffixes: ["drop.test"])
        let asset = AerialAsset(id: "DROPPED", nameKey: "K", fallbackName: "D", categoryIDs: [], subcategoryIDs: [],
                                preferredOrder: 0, includeInShuffle: true, remoteURL: URL(string: "https://drop.test/d.mov"), isDynamic: false)
        var caught: Error?
        do { _ = try await downloader.download(asset, paths: box.paths, allowsConstrainedNetwork: false) { _, _ in } } catch { caught = error }
        let error = try #require(caught)
        #expect(StreamPolicy.wait(after: error) == .network)
        let files = try FileManager.default.contentsOfDirectory(atPath: box.paths.videos.path)
        #expect(!files.contains { $0.contains("DROPPED") })
    }
}

/// Records what the downloader asked the network for.
final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "record.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "1100000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 1_100_000)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ConstrainedNetworkTests {
    @Test func scheduledDownloadsStayOffLowDataModeAndManualOnesDont() async throws {
        let box = try Sandbox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        let downloader = AerialDownloader(configuration: configuration, allowedHostSuffixes: ["record.test"])
        func asset(_ id: String) -> AerialAsset {
            AerialAsset(id: id, nameKey: "K", fallbackName: id, categoryIDs: [], subcategoryIDs: [], preferredOrder: 0,
                        includeInShuffle: true, remoteURL: URL(string: "https://record.test/\(id).mov"), isDynamic: false)
        }
        RecordingProtocol.requests = []
        _ = try await downloader.remoteSize(of: asset("A"), allowsConstrainedNetwork: false)
        _ = try await downloader.download(asset("A"), paths: box.paths, allowsConstrainedNetwork: false) { _, _ in }
        _ = try await downloader.download(asset("B"), paths: box.paths) { _, _ in }
        let flags = RecordingProtocol.requests.map { [$0.allowsConstrainedNetworkAccess, $0.allowsExpensiveNetworkAccess] }
        #expect(flags == [[false, false], [false, false], [true, true]])
    }
}

@Suite struct SwitchRaceTests {
    /// A streamed copy deleted after the caller looked at the disk, but before the switch took the lock:
    /// the switch must not point macOS at a missing file (macOS would download it).
    @Test func neverSetsAVideoWhoseFileWentAwayMeanwhile() async throws {
        let box = try Sandbox()
        let agent = try FakeAgent(.keeps, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        let staleList = LocalLibrary.scan(paths: box.paths)
        try FileManager.default.removeItem(at: box.paths.videoFile(for: Sandbox.goldenGateNight))
        await #expect(throws: SwitchError.unsafe(Sandbox.goldenGateNight, .notDownloaded)) {
            try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: staleList)
        }
        #expect(agent.restarts == 0)
        #expect(try WallpaperStore(url: box.paths.storeIndex).snapshot().assetID == Sandbox.tahoeDay)
    }
}

@Suite struct RotationSourceTests {
    @Test func streamingRotatesTheWholeCatalogInsteadOfTheFewDownloads() {
        #expect(RotationPolicy.source(.allDownloaded, streaming: true) == .allAerials)
        #expect(RotationPolicy.source(.allAerials, streaming: false) == .allDownloaded)
        #expect(RotationPolicy.source(.allAerials, streaming: true) == .allAerials)
        #expect(RotationPolicy.source(.allDownloaded, streaming: false) == .allDownloaded)
        let playlist = RotationMode.playlist(UUID())
        #expect(RotationPolicy.source(playlist, streaming: true) == playlist)
        #expect(RotationPolicy.source(.single("x"), streaming: false) == .single("x"))
    }
}

@Suite struct SourceNormalizationTests {
    @Test func aStreamingStateFrom030RotatesEverythingAndStartsANewRound() {
        var state = RotationState()
        state.streaming = true
        state.mode = .allDownloaded
        state.bag = ["the-other-downloaded-one"]
        let changed = state.normalizeSource()
        #expect(changed)
        #expect(state.mode == .allAerials)
        #expect(state.bag.isEmpty)
        let again = state.normalizeSource()
        #expect(!again)
    }

    @Test func playlistsAndSingleVideosAreLeftAlone() {
        var state = RotationState()
        state.streaming = true
        state.mode = .playlist(UUID())
        state.bag = ["x"]
        let changed = state.normalizeSource()
        #expect(!changed)
        #expect(state.bag == ["x"])
    }

    @Test func theFallbackAfterADeletedPlaylistFollowsTheStorageMode() {
        var state = RotationState()
        #expect(state.wholeLibraryMode == .allDownloaded)
        state.streaming = true
        #expect(state.wholeLibraryMode == .allAerials)
    }
}
