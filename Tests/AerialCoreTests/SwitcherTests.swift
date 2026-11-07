import Foundation
import Testing
@testable import AerialCore

/// A fake home folder with Apple's aerial layout: catalog, names, store and a few "videos".
struct Sandbox {
    let paths: AerialPaths
    static let tahoeDay = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    static let goldenGateNight = "86E89C23-C39B-44C8-A985-E56EEA6456FE"
    static let notDownloaded = "CF6347E2-4F81-4410-8892-4830991B6C5A"
    static let dynamic = "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19"

    init() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "aerial-tests-\(UUID().uuidString)")
        paths = AerialPaths(home: home)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.localizedStrings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.storeIndex.deletingLastPathComponent(), withIntermediateDirectories: true)

        func asset(_ id: String, _ key: String, _ label: String, category: String = "landscape", variant: Bool = false) -> [String: Any] {
            var a: [String: Any] = [
                "id": id, "localizedNameKey": key, "accessibilityLabel": label, "categories": [category],
                "subcategories": [], "preferredOrder": 0, "includeInShuffle": true,
                "url-4K-SDR-240FPS": "https://example.com/\(id).mov",
            ]
            if variant { a["variant"] = ["appearance": "light"] }
            return a
        }
        let manifest: [String: Any] = [
            "assets": [
                asset(Self.tahoeDay, "TAHOE_DAY", "Tahoe Day"),
                asset(Self.goldenGateNight, "GG_NIGHT", "Golden Gate Night"),
                asset(Self.notDownloaded, "TAHOE_NIGHT", "Tahoe Night"),
                asset(Self.dynamic, "DYNAMIC", "macOS", category: "dynamic-aerials", variant: true),
            ],
            "categories": [
                ["id": "landscape", "localizedNameKey": "CAT_LANDSCAPE", "preferredOrder": 1],
                ["id": "dynamic-aerials", "localizedNameKey": "CAT_DYNAMIC", "preferredOrder": 0],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: paths.manifest)
        let strings: [String: Any] = [
            "en": ["TAHOE_DAY": "Tahoe Day", "CAT_LANDSCAPE": "Landscape"],
            "ru": ["TAHOE_DAY": "Тахо днем", "CAT_LANDSCAPE": "Природа"],
        ]
        try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0).write(to: paths.localizedStrings)
        try fixtureStore().write(to: paths.storeIndex)
        try makeVideo(Self.tahoeDay)
        try makeVideo(Self.goldenGateNight)
    }

    func makeVideo(_ id: String, size: UInt64 = 2_000_000, source: String? = nil) throws {
        let url = paths.videoFile(for: id)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        ExtendedAttributes.set(source ?? "https://example.com/\(id).mov", named: "SourceURL", at: url)
    }

    func catalog() throws -> Catalog { try Catalog.load(paths: paths) }
}

/// Simulates `WallpaperAgent` reacting to a restart.
final class FakeAgent: WallpaperAgentControlling, @unchecked Sendable {
    enum Behaviour { case keeps, resetsToDefault, resetsToBuiltInAerial, writesOldValueBackOnce, alwaysWritesOldValueBack, fails }
    let behaviour: Behaviour
    let store: URL
    let oldData: Data
    private(set) var restarts = 0

    init(_ behaviour: Behaviour, store: URL) throws {
        self.behaviour = behaviour
        self.store = store
        self.oldData = try Data(contentsOf: store)
    }

    func restart() throws {
        restarts += 1
        switch behaviour {
        case .keeps:
            break
        case .resetsToDefault:
            let defaults: [String: Any] = ["AllSpacesAndDisplays": [
                "Type": "linked",
                "Linked": ["Content": ["Choices": [["Provider": "default", "Configuration": Data(), "Files": [Any]()]]]],
            ]]
            if restarts == 1 {
                try PropertyListSerialization.data(fromPropertyList: defaults, format: .binary, options: 0).write(to: store)
            }
        case .resetsToBuiltInAerial:
            // What macOS really writes when it cannot decode the store: the built-in Golden Gate aerial.
            if restarts == 1 {
                let configuration = try PropertyListSerialization.data(
                    fromPropertyList: ["assetID": "4207734D-74FE-4F92-B5E1-6EC8DEE24A15"], format: .binary, options: 0)
                let reset: [String: Any] = ["AllSpacesAndDisplays": [
                    "Type": "linked",
                    "Linked": ["Content": ["Choices": [["Provider": WallpaperStore.aerialsProvider, "Configuration": configuration, "Files": [Any]()]]]],
                ]]
                try PropertyListSerialization.data(fromPropertyList: reset, format: .binary, options: 0).write(to: store)
            }
        case .writesOldValueBackOnce:
            if restarts == 1 { try oldData.write(to: store) }
        case .alwaysWritesOldValueBack:
            if restarts <= 2 { try oldData.write(to: store) }
        case .fails:
            throw AgentError.notRestarted(1)
        }
    }
}

