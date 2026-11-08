import Foundation
import XCTest
@testable import HorizontalNative

/// The track tool's corner style starts at 45° on a first launch, and the
/// route inspector's picker and C both put 45° first.
@MainActor
final class BoardTrackCornerStyleDefaultTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "corner-style-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testAFirstLaunchRoutesAt45Degrees() {
        XCTAssertEqual(HorizontalBoardToolSettings(defaults: freshDefaults()).cornerStyle, .fortyFive)
    }

    func testAChosenStyleIsKept() {
        let defaults = freshDefaults()
        HorizontalBoardToolSettings(defaults: defaults).cornerStyle = .ninety
        XCTAssertEqual(HorizontalBoardToolSettings(defaults: defaults).cornerStyle, .ninety)
    }

    func testThePickerAndCPut45First() {
        XCTAssertEqual(BoardTrackCornerStyle.allCases, [.fortyFive, .ninety, .arc])
        var style = BoardTrackCornerStyle.fortyFive
        var seen = [style]
        for _ in 0..<3 {
            style.cycle()
            seen.append(style)
        }
        XCTAssertEqual(seen, [.fortyFive, .ninety, .arc, .fortyFive])
    }
}
