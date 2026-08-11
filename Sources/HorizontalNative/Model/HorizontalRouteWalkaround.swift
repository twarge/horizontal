import Foundation

/// 45°-constrained path construction, and the two ways around an obstacle.
///
/// Step 3 of `docs/push-shove-router.md`. Walkaround is useful on its own —
/// "route around what is there" — and it is what shoving is built from, since
/// shoving is walkaround applied to the track being pushed rather than to the
/// one being drawn.
enum HorizontalRoute45 {
    /// The two-segment 45° join between any two points: one diagonal run and one
    /// axis run.
    ///
    /// `diagonalFirst` is the route's posture, the same choice the interactive
    /// draw tool exposes. It is a genuine choice rather than a derived one —
    /// both joins are legal and they go different ways round — so it is a
    /// parameter, and a shove has to preserve it or the user's route flips under
    /// them.
    ///
    /// Exact: the corner lands on integer coordinates whenever the endpoints do,
    /// because the diagonal run moves by the same amount in x and y.
    static func elbow(
        from: HorizontalPoint,
        to: HorizontalPoint,
        diagonalFirst: Bool
    ) -> [HorizontalPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        if dx == 0 || dy == 0 || abs(dx) == abs(dy) {
            return from == to ? [from] : [from, to]
        }

        let run = min(abs(dx), abs(dy))
        let stepX = dx < 0 ? -run : run
        let stepY = dy < 0 ? -run : run

        let corner = diagonalFirst
            ? HorizontalPoint(x: from.x + stepX, y: from.y + stepY)
            : HorizontalPoint(x: to.x - stepX, y: to.y - stepY)
        return [from, corner, to]
    }

    /// Total length of a polyline.
    static func length(of points: [HorizontalPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    /// How many direction changes a polyline makes. Corners cost manufacturing
    /// margin and readability, so a route with fewer is preferred at equal
    /// length.
    static func corners(of points: [HorizontalPoint]) -> Int {
        guard points.count > 2 else { return 0 }
        var count = 0
        var previous = HorizontalDirection45(from: points[0], to: points[1])
        for index in 2..<points.count {
            let next = HorizontalDirection45(from: points[index - 1], to: points[index])
            if let previous, let next, previous != next { count += 1 }
            if next != nil { previous = next }
        }
        return count
    }

    /// Drops points that continue in the same direction, so a route carries no
    /// vertex that does not turn.
    static func simplified(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        for index in 1..<(points.count - 1) {
            let incoming = HorizontalDirection45(from: result[result.count - 1], to: points[index])
            let outgoing = HorizontalDirection45(from: points[index], to: points[index + 1])
            if incoming == nil || outgoing == nil || incoming != outgoing {
                result.append(points[index])
            }
        }
        result.append(points[points.count - 1])
        return result
    }
}

/// The two ways around one obstacle.
enum HorizontalRouteWalkaround {
    struct Detour {
        /// Anticlockwise around the obstacle, or clockwise.
        var isAnticlockwise: Bool
        var points: [HorizontalPoint]
        var length: Double
        var corners: Int

        /// Cheaper is shorter, with a corner priced as a fixed length. The
        /// weight is a preference and not a rule — it exists so that two routes
        /// of nearly equal length are settled by corner count rather than by
        /// floating-point noise.
        var cost: Double { length + Double(corners) * Detour.cornerPenalty }

        /// One tenth of a millimetre. Small enough that it never outweighs a
        /// materially shorter route, large enough to settle near-ties.
        static let cornerPenalty = 100_000.0
    }

    /// Both ways around `hull`, from `from` to `to`.
    ///
    /// The obstacle's ring is already a legal 45° path — consecutive corners are
    /// joined by edges in the eight routing directions — so a detour is the ring
    /// arc with a 45° elbow at each end. The two arcs between the same pair of
    /// ring corners are the two ways round, and the caller picks by cost or by
    /// which one collides with less.
    ///
    /// Returns an empty array when the hull has no ring to walk.
    static func detours(
        around hull: HorizontalOctagon,
        from: HorizontalPoint,
        to: HorizontalPoint,
        diagonalFirst: Bool = true
    ) -> [Detour] {
        let ring = hull.vertices
        guard ring.count >= 3 else { return [] }

        let entry = nearestCorner(in: ring, to: from)
        let exit = nearestCorner(in: ring, to: to)

        return [true, false].compactMap { anticlockwise in
            let arc = arc(in: ring, from: entry, to: exit, anticlockwise: anticlockwise)
            var points = HorizontalRoute45.elbow(from: from, to: arc[0], diagonalFirst: diagonalFirst)
            for corner in arc.dropFirst() {
                points.append(corner)
            }
            points.append(contentsOf:
                HorizontalRoute45.elbow(from: arc[arc.count - 1], to: to, diagonalFirst: diagonalFirst)
                    .dropFirst())

            let simplified = HorizontalRoute45.simplified(points)
            return Detour(
                isAnticlockwise: anticlockwise,
                points: simplified,
                length: HorizontalRoute45.length(of: simplified),
                corners: HorizontalRoute45.corners(of: simplified)
            )
        }
    }

    /// The cheaper of the two ways round, or nil when there is no ring.
    static func best(
        around hull: HorizontalOctagon,
        from: HorizontalPoint,
        to: HorizontalPoint,
        diagonalFirst: Bool = true
    ) -> Detour? {
        detours(around: hull, from: from, to: to, diagonalFirst: diagonalFirst)
            // Ties break towards anticlockwise so the same inputs always give the
            // same route; a router that picks differently run to run is unusable
            // for comparing two versions of a board.
            .min { lhs, rhs in
                lhs.cost != rhs.cost ? lhs.cost < rhs.cost : (lhs.isAnticlockwise && !rhs.isAnticlockwise)
            }
    }

    private static func nearestCorner(in ring: [HorizontalPoint], to point: HorizontalPoint) -> Int {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, corner) in ring.enumerated() {
            let dx = corner.x - point.x
            let dy = corner.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// The run of ring corners from `start` to `end`, inclusive, in one
    /// direction.
    private static func arc(
        in ring: [HorizontalPoint], from start: Int, to end: Int, anticlockwise: Bool
    ) -> [HorizontalPoint] {
        var corners = [ring[start]]
        var index = start
        let step = anticlockwise ? 1 : -1
        while index != end {
            index = ((index + step) % ring.count + ring.count) % ring.count
            corners.append(ring[index])
        }
        return corners
    }
}
