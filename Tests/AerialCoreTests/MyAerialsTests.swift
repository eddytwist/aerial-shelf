import Foundation
import Testing
@testable import AerialCore

/// A catalog of Apple-hosted videos plus one of the user's own, for the My Aerials model.
private func myAerialsCatalog() -> Catalog {
    func asset(_ id: String, category: String = "landscape", custom: Bool = false) -> AerialAsset {
        var asset = AerialAsset(
            id: id, nameKey: id, fallbackName: id, categoryIDs: [category], subcategoryIDs: [], preferredOrder: 0,
            includeInShuffle: true, remoteURL: URL(string: "https://sylvan.apple.com/Videos/\(id).mov"), isDynamic: false
        )
        asset.isCustom = custom
        return asset
    }
    return Catalog(
        assets: [asset("a"), asset("b"), asset("c", category: "cities"), asset("d", category: "cities"), asset("own", custom: true)],
        categories: [], strings: [:], customEnabled: true
    )
}

private func onDisk(_ ids: String...) -> [String: LocalVideo] {
    Dictionary(uniqueKeysWithValues: ids.map { id in
        (id, LocalVideo(assetID: id, url: URL(fileURLWithPath: "/tmp/\(id).mov"), size: 50_000_000,
                        sourceURL: id == "own" ? nil : "https://sylvan.apple.com/Videos/\(id).mov", modified: Date()))
    })
}

@Suite struct StorageMigrationTests {
    @Test func aNewInstallStartsWithMyAerialsDeletionOnAndThreeKept() {
        var state = RotationState()
        StorageMigration.migrate(&state, isNewInstall: true, onDisk: ["b", "a"], current: "a")
        #expect(state.myAerials?.assetIDs == ["a", "b"])
        #expect(state.playlists.first?.isMyAerials == true)
        #expect(state.mode == RotationState.myAerialsMode)
        #expect(state.deleteShown)
        #expect(state.keepLast == 3)
        #expect(state.shownLog == ["a"])
        #expect(state.storageVersion == 1)
    }

    @Test func upgradingWithoutStreamingTouchesNothingOnDisk() {
        var state = RotationState()
        state.mode = .allDownloaded
        let mine = Playlist(name: "Winter", assetIDs: ["c"])
        state.playlists = [mine]
        StorageMigration.migrate(&state, isNewInstall: false, onDisk: ["a", "b"], current: "a")
        #expect(!state.deleteShown)
        #expect(state.mode == RotationState.myAerialsMode)
        #expect(state.playlists.map(\.id) == [Playlist.myAerialsID, mine.id])
        #expect(state.myAerials?.assetIDs == ["a", "b"])
    }

    @Test func upgradingWithStreamingKeepsOnlyTheVideoOnScreenAndRotatesEverything() {
        var state = RotationState()
        state.streaming = true
        state.mode = .allDownloaded
        state.streamedIDs = ["a"]
        StorageMigration.migrate(&state, isNewInstall: false, onDisk: ["a"], current: "a")
        #expect(state.deleteShown)
        #expect(state.keepLast == 1)
        #expect(state.mode == .allAerials)
        #expect(state.streamedIDs == ["a"])
    }

    @Test func runsOnceButRestoresMyAerialsIfItWentMissing() {
        var state = RotationState()
        StorageMigration.migrate(&state, isNewInstall: false, onDisk: ["a"], current: nil)
        state.deleteShown = true
        state.keepLast = 5
        state.playlists.removeAll()
        StorageMigration.migrate(&state, isNewInstall: false, onDisk: ["b"], current: nil)
        #expect(state.keepLast == 5)
        #expect(state.deleteShown)
        #expect(state.myAerials?.assetIDs == ["b"])
    }

    @Test func aDeletedPlaylistFallsBackToMyAerials() {
        var state = RotationState()
        StorageMigration.migrate(&state, isNewInstall: true, onDisk: [], current: nil)
        state.mode = .playlist(UUID())
        state.bag = ["x"]
        let changed = state.normalizeSource()
        #expect(changed)
        #expect(state.mode == RotationState.myAerialsMode)
        #expect(state.bag.isEmpty)
    }

