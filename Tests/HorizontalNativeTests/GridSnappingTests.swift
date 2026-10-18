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

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x, y: y)
    }

    private func gridSnap(_ point: HorizontalPoint) -> HorizontalPoint {
        HorizontalCanvasInputCore.snapToGrid(point, grid: grid(spacing: 1_000_000), divisor: 1)
    }

    func testCursorTrackedMoveHoistsGrabbedPointOntoGrid() {
        let grabbedVertex = HorizontalPoint(x: 400_000, y: 600_000)
        let snappedCursor = snap(grabbedVertex.x, grabbedVertex.y)

        let initial = HorizontalCanvasModeSupport.moveInitialPoints(
            startPoint: grabbedVertex,
            snappedCursorPoint: snappedCursor,
            tracksCursor: true
        )

        XCTAssertEqual(initial.startPoint, grabbedVertex)
        XCTAssertEqual(initial.lastPoint, HorizontalPoint(x: 0, y: 1_000_000))
        XCTAssertEqual(initial.lastPoint - initial.startPoint, HorizontalPoint(x: -400_000, y: 400_000))
    }

    func testKeyboardMoveStartsWithoutAnImplicitSnapDelta() {
        let grabbedVertex = HorizontalPoint(x: 400_000, y: 600_000)

        let initial = HorizontalCanvasModeSupport.moveInitialPoints(
            startPoint: grabbedVertex,
            snappedCursorPoint: snap(grabbedVertex.x, grabbedVertex.y),
            tracksCursor: false
        )

        XCTAssertEqual(initial.startPoint, grabbedVertex)
        XCTAssertEqual(initial.lastPoint, grabbedVertex)
    }

    private func pivot(
        _ points: [String: [HorizontalPoint]],
        types: [String: HorizontalObjectType] = [:],
        snap: (HorizontalPoint, [HorizontalPoint]) -> HorizontalPoint
    ) -> HorizontalPoint? {
        let refs = points.keys.sorted().map { HorizontalSelectableRef(id: $0, type: types[$0] ?? .schematicSymbol) }
        return HorizontalCanvasModeSupport.selectionPivot(for: refs, origins: { points[$0.id] ?? [] }, snapToGrid: snap)
    }

    private func turned(_ point: HorizontalPoint, about pivot: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(x: pivot.x - (point.y - pivot.y), y: pivot.y + (point.x - pivot.x))
    }

    /// Two parts three grid steps apart have their middle half a step off the
    /// grid; turned about it, both left the grid. On a sheet the pivot goes
    /// onto the grid, and both stay on it.
    func testAGroupTurnsAboutAGridPoint() throws {
        let left = point(0, 0)
        let right = point(3_000_000, 0)
        let center = try XCTUnwrap(pivot(["a": [left], "b": [right]]) { center, _ in self.gridSnap(center) })

        XCTAssertEqual(gridSnap(center), center)
        for origin in [left, right] {
            let after = turned(origin, about: center)
            XCTAssertEqual(gridSnap(after), after, "\(origin) stays on the grid")
        }
    }

    /// One part — or several on one origin — turns about its own origin, on
    /// the grid or not.
    func testOnePartTurnsAboutItsOwnOrigin() {
        let origin = point(1_100_000, 2_300_000)
        let snapped = pivot(["a": [origin], "b": [origin]]) { center, _ in self.gridSnap(center) }
        XCTAssertEqual(snapped, origin)
    }

    /// On a board a group goes onto the grid only when every origin is on it;
    /// parts placed off the grid turn about their exact middle.
    func testABoardGroupOffTheGridTurnsAboutItsExactMiddle() {
        func boardSnap(_ center: HorizontalPoint, _ origins: [HorizontalPoint]) -> HorizontalPoint {
            origins.allSatisfy { HorizontalCanvasModeSupport.isOnGrid($0, snapToGrid: gridSnap) } ? gridSnap(center) : center
        }
        XCTAssertEqual(pivot(["a": [point(0, 0)], "b": [point(3_000_000, 0)]], snap: boardSnap),
                       point(2_000_000, 0))
        XCTAssertEqual(pivot(["a": [point(100_000, 0)], "b": [point(3_100_000, 0)]], snap: boardSnap),
                       point(1_600_000, 0))
    }

    /// A free text beside the parts doesn't pull the pivot; texts alone turn
    /// about their own middle.
    func testFreeTextsCountOnlyWhenNothingElseIsSelected() {
        let types: [String: HorizontalObjectType] = ["note": .text, "other": .text]
        let exact: (HorizontalPoint, [HorizontalPoint]) -> HorizontalPoint = { center, _ in center }
        XCTAssertEqual(pivot(["a": [point(2_000_000, 1_000_000)], "note": [point(9_300_000, 7_700_000)]], types: types, snap: exact),
                       point(2_000_000, 1_000_000))
        XCTAssertEqual(pivot(["note": [point(0, 0)], "other": [point(4_000_000, 0)]], types: types, snap: exact),
                       point(2_000_000, 0))
    }

    /// M picks up, and T turns about, the selection's own point under the
    /// cursor, else the grid point under it — not another object's point the
    /// cursor snapped to, which would carry the selection off the grid by how
    /// far that point sits off it.
    func testTheCursorHoldsTheSelectionByItsOwnPointOrAGridPoint() {
        let vertex = point(400_000, 600_000)
        XCTAssertEqual(HorizontalCanvasModeSupport.cursorAnchor(cursor: vertex, cursorIsOnSelection: true, snapToGrid: gridSnap),
                       vertex)
        XCTAssertEqual(HorizontalCanvasModeSupport.cursorAnchor(cursor: vertex, cursorIsOnSelection: false, snapToGrid: gridSnap),
                       point(0, 1_000_000))
    }
}
