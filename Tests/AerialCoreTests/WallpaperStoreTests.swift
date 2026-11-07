import Foundation
import Testing
@testable import AerialCore

/// A real `Index.plist` from macOS 27.2: one aerial ("Tahoe Day"), linked to the screen saver.
func fixtureStore() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Index-linked-aerial", withExtension: "plist", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func plist(_ data: Data) throws -> [String: Any] {
    try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Suite struct WallpaperStoreTests {
    let tahoeDay = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    let goldenGateNight = "86E89C23-C39B-44C8-A985-E56EEA6456FE"

    @Test func readsTheCurrentAerial() throws {
        let snapshot = try WallpaperStore.inspect(fixtureStore())
        #expect(snapshot.provider == WallpaperStore.aerialsProvider)
        #expect(snapshot.assetID == tahoeDay)
        #expect(snapshot.layoutType == "linked")
        #expect(!snapshot.hasPerDisplayOverrides)
        #expect(!snapshot.isShuffle)
    }

    @Test func changesOnlyTheChosenVideo() throws {
        let original = try fixtureStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let edited = try WallpaperStore.settingAerial(goldenGateNight, in: original, now: now)

        #expect(try WallpaperStore.inspect(edited).assetID == goldenGateNight)

        let before = try plist(original), after = try plist(edited)
        // Other sections are untouched.
        #expect(NSDictionary(dictionary: before["SystemDefault"] as! [String: Any])
            .isEqual(to: after["SystemDefault"] as! [String: Any]))
        #expect(NSDictionary(dictionary: before["Displays"] as! [String: Any]).isEqual(to: after["Displays"] as! [String: Any]))

        let b = (before["AllSpacesAndDisplays"] as! [String: Any])["Linked"] as! [String: Any]
        let a = (after["AllSpacesAndDisplays"] as! [String: Any])["Linked"] as! [String: Any]
        let bc = b["Content"] as! [String: Any], ac = a["Content"] as! [String: Any]
        // Shuffle frequency and the shuffle marker are kept.
        #expect(bc["EncodedOptionValues"] as? Data == ac["EncodedOptionValues"] as? Data)
        #expect(ac["Shuffle"] as? String == "$null")
        #expect(a["LastSet"] as? Date == now)
        #expect((after["AllSpacesAndDisplays"] as! [String: Any])["Type"] as? String == "linked")
    }

    @Test func refusesShuffleAndEmptyIDs() throws {
        let original = try fixtureStore()
        #expect(throws: StoreError.self) { try WallpaperStore.settingAerial("shuffle-all-aerials", in: original) }
        #expect(throws: StoreError.self) { try WallpaperStore.settingAerial("", in: original) }
    }

    @Test func replacesOptionsOfAnotherProvider() throws {
        var root = try plist(fixtureStore())
        var shared = root["AllSpacesAndDisplays"] as! [String: Any]
        var linked = shared["Linked"] as! [String: Any]
        var content = linked["Content"] as! [String: Any]
        content["Choices"] = [["Provider": "com.apple.wallpaper.choice.image", "Files": [Any]()]]
        content["EncodedOptionValues"] = Data([1, 2, 3])
        linked["Content"] = content; shared["Linked"] = linked; root["AllSpacesAndDisplays"] = shared
        let imageStore = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)

        let edited = try WallpaperStore.settingAerial(goldenGateNight, in: imageStore)
        let editedContent = (((try plist(edited))["AllSpacesAndDisplays"] as! [String: Any])["Linked"] as! [String: Any])["Content"] as! [String: Any]
        #expect(editedContent["EncodedOptionValues"] as? Data == (try WallpaperStore.defaultAerialOptions()))
        #expect(try WallpaperStore.inspect(edited).assetID == goldenGateNight)
    }

    @Test func rejectsAStoreWithoutTheSharedSection() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Displays": [String: Any]()], format: .binary, options: 0)
        #expect(throws: StoreError.self) { try WallpaperStore.settingAerial(goldenGateNight, in: data) }
    }
}

