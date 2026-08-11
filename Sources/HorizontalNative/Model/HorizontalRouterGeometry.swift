import Foundation

/// Foundation geometry for the interactive router: the eight routing directions,
/// and the octagon every obstacle is reduced to.
///
/// See `docs/push-shove-router.md`. Two decisions from that study are load
/// bearing here and are the reason this is not built on Clipper:
///
///  * The router's inner loop runs per mouse-move, so obstacle tests have to
///    cost nanoseconds. General polygon offsetting is correct and orders of
///    magnitude too slow for that; an octagon test is a handful of comparisons.
///  * Interactive routes are constrained to eight directions, so the octagon's
///    faces are exactly the directions a route can travel. That is what makes
///    "walk around this obstacle" a closed-form answer later, rather than a
///    search.
enum HorizontalDirection45: Int, CaseIterable, Hashable, Sendable {
    case east = 0
    case northEast = 1
    case north = 2
    case northWest = 3
    case west = 4
    case southWest = 5
    case south = 6
    case southEast = 7

    /// The direction from `from` to `to`, or nil when the step is not one of the
    /// eight — which is a caller error rather than a rounding question, so it is
    /// reported instead of being snapped to the nearest.
    init?(from: HorizontalPoint, to: HorizontalPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard dx != 0 || dy != 0 else { return nil }
        if dx != 0, dy != 0, abs(dx) != abs(dy) { return nil }

        switch (dx.signum(), dy.signum()) {
        case (1, 0): self = .east
        case (1, 1): self = .northEast
        case (0, 1): self = .north
        case (-1, 1): self = .northWest
        case (-1, 0): self = .west
        case (-1, -1): self = .southWest
        case (0, -1): self = .south
        case (1, -1): self = .southEast
        default: return nil
        }
    }

    var isDiagonal: Bool { rawValue % 2 == 1 }

    /// A one-unit step. Diagonals step one in each axis, so a diagonal segment's
    /// endpoints always differ by the same amount in x and y — which is what
    /// keeps 45° arithmetic exact.
    var step: HorizontalPoint {
        switch self {
        case .east: HorizontalPoint(x: 1, y: 0)
        case .northEast: HorizontalPoint(x: 1, y: 1)
        case .north: HorizontalPoint(x: 0, y: 1)
        case .northWest: HorizontalPoint(x: -1, y: 1)
        case .west: HorizontalPoint(x: -1, y: 0)
        case .southWest: HorizontalPoint(x: -1, y: -1)
        case .south: HorizontalPoint(x: 0, y: -1)
        case .southEast: HorizontalPoint(x: 1, y: -1)
        }
    }

    var opposite: HorizontalDirection45 { turned(by: 4) }

    /// Rotates by `eighths` × 45°, positive anticlockwise.
    func turned(by eighths: Int) -> HorizontalDirection45 {
        let wrapped = ((rawValue + eighths) % 8 + 8) % 8
        return HorizontalDirection45(rawValue: wrapped) ?? self
    }

    /// How many 45° steps separate two directions, 0...4. The router uses this to
    /// price corners: a route that turns 90° costs more than one that turns 45°.
    func eighths(to other: HorizontalDirection45) -> Int {
        let raw = ((other.rawValue - rawValue) % 8 + 8) % 8
        return raw > 4 ? 8 - raw : raw
    }
}

private extension Double {
    func signum() -> Int { self > 0 ? 1 : (self < 0 ? -1 : 0) }
}

/// An axis-and-diagonal aligned octagon: the shape every obstacle is inflated
/// into before the router looks at it.
///
/// Stored as eight support values — the extent of the shape along each of the
/// eight directions — rather than as vertices. That representation is what makes
/// the operations cheap and exact:
///
///  * building one from a point set is a single pass of min/max;
///  * inflating by a clearance adds to each support value;
///  * two octagons share the same eight face normals, so the separating-axis
///    test over those eight is not an approximation but a decision.
///
/// The extents are, in order: +x, +(x+y), +y, +(-x+y), -x, -(x+y), -y, -(-x+y).
struct HorizontalOctagon: Equatable, Sendable {
    /// Support value per `HorizontalDirection45`, indexed by its raw value.
    private(set) var extents: [Double]

    private init(extents: [Double]) {
        self.extents = extents
    }

    /// Projection of `point` onto direction `d`'s (unnormalised) normal.
    ///
    /// Diagonal normals are deliberately left unnormalised — `(1, 1)` rather than
    /// `(1, 1)/√2` — so every projection of an integer-nanometre coordinate stays
    /// an exact integer. The √2 reappears in `inflated(by:)`, which is the only
    /// place it can be handled honestly.
    @inline(__always)
    static func support(_ point: HorizontalPoint, _ direction: HorizontalDirection45) -> Double {
        let step = direction.step
        return point.x * step.x + point.y * step.y
    }

    /// The smallest octagon containing every point. Empty input yields nil rather
    /// than a degenerate octagon that would silently collide with nothing.
    init?(points: [HorizontalPoint]) {
        guard let first = points.first else { return nil }
        var extents = HorizontalDirection45.allCases.map { Self.support(first, $0) }
        for point in points.dropFirst() {
            for direction in HorizontalDirection45.allCases {
                let value = Self.support(point, direction)
                if value > extents[direction.rawValue] {
                    extents[direction.rawValue] = value
                }
            }
        }
        self.extents = extents
    }

    /// The octagon covering a track segment of the given width — its two
    /// endpoints, each grown by half the width.
    init(from: HorizontalPoint, to: HorizontalPoint, width: Double) {
        // Safe because the point list is never empty.
        self = HorizontalOctagon(points: [from, to])!.inflated(by: max(width, 0) / 2)
    }

