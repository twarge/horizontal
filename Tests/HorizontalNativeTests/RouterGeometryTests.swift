import XCTest
@testable import HorizontalNative

/// The router's foundation geometry (`docs/push-shove-router.md`, step 1).
///
/// These are mostly PROPERTY tests rather than examples, because the properties
/// are the specification: an octagon that fails to contain its own clearance is
/// a board with a violation the router will report as legal, and no amount of
/// worked examples rules that out the way a swept assertion does.
final class RouterGeometryTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    // MARK: - Directions

    func testEveryLegalStepDecodesToItsDirection() {
        let origin = p(0, 0)
        for direction in HorizontalDirection45.allCases {
            let step = direction.step
            let target = p(step.x * 1_000, step.y * 1_000)
            XCTAssertEqual(HorizontalDirection45(from: origin, to: target), direction)
        }
    }

    /// A step that is not one of the eight is reported, not snapped. Silently
    /// rounding a near-45° drag to 45° would move copper the user did not.
    func testOffAxisStepsAreRejected() {
        XCTAssertNil(HorizontalDirection45(from: p(0, 0), to: p(1_000, 999)))
        XCTAssertNil(HorizontalDirection45(from: p(0, 0), to: p(1_000, 500)))
        XCTAssertNil(HorizontalDirection45(from: p(0, 0), to: p(0, 0)), "a zero step has no direction")
    }

    func testOppositeIsAnInvolutionAndNeverIdentity() {
        for direction in HorizontalDirection45.allCases {
            XCTAssertEqual(direction.opposite.opposite, direction)
            XCTAssertNotEqual(direction.opposite, direction)
            XCTAssertEqual(direction.eighths(to: direction.opposite), 4, "opposite is four eighths away")
        }
    }

    func testTurningWrapsInBothDirections() {
        for direction in HorizontalDirection45.allCases {
            XCTAssertEqual(direction.turned(by: 8), direction)
            XCTAssertEqual(direction.turned(by: -8), direction)
            XCTAssertEqual(direction.turned(by: 3).turned(by: -3), direction)
        }
    }

    /// Turn cost has to be symmetric, or the router would price a corner
    /// differently depending on which way it was walking.
    func testTurnCostIsSymmetricAndBounded() {
        for a in HorizontalDirection45.allCases {
            for b in HorizontalDirection45.allCases {
                let cost = a.eighths(to: b)
                XCTAssertEqual(cost, b.eighths(to: a))
                XCTAssertTrue((0...4).contains(cost))
                XCTAssertEqual(cost == 0, a == b)
            }
        }
    }

    func testDiagonalsAreTheOddDirections() {
        XCTAssertTrue(HorizontalDirection45.northEast.isDiagonal)
        XCTAssertFalse(HorizontalDirection45.north.isDiagonal)
        XCTAssertEqual(HorizontalDirection45.allCases.filter(\.isDiagonal).count, 4)
    }

    // MARK: - Octagon basics

    func testAnOctagonContainsThePointsItWasBuiltFrom() throws {
        let points = [p(0, 0), p(5_000, 1_000), p(-2_000, 3_000), p(1_000, -4_000)]
        let hull = try XCTUnwrap(HorizontalOctagon(points: points))
        for point in points {
            XCTAssertTrue(hull.contains(point), "\(point) should be inside its own hull")
        }
    }

    func testAnEmptyPointSetHasNoOctagon() {
        XCTAssertNil(HorizontalOctagon(points: []))
    }

    /// THE property. Everything the router decides rests on it: a shape inflated
    /// by a clearance must contain every point within that clearance of the
    /// original. If it does not, the router reports a legal route across a board
    /// that violates its own rules — and nothing downstream would catch it.
    func testInflationContainsEveryPointWithinTheClearance() throws {
        let clearance = 200_000.0
        let hull = try XCTUnwrap(HorizontalOctagon(points: [p(0, 0), p(1_000_000, 0)]))
        let inflated = hull.inflated(by: clearance)

        // Sweep the full circle at the clearance radius, around both ends and the
        // middle — the diagonal faces are where an under-approximation hides.
        for anchor in [p(0, 0), p(500_000, 0), p(1_000_000, 0)] {
            for degrees in stride(from: 0, to: 360, by: 1) {
                let radians = Double(degrees) * .pi / 180
                let probe = p(
                    anchor.x + clearance * cos(radians),
                    anchor.y + clearance * sin(radians)
                )
                XCTAssertTrue(
                    inflated.contains(probe),
                    "a point exactly \(clearance)nm away at \(degrees)° must be inside the clearance hull"
                )
            }
        }
    }

    /// The corollary: inflation must not be so generous that it swallows the
    /// board. An octagon circumscribing a circle exceeds it by at most the
    /// circumscribing factor, so a point well beyond the clearance stays outside.
    func testInflationDoesNotExtendUnboundedly() throws {
        let clearance = 100_000.0
        let hull = try XCTUnwrap(HorizontalOctagon(points: [p(0, 0)]))
        let inflated = hull.inflated(by: clearance)

        // A regular octagon circumscribing a circle of radius r reaches r×√2 at
        // its vertices; nothing beyond that can be inside.
        let beyond = clearance * 2.0.squareRoot() + 10
        XCTAssertFalse(inflated.contains(p(beyond, 0)))
        XCTAssertFalse(inflated.contains(p(beyond, beyond)))
    }

    func testInflatingByZeroChangesNothing() throws {
        let hull = try XCTUnwrap(HorizontalOctagon(points: [p(0, 0), p(1_000, 2_000)]))
        XCTAssertEqual(hull.inflated(by: 0), hull)
    }

    func testInflationIsMonotonic() throws {
        let hull = try XCTUnwrap(HorizontalOctagon(points: [p(0, 0), p(3_000, 1_000)]))
        let small = hull.inflated(by: 1_000)
        let large = hull.inflated(by: 5_000)

        for direction in HorizontalDirection45.allCases {
            XCTAssertLessThanOrEqual(
                small.extents[direction.rawValue], large.extents[direction.rawValue])
            XCTAssertLessThanOrEqual(
                hull.extents[direction.rawValue], small.extents[direction.rawValue])
        }
    }

    // MARK: - Intersection

    func testIntersectionIsSymmetric() {
        let a = HorizontalOctagon(from: p(0, 0), to: p(10_000, 0), width: 200_000)
        for dx in stride(from: -400_000.0, through: 400_000.0, by: 50_000) {
            let b = HorizontalOctagon(from: p(dx, 0), to: p(dx + 10_000, 0), width: 200_000)
            XCTAssertEqual(a.intersects(b), b.intersects(a), "at dx=\(dx)")
        }
    }

    func testAnOctagonIntersectsItself() {
        let a = HorizontalOctagon(center: p(1_000, 2_000), radius: 300_000)
        XCTAssertTrue(a.intersects(a))
    }

    /// Two tracks separated by more than their combined clearance do not collide;
    /// brought closer, they do. This is the router's central question.
    func testSeparatedTracksDoNotCollideAndTouchingOnesDo() {
        let width = 200_000.0
        let lower = HorizontalOctagon(from: p(0, 0), to: p(1_000_000, 0), width: width)

        let farAway = HorizontalOctagon(from: p(0, 900_000), to: p(1_000_000, 900_000), width: width)
        XCTAssertFalse(lower.intersects(farAway))

        // Centres one width apart: the two half-widths meet exactly.
        let touching = HorizontalOctagon(from: p(0, width), to: p(1_000_000, width), width: width)
        XCTAssertTrue(lower.intersects(touching), "touching counts as collision, not clearance")

        let overlapping = HorizontalOctagon(from: p(0, width / 2), to: p(1_000_000, width / 2), width: width)
        XCTAssertTrue(lower.intersects(overlapping))
    }

    /// Containment and intersection have to agree: a point inside one hull means
    /// a degenerate hull at that point intersects it. Two independent code paths
    /// answering the same question differently is how a router develops a limp.
    func testContainmentAgreesWithIntersection() throws {
        let hull = try XCTUnwrap(HorizontalOctagon(points: [p(0, 0), p(400_000, 200_000)]))
            .inflated(by: 50_000)

        for x in stride(from: -200_000.0, through: 600_000.0, by: 37_000) {
            for y in stride(from: -200_000.0, through: 400_000.0, by: 37_000) {
                let point = p(x, y)
                let degenerate = try XCTUnwrap(HorizontalOctagon(points: [point]))
                XCTAssertEqual(
                    hull.contains(point), hull.intersects(degenerate),
                    "disagreement at (\(x), \(y))"
                )
            }
        }
    }

    // MARK: - Obstacle shapes

    func testATrackHullCoversItsWholeWidth() {
        let width = 250_000.0
        let hull = HorizontalOctagon(from: p(0, 0), to: p(1_000_000, 0), width: width)

        XCTAssertTrue(hull.contains(p(500_000, width / 2)), "the edge of the copper is copper")
        XCTAssertTrue(hull.contains(p(500_000, -width / 2)))
        XCTAssertFalse(hull.contains(p(500_000, width)), "well outside the trace is not")
    }

    func testAZeroWidthTrackIsStillItsOwnSegment() {
        let hull = HorizontalOctagon(from: p(0, 0), to: p(1_000, 0), width: 0)
        XCTAssertTrue(hull.contains(p(500, 0)))
        XCTAssertTrue(hull.contains(p(0, 0)))
        XCTAssertTrue(hull.contains(p(1_000, 0)))
    }

    func testBoundingBoxContainsTheOctagon() throws {
        let hull = try XCTUnwrap(HorizontalOctagon(points: [p(-1_000, 2_000), p(3_000, -500)]))
            .inflated(by: 100_000)
        let box = hull.boundingBox

        for degrees in stride(from: 0, to: 360, by: 5) {
            let radians = Double(degrees) * .pi / 180
            let probe = p(200_000 * cos(radians), 200_000 * sin(radians))
            if hull.contains(probe) {
                XCTAssertTrue(
                    probe.x >= box.minX && probe.x <= box.maxX
                        && probe.y >= box.minY && probe.y <= box.maxY,
                    "a point in the hull must be in its bounding box"
                )
            }
        }
    }
}