@Suite struct SeparateScreenSaverTests {
    /// When "Show as screen saver" is off, the store keeps separate Desktop and Idle entries.
    func individualStore() throws -> Data {
        var root = try plist(fixtureStore())
        var shared = root["AllSpacesAndDisplays"] as! [String: Any]
        let linked = shared.removeValue(forKey: "Linked")!
        shared["Type"] = "individual"
        shared["Desktop"] = linked
        var idle = linked as! [String: Any]
        var content = idle["Content"] as! [String: Any]
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": "IDLE-ASSET"], format: .binary, options: 0)
        content["Choices"] = [["Provider": WallpaperStore.aerialsProvider, "Configuration": configuration, "Files": [Any]()]]
        idle["Content"] = content
        shared["Idle"] = idle
        root["AllSpacesAndDisplays"] = shared
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    @Test func changesOnlyTheDesktopAndLeavesTheScreenSaver() throws {
        let edited = try WallpaperStore.settingAerial("86E89C23-C39B-44C8-A985-E56EEA6456FE", in: individualStore())
        #expect(try WallpaperStore.inspect(edited).assetID == "86E89C23-C39B-44C8-A985-E56EEA6456FE")
        let shared = (try plist(edited))["AllSpacesAndDisplays"] as! [String: Any]
        let idleContent = (shared["Idle"] as! [String: Any])["Content"] as! [String: Any]
        let idleConfiguration = ((idleContent["Choices"] as! [[String: Any]]).first!["Configuration"] as! Data)
        let idleAsset = (try PropertyListSerialization.propertyList(from: idleConfiguration, format: nil) as! [String: Any])["assetID"] as? String
        #expect(idleAsset == "IDLE-ASSET")
        #expect(shared["Type"] as? String == "individual")
    }
}

@Suite struct ReferencedVideosTests {
    @Test func findsVideosUsedByTheScreenSaverToo() throws {
        let store = try SeparateScreenSaverTests().individualStore()
        let ids = WallpaperStore.referencedAssetIDs(store)
        #expect(ids.contains("IDLE-ASSET"))
        #expect(ids.contains("4C108785-A7BA-422E-9C79-B0129F1D5550"))
    }
}

@Suite struct RotationPolicyTests {
    func snapshot(provider: String? = WallpaperStore.aerialsProvider, asset: String?) -> StoreSnapshot {
        StoreSnapshot(provider: provider, assetID: asset, layoutType: "linked", hasPerDisplayOverrides: false)
    }

    @Test func appleShuffleIsAlwaysReported() {
        #expect(RotationPolicy.observe(snapshot(asset: "shuffle-all-aerials"), lastAssetID: nil, paused: false) == .appleShuffle)
        #expect(RotationPolicy.observe(snapshot(asset: "shuffle-all-aerials"), lastAssetID: "A", paused: true) == .appleShuffle)
    }

    @Test func outsideChangesPauseOnlyAfterTheAppSetSomething() {
        #expect(RotationPolicy.observe(snapshot(asset: "B"), lastAssetID: nil, paused: false) == .fine)
        #expect(RotationPolicy.observe(snapshot(asset: "B"), lastAssetID: "A", paused: false) == .changedOutside)
        #expect(RotationPolicy.observe(snapshot(provider: "com.apple.wallpaper.choice.image", asset: nil), lastAssetID: "A", paused: false) == .changedOutside)
        #expect(RotationPolicy.observe(snapshot(asset: "A"), lastAssetID: "A", paused: false) == .fine)
        #expect(RotationPolicy.observe(snapshot(asset: "B"), lastAssetID: "A", paused: true) == .fine)
    }

    @Test func firstLaunchReplacesAppleShuffleOnlyWithSomethingToShow() {
        #expect(RotationPolicy.replacesAppleShuffleAtLaunch(isFirstLaunch: true, observation: .appleShuffle, poolCount: 3))
        #expect(!RotationPolicy.replacesAppleShuffleAtLaunch(isFirstLaunch: true, observation: .appleShuffle, poolCount: 0))
        #expect(!RotationPolicy.replacesAppleShuffleAtLaunch(isFirstLaunch: false, observation: .appleShuffle, poolCount: 3))
    }

    @Test func nextIsPossibleOnlyWithAnotherVideo() {
        #expect(!RotationPolicy.canAdvance(pool: [], current: nil))
        #expect(!RotationPolicy.canAdvance(pool: ["A"], current: "A"))
        #expect(RotationPolicy.canAdvance(pool: ["A"], current: "B"))
        #expect(RotationPolicy.canAdvance(pool: ["A", "B"], current: "A"))
    }
}