    /// The octagon circumscribing a circle — a via, or a round pad.
    init(center: HorizontalPoint, radius: Double) {
        self = HorizontalOctagon(points: [center])!.inflated(by: max(radius, 0))
    }

    /// Grows the octagon by `distance` in every direction, as a Minkowski sum
    /// with a disc of that radius.
    ///
    /// The diagonal faces are the subtle part. A support value along the
    /// unnormalised normal `(1, 1)` is √2 times the true distance to that face,
    /// so growing the shape by `distance` means growing that support value by
    /// `distance × √2`. Rounding is deliberately UP: the result must always
    /// CONTAIN the true offset shape, because this is a clearance. Rounding down
    /// would under-clear by a fraction of a nanometre and report a legal route
    /// where the board has a violation — the one error worth biasing against.
    func inflated(by distance: Double) -> HorizontalOctagon {
        guard distance != 0 else { return self }
        let axial = distance
        let diagonal = (distance * 2.0.squareRoot()).rounded(.up)
        var grown = extents
        for direction in HorizontalDirection45.allCases {
            grown[direction.rawValue] += direction.isDiagonal ? diagonal : axial
        }
        return HorizontalOctagon(extents: grown)
    }

    func contains(_ point: HorizontalPoint) -> Bool {
        for direction in HorizontalDirection45.allCases
        where Self.support(point, direction) > extents[direction.rawValue] {
            return false
        }
        return true
    }

    /// Whether two octagons share any point, touching included.
    ///
    /// Both shapes have the same eight face normals, so the separating-axis
    /// theorem over exactly those eight is a decision rather than an
    /// approximation: if none of them separates the two, they overlap.
    func intersects(_ other: HorizontalOctagon) -> Bool {
        for direction in HorizontalDirection45.allCases {
            // The pair separates when this octagon's extent along `direction`
            // falls short of where the other one begins.
            if extents[direction.rawValue] + other.extents[direction.opposite.rawValue] < 0 {
                return false
            }
        }
        return true
    }

    /// The octagon's corners, anticlockwise from the +x face.
    ///
    /// Each corner is where two adjacent half-planes meet, so this is exact
    /// arithmetic on the support values rather than a reconstruction. Corners
    /// that coincide — which happens whenever a face has zero length, as on a
    /// plain rectangle — are collapsed, so the ring is always a simple polygon.
    ///
    /// The ring matters because consecutive corners are joined by edges running
    /// in the eight routing directions. Walking it is therefore already a legal
    /// 45° path, which is what makes "go around this obstacle" a closed-form
    /// answer rather than a search.
    var vertices: [HorizontalPoint] {
        let e = extents
        // Adjacent half-plane pairs, anticlockwise. Each solves two equations:
        // e.g. x = e[east] with x + y = e[northEast] gives (e0, e1 - e0).
        let corners = [
            HorizontalPoint(x: e[0], y: e[1] - e[0]),          // E  ∧ NE
            HorizontalPoint(x: e[1] - e[2], y: e[2]),          // NE ∧ N
            HorizontalPoint(x: e[2] - e[3], y: e[2]),          // N  ∧ NW
            HorizontalPoint(x: -e[4], y: e[3] - e[4]),         // NW ∧ W
            HorizontalPoint(x: -e[4], y: e[4] - e[5]),         // W  ∧ SW
            HorizontalPoint(x: e[6] - e[5], y: -e[6]),         // SW ∧ S
            HorizontalPoint(x: e[7] - e[6], y: -e[6]),         // S  ∧ SE
            HorizontalPoint(x: e[0], y: e[0] - e[7]),          // SE ∧ E
        ]

        var ring = [HorizontalPoint]()
        for corner in corners where ring.last != corner {
            ring.append(corner)
        }
        if ring.count > 1, ring.first == ring.last {
            ring.removeLast()
        }
        return ring
    }

    /// Whether two octagons overlap with area to spare — touching is NOT enough.
    ///
    /// This is the predicate a CLEARANCE needs, and it differs from `intersects`
    /// in exactly the case that matters. A clearance says two things must be at
    /// least so far apart; being exactly that far apart satisfies it. Since the
    /// obstacle hull is inflated by the clearance before the test, a route
    /// riding its boundary is legal — and a route around an obstacle rides that
    /// boundary by construction, so testing with `intersects` would report every
    /// detour as colliding with the very thing it was drawn to avoid.
    func overlaps(_ other: HorizontalOctagon) -> Bool {
        for direction in HorizontalDirection45.allCases {
            if extents[direction.rawValue] + other.extents[direction.opposite.rawValue] <= 0 {
                return false
            }
        }
        return true
    }

    /// The axis-aligned bounds, for handing to a spatial index.
    var boundingBox: HorizontalRect {
        HorizontalRect(points: [
            HorizontalPoint(
                x: -extents[HorizontalDirection45.west.rawValue],
                y: -extents[HorizontalDirection45.south.rawValue]
            ),
            HorizontalPoint(
                x: extents[HorizontalDirection45.east.rawValue],
                y: extents[HorizontalDirection45.north.rawValue]
            ),
        ])
    }

    /// True when the extents describe no region at all, which can only happen if
    /// a caller builds one by hand with contradictory values.
    var isEmpty: Bool {
        for direction in HorizontalDirection45.allCases
        where extents[direction.rawValue] + extents[direction.opposite.rawValue] < 0 {
            return true
        }
        return false
    }
}
