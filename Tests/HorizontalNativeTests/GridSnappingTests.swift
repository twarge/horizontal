import Foundation
import XCTest
@testable import HorizontalNative

/// Grid snapping had no coverage before this: it is small, load-bearing
/// arithmetic (every drawn point passes through it) and any change to the
/// rounding silently moves geometry off-grid.
final class GridSnappingTests: XCTestCase {
    private func grid(spacing: Double, origin: Double = 0) -> HorizontalGridSettings {
        HorizontalGridSettings(
            name: "test",
            mode: "square",
            spacing: HorizontalPoint(x: spacing, y: spacing),
            origin: HorizontalPoint(x: origin, y: origin)
        )
    }

    private func snap(_ x: Double, _ y: Double, spacing: Double = 1_000_000,
                      origin: Double = 0, divisor: Int = 1) -> HorizontalPoint {
        HorizontalCanvasInputCore.snapToGrid(
            HorizontalPoint(x: x, y: y),
            grid: grid(spacing: spacing, origin: origin),
            divisor: divisor
        )
    }

    func testSnapsToTheNearestIntersection() {
        XCTAssertEqual(snap(400_000, 600_000).x, 0)
        XCTAssertEqual(snap(400_000, 600_000).y, 1_000_000)
    }

    func testExactIntersectionIsUnchanged() {
        let point = snap(3_000_000, -2_000_000)
        XCTAssertEqual(point.x, 3_000_000)
        XCTAssertEqual(point.y, -2_000_000)
    }

    /// Snapping must be idempotent, or repeated edits would drift a point across
    /// the board one rounding at a time.
    func testSnappingIsIdempotent() {
        let once = snap(1_234_567, -7_654_321)
        let twice = HorizontalCanvasInputCore.snapToGrid(
            once, grid: grid(spacing: 1_000_000), divisor: 1)
        XCTAssertEqual(once.x, twice.x)
        XCTAssertEqual(once.y, twice.y)
    }

    /// Halves round away from the origin on BOTH sides, so dragging left and
    /// right across the same boundary behaves the same rather than favouring one
    /// direction.
    func testHalfStepsRoundAwayFromZeroSymmetrically() {
        XCTAssertEqual(snap(500_000, 0).x, 1_000_000)
        XCTAssertEqual(snap(-500_000, 0).x, -1_000_000)
    }

    func testNegativeCoordinatesSnapSymmetrically() {
        XCTAssertEqual(snap(-400_000, 0).x, 0)
        XCTAssertEqual(snap(-600_000, 0).x, -1_000_000)
    }

    /// The fine-grid modifier subdivides the spacing.
    func testDivisorSubdividesTheGrid() {
        XCTAssertEqual(snap(120_000, 0, divisor: 10).x, 100_000)
        XCTAssertEqual(snap(120_000, 0, divisor: 1).x, 0)
    }

    /// A non-zero origin anchors the grid, so intersections are offset by it
    /// rather than sitting on multiples of the spacing.
    func testOriginAnchorsTheGrid() {
        XCTAssertEqual(snap(260_000, 0, spacing: 1_000_000, origin: 250_000).x, 250_000)
        XCTAssertEqual(snap(760_000, 0, spacing: 1_000_000, origin: 250_000).x, 1_250_000)
    }

    /// Degenerate inputs must not divide by zero or collapse the grid.
    func testDegenerateDivisorAndSpacingAreClamped() {
        XCTAssertEqual(snap(400_000, 0, divisor: 0).x, 0, "divisor below 1 is clamped")
        XCTAssertEqual(snap(400_000, 0, divisor: -5).x, 0)
        // A divisor finer than the spacing clamps to a 1nm grid rather than 0.
        let fine = snap(400_123, 0, spacing: 1_000, divisor: 100_000)
        XCTAssertEqual(fine.x, 400_123)
    }
}
