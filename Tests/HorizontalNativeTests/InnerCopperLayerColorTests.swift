import SwiftUI
import XCTest
@testable import HorizontalNative

/// Inner copper defaults to a rainbow, In1 first: orange, cyan, magenta,
/// lavender, grey-yellow, pink, brown and pea soup.
@MainActor
final class InnerCopperLayerColorTests: XCTestCase {
    private let rainbow: [Color] = [
        Color(red: 1, green: 0.5, blue: 0),
        Color(red: 0, green: 0.85, blue: 0.9),
        Color(red: 1, green: 0.15, blue: 0.85),
        Color(red: 0.72, green: 0.62, blue: 1),
        Color(red: 0.78, green: 0.75, blue: 0.48),
        Color(red: 1, green: 0.6, blue: 0.78),
        Color(red: 0.66, green: 0.42, blue: 0.2),
        Color(red: 0.5, green: 0.62, blue: 0.2),
    ]

    private let innerLayers = [
        HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.in2Copper,
        HorizontalBoardLayers.in3Copper, HorizontalBoardLayers.in4Copper,
        HorizontalBoardLayers.in5Copper, HorizontalBoardLayers.in6Copper,
        HorizontalBoardLayers.in7Copper, HorizontalBoardLayers.in8Copper,
    ]

    func testFreshSettingsGiveEachInnerLayerItsRainbowColour() throws {
        let name = "horizontal-inner-copper-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = HorizontalAppearanceSettings(defaults: defaults)

        for (index, layer) in innerLayers.enumerated() {
            let expected = rainbow[index]
            assertColor(settings.layerColorBinding(for: layer, mode: .dark).wrappedValue, expected, "In\(index + 1) in Settings")
            assertColor(settings.palette(for: .board, mode: .light).layerColor(for: layer), expected, "In\(index + 1) on a light board")
            assertColor(Color(nsColor: HorizontalDefaultTheme.nsLayerColor(for: layer)), expected, "In\(index + 1) in the 3D view")
        }
        let colours = innerLayers.map {
            HorizontalAppearanceSettings.hexString(from: settings.layerColorBinding(for: $0, mode: .dark).wrappedValue)
        }
        XCTAssertEqual(Set(colours).count, 8, "no two inner layers share a colour")
    }

    func testAChosenInnerLayerColourStillWins() throws {
        let name = "horizontal-inner-copper-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        HorizontalAppearanceSettings(defaults: defaults).layerColorBinding(for: HorizontalBoardLayers.in2Copper, mode: .dark).wrappedValue = Color(red: 1, green: 1, blue: 0)

        let settings = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertEqual(HorizontalAppearanceSettings.hexString(from: settings.layerColorBinding(for: HorizontalBoardLayers.in2Copper, mode: .dark).wrappedValue), "#FFFF00")
        assertColor(settings.layerColorBinding(for: HorizontalBoardLayers.in1Copper, mode: .dark).wrappedValue, rainbow[0], "In1 keeps its default")
    }

    /// Within one step of 255 a channel: a component that lands on a half,
    /// as 0.9 does, rounds either way once it has been through NSColor.
    private func assertColor(_ color: Color, _ expected: Color, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let actual = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        let wanted = NSColor(expected).usingColorSpace(.sRGB) ?? .white
        XCTAssertEqual(actual.redComponent, wanted.redComponent, accuracy: 1 / 255, message, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, wanted.greenComponent, accuracy: 1 / 255, message, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, wanted.blueComponent, accuracy: 1 / 255, message, file: file, line: line)
    }
}
