import XCTest
@testable import HorizontalNative

/// Horizon's round-off-vertex geometry: a corner becomes an arc tangent to
/// both edges, with the radius set by where the cursor is.
final class HorizontalPolygonRoundingTests: XCTestCase {
    private let mm = 1_000_000.0

    private func square(clockwise: Bool = false) -> HorizontalPolygon {
        var points = [
            HorizontalPoint(x: 0, y: 0),
            HorizontalPoint(x: 10 * mm, y: 0),
            HorizontalPoint(x: 10 * mm, y: 10 * mm),
            HorizontalPoint(x: 0, y: 10 * mm),
        ]
        if clockwise {
            points.reverse()
        }
        return HorizontalPolygon(id: "square", vertices: points, layer: 0)
    }

    private func assertPoint(_ point: HorizontalPoint, _ x: Double, _ y: Double, accuracy: Double = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: accuracy, file: file, line: line)
    }

    func testRightAngleCornerBecomesATangentQuarterArc() throws {
        let rounding = try XCTUnwrap(HorizontalPolygonRounding(polygon: square(), vertexIndex: 1))
        XCTAssertEqual(rounding.halfAngle, .pi / 4, accuracy: 1e-9)
        // The arc reaches the neighbouring vertices when its radius is the edge length.
        XCTAssertEqual(rounding.maxRadius, 10 * mm, accuracy: 1)
        XCTAssertFalse(rounding.reverse)

        let rounded = rounding.polygon(radius: 2 * mm)
        XCTAssertEqual(rounded.polygonVertices.count, 5)
        let start = rounded.polygonVertices[1]
        XCTAssertEqual(start.type, .arc)
        assertPoint(start.position, 8 * mm, 0)
        assertPoint(start.arcCenter, 8 * mm, 2 * mm)
        XCTAssertFalse(start.arcReverse)
        let end = rounded.polygonVertices[2]
        XCTAssertEqual(end.type, .line)
        assertPoint(end.position, 10 * mm, 2 * mm)
        // The rest of the polygon is untouched.
        assertPoint(rounded.polygonVertices[0].position, 0, 0)
        assertPoint(rounded.polygonVertices[3].position, 10 * mm, 10 * mm)
        assertPoint(rounded.polygonVertices[4].position, 0, 10 * mm)
        XCTAssertEqual(rounded.id, "square")
        XCTAssertEqual(rounded.layer, 0)
    }

    func testCursorSetsTheRadiusFromItsProjectionOntoTheBisector() throws {
        let rounding = try XCTUnwrap(HorizontalPolygonRounding(polygon: square(), vertexIndex: 1))
        // On the bisector, the cursor is exactly the arc centre.
        let radius = rounding.radius(for: HorizontalPoint(x: 7 * mm, y: 3 * mm))
        XCTAssertEqual(radius, 3 * mm, accuracy: 1)
        assertPoint(rounding.polygon(radius: radius).polygonVertices[1].arcCenter, 7 * mm, 3 * mm)
        // Off the bisector only the component along it counts.
        XCTAssertEqual(rounding.radius(for: HorizontalPoint(x: 7 * mm, y: 0)), 1.5 * mm, accuracy: 1)
        // Beyond the corner there is no arc; past the neighbours it stops growing.
        XCTAssertEqual(rounding.radius(for: HorizontalPoint(x: 12 * mm, y: -2 * mm)), 0)
        XCTAssertEqual(rounding.radius(for: HorizontalPoint(x: -20 * mm, y: 30 * mm)), 10 * mm, accuracy: 1)
        XCTAssertEqual(rounding.radius(for: rounding.corner), 0)
    }

    func testClockwiseWindingReversesTheArcAndAnOverrideFlipsIt() throws {
        let rounding = try XCTUnwrap(HorizontalPolygonRounding(polygon: square(clockwise: true), vertexIndex: 2))
        XCTAssertTrue(rounding.reverse)
        XCTAssertTrue(rounding.polygon(radius: mm).polygonVertices[2].arcReverse)
        XCTAssertFalse(rounding.polygon(radius: mm, reverse: false).polygonVertices[2].arcReverse)
    }

    func testLastVertexInsertsItsArcEndAtTheEnd() throws {
        let rounding = try XCTUnwrap(HorizontalPolygonRounding(polygon: square(), vertexIndex: 3))
        let rounded = rounding.polygon(radius: mm)
        XCTAssertEqual(rounded.polygonVertices.count, 5)
        XCTAssertEqual(rounded.polygonVertices[3].type, .arc)
        assertPoint(rounded.polygonVertices[3].position, mm, 10 * mm)
        assertPoint(rounded.polygonVertices[4].position, 0, 9 * mm)
        assertPoint(rounded.polygonVertices[0].position, 0, 0)

        let first = try XCTUnwrap(HorizontalPolygonRounding(polygon: square(), vertexIndex: 0))
        let roundedFirst = first.polygon(radius: mm)
        assertPoint(roundedFirst.polygonVertices[0].position, 0, mm)
        assertPoint(roundedFirst.polygonVertices[1].position, mm, 0)
        assertPoint(roundedFirst.polygonVertices[2].position, 10 * mm, 0)
    }

    func testArcsCollinearEdgesAndTinyPolygonsCannotBeRounded() {
        var arced = square()
        arced.polygonVertices[1].type = .arc
        arced.polygonVertices[1].arcCenter = HorizontalPoint(x: 10 * mm, y: 5 * mm)
        XCTAssertNil(HorizontalPolygonRounding(polygon: arced, vertexIndex: 1), "the vertex starts an arc")
        XCTAssertNil(HorizontalPolygonRounding(polygon: arced, vertexIndex: 2), "the previous edge is an arc")
        XCTAssertNotNil(HorizontalPolygonRounding(polygon: arced, vertexIndex: 3))

        let collinear = HorizontalPolygon(id: "c", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 5 * mm, y: 0), HorizontalPoint(x: 10 * mm, y: 0), HorizontalPoint(x: 5 * mm, y: 5 * mm),
        ], layer: 0)
        XCTAssertNil(HorizontalPolygonRounding(polygon: collinear, vertexIndex: 1))
        XCTAssertNotNil(HorizontalPolygonRounding(polygon: collinear, vertexIndex: 2))

        let line = HorizontalPolygon(id: "l", vertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: mm, y: 0)], layer: 0)
        XCTAssertNil(HorizontalPolygonRounding(polygon: line, vertexIndex: 0))
        XCTAssertNil(HorizontalPolygonRounding(polygon: square(), vertexIndex: 4))
    }
}
