import Foundation
import Testing
@testable import AerialCore

/// Serves canned responses so the downloader can be tested without the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var etag: String? = "\"stub-etag-1\""

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers = ["Content-Length": "\(Self.body.count)"]
        if let etag = Self.etag { headers["ETag"] = etag }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct DownloaderTests {
    func asset(_ id: String = "AAAA-STUB") -> AerialAsset {
        AerialAsset(
            id: id, nameKey: "K", fallbackName: "Stub", categoryIDs: ["landscape"], subcategoryIDs: [],
            preferredOrder: 0, includeInShuffle: true, remoteURL: URL(string: "https://stub.test/\(id).mov"), isDynamic: false
        )
    }

    @Test func downloadsIntoTheMacOSFolderWithAttributes() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.body = Data(repeating: 7, count: 2_100_000)
        StubProtocol.status = 200
        let box = try Sandbox()
        let downloader = AerialDownloader(configuration: .stubbed, allowedHostSuffixes: ["stub.test"])
        let file = try await downloader.download(asset(), paths: box.paths) { _, _ in }
        #expect(file == box.paths.videoFile(for: "AAAA-STUB"))
        #expect(try Data(contentsOf: file).count == 2_100_000)
        #expect(ExtendedAttributes.string(named: "SourceURL", at: file) == "https://stub.test/AAAA-STUB.mov")
        #expect(ExtendedAttributes.string(named: "LastETag", at: file) == "\"stub-etag-1\"")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.paths.videos.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func failedDownloadLeavesNoFile() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.body = Data("not found".utf8)
        StubProtocol.status = 404
        let box = try Sandbox()
        let downloader = AerialDownloader(configuration: .stubbed, allowedHostSuffixes: ["stub.test"])
        await #expect(throws: DownloadError.badResponse(404)) {
            try await downloader.download(asset(), paths: box.paths) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: box.paths.videoFile(for: "AAAA-STUB").path))
    }

    @Test func refusesNonAppleAndPlainHTTPAddresses() async throws {
        let box = try Sandbox()
        for address in ["https://evil.example/x.mov", "http://sylvan.apple.com/x.mov", "https://apple.com.evil.example/x.mov"] {
            let bad = AerialAsset(id: "B", nameKey: "K", fallbackName: "B", categoryIDs: [], subcategoryIDs: [],
                                  preferredOrder: 0, includeInShuffle: true, remoteURL: URL(string: address), isDynamic: false)
            await #expect(throws: DownloadError.untrustedURL(address)) {
                try await AerialDownloader().download(bad, paths: box.paths) { _, _ in }
            }
        }
    }

    @Test func refusesAssetsWithoutAnAddress() async throws {
        let box = try Sandbox()
        let noURL = AerialAsset(id: "X", nameKey: "K", fallbackName: "X", categoryIDs: [], subcategoryIDs: [],
                                preferredOrder: 0, includeInShuffle: true, remoteURL: nil, isDynamic: false)
        await #expect(throws: DownloadError.noRemoteURL) {
            try await AerialDownloader().download(noURL, paths: box.paths) { _, _ in }
        }
    }
}

extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }
}

@Suite struct RobustnessTests {
    @Test func corruptStateFileIsKeptAsideNotOverwritten() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.appSupport, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: box.paths.stateFile)
        let loaded = StateStore(paths: box.paths).load()
        #expect(loaded.state == RotationState())
        let aside = try #require(loaded.corruptCopy)
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
    }

    @Test func stateFromAnotherVersionKeepsPlaylists() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.appSupport, withIntermediateDirectories: true)
        let json = """
        {"interval":"week","playlists":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Ocean","assetIDs":["A"]}],"someFutureKey":true}
        """
        try Data(json.utf8).write(to: box.paths.stateFile)
        let loaded = StateStore(paths: box.paths).load()
        #expect(loaded.corruptCopy == nil)
        #expect(loaded.state.interval == .week)
        #expect(loaded.state.playlists.first?.name == "Ocean")
        #expect(loaded.state.mode == .allDownloaded)
    }

    @Test func identicalBackupsAreNotRepeated() throws {
        let box = try Sandbox()
        let backups = BackupStore(paths: box.paths, keep: 20)
        for index in 0..<5 {
            try backups.backUp(Data("same".utf8), now: Date(timeIntervalSince1970: Double(1_800_000_000 + index)))
        }
        #expect(backups.rolling().count == 1)
    }

    @Test func backupsKeepTheOriginalAndPruneOldCopies() throws {
        let box = try Sandbox()
        let backups = BackupStore(paths: box.paths, keep: 3)
        let first = Data("first".utf8)
        for index in 0..<6 {
            try backups.backUp(index == 0 ? first : Data("copy \(index)".utf8), now: Date(timeIntervalSince1970: Double(1_800_000_000 + index)))
        }
        #expect(try backups.original() == first)
        #expect(backups.rolling().count == 3)
    }

    @Test func catalogWithoutTranslationsStillLoads() throws {
        let box = try Sandbox()
        try FileManager.default.removeItem(at: box.paths.localizedStrings)
        let catalog = try box.catalog()
        let tahoe = try #require(catalog.asset(Sandbox.tahoeDay))
        #expect(catalog.name(of: tahoe, language: "ru") == "Tahoe Day")
    }

    @Test func missingCatalogIsReportedClearly() throws {
        let box = try Sandbox()
        try FileManager.default.removeItem(at: box.paths.manifest)
        #expect(throws: CatalogError.missingManifest(box.paths.manifest.path)) { try box.catalog() }
    }

    @Test func emptyPlaylistGivesAnEmptyPool() throws {
        let box = try Sandbox()
        let playlist = Playlist(name: "Empty")
        let pool = RotationPool.candidates(mode: .playlist(playlist.id), playlists: [playlist], catalog: try box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        #expect(pool.isEmpty)
        var bag = ["stale"]
        #expect(ShuffleBag.next(pool: pool, bag: &bag, current: nil) == nil)
        #expect(bag.isEmpty)
    }

    @Test func deletedPlaylistFallsBackToNothing() throws {
        let box = try Sandbox()
        let pool = RotationPool.candidates(mode: .playlist(UUID()), playlists: [], catalog: try box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        #expect(pool.isEmpty)
    }
}
