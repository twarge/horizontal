import XCTest
@testable import HorizontalNative

/// The plane tessellation cache is keyed by fragment CONTENT, which is what lets
/// it survive an edit that leaves the planes alone.
///
/// Before that, the cache was dropped on every commit. Moving a component does
/// not change a single plane fragment — the fills are not re-poured — but their
/// triangles were discarded, so the planes rendered empty until a background
/// pass caught up. That repaint is what read as a flash.
///
/// The risk the content hash removes: with a key of only path and vertex counts,
/// a fill whose vertices MOVED kept the same key, and preserving the cache would
/// have served it another shape's triangles. Cheap to get wrong, invisible in
/// the small, and wrong copper on screen.
final class BoardPlaneFragmentKeyTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func fragment(_ points: [HorizontalPoint], orphan: Bool = false) -> HorizontalPlaneFragment {
        HorizontalPlaneFragment(paths: [points], orphan: orphan)
    }

    private func key(_ fragment: HorizontalPlaneFragment, plane: String = "p1", index: Int = 0)
        -> BoardPlaneFragmentKey {
        boardPlaneFragmentKey(planeID: plane, fragmentIndex: index, fragment: fragment)
    }

    func testIdenticalFragmentsShareAKey() {
        let a = fragment([p(0, 0), p(1, 0), p(1, 1)])
        let b = fragment([p(0, 0), p(1, 0), p(1, 1)])
        XCTAssertEqual(key(a), key(b), "an unchanged fill must keep its triangulation")
    }

    /// The case the old key missed: same shape count, same vertex count, moved
    /// geometry. Without this the cache would serve the wrong triangles.
    func testMovedVertexChangesTheKey() {
        let before = fragment([p(0, 0), p(1, 0), p(1, 1)])
        let after = fragment([p(0, 0), p(2, 0), p(1, 1)])
        XCTAssertEqual(before.paths.count, after.paths.count, "precondition: same path count")
        XCTAssertEqual(before.paths[0].count, after.paths[0].count, "precondition: same vertex count")

        XCTAssertNotEqual(key(before), key(after))
    }

    /// Winding matters to a triangulation, so the same points in a different
    /// order are a different fill.
    func testReorderedVerticesChangeTheKey() {
        let a = fragment([p(0, 0), p(1, 0), p(1, 1)])
        let b = fragment([p(1, 1), p(1, 0), p(0, 0)])
        XCTAssertNotEqual(key(a), key(b))
    }

    func testOrphanFlagAndIdentityStillSeparateFragments() {
        let points = [p(0, 0), p(1, 0), p(1, 1)]
        XCTAssertNotEqual(key(fragment(points)), key(fragment(points, orphan: true)))
        XCTAssertNotEqual(key(fragment(points)), key(fragment(points), plane: "p2"))
        XCTAssertNotEqual(key(fragment(points)), key(fragment(points), index: 1))
    }

    /// A hole added to a fragment changes what is drawn, so it must change the key
    /// even though the outer contour is untouched.
    func testAddingAHoleChangesTheKey() {
        let solid = HorizontalPlaneFragment(paths: [[p(0, 0), p(4, 0), p(4, 4), p(0, 4)]], orphan: false)
        let holed = HorizontalPlaneFragment(
            paths: [[p(0, 0), p(4, 0), p(4, 4), p(0, 4)], [p(1, 1), p(2, 1), p(2, 2)]],
            orphan: false)
        XCTAssertNotEqual(key(solid), key(holed))
    }
}
