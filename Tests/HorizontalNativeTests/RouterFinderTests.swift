import XCTest
@testable import HorizontalNative

/// Routing around what is on the board (`docs/push-shove-router.md`, step 3).
///
/// The central property is the one the study puts first: a route this returns as
/// complete must not violate a clearance. So rather than checking shapes, most
/// of these re-derive the answer — take the route it produced and verify no
/// segment of it collides with anything — which is a check that cannot pass by
/// coincidence.
final class RouterFinderTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private let width = 200_000.0
    private let clearance = 150_000.0

    /// A rule set with one uniform clearance, so the expected geometry is
    /// arithmetic a reader can follow.
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
        .init(id: id, from: a, to: b, center: nil, width: width,
              layer: 0, netCode: net, locked: false)
    }

    private func index(_ tracks: [HorizontalRouterWorld.Track]) -> HorizontalRouterIndex {
        var world = HorizontalRouterWorld()
        world.tracks = tracks
        return HorizontalRouterIndex(world: world)
    }

    private func route(
        from: HorizontalPoint, to: HorizontalPoint,
        _ index: HorizontalRouterIndex, net: Int = 1
    ) -> HorizontalRouteFinder.Result {
        HorizontalRouteFinder.route(
            from: from, to: to, layer: 0, net: net, width: width,
            index: index, clearances: clearances)
    }

    /// Re-derives the verdict: does any segment of this route come closer to any
    /// obstacle than the rules allow?
    private func violations(
        _ result: HorizontalRouteFinder.Result, _ index: HorizontalRouterIndex, net: Int = 1
    ) -> Int {
        var count = 0
        let points = result.points
        guard points.count > 1 else { return 0 }
        for segment in 0..<(points.count - 1) {
            let swept = HorizontalOctagon(from: points[segment], to: points[segment + 1], width: 0)
            for obstacle in index.obstacles {
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

    // MARK: - The empty case

    func testAnEmptyBoardRoutesStraightThrough() {
        let result = route(from: p(0, 0), to: p(10_000_000, 3_000_000), index([]))
        XCTAssertTrue(result.isComplete)
        assertLegal45(result.points)
        XCTAssertEqual(result.points.first, p(0, 0))
        XCTAssertEqual(result.points.last, p(10_000_000, 3_000_000))
    }

    // MARK: - Avoidance

    /// One track across the path: the route must go around it and, crucially,
    /// must actually be clear of it afterwards.
    func testItRoutesAroundASingleObstacle() {
        let blocker = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        let result = route(from: p(0, 0), to: p(10_000_000, 0), blocker)

        XCTAssertTrue(result.isComplete, "a track with open board around it is routable")
        assertLegal45(result.points)
        XCTAssertEqual(violations(result, blocker), 0, "the completed route still crosses something")
        XCTAssertGreaterThan(result.points.count, 2, "it should have detoured, not gone straight")
    }

    /// Two obstacles in series is the case that separates "handles an obstacle"
    /// from "handles the board".
    func testItRoutesAroundSuccessiveObstacles() {
        let blockers = index([
            track(1, p(3_000_000, -2_000_000), p(3_000_000, 2_000_000)),
            track(2, p(7_000_000, -2_000_000), p(7_000_000, 2_000_000)),
        ])
        let result = route(from: p(0, 0), to: p(10_000_000, 0), blockers)

        XCTAssertTrue(result.isComplete)
        assertLegal45(result.points)
        XCTAssertEqual(violations(result, blockers), 0)
    }

    /// Copper of the router's own net is not an obstacle to it, or a track could
    /// never leave its own pad.
    func testItIgnoresItsOwnNet() {
        let sameNet = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000), net: 1)])
        let result = route(from: p(0, 0), to: p(10_000_000, 0), sameNet, net: 1)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.points.count, 2, "same-net copper needs no detour at all")
    }

    // MARK: - Honest failure

    /// The requirement that separates a tool from a demo: when it cannot get
    /// through it must SAY so, not return something plausible. A box of tracks
    /// with the target inside has no legal route.
    func testACompletelyBlockedTargetIsReportedNotFaked() {
        let box = index([
            track(1, p(8_000_000, -2_000_000), p(12_000_000, -2_000_000)),
            track(2, p(8_000_000, 2_000_000), p(12_000_000, 2_000_000)),
            track(3, p(12_000_000, -2_000_000), p(12_000_000, 2_000_000)),
            track(4, p(8_000_000, -2_000_000), p(8_000_000, 2_000_000)),
        ])
        let result = route(from: p(0, 0), to: p(10_000_000, 0), box)

        XCTAssertFalse(result.isComplete, "there is no way into a closed box")
        switch result.outcome {
        case .blocked(let obstacle), .exhausted(let obstacle):
            XCTAssertTrue(box.obstacles.indices.contains(obstacle),
                          "it should name what stopped it, for the UI to highlight")
        case .complete:
            XCTFail("unreachable")
        }
    }

    /// It must come back at all. A dense field is where an unbounded search
    /// hangs, and a hung router is worse than one that refuses.
    func testItTerminatesInADenseField() {
        var tracks: [HorizontalRouterWorld.Track] = []
        for row in 0..<12 {
            for column in 0..<12 {
                let x = Double(column) * 900_000
                let y = Double(row) * 900_000 - 5_000_000
                tracks.append(track(Int64(row * 12 + column), p(x, y), p(x + 400_000, y)))
            }
        }
        let dense = index(tracks)

        let result = route(from: p(-2_000_000, 0), to: p(14_000_000, 0), dense)
        assertLegal45(result.points)
        if result.isComplete {
            XCTAssertEqual(violations(result, dense), 0,
                           "if it claims success it must actually be clear")
        }
    }

    // MARK: - Reproducibility

    func testTheSameRequestGivesTheSameRoute() {
        let blockers = index([
            track(1, p(3_000_000, -2_000_000), p(3_000_000, 2_000_000)),
            track(2, p(7_000_000, -2_000_000), p(7_000_000, 2_000_000)),
        ])
        let routes = (0..<8).map { _ in route(from: p(0, 0), to: p(10_000_000, 0), blockers).points }
        XCTAssertEqual(Set(routes.map { "\($0)" }).count, 1, "the route varied between runs")
    }

    /// A wider track needs more room, so it must not reuse a narrower track's
    /// answer. Getting this wrong is how a fat trace ends up too close.
    func testAWiderTrackKeepsItsOwnDistance() {
        let blocker = index([track(1, p(5_000_000, -3_000_000), p(5_000_000, 3_000_000))])
        let narrow = HorizontalRouteFinder.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0, net: 1, width: 100_000,
            index: blocker, clearances: clearances)
        let wide = HorizontalRouteFinder.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0, net: 1, width: 2_000_000,
            index: blocker, clearances: clearances)

        XCTAssertTrue(narrow.isComplete)
        XCTAssertTrue(wide.isComplete)
        let narrowExtent = narrow.points.map { abs($0.y) }.max() ?? 0
        let wideExtent = wide.points.map { abs($0.y) }.max() ?? 0
        XCTAssertGreaterThan(wideExtent, narrowExtent, "a wider track must swing wider")
    }
}

