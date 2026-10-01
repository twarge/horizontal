import XCTest
@testable import HorizontalNative

final class HorizontalCanvasWarningGeometryTests: XCTestCase {
    private let warning = HorizontalCanvasWarning(position: .init(x: 2_000_000, y: 3_000_000), messages: ["Net label on pin"])

    func testMetalWarningsHaveWorldAnchorsAndFixedPixelGeometry() {
        let triangles = HorizontalCanvasWarningGeometry.triangles(for: [warning])
        XCTAssertEqual(triangles.count, 6)
        XCTAssertTrue(triangles.allSatisfy { $0.worldAnchor == warning.position })
        let xs = triangles.flatMap { [$0.ax, $0.bx, $0.cx] }
        let ys = triangles.flatMap { [$0.ay, $0.by, $0.cy] }
        XCTAssertEqual(xs.max()! - xs.min()!, 18)
        XCTAssertEqual(ys.max()! - ys.min()!, 16)
        var moved = warning
        moved.position = .init(x: 8_000_000, y: -4_000_000)
        let movedTriangles = HorizontalCanvasWarningGeometry.triangles(for: [moved])
        for (original, moved) in zip(triangles, movedTriangles) {
            XCTAssertNotEqual(original.worldAnchor, moved.worldAnchor)
            XCTAssertEqual(original.ax, moved.ax)
            XCTAssertEqual(original.ay, moved.ay)
            XCTAssertEqual(original.bx, moved.bx)
            XCTAssertEqual(original.by, moved.by)
            XCTAssertEqual(original.cx, moved.cx)
            XCTAssertEqual(original.cy, moved.cy)
        }
    }

    func testHitTestingFollowsZoomPanAndMirroringWithoutScalingHitArea() {
        for zoom in [0.25, 1, 8] {
            for mirrored in [false, true] {
                let transform = HorizontalCanvasTransform(
                    bounds: .init(points: [.init(x: -10_000_000, y: -10_000_000), .init(x: 10_000_000, y: 10_000_000)]),
                    size: .init(width: 800, height: 600), zoom: zoom,
                    pan: .init(width: 45, height: -20), mirrored: mirrored)
                let anchor = transform.point(warning.position)
                let center = CGPoint(x: anchor.x + 12, y: anchor.y - 12)
                XCTAssertEqual(HorizontalCanvasWarningGeometry.hitTest(center, warnings: [warning], transform: transform), warning)
                XCTAssertEqual(HorizontalCanvasWarningGeometry.hitTest(.init(x: center.x + 9, y: center.y + 9), warnings: [warning], transform: transform), warning)
                XCTAssertNil(HorizontalCanvasWarningGeometry.hitTest(.init(x: center.x + 11, y: center.y), warnings: [warning], transform: transform))
                XCTAssertNil(HorizontalCanvasWarningGeometry.hitTest(anchor, warnings: [warning], transform: transform))
            }
        }
    }

    func testOverlappingWarningsHitTopmostMarkerAndEmptyWarningsProduceNoGeometry() {
        var top = warning
        top.messages = ["Line on pin"]
        let transform = HorizontalCanvasTransform(bounds: .init(points: [.zero, .init(x: 10_000_000, y: 10_000_000)]), size: .init(width: 800, height: 600))
        let point = transform.point(warning.position)
        XCTAssertEqual(HorizontalCanvasWarningGeometry.hitTest(.init(x: point.x + 12, y: point.y - 12), warnings: [warning, top], transform: transform), top)
        XCTAssertTrue(HorizontalCanvasWarningGeometry.triangles(for: []).isEmpty)
        XCTAssertNil(HorizontalCanvasWarningGeometry.hitTest(.zero, warnings: [], transform: transform))
    }

    func testExistingScreenTrianglesRemainUnanchored() {
        let triangle = HorizontalMetalScreenTrianglePrimitive(a: .zero, b: .init(x: 1, y: 0), c: .init(x: 0, y: 1),
                                                              color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertNil(triangle.worldAnchor)
    }
}
