import Foundation
import XCTest
@testable import HorizontalNative

/// Tracks that run on along one line are one track
/// (`HorizontalBoard.mergeCollinearTracks`): a route clicked several times
/// along a line, at any angle, and the two tracks either side of a via once
/// the via is taken out. Nothing merges across a point where something else
/// connects, or between tracks that differ in layer, net or width.
///
/// The route tool laid a track per click and nothing ever joined them, and a
/// via deleted from the middle of a run left its two tracks.
final class TrackCollinearMergeTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let net = "5a3e1c2b-7d4f-4e6a-9b8c-1d2e3f4a5b6c"
    private let otherNet = "6b4f2d3c-8e5a-4f7b-8c9d-2e3f4a5b6c7d"

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func emptyBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/track-merge.hprj"), uuid: "b", name: "track-merge",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    /// A track drawn as the tool draws one, its ends on junctions.
    private func track(
        _ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint,
        layer: Int? = nil, net: String? = nil, width: Double = 200_000, locked: Bool = false,
        on board: inout HorizontalBoard
    ) {
        let layer = layer ?? top
        let net = net ?? self.net
        let fromJunction = BoardTrackRouting.mergeJunctions(at: from, preferredID: nil, netID: net, layer: layer, board: &board)
        let toJunction = BoardTrackRouting.mergeJunctions(at: to, preferredID: nil, netID: net, layer: layer, board: &board)
        board.tracks.append(HorizontalSegment(
            id: id, from: from, to: to, width: width, layer: layer, netID: net,
            fromJunctionID: fromJunction, toJunctionID: toJunction, locked: locked))
    }

    private func via(_ id: String, at point: HorizontalPoint, on board: inout HorizontalBoard) {
        BoardTrackRouting.mergeJunctions(at: point, preferredID: nil, netID: net, board: &board)
        board.vias.append(HorizontalMarker(
            id: id, position: point, size: 500_000, holeSize: 200_000, layer: nil,
            connectedLayers: [top, bottom], netID: net, netSetID: net))
        board.viaHoles.append(HorizontalHole(
            id: "\(id)/hole", position: point, diameter: 200_000, length: 200_000,
            shape: .round, plated: true, netID: net))
    }

    /// A route clicked through `points` in straight legs, as the route tool
    /// lays one, and then ended, as its commit ends it.
    private func route(_ points: [HorizontalPoint], on board: inout HorizontalBoard) {
        let original = board
        let start = points[0]
        var head = BoardTrackRouteHead(
            anchor: start,
            anchorJunctionID: BoardTrackRouting.junctionID(at: start, layer: top, in: board),
            anchorOnPad: false, netID: net, width: 200_000, layer: top, placesVia: false)
        var loopStart = BoardTrackLoops.start(at: start, layer: top, onPad: false, in: board)
        var routeIDs = Set<String>()
        for target in points.dropFirst() {
            let step = BoardTrackLoops.lay(
                [BoardTrackSegmentSpec(from: head.anchor, to: target, center: nil)],
                to: target, endsOnPad: false, via: nil, from: head,
                loopStart: loopStart, routeTrackIDs: routeIDs, removesLoops: true, on: &board)
            head = step.laid.head
            loopStart = step.loopStart
            routeIDs = step.routeTrackIDs
        }
        board.mergeCollinearTracks(laidSince: original)
    }

    private func ends(_ track: HorizontalSegment) -> Set<HorizontalPoint> {
        [track.from, track.to]
    }

    // MARK: - A route clicked along a line

    func testClicksAlongAHorizontalLineLayOneTrack() {
        var board = emptyBoard()
        route([point(0, 0), point(5, 0), point(12, 0), point(20, 0)], on: &board)
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(20, 0)])
        XCTAssertEqual(Set(board.junctions.values), [point(0, 0), point(20, 0)], "the junctions between go with the merge")
        XCTAssertEqual(
            Set([board.tracks[0].fromJunctionID, board.tracks[0].toJunctionID].compactMap { $0 }),
            Set(board.junctions.keys), "and the track's ends are on the two left")
    }

    func testClicksAlongAVerticalLineLayOneTrack() {
        var board = emptyBoard()
        route([point(3, 0), point(3, -4), point(3, -9)], on: &board)
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertEqual(ends(board.tracks[0]), [point(3, 0), point(3, -9)])
    }

    func testClicksAlongADiagonalLayOneTrack() {
        var board = emptyBoard()
        route([point(0, 0), point(2, 2), point(7, 7), point(10, 10)], on: &board)
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(10, 10)])
    }

    func testClicksAlongALineAtAnArbitraryAngleLayOneTrack() {
        var board = emptyBoard()
        // A slope of 3 in 7, which no compass direction is.
        route([point(0, 0), point(7, 3), point(21, 9), point(28, 12)], on: &board)
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(28, 12)])
        XCTAssertEqual(board.junctions.count, 2)
    }

    func testARouteThatTurnsKeepsATrackEachSideOfTheCorner() {
        var board = emptyBoard()
        route([point(0, 0), point(5, 0), point(10, 0), point(10, 4), point(10, 8)], on: &board)
        XCTAssertEqual(board.tracks.count, 2)
        XCTAssertEqual(
            Set(board.tracks.map(ends)), [[point(0, 0), point(10, 0)], [point(10, 0), point(10, 8)]])
    }

    func testARouteThatDoublesBackOverItselfIsNotMerged() {
        var board = emptyBoard()
        route([point(0, 0), point(10, 0), point(4, 0)], on: &board)
        XCTAssertEqual(board.tracks.count, 2, "back along the line is not on along it")
    }

    func testARouteCarriedStraightOnFromATracksEndBecomesPartOfIt() {
        var board = emptyBoard()
        track("old", point(0, 0), point(10, 0), on: &board)
        route([point(10, 0), point(15, 0), point(20, 0)], on: &board)
        XCTAssertEqual(board.tracks.map(\.id), ["old"], "the track that was there is the one kept")
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(20, 0)])
    }

    func testARouteOffTheMiddleOfATrackLeavesItCutThere() {
        var board = emptyBoard()
        track("old", point(0, 0), point(20, 0), on: &board)
        route([point(10, 0), point(10, 5), point(10, 9)], on: &board)
        XCTAssertEqual(board.tracks.count, 3, "the two halves stay two: the route joins them where they meet")
        XCTAssertTrue(board.tracks.contains { ends($0) == [point(10, 0), point(10, 9)] }, "and the route is one track")
    }

    // MARK: - A via taken out of a run

    /// The via and its hole taken off, as a delete takes them, and the
    /// tracks merged where it stood, as the canvas's delete then does.
    private func deleteVia(_ id: String, from board: inout HorizontalBoard) -> [String: String] {
        let position = board.vias.first { $0.id == id }?.position
        BoardTrackLoops.remove(tracks: [], vias: [id], from: &board)
        return board.mergeCollinearTracks(at: [position].compactMap { $0 })
    }

    func testAViaTakenOutOfAStraightRunLeavesOneTrack() {
        var board = emptyBoard()
        track("left", point(0, 0), point(10, 0), on: &board)
        track("right", point(10, 0), point(20, 0), on: &board)
        via("v", at: point(10, 0), on: &board)
        XCTAssertTrue(board.mergeCollinearTracks(at: [point(10, 0)]).isEmpty, "nothing merges through a via")
        XCTAssertEqual(board.tracks.count, 2)

        let merged = deleteVia("v", from: &board)
        XCTAssertEqual(merged, ["right": "left"])
        XCTAssertEqual(board.tracks.map(\.id), ["left"])
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(20, 0)])
        XCTAssertEqual(Set(board.junctions.values), [point(0, 0), point(20, 0)])
    }

    func testAViaTakenOutOfADiagonalRunLeavesOneTrackWhicheverWayItsTracksWereDrawn() {
        var board = emptyBoard()
        // Both drawn towards the via.
        track("a", point(0, 0), point(6, 6), on: &board)
        track("b", point(15, 15), point(6, 6), on: &board)
        via("v", at: point(6, 6), on: &board)
        _ = deleteVia("v", from: &board)
        XCTAssertEqual(board.tracks.map(\.id), ["a"])
        XCTAssertEqual(board.tracks[0].from, point(0, 0))
        XCTAssertEqual(board.tracks[0].to, point(15, 15))
    }

    func testAViaTakenOutOfARunAtAnArbitraryAngleLeavesOneTrack() {
        var board = emptyBoard()
        track("a", point(0, 0), point(5, 2), on: &board)
        track("b", point(5, 2), point(20, 8), on: &board)
        via("v", at: point(5, 2), on: &board)
        _ = deleteVia("v", from: &board)
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(20, 8)])
    }

    func testAViaTakenOffACornerLeavesBothTracks() {
        var board = emptyBoard()
        track("a", point(0, 0), point(10, 0), on: &board)
        track("b", point(10, 0), point(10, 10), on: &board)
        via("v", at: point(10, 0), on: &board)
        XCTAssertTrue(deleteVia("v", from: &board).isEmpty)
        XCTAssertEqual(board.tracks.count, 2)
        XCTAssertTrue(board.junctions.values.contains(point(10, 0)), "and the junction they share")
    }

    func testAViaTakenFromBetweenTracksOnTwoLayersLeavesBoth() {
        var board = emptyBoard()
        track("a", point(0, 0), point(10, 0), on: &board)
        track("b", point(10, 0), point(20, 0), layer: bottom, on: &board)
        via("v", at: point(10, 0), on: &board)
        XCTAssertTrue(deleteVia("v", from: &board).isEmpty)
        XCTAssertEqual(board.tracks.count, 2)
    }

    // MARK: - What keeps two tracks apart

    private func run(
        _ change: (inout HorizontalBoard) -> Void = { _ in },
        second: (width: Double, net: String?, locked: Bool) = (200_000, nil, false)
    ) -> HorizontalBoard {
        var board = emptyBoard()
        track("a", point(0, 0), point(10, 0), on: &board)
        track("b", point(10, 0), point(20, 0), net: second.net, width: second.width, locked: second.locked, on: &board)
        change(&board)
        board.mergeCollinearTracks(at: [point(10, 0)])
        return board
    }

    func testTwoTracksAloneOnALineMerge() {
        XCTAssertEqual(run().tracks.count, 1)
    }

    func testTracksOfTwoWidthsStayTwo() {
        XCTAssertEqual(run(second: (300_000, nil, false)).tracks.count, 2)
    }

    func testTracksOnTwoNetsStayTwo() {
        XCTAssertEqual(run(second: (200_000, otherNet, false)).tracks.count, 2)
    }

    func testALockedTrackIsLeftAsItIs() {
        XCTAssertEqual(run(second: (200_000, nil, true)).tracks.count, 2)
    }

    func testAThirdTrackAtThePointKeepsThemApart() {
        let board = run { self.track("c", self.point(10, 0), self.point(10, 10), on: &$0) }
        XCTAssertEqual(board.tracks.count, 3)
    }

    func testATrackOnAnotherLayerEndingAtThePointKeepsThemApart() {
        let board = run { self.track("c", self.point(10, 0), self.point(10, 10), layer: self.bottom, on: &$0) }
        XCTAssertEqual(board.tracks.count, 3)
    }

    func testAPadAtThePointKeepsThemApart() {
        let board = run { $0.packagePadPositions["pkg/1"] = self.point(10, 0) }
        XCTAssertEqual(board.tracks.count, 2)
    }

    func testANetTieEndingAtThePointKeepsThemApart() {
        let board = run {
            $0.netTies.append(HorizontalSegment(
                id: "tie", from: self.point(10, 0), to: self.point(10, 3), width: 200_000, layer: self.top))
        }
        XCTAssertEqual(board.tracks.count, 2)
    }

    func testAnArcTrackIsNotMergedIntoAStraightOne() {
        var board = emptyBoard()
        track("a", point(0, 0), point(10, 0), on: &board)
        track("b", point(10, 0), point(20, 0), on: &board)
        board.tracks[1].center = point(15, 0)
        board.mergeCollinearTracks(at: [point(10, 0)])
        XCTAssertEqual(board.tracks.count, 2)
    }

    func testAPointOffTheLineByMoreThanTheToleranceIsACorner() {
        var board = emptyBoard()
        // Ten nanometres off a 20 mm line.
        let bend = HorizontalPoint(x: 10 * mm, y: 10)
        track("a", point(0, 0), bend, on: &board)
        track("b", bend, point(20, 0), on: &board)
        board.mergeCollinearTracks(at: [bend])
        XCTAssertEqual(board.tracks.count, 2)
    }

    func testAPointRoundedOntoALineAtAnAngleStillMerges() {
        var board = emptyBoard()
        // A third of the way along a line of slope 1 in 3, to the nanometre.
        let cut = HorizontalPoint(x: 1_000_000, y: 333_333)
        track("a", point(0, 0), cut, on: &board)
        track("b", cut, point(3, 1), on: &board)
        board.mergeCollinearTracks(at: [cut])
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertEqual(ends(board.tracks[0]), [point(0, 0), point(3, 1)])
    }

    func testALineOnTheJunctionKeepsItWhenTheTracksMerge() {
        var board = emptyBoard()
        track("a", point(0, 0), point(10, 0), on: &board)
        track("b", point(10, 0), point(20, 0), on: &board)
        board.lines.append(HorizontalSegment(id: "silk", from: point(10, 0), to: point(10, 5), width: 150_000, layer: 20))
        board.mergeCollinearTracks(at: [point(10, 0)])
        XCTAssertEqual(board.tracks.count, 1)
        XCTAssertTrue(board.junctions.values.contains(point(10, 0)))
    }
}
