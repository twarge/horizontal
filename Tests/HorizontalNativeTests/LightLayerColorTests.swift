import SwiftUI
import XCTest
@testable import HorizontalNative

/// The light theme has board layer colours of its own: the dark set's
/// near-white silkscreen, notes and dimensions vanished on a white canvas.
@MainActor
final class LightLayerColorTests: XCTestCase {
    private let nearBlack = Color(red: 0.1, green: 0.1, blue: 0.1)
    private let darkSilkscreen = Color(red: 0.9, green: 0.9, blue: 0.9)

    private var lightOnly: [Int: Color] {
        [
            HorizontalBoardLayers.topSilkscreen: nearBlack,
            HorizontalBoardLayers.bottomSilkscreen: nearBlack,
            HorizontalBoardLayers.topNotes: Color(red: 0, green: 0, blue: 0),
            HorizontalBoardLayers.bottomNotes: Color(red: 0, green: 0, blue: 0),
            HorizontalBoardLayers.dimensions: Color(red: 0, green: 0, blue: 0),
            HorizontalBoardLayers.topPaste: Color(red: 0.45, green: 0.45, blue: 0.45),
            HorizontalBoardLayers.bottomPaste: Color(red: 0.45, green: 0.45, blue: 0.45),
            HorizontalBoardLayers.outline: Color(red: 0.45, green: 0.45, blue: 0),
            HorizontalBoardLayers.outlineNotes: Color(red: 0.1, green: 0.1, blue: 0),
            HorizontalBoardLayers.user1: Color(red: 0, green: 0.5, blue: 0.55),
            HorizontalBoardLayers.user8: Color(red: 0, green: 0.5, blue: 0.55),
        ]
    }

    func testFreshSettingsGiveTheLightThemeItsOwnPaleLayersAndShareTheRest() throws {
        let settings = HorizontalAppearanceSettings(defaults: try freshDefaults())
        let light = settings.palette(for: .board, mode: .light)
        let dark = settings.palette(for: .board, mode: .dark)

        for (layer, expected) in lightOnly {
            let name = HorizontalBoardLayers.name(for: layer)
            assertColor(light.layerColor(for: layer), expected, name)
            assertColor(settings.layerColorBinding(for: layer, mode: .light).wrappedValue, expected, "\(name) in Settings")
            XCTAssertNotEqual(hexString(dark.layerColor(for: layer)), hexString(expected), "\(name) keeps its dark colour")
        }
        assertColor(dark.layerColor(for: HorizontalBoardLayers.topSilkscreen), darkSilkscreen, "dark silkscreen")
        XCTAssertEqual(hexString(dark.layerColor(for: HorizontalBoardLayers.topNotes)), "#FFFFFF")
        for layer in editableLayers where lightOnly[layer] == nil && !HorizontalBoardLayers.isUser(layer) {
            XCTAssertEqual(hexString(light.layerColor(for: layer)), hexString(dark.layerColor(for: layer)), "\(HorizontalBoardLayers.name(for: layer)) is the same in both themes")
        }
        assertColor(
            settings.palette(for: .schematic, mode: .light).layerColor(for: HorizontalBoardLayers.topSilkscreen),
            nearBlack,
            "a light canvas of either kind draws the light set"
        )
    }

    /// At the board's 60 % default layer opacity over the light background,
    /// silkscreen, the notes layers and dimensions read as text should.
    func testThePaleLayersStandOutFromTheLightBackground() throws {
        let palette = HorizontalAppearanceSettings(defaults: try freshDefaults()).palette(for: .board, mode: .light)
        let background = components(palette.background)
        for layer in [HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen,
                      HorizontalBoardLayers.topNotes, HorizontalBoardLayers.bottomNotes,
                      HorizontalBoardLayers.outlineNotes, HorizontalBoardLayers.dimensions] {
            let ink = components(palette.layerColor(for: layer))
            let drawn = (0..<3).map { 0.6 * ink[$0] + 0.4 * background[$0] }
            XCTAssertGreaterThanOrEqual(contrast(drawn, background), 4.5, HorizontalBoardLayers.name(for: layer))
        }
    }

