import XCTest
@testable import HorizontalNative

/// A route drawn around obstacles with a via armed ends where the via may
/// stand on every layer it spans (`HorizontalRouteFinder.approach` with an
/// `endVia`, and `BoardTrackRouterVia`, which the track tool asks).
///
/// The route's track is on one layer and used to be all that decided where
/// the route ends, so the via riding on its end sat on top of another net's
/// copper on the far side, and next to copper on its own layer at a track's
/// clearance rather than a via's.
final class RouterArmedViaClearanceTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let width = 200_000.0
    private let trackClearance = 150_000.0
    private let viaClearance = 200_000.0
    private let holeClearance = 150_000.0
    private let via = HorizontalRouteEndVia(
        diameter: 600_000, holeDiameter: 300_000,
        layers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper])

    /// How far the via's centre keeps from the centre line of a 0.2 mm track
    /// of another net: half that track, the via's clearance, half the via.
    private var viaKeepOff: Double { 100_000 + viaClearance + via.diameter / 2 }

    private func rules(holeToTrack: Double? = nil) -> HorizontalBoardRules {
        var rules = HorizontalBoardRules.empty
        // The table is symmetric, so each pair is stated once.
        var entries: [[String: Any]] = []
        for other in ["track", "pad", "pad_th"] {
            entries.append(["types": ["track", other], "clearance": Int(trackClearance)])
        }
        for other in ["track", "pad", "pad_th", "via"] {
            entries.append(["types": ["via", other], "clearance": Int(viaClearance)])
            entries.append(["types": ["hole_pth", other], "clearance": Int(holeClearance)])
        }
        if let holeToTrack {
            entries.append(["types": ["hole_pth", "track"], "clearance": Int(holeToTrack)])
        }
        rules.clearanceCopperRules = [HorizontalRuleClearanceCopper(json: [
            "enabled": true, "order": 0, "layer": 10_000,
            "match_1": ["mode": "all"], "match_2": ["mode": "all"],
            "clearances": entries,
        ])]
        return rules
    }

    private func clearances(holeToTrack: Double? = nil) -> HorizontalRouterClearances {
        HorizontalRouterClearances(
            rules: rules(holeToTrack: holeToTrack), netIDForCode: [0: "net-a", 1: "net-b", 2: "net-c"])
    }

    /// A vertical 0.2 mm track across the route's way at x = 5 mm.
    private func wall(layer: Int, net: Int = 2) -> HorizontalRouterWorld.Track {
        .init(id: 1, from: p(5_000_000, -3_000_000), to: p(5_000_000, 3_000_000), center: nil,
              width: 200_000, layer: layer, netCode: net, locked: false)
    }

    private func index(
        tracks: [HorizontalRouterWorld.Track] = [],
        pads: [HorizontalRouterWorld.Solid] = [],
        vias: [HorizontalRouterWorld.Via] = [],
        holes: [HorizontalRouterWorld.UnplatedHole] = []
    ) -> HorizontalRouterIndex {
        var world = HorizontalRouterWorld()
        world.tracks = tracks
        world.solids = pads
        world.vias = vias
        world.unplatedHoles = holes
        return HorizontalRouterIndex(world: world)
    }

    private func approach(
        to: HorizontalPoint, _ index: HorizontalRouterIndex,
        via: HorizontalRouteEndVia?, net: Int = 1,
        clearances: HorizontalRouterClearances? = nil
    ) -> HorizontalRouteFinder.Approach {
        HorizontalRouteFinder.approach(
            from: p(0, 0), to: to, layer: top, net: net, width: width,
            index: index, clearances: clearances ?? self.clearances(), endVia: via)
    }

    /// Re-derives the verdict on a via at `point`, from the index and the
    /// rules alone: how many obstacles of another net it is too close to on a
    /// layer it spans.
    private func viaViolations(
        at point: HorizontalPoint, _ index: HorizontalRouterIndex,
        via: HorizontalRouteEndVia, net: Int = 1,
        clearances: HorizontalRouterClearances? = nil
    ) -> Int {
        let clearances = clearances ?? self.clearances()
        let here = HorizontalOctagon(from: point, to: point, width: 0)
        var count = 0
        for obstacle in index.obstacles where obstacle.netCode != net {
            for layer in via.layers where obstacle.layerMin <= layer && layer <= obstacle.layerMax {
                let copper = clearances.clearance(
                    .via, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer) + via.diameter / 2
                let hole = clearances.clearance(
                    .holePlated, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
                    + via.holeDiameter / 2
                if obstacle.hull.inflated(by: max(copper, hole)).overlaps(here) {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    // MARK: - Copper on another layer

    /// The report: the cursor by another net's track on the far side. The
    /// route's own layer is empty, so only the via stops it, at the via's
    /// clearance from that track.
    func testAnArmedViaKeepsItsClearanceFromAnotherNetsTrackOnAnotherLayer() {
        let board = index(tracks: [wall(layer: bottom)])
        for y in [0.0, 1_000_000, -700_000] {
            let result = approach(to: p(4_980_000, y), board, via: via)

            XCTAssertFalse(result.reachesTarget)
            XCTAssertEqual(result.points.last, p(5_000_000 - viaKeepOff, y),
                           "it should end at the via's clearance from the track, level with the cursor")
            XCTAssertEqual(result.blocker, 0, "it names the track the via stopped at")
        }
    }

    /// Past the track rather than short of it: the track is no obstacle to
    /// the route, only to where its via stands, so the route crosses it.
    func testTheRouteCrossesOtherLayerCopperToWhereItsViaMayStand() throws {
        let board = index(tracks: [wall(layer: bottom)])
        let result = approach(to: p(5_300_000, 0), board, via: via)

        XCTAssertEqual(result.points.last, p(5_000_000 + viaKeepOff, 0),
                       "the nearest place the via may stand is beyond the track")
        XCTAssertEqual(viaViolations(at: try XCTUnwrap(result.points.last), board, via: via), 0)
    }

    /// On the middle of the track the via goes to one side or the other,
    /// whichever, and is legal there.
    func testAViaArmedOnTopOfOtherLayerCopperIsPushedOffIt() throws {
        let board = index(tracks: [wall(layer: bottom)])
        let end = try XCTUnwrap(approach(to: p(5_000_000, 200_000), board, via: via).points.last)

        XCTAssertEqual(abs(end.x - 5_000_000), viaKeepOff)
        XCTAssertEqual(end.y, 200_000)
        XCTAssertEqual(viaViolations(at: end, board, via: via), 0)
    }

    func testWithNoViaArmedOtherLayerCopperIsIgnored() {
        let board = index(tracks: [wall(layer: bottom)])
        for target in [p(4_980_000, 0), p(5_000_000, 200_000), p(8_000_000, 0)] {
            let result = approach(to: target, board, via: nil)

            XCTAssertTrue(result.reachesTarget)
            XCTAssertEqual(result.points.last, target)
            XCTAssertEqual(result.blocker, -1)
        }
    }

    func testSameNetCopperOnAnotherLayerDoesNotBlockTheVia() {
        let board = index(tracks: [wall(layer: bottom, net: 1)])
        for target in [p(4_980_000, 0), p(5_000_000, 200_000)] {
            let result = approach(to: target, board, via: via)

            XCTAssertTrue(result.reachesTarget, "a via onto its own net's copper is what a via is for")
            XCTAssertEqual(result.points.last, target)
        }
    }

    /// A route on no net takes the net of the copper it reaches, and through
    /// its via that of the copper the via lands on; what is merely near stays
    /// an obstacle.
    func testARouteOnNoNetDropsItsViaOntoTheCopperItLandsOn() {
        let board = index(tracks: [wall(layer: bottom)])

        XCTAssertTrue(approach(to: p(5_020_000, 0), board, via: via, net: -1).reachesTarget)
        XCTAssertEqual(approach(to: p(4_800_000, 0), board, via: via, net: -1).points.last,
                       p(5_000_000 - viaKeepOff, 0))
    }

    /// A via that does not reach a layer owes nothing to the copper on it.
    func testAViaThatDoesNotSpanALayerIgnoresItsCopper() {
        let board = index(tracks: [wall(layer: bottom)])
        let blind = HorizontalRouteEndVia(diameter: 600_000, holeDiameter: 300_000, layers: [top, -1])

        XCTAssertTrue(approach(to: p(4_980_000, 0), board, via: blind).reachesTarget)

        let inner = index(tracks: [wall(layer: -1)])
        XCTAssertEqual(approach(to: p(4_980_000, 0), inner, via: blind).points.last,
                       p(5_000_000 - viaKeepOff, 0), "and keeps clear of copper on an inner layer it does span")
    }

    // MARK: - Which clearance

    /// On the route's own layer too: the track may come to a track's
    /// clearance of the copper there, the via only to a via's.
    func testOnTheRoutesOwnLayerTheEndKeepsTheViasClearanceNotTheTracks() {
        let board = index(tracks: [wall(layer: top)])
        let trackKeepOff = 100_000 + trackClearance + width / 2

        XCTAssertEqual(approach(to: p(4_980_000, 0), board, via: nil).points.last,
                       p(5_000_000 - trackKeepOff, 0))
        XCTAssertEqual(approach(to: p(4_980_000, 0), board, via: via).points.last,
                       p(5_000_000 - viaKeepOff, 0))
    }

    /// The via's hole has a rule of its own, and where that asks for more
    /// than the via's copper does, it decides.
    func testTheViasHoleClearanceDecidesWhereItIsTheWider() {
        let board = index(tracks: [wall(layer: bottom)])
        let wide = clearances(holeToTrack: 600_000)
        let result = approach(to: p(4_980_000, 0), board, via: via, clearances: wide)

        XCTAssertEqual(result.points.last, p(5_000_000 - (100_000 + 600_000 + via.holeDiameter / 2), 0))
    }

    /// Pads, vias and unplated holes on the far side, as tracks: each kind of
    /// obstacle the router knows stops the via at the distance the rules give.
    func testPadsViasAndHolesOnOtherLayersKeepTheViaOff() throws {
        let pad = HorizontalRouterWorld.Solid(
            points: [p(4_800_000, -500_000), p(5_800_000, -500_000), p(5_800_000, 500_000), p(4_800_000, 500_000)],
            layerMin: bottom, layerMax: bottom, netCode: 2)
        let padEnd = try XCTUnwrap(approach(to: p(4_790_000, 0), index(pads: [pad]), via: via).points.last)
        XCTAssertEqual(padEnd, p(4_800_000 - viaClearance - via.diameter / 2, 0))

        // A buried via the route's layer never sees.
        let other = HorizontalRouterWorld.Via(
            id: 1, pos: p(5_000_000, 0), layerStart: -1, layerEnd: bottom,
            diameter: 600_000, drill: 300_000, netCode: 2)
        let buried = index(vias: [other])
        XCTAssertTrue(approach(to: p(4_690_000, 0), buried, via: nil).reachesTarget)
        let viaEnd = try XCTUnwrap(approach(to: p(4_690_000, 0), buried, via: via).points.last)
        XCTAssertEqual(viaEnd, p(5_000_000 - 300_000 - viaClearance - via.diameter / 2, 0))

        // An unplated hole stops the track as well; the via stays further.
        let holes = index(holes: [.init(position: p(5_000_000, 0), diameter: 1_000_000)])
        let drilled = clearances()
        let holeEnd = try XCTUnwrap(approach(to: p(4_490_000, 0), holes, via: via).points.last)
        let viaToHole = drilled.clearance(.via, net: 1, .holeUnplated, net: -1, on: bottom) + via.diameter / 2
        let holeToHole = drilled.clearance(.holePlated, net: 1, .holeUnplated, net: -1, on: bottom)
            + via.holeDiameter / 2
        XCTAssertEqual(holeEnd, p(5_000_000 - 500_000 - max(viaToHole, holeToHole), 0))
        XCTAssertEqual(viaViolations(at: holeEnd, holes, via: via), 0)
    }

    // MARK: - A route that cannot reach its goal

    /// Where the search stops short, the route is cut back to the last point
    /// on it the via may stand.
    func testARouteIsCutBackToWhereItsViaMayStand() {
        let board = index(tracks: [wall(layer: bottom)])
        let collider = HorizontalRouteViaCollider(
            index: board, clearances: clearances(), via: via, net: 1)

        XCTAssertEqual(collider.trimmed([p(0, 0), p(4_900_000, 0)]), [p(0, 0), p(5_000_000 - viaKeepOff, 0)])
        XCTAssertEqual(collider.trimmed([p(0, 0), p(4_000_000, 0)]), [p(0, 0), p(4_000_000, 0)],
                       "a route whose end is legal is left alone")
        XCTAssertEqual(
            collider.trimmed([p(0, 0), p(4_700_000, 0), p(4_700_000, 500_000)]),
            [p(0, 0), p(5_000_000 - viaKeepOff, 0)],
            "a last leg the via may stand nowhere on goes entirely")
        XCTAssertEqual(collider.trimmed([p(4_800_000, 0), p(4_900_000, 0)]), [p(4_800_000, 0)],
                       "with nowhere for the via along it, the route lays nothing")
    }

    // MARK: - What the track tool asks

    /// A board with `tracks` and a stub of the route's own net behind its
    /// start, so the route has a net: one on none joins what it lands on.
    private func board(tracks: [HorizontalSegment]) -> HorizontalBoard {
        let stub = HorizontalSegment(
            id: "stub", from: p(-1_000_000, 0), to: p(0, 0), width: 200_000, layer: top, netID: "mine")
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/router-via.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [stub] + tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty)
    }

    private func toolApproach(
        _ session: HorizontalBoardTrackRouterSession, to: HorizontalPoint,
        via: HorizontalBoardViaTemplate?, endsRoute: Bool = false
    ) -> HorizontalRouteFinder.Approach {
        BoardTrackRouterVia.approach(
            session: session, from: p(0, 0), to: to, layer: top, netID: "mine",
            width: width, diagonalFirst: true, via: via, endsRoute: { endsRoute })
    }

    /// Through the session the tool holds, with the board's own rules: the
    /// via the tool drops is a through via, so copper on the bottom of a
    /// two-layer board holds it off, and what the click lays is this route.
    func testTheTrackToolsRouteEndsWhereItsArmedViaIsLegal() throws {
        let under = HorizontalSegment(
            id: "t1", from: p(5_000_000, -3_000_000), to: p(5_000_000, 3_000_000),
            width: 200_000, layer: bottom, netID: "other")
        let session = HorizontalBoardTrackRouterSession(board: board(tracks: [under]))
        let template = HorizontalBoardViaTemplate(padstackID: "v", diameter: 600_000, holeDiameter: 300_000)
        let target = p(4_980_000, 0)

        XCTAssertEqual(toolApproach(session, to: target, via: nil).points.last, target,
                       "with no via armed the far side is none of the route's business")

        let mine = session.netCode(for: "mine"), other = session.netCode(for: "other")
        let keepOff = 100_000 + max(
            session.clearances.clearance(.via, net: mine, .track, net: other, on: bottom) + 300_000,
            session.clearances.clearance(.holePlated, net: mine, .track, net: other, on: bottom) + 150_000)
        let armed = toolApproach(session, to: target, via: template)
        XCTAssertFalse(armed.reachesTarget)
        XCTAssertEqual(armed.points.last, p(5_000_000 - keepOff, 0))

        // Asked again, as the preview, the inspector and the click each ask.
        XCTAssertEqual(toolApproach(session, to: target, via: template).points, armed.points)
    }

    /// A click that ends the route drops no via, so the route still gets
    /// there over what lies under it; one that would end it but cannot arrive
    /// stops on bare board, where the via drops and must be legal.
    func testAClickThatEndsTheRouteIsNotHeldToWhereAViaMayStand() {
        let under = HorizontalSegment(
            id: "t1", from: p(5_000_000, -3_000_000), to: p(5_000_000, 3_000_000),
            width: 200_000, layer: bottom, netID: "other")
        let template = HorizontalBoardViaTemplate(padstackID: "v", diameter: 600_000, holeDiameter: 300_000)
        let session = HorizontalBoardTrackRouterSession(board: board(tracks: [under]))

        XCTAssertEqual(
            toolApproach(session, to: p(4_980_000, 0), via: template, endsRoute: true).points.last,
            p(4_980_000, 0))

        // Another net's track on the route's own layer: the route stops
        // short of it, and the via it then drops keeps a via's distance.
        let across = HorizontalSegment(
            id: "t2", from: p(5_000_000, -3_000_000), to: p(5_000_000, 3_000_000),
            width: 200_000, layer: top, netID: "other")
        let blocked = HorizontalBoardTrackRouterSession(board: board(tracks: [across]))
        let plain = toolApproach(blocked, to: p(4_980_000, 0), via: nil)
        let ending = toolApproach(blocked, to: p(4_980_000, 0), via: template, endsRoute: true)
        let armed = toolApproach(blocked, to: p(4_980_000, 0), via: template)

        XCTAssertFalse(plain.reachesTarget)
        XCTAssertEqual(ending.points, armed.points)
        XCTAssertLessThan(armed.points.last?.x ?? .infinity, plain.points.last?.x ?? 0,
                          "the via stays further from the track than the track's own end would")
    }
}
