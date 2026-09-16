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
        let exempt = endpointObstacles(
            from: from, to: to, layer: layer, net: net, width: width,
            index: index, clearances: clearances)
        let collider = HorizontalRouteCollider(
            index: index, clearances: clearances, layer: layer, net: net, width: width,
            exempt: exempt)

        // The plain elbow, in the route's posture or failing that the other: a
        // clear elbow beats any detour, and it is what the tool draws without
        // the router, so an open board routes exactly as before.
        for posture in [diagonalFirst, !diagonalFirst] {
            let direct = HorizontalRoute45.elbow(from: from, to: to, diagonalFirst: posture)
            if collider.isClear(direct) {
                return Result(points: direct, outcome: .complete)
            }
        }

        let direct = HorizontalRoute45.elbow(from: from, to: to, diagonalFirst: diagonalFirst)
        var outcome = HorizontalRouteGridSearch.search(
            from: from, to: to, collider: collider, diagonalFirst: diagonalFirst, budget: budget)

        if budget.retriesOnFailure, case .unreachable(_, let reachedWindowEdge) = outcome {
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
            outcome = HorizontalRouteGridSearch.search(
                from: from, to: to, collider: collider, diagonalFirst: diagonalFirst, budget: harder)
        }

        switch outcome {
        case .found(let staircase):
            let pulled = pulled(
                HorizontalRoute45.simplified(staircase), collider: collider, diagonalFirst: diagonalFirst)
            let tight = tightened(pulled, collider: collider, diagonalFirst: diagonalFirst)
            return Result(points: tight, outcome: .complete)
        case .unreachable(let blocker, _):
            return Result(points: direct, outcome: .blocked(obstacle: blocker))
        case .exhausted(let blocker):
            return Result(points: direct, outcome: .exhausted(obstacle: blocker))
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

    /// Obstacles containing either endpoint — the pads a route connects.
    private static func endpointObstacles(
        from: HorizontalPoint,
        to: HorizontalPoint,
        layer: Int,
        net: Int,
        width: Double,
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances
    ) -> Set<Int> {
        var exempt = Set<Int>()
        for endpoint in [from, to] {
            let point = HorizontalOctagon(from: endpoint, to: endpoint, width: 0)
            let reach = clearances.broadPhaseClearance(forTrackOn: net, layer: layer) + width / 2
            index.forEachObstacle(
                overlapping: point.inflated(by: reach).boundingBox, on: layer
            ) { position, obstacle in
                let clearance = clearances.clearance(
                    .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
                if obstacle.hull.inflated(by: clearance + width / 2).overlaps(point) {
                    exempt.insert(position)
                }
            }
        }
        return exempt
    }
}
