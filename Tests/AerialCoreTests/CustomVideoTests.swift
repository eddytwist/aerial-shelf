import AVFoundation
import Foundation
import Testing
@testable import AerialCore

/// In-memory preferences instead of the real `com.apple.wallpaper.aerial` domain.
final class FakePreferences: PreferencesAccessing, @unchecked Sendable {
    var values: [String: Any] = [:]
    func value(_ key: String, domain: String) -> Any? { values["\(domain)/\(key)"] }
    func set(_ value: Any?, _ key: String, domain: String) { values["\(domain)/\(key)"] = value }
}

@Suite struct CustomCatalogTests {
    let video = CustomVideo(id: "11111111-2222-3333-4444-555555555555", name: "Iceland Trip")
    let set = CustomSet(name: "Summer")

    @Test func mergeAddsOneCategoryAndKeepsApplesEntries() throws {
        let box = try Sandbox()
        let apple = try Data(contentsOf: box.paths.manifest)
        let inSet = CustomVideo(id: "66666666-7777-8888-9999-000000000000", name: "Beach", setID: set.id)
        let library = CustomLibrary(videos: [video, inSet], sets: [set])
        let merged = try CustomCatalog.merge(appleCatalog: apple, library: library, categoryName: "My Videos", looseSetName: "My Videos")
        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let assets = try #require(root["assets"] as? [[String: Any]])
        let categories = try #require(root["categories"] as? [[String: Any]])
        let appleRoot = try #require(JSONSerialization.jsonObject(with: apple) as? [String: Any])
        #expect(assets.count == (appleRoot["assets"] as? [Any])!.count + 2)
        #expect(categories.count == (appleRoot["categories"] as? [Any])!.count + 1)

        let category = try #require(categories.first { $0["id"] as? String == CustomLibrary.categoryID })
        #expect(category["localizedNameKey"] as? String == "My Videos")
        let subcategories = try #require(category["subcategories"] as? [[String: Any]])
        #expect(subcategories.map { $0["id"] as? String } == [CustomLibrary.looseSubcategoryID, set.id.uuidString])

        let entry = try #require(assets.first { $0["id"] as? String == video.id })
        #expect(entry["localizedNameKey"] as? String == "Iceland Trip")
        #expect(entry["subcategories"] as? [String] == [CustomLibrary.looseSubcategoryID])
        #expect(entry["includeInShuffle"] as? Bool == false)
        #expect(entry["url-4K-SDR-240FPS"] as? String == CustomLibrary.sourceURL(for: video.id).absoluteString)
        #expect(CustomLibrary.sourceURL(for: video.id).host() == "aerial-shelf.invalid")
    }

    @Test func noVideosMeansApplesCatalogUnchanged() throws {
        let box = try Sandbox()
        let apple = try Data(contentsOf: box.paths.manifest)
        let merged = try CustomCatalog.merge(appleCatalog: apple, library: CustomLibrary(), categoryName: "x", looseSetName: "x")
        #expect(merged == apple)
    }

    @Test func emptySetsGetNoSubcategory() throws {
        let box = try Sandbox()
        let apple = try Data(contentsOf: box.paths.manifest)
        let merged = try CustomCatalog.merge(
            appleCatalog: apple, library: CustomLibrary(videos: [video], sets: [set]), categoryName: "x", looseSetName: "x"
        )
        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let category = try #require((root["categories"] as? [[String: Any]])?.first { $0["id"] as? String == CustomLibrary.categoryID })
        #expect((category["subcategories"] as? [Any])?.count == 1)
    }

    @Test func libraryFileSurvivesADamagedEntry() throws {
        let box = try Sandbox()
        let json = #"{"videos":[{"id":"11111111-2222-3333-4444-555555555555","name":"Ok"},{"name":"no id"},7],"sets":[]}"#
        try FileManager.default.createDirectory(at: box.paths.appSupport, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: box.paths.customLibraryFile)
        let library = CustomLibraryStore(paths: box.paths).load().library
        #expect(library.videos.map(\.name) == ["Ok"])
    }

    @Test func customVideosAreUsableOnlyWhileOn() throws {
        let box = try Sandbox()
        try box.makeVideo(video.id, size: 200_000, source: CustomLibrary.sourceURL(for: video.id).absoluteString)
        let local = LocalLibrary.scan(paths: box.paths)
        let library = CustomLibrary(videos: [video])
        let off = try box.catalog().adding(library, enabled: false)
        let on = try box.catalog().adding(library, enabled: true)
        #expect(SafetyCheck.verdict(assetID: video.id, catalog: off, local: local) == .customVideosOff)
        // Under 1 MB is fine for the user's own videos: the app writes them in one step.
        #expect(SafetyCheck.verdict(assetID: video.id, catalog: on, local: local) == .safe)
        #expect(RotationPool.candidates(mode: .allDownloaded, playlists: [], catalog: off, local: local).contains(video.id) == false)
        #expect(RotationPool.candidates(mode: .allDownloaded, playlists: [], catalog: on, local: local).contains(video.id))
        #expect(on.customAssets.map(\.fallbackName) == ["Iceland Trip"])
        #expect(on.name(of: on.asset(video.id)!, language: "ru") == "Iceland Trip")
    }

