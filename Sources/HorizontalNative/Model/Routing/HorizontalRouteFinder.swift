import Foundation

/// Routes a track around whatever is in the way, on one layer.
///
/// Completes step 3 of `docs/push-shove-router.md`. It shoves nothing — every
/// existing object stays where it is — which makes it useful on its own and is
/// the base the shove is built on.
///
/// Three stages, each cheap when the previous one suffices:
///
///  1. The plain elbow. On an open board that is the answer, and it costs one
///     collision test.
///  2. A grid search (`HorizontalRouteGridSearch`) when something is in the
///     way. Bounded, deterministic and complete at its resolution, it finds a
///     clear path if one exists — but as a staircase of grid steps.
///  3. Pulling that staircase taut: replacing runs of steps with the longest
///     clear elbows, then dropping any corner whose removal is still clear.
///     Every shortcut is checked against the board, so this shortens a route
///     but never makes it illegal.
///
/// Two design commitments carried from the study:
///
///  * **It degrades honestly.** When it cannot get through it says so and names
///    the obstruction. It never returns a route that crosses something, because
///    a plausible-looking illegal route is worse than no route.
///  * **It is deterministic.** The same request produces the same copper, so two
///    versions of a board can be compared.
enum HorizontalRouteFinder {
    struct Budget {
        /// How many grid nodes the search may expand before giving up.
        /// Interactive means the answer has to come back this frame; an
        /// unbounded correct answer is a wrong answer. Twelve thousand is a few
        /// tens of milliseconds on a dense board, and a route that needs more
        /// than that is one the user would rather place by hand anyway.
        var maxExpansions = 12_000

        /// The finest grid pitch. Fifty micrometres is well below any clearance
        /// a fabricator quotes, so at that pitch a channel the track fits
        /// through always holds a grid line.
        var finestPitch = 50_000.0

        /// How many cells a side of the search window is allowed before the
        /// pitch coarsens. Keeps the cell count — and with it the worst case —
        /// bounded; a route across the board is drawn coarser than one between
        /// neighbours and nobody can tell.
        var cellsPerSide = 384.0

        /// The least the search window extends beyond the endpoints. A route
        /// has to be able to leave the endpoints' bounding box, or nothing
        /// could go around a component that spans it.
        var minimumMargin = 3_000_000.0

        /// Whether a search that finds no way through gets a second, harder
        /// try: a wider window when the first one ran into its own edge, a
        /// finer grid when the start turned out to be enclosed. One retry,
        /// because it costs a few times what the first attempt did and a
        /// third would buy almost nothing. On a dense real board the retry
        /// rescues about a tenth of the routes the first attempt gives up on.
        var retriesOnFailure = true

        static let interactive = Budget()
    }

    enum Outcome: Equatable {
        /// Reached the target with nothing in the way.
        case complete
        /// Could not get through. Carries the obstacle it gave up on, so the
        /// caller can highlight what is actually blocking the route.
        case blocked(obstacle: Int)
        /// Ran out of budget with the route still colliding.
        case exhausted(obstacle: Int)
    }

    struct Result {
        var points: [HorizontalPoint]
        var outcome: Outcome

        var isComplete: Bool { outcome == .complete }
    }

