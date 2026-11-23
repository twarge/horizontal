import XCTest
@testable import HorizontalNative

/// Draw Dimension's three clicks: two points to measure between, then where
/// the dimension's line goes. From the second click it is previewed whole,
/// following the cursor; the third sets its distance from the points and the
/// side it lies on.
final class BoardDrawDimensionTests: XCTestCase {
    private let mm = 1_000_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func key(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())),\(Int64(point.y.rounded()))"
    }

    private func dimension(_ points: [HorizontalPoint], cursor: HorizontalPoint? = nil) -> HorizontalDimension? {
        BoardDrawDimension.dimension(id: "d", points: points, cursor: cursor, pointKey: key)
    }

    func testThereIsNoDimensionUntilTwoPointsApartAreDown() {
        XCTAssertNil(dimension([], cursor: point(5, 5)))
        XCTAssertNil(dimension([point(0, 0)], cursor: point(5, 5)), "one point: the line tool's rubber band still")
        XCTAssertNil(dimension([point(0, 0), point(0, 0)], cursor: point(5, 5)), "a double-click is one point")
        XCTAssertNotNil(dimension([point(0, 0), point(10, 0)]))
    }

    /// After the second click the dimension follows the cursor: as far from
    /// the points as the cursor is from the line through them, on its side.
    func testTheCursorCarriesTheDimensionsLineAfterTheSecondPoint() throws {
        let points = [point(0, 0), point(10, 0)]
        let above = try XCTUnwrap(dimension(points, cursor: point(3, 4)))
        XCTAssertEqual(above.p0, point(0, 0))
        XCTAssertEqual(above.p1, point(10, 0))
        XCTAssertEqual(above.labelDistance, 4 * mm)
        XCTAssertEqual(above.mode, .distance)
        let below = try XCTUnwrap(dimension(points, cursor: point(30, -2.5)))
        XCTAssertEqual(below.labelDistance, -2.5 * mm, "the other side, and past the points' ends counts the same")

        // Its line passes through the cursor.
        let anchor = try XCTUnwrap(BoardDimensionParts.labelAnchor(of: above))
        XCTAssertEqual(anchor.y, 4 * mm, accuracy: 1)

        // On a slant: the distance is across the line, not along an axis.
        let slanted = try XCTUnwrap(dimension([point(0, 0), point(10, 10)], cursor: point(0, 10)))
        XCTAssertEqual(slanted.labelDistance, (50.0).squareRoot() * mm, accuracy: 1)
        let other = try XCTUnwrap(dimension([point(0, 0), point(10, 10)], cursor: point(10, 0)))
        XCTAssertEqual(other.labelDistance, -(50.0).squareRoot() * mm, accuracy: 1)
    }

    func testTheThirdPointSetsTheOffsetWhereverTheCursorGoesNext() throws {
        let placed = try XCTUnwrap(dimension([point(0, 0), point(10, 0), point(5, 6)], cursor: point(5, -20)))
        XCTAssertEqual(placed.labelDistance, 6 * mm)
        XCTAssertEqual(placed.labelSize, BoardDrawDimension.labelSize)
    }

    /// Return straight after the second click, the cursor still on it, and a
    /// third click on the line between the points: a dimension drawn on its
    /// own points would hide them, so it takes the usual distance.
    func testAPointOnTheLineBetweenTheTwoTakesTheUsualDistance() throws {
        let points = [point(0, 0), point(10, 0)]
        XCTAssertEqual(try XCTUnwrap(dimension(points, cursor: point(10, 0))).labelDistance, BoardDrawDimension.defaultLabelDistance)
        XCTAssertEqual(try XCTUnwrap(dimension(points)).labelDistance, BoardDrawDimension.defaultLabelDistance)
        XCTAssertEqual(try XCTUnwrap(dimension(points + [point(4, 0)])).labelDistance, BoardDrawDimension.defaultLabelDistance)
    }

    /// The preview draws what the dimension will: extension lines from the
    /// points past its line, the line itself, arrowheads and the label.
    func testThePreviewDrawsTheWholeDimension() throws {
        let previewed = try XCTUnwrap(dimension([point(0, 0), point(40, 0)], cursor: point(20, 5)))
        let strokes = BoardDrawDimension.strokes(of: previewed)
        func has(_ from: HorizontalPoint, _ to: HorizontalPoint) -> Bool {
            strokes.contains { abs($0.from.x - from.x) < 1 && abs($0.from.y - from.y) < 1 && abs($0.to.x - to.x) < 1 && abs($0.to.y - to.y) < 1 }
        }
        XCTAssertTrue(has(point(0, 0), point(0, 5.75)), "an extension line, half a label's height past the line")
        XCTAssertTrue(has(point(40, 0), point(40, 5.75)))
        XCTAssertTrue(strokes.contains { $0.from == point(0, 5) && $0.to.y == 5 * mm && $0.to.x < 20 * mm },
                      "the line from its start to the label")
        XCTAssertTrue(strokes.contains { $0.to == point(40, 5) && $0.from.y == 5 * mm && $0.from.x > 20 * mm })
        XCTAssertTrue(has(point(0, 5), point(1.5, 5.75)), "an arrowhead at each end, pointing in")
        XCTAssertTrue(has(point(40, 5), point(38.5, 4.25)))
        let label = try XCTUnwrap(previewed.labelText)
        XCTAssertGreaterThan(strokes.count, 8 + HorizontalOutlineTextRenderer.outlineSegments(for: label).count - 1, "and the label's strokes")

        // Too short for its label: one unbroken line.
        let short = try XCTUnwrap(dimension([point(0, 0), point(5, 0)], cursor: point(0, 3)))
        XCTAssertTrue(BoardDrawDimension.strokes(of: short).contains { $0.from == point(0, 3) && $0.to == point(5, 3) })
    }
}
