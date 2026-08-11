import XCTest
@testable import HorizontalNative

final class HorizontalSnapIndexTests: XCTestCase {
    func testExactMatchMirrorsRoundedKey() {
        let target = HorizontalPoint(x: 10.2, y: 20.8) // rounds to (10, 21)
        let index = HorizontalSnapIndex(targets: [target, HorizontalPoint(x: -5.5, y: 3.1)])
        XCTAssertEqual(index.exactMatch(HorizontalPoint(x: 10.4, y: 21.3)), target) // rounds to (10, 21)
        XCTAssertEqual(index.exactMatch(HorizontalPoint(x: 9.6, y: 20.6)), target)  // rounds to (10, 21)
        XCTAssertNil(index.exactMatch(HorizontalPoint(x: 12, y: 21)))
    }

    func testEmptyAndSingle() {
        XCTAssertNil(HorizontalSnapIndex.empty.nearest(to: .zero, within: 100))
        XCTAssertNil(HorizontalSnapIndex.empty.exactMatch(.zero))

        let one = HorizontalSnapIndex(targets: [HorizontalPoint(x: 5, y: 5)])
        XCTAssertEqual(one.nearest(to: HorizontalPoint(x: 6, y: 5), within: 2), HorizontalPoint(x: 5, y: 5))
        XCTAssertNil(one.nearest(to: HorizontalPoint(x: 100, y: 100), within: 2))
    }

    func testCoincidentPoints() {
        let index = HorizontalSnapIndex(targets: Array(repeating: HorizontalPoint(x: 3, y: 3), count: 50))
        XCTAssertEqual(index.nearest(to: HorizontalPoint(x: 3.5, y: 3), within: 1), HorizontalPoint(x: 3, y: 3))
        XCTAssertNil(index.nearest(to: HorizontalPoint(x: 10, y: 10), within: 1))
    }

    func testRadiusIsExclusiveAtBoundary() {
        let index = HorizontalSnapIndex(targets: [HorizontalPoint(x: 10, y: 0)])
        // Target is exactly `radius` away → excluded (strict <), matching the
        // original nearestSnapTarget.
        XCTAssertNil(index.nearest(to: .zero, within: 10))
        XCTAssertEqual(index.nearest(to: .zero, within: 10.0001), HorizontalPoint(x: 10, y: 0))
    }

    // The index must agree with a brute-force nearest-within-radius scan across
    // densities, radii (both the grid path and the cell-cap full-scan fallback),
    // and query positions. Ties are compared by distance, since equidistant
    // targets may resolve to different identities by iteration order.
    func testNearestMatchesBruteForce() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for trial in 0..<300 {
            let count = Int(rng.next() % 500) + 1
            let targets = (0..<count).map { _ in
                HorizontalPoint(x: rng.double(-10_000, 10_000), y: rng.double(-10_000, 10_000))
            }
            let index = HorizontalSnapIndex(targets: targets)

            for _ in 0..<8 {
                let world = HorizontalPoint(x: rng.double(-11_000, 11_000), y: rng.double(-11_000, 11_000))
                let radius = rng.double(0.5, 6_000) // small → grid; large → full-scan fallback
                let expected = bruteNearest(targets, to: world, within: radius)
                let actual = index.nearest(to: world, within: radius)

                XCTAssertEqual(actual == nil, expected == nil, "trial \(trial) radius \(radius)")
                if let actual, let expected {
                    XCTAssertEqual(
                        distance(actual, world),
                        distance(expected, world),
                        accuracy: 1e-6,
                        "trial \(trial) radius \(radius)"
                    )
                }
            }
        }
    }

    func testCacheRebuildsOnlyOnChange() {
        let cache = HorizontalSnapIndexCache()
        let a = [HorizontalPoint(x: 1, y: 1), HorizontalPoint(x: 2, y: 2)]
        XCTAssertEqual(cache.index(for: a).exactMatch(HorizontalPoint(x: 1, y: 1)), HorizontalPoint(x: 1, y: 1))
        // Same contents → still returns a valid index for the new targets.
        XCTAssertEqual(cache.index(for: a).exactMatch(HorizontalPoint(x: 2, y: 2)), HorizontalPoint(x: 2, y: 2))
        // Changed contents → reflects the new targets.
        let b = [HorizontalPoint(x: 9, y: 9)]
        XCTAssertNil(cache.index(for: b).exactMatch(HorizontalPoint(x: 1, y: 1)))
        XCTAssertEqual(cache.index(for: b).exactMatch(HorizontalPoint(x: 9, y: 9)), HorizontalPoint(x: 9, y: 9))
    }

    private func bruteNearest(_ targets: [HorizontalPoint], to world: HorizontalPoint, within radius: Double) -> HorizontalPoint? {
        var nearest: HorizontalPoint?
        var nearestDistance = radius
        for target in targets {
            let d = distance(target, world)
            if d < nearestDistance {
                nearest = target
                nearestDistance = d
            }
        }
        return nearest
    }

    private func distance(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Deterministic PRNG so the brute-force comparison is reproducible.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func double(_ lower: Double, _ upper: Double) -> Double {
        let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
        return lower + unit * (upper - lower)
    }
}
