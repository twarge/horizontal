import Foundation
import XCTest
@testable import HorizontalNative

/// The user's preferences travel between their devices through iCloud's
/// key-value store: what one device sets or resets, the others take.
@MainActor
final class PreferenceSyncTests: XCTestCase {
    private final class Cloud: SettingsSyncStore {
        var values = [String: Any]()
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func synchronize() -> Bool { true }
    }

    /// The store of a build without the iCloud entitlement: it takes nothing.
    private final class DeafCloud: SettingsSyncStore {
        func object(forKey key: String) -> Any? { nil }
        func set(_ value: Any?, forKey key: String) {}
        func removeObject(forKey key: String) {}
        func synchronize() -> Bool { false }
    }

    private struct Device {
        var defaults: UserDefaults
        var sync: SettingsSync
        var domain: String
    }

    private let lineWidthKey = "appearance.grid.lineWidth"
    private let hoverKey = "appearance.showsHoverPopover"

    private func makeDevice(_ cloud: any SettingsSyncStore, account: Data? = Data([1])) throws -> Device {
        let name = "horizontal-preference-sync-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return Device(defaults: defaults,
                      sync: SettingsSync(defaults: defaults, store: cloud, domain: name, account: { account }),
                      domain: name)
    }

    func testAStoreThatTakesNothingRemovesNothingAtTheNextLaunch() throws {
        let cloud = DeafCloud()
        let mac = try makeDevice(cloud)
        mac.defaults.set(0.2, forKey: lineWidthKey)
        mac.sync.start()

        let relaunched = SettingsSync(defaults: mac.defaults, store: cloud, domain: mac.domain, account: { Data([1]) })
        relaunched.start()
        XCTAssertEqual(mac.defaults.object(forKey: lineWidthKey) as? Double, 0.2)
    }

    func testAChoiceReachesTheCloudAndAnotherDevice() throws {
        let cloud = Cloud()
        let mac = try makeDevice(cloud)
        mac.defaults.set(0.2, forKey: lineWidthKey)
        mac.sync.start()
        XCTAssertEqual(cloud.values[lineWidthKey] as? Double, 0.2)

        let pad = try makeDevice(cloud)
        pad.sync.start()
        XCTAssertEqual(pad.defaults.double(forKey: lineWidthKey), 0.2)
    }

    func testOnlySyncedKeysTravel() throws {
        let cloud = Cloud()
        let mac = try makeDevice(cloud)
        mac.defaults.set("dark", forKey: "appearance.appTheme")
        mac.defaults.set(["/pool"], forKey: "HorizontalPoolPaths")
        mac.defaults.set(true, forKey: hoverKey)
        mac.sync.start()
        XCTAssertEqual(Set(cloud.values.keys), [hoverKey])

        cloud.values["operation.readOnly"] = false
        mac.sync.storeChanged(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["operation.readOnly"])
        XCTAssertNil(mac.defaults.object(forKey: "operation.readOnly"))
    }

    func testAnUnsetDefaultDoesNotOverwriteTheCloud() throws {
        let cloud = Cloud()
        cloud.values[hoverKey] = true
        let pad = try makeDevice(cloud)
        pad.defaults.register(defaults: [hoverKey: false])
        pad.sync.start()
        XCTAssertEqual(cloud.values[hoverKey] as? Bool, true)
        XCTAssertTrue(pad.defaults.bool(forKey: hoverKey))
    }

    func testAResetTravelsBothWays() throws {
        let cloud = Cloud()
        let mac = try makeDevice(cloud)
        let pad = try makeDevice(cloud)
        mac.defaults.set(0.2, forKey: lineWidthKey)
        mac.sync.start()
        pad.sync.start()

        mac.defaults.removeObject(forKey: lineWidthKey)
        mac.sync.push()
        XCTAssertNil(cloud.values[lineWidthKey], "the reset leaves the cloud")

        pad.sync.storeChanged(reason: NSUbiquitousKeyValueStoreServerChange, keys: [lineWidthKey])
        XCTAssertNil(pad.defaults.object(forKey: lineWidthKey), "and the other device")
        XCTAssertNil(cloud.values[lineWidthKey], "which does not put it back")
    }

    func testAnotherAccountsEmptyStoreRemovesNothing() throws {
        let cloud = Cloud()
        let mac = try makeDevice(cloud)
        mac.defaults.set(0.2, forKey: lineWidthKey)
        mac.sync.start()

        cloud.values = [:]
        mac.sync.storeChanged(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
        XCTAssertEqual(mac.defaults.double(forKey: lineWidthKey), 0.2)
    }

    func testOpenSettingsTakeWhatArrives() throws {
        let cloud = Cloud()
        let pad = try makeDevice(cloud)
        pad.sync.start()
        let settings = HorizontalAppearanceSettings(defaults: pad.defaults)
        XCTAssertFalse(settings.shouldShowHoverPopover)

        cloud.values[hoverKey] = true
        pad.sync.storeChanged(reason: NSUbiquitousKeyValueStoreServerChange, keys: [hoverKey])
        XCTAssertTrue(settings.shouldShowHoverPopover)
    }

    func testOpenRouterOptionsTakeWhatArrivesAndAResetStaysReset() throws {
        let cloud = Cloud()
        let pad = try makeDevice(cloud)
        pad.sync.start()
        let tools = HorizontalBoardToolSettings(defaults: pad.defaults)
        XCTAssertTrue(tools.removeLoops)

        cloud.values["boardTool.removeLoops"] = false
        pad.sync.storeChanged(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["boardTool.removeLoops"])
        XCTAssertFalse(tools.removeLoops)

        cloud.values["boardTool.removeLoops"] = nil
        pad.sync.storeChanged(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["boardTool.removeLoops"])
        XCTAssertTrue(tools.removeLoops)
        XCTAssertNil(pad.defaults.object(forKey: "boardTool.removeLoops"), "the open settings do not write it back")
        pad.sync.push()
        XCTAssertNil(cloud.values["boardTool.removeLoops"])
    }

    func testColoursFromAnotherDeviceDoNotSeedTheLightLayerSet() throws {
        let cloud = Cloud()
        let darkTopCopper = "appearance.board.shared.layer.\(HorizontalBoardLayers.topCopper)"
        let lightTopCopper = "appearance.board.shared.light.layer.\(HorizontalBoardLayers.topCopper)"
        XCTAssertTrue(SettingsSync.syncedKeys.contains(darkTopCopper))
        cloud.values[darkTopCopper] = "#112233"

        let pad = try makeDevice(cloud)
        pad.sync.start()
        _ = HorizontalAppearanceSettings(defaults: pad.defaults)
        XCTAssertEqual(pad.defaults.string(forKey: darkTopCopper), "#112233")
        XCTAssertNil(pad.defaults.object(forKey: lightTopCopper))
        XCTAssertNil(cloud.values[lightTopCopper])
    }
}
