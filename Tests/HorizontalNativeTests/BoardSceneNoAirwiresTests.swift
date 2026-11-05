import Foundation
import SceneKit
import XCTest
@testable import HorizontalNative

/// The 3D view draws the board as built, not its unrouted connections: a
/// board's airwires and connection lines add nothing to its scene, even with
/// the Connections switch on.
@MainActor
final class BoardSceneNoAirwiresTests: XCTestCase {
    private let mm = 1_000_000.0

    private func board(withConnections: Bool) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: "air", name: "Air", url: URL(fileURLWithPath: "/tmp/air"))
        board.polygons.append(HorizontalPolygon(id: "outline", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 40 * mm, y: 0),
            HorizontalPoint(x: 40 * mm, y: 30 * mm), HorizontalPoint(x: 0, y: 30 * mm),
        ], layer: HorizontalBoardLayers.outline))
        if withConnections {
            board.airwires = [
                HorizontalSegment(id: "a1", from: HorizontalPoint(x: 5 * mm, y: 5 * mm), to: HorizontalPoint(x: 35 * mm, y: 25 * mm), width: 0, layer: nil),
            ]
            board.connectionLines = [
                HorizontalSegment(id: "c1", from: HorizontalPoint(x: 5 * mm, y: 25 * mm), to: HorizontalPoint(x: 35 * mm, y: 5 * mm), width: 0, layer: nil),
            ]
        }
        return board
    }

    private func nodeCount(of board: HorizontalBoard) async -> Int {
        let cache = BoardSceneSceneCache()
        let nodes: BoardSceneNodes = await withCheckedContinuation { continuation in
            if let ready = cache.nodes(for: board, onReady: { built in continuation.resume(returning: built) }) {
                continuation.resume(returning: ready)
            }
        }
        var options = BoardDisplayOptions()
        options.connectionLines = true
        nodes.applyDisplayOptions(
            options,
            backgroundColor: HorizontalDefaultTheme.background,
            copperColor: HorizontalDefaultTheme.background,
            materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            layerColors: [:],
            board: board
        )
        var count = 0
        nodes.scene.rootNode.enumerateHierarchy { node, _ in
            if node.geometry != nil { count += 1 }
        }
        return count
    }

    func testAirwiresAndConnectionLinesAddNothingToTheScene() async {
        let plain = await nodeCount(of: board(withConnections: false))
        let connected = await nodeCount(of: board(withConnections: true))
        XCTAssertGreaterThan(plain, 0, "the board itself is drawn")
        XCTAssertEqual(connected, plain, "no dash is drawn for an airwire or a connection line")
    }
}