    func testEachThemeKeepsItsOwnChoice() throws {
        let defaults = try freshDefaults()
        let silkscreen = HorizontalBoardLayers.topSilkscreen
        let first = HorizontalAppearanceSettings(defaults: defaults)
        first.layerColorBinding(for: silkscreen, mode: .light).wrappedValue = Color(red: 0, green: 0, blue: 1)
        assertColor(first.palette(for: .board, mode: .dark).layerColor(for: silkscreen), darkSilkscreen, "the dark theme is untouched")
        first.layerColorBinding(for: silkscreen, mode: .dark).wrappedValue = Color(red: 1, green: 1, blue: 0)

        let reloaded = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertEqual(hexString(reloaded.palette(for: .board, mode: .light).layerColor(for: silkscreen)), "#0000FF")
        XCTAssertEqual(hexString(reloaded.palette(for: .board, mode: .dark).layerColor(for: silkscreen)), "#FFFF00")
        XCTAssertEqual(hexString(reloaded.layerColorBinding(for: silkscreen, colorScheme: .light).wrappedValue), "#0000FF", "the rail's swatch follows the canvas's scheme")
        XCTAssertEqual(hexString(reloaded.layerColorBinding(for: silkscreen, colorScheme: .dark).wrappedValue), "#FFFF00")

        reloaded.resetLayerColors()
        assertColor(reloaded.palette(for: .board, mode: .light).layerColor(for: silkscreen), nearBlack, "light after reset")
        assertColor(reloaded.palette(for: .board, mode: .dark).layerColor(for: silkscreen), darkSilkscreen, "dark after reset")
        let afterReset = HorizontalAppearanceSettings(defaults: defaults)
        assertColor(afterReset.palette(for: .board, mode: .light).layerColor(for: silkscreen), nearBlack, "reset is kept")
        assertColor(afterReset.palette(for: .board, mode: .dark).layerColor(for: silkscreen), darkSilkscreen, "dark reset is kept")
    }

    /// A colour chosen while one set served both themes was chosen for the
    /// light canvas too, so it carries over to the light set, once.
    func testAColourChosenBeforeTheLightSetCarriesOverOnce() throws {
        let defaults = try freshDefaults()
        defaults.set("#FFFF00", forKey: "appearance.board.shared.layer.\(HorizontalBoardLayers.topSilkscreen)")
        defaults.set("#00FF00", forKey: "appearance.board.dark.layer.\(HorizontalBoardLayers.bottomSilkscreen)")

        let migrated = HorizontalAppearanceSettings(defaults: defaults)
        for mode in HorizontalPaletteMode.allCases {
            let palette = migrated.palette(for: .board, mode: mode)
            XCTAssertEqual(hexString(palette.layerColor(for: HorizontalBoardLayers.topSilkscreen)), "#FFFF00", "\(mode) top silkscreen")
            XCTAssertEqual(hexString(palette.layerColor(for: HorizontalBoardLayers.bottomSilkscreen)), "#00FF00", "\(mode) bottom silkscreen, from the older key")
        }
        XCTAssertEqual(hexString(migrated.palette(for: .board, mode: .light).layerColor(for: HorizontalBoardLayers.topNotes)), "#000000", "a layer never chosen takes the light default")

        migrated.layerColorBinding(for: HorizontalBoardLayers.topSilkscreen, mode: .dark).wrappedValue = Color(red: 1, green: 0, blue: 1)
        defaults.set("#FF8000", forKey: "appearance.board.shared.layer.\(HorizontalBoardLayers.topNotes)")
        let later = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertEqual(hexString(later.palette(for: .board, mode: .light).layerColor(for: HorizontalBoardLayers.topSilkscreen)), "#FFFF00", "a later dark choice stays dark")
        XCTAssertEqual(hexString(later.palette(for: .board, mode: .light).layerColor(for: HorizontalBoardLayers.topNotes)), "#000000", "nothing is copied a second time")
    }

    func testThe3DViewTakesTheSetForItsOwnBackground() throws {
        let settings = HorizontalAppearanceSettings(defaults: try freshDefaults())
        XCTAssertEqual(settings.boardSceneLayerColorMode, .dark, "the default navy background")
        settings.layerColorBinding(for: HorizontalBoardLayers.topCopper, mode: .light).wrappedValue = Color(red: 0, green: 0, blue: 1)
        XCTAssertEqual(settings.boardSceneLayerColors[HorizontalBoardLayers.topCopper], HorizontalRGBColor(red: 1, green: 0, blue: 0))

        settings.boardSceneBackgroundColorBinding().wrappedValue = Color(red: 1, green: 1, blue: 1)
        XCTAssertEqual(settings.boardSceneLayerColorMode, .light)
        XCTAssertEqual(settings.boardSceneLayerColors[HorizontalBoardLayers.topCopper], HorizontalRGBColor(red: 0, green: 0, blue: 1))
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "horizontal-light-layer-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func hexString(_ color: Color) -> String {
        HorizontalAppearanceSettings.hexString(from: color)
    }

    /// Within one step of 255 a channel: a component that lands on a half,
    /// as 0.1 and 0.9 do, rounds either way once it has been through NSColor.
    private func assertColor(_ color: Color, _ expected: Color, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (actual, wanted) in zip(components(color), components(expected)) {
            XCTAssertEqual(actual, wanted, accuracy: 1 / 255, message, file: file, line: line)
        }
    }

    private func components(_ color: Color) -> [Double] {
        let platform = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [platform.redComponent, platform.greenComponent, platform.blueComponent].map(Double.init)
    }

    /// WCAG 2's contrast ratio between two sRGB colours.
    private func contrast(_ first: [Double], _ second: [Double]) -> Double {
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
