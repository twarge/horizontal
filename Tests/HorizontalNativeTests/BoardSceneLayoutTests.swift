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

    /// The bottom silkscreen hangs under the bottom mask as the top
    /// silkscreen stands on the top mask: its lines, fills and texts as far
    /// out from the mask's outer face, and as thick, clipped or not. They
    /// were lifted towards the core like the top's, which put the bottom's
    /// lines half inside the mask and its texts on the mask's face.
    func testTheBottomSilkscreenMirrorsTheTop() {
        let mm = 1_000_000.0
        func point(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }
        var board = board(bottomSubstrate: 0)
        // An edge the lines run over, so clipping cuts them and draws them
        // as clipped sheets while the fills and texts, well inside, stay as
        // they are.
        board.polygons.append(HorizontalPolygon(
            id: "outline", vertices: [point(-1, -1), point(3, -1), point(3, 10), point(-1, 10)], layer: HorizontalBoardLayers.outline
        ))
        for layer in [HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen] {
            board.lines.append(HorizontalSegment(id: "line:\(layer)", from: point(0, 2), to: point(4, 2), width: 150_000, layer: layer, netID: nil))
            board.polygons.append(HorizontalPolygon(
                id: "polygon:\(layer)", vertices: [point(0, 4), point(2, 4), point(2, 6), point(0, 6)], layer: layer
            ))
            board.texts.append(HorizontalText(id: "text:\(layer)", text: "R1", position: point(0, 8), size: mm, layer: layer))
        }
        let layout = BoardSceneFactory.sceneLayout(for: board)

        for clipping in [nil, HorizontalSilkscreenClipping()] {
            let meshes = BoardSceneFactory.describeScene(for: board, silkscreenClipping: clipping).meshes
                .filter { $0.group == .silkscreen && !$0.mesh.isEmpty }
            if clipping != nil {
                XCTAssertTrue(meshes.contains { $0.name.hasPrefix("clipped:") }, "the lines are clipped at the edge")
            }
            // Each mesh's near and far faces, measured out from its own side's mask.
            func spans(top: Bool) -> [String] {
                meshes.filter { (($0.explodeFactor ?? 0) > 0) == top }.map { item in
                    let near = top ? Double(item.mesh.boundsMin.y) - layout.topMaskTopY : layout.bottomMaskBottomY - Double(item.mesh.boundsMax.y)
                    let far = top ? Double(item.mesh.boundsMax.y) - layout.topMaskTopY : layout.bottomMaskBottomY - Double(item.mesh.boundsMin.y)
                    XCTAssertGreaterThanOrEqual(near, 0.01 - 1e-5, "\(item.name) clears its mask, clipping \(String(describing: clipping))")
                    return String(format: "%.4f…%.4f", near, far)
                }.sorted()
            }
            let top = spans(top: true)
            XCTAssertFalse(top.isEmpty)
            XCTAssertEqual(spans(top: false), top, "clipping \(String(describing: clipping))")
        }
    }
}
