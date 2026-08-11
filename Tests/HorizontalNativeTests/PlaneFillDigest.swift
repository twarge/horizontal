import Foundation
@testable import HorizontalNative

/// A stable summary of one plane's poured fill.
///
/// Deliberately records no coordinates. Two reasons, and the second is not
/// optional: a fill's vertex COUNT is not reproducible across processes — Swift
/// seeds `Set` iteration per process, which reorders the cutouts handed to the
/// clipper and leaves it emitting the odd redundant collinear point — so any
/// golden built from vertices or a coordinate hash would fail at random. Area is
/// unaffected by a collinear vertex and has been stable to six decimal places
/// across every run measured.
///
/// It also means a golden captured from a real board records how much copper was
/// poured and in how many pieces, not the board's design.
struct PlaneFillDigest {
    var fragmentCount: Int
    /// Net copper: outer contours minus their holes.
    var areaMM2: Double
    var holeCount: Int

    init(_ plane: HorizontalPlane) {
        func ringArea(_ ring: [HorizontalPoint]) -> Double {
            guard ring.count > 2 else { return 0 }
            var sum = 0.0
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        }
        fragmentCount = plane.fragments.count
        holeCount = plane.fragments.reduce(0) { $0 + max($1.paths.count - 1, 0) }
        areaMM2 = plane.fragments.reduce(0.0) { total, fragment in
            guard let outer = fragment.paths.first else { return total }
            let holes = fragment.paths.dropFirst().reduce(0.0) { $0 + ringArea($1) }
            return total + ringArea(outer) - holes
        } / 1e12
    }
}

struct PlaneFillGolden {
    var id: String
    var layer: Int
    var priority: Int
    var fragments: Int
    var areaMM2: Double
    var holes: Int
}
