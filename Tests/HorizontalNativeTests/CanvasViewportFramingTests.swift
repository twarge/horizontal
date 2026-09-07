import XCTest
@testable import HorizontalNative

/// `CanvasViewport.framing`: the viewport that puts a world rectangle in the
/// middle of the canvas at a zoom that fits it.
final class CanvasViewportFramingTests: XCTestCase {
    private let bounds = HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 100_000_000, y: 50_000_000)])
    private let size = CGSize(width: 800, height: 600)

    private func transform(_ viewport: CanvasViewport) -> HorizontalCanvasTransform {
        HorizontalCanvasTransform(bounds: bounds, size: size, fitInsets: .defaultFit, zoom: viewport.zoom, pan: viewport.pan)
    }

    func testTheRectangleLandsCenteredAndFits() {
        let rect = HorizontalRect(points: [HorizontalPoint(x: 60_000_000, y: 10_000_000), HorizontalPoint(x: 70_000_000, y: 15_000_000)])
        let viewport = CanvasViewport.framing(rect, in: transform(CanvasViewport()))
        let framed = transform(viewport)

        let center = framed.point(rect.center)
        XCTAssertEqual(center.x, size.width / 2, accuracy: 0.5)
        XCTAssertEqual(center.y, size.height / 2, accuracy: 0.5)

        let corners = [
            framed.point(HorizontalPoint(x: rect.minX, y: rect.minY)),
            framed.point(HorizontalPoint(x: rect.maxX, y: rect.maxY))
        ]
        for corner in corners {
            XCTAssertGreaterThan(corner.x, 0)
            XCTAssertLessThan(corner.x, size.width)
            XCTAssertGreaterThan(corner.y, 0)
            XCTAssertLessThan(corner.y, size.height)
        }
        // Filling 85% of the available width: the 10 mm span covers most of it.
        XCTAssertGreaterThan(abs(corners[1].x - corners[0].x), size.width * 0.5)
        XCTAssertTrue(framed.visibleBounds.minX <= rect.minX && framed.visibleBounds.maxX >= rect.maxX)
    }

    func testZoomIsClampedAndEmptyInputsAreSafe() {
        let tiny = HorizontalRect(points: [HorizontalPoint(x: 1_000, y: 1_000), HorizontalPoint(x: 2_000, y: 2_000)])
        let viewport = CanvasViewport.framing(tiny, in: transform(CanvasViewport()))
        XCTAssertLessThanOrEqual(viewport.zoom, CanvasViewport.maximumZoom)
        XCTAssertGreaterThanOrEqual(viewport.zoom, CanvasViewport.minimumZoom)

        let emptyCanvas = HorizontalCanvasTransform(bounds: .empty, size: size, fitInsets: .defaultFit)
        XCTAssertEqual(CanvasViewport.framing(tiny, in: emptyCanvas), CanvasViewport())
        let point = HorizontalRect(points: [HorizontalPoint(x: 5_000_000, y: 5_000_000)])
        XCTAssertTrue(CanvasViewport.framing(point, in: transform(CanvasViewport())).zoom.isFinite)
    }
}
