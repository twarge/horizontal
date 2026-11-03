import Foundation
import XCTest
@testable import HorizontalNative

/// Settings' Line Width section sets the board's connection lines and a
/// smashed text's line to its package, each on its own.
@MainActor
final class HorizontalLineWidthSettingsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "horizontal-line-width-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    func testUnsetWidthsAreWhatTheLinesWereDrawnAtBefore() throws {
        let settings = HorizontalAppearanceSettings(defaults: try makeDefaults())

        XCTAssertEqual(settings.lineWidth(for: .connectionLine), 3)
        XCTAssertEqual(settings.lineWidth(for: .smashedConnectionLine), settings.minimumLineWidth(for: .board))
    }

    func testAWidthIsKeptOnItsOwnAndReset() throws {
        let defaults = try makeDefaults()
        let settings = HorizontalAppearanceSettings(defaults: defaults)

        settings.lineWidthBinding(for: .connectionLine).wrappedValue = 4.5
        settings.lineWidthBinding(for: .smashedConnectionLine).wrappedValue = 2
        XCTAssertEqual(settings.lineWidth(for: .connectionLine), 4.5)
        XCTAssertEqual(settings.lineWidth(for: .smashedConnectionLine), 2)
        XCTAssertEqual(settings.minimumLineWidth(for: .board), 1.5, "the board's minimum is its own")

        let reloaded = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertEqual(reloaded.lineWidth(for: .connectionLine), 4.5)
        XCTAssertEqual(reloaded.lineWidth(for: .smashedConnectionLine), 2)

        reloaded.resetLineWidth(role: .connectionLine)
        XCTAssertEqual(reloaded.lineWidth(for: .connectionLine), 3)
        XCTAssertEqual(reloaded.lineWidth(for: .smashedConnectionLine), 2, "a reset takes back only its own")
        XCTAssertEqual(HorizontalAppearanceSettings(defaults: defaults).lineWidth(for: .connectionLine), 3)
    }

    func testAWidthStaysInTheSlidersRange() throws {
        let defaults = try makeDefaults()
        let settings = HorizontalAppearanceSettings(defaults: defaults)

        settings.lineWidthBinding(for: .connectionLine).wrappedValue = 40
        settings.lineWidthBinding(for: .smashedConnectionLine).wrappedValue = 0
        XCTAssertEqual(settings.lineWidth(for: .connectionLine), CGFloat(HorizontalLineWidthRole.range.upperBound))
        XCTAssertEqual(settings.lineWidth(for: .smashedConnectionLine), CGFloat(HorizontalLineWidthRole.range.lowerBound))

        defaults.set(-1.0, forKey: "appearance.board.connectionLine.lineWidth")
        XCTAssertEqual(
            HorizontalAppearanceSettings(defaults: defaults).lineWidth(for: .connectionLine),
            CGFloat(HorizontalLineWidthRole.range.lowerBound),
            "a stored width out of range is brought into it"
        )
    }
}
