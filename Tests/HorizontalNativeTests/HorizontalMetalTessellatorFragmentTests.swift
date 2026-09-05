import XCTest
@testable import HorizontalNative

/// Clipper fragments (outer contour first, then holes) triangulate to
/// exactly their area, whichever way the contours were wound.
final class HorizontalMetalTessellatorFragmentTests: XCTestCase {
    private func area(_ points: [HorizontalPoint]) -> Double {
        var area = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }
        return abs(area / 2)
    }

    private func circle(center: HorizontalPoint, radius: Double, segments: Int, clockwise: Bool) -> [HorizontalPoint] {
        let points = (0..<segments).map { index -> HorizontalPoint in
            let angle = Double(index) / Double(segments) * 2 * Double.pi
            return HorizontalPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        return clockwise ? points.reversed() : points
    }

    func testSlabWithManyHolesTriangulatesToItsArea() {
        let mm = 1_000_000.0
        var paths = [[HorizontalPoint]]()
        // A clockwise outer: the orientation must not matter.
        paths.append([
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 0, y: 20 * mm),
            HorizontalPoint(x: 30 * mm, y: 20 * mm), HorizontalPoint(x: 30 * mm, y: 0),
        ])
        var holeArea = 0.0
        for row in 0..<4 {
            for column in 0..<6 {
                let hole = circle(
                    center: HorizontalPoint(x: (2.5 + Double(column) * 5) * mm, y: (2.5 + Double(row) * 5) * mm),
                    radius: 0.8 * mm,
                    segments: 24,
                    clockwise: (row + column).isMultiple(of: 2)
                )
                holeArea += area(hole)
                paths.append(hole)
            }
        }
        let triangles = HorizontalMetalTessellator.fragmentTriangles(paths, color: HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertFalse(triangles.isEmpty)
        let triangleArea = triangles.reduce(0.0) { $0 + area([$1.a, $1.b, $1.c]) }
        let expected = area(paths[0]) - holeArea
        XCTAssertEqual(triangleArea, expected, accuracy: expected * 1e-6)
    }

    func testDegenerateFragmentsProduceNothing() {
        let black = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertTrue(HorizontalMetalTessellator.fragmentTriangles([], color: black).isEmpty)
        XCTAssertTrue(HorizontalMetalTessellator.fragmentTriangles([[HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 1, y: 1)]], color: black).isEmpty)
    }
}
