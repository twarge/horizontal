import Foundation
import XCTest
@testable import HorizontalNative

/// Where the 3D scene stacks a board's surfaces.
final class BoardSceneLayoutTests: XCTestCase {
    private func board(bottomSubstrate: Double) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: "b", name: "Layout", url: URL(fileURLWithPath: "/tmp/layout"))
        board.stackupLayers = [
            HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.topCopper, copperThickness: 35_000, substrateThickness: 1_600_000),
            HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.bottomCopper, copperThickness: 35_000, substrateThickness: bottomSubstrate),
        ]
        return board
    }

    func testABottomCopperSubstrateEntryDoesNotThickenTheBoard() {
        // Horizon writes 0 there; documents made by the old template carry
        // a second 1.6 mm, which used to float the bottom mask a slab below.
        let clean = BoardSceneFactory.sceneLayout(for: board(bottomSubstrate: 0))
        let legacy = BoardSceneFactory.sceneLayout(for: board(bottomSubstrate: 1_600_000))
        XCTAssertEqual(clean, legacy)
        XCTAssertEqual(clean.boardThickness, 1.635, accuracy: 1e-9)
        XCTAssertEqual(clean.substrateTopY - clean.substrateBottomY, 1.6, accuracy: 1e-9)
        // The bottom mask hangs just under the bottom copper, which is just under the substrate.
        XCTAssertEqual(clean.bottomCopperBottomY, clean.substrateBottomY - 0.035, accuracy: 1e-9)
        XCTAssertLessThan(clean.bottomCopperBottomY - clean.bottomMaskTopY, 0.02)
        XCTAssertGreaterThan(clean.bottomCopperBottomY - clean.bottomMaskTopY, 0)
    }

    func testLayersSitClearOfWhatTheyCover() {
        let layout = BoardSceneFactory.sceneLayout(for: board(bottomSubstrate: 0))
        // Mask over copper, silkscreen over mask: each a real gap, none coplanar.
        let maskGap = layout.topMaskBottomY - layout.topCopperTopY
        XCTAssertGreaterThanOrEqual(maskGap, 0.01 - 1e-9)
        XCTAssertLessThan(maskGap, 0.05)
        let silkGap = layout.topSilkscreenY - layout.topMaskTopY
        XCTAssertGreaterThanOrEqual(silkGap, 0.01 - 1e-9)
        XCTAssertLessThan(silkGap, 0.05)
    }
}
