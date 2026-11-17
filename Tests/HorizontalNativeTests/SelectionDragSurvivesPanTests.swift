import CoreGraphics
import XCTest
@testable import HorizontalNative

/// An area selection drawn while the canvas pans keeps the region where it
/// was drawn on the document, not where it was drawn on the screen.
final class SelectionDragSurvivesPanTests: XCTestCase {
    /// A viewport that maps screen to world by an offset alone.
    private func toWorld(panX: Double) -> (CGPoint) -> HorizontalPoint {
        { HorizontalPoint(x: Double($0.x) + panX, y: Double($0.y)) }
    }

    func testPointsKeepTheWorldPositionTheyWereDrawnAt() {
        let first = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        var preview = HorizontalSelectionDragPreview(
            tool: .lasso,
            start: first[0],
            current: first[1],
            points: first,
            toWorld: toWorld(panX: 0)
        )

        // The canvas pans by 500 mid-drag, then the pointer moves on.
        let second = first + [CGPoint(x: 100, y: 100)]
        XCTAssertTrue(preview.extend(current: second[2], points: second, toWorld: toWorld(panX: 500)))

        XCTAssertEqual(preview.start, HorizontalPoint(x: 0, y: 0))
        XCTAssertEqual(preview.points, [
            HorizontalPoint(x: 0, y: 0),
            HorizontalPoint(x: 100, y: 0),
            HorizontalPoint(x: 600, y: 100)
        ])
        XCTAssertEqual(preview.current, CGPoint(x: 100, y: 100))
    }

    func testAShorterTrailIsADifferentDrag() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        var preview = HorizontalSelectionDragPreview(
            tool: .lasso,
            start: points[0],
            current: points[1],
            points: points,
            toWorld: toWorld(panX: 0)
        )
        XCTAssertFalse(preview.extend(current: .zero, points: [.zero], toWorld: toWorld(panX: 500)))
        XCTAssertEqual(preview.points.count, 2)
    }
}
