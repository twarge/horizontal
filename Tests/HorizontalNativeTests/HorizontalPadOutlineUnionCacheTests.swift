import XCTest
@testable import HorizontalNative

/// The board canvas's pad-outline cache: a rebuild re-merges only the pads
/// whose shapes changed, and must draw exactly what a fresh merge would.
final class HorizontalPadOutlineUnionCacheTests: XCTestCase {
    private let mm = 1_000_000.0

    /// A cross-shaped pad: two overlapping rectangles the outline merges.
    private func pad(_ name: String, at origin: HorizontalPoint) -> [HorizontalPolygon] {
        func rectangle(_ shape: String, halfWidth: Double, halfHeight: Double) -> HorizontalPolygon {
            HorizontalPolygon(
                id: "pkg/pad/\(name)/shape/\(shape)",
                vertices: [
                    origin + HorizontalPoint(x: -halfWidth, y: -halfHeight),
                    origin + HorizontalPoint(x: halfWidth, y: -halfHeight),
                    origin + HorizontalPoint(x: halfWidth, y: halfHeight),
                    origin + HorizontalPoint(x: -halfWidth, y: halfHeight),
                ],
                layer: HorizontalBoardLayers.topCopper
            )
        }
        return [
            rectangle("wide", halfWidth: mm, halfHeight: 0.5 * mm),
            rectangle("tall", halfWidth: 0.5 * mm, halfHeight: mm),
        ]
    }

    func testCachedOutlinesMatchAFreshMerge() {
        let cache = HorizontalPadOutlineUnionCache()
        let pads = pad("p1", at: .zero) + pad("p2", at: HorizontalPoint(x: 5 * mm, y: 0))
        let fresh = horizonPadOutlineFragments(pads)
        XCTAssertEqual(fresh.count, 2, "each pad's two shapes merge into one outline")

        XCTAssertEqual(horizonPadOutlineFragments(pads, unionCache: cache), fresh)
        XCTAssertEqual(horizonPadOutlineFragments(pads, unionCache: cache), fresh, "the second pass is served from the cache")
    }

    func testAMovedPadIsServedTranslated() {
        let cache = HorizontalPadOutlineUnionCache()
        _ = horizonPadOutlineFragments(pad("p1", at: .zero), unionCache: cache)

        let moved = pad("p1", at: HorizontalPoint(x: 3 * mm, y: -2 * mm))
        XCTAssertEqual(horizonPadOutlineFragments(moved, unionCache: cache), horizonPadOutlineFragments(moved))
    }
}
