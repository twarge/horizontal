import Foundation
import XCTest
@testable import HorizontalNative

/// A via armed on a route drops in a pad of the route's net when clicked
/// there, at the point clicked, so an exposed pad takes ground vias: the click
/// is not snapped to the pad's centre, and does not end the route in the pad.
/// A pad of another net, or one with a hole, takes the route as before.
final class BoardViaInPadTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let gnd = "6d1f3c2a-0b4e-4f6a-8c1d-2e3f4a5b6c7d"
    private let via = HorizontalBoardViaTemplate(padstackID: "route-via", diameter: 500_000, holeDiameter: 200_000)

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// A two-layer board with a 4 mm exposed ground pad on top, centred at
    /// (10, 10).
    private func boardWithExposedPad() -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/via-in-pad.hprj"), uuid: "b", name: "via-in-pad",
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
        board.packagePadPositions["pkg/ep"] = point(10, 10)
        board.packagePads.append(HorizontalPolygon(
            id: "pkg/pad/ep", vertices: [point(8, 8), point(12, 8), point(12, 12), point(8, 12)], layer: top))
        return board
    }

    private func lay(
        from head: BoardTrackRouteHead, to target: HorizontalPoint, on board: inout HorizontalBoard
    ) -> BoardTrackLoopStepResult {
        BoardTrackLoops.lay(
            BoardTrackRouting.route(from: head.anchor, to: target, horizontalFirst: true, cornerStyle: .ninety),
            to: target, endsOnPad: false, via: via, from: head,
            loopStart: nil, routeTrackIDs: [], removesLoops: true, on: &board)
    }

    func testAnArmedViaDropsInAPadOfTheRoutesNetAndNotInAnothersOrOneWithAHole() {
        let center = point(10, 10)
        XCTAssertTrue(BoardTrackRouting.viaDropsInPad(
            center: center, padNetID: gnd.uppercased(), routeNetID: gnd, packageHoles: []))
        XCTAssertTrue(BoardTrackRouting.viaDropsInPad(
            center: center, padNetID: gnd, routeNetID: nil, packageHoles: []), "a route with no net yet takes the pad's")
        XCTAssertTrue(BoardTrackRouting.viaDropsInPad(
            center: center, padNetID: nil, routeNetID: gnd, packageHoles: []))
        XCTAssertFalse(BoardTrackRouting.viaDropsInPad(
            center: center, padNetID: "another-net", routeNetID: gnd, packageHoles: []))
        let hole = HorizontalHole(id: "h", position: center, diameter: 800_000, plated: true, netID: gnd)
        XCTAssertFalse(BoardTrackRouting.viaDropsInPad(
            center: center, padNetID: gnd, routeNetID: gnd, packageHoles: [hole]), "a through-hole pad needs no via")
        let elsewhere = HorizontalHole(id: "h", position: point(30, 30), diameter: 800_000, plated: true, netID: gnd)
        XCTAssertTrue(BoardTrackRouting.viaDropsInPad(
            center: center, padNetID: gnd, routeNetID: gnd, packageHoles: [elsewhere]))
    }

    /// A route from outside the pad, clicked into it off its centre: the via
    /// goes where the click was, and the route goes on from it on the bottom.
    func testAClickInAPadOffItsCentreDropsTheViaWhereItWasClicked() throws {
        var board = boardWithExposedPad()
        let start = point(0, 11), inPad = point(11, 11)
        let head = BoardTrackRouteHead(
            anchor: start, anchorJunctionID: nil, anchorOnPad: false, netID: gnd,
            width: 200_000, layer: top, placesVia: true)
        let step = lay(from: head, to: inPad, on: &board)

        XCTAssertEqual(step.laid.vias, 1)
        XCTAssertFalse(step.endsRoute, "the route goes on from the via")
        XCTAssertEqual(board.vias.map(\.position), [inPad], "not at the pad's centre")
        XCTAssertEqual(board.vias.first?.netID, gnd)
        XCTAssertEqual(step.laid.head.anchor, inPad)
        XCTAssertEqual(step.laid.head.layer, bottom)
        let junction = try XCTUnwrap(step.laid.head.anchorJunctionID)
        XCTAssertEqual(board.junctions[junction], inPad)
    }

    /// A route started on the pad, which is at its centre, takes a via
    /// elsewhere in the pad, on a track from the centre.
    func testARouteStartedOnThePadDropsAViaElsewhereInIt() {
        var board = boardWithExposedPad()
        let inPad = point(9, 10)
        let head = BoardTrackRouteHead(
            anchor: point(10, 10), anchorJunctionID: nil, anchorOnPad: true, netID: gnd,
            width: 200_000, layer: top, placesVia: true)
        let step = lay(from: head, to: inPad, on: &board)

        XCTAssertEqual(step.laid.vias, 1)
        XCTAssertEqual(board.vias.map(\.position), [inPad])
        XCTAssertEqual(board.tracks.count, 1, "one leg, from the pad's centre to the via")
        XCTAssertFalse(board.junctions.values.contains(point(10, 10)), "the pad takes the track with no junction")
    }

    /// At the pad's very centre too, where the cursor snaps: the via drops
    /// there rather than the route ending in the pad.
    func testAClickOnAPadsCentreDropsTheViaThere() {
        var board = boardWithExposedPad()
        let head = BoardTrackRouteHead(
            anchor: point(0, 10), anchorJunctionID: nil, anchorOnPad: false, netID: gnd,
            width: 200_000, layer: top, placesVia: true)
        let step = lay(from: head, to: point(10, 10), on: &board)
        XCTAssertEqual(step.laid.vias, 1)
        XCTAssertEqual(board.vias.map(\.position), [point(10, 10)])
    }
}
