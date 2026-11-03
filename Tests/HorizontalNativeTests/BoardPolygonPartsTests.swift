import XCTest
@testable import HorizontalNative

/// A polygon's edge moves only its two vertices, as Horizon's move tool
/// expands an edge (tool_move's expand_selection), and each point moves once
/// however many selected refs name it. An arc's centre moves only when it is
/// selected itself.
final class BoardPolygonPartsTests: XCTestCase {
    private let square = HorizontalPolygon(id: "Outline", vertices: [
        HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10, y: 0),
        HorizontalPoint(x: 10, y: 10), HorizontalPoint(x: 0, y: 10),
    ], layer: HorizontalBoardLayers.outline, netID: nil)

    private func ref(_ type: HorizontalObjectType, _ vertex: Int) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: "outline", type: type, vertex: vertex, layer: HorizontalBoardLayers.outline)
    }

    private func moved(_ polygon: HorizontalPolygon, by refs: [HorizontalSelectableRef], delta: HorizontalPoint) -> HorizontalPolygon {
        var polygons = [polygon]
        var done = Set<String>()
        for ref in refs {
            BoardPolygonParts.change(&polygons, ref: ref, done: &done) { $0 + delta }
        }
        return polygons[0]
    }

    func testAnEdgeMovesItsTwoVerticesAndNothingElse() {
        let up = HorizontalPoint(x: 0, y: 5)
        let result = moved(square, by: [ref(.polygonEdge, 1)], delta: up)
        XCTAssertEqual(result.vertices, [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10, y: 5),
            HorizontalPoint(x: 10, y: 15), HorizontalPoint(x: 0, y: 10),
        ])
        XCTAssertEqual(BoardPolygonParts.reshapedPolygonIDs(by: [ref(.polygonEdge, 1)], in: [square]), ["outline"])
    }

    func testTheLastEdgeRunsBackToTheFirstVertex() {
        let result = moved(square, by: [ref(.polygonEdge, 3)], delta: HorizontalPoint(x: -5, y: 0))
        XCTAssertEqual(result.vertices, [
            HorizontalPoint(x: -5, y: 0), HorizontalPoint(x: 10, y: 0),
            HorizontalPoint(x: 10, y: 10), HorizontalPoint(x: -5, y: 10),
        ])
    }

    func testAVertexTwoSelectedEdgesShareMovesOnce() {
        let refs = [ref(.polygonEdge, 0), ref(.polygonEdge, 1), ref(.polygonVertex, 1)]
        let result = moved(square, by: refs, delta: HorizontalPoint(x: 1, y: 1))
        XCTAssertEqual(result.vertices, [
            HorizontalPoint(x: 1, y: 1), HorizontalPoint(x: 11, y: 1),
            HorizontalPoint(x: 11, y: 11), HorizontalPoint(x: 0, y: 10),
        ])
    }

    func testEveryEdgeAndVertexMovesThePolygonWholeAndOnce() {
        let refs = (0..<4).flatMap { [ref(.polygonEdge, $0), ref(.polygonVertex, $0)] }
        let result = moved(square, by: refs, delta: HorizontalPoint(x: 0, y: 2))
        XCTAssertEqual(result.vertices, square.vertices.map { $0 + HorizontalPoint(x: 0, y: 2) })
        XCTAssertTrue(BoardPolygonParts.reshapedPolygonIDs(by: refs, in: [square]).isEmpty, "it moves whole, so its spans can shift")
    }

    func testAnArcEdgeLeavesItsCentreUnlessTheCentreIsSelected() {
        var arc = square
        arc.polygonVertices[1].type = .arc
        arc.polygonVertices[1].arcCenter = HorizontalPoint(x: 10, y: 5)
        let up = HorizontalPoint(x: 0, y: 3)

        let alone = moved(arc, by: [ref(.polygonEdge, 1)], delta: up)
        XCTAssertEqual(alone.polygonVertices[1].arcCenter, HorizontalPoint(x: 10, y: 5), "the centre stays, as in Horizon")
        let withCentre = moved(arc, by: [ref(.polygonEdge, 1), ref(.polygonArcCenter, 1)], delta: up)
        XCTAssertEqual(withCentre.polygonVertices[1].arcCenter, HorizontalPoint(x: 10, y: 8))

        let edges = (0..<4).map { ref(.polygonEdge, $0) }
        XCTAssertEqual(BoardPolygonParts.reshapedPolygonIDs(by: edges, in: [arc]), ["outline"],
                       "every vertex moves, but the arc's centre stays behind")
        let whole = BoardPolygonParts.wholeSelection(of: arc)
        XCTAssertTrue(whole.contains(HorizontalSelectableRef(
            id: arc.id, type: .polygonArcCenter, vertex: 1, layer: HorizontalBoardLayers.outline
        )), "the polygon's own id, as its selectables carry it")
        XCTAssertTrue(BoardPolygonParts.reshapedPolygonIDs(by: whole, in: [arc]).isEmpty)
        XCTAssertEqual(moved(arc, by: whole, delta: up).polygonVertices.map(\.arcCenter)[1], HorizontalPoint(x: 10, y: 8))
    }

    func testAMirrorTurnsAnArcRoundOnlyWhereItMirrorsItsCentre() {
        var arc = square
        arc.polygonVertices[1].type = .arc
        arc.polygonVertices[1].arcCenter = HorizontalPoint(x: 10, y: 5)
        var polygons = [arc]
        var done = Set<String>()
        // Twice over the same centre: one mirror, one turn round.
        for ref in [ref(.polygonEdge, 1), ref(.polygonArcCenter, 1), ref(.polygonArcCenter, 1)] {
            BoardPolygonParts.change(&polygons, ref: ref, done: &done, mirrorsArcs: true) {
                HorizontalPoint(x: -$0.x, y: $0.y)
            }
        }
        XCTAssertTrue(polygons[0].polygonVertices[1].arcReverse)
        XCTAssertEqual(polygons[0].polygonVertices[1].arcCenter, HorizontalPoint(x: -10, y: 5))
        XCTAssertEqual(polygons[0].polygonVertices[1].position, HorizontalPoint(x: -10, y: 0))
        XCTAssertEqual(polygons[0].polygonVertices[0].position, HorizontalPoint(x: 0, y: 0), "not on the edge")
    }
}