    @Test func overrideWritesAndRemovesOnlyItsOwnKeys() throws {
        let box = try Sandbox()
        let preferences = FakePreferences()
        let override = CatalogOverride(paths: box.paths, preferences: preferences)
        #expect(!override.isActive)
        #expect(try override.writeCatalog(library: CustomLibrary(videos: [video]), categoryName: "My Videos", looseSetName: "My Videos"))
        #expect(try !override.writeCatalog(library: CustomLibrary(videos: [video]), categoryName: "My Videos", looseSetName: "My Videos"),
                "same content: no rewrite, no reload")
        override.activate()
        #expect(override.isActive)
        #expect(try Catalog.loadWithCustom(paths: box.paths, customVideosEnabled: true, preferences: preferences).customEnabled)
        #expect(try !Catalog.loadWithCustom(paths: box.paths, customVideosEnabled: false, preferences: preferences).customEnabled,
                "the user's switch wins even when the keys are set")
        override.deactivate()
        #expect(!override.isActive)
        #expect(preferences.value(CatalogOverride.pathKey, domain: CatalogOverride.domain) == nil)

        preferences.set("/somewhere/else.json", CatalogOverride.pathKey, domain: CatalogOverride.domain)
        #expect(override.isUsedByOthers)
        override.deactivate()
        #expect(preferences.value(CatalogOverride.pathKey, domain: CatalogOverride.domain) as? String == "/somewhere/else.json")
    }

    @Test func categoryNamesFollowTheSystemLanguage() {
        #expect(CustomCategoryNames.names(systemLanguage: "ru-RU").category == "Мои видео")
        #expect(CustomCategoryNames.names(systemLanguage: "en-US").category == "My Videos")
        #expect(CustomCategoryNames.names(systemLanguage: nil).category == "My Videos")
    }
}

@Suite struct CustomLifecycleTests {
    let id = "11111111-2222-3333-4444-555555555555"

    @Test func turningOffWaitsWhileAnOwnVideoIsInUse() {
        #expect(CustomPolicy.canTurnOff(referenced: ["apple"], customIDs: [id]))
        #expect(!CustomPolicy.canTurnOff(referenced: ["apple", id], customIDs: [id]), "e.g. a separate screen saver")
        #expect(!CustomPolicy.canTurnOff(referenced: nil, customIDs: [id]), "settings unreadable: don't risk it")
        #expect(CustomPolicy.inUse(referenced: [id, "apple"], customIDs: [id]) == [id])
    }

    @Test func retriesWaitAnHourAfterAFailure() {
        let now = Date()
        #expect(CustomPolicy.shouldRetry(lastFailure: nil, now: now))
        #expect(!CustomPolicy.shouldRetry(lastFailure: now.addingTimeInterval(-60), now: now))
        #expect(CustomPolicy.shouldRetry(lastFailure: now.addingTimeInterval(-3601), now: now))
    }

    @Test func aFilePutBackFromTheTrashReturnsWithItsName() throws {
        let box = try Sandbox()
        let set = CustomSet(name: "Trip")
        var library = CustomLibrary(videos: [CustomVideo(id: id, name: "Glacier", setID: set.id)], sets: [set])
        library.remove(id)
        #expect(library.videos.isEmpty)
        #expect(library.sets.isEmpty, "a set without videos goes too")
        #expect(library.trashed.map(\.name) == ["Glacier"])

        try box.makeVideo(id, size: 300_000, source: CustomLibrary.sourceURL(for: id).absoluteString)
        let adopted = library.adoptReturnedFiles(LocalLibrary.scan(paths: box.paths), defaultName: "Restored Video")
        #expect(adopted == [id])
        #expect(library.video(id)?.name == "Glacier")
        #expect(library.video(id)?.setID == nil, "its set is gone, so it comes back without one")
        #expect(library.trashed.isEmpty)
    }

    @Test func unknownFilesOfTheAppAreAdoptedButApplesAreNot() throws {
        let box = try Sandbox()
        try box.makeVideo(id, size: 300_000, source: CustomLibrary.sourceURL(for: id).absoluteString)
        var library = CustomLibrary()
        let adopted = library.adoptReturnedFiles(LocalLibrary.scan(paths: box.paths), defaultName: "Restored Video")
        #expect(adopted == [id], "Apple's downloaded videos in the sandbox have Apple addresses and stay out")
        #expect(library.video(id)?.name == "Restored Video")
    }

