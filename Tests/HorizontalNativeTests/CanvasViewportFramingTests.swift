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

    /// A viewport measures from its reference on the canvas the reference is
    /// for, whatever that canvas's content spans, and from the content on any
    /// other canvas or without one.
    func testAViewportMeasuresFromItsReferenceOnlyOnItsOwnCanvas() {
        let grown = HorizontalRect(points: [HorizontalPoint(x: -20_000_000, y: 0), HorizontalPoint(x: 180_000_000, y: 70_000_000)])
        let pinned = CanvasViewport(zoom: 2.5, pan: CGSize(width: -140, height: 65),
                                    reference: .init(identity: "sheet", bounds: bounds))
        XCTAssertEqual(pinned.measuringBounds(for: "sheet", contentBounds: grown), bounds)
        XCTAssertEqual(pinned.measuringBounds(for: "other sheet", contentBounds: grown), grown)
        XCTAssertEqual(pinned.measuringBounds(for: nil, contentBounds: grown), grown)
        XCTAssertEqual(CanvasViewport().measuringBounds(for: "sheet", contentBounds: grown), grown)

        var fitted = pinned
        fitted.fit()
        XCTAssertEqual(fitted, CanvasViewport(), "Fit measures from the content again")
    }

    /// Framed for a canvas, the viewport takes the bounds it was framed in as
    /// its reference, so the rectangle stays framed while the content
    /// changes; framed for none, it has no reference.
    func testFramingForACanvasPinsTheBoundsItWasFramedIn() {
        let rect = HorizontalRect(points: [HorizontalPoint(x: 60_000_000, y: 10_000_000), HorizontalPoint(x: 70_000_000, y: 15_000_000)])
        let framed = CanvasViewport.framing(rect, in: transform(CanvasViewport()), identity: "board")
        XCTAssertEqual(framed.reference, CanvasViewport.Reference(identity: "board", bounds: bounds))
        XCTAssertNil(CanvasViewport.framing(rect, in: transform(CanvasViewport())).reference)

        let grown = HorizontalRect(points: [HorizontalPoint(x: -20_000_000, y: 0), HorizontalPoint(x: 180_000_000, y: 70_000_000)])
        let shown = HorizontalCanvasTransform(bounds: framed.measuringBounds(for: "board", contentBounds: grown), size: size,
                                              fitInsets: .defaultFit, zoom: framed.zoom, pan: framed.pan)
        XCTAssertEqual(shown.point(rect.center).x, size.width / 2, accuracy: 0.5)
        XCTAssertEqual(shown.point(rect.center).y, size.height / 2, accuracy: 0.5)
    }

    /// A saved view keeps its reference, and one saved before views had one
    /// opens without, to be measured from the content it opens on.
    func testAViewKeepsItsReferenceThroughSavingAndAnOldOneHasNone() throws {
        let viewport = CanvasViewport(zoom: 3, pan: CGSize(width: 12.5, height: -40), mirrored: true,
                                      reference: .init(identity: "board-uuid", bounds: bounds))
        let decoded = try JSONDecoder().decode(CanvasViewport.self, from: JSONEncoder().encode(viewport))
        XCTAssertEqual(decoded, viewport)

        let old = try JSONDecoder().decode(CanvasViewport.self, from: Data(#"{"zoom":2,"panWidth":5,"panHeight":-7}"#.utf8))
        XCTAssertEqual(old, CanvasViewport(zoom: 2, pan: CGSize(width: 5, height: -7)))
        XCTAssertNil(old.reference)
        let unpinned = try JSONEncoder().encode(CanvasViewport(zoom: 2))
        XCTAssertFalse(String(decoding: unpinned, as: UTF8.self).contains("reference"))
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