    /// Routes from `from` to `to` on `layer`, avoiding everything the index
    /// knows about.
    ///
    /// `width` is the track's own width; the clearance it needs is resolved per
    /// obstacle from the rules, so a route past a pad keeps the pad's distance
    /// and a route past a track keeps the track's.
    static func route(
        from: HorizontalPoint,
        to: HorizontalPoint,
        layer: Int,
        net: Int,
        width: Double,
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances,
        diagonalFirst: Bool = true,
        budget: Budget = .interactive
    ) -> Result {
        // Obstacles the route STARTS or ENDS inside cannot be avoided, and must
        // not be treated as collisions.
        //
        // A route normally begins on a pad and ends on another: that is what
        // routing is. The pad under the anchor overlaps the very first segment,
        // and there is no way around something you are standing on — so the
        // router would report blocked on essentially every real route, which is
        // exactly what happened the first time this ran on a board.
        //
        // Exempting them is not a loophole. Connecting to a pad is the route's
        // purpose, and its own net is already exempt; this covers the case where
        // the net is not yet known (a fresh route has no net until it reaches
        // something) and the endpoints' own footprint copper.
        let exempt = obstaclesAround(
            from, layer: layer, net: net, width: width, index: index, clearances: clearances
        ).union(obstaclesAround(
            to, layer: layer, net: net, width: width, index: index, clearances: clearances))
        let collider = HorizontalRouteCollider(
            index: index, clearances: clearances, layer: layer, net: net, width: width,
            exempt: exempt)

        switch solve(from: from, to: to, collider: collider, diagonalFirst: diagonalFirst, budget: budget) {
        case .route(let points):
            return Result(points: points, outcome: .complete)
        case .failed(let outcome, _):
            let direct = HorizontalRoute45.elbow(from: from, to: to, diagonalFirst: diagonalFirst)
            return Result(points: direct, outcome: outcome)
        }
    }

    /// `retried`, or, where it failed and got less far than `first` did — a
    /// finer grid spends its budget nearer the start — its verdict with
    /// `first`'s path to the nearest point, the one a route that stops short
    /// should follow.
    private static func nearer(
        _ retried: HorizontalRouteGridSearch.Outcome,
        than first: HorizontalRouteGridSearch.Outcome,
        to target: HorizontalPoint
    ) -> HorizontalRouteGridSearch.Outcome {
        guard let earlier = HorizontalRouteGridSearch.nearest(in: first),
              let later = HorizontalRouteGridSearch.nearest(in: retried),
              let earlierEnd = earlier.last, let laterEnd = later.last,
              distance(earlierEnd, target) < distance(laterEnd, target) else {
            return retried
        }
        switch retried {
        case .found:
            return retried
        case .unreachable(let blocker, let reachedWindowEdge, _):
            return .unreachable(blocker: blocker, reachedWindowEdge: reachedWindowEdge, nearest: earlier)
        case .exhausted(let blocker, _):
            return .exhausted(blocker: blocker, nearest: earlier)
        }
    }