@Suite struct SwitcherTests {
    @Test func setsADownloadedVideo() async throws {
        let box = try Sandbox()
        let agent = try FakeAgent(.keeps, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        let result = try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        #expect(result == SwitchResult(assetID: Sandbox.goldenGateNight, attempts: 1))
        #expect(try WallpaperStore(url: box.paths.storeIndex).snapshot().assetID == Sandbox.goldenGateNight)
        // The original store is kept for "Restore Original Wallpaper".
        #expect(try WallpaperStore.inspect(BackupStore(paths: box.paths).original()).assetID == Sandbox.tahoeDay)
    }

    @Test func neverSetsAVideoThatIsNotOnDisk() async throws {
        let box = try Sandbox()
        let agent = try FakeAgent(.keeps, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        await #expect(throws: SwitchError.unsafe(Sandbox.notDownloaded, .notDownloaded)) {
            try await switcher.apply(assetID: Sandbox.notDownloaded, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        }
        #expect(agent.restarts == 0)
        #expect(try WallpaperStore(url: box.paths.storeIndex).snapshot().assetID == Sandbox.tahoeDay)
    }

    @Test func putsTheBackupBackWhenMacOSResetsTheStore() async throws {
        let box = try Sandbox()
        let agent = try FakeAgent(.resetsToDefault, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        await #expect(throws: SwitchError.storeWasReset) {
            try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        }
        #expect(try WallpaperStore(url: box.paths.storeIndex).snapshot().assetID == Sandbox.tahoeDay)
    }

    @Test func treatsAResetToTheBuiltInAerialAsAReset() async throws {
        let box = try Sandbox()
        let original = try Data(contentsOf: box.paths.storeIndex)
        let agent = try FakeAgent(.resetsToBuiltInAerial, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        await #expect(throws: SwitchError.storeWasReset) {
            try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        }
        #expect(try Data(contentsOf: box.paths.storeIndex) == original)
    }

    @Test func givesUpAfterTwoAttemptsAndPutsTheOriginalBack() async throws {
        let box = try Sandbox()
        let original = try Data(contentsOf: box.paths.storeIndex)
        let agent = try FakeAgent(.alwaysWritesOldValueBack, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        await #expect(throws: SwitchError.notApplied(Sandbox.goldenGateNight)) {
            try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        }
        #expect(try Data(contentsOf: box.paths.storeIndex) == original)
    }

    @Test func aFailedRestartLeavesTheStoreAsItWas() async throws {
        let box = try Sandbox()
        let original = try Data(contentsOf: box.paths.storeIndex)
        let agent = try FakeAgent(.fails, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        await #expect(throws: SwitchError.agent(.notRestarted(1))) {
            try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        }
        #expect(try Data(contentsOf: box.paths.storeIndex) == original)
    }

    @Test func retriesWhenTheAgentWritesTheOldValueBack() async throws {
        let box = try Sandbox()
        let agent = try FakeAgent(.writesOldValueBackOnce, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        let result = try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        #expect(result.attempts == 2)
        #expect(try WallpaperStore(url: box.paths.storeIndex).snapshot().assetID == Sandbox.goldenGateNight)
    }

    @Test func restoreKeepsACopyOfTheCurrentStore() async throws {
        let box = try Sandbox()
        let agent = try FakeAgent(.keeps, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        _ = try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        let changed = try Data(contentsOf: box.paths.storeIndex)
        try await switcher.restoreOriginal()
        let copies = BackupStore(paths: box.paths).rolling().compactMap { try? Data(contentsOf: $0) }
        #expect(copies.contains(changed))
    }

    @Test func restoresTheOriginalStoreByteForByte() async throws {
        let box = try Sandbox()
        let original = try Data(contentsOf: box.paths.storeIndex)
        let agent = try FakeAgent(.keeps, store: box.paths.storeIndex)
        let switcher = Switcher(paths: box.paths, agent: agent, settleDelay: .zero)
        _ = try await switcher.apply(assetID: Sandbox.goldenGateNight, catalog: box.catalog(), local: LocalLibrary.scan(paths: box.paths))
        try await switcher.restoreOriginal()
        #expect(try Data(contentsOf: box.paths.storeIndex) == original)
    }
}

@Suite struct CatalogAndSafetyTests {
    @Test func loadsNamesAndSkipsDynamicWallpapers() throws {
        let box = try Sandbox()
        let catalog = try box.catalog()
        #expect(catalog.assets.count == 4)
        #expect(catalog.videoAssets.count == 3)
        let tahoe = try #require(catalog.asset(Sandbox.tahoeDay))
        #expect(catalog.name(of: tahoe, language: "ru") == "Тахо днем")
        #expect(catalog.name(of: tahoe, language: "de") == "Tahoe Day")
        let night = try #require(catalog.asset(Sandbox.goldenGateNight))
        #expect(catalog.name(of: night, language: "ru") == "Golden Gate Night") // no translation → catalog label
        #expect(catalog.videoCategories.map(\.id) == ["landscape"])
    }

    @Test func safetyVerdicts() throws {
        let box = try Sandbox()
        try box.makeVideo(Sandbox.notDownloaded, size: 1_000)
        try box.makeVideo(Sandbox.dynamic)
        let catalog = try box.catalog()
        var local = LocalLibrary.scan(paths: box.paths)
        #expect(SafetyCheck.verdict(assetID: Sandbox.tahoeDay, catalog: catalog, local: local) == .safe)
        #expect(SafetyCheck.verdict(assetID: Sandbox.notDownloaded, catalog: catalog, local: local) == .incompleteFile)
        #expect(SafetyCheck.verdict(assetID: Sandbox.dynamic, catalog: catalog, local: local) == .dynamicWallpaper)
        #expect(SafetyCheck.verdict(assetID: "UNKNOWN", catalog: catalog, local: local) == .notInCatalog)
        try box.makeVideo(Sandbox.goldenGateNight, source: "https://example.com/old-address.mov")
        local = LocalLibrary.scan(paths: box.paths)
        #expect(SafetyCheck.verdict(assetID: Sandbox.goldenGateNight, catalog: catalog, local: local) == .outdatedFile)
    }
}
