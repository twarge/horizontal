import XCTest
@testable import HorizontalNative

/// 45° path construction and the two ways around an obstacle
/// (`docs/push-shove-router.md`, step 3).
///
/// The properties that matter are legality and reproducibility: every segment a
/// route emits has to be one of the eight directions, and the same inputs have
/// to give the same route. A router that answers differently run to run cannot
/// be used to compare two versions of a board.
final class RouterWalkaroundTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func assertLegal45(_ points: [HorizontalPoint], _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        for index in 1..<max(points.count, 1) {
            XCTAssertNotNil(
                HorizontalDirection45(from: points[index - 1], to: points[index]),
                "\(message) segment \(points[index - 1]) → \(points[index]) is not a routing direction",
                file: file, line: line
            )
        }
    }

    // MARK: - Elbows

    /// Every elbow between any two points must be legal, whichever posture.
    /// This is swept rather than sampled because the failure is a segment at an
    /// arbitrary angle, which the board cannot fabricate as drawn.
    func testEveryElbowIsALegal45Path() {
        for dx in stride(from: -3_000_000.0, through: 3_000_000.0, by: 250_000) {
            for dy in stride(from: -3_000_000.0, through: 3_000_000.0, by: 250_000) {
                for diagonalFirst in [true, false] {
                    let path = HorizontalRoute45.elbow(
                        from: p(0, 0), to: p(dx, dy), diagonalFirst: diagonalFirst)
                    assertLegal45(path, "d=(\(dx), \(dy)) diagonalFirst=\(diagonalFirst):")
                    XCTAssertEqual(path.first, p(0, 0))
                    XCTAssertEqual(path.last, p(dx, dy))
                }
            }
        }
    }

    /// The two postures are genuinely different routes — that is why the choice
    /// is exposed rather than derived.
    func testThePostureChoosesADifferentCorner() {
        let diagonal = HorizontalRoute45.elbow(from: p(0, 0), to: p(3_000, 1_000), diagonalFirst: true)
        let straight = HorizontalRoute45.elbow(from: p(0, 0), to: p(3_000, 1_000), diagonalFirst: false)

        XCTAssertEqual(diagonal, [p(0, 0), p(1_000, 1_000), p(3_000, 1_000)])
        XCTAssertEqual(straight, [p(0, 0), p(2_000, 0), p(3_000, 1_000)])
    }

    /// Already-legal steps need no corner at all.
    func testAlignedPointsProduceASingleSegment() {
        XCTAssertEqual(HorizontalRoute45.elbow(from: p(0, 0), to: p(5_000, 0), diagonalFirst: true).count, 2)
        XCTAssertEqual(HorizontalRoute45.elbow(from: p(0, 0), to: p(0, 5_000), diagonalFirst: true).count, 2)
        XCTAssertEqual(HorizontalRoute45.elbow(from: p(0, 0), to: p(5_000, 5_000), diagonalFirst: true).count, 2)
        XCTAssertEqual(HorizontalRoute45.elbow(from: p(7, 7), to: p(7, 7), diagonalFirst: true), [p(7, 7)])
    }

    /// Corners land on integers, so a route dragged and redrawn returns to the
    /// same coordinates instead of drifting.
    func testElbowCornersAreExact() {
        let path = HorizontalRoute45.elbow(from: p(1, 2), to: p(1_000_001, 3), diagonalFirst: true)
        for point in path {
            XCTAssertEqual(point.x, point.x.rounded(), "x drifted off an integer")
            XCTAssertEqual(point.y, point.y.rounded(), "y drifted off an integer")
        }
    }

    // MARK: - Simplification and measurement

    func testCollinearRunsAreCollapsed() {
        let straight = [p(0, 0), p(1_000, 0), p(2_000, 0), p(3_000, 0)]
        XCTAssertEqual(HorizontalRoute45.simplified(straight), [p(0, 0), p(3_000, 0)])
    }

    func testATurnIsKept() {
        let bent = [p(0, 0), p(1_000, 0), p(2_000, 1_000)]
        XCTAssertEqual(HorizontalRoute45.simplified(bent), bent)
        XCTAssertEqual(HorizontalRoute45.corners(of: bent), 1)
    }

    func testLengthIsTheSumOfItsSegments() {
        XCTAssertEqual(HorizontalRoute45.length(of: [p(0, 0), p(3_000, 0), p(3_000, 4_000)]), 7_000)
        XCTAssertEqual(
            HorizontalRoute45.length(of: [p(0, 0), p(1_000, 1_000)]),
            1_000 * 2.0.squareRoot(), accuracy: 0.001)
    }

    // MARK: - Walkaround

    private var obstacle: HorizontalOctagon {
        // A track running east, inflated as the router would inflate it.
        HorizontalOctagon(from: p(0, 0), to: p(4_000_000, 0), width: 400_000)
            .inflated(by: 200_000)
    }

    /// Both ways round must be legal routes. A detour that cannot be fabricated
    /// is not a detour.
    func testBothDetoursAreLegal45Paths() {
        let detours = HorizontalRouteWalkaround.detours(
            around: obstacle, from: p(-2_000_000, 0), to: p(6_000_000, 0))

        XCTAssertEqual(detours.count, 2, "an obstacle always has two sides")
        for detour in detours {
            assertLegal45(detour.points, "\(detour.isAnticlockwise ? "CCW" : "CW"):")
            XCTAssertEqual(detour.points.first, p(-2_000_000, 0))
            XCTAssertEqual(detour.points.last, p(6_000_000, 0))
        }
    }

    /// The two detours must actually go opposite ways — one above the obstacle
    /// and one below — or the router is choosing between the same route twice.
    func testTheTwoDetoursPassOnOppositeSides() {
        let detours = HorizontalRouteWalkaround.detours(
            around: obstacle, from: p(-2_000_000, 0), to: p(6_000_000, 0))
        let extremes = detours.map { detour in
            detour.points.map(\.y).reduce(0) { abs($0) > abs($1) ? $0 : $1 }
        }

        XCTAssertEqual(extremes.count, 2)
        XCTAssertTrue(
            (extremes[0] > 0) != (extremes[1] > 0),
            "one detour should pass above and the other below, got \(extremes)")
    }

    /// A detour must leave the obstacle alone. Its corners ride the hull's
    /// boundary — exactly at clearance, since the hull is already inflated — so
    /// none may be strictly inside.
    func testADetourNeverEntersTheObstacle() throws {
        let hull = obstacle
        let inner = hull.inflated(by: -1)
        for detour in HorizontalRouteWalkaround.detours(
            around: hull, from: p(-2_000_000, 0), to: p(6_000_000, 0)) {
            for point in detour.points {
                XCTAssertFalse(
                    inner.contains(point),
                    "\(point) is inside the obstacle on the \(detour.isAnticlockwise ? "CCW" : "CW") detour")
            }
        }
    }

    /// Picking between them must be reproducible. The same board, routed twice,
    /// has to give the same copper.
    func testTheChoiceIsDeterministic() {
        let choices = (0..<10).map { _ in
            HorizontalRouteWalkaround.best(
                around: obstacle, from: p(-2_000_000, 500_000), to: p(6_000_000, 500_000)
            )?.isAnticlockwise
        }
        XCTAssertEqual(Set(choices.map { $0 ?? false }).count, 1, "the pick varied: \(choices)")
    }

    /// And it must pick the cheaper one rather than whichever came first.
    func testTheBestDetourIsTheCheaperOne() throws {
        let detours = HorizontalRouteWalkaround.detours(
            around: obstacle, from: p(-2_000_000, 900_000), to: p(6_000_000, 900_000))
        let best = try XCTUnwrap(HorizontalRouteWalkaround.best(
            around: obstacle, from: p(-2_000_000, 900_000), to: p(6_000_000, 900_000)))

        for detour in detours {
            XCTAssertLessThanOrEqual(best.cost, detour.cost)
        }
        // The meaningful property, rather than which winding it happens to be:
        // approaching from above, the cheaper route goes over the top instead of
        // all the way around the bottom.
        let lowest = try XCTUnwrap(best.points.map(\.y).min())
        XCTAssertGreaterThan(
            lowest, 0,
            "approaching from above, the cheaper route should not dip under the obstacle")
    }

    /// A degenerate hull has no ring to walk, and must say so rather than
    /// returning a route that goes nowhere.
    func testADegenerateHullYieldsNoDetour() throws {
        let point = try XCTUnwrap(HorizontalOctagon(points: [p(0, 0)]))
        XCTAssertTrue(HorizontalRouteWalkaround.detours(
            around: point, from: p(-1_000, 0), to: p(1_000, 0)).isEmpty)
        XCTAssertNil(HorizontalRouteWalkaround.best(
            around: point, from: p(-1_000, 0), to: p(1_000, 0)))
    }
}