    @Test func storageSettingsSurviveASaveAndOddValuesAreReset() throws {
        var state = RotationState()
        state.deleteShown = false
        state.keepLast = 10
        state.pinnedIDs = ["a"]
        state.shownLog = ["b", "a"]
        state.storageVersion = 1
        let decoded = try JSONDecoder.iso.decode(RotationState.self, from: JSONEncoder.iso.encode(state))
        #expect(decoded == state)
        let odd = try JSONDecoder.iso.decode(RotationState.self, from: Data(#"{"keepLast":7}"#.utf8))
        #expect(odd.keepLast == 3)
        #expect(odd.storageVersion == 0)
    }
}

@Suite struct ShownLogTests {
    @Test func theLastShownMoveToTheFrontWithoutRepeats() {
        var state = RotationState()
        for id in ["a", "b", "c", "a"] { state.recordShown(id) }
        #expect(state.shownLog == ["a", "c", "b"])
        state.keepLast = 1
        #expect(state.lastShown() == ["a"])
        state.keepLast = 3
        #expect(state.lastShown() == ["a", "b", "c"])
    }

    @Test func theHistoryIsCapped() {
        var state = RotationState()
        for index in 0..<150 { state.recordShown("v\(index)") }
        #expect(state.shownLog.count == RotationState.shownLogLimit)
        #expect(state.shownLog.first == "v149")
    }
}

@Suite struct EffectivePoolTests {
    let catalog = myAerialsCatalog()

    @Test func myAerialsRotatesItsVideosDownloadedOrNot() {
        let mine = Playlist(id: Playlist.myAerialsID, name: "My Aerials", assetIDs: ["a", "c"])
        let result = RotationPool.effective(mode: RotationState.myAerialsMode, playlists: [mine], catalog: catalog, local: onDisk("a"))
        #expect(result.pool == ["a", "c"])
        #expect(!result.showingAllInstead)
    }

    @Test func anEmptyOrSingleVideoMyAerialsShowsAllAerialsInstead() {
        let mine = Playlist(id: Playlist.myAerialsID, name: "My Aerials", assetIDs: ["a"])
        let result = RotationPool.effective(mode: RotationState.myAerialsMode, playlists: [mine], catalog: catalog, local: onDisk("a"))
        #expect(result.showingAllInstead)
        #expect(result.pool == ["a", "b", "c", "d"])  // "own" isn't on disk, and the user's own videos are never downloaded
    }

    @Test func aCategoryRotatesItsVideos() {
        let result = RotationPool.effective(mode: .category("cities"), playlists: [], catalog: catalog, local: [:])
        #expect(result.pool == ["c", "d"])
    }
}

@Suite struct OfflineFallbackTests {
    let catalog = myAerialsCatalog()

    @Test func showsTheOnDiskVideoShownLongestAgo() {
        let pick = RotationPool.onDiskFallback(
            pool: ["a", "b", "c", "d"], catalog: catalog, local: onDisk("a", "b", "c"), shownLog: ["a", "b", "c"], current: "a"
        )
        #expect(pick == "c")
    }

    @Test func aVideoNeverShownComesFirst() {
        let pick = RotationPool.onDiskFallback(
            pool: ["a", "b", "c"], catalog: catalog, local: onDisk("a", "b", "c"), shownLog: ["a", "b"], current: "a"
        )
        #expect(pick == "c")
    }

    @Test func nothingOnDiskButTheVideoOnScreenKeepsIt() {
        let pick = RotationPool.onDiskFallback(pool: ["a", "b"], catalog: catalog, local: onDisk("a"), shownLog: ["a"], current: "a")
        #expect(pick == nil)
    }
}

@Suite struct ExcessTests {
    let catalog = myAerialsCatalog()

    @Test func turningDeletionOnListsOnlyWhatCanGo() {
        let excess = StreamPolicy.excess(
            onDisk: ["a", "b", "c", "d", "own", "unknown"], catalog: catalog,
            pinned: ["b"], lastShown: ["a"], inUse: ["c"]
        )
        // a: last shown; b: kept on this Mac; c: in use; own: the user's own video; unknown: not in the catalog.
        #expect(excess == ["d"])
    }

    @Test func nothingWhenTheSettingsCantBeRead() {
        #expect(StreamPolicy.excess(onDisk: ["d"], catalog: catalog, pinned: [], lastShown: [], inUse: nil).isEmpty)
    }
}

@Suite struct MigrationEdgeTests {
    @Test func aPlaylistAllAerialsOrSingleVideoSourceIsKept() {
        for mode in [RotationMode.allAerials, .single("a")] {
            var state = RotationState()
            state.mode = mode
            StorageMigration.migrate(&state, isNewInstall: false, onDisk: ["a"], current: "a")
            #expect(state.mode == mode)
        }
        var state = RotationState()
        let winter = Playlist(name: "Winter", assetIDs: ["c"])
        state.playlists = [winter]
        state.mode = .playlist(winter.id)
        StorageMigration.migrate(&state, isNewInstall: false, onDisk: [], current: nil)
        #expect(state.mode == .playlist(winter.id))
        #expect(state.myAerials?.assetIDs.isEmpty == true)
    }

    @Test func aFileFromBefore05WithoutAModeIsMovedToMyAerials() throws {
        var state = try JSONDecoder.iso.decode(RotationState.self, from: Data(#"{"interval":"day"}"#.utf8))
        #expect(state.mode == .allDownloaded)
        StorageMigration.migrate(&state, isNewInstall: false, onDisk: ["a"], current: nil)
        #expect(state.mode == RotationState.myAerialsMode)
    }
}

@Suite struct DeletionOffTests {
    @Test func withDeletionOffASmallMyAerialsIsNotReplacedByTheWholeCatalog() {
        let mine = Playlist(id: Playlist.myAerialsID, name: "My Aerials", assetIDs: ["a"])
        let result = RotationPool.effective(mode: RotationState.myAerialsMode, playlists: [mine],
                                            catalog: myAerialsCatalog(), local: onDisk("a"), deleteShown: false)
        // Showing all 160 with deletion off would keep every one of them on disk.
        #expect(!result.showingAllInstead)
        #expect(result.pool == ["a"])
    }

    @Test func keptAndOwnVideosDontTakeAPlaceAmongTheLastN() {
        var state = RotationState()
        for id in ["c", "pinned", "b", "own", "a"] { state.recordShown(id) }
        // Most recent first: a, own, b, pinned, c.
        #expect(state.lastShown(keep: 3, exempt: ["pinned", "own"]) == ["a", "b", "c"])
        #expect(state.lastShown(keep: 3) == ["a", "own", "b"])
    }
}

@Suite struct LoginItemStateTests {
    @Test func openAtLoginIsTurnedOnOnceAndAChoiceIsRemembered() throws {
        var state = RotationState()
        #expect(!state.loginItemChosen && !state.loginItemTurnedOnByApp)
        state.loginItemTurnedOnByApp = true
        state.loginItemChosen = true
        let decoded = try JSONDecoder.iso.decode(RotationState.self, from: JSONEncoder.iso.encode(state))
        #expect(decoded.loginItemTurnedOnByApp && decoded.loginItemChosen)
        let old = try JSONDecoder.iso.decode(RotationState.self, from: Data("{}".utf8))
        #expect(!old.loginItemChosen && !old.loginItemTurnedOnByApp)
    }
}

@Suite struct LoginItemPolicyTests {
    @Test func aNewInstallTurnsItOnAnUpdateOnlyOffersIt() {
        #expect(RotationPolicy.loginItem(isFirstLaunch: true, chosen: false, handled: false, isOn: false) == .turnOn)
        // Off after an update may be the user's choice from an earlier version: ask, don't override.
        #expect(RotationPolicy.loginItem(isFirstLaunch: false, chosen: false, handled: false, isOn: false) == .offer)
        #expect(RotationPolicy.loginItem(isFirstLaunch: false, chosen: false, handled: false, isOn: true) == .nothing)
        #expect(RotationPolicy.loginItem(isFirstLaunch: false, chosen: true, handled: false, isOn: false) == .nothing)
        #expect(RotationPolicy.loginItem(isFirstLaunch: true, chosen: false, handled: true, isOn: false) == .nothing)
    }
}