    @Test func anUnreadableListIsKeptAside() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.appSupport, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: box.paths.customLibraryFile)
        let store = CustomLibraryStore(paths: box.paths)
        #expect(store.read().isEmpty)
        #expect(FileManager.default.fileExists(atPath: box.paths.customLibraryFile.path), "reading changes nothing")
        let loaded = store.load()
        let aside = try #require(loaded.corruptCopy)
        #expect(aside.lastPathComponent.hasPrefix("custom.corrupt-"))
        #expect(!FileManager.default.fileExists(atPath: box.paths.customLibraryFile.path))
    }

    @Test func theCatalogIsRewrittenWhenNamesChange() throws {
        let box = try Sandbox()
        let override = CatalogOverride(paths: box.paths, preferences: FakePreferences())
        var library = CustomLibrary(videos: [CustomVideo(id: id, name: "Glacier")])
        try override.writeCatalog(library: library, categoryName: "My Videos", looseSetName: "My Videos")
        #expect(!override.catalogIsOutdated(library: library, categoryName: "My Videos", looseSetName: "My Videos"))
        #expect(override.catalogIsOutdated(library: library, categoryName: "Мои видео", looseSetName: "Мои видео"), "system language changed")
        library.videos[0].name = "Glacier Lagoon"
        #expect(override.catalogIsOutdated(library: library, categoryName: "My Videos", looseSetName: "My Videos"), "renamed")
    }

    @Test func oneEntryPerID() throws {
        var library = CustomLibrary()
        library.add(CustomVideo(id: id, name: "A"))
        library.add(CustomVideo(id: id, name: "B"))
        #expect(library.videos.map(\.name) == ["B"])
        let json = #"{"videos":[{"id":"\#(id)","name":"First"},{"id":"\#(id)","name":"Again"}]}"#
        let decoded = try JSONDecoder.iso.decode(CustomLibrary.self, from: Data(json.utf8))
        #expect(decoded.videos.map(\.name) == ["First"])
    }

    @Test func ownFilesAreRecognisedWithoutTheList() throws {
        let box = try Sandbox()
        try box.makeVideo(id, size: 300_000, source: CustomLibrary.sourceURL(for: id).absoluteString)
        #expect(CustomLibrary.filesOnDisk(LocalLibrary.scan(paths: box.paths)) == [id])
    }

    @Test func playlistsRememberTheirSet() throws {
        let set = UUID()
        let data = try JSONEncoder().encode([Playlist(name: "Trip", assetIDs: [id], customSetID: set)])
        #expect(try JSONDecoder().decode([Playlist].self, from: data).first?.customSetID == set)
        let old = #"[{"id":"\#(UUID().uuidString)","name":"Old","assetIDs":[]}]"#
        #expect(try JSONDecoder().decode([Playlist].self, from: Data(old.utf8)).first?.customSetID == nil)
    }
}

@Suite struct VideoImporterTests {
    @Test func convertsH264ToHEVCWithAttributeAndPreview() async throws {
        let box = try Sandbox()
        let source = FileManager.default.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).mp4")
        try await TestVideo.write(to: source, codec: .h264, fileType: .mp4)
        let video = try await VideoImporter(paths: box.paths).importVideo(from: source)
        #expect(video.name == source.deletingPathExtension().lastPathComponent)
        let file = box.paths.videoFile(for: video.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(ExtendedAttributes.string(named: "SourceURL", at: file) == CustomLibrary.sourceURL(for: video.id).absoluteString)
        #expect(FileManager.default.fileExists(atPath: box.paths.thumbnailFile(for: video.id).path))
        let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(!FileManager.default.fileExists(atPath: box.paths.appSupport.appending(path: "Import/\(video.id).mov").path))
    }

    @Test func refusesFilesWithoutVideo() async throws {
        let box = try Sandbox()
        let text = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString).mov")
        try Data("not a video".utf8).write(to: text)
        await #expect(throws: ImportError.self) { _ = try await VideoImporter(paths: box.paths).importVideo(from: text) }
    }

    @Test func findsVideosInAFolderOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
        for name in ["b.mov", "a.MP4", "c.m4v", "notes.txt", "nested/d.mov"] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data())
        }
        #expect(VideoImporter.videos(inFolder: folder).map(\.lastPathComponent) == ["a.MP4", "b.mov", "c.m4v"])
    }
}

/// Writes a tiny real video with AVAssetWriter, so the importer is tested on actual media.
enum TestVideo {
    static func write(to url: URL, codec: AVVideoCodecType, fileType: AVFileType, frames: Int = 12) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ImportError.exportFailed("test video") }
    }
}
