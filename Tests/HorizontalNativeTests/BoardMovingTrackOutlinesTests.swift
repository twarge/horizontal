import XCTest
@testable import HorizontalNative

/// The selected tracks a move reshapes, an end of theirs staying put, are
/// outlined where the move takes their ends (`BoardMovingTrackOutlines`), and
/// those it carries whole are left to the shift that carries the rest.
final class BoardMovingTrackOutlinesTests: XCTestCase {
    private let pad = HorizontalPoint(x: 0, y: 0)
    private let otherPad = HorizontalPoint(x: 0, y: 2_000_000)
    private let corner = HorizontalPoint(x: 1_000_000, y: 0)
    private let far = HorizontalPoint(x: 1_000_000, y: 1_000_000)

    private func track(_ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint, center: HorizontalPoint? = nil) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 200_000, layer: 0, center: center, netID: "n")
    }

    private func ref(_ id: String, type: HorizontalObjectType = .track) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: type, layer: 0)
    }

    private func board(tracks: [HorizontalSegment], netTies: [HorizontalSegment] = []) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/moving-outlines.hprj"), uuid: "b", name: "moving outlines",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: netTies, lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    /// One end moving, none, or both: only the first two are reshaped.
    func testReshapedAreTheTracksTheMoveDoesNotCarryWhole() {
        var plan = BoardResidentMovePlan()
        plan.segmentMoves[ref("swings")] = BoardResidentSegmentMove(movesTo: true)
        plan.segmentMoves[ref("carried")] = BoardResidentSegmentMove(movesFrom: true, movesTo: true)
        plan.segmentMoves[ref("tie")] = BoardResidentSegmentMove(movesFrom: true)
        let outlines = BoardMovingTrackOutlines(
            selectedRefs: [ref("swings"), ref("stays"), ref("carried"), ref("tie", type: .boardNetTie),
                           HorizontalSelectableRef(id: "j1", type: .junction)],
            plan: plan,
            board: board(
                tracks: [track("swings", pad, corner), track("stays", pad, otherPad), track("carried", corner, far)],
                netTies: [track("tie", corner, far)]
            )
        )
        XCTAssertEqual(outlines.refs, [ref("swings"), ref("stays"), ref("tie", type: .boardNetTie)])
        XCTAssertNil(outlines.tracks.first { $0.ref == ref("stays") }?.move, "neither end of a pad-to-pad track moves")
    }

    /// An arc moving both ends but not its centre is reshaped; with its
    /// centre too it is carried.
    func testAnArcIsCarriedOnlyWithItsCentre() {
        let arc = track("arc", corner, far, center: HorizontalPoint(x: 1_000_000, y: 500_000))
        var plan = BoardResidentMovePlan()
        plan.segmentMoves[ref("arc")] = BoardResidentSegmentMove(movesFrom: true, movesTo: true)
        XCTAssertEqual(BoardMovingTrackOutlines(selectedRefs: [ref("arc")], plan: plan, board: board(tracks: [arc])).refs,
                       [ref("arc")])
        plan.segmentMoves[ref("arc")]?.movesCenter = true
        XCTAssertTrue(BoardMovingTrackOutlines(selectedRefs: [ref("arc")], plan: plan, board: board(tracks: [arc])).isEmpty)
    }

    /// The selectables follow the moving end and leave the pad end; with no
    /// move they are the track's own.
    func testSelectablesFollowTheMovingEndOnly() throws {
        var plan = BoardResidentMovePlan()
        plan.segmentMoves[ref("t1")] = BoardResidentSegmentMove(movesTo: true)
        let t1 = track("t1", pad, corner)
        let outlines = BoardMovingTrackOutlines(selectedRefs: [ref("t1")], plan: plan, board: board(tracks: [t1]))
        let shift = HorizontalPoint(x: 0, y: 500_000)

        let moved = try XCTUnwrap(outlines.selectables(at: HorizontalPlacementTransform(shift: shift, angle: 0, mirrored: false))[ref("t1")])
        let box = try XCTUnwrap(moved.first { !$0.isPoint })
        XCTAssertEqual(box.handlePoints, [pad, corner + shift], "the box runs from the pad to the moved end")
        XCTAssertEqual(moved.first { $0.isPoint }?.center, (pad + corner + shift) * 0.5, "the grab handle is the moved middle")

        let still = try XCTUnwrap(outlines.selectables(at: .identity)[ref("t1")])
        XCTAssertEqual(still.first { !$0.isPoint }?.handlePoints, [pad, corner])
    }

    /// A turn made while moving turns the moving end about the origin as the
    /// scene does, and the arc widths come from the tracks themselves.
    func testMovedEndsFollowTheWholePlacement() {
        let quarter = HorizontalCanvasModeSupport.fullTurnAngle / 4
        let placement = HorizontalPlacementTransform(shift: HorizontalPoint(x: 10, y: 0), angle: quarter, mirrored: false)
        let moved = BoardMovingTrackOutlines.moved(
            track("t1", pad, corner),
            by: BoardResidentSegmentMove(movesTo: true),
            placement: placement
        )
        XCTAssertEqual(moved.from, pad)
        XCTAssertEqual(moved.to, placement.applying(to: corner))

        let arc = track("arc", corner, far, center: HorizontalPoint(x: 1_000_000, y: 500_000))
        let outlines = BoardMovingTrackOutlines(selectedRefs: [ref("arc")], plan: BoardResidentMovePlan(), board: board(tracks: [arc]))
        XCTAssertEqual(outlines.arcWidths, ["arc": 200_000])
    }
}
