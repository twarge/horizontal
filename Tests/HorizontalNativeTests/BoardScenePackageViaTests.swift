import Foundation
import XCTest
@testable import HorizontalNative

/// Plated package holes get a copper barrel in 3D whatever pad they sit
/// in: a round pad is replaced by a ring around it, any other pad keeps
/// its copper and gets the barrel alone.
final class BoardScenePackageViaTests: XCTestCase {
    private let mm = 1_000_000.0

    private func circle(center: HorizontalPoint, radius: Double, segments: Int = 24) -> [HorizontalPoint] {
        (0..<segments).map { index in
            let angle = Double(index) / Double(segments) * 2 * .pi
            return HorizontalPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    /// An obround: a 3 × 1.2 mm bar with round ends.
    private func obround(center: HorizontalPoint) -> [HorizontalPoint] {
        let halfLength = 0.9 * mm
        let radius = 0.6 * mm
        var points = [HorizontalPoint]()
        for index in 0...8 {
            let angle = -Double.pi / 2 + Double(index) / 8 * .pi
            points.append(HorizontalPoint(x: center.x + halfLength + radius * cos(angle), y: center.y + radius * sin(angle)))
        }
        for index in 0...8 {
            let angle = Double.pi / 2 + Double(index) / 8 * .pi
            points.append(HorizontalPoint(x: center.x - halfLength + radius * cos(angle), y: center.y + radius * sin(angle)))
        }
        return points
    }

    private func board(padVertices: [HorizontalPoint], holePositions: [HorizontalPoint]) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: "b", name: "B", url: URL(fileURLWithPath: "/tmp/b"))
        for layer in [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper] {
            board.packagePads.append(HorizontalPolygon(id: "pkg/pad/p1/shape/s1/layer/\(layer)", vertices: padVertices, layer: layer, netID: "gnd"))
        }
        for (index, position) in holePositions.enumerated() {
            var hole = HorizontalHole(
                id: "pkg/pad/p1/hole/h\(index)",
                position: position,
                diameter: 0.9 * mm,
                length: 0.9 * mm,
                shape: .round,
                plated: true,
                parameterClass: "hole"
            )
            hole.netID = "gnd"
            board.packageHoles.append(hole)
        }
        return board
    }

    func testAPlatedHoleInAnObroundPadGetsABarrelButNoRing() {
        let center = HorizontalPoint(x: 10 * mm, y: 5 * mm)
        let holes = [HorizontalPoint(x: center.x - 0.9 * mm, y: center.y), HorizontalPoint(x: center.x + 0.9 * mm, y: center.y)]
        let markers = BoardSceneFactory.packageViaMarkers(for: board(padVertices: obround(center: center), holePositions: holes))
        XCTAssertEqual(markers.count, 2, "one barrel per plated hole")
        for entry in markers {
            XCTAssertEqual(entry.marker.holeSize, 0.9 * mm)
            XCTAssertEqual(entry.marker.size, 0.9 * mm, "no ring: the pad draws its own copper")
            XCTAssertTrue(entry.coveredPadIDs.isEmpty, "the pad stays")
            XCTAssertEqual(entry.marker.netID, "gnd")
            XCTAssertEqual(Set(entry.marker.connectedLayers), [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper])
        }
    }

    func testAPlatedHoleInARoundPadIsReplacedByARing() {
        let center = HorizontalPoint(x: 0, y: 0)
        let markers = BoardSceneFactory.packageViaMarkers(for: board(padVertices: circle(center: center, radius: 0.8 * mm), holePositions: [center]))
        XCTAssertEqual(markers.count, 1)
        let entry = markers[0]
        XCTAssertEqual(entry.marker.size, 1.6 * mm, accuracy: 1_000)
        XCTAssertEqual(entry.coveredPadIDs.count, 2, "both round pads are drawn as rings")
    }

    func testAnUnplatedHoleGetsNoBarrel() {
        var unplated = board(padVertices: obround(center: .zero), holePositions: [.zero])
        unplated.packageHoles[0].plated = false
        XCTAssertTrue(BoardSceneFactory.packageViaMarkers(for: unplated).isEmpty)
    }
}
