import XCTest
@testable import HorizontalNative

/// Guards the `renderBoundsPoints` fix: it must be a valid, simple (non
/// self-intersecting) rectangle so it works as a clip polygon for plane text
/// cutouts — not the old 5-point Z-order bowtie.
final class HorizontalTextBoundsTests: XCTestCase {
    private func makeText() -> HorizontalText {
        HorizontalText(
            id: "t1",
            text: "REF",
            position: HorizontalPoint(x: 1_000, y: 2_000),
            size: 1_500,
            layer: HorizontalBoardLayers.topCopper,
            angle: 0)
    }

    func testBoundsIsFourCornerSimpleRectangle() {
        let points = makeText().renderBoundsPoints
        XCTAssertEqual(points.count, 4, "should be exactly 4 corners (no appended position point)")

        // Proper rectangle winding: consecutive edges are axis-aligned and the
        // polygon is convex with positive area (not a bowtie).
        let area = signedArea(points)
        XCTAssertGreaterThan(abs(area), 0, "non-degenerate area")

        // A bowtie self-intersects; a simple rectangle does not. Check no two
        // non-adjacent edges cross.
        XCTAssertFalse(isSelfIntersecting(points), "bounds polygon must be simple, not a bowtie")
    }

    private func signedArea(_ points: [HorizontalPoint]) -> Double {
        var sum = 0.0
        for i in points.indices {
            let j = (i + 1) % points.count
            sum += points[i].x * points[j].y - points[j].x * points[i].y
        }
        return sum / 2
    }

    private func isSelfIntersecting(_ points: [HorizontalPoint]) -> Bool {
        let n = points.count
        for i in 0..<n {
            let a1 = points[i], a2 = points[(i + 1) % n]
            for j in (i + 1)..<n {
                // skip adjacent edges (they share a vertex)
                if j == i || (j + 1) % n == i || j == (i + 1) % n { continue }
                let b1 = points[j], b2 = points[(j + 1) % n]
                if segmentsCross(a1, a2, b1, b2) { return true }
            }
        }
        return false
    }

    private func segmentsCross(_ p1: HorizontalPoint, _ p2: HorizontalPoint, _ p3: HorizontalPoint, _ p4: HorizontalPoint) -> Bool {
        func cross(_ o: HorizontalPoint, _ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }
}
