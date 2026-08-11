import XCTest
@testable import HorizontalNative

/// Verifies the spatial index (the hover hit-test acceleration structure)
/// returns results identical to a brute-force linear scan, across many random
/// scenes and query points. This is the correctness property the index was
/// claimed to hold "by construction"; these tests make it empirical.
final class HorizontalSelectableSpatialIndexTests: XCTestCase {
    /// Deterministic PRNG so failures are reproducible (the harness forbids
    /// nondeterministic Date/random in some contexts; this is self-seeded).
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let types: [HorizontalObjectType] = [.track, .via, .boardHole, .text, .boardPackage, .junction]

    private func makeScene(seed: UInt64, count: Int, extent: Double) -> [HorizontalSelectable] {
        var rng = SplitMix64(state: seed)
        var result = [HorizontalSelectable]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let type = types[Int.random(in: 0..<types.count, using: &rng)]
            let ref = HorizontalSelectableRef(id: "obj-\(i)", type: type, layer: Int.random(in: -2...2, using: &rng))
            let cx = Double.random(in: -extent...extent, using: &rng)
            let cy = Double.random(in: -extent...extent, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0:
                result.append(.point(ref: ref, at: HorizontalPoint(x: cx, y: cy)))
            case 1:
                let dx = Double.random(in: -extent / 4...extent / 4, using: &rng)
                let dy = Double.random(in: -extent / 4...extent / 4, using: &rng)
                let width = Double.random(in: 0...extent / 50, using: &rng)
                result.append(.line(ref: ref, from: HorizontalPoint(x: cx, y: cy),
                                    to: HorizontalPoint(x: cx + dx, y: cy + dy), width: width))
            default:
                let hw = Double.random(in: 1...extent / 20, using: &rng)
                let hh = Double.random(in: 1...extent / 20, using: &rng)
                let corners = [
                    HorizontalPoint(x: cx - hw, y: cy - hh),
                    HorizontalPoint(x: cx + hw, y: cy - hh),
                    HorizontalPoint(x: cx + hw, y: cy + hh),
                    HorizontalPoint(x: cx - hw, y: cy + hh),
                ]
                result.append(.bounds(ref: ref, points: corners, fallbackCenter: HorizontalPoint(x: cx, y: cy), fallbackSize: hw))
            }
        }
        return result
    }

    func testSmallestSelectableMatchesLinearScan() {
        let extent = 1_000_000.0
        for seed in UInt64(1)...UInt64(8) {
            let scene = makeScene(seed: seed &* 0x100, count: 400, extent: extent)
            let index = HorizontalSelectableSpatialIndex(scene)
            var rng = SplitMix64(state: seed &* 0xABCD)
            for expand in [0.0, 500.0, 5_000.0, 50_000.0] {
                for _ in 0..<400 {
                    let p = HorizontalPoint(
                        x: Double.random(in: -extent * 1.1...extent * 1.1, using: &rng),
                        y: Double.random(in: -extent * 1.1...extent * 1.1, using: &rng))
                    let indexed = index.smallestSelectable(at: p, expand: expand)
                    let linear = HorizontalSelectableHitTest.smallestSelectable(at: p, in: scene, expand: expand)
                    XCTAssertEqual(indexed, linear, "seed=\(seed) expand=\(expand) p=\(p.x),\(p.y)")
                }
            }
        }
    }

    func testAllSelectablesMatchLinearScan() {
        let extent = 500_000.0
        for seed in UInt64(1)...UInt64(4) {
            let scene = makeScene(seed: seed &* 0x55, count: 300, extent: extent)
            let index = HorizontalSelectableSpatialIndex(scene)
            var rng = SplitMix64(state: seed &* 0x999)
            for _ in 0..<300 {
                let p = HorizontalPoint(
                    x: Double.random(in: -extent...extent, using: &rng),
                    y: Double.random(in: -extent...extent, using: &rng))
                let expand = 20_000.0
                let indexed = Set(index.allSelectables(at: p, expand: expand))
                let linear = Set(HorizontalSelectableHitTest.allSelectables(at: p, in: scene, expand: expand))
                XCTAssertEqual(indexed, linear, "seed=\(seed) p=\(p.x),\(p.y)")
            }
        }
    }

    func testCandidatesAreSupersetOfTrueHits() {
        let extent = 800_000.0
        let scene = makeScene(seed: 0xFEED, count: 500, extent: extent)
        let index = HorizontalSelectableSpatialIndex(scene)
        var rng = SplitMix64(state: 0xBEEF)
        for _ in 0..<800 {
            let p = HorizontalPoint(
                x: Double.random(in: -extent...extent, using: &rng),
                y: Double.random(in: -extent...extent, using: &rng))
            let expand = 30_000.0
            let candidateRefs = Set(index.candidates(at: p, expand: expand).map(\.ref))
            let trueHits = scene.filter { $0.inside(p, expand: expand) }.map(\.ref)
            for hit in trueHits {
                XCTAssertTrue(candidateRefs.contains(hit), "missing candidate for a true hit at \(p.x),\(p.y)")
            }
        }
    }

    func testEmptyAndSingletonScenes() {
        let empty = HorizontalSelectableSpatialIndex([])
        XCTAssertNil(empty.smallestSelectable(at: HorizontalPoint(x: 0, y: 0), expand: 1000))

        let one = [HorizontalSelectable.point(ref: HorizontalSelectableRef(id: "x", type: .via), at: HorizontalPoint(x: 100, y: 100))]
        let index = HorizontalSelectableSpatialIndex(one)
        XCTAssertEqual(index.smallestSelectable(at: HorizontalPoint(x: 100, y: 100), expand: 50)?.id, "x")
        XCTAssertNil(index.smallestSelectable(at: HorizontalPoint(x: 1_000_000, y: 0), expand: 50))
    }
}
