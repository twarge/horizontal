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

    // MARK: Adjusting a corner rounded off before

    private func roundedSquare(radius: Double, vertex: Int = 1, flipped: Bool = false) throws -> HorizontalPolygon {
        let rounding = try XCTUnwrap(HorizontalPolygonRounding(polygon: square(), vertexIndex: vertex))
        return rounding.polygon(radius: radius, reverse: flipped ? !rounding.reverse : nil)
    }

    private func assertSquare(_ polygon: HorizontalPolygon, file: StaticString = #filePath, line: UInt = #line) {
        let expected = square().polygonVertices.map(\.position)
        XCTAssertEqual(polygon.polygonVertices.count, expected.count, file: file, line: line)
        for (vertex, point) in zip(polygon.polygonVertices, expected) {
            XCTAssertEqual(vertex.type, .line, file: file, line: line)
            assertPoint(vertex.position, point.x, point.y, file: file, line: line)
        }
    }

    func testEitherEndOfARoundedCornerFindsItsCornerAndRadius() throws {
        let rounded = try roundedSquare(radius: 2 * mm)
        for index in [1, 2] {
            let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: index), "vertex \(index)")
            let existing = try XCTUnwrap(rounding.existing)
            XCTAssertEqual(existing.radius, 2 * mm, accuracy: 1)
            XCTAssertFalse(existing.reverse)
            XCTAssertFalse(existing.endIsFirst)
            XCTAssertEqual(rounding.vertexIndex, 1)
            assertPoint(rounding.corner, 10 * mm, 0)
            XCTAssertEqual(rounding.maxRadius, 10 * mm, accuracy: 1)
            assertSquare(rounding.original)
        }
        // So does the arc's centre, which names the arc's start.
        let fromCenter = try XCTUnwrap(HorizontalPolygonRounding(roundedCornerOf: rounded, arcStart: 1))
        XCTAssertEqual(fromCenter.existing?.radius ?? 0, 2 * mm, accuracy: 1)
        XCTAssertNil(HorizontalPolygonRounding(roundedCornerOf: rounded, arcStart: 2), "vertex 2 starts a straight edge")
        // A sharp corner of it is no rounded one.
        XCTAssertNil(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: 3))
    }

    func testARoundedCornerGrowsShrinksAndGoesSharpAgain() throws {
        let rounded = try roundedSquare(radius: 2 * mm)
        let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: 2))

        let larger = rounding.polygon(radius: 3 * mm)
        XCTAssertEqual(larger.polygonVertices.count, 5)
        XCTAssertEqual(larger.polygonVertices[1].type, .arc)
        assertPoint(larger.polygonVertices[1].position, 7 * mm, 0)
        assertPoint(larger.polygonVertices[1].arcCenter, 7 * mm, 3 * mm)
        assertPoint(larger.polygonVertices[2].position, 10 * mm, 3 * mm)
        XCTAssertEqual(rounding.vertexIndex(roundedAt: 3 * mm), 1)

        // The cursor sets it as for a sharp corner: at the corner, or past
        // it, the arc goes and the corner is sharp again.
        XCTAssertEqual(rounding.radius(for: HorizontalPoint(x: 9 * mm, y: mm)), mm, accuracy: 1)
        XCTAssertEqual(rounding.radius(for: rounding.corner), 0)
        XCTAssertEqual(rounding.radius(for: HorizontalPoint(x: 11 * mm, y: -mm)), 0)
        assertSquare(rounding.polygon(radius: rounding.radius(for: rounding.corner)))
        assertSquare(rounding.polygon(radius: 0.4))
        XCTAssertEqual(rounding.vertexIndex(roundedAt: 0), 1, "the sharp corner is where the arc started")
    }

    func testAFlippedArcKeepsItsDirection() throws {
        let rounded = try roundedSquare(radius: 2 * mm, flipped: true)
        XCTAssertTrue(rounded.polygonVertices[1].arcReverse)
        let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: 1))
        XCTAssertEqual(rounding.existing?.reverse, true)
        XCTAssertFalse(rounding.reverse, "the corner's own direction is still the short way round")
        XCTAssertEqual(rounding.existing?.radius ?? 0, 2 * mm, accuracy: 1)
    }

    func testAnArcAtTheLargestRadiusIsStillARoundedCorner() throws {
        // At the largest radius the arc starts on the previous vertex.
        let rounded = try roundedSquare(radius: 10 * mm)
        assertPoint(rounded.polygonVertices[1].position, 0, 0)
        let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: 1))
        XCTAssertEqual(rounding.existing?.radius ?? 0, 10 * mm, accuracy: 1)
        assertPoint(rounding.corner, 10 * mm, 0)
        assertSquare(rounding.original)
    }

    func testAnArcEndingOnTheFirstVertexStaysThere() throws {
        // The rounded square turned so its arc starts on the last vertex
        // and ends on the first.
        var turned = try roundedSquare(radius: 2 * mm)
        let vertices = turned.polygonVertices
        turned.polygonVertices = Array(vertices[2...] + vertices[..<2])
        XCTAssertEqual(turned.polygonVertices[4].type, .arc)

        let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: turned, vertexIndex: 0))
        XCTAssertEqual(rounding.existing?.endIsFirst, true)
        XCTAssertEqual(rounding.existing?.radius ?? 0, 2 * mm, accuracy: 1)
        XCTAssertEqual(rounding.vertexIndex, 3, "the corner is last once the arc is out")

        let larger = rounding.polygon(radius: 3 * mm).polygonVertices
        XCTAssertEqual(larger.count, 5)
        XCTAssertEqual(larger[4].type, .arc)
        assertPoint(larger[4].position, 7 * mm, 0)
        assertPoint(larger[0].position, 10 * mm, 3 * mm)
        assertPoint(larger[1].position, 10 * mm, 10 * mm)
        XCTAssertEqual(rounding.vertexIndex(roundedAt: 3 * mm), 4)

        let sharp = rounding.polygon(radius: 0).polygonVertices
        XCTAssertEqual(sharp.count, 4)
        assertPoint(sharp[0].position, 10 * mm, 10 * mm)
        assertPoint(sharp[3].position, 10 * mm, 0)
        XCTAssertEqual(rounding.vertexIndex(roundedAt: 0), 3)
    }

    func testARoundedTriangleCornerIsFound() throws {
        let triangle = HorizontalPolygon(id: "t", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10 * mm, y: 0), HorizontalPoint(x: 0, y: 10 * mm),
        ], layer: 0)
        let rounded = try XCTUnwrap(HorizontalPolygonRounding(polygon: triangle, vertexIndex: 1)).polygon(radius: mm)
        XCTAssertEqual(rounded.polygonVertices.count, 4)
        let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: 2))
        XCTAssertEqual(rounding.existing?.radius ?? 0, mm, accuracy: 2)
        assertPoint(rounding.corner, 10 * mm, 0, accuracy: 10)
        XCTAssertEqual(rounding.original.polygonVertices.count, 3)
    }

    func testOtherArcsAreNotRoundedCorners() throws {
        // A half circle: its tangents never meet.
        var halfCircle = square()
        halfCircle.polygonVertices[1].type = .arc
        halfCircle.polygonVertices[1].arcCenter = HorizontalPoint(x: 10 * mm, y: 5 * mm)
        XCTAssertNil(HorizontalPolygonRounding.roundedCorner(of: halfCircle, vertexIndex: 1))
        XCTAssertNil(HorizontalPolygonRounding.roundedCorner(of: halfCircle, vertexIndex: 2))

        // An arc whose centre is off the bisector isn't tangent to both edges.
        var skewed = try roundedSquare(radius: 2 * mm)
        skewed.polygonVertices[1].arcCenter = HorizontalPoint(x: 8 * mm, y: 2.5 * mm)
        XCTAssertNil(HorizontalPolygonRounding.roundedCorner(of: skewed, vertexIndex: 1))

        // An arc running on into another arc has no straight edge after it.
        var chained = try roundedSquare(radius: 2 * mm)
        chained.polygonVertices[2].type = .arc
        chained.polygonVertices[2].arcCenter = HorizontalPoint(x: 10 * mm, y: 6 * mm)
        XCTAssertNil(HorizontalPolygonRounding(roundedCornerOf: chained, arcStart: 1))
    }

    func testRoundedPointsAreWholeNanometres() throws {
        // A 60° corner puts the arc's ends and centre off the nanometre grid.
        let triangle = HorizontalPolygon(id: "t", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10 * mm, y: 0), HorizontalPoint(x: 5 * mm, y: 8.660_254 * mm),
        ], layer: 0)
        let rounded = try XCTUnwrap(HorizontalPolygonRounding(polygon: triangle, vertexIndex: 1)).polygon(radius: 1.234_567 * mm)
        for vertex in rounded.polygonVertices {
            XCTAssertEqual(vertex.position.x, vertex.position.x.rounded())
            XCTAssertEqual(vertex.position.y, vertex.position.y.rounded())
        }
        XCTAssertEqual(rounded.polygonVertices[1].arcCenter.x, rounded.polygonVertices[1].arcCenter.x.rounded())
        XCTAssertEqual(rounded.polygonVertices[1].arcCenter.y, rounded.polygonVertices[1].arcCenter.y.rounded())
        let rounding = try XCTUnwrap(HorizontalPolygonRounding.roundedCorner(of: rounded, vertexIndex: 1))
        XCTAssertEqual(rounding.existing?.radius ?? 0, 1.234_567 * mm, accuracy: 2)
        assertPoint(rounding.corner, 10 * mm, 0, accuracy: 10)
    }
}
