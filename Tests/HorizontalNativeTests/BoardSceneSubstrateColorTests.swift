import SwiftUI
import XCTest
@testable import HorizontalNative

/// The 3D view's substrate is #BCC486 unless someone picked their own: only a
/// picked colour is stored, so a new default reaches everyone else.
@MainActor
final class BoardSceneSubstrateColorTests: XCTestCase {
    private let key = "appearance.boardScene.substrateColor"

    func testSomeoneWhoNeverChoseGetsTheDefault() throws {
        let settings = HorizontalAppearanceSettings(defaults: try freshDefaults())

        XCTAssertEqual(hexString(settings.boardSceneSubstrateColorBinding().wrappedValue), "#BCC486")
        let substrate = try XCTUnwrap(settings.boardSceneMaterialColors.substrate)
        XCTAssertEqual(substrate.red, 188 / 255, accuracy: 0.5 / 255)
        XCTAssertEqual(substrate.green, 196 / 255, accuracy: 0.5 / 255)
        XCTAssertEqual(substrate.blue, 134 / 255, accuracy: 0.5 / 255)
    }

    func testAChosenColourIsKept() throws {
        let defaults = try freshDefaults()
        defaults.set("#2E572E", forKey: key)

        let settings = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertEqual(hexString(settings.boardSceneSubstrateColorBinding().wrappedValue), "#2E572E", "the old default, once picked, stays")

        settings.boardSceneSubstrateColorBinding().wrappedValue = Color(red: 1, green: 0, blue: 0)
        XCTAssertEqual(defaults.string(forKey: key), "#FF0000")
        XCTAssertEqual(hexString(HorizontalAppearanceSettings(defaults: defaults).boardSceneSubstrateColorBinding().wrappedValue), "#FF0000")
    }

    func testResetForgetsTheChoice() throws {
        let defaults = try freshDefaults()
        let settings = HorizontalAppearanceSettings(defaults: defaults)
        settings.boardSceneSubstrateColorBinding().wrappedValue = Color(red: 1, green: 0, blue: 0)

        settings.resetBoardSceneColors()

        XCTAssertNil(defaults.string(forKey: key))
        XCTAssertEqual(hexString(settings.boardSceneSubstrateColorBinding().wrappedValue), "#BCC486")
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "horizontal-substrate-color-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func hexString(_ color: Color) -> String {
        HorizontalAppearanceSettings.hexString(from: color)
    }
}