    private static func distance(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// What `solve` finds: a clear route onto the target, or the verdict on
    /// why there is none with the clear way to the nearest point it reached.
    private enum Solution {
        case route([HorizontalPoint])
        case failed(Outcome, nearest: [HorizontalPoint])
    }

    /// The three stages, against a collider whose exemptions the caller has
    /// settled.
    private static func solve(
        from: HorizontalPoint,
        to: HorizontalPoint,
        collider: HorizontalRouteCollider,
        diagonalFirst: Bool,
        budget: Budget
    ) -> Solution {
        // The plain elbow, in the route's posture or failing that the other: a
        // clear elbow beats any detour, and it is what the tool draws without
        // the router, so an open board routes exactly as before.
        for posture in [diagonalFirst, !diagonalFirst] {
            let direct = HorizontalRoute45.elbow(from: from, to: to, diagonalFirst: posture)
            if collider.isClear(direct) {
                return .route(direct)
            }
        }

        var outcome = HorizontalRouteGridSearch.search(
            from: from, to: to, collider: collider, diagonalFirst: diagonalFirst, budget: budget)

        if budget.retriesOnFailure, case .unreachable(_, let reachedWindowEdge, _) = outcome {
            let first = outcome
            // The first window was sized for the common case.
            var harder = budget
            harder.retriesOnFailure = false
            if reachedWindowEdge {
                // The search spilled to the window's edge, so the way round
                // may lie beyond it: a far detour, which a coarser grid draws
                // as well as a fine one. The window doubles and the pitch is
                // left to coarsen with it, so the flood of whatever enclosed
                // the first attempt costs a quarter as much the second time;
                // the budget still doubles, because the flood comes first and
                // the route after it.
                let extent = max(abs(to.x - from.x), abs(to.y - from.y))
                harder.minimumMargin = 2 * max(budget.minimumMargin, extent / 2)
                harder.maxExpansions *= 2
            } else {
                // The start is enclosed at this pitch, and the only hope is a
                // channel too narrow for the grid to have seen. Halving the
                // pitch quadruples the cells in the same enclosure, and all of
                // them have to be flooded before the channel is found.
                harder.finestPitch /= 2
                harder.cellsPerSide *= 2
                harder.maxExpansions *= 3
            }
            let retried = HorizontalRouteGridSearch.search(
                from: from, to: to, collider: collider, diagonalFirst: diagonalFirst, budget: harder)
            outcome = nearer(retried, than: first, to: to)
        }

        switch outcome {
        case .found(let staircase):
            let pulled = pulled(
                HorizontalRoute45.simplified(staircase), collider: collider, diagonalFirst: diagonalFirst)
            let tight = tightened(pulled, collider: collider, diagonalFirst: diagonalFirst)
            return .route(tight)
        case .unreachable(let blocker, _, let nearest):
            return .failed(.blocked(obstacle: blocker), nearest: nearest)
        case .exhausted(let blocker, let nearest):
            return .failed(.exhausted(obstacle: blocker), nearest: nearest)
        }
    }

    // MARK: - Pulling a route taut

    /// Replaces runs of grid steps with the longest clear elbow from each
    /// anchor: from a point on the path, find the furthest later point an
    /// elbow reaches without touching anything, jump there, repeat.
    ///
    /// The furthest point is found by galloping — doubling the stride while the
    /// elbow stays clear, then bisecting — which assumes that what is visible
    /// from an anchor is a prefix of the path. It is not always; the result is
    /// then a clear route with a corner it did not need, which `tightened`
    /// takes out. What it never is, is illegal: every jump taken was tested.
    static func pulled(
        _ path: [HorizontalPoint],
        collider: HorizontalRouteCollider,
        diagonalFirst: Bool
    ) -> [HorizontalPoint] {
        guard path.count > 2 else { return path }
        let last = path.count - 1
        var result = [path[0]]
        var anchor = 0

        while anchor < last {
            // The next point is always reachable: it is one grid step, or the
            // arrival elbow, both already checked by the search.
            var reachable = anchor + 1
            var reachableElbow: [HorizontalPoint]?

            var stride = 2
            var probe = anchor + stride
            var firstBlocked = last + 1
            while probe <= last {
                if let elbow = clearElbow(from: path[anchor], to: path[probe],
                                          collider: collider, diagonalFirst: diagonalFirst) {
                    reachable = probe
                    reachableElbow = elbow
                    stride *= 2
                    probe = anchor + stride
                } else {
                    firstBlocked = probe
                    break
                }
            }

            var low = reachable + 1
            var high = firstBlocked - 1
            while low <= high {
                let middle = (low + high) / 2
                if let elbow = clearElbow(from: path[anchor], to: path[middle],
                                          collider: collider, diagonalFirst: diagonalFirst) {
                    reachable = middle
                    reachableElbow = elbow
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }

            if let reachableElbow {
                result.append(contentsOf: reachableElbow.dropFirst())
            } else {
                result.append(path[reachable])
            }
            anchor = reachable
        }
        return HorizontalRoute45.simplified(result)
    }

    /// The elbow between two points if either posture of it is clear, the
    /// route's own posture preferred.
    private static func clearElbow(
        from: HorizontalPoint,
        to: HorizontalPoint,
        collider: HorizontalRouteCollider,
        diagonalFirst: Bool
    ) -> [HorizontalPoint]? {
        for posture in [diagonalFirst, !diagonalFirst] {
            let elbow = HorizontalRoute45.elbow(from: from, to: to, diagonalFirst: posture)
            if collider.isClear(elbow) {
                return elbow
            }
        }
        return nil
    }

    /// Drops any corner the route does not need.
    ///
    /// Each interior corner is tested for removal: if joining its neighbours
    /// directly is still clear of everything, the corner goes. Only shortcuts
    /// that are checked against the board are taken, so tightening can shorten a
    /// route but never make it illegal.
    static func tightened(
        _ points: [HorizontalPoint],
        collider: HorizontalRouteCollider,
        diagonalFirst: Bool
    ) -> [HorizontalPoint] {
        guard points.count > 2 else { return points }
        var result = points

        // Repeat until a pass changes nothing: removing one corner often makes
        // its neighbour removable too.
        var changed = true
        var passes = 0
        while changed, passes < 8 {
            changed = false
            passes += 1
            var index0 = 1
            while index0 < result.count - 1 {
                guard let shortcut = clearElbow(
                    from: result[index0 - 1], to: result[index0 + 1],
                    collider: collider, diagonalFirst: diagonalFirst
                ) else {
                    index0 += 1
                    continue
                }
                var candidate = Array(result[..<(index0 - 1)])
                candidate.append(contentsOf: shortcut)
                candidate.append(contentsOf: result[(index0 + 2)...])
                let simplified = HorizontalRoute45.simplified(candidate)

                if HorizontalRoute45.corners(of: simplified) < HorizontalRoute45.corners(of: result) {
                    result = simplified
                    changed = true
                } else {
                    index0 += 1
                }
            }
        }
        return result
    }

    // MARK: - Endpoints

    /// Obstacles whose grown hull contains `point` — the pads a route starts
    /// or ends in, and their neighbours too close to it for any route there
    /// to keep clear of.
    private static func obstaclesAround(
        _ point: HorizontalPoint,
        layer: Int,
        net: Int,
        width: Double,
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances
    ) -> Set<Int> {
        var exempt = Set<Int>()
        let octagon = HorizontalOctagon(from: point, to: point, width: 0)
        let reach = clearances.broadPhaseClearance(forTrackOn: net, layer: layer) + width / 2
        index.forEachObstacle(
            overlapping: octagon.inflated(by: reach).boundingBox, on: layer
        ) { position, obstacle in
            let clearance = clearances.clearance(
                .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
            if obstacle.hull.inflated(by: clearance + width / 2).overlaps(octagon) {
                exempt.insert(position)
            }
        }
        return exempt
    }

    /// Whether a route ending at `point` joins copper there: copper of its
    /// own net, or, for a route on no net yet, any copper, which is how such
    /// a route takes a net.
    private static func joinsCopper(
        at point: HorizontalPoint,
        layer: Int,
        net: Int,
        index: HorizontalRouterIndex
    ) -> Bool {
        var joins = false
        index.forEachObstacle(overlapping: HorizontalRect(points: [point, point]), on: layer) { _, obstacle in
            guard !joins, net < 0 || obstacle.netCode == net, obstacle.hull.contains(point) else { return }
            switch obstacle.kind {
            case .track, .solid, .via: joins = true
            case .unplatedHole, .keepout, .boardEdge: break
            }
        }
        return joins
    }

    // MARK: - Ending as near the target as it may

    /// A route that ends as near its target as the rules let it.
    struct Approach {
        /// A clear 45° route from the start, never closer to anything than the
        /// rules allow. It ends on the target when `reachesTarget`, and
        /// otherwise at the point nearest the target that a route can reach —
        /// just the start when it can go nowhere towards it.
        var points: [HorizontalPoint]
        var reachesTarget: Bool
        /// What keeps the route from the target: the obstacle the target is
        /// too close to, or the one that stopped the search. −1 when nothing
        /// does or the search could not say.
        var blocker: Int
    }

    /// Routes from `from` towards `to` and, where `to` cannot be reached
    /// legally, stops at the nearest point that can — what the interactive
    /// tool previews and lays, so the cursor over something the route must
    /// keep away from shows the route ending at its edge rather than through
    /// it.
    ///
    /// Two things keep a route off its target. The target can be too close
    /// to something — the cursor over another net's pad, a track, a keepout,
    /// or in the clearance round any of them — when the route aims instead at
    /// the nearest point that is not (`nearestClearPoint`). Or the target can
    /// be clear but out of reach, enclosed, when the route follows the search
    /// to the nearest point it got to and carries on from there as far as it
    /// stays clear.
    ///
    /// The start is exempt from what it is inside, as for `route`: a route
    /// has to be able to leave the pad it begins on. The end is exempt only
    /// where the route joins copper — its own net's, or any while it has no
    /// net — because there the target is a pad being entered, and its
    /// neighbours' clearances on a fine pitch reach its centre. Anywhere else
    /// the target is only where the cursor is, and it gets no exemption: that
    /// exemption is what used to draw a route straight through whatever the
    /// cursor rested on.
    static func approach(
        from: HorizontalPoint,
        to target: HorizontalPoint,
        layer: Int,
        net: Int,
        width: Double,
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances,
        diagonalFirst: Bool = true,
        budget: Budget = .interactive
    ) -> Approach {
        // Whole nanometres: what the route ends on is laid, and the file
        // holds integer coordinates.
        let to = HorizontalPoint(x: target.x.rounded(), y: target.y.rounded())
        guard from != to else {
            return Approach(points: [from], reachesTarget: true, blocker: -1)
        }

        var exempt = obstaclesAround(
            from, layer: layer, net: net, width: width, index: index, clearances: clearances)
        if joinsCopper(at: to, layer: layer, net: net, index: index) {
            exempt.formUnion(obstaclesAround(
                to, layer: layer, net: net, width: width, index: index, clearances: clearances))
        }
        let collider = HorizontalRouteCollider(
            index: index, clearances: clearances, layer: layer, net: net, width: width,
            exempt: exempt)

        var goal = to
        var blocker = -1
        if let inside = collider.blocker(to, to) {
            blocker = inside
            guard let clear = nearestClearPoint(to: to, collider: collider) else {
                return Approach(points: [from], reachesTarget: false, blocker: blocker)
            }
            goal = clear
        }
        guard goal != from else {
            return Approach(points: [from], reachesTarget: false, blocker: blocker)
        }

        switch solve(from: from, to: goal, collider: collider, diagonalFirst: diagonalFirst, budget: budget) {
        case .route(let points):
            return Approach(points: points, reachesTarget: goal == to, blocker: blocker)
        case .failed(let outcome, let nearest):
            if blocker < 0, case .blocked(let obstacle) = outcome { blocker = obstacle }
            if blocker < 0, case .exhausted(let obstacle) = outcome { blocker = obstacle }
            var points = HorizontalRoute45.simplified(nearest)
            points = pulled(points, collider: collider, diagonalFirst: diagonalFirst)
            points = tightened(points, collider: collider, diagonalFirst: diagonalFirst)
            points = extended(points, toward: goal, collider: collider, diagonalFirst: diagonalFirst)
            return Approach(points: points, reachesTarget: false, blocker: blocker)
        }
    }

    /// `points` carried on from its end towards `goal` for as far as it stays
    /// clear, along whichever posture of the elbow gets nearer. The search
    /// stops short on its grid; this takes the route the rest of the way to
    /// whatever stopped it. Each leg of an elbow heads towards its far end,
    /// so the further along one the route gets, the nearer the goal it ends.
    static func extended(
        _ points: [HorizontalPoint],
        toward goal: HorizontalPoint,
        collider: HorizontalRouteCollider,
        diagonalFirst: Bool
    ) -> [HorizontalPoint] {
        guard let end = points.last, end != goal else { return points }
        var best: [HorizontalPoint] = []
        var bestDistance = distance(end, goal)
        for posture in [diagonalFirst, !diagonalFirst] {
            let elbow = HorizontalRoute45.elbow(from: end, to: goal, diagonalFirst: posture)
            let prefix = clearPrefix(of: elbow, collider: collider)
            if let last = prefix.last, distance(last, goal) < bestDistance {
                best = prefix
                bestDistance = distance(last, goal)
            }
        }
        guard best.count > 1 else { return points }
        return HorizontalRoute45.simplified(points + best.dropFirst())
    }

    /// As much of a 45° polyline as is clear, from its start, which must be:
    /// up to where it first comes too close to something, to the nanometre.
    /// Clearance is lost at one point along a segment and not regained before
    /// its end, since every grown hull is convex, so the clear stretch of a
    /// segment is found by bisecting the whole steps along it.
    static func clearPrefix(
        of points: [HorizontalPoint],
        collider: HorizontalRouteCollider
    ) -> [HorizontalPoint] {
        guard var a = points.first else { return [] }
        var result = [a]
        for b in points.dropFirst() {
            if collider.blocker(a, b) == nil {
                result.append(b)
                a = b
                continue
            }
            let dx = b.x - a.x
            let dy = b.y - a.y
            let steps = max(abs(dx), abs(dy))
            guard steps > 0 else { break }
            let unit = HorizontalPoint(x: dx / steps, y: dy / steps)
            func along(_ k: Int) -> HorizontalPoint {
                HorizontalPoint(x: a.x + unit.x * Double(k), y: a.y + unit.y * Double(k))
            }
            // `low` is clear and `high` is not: the start is the route's own
            // end, and the segment as a whole collides.
            var low = 0
            var high = Int(steps.rounded(.down)) + 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if collider.blocker(a, along(middle)) == nil {
                    low = middle
                } else {
                    high = middle
                }
            }
            if low > 0 {
                result.append(along(low))
            }
            break
        }
        return result
    }

    /// The nearest point to `point` that a route may end on — outside every
    /// grown hull it has to keep out of — in whole nanometres, or nil when
    /// none could be found nearby.
    ///
    /// Worked out rather than searched for. The region the route's centre
    /// line must stay out of is a union of octagons, and the nearest point
    /// outside a union of convex shapes is on its boundary: either the foot
    /// of the perpendicular onto one face, or a corner where two faces
    /// cross. So the candidates are those feet and crossings, and the answer
    /// is the nearest of them that is clear of everything.
    ///
    /// They are looked for within a radius that doubles until one is found,
    /// starting at the depth `point` is inside, which no exit can be nearer
    /// than. Within a radius, only hulls that reach inside it can have a face
    /// there or hold a candidate there, so each round asks the index once and
    /// tests its candidates against that short list — and the first clear
    /// candidate inside the radius is the nearest there is, since any nearer
    /// one would be inside it too.
    static func nearestClearPoint(
        to point: HorizontalPoint,
        collider: HorizontalRouteCollider
    ) -> HorizontalPoint? {
        let depth = collider.depth(of: point)
        guard depth > 0 else { return point }
        var radius = max(depth, minimumClearPointRadius) + 1
        while radius <= maximumClearPointRadius {
            // A little beyond the radius, for the roundings of a candidate on
            // its edge.
            let hulls = collider.hulls(within: radius + roundingReach * 2, of: point)
                .compactMap { collider.hull($0) }
            if let found = nearestClearCandidate(to: point, among: hulls, within: radius) {
                return found
            }
            radius *= 2
        }
        return nil
    }

    /// Where `nearestClearPoint` starts looking, and how far it goes: an
    /// exit further than this from the cursor is not one the cursor is
    /// asking for, and looking further costs more than an answer is worth on
    /// every mouse move.
    private static let minimumClearPointRadius = 25_000.0
    private static let maximumClearPointRadius = 8_000_000.0

    /// How far from a candidate its whole-nanometre stand-in may be: one of
    /// the four grid points round it, or one a few further in where it is
    /// the tip of a wedge of free space too narrow for those. Faces meet at
    /// no less than 45°, so a wedge holds a grid point within this.
    private static let roundingReach = 4.0

    /// A face of a grown hull, as the line it lies on: the points `q` with
    /// `normal · q == offset`, the normal one of the eight directions'
    /// unnormalised steps.
    private struct FaceLine {
        var normal: HorizontalPoint
        var offset: Double
    }

    /// The nearest clear point among the feet and crossings, within
    /// `radius` of `point`, of the faces of `hulls`, which must be every
    /// hull reaching that far.
    private static func nearestClearCandidate(
        to point: HorizontalPoint,
        among hulls: [HorizontalOctagon],
        within radius: Double
    ) -> HorizontalPoint? {
        /// Whether `q` is on hull `i` or inside it, to the nanometre: on its
        /// boundary, for a point on one of its faces' lines.
        func touches(_ q: HorizontalPoint, _ i: Int) -> Bool {
            hulls[i].separation(from: HorizontalOctagon.supports(q)) <= 1
        }

        // A foot is as far as its line, and a crossing at least as far as
        // either of its lines, so only lines within the radius carry one.
        // And the boundary of the union is made of the hulls' own faces, so
        // a foot counts only on its face, not on the line beyond the hull,
        // and a crossing only where two faces meet: a corner of one hull, or
        // where two hulls that touch cross.
        var faces = [[FaceLine]](repeating: [], count: hulls.count)
        var candidates: [(point: HorizontalPoint, distance: Double)] = []
        for (i, hull) in hulls.enumerated() {
            for direction in HorizontalDirection45.allCases {
                let normal = direction.step
                let offset = hull.extents[direction.rawValue]
                let squared = normal.x * normal.x + normal.y * normal.y
                let along = (offset - (normal.x * point.x + normal.y * point.y)) / squared
                let distance = abs(along) * squared.squareRoot()
                guard distance <= radius else { continue }
                faces[i].append(FaceLine(normal: normal, offset: offset))
                let foot = HorizontalPoint(x: point.x + normal.x * along, y: point.y + normal.y * along)
                if touches(foot, i) {
                    candidates.append((foot, distance))
                }
            }
        }
        for i in hulls.indices where !faces[i].isEmpty {
            for j in i..<hulls.count where !faces[j].isEmpty {
                guard i == j || hulls[i].intersects(hulls[j]) else { continue }
                for (m, a) in faces[i].enumerated() {
                    for (n, b) in faces[j].enumerated() where i != j || n > m {
                        let determinant = a.normal.x * b.normal.y - a.normal.y * b.normal.x
                        guard determinant != 0 else { continue }
                        let crossing = HorizontalPoint(
                            x: (a.offset * b.normal.y - b.offset * a.normal.y) / determinant,
                            y: (a.normal.x * b.offset - b.normal.x * a.offset) / determinant)
                        let distance = Self.distance(crossing, point)
                        if distance <= radius, touches(crossing, i), touches(crossing, j) {
                            candidates.append((crossing, distance))
                        }
                    }
                }
            }
        }
        candidates.sort { $0.distance < $1.distance }

        /// How far inside the deepest of `hulls` a point is, 0 when clear.
        func depth(of point: HorizontalPoint) -> Double {
            let supports = HorizontalOctagon.supports(point)
            var depth = 0.0
            for hull in hulls {
                depth = max(depth, -hull.separation(from: supports))
            }
            return depth
        }

        for candidate in candidates {
            // Most crossings lie well inside some other hull, where no grid
            // point near them can be clear.
            guard depth(of: candidate.point) <= roundingReach * 2 else { continue }
            let c = candidate.point
            for reach in [0.0, roundingReach] {
                var roundings: [HorizontalPoint] = []
                for x in stride(from: c.x.rounded(.down) - reach, through: c.x.rounded(.up) + reach, by: 1) {
                    for y in stride(from: c.y.rounded(.down) - reach, through: c.y.rounded(.up) + reach, by: 1) {
                        roundings.append(HorizontalPoint(x: x, y: y))
                    }
                }
                roundings.sort { Self.distance($0, point) < Self.distance($1, point) }
                if let clear = roundings.first(where: { depth(of: $0) == 0 }) {
                    return clear
                }
            }
        }
        return nil
    }
}