/// Route quality, not just legality.
///
/// A detour walks the obstacle's whole corner ring — the closed-form answer, and
/// guaranteed legal, but far more corners than the route needs. Left alone it
/// produces a legal staircase, which is the first thing a user notices and the
/// reason the first build of this looked rough.
extension RouterFinderTests {
    private func p2(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    /// Going round one small obstacle should cost a handful of corners, not the
    /// whole ring.
    func testRoutingAroundOneObstacleStaysTidy() {
        let blocker = index([track(1, p2(5_000_000, -1_000_000), p2(5_000_000, 1_000_000))])
        let result = route(from: p2(0, 0), to: p2(10_000_000, 0), blocker)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(violations(result, blocker), 0)
        let corners = HorizontalRoute45.corners(of: result.points)
        XCTAssertLessThanOrEqual(
            corners, 4,
            "one obstacle should not cost \(corners) corners: \(result.points)")
    }

    /// Tightening must never buy a shorter route with a violation.
    func testTighteningNeverIntroducesACollision() {
        var tracks: [HorizontalRouterWorld.Track] = []
        for row in 0..<6 {
            let y = Double(row) * 1_200_000 - 3_000_000
            tracks.append(track(Int64(row), p2(4_000_000, y), p2(4_000_000, y + 600_000)))
        }
        let field = index(tracks)
        let result = route(from: p2(0, 0), to: p2(9_000_000, 0), field)

        if result.isComplete {
            XCTAssertEqual(violations(result, field), 0,
                           "a tightened route must still be clear")
        }
        assertLegal45(result.points)
    }

    /// And it must not tighten a route into a straight line through the thing it
    /// was avoiding.
    func testTighteningKeepsTheDetour() {
        let blocker = index([track(1, p2(5_000_000, -3_000_000), p2(5_000_000, 3_000_000))])
        let result = route(from: p2(0, 0), to: p2(10_000_000, 0), blocker)

        XCTAssertTrue(result.isComplete)
        XCTAssertGreaterThan(result.points.count, 2, "it still has to go around")
        XCTAssertEqual(violations(result, blocker), 0)
    }
}

/// The cases a greedy walk cannot solve, and the reason the finder is a search.
///
/// Walking around one obstacle at a time commits to each decision before
/// seeing the next. On a real board the way past a component is a SEQUENCE of
/// decisions, and the first version of this router — which did exactly that —
/// completed two percent of pad-to-pad routes on a real board. Each test here
/// is a shape that defeats a greedy walk outright and that a search gets
/// through, and each re-derives the verdict rather than trusting the report.
extension RouterFinderTests {
    private func p3(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    /// A row of pads with no gap a track fits through: the route has to go
    /// around the whole row, not between any two of its members. A greedy walk
    /// detours around one pad, lands on its neighbour, and gives up.
    func testItRoutesAroundAWallOfPads() {
        var wall: [HorizontalRouterWorld.Track] = []
        for column in 0..<10 {
            let x = 3_000_000 + Double(column) * 400_000
            wall.append(track(Int64(column), p3(x, -2_000_000), p3(x, 2_000_000)))
        }
        let index = index(wall)
        let result = route(from: p3(0, 0), to: p3(10_000_000, 0), index)

        XCTAssertTrue(result.isComplete, "there is open board above and below the wall")
        assertLegal45(result.points)
        XCTAssertEqual(violations(result, index), 0)
        let swing = result.points.map { abs($0.y) }.max() ?? 0
        XCTAssertGreaterThan(swing, 2_000_000, "it must clear the whole row, not thread it")
    }

    /// The start is inside a U that opens AWAY from the target. Every step
    /// towards the target is blocked; the way out is to go the other way first.
    /// A greedy walk never does.
    func testItEscapesAUTrap() {
        let trap = index([
            // The closed side, between the start and the target.
            track(1, p3(2_000_000, -3_000_000), p3(2_000_000, 3_000_000)),
            // The two arms, reaching back past the start.
            track(2, p3(-4_000_000, 3_000_000), p3(2_000_000, 3_000_000)),
            track(3, p3(-4_000_000, -3_000_000), p3(2_000_000, -3_000_000)),
        ])
        let result = route(from: p3(0, 0), to: p3(6_000_000, 0), trap)

        XCTAssertTrue(result.isComplete, "the U is open at its back")
        assertLegal45(result.points)
        XCTAssertEqual(violations(result, trap), 0)
        let furthestBack = result.points.map(\.x).min() ?? 0
        XCTAssertLessThan(furthestBack, -4_000_000, "it has to leave through the open back")
    }

    /// Two long walls with one channel through them, just wide enough for the
    /// track and its clearance. The only route is through the channel, and the
    /// grid has to be fine enough to find it.
    func testItThreadsANarrowChannel() {
        // Between the walls' centre lines the track needs half a wall, a
        // clearance, its own width, a clearance and half a wall again — 100 +
        // 150 + 200 + 150 + 100 µm — so its centre may sit anywhere in a band
        // as wide as the spare room given here.
        let half = (width / 2 + clearance + width + clearance + width / 2 + 100_000) / 2
        let walls = index([
            track(1, p3(5_000_000, half), p3(5_000_000, 40_000_000)),
            track(2, p3(5_000_000, -40_000_000), p3(5_000_000, -half)),
        ])
        let result = route(from: p3(0, 1_500_000), to: p3(10_000_000, -1_500_000), walls)

        XCTAssertTrue(result.isComplete, "the channel is wide enough and the walls too long to go around")
        assertLegal45(result.points)
        XCTAssertEqual(violations(result, walls), 0)
        let crossing = result.points.filter { abs($0.x - 5_000_000) < 600_000 }
        XCTAssertFalse(crossing.isEmpty)
        for point in crossing {
            XCTAssertLessThan(abs(point.y), half, "it crossed the wall line outside the channel")
        }
    }

    /// Whatever the search did to find it, the route it hands back is a few
    /// elbows, not the staircase of grid steps it was found as.
    func testASearchedRouteIsPulledTaut() {
        let blockers = index([
            track(1, p3(3_000_000, -2_000_000), p3(3_000_000, 2_000_000)),
            track(2, p3(7_000_000, -1_000_000), p3(7_000_000, 3_000_000)),
        ])
        let result = route(from: p3(0, 0), to: p3(10_000_000, 0), blockers)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(violations(result, blockers), 0)
        let corners = HorizontalRoute45.corners(of: result.points)
        XCTAssertLessThanOrEqual(corners, 8, "two obstacles should not cost \(corners) corners: \(result.points)")
    }

    /// The budget is honoured: an enormous unreachable window comes back with
    /// `exhausted`, not a hang.
    func testAnUnreachableTargetComesBackWithinItsBudget() {
        let box = index([
            track(1, p3(8_000_000, -2_000_000), p3(12_000_000, -2_000_000)),
            track(2, p3(8_000_000, 2_000_000), p3(12_000_000, 2_000_000)),
            track(3, p3(12_000_000, -2_000_000), p3(12_000_000, 2_000_000)),
            track(4, p3(8_000_000, -2_000_000), p3(8_000_000, 2_000_000)),
        ])
        var budget = HorizontalRouteFinder.Budget()
        budget.maxExpansions = 500
        let result = HorizontalRouteFinder.route(
            from: p3(0, 0), to: p3(10_000_000, 0), layer: 0, net: 1, width: width,
            index: box, clearances: clearances, budget: budget)

        XCTAssertFalse(result.isComplete)
        if case .exhausted(let obstacle) = result.outcome {
            XCTAssertTrue(box.obstacles.indices.contains(obstacle), "it should still name what was in the way")
        } else if case .blocked = result.outcome {
            // Also acceptable: the search may exhaust the reachable region first.
        } else {
            XCTFail("unreachable")
        }
    }
}
