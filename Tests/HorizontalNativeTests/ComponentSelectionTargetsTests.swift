import XCTest
@testable import HorizontalNative

/// A component selection made in the board or the schematic stays there: a
/// part picked on the board is not selected in the schematic, nor one picked
/// in the schematic on the board. One made anywhere else — the 3D view, Find,
/// the Parts pane, `select` from the live channel — goes into both canvases.
/// Both workspaces put a selection into the canvases this names, and only
/// those.
final class ComponentSelectionTargetsTests: XCTestCase {
    func testACanvasKeepsItsSelectionToItself() {
        XCTAssertEqual(HorizontalPane.componentSelectionTargets(from: .board), [])
        XCTAssertEqual(HorizontalPane.componentSelectionTargets(from: .schematic), [])
    }

    func testASelectionFromAnywhereElseLandsInBothCanvases() {
        XCTAssertEqual(HorizontalPane.componentSelectionTargets(from: nil), [.board, .schematic])
        XCTAssertEqual(HorizontalPane.componentSelectionTargets(from: .threeD), [.board, .schematic])
        XCTAssertEqual(HorizontalPane.componentSelectionTargets(from: .parts), [.board, .schematic])
        XCTAssertEqual(HorizontalPane.componentSelectionTargets(from: .library), [.board, .schematic])
    }
}
