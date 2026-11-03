import XCTest
@testable import HorizontalNative

/// A selected object marks its parts that select on their own, and a click on
/// one of those marks picks it ahead of anything else under the cursor: a
/// polygon's vertices and arc centres, the junctions a track, line or arc ends
/// on, a dimension's two points and its label. A dimension's parts are
/// Horizon's three selectables, and move as Horizon's move tool moves them.
final class BoardSelectionVerticesTests: XCTestCase {
    private static let mm = 1_000_000.0

    private func board(
        junctions: [String: HorizontalPoint] = [:],
        tracks: [HorizontalSegment] = [],
        lines: [HorizontalSegment] = [],
        arcs: [HorizontalArc] = [],
        polygons: [HorizontalPolygon] = [],
        dimensions: [HorizontalDimension] = []
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/vertices.hprj"), uuid: "b", name: "vertices",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: lines, arcs: arcs, connectionLines: [], airwires: [],
            polygons: polygons,
            planes: [], keepouts: [], dimensions: dimensions, decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * Self.mm, y: y * Self.mm)
    }

    private func junction(_ id: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .junction)
    }

    private let dimension = HorizontalDimension(
        id: "D", p0: HorizontalPoint(x: 0, y: 0), p1: HorizontalPoint(x: 10_000_000, y: 0),
        labelDistance: 1_000_000, labelSize: 1_500_000, mode: .distance
    )

    // MARK: What a selection marks

    func testASelectedTrackMarksTheJunctionsAtBothItsEnds() {
        let track = HorizontalSegment(
            id: "T", from: point(0, 0), to: point(5, 0), width: 250_000, layer: HorizontalBoardLayers.topCopper,
            fromJunctionID: "J1", toJunctionID: "J2"
        )
        let board = board(junctions: ["J1": point(0, 0), "J2": point(5, 0)], tracks: [track])
        let selected = [HorizontalSelectableRef(id: "t", type: .track, layer: HorizontalBoardLayers.topCopper)]
        XCTAssertEqual(BoardSelectionVertices.refs(of: selected, in: board), [junction("J1"), junction("J2")])
    }

    func testATrackEndOnAPadMarksNothingThere() {
        // The file names no junction for an end on a pad, and none is there.
        let track = HorizontalSegment(
            id: "T", from: point(0, 0), to: point(5, 0), width: 250_000, layer: HorizontalBoardLayers.topCopper,
            fromJunctionID: nil, toJunctionID: "J2"
        )
        let board = board(junctions: ["J2": point(5, 0)], tracks: [track])
        let selected = [HorizontalSelectableRef(id: "T", type: .track, layer: HorizontalBoardLayers.topCopper)]
        XCTAssertEqual(BoardSelectionVertices.refs(of: selected, in: board), [junction("J2")])
    }

    func testATrackEndNamingNoJunctionTakesTheOneAtItsPoint() {
        // A track drawn here and not yet saved names none.
        let track = HorizontalSegment(
            id: "T", from: point(0, 0), to: point(5, 0), width: 250_000, layer: HorizontalBoardLayers.topCopper
        )
        let board = board(junctions: ["J1": point(0, 0), "J2": point(5, 0)], tracks: [track])
        let selected = [HorizontalSelectableRef(id: "T", type: .track, layer: HorizontalBoardLayers.topCopper)]
        XCTAssertEqual(BoardSelectionVertices.refs(of: selected, in: board), [junction("J1"), junction("J2")])
    }

    func testALineAndAnArcMarkTheJunctionsTheyEndOnAndTheArcsCentre() {
        let silk = HorizontalBoardLayers.topSilkscreen
        let line = HorizontalSegment(id: "L", from: point(0, 0), to: point(5, 0), width: 150_000, layer: silk)
        let arc = HorizontalArc(id: "A", from: point(5, 0), to: point(0, 5), center: point(0, 0), width: 150_000, layer: silk)
        let board = board(
            junctions: ["J1": point(0, 0), "J2": point(5, 0), "J3": point(0, 5)],
            lines: [line], arcs: [arc]
        )
        let selected = [
            HorizontalSelectableRef(id: "L", type: .boardLine, layer: silk),
            HorizontalSelectableRef(id: "A", type: .boardArc, layer: silk),
        ]
        XCTAssertEqual(BoardSelectionVertices.refs(of: selected, in: board),
                       [junction("J1"), junction("J2"), junction("J3")], "each junction once")
    }

    func testAnyPartOfAPolygonMarksAllItsVerticesAndArcCentres() {
        let layer = HorizontalBoardLayers.outline
        var outline = HorizontalPolygon(id: "Outline", vertices: [point(0, 0), point(10, 0), point(10, 10)], layer: layer, netID: nil)
        outline.polygonVertices[1].type = .arc
        outline.polygonVertices[1].arcCenter = point(10, 5)
        let board = board(polygons: [outline])
        let edge = HorizontalSelectableRef(id: "outline", type: .polygonEdge, vertex: 2, layer: layer)
        let vertex = HorizontalSelectableRef(id: "Outline", type: .polygonVertex, vertex: 0, layer: layer)
        let expected = [
            HorizontalSelectableRef(id: "Outline", type: .polygonVertex, vertex: 0, layer: layer),
            HorizontalSelectableRef(id: "Outline", type: .polygonVertex, vertex: 1, layer: layer),
            HorizontalSelectableRef(id: "Outline", type: .polygonArcCenter, vertex: 1, layer: layer),
            HorizontalSelectableRef(id: "Outline", type: .polygonVertex, vertex: 2, layer: layer),
        ]
        XCTAssertEqual(BoardSelectionVertices.refs(of: [edge], in: board), expected)
        XCTAssertEqual(BoardSelectionVertices.refs(of: [edge, vertex], in: board), expected, "the polygon once, whatever of it is selected")
    }

    func testAnyPartOfADimensionMarksAllThree() {
        let board = board(dimensions: [dimension])
        let parts = (0...2).map { BoardDimensionParts.ref(dimension, $0) }
        XCTAssertEqual(BoardSelectionVertices.refs(of: [parts[2]], in: board), parts)
        XCTAssertEqual(BoardSelectionVertices.refs(of: [parts[0]], in: board), parts)
    }

    func testWhatHasNoPartsOfItsOwnMarksNothing() {
        let board = board(junctions: ["J1": point(0, 0)])
        XCTAssertEqual(BoardSelectionVertices.refs(of: [junction("J1")], in: board), [])
        XCTAssertEqual(BoardSelectionVertices.refs(of: [HorizontalSelectableRef(id: "P", type: .boardPackage)], in: board), [])
    }

    // MARK: What a click on the marks picks

    func testAClickPicksTheNearestMarkWithinReachAndNothingBeyond() {
        let marks = [
            HorizontalSelectable.point(ref: junction("A"), at: point(0, 0)),
            HorizontalSelectable.point(ref: junction("B"), at: point(1, 0)),
        ]
        let reach = 1.4 * Self.mm   // the hit box's width: a click within 0.7 mm
        XCTAssertEqual(BoardSelectionVertices.pick(at: point(0.6, 0), among: marks, expand: reach), junction("B"))
        XCTAssertEqual(BoardSelectionVertices.pick(at: point(0.4, 0.2), among: marks, expand: reach), junction("A"))
        XCTAssertNil(BoardSelectionVertices.pick(at: point(0.5, 1), among: marks, expand: reach))
    }

    func testAPointMarkWinsOverABoxItSitsInAndTheBoxTakesTheRest() {
        let box = HorizontalSelectable.bounds(
            ref: BoardDimensionParts.ref(dimension, BoardDimensionParts.label),
            points: [point(0, 0), point(4, 2)], fallbackCenter: point(0, 0), fallbackSize: 0
        )
        let marks = [box, HorizontalSelectable.point(ref: junction("A"), at: point(1, 1))]
        let reach = 1.4 * Self.mm
        XCTAssertEqual(BoardSelectionVertices.pick(at: point(1.2, 1), among: marks, expand: reach), junction("A"))
        XCTAssertEqual(BoardSelectionVertices.pick(at: point(3, 1), among: marks, expand: reach), box.ref)
    }

    // MARK: A dimension's parts

    func testADimensionIsItsTwoPointsAndALabelWhoseOriginStartsTheDimensionLine() throws {
        let selectables = BoardDimensionParts.selectables(for: dimension)
        XCTAssertEqual(selectables.map(\.ref.vertex).sorted(), [0, 1, 2])
        let start = try XCTUnwrap(selectables.first { $0.ref.vertex == BoardDimensionParts.start })
        let end = try XCTUnwrap(selectables.first { $0.ref.vertex == BoardDimensionParts.end })
        XCTAssertTrue(start.isPoint && end.isPoint)
        XCTAssertEqual(start.center, dimension.p0)
        XCTAssertEqual(end.center, dimension.p1)

        let label = try XCTUnwrap(selectables.first { $0.ref.vertex == BoardDimensionParts.label })
        XCTAssertEqual(label.center, point(0, 1), "Horizon's q0: p0 off by the label distance")
        XCTAssertEqual(label.anchorSnapPoints, [point(0, 1)])
        let text = try XCTUnwrap(dimension.labelText)
        XCTAssertTrue(label.inside(text.position), "the box is round the label's text")
        XCTAssertFalse(label.inside(dimension.p0), "the box is the label's, not the whole dimension's")
    }

    func testADimensionThatMeasuresNothingHasNoLabelToSelect() {
        var empty = dimension
        empty.p1 = empty.p0
        XCTAssertEqual(BoardDimensionParts.selectables(for: empty).map(\.ref.vertex), [0, 1])
    }

    func testAPointMovesAlone() {
        let delta = point(1, 2)
        let moved = BoardDimensionParts.moved(dimension, parts: [BoardDimensionParts.end], by: delta)
        XCTAssertEqual(moved.p0, dimension.p0)
        XCTAssertEqual(moved.p1, dimension.p1 + delta)
        XCTAssertEqual(moved.labelDistance, dimension.labelDistance)
        XCTAssertFalse(BoardDimensionParts.movesWhole([BoardDimensionParts.end]))
    }

    func testTheLabelMovesOnlyAcrossTheDimension() {
        let moved = BoardDimensionParts.moved(dimension, parts: [BoardDimensionParts.label], by: point(3, 2))
        XCTAssertEqual(moved.p0, dimension.p0)
        XCTAssertEqual(moved.p1, dimension.p1)
        XCTAssertEqual(moved.labelDistance, 3 * Self.mm, accuracy: 1, "the 2 mm across it, not the 3 mm along it")

        var vertical = dimension
        vertical.mode = .vertical
        vertical.p1 = point(5, 8)
        let across = BoardDimensionParts.moved(vertical, parts: [BoardDimensionParts.label], by: point(2, 5))
        XCTAssertEqual(across.labelDistance, 3 * Self.mm, accuracy: 1, "a vertical dimension's label moves in x")
    }

    func testWithAPointSelectedTheLabelKeepsItsDistanceAndBothPointsMoveItWhole() {
        let delta = point(1, 1)
        let pointAndLabel = BoardDimensionParts.moved(
            dimension, parts: [BoardDimensionParts.start, BoardDimensionParts.label], by: delta
        )
        XCTAssertEqual(pointAndLabel.p0, dimension.p0 + delta)
        XCTAssertEqual(pointAndLabel.labelDistance, dimension.labelDistance)

        let all: Set<Int> = [BoardDimensionParts.start, BoardDimensionParts.end, BoardDimensionParts.label]
        XCTAssertTrue(BoardDimensionParts.movesWhole(all))
        let whole = BoardDimensionParts.moved(dimension, parts: all, by: delta)
        XCTAssertEqual(whole.p0, dimension.p0 + delta)
        XCTAssertEqual(whole.p1, dimension.p1 + delta)
        XCTAssertEqual(whole.labelDistance, dimension.labelDistance)
    }
}