/// The octagon's corner ring, which walkaround walks (step 3).
///
/// Two properties carry the weight. The ring must describe the SAME region the
/// support values do — otherwise walkaround follows a boundary that is not the
/// obstacle's — and consecutive corners must be joined by edges in the eight
/// routing directions, or the path around an obstacle is not a legal 45° route.
extension RouterGeometryTests {
    private func pt(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    func testEveryCornerLiesOnTheOctagon() throws {
        let hull = try XCTUnwrap(HorizontalOctagon(points: [pt(0, 0), pt(3_000_000, 1_000_000)]))
            .inflated(by: 400_000)
        for corner in hull.vertices {
            XCTAssertTrue(hull.contains(corner), "\(corner) is a corner but not inside")
        }
    }

    /// Rebuilding an octagon from its own corners must give the same octagon.
    /// If it does not, the ring and the support values disagree about where the
    /// obstacle is.
    func testTheRingDescribesTheSameRegion() throws {
        for radius in [1.0, 1_000.0, 250_000.0] {
            let hull = try XCTUnwrap(HorizontalOctagon(points: [pt(0, 0)])).inflated(by: radius)
            let rebuilt = try XCTUnwrap(HorizontalOctagon(points: hull.vertices))
            XCTAssertEqual(rebuilt, hull, "at radius \(radius)")
        }
    }

    /// THE property for walkaround: every edge of the ring runs in one of the
    /// eight directions, so walking the ring is already a legal 45° path.
    func testEveryRingEdgeRunsInARoutingDirection() throws {
        let shapes = [
            try XCTUnwrap(HorizontalOctagon(points: [pt(0, 0)])).inflated(by: 500_000),
            HorizontalOctagon(from: pt(0, 0), to: pt(4_000_000, 0), width: 300_000),
            HorizontalOctagon(from: pt(0, 0), to: pt(2_000_000, 2_000_000), width: 300_000),
            try XCTUnwrap(HorizontalOctagon(points: [pt(0, 0), pt(1_000_000, 0),
                                                     pt(1_000_000, 700_000), pt(0, 700_000)])),
        ]
        for (index, hull) in shapes.enumerated() {
            let ring = hull.vertices
            XCTAssertGreaterThanOrEqual(ring.count, 3, "shape \(index) should be a polygon")
            for position in ring.indices {
                let a = ring[position]
                let b = ring[(position + 1) % ring.count]
                XCTAssertNotNil(
                    HorizontalDirection45(from: a, to: b),
                    "shape \(index): edge \(a) → \(b) is not a routing direction"
                )
            }
        }
    }

    /// A rectangle has four corners, not eight: the diagonal faces are slack and
    /// their corners coincide. Emitting the duplicates would put zero-length
    /// edges into a route.
    func testARectangleCollapsesToFourCorners() throws {
        let rectangle = try XCTUnwrap(HorizontalOctagon(points: [
            pt(0, 0), pt(2_000_000, 0), pt(2_000_000, 1_000_000), pt(0, 1_000_000),
        ]))
        XCTAssertEqual(rectangle.vertices.count, 4)
    }

    func testTheRingIsAnticlockwise() throws {
        let hull = try XCTUnwrap(HorizontalOctagon(points: [pt(0, 0)])).inflated(by: 100_000)
        let ring = hull.vertices
        var twiceArea = 0.0
        for position in ring.indices {
            let a = ring[position]
            let b = ring[(position + 1) % ring.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        XCTAssertGreaterThan(twiceArea, 0, "walkaround relies on a known winding")
    }
}

/// `intersects` versus `overlaps`. The difference is one case — touching — and
/// the whole router rests on it: a clearance says two things must be at least so
/// far apart, so being exactly that far apart is legal. Since an obstacle's hull
/// is inflated by the clearance before testing, a route riding its boundary is
/// correct, and a detour rides that boundary by construction. Testing detours
/// with `intersects` reports every one of them as colliding with the very thing
/// it was drawn to avoid — which is exactly what happened before this existed.
extension RouterGeometryTests {
    func testTouchingIntersectsButDoesNotOverlap() {
        let left = HorizontalOctagon(from: HorizontalPoint(x: 0, y: 0),
                                     to: HorizontalPoint(x: 1_000_000, y: 0), width: 0)
        // Its own extent along +x is 1_000_000, so a shape starting exactly there
        // touches without sharing area.
        let touching = HorizontalOctagon(from: HorizontalPoint(x: 1_000_000, y: 0),
                                         to: HorizontalPoint(x: 2_000_000, y: 0), width: 0)

        XCTAssertTrue(left.intersects(touching), "they share a point")
        XCTAssertFalse(left.overlaps(touching), "but no area, so no clearance is violated")
    }

    func testRealOverlapIsReportedByBoth() {
        let a = HorizontalOctagon(from: HorizontalPoint(x: 0, y: 0),
                                  to: HorizontalPoint(x: 1_000_000, y: 0), width: 200_000)
        let b = HorizontalOctagon(from: HorizontalPoint(x: 500_000, y: 0),
                                  to: HorizontalPoint(x: 1_500_000, y: 0), width: 200_000)
        XCTAssertTrue(a.intersects(b))
        XCTAssertTrue(a.overlaps(b))
    }

    func testSeparationIsReportedByBoth() {
        let a = HorizontalOctagon(center: HorizontalPoint(x: 0, y: 0), radius: 100_000)
        let b = HorizontalOctagon(center: HorizontalPoint(x: 5_000_000, y: 0), radius: 100_000)
        XCTAssertFalse(a.intersects(b))
        XCTAssertFalse(a.overlaps(b))
    }

    func testOverlapIsSymmetric() {
        let a = HorizontalOctagon(from: HorizontalPoint(x: 0, y: 0),
                                  to: HorizontalPoint(x: 10_000, y: 0), width: 200_000)
        for dx in stride(from: -400_000.0, through: 400_000.0, by: 25_000) {
            let b = HorizontalOctagon(from: HorizontalPoint(x: dx, y: 0),
                                      to: HorizontalPoint(x: dx + 10_000, y: 0), width: 200_000)
            XCTAssertEqual(a.overlaps(b), b.overlaps(a), "at dx=\(dx)")
        }
    }
}
