import XCTest
@testable import HorizontalNative

/// A route that ends as near its target as the rules let it
/// (`HorizontalRouteFinder.approach`), which the track tool previews and lays.
///
/// The cursor over another net's copper, or in the clearance round it, used to
/// exempt that copper from the route — the exemption a route needs for the pad
/// it starts in — so the route was drawn straight into it. These check that the
/// route now stops at the edge instead, at the nearest point it legally can, and
/// that the cases the exemption is for still get it.
final class RouterApproachTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private let width = 200_000.0
    private let clearance = 150_000.0
    /// How far a route's centre line keeps from a 0.2 mm track's centre line:
    /// half the other track, the clearance, half the route.
    private var trackKeepOff: Double { 100_000 + clearance + width / 2 }

    private var clearances: HorizontalRouterClearances {
        var rules = HorizontalBoardRules.empty
        rules.clearanceCopperRules = [HorizontalRuleClearanceCopper(json: [
            "enabled": true, "order": 0, "layer": 10_000,
            "match_1": ["mode": "all"], "match_2": ["mode": "all"],
            "clearances": [
                ["types": ["track", "track"], "clearance": Int(clearance)],
                ["types": ["track", "pad"], "clearance": Int(clearance)],
                ["types": ["track", "via"], "clearance": Int(clearance)],
            ],
        ])]
        return HorizontalRouterClearances(
            rules: rules, netIDForCode: [0: "net-a", 1: "net-b", 2: "net-c"])
    }

    private func track(_ id: Int64, _ a: HorizontalPoint, _ b: HorizontalPoint,
                       net: Int = 2) -> HorizontalRouterWorld.Track {
        .init(id: id, from: a, to: b, center: nil, width: 200_000,
              layer: 0, netCode: net, locked: false)
    }

    private func pad(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                     net: Int) -> HorizontalRouterWorld.Solid {
        .init(points: [p(minX, minY), p(maxX, minY), p(maxX, maxY), p(minX, maxY)],
              layerMin: 0, layerMax: 0, netCode: net)
    }

    private func index(
        _ tracks: [HorizontalRouterWorld.Track], pads: [HorizontalRouterWorld.Solid] = []
    ) -> HorizontalRouterIndex {
        var world = HorizontalRouterWorld()
        world.tracks = tracks
        world.solids = pads
        return HorizontalRouterIndex(world: world)
    }

    private func approach(
        from: HorizontalPoint, to: HorizontalPoint,
        _ index: HorizontalRouterIndex, net: Int = 1
    ) -> HorizontalRouteFinder.Approach {
        HorizontalRouteFinder.approach(
            from: from, to: to, layer: 0, net: net, width: width,
            index: index, clearances: clearances)
    }

    /// Re-derives the verdict, with no exemptions at all: how many segments of
    /// the route come closer to anything of another net than the rules allow.
    private func violations(
        _ points: [HorizontalPoint], _ index: HorizontalRouterIndex, net: Int = 1
    ) -> Int {
        var count = 0
        guard points.count > 1 else { return 0 }
        for segment in 0..<(points.count - 1) {
            let swept = HorizontalOctagon(from: points[segment], to: points[segment + 1], width: 0)
            for obstacle in index.obstacles where obstacle.netCode != net {
                let gap = clearances.clearance(
                    .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: 0)
                if obstacle.hull.inflated(by: gap + width / 2).overlaps(swept) {
                    count += 1
                }
            }
        }
        return count
    }

    private func assertLegal45(_ points: [HorizontalPoint],
                               file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<max(points.count, 1) {
            XCTAssertNotNil(
                HorizontalDirection45(from: points[i - 1], to: points[i]),
                "segment \(points[i - 1]) → \(points[i]) is not a routing direction",
                file: file, line: line)
        }
    }

    private func distance(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    // MARK: - The cursor over what the route must avoid

    /// The case the user saw: the cursor on another net's track. The route
    /// stops at that track's clearance, square in front of the cursor, and
    /// follows the cursor along its edge.
    func testACursorOnAnotherNetsTrackStopsTheRouteAtItsClearance() {
        let wall = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        for y in [0.0, 1_000_000, -700_000] {
            let result = approach(from: p(0, 0), to: p(4_980_000, y), wall)

            XCTAssertFalse(result.reachesTarget)
            XCTAssertEqual(result.points.last, p(5_000_000 - trackKeepOff, y),
                           "it should end at the edge of the clearance, level with the cursor")
            XCTAssertEqual(result.blocker, 0, "it names the track it stopped at")
            XCTAssertEqual(violations(result.points, wall), 0, "\(result.points)")
            assertLegal45(result.points)
        }
    }

    /// The old route, which `route` still is, went straight in: its end was
    /// exempt from what it ended inside.
    func testRouteStillExemptsBothEnds() {
        let wall = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        let result = HorizontalRouteFinder.route(
            from: p(0, 0), to: p(4_980_000, 0), layer: 0, net: 1, width: width,
            index: wall, clearances: clearances)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.points.last, p(4_980_000, 0))
    }

    /// Between two tracks whose clearances overlap, the edge nearest the
    /// cursor of one is inside the other's: the route has to end outside
    /// both, on the nearer side.
    func testBetweenTwoClearancesTheRouteEndsOutsideBoth() {
        let pair = index([
            track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000)),
            track(2, p(5_400_000, -3_000_000), p(5_400_000, 3_000_000)),
        ])
        let result = approach(from: p(0, 0), to: p(5_150_000, 0), pair)

        XCTAssertFalse(result.reachesTarget)
        XCTAssertEqual(result.points.last, p(5_000_000 - trackKeepOff, 0))
        XCTAssertEqual(violations(result.points, pair), 0)
    }

    /// The end is the NEAREST legal point to the cursor, not just a legal one:
    /// nothing nearer is clear. Checked against a ring of points just inside
    /// that distance, all round, for cursors all over a diagonal track and a
    /// pad beside it, whose clearances meet at an angle.
    func testTheEndIsTheNearestLegalPointToTheCursor() {
        let field = index(
            [track(1, p(4_000_000, -1_000_000), p(6_000_000, 1_000_000))],
            pads: [pad(5_200_000, -900_000, 6_200_000, -100_000, net: 2)])
        let collider = HorizontalRouteCollider(
            index: field, clearances: clearances, layer: 0, net: 1, width: width, exempt: [])

        var tried = 0
        for column in 0...12 {
            for row in 0...12 {
                let cursor = p(3_900_000 + Double(column) * 197_311, -1_300_000 + Double(row) * 211_793)
                guard collider.blocker(cursor, cursor) != nil else { continue }
                tried += 1
                guard let end = HorizontalRouteFinder.nearestClearPoint(to: cursor, collider: collider) else {
                    XCTFail("no clear point found near \(cursor)")
                    continue
                }
                XCTAssertNil(collider.blocker(end, end), "\(end) is not clear")
                XCTAssertEqual(end.x, end.x.rounded(), "whole nanometres")
                XCTAssertEqual(end.y, end.y.rounded(), "whole nanometres")
                let radius = distance(end, cursor) - 6
                guard radius > 0 else { continue }
                for step in 0..<720 {
                    let angle = Double(step) / 720 * 2 * .pi
                    let probe = p(cursor.x + radius * cos(angle), cursor.y + radius * sin(angle))
                    if collider.blocker(probe, probe) == nil {
                        XCTFail("\(probe) is clear and nearer \(cursor) than \(end)")
                        break
                    }
                }
            }
        }
        XCTAssertGreaterThan(tried, 20, "the grid should land plenty of cursors inside")
    }

    /// A cursor somewhere clear but out of reach — inside a ring of another
    /// net's tracks — gets the route as far as it can go towards it: up to the
    /// ring's nearer wall.
    func testAnEnclosedCursorGetsTheRouteToTheNearestPointItReaches() {
        let box = index([
            track(1, p(8_000_000, -3_000_000), p(13_000_000, -3_000_000)),
            track(2, p(8_000_000, 3_000_000), p(13_000_000, 3_000_000)),
            track(3, p(13_000_000, -3_000_000), p(13_000_000, 3_000_000)),
            track(4, p(8_000_000, -3_000_000), p(8_000_000, 3_000_000)),
        ])
        let result = approach(from: p(0, 0), to: p(10_000_000, 0), box)

        XCTAssertFalse(result.reachesTarget)
        XCTAssertGreaterThan(result.points.count, 1, "it should get somewhere")
        XCTAssertEqual(violations(result.points, box), 0, "\(result.points)")
        assertLegal45(result.points)
        let end = result.points.last ?? p(0, 0)
        XCTAssertLessThan(distance(end, p(8_000_000 - trackKeepOff, 0)), 1_000,
                          "it should end at the wall nearest the cursor, got \(end)")
    }

    /// A route stopped at a clearance carries on from there: its next leg
    /// starts on the edge, and goes round rather than through.
    func testARouteFromWhereItStoppedGoesRound() {
        let wall = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        let stopped = approach(from: p(0, 0), to: p(4_990_000, 0), wall)
        let edge = try! XCTUnwrap(stopped.points.last)
        XCTAssertEqual(edge, p(5_000_000 - trackKeepOff, 0))

        let onward = approach(from: edge, to: p(10_000_000, 0), wall)
        XCTAssertTrue(onward.reachesTarget)
        XCTAssertEqual(violations(onward.points, wall), 0, "\(onward.points)")
        assertLegal45(onward.points)
    }

    // MARK: - The cursor on copper the route joins

    /// A route enters its own net's pad even where a neighbour's clearance
    /// reaches the pad's centre, as on a fine pitch: there the end keeps the
    /// exemption, as the start does.
    func testItEntersItsOwnNetsPadOnAFinePitch() {
        let pads = index([], pads: [
            pad(4_900_000, -500_000, 5_100_000, 500_000, net: 1),
            pad(5_200_000, -500_000, 5_400_000, 500_000, net: 2),
        ])
        let entered = approach(from: p(0, 0), to: p(5_000_000, 0), pads)
        XCTAssertTrue(entered.reachesTarget)
        XCTAssertEqual(entered.points.last, p(5_000_000, 0))

        // The neighbour itself is another net's, and the route stops short of
        // it, inside its own net's pad where that is nearest.
        let neighbour = approach(from: p(0, 0), to: p(5_250_000, 0), pads)
        XCTAssertFalse(neighbour.reachesTarget)
        XCTAssertEqual(neighbour.points.last, p(5_200_000 - clearance - width / 2, 0))
    }

    /// A route on no net yet takes the net of the copper it ends on, so that
    /// copper is a connection, not something to stop short of.
    func testARouteOnNoNetEndsOnWhateverCopperItReaches() {
        let wall = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        let result = approach(from: p(0, 0), to: p(5_000_000, 0), wall, net: -1)
        XCTAssertTrue(result.reachesTarget)
        XCTAssertEqual(result.points.last, p(5_000_000, 0))
    }

    /// Where nothing is in the way the approach is the route.
    func testAReachableTargetIsTheRoute() {
        let blocker = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        let target = p(10_000_000, 0)
        let approached = approach(from: p(0, 0), to: target, blocker)
        let routed = HorizontalRouteFinder.route(
            from: p(0, 0), to: target, layer: 0, net: 1, width: width,
            index: blocker, clearances: clearances)

        XCTAssertTrue(approached.reachesTarget)
        XCTAssertEqual(approached.points, routed.points)
        XCTAssertEqual(approached.blocker, -1)
    }
}
