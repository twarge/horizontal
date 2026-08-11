import Foundation

/// Routes a track around whatever is in the way, on one layer.
///
/// Completes step 3 of `docs/push-shove-router.md`: walkaround handles one
/// obstacle, this handles the board. It shoves nothing — every existing object
/// stays where it is — which makes it useful on its own and is the base the
/// shove is built on.
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
        /// How many obstacles the router will detour around before giving up.
        /// Interactive means the answer has to come back this frame; an
        /// unbounded correct answer is a wrong answer.
        var maxDetours = 12
        /// Guards against two obstacles that each push the route into the other.
        var maxIterations = 48

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

    /// Where a route first crosses something it must not.
    private struct Collision {
        var segment: Int
        var obstacle: Int
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

        var waypoints = HorizontalRoute45.elbow(from: from, to: to, diagonalFirst: diagonalFirst)
        var detoursTaken = 0
        /// Obstacles already routed around, and which way. Meeting one a second
        /// time means the first choice did not work, so the other side is tried
        /// before giving up.
        var attempted: [Int: Set<Bool>] = [:]

        for _ in 0..<budget.maxIterations {
            guard let collision = firstCollision(
                along: waypoints, layer: layer, net: net, width: width,
                index: index, clearances: clearances, exempt: exempt
            ) else {
                return Result(
                    points: tightened(
                        HorizontalRoute45.simplified(waypoints),
                        layer: layer, net: net, width: width,
                        index: index, clearances: clearances,
                        diagonalFirst: diagonalFirst, exempt: exempt),
                    outcome: .complete)
            }

            guard detoursTaken < budget.maxDetours else {
                return Result(points: HorizontalRoute45.simplified(waypoints),
                              outcome: .exhausted(obstacle: collision.obstacle))
            }

            let obstacle = index.obstacles[collision.obstacle]
            let clearance = clearances.clearance(
                .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
            // Inflate by the clearance AND the moving track's half width, so the
            // route's centre line staying outside this hull means its copper
            // keeps the full distance.
            let hull = obstacle.hull.inflated(by: clearance + width / 2)

            let start = waypoints[collision.segment]
            let end = waypoints[collision.segment + 1]
            let options = HorizontalRouteWalkaround.detours(
                around: hull, from: start, to: end, diagonalFirst: diagonalFirst)
            guard !options.isEmpty else {
                return Result(points: HorizontalRoute45.simplified(waypoints),
                              outcome: .blocked(obstacle: collision.obstacle))
            }

            let alreadyTried = attempted[collision.obstacle] ?? []
            let remaining = options.filter { !alreadyTried.contains($0.isAnticlockwise) }
            guard let chosen = remaining.min(by: { lhs, rhs in
                lhs.cost != rhs.cost
                    ? lhs.cost < rhs.cost
                    : (lhs.isAnticlockwise && !rhs.isAnticlockwise)
            }) else {
                // Both sides of this obstacle have been tried and neither got
                // through. Saying so is the honest answer.
                return Result(points: HorizontalRoute45.simplified(waypoints),
                              outcome: .blocked(obstacle: collision.obstacle))
            }
            attempted[collision.obstacle, default: []].insert(chosen.isAnticlockwise)
            detoursTaken += 1

            // Splice the detour in place of the segment it replaces. Its first
            // and last points are that segment's own endpoints.
            waypoints.replaceSubrange(collision.segment...(collision.segment + 1),
                                      with: chosen.points)
        }

        let stuck = firstCollision(
            along: waypoints, layer: layer, net: net, width: width,
            index: index, clearances: clearances, exempt: exempt)
        return Result(
            points: HorizontalRoute45.simplified(waypoints),
            outcome: .exhausted(obstacle: stuck?.obstacle ?? -1))
    }

    /// Pulls a route taut: drops any corner the route does not need.
    ///
    /// A detour walks the obstacle's whole corner ring, because that is the
    /// closed-form answer and it is guaranteed legal. It is also far more
    /// corners than the route needs — the ring has up to eight, and usually two
    /// of them do the job. Left alone the result is a legal route that looks
    /// like a staircase, which is what a user notices first.
    ///
    /// So each interior corner is tested for removal: if joining its neighbours
    /// directly is still clear of everything, the corner goes. Only shortcuts
    /// that are checked against the board are taken, so tightening can shorten a
    /// route but never make it illegal.
    private static func tightened(
        _ points: [HorizontalPoint],
        layer: Int,
        net: Int,
        width: Double,
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances,
        diagonalFirst: Bool,
        exempt: Set<Int>
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
                let shortcut = HorizontalRoute45.elbow(
                    from: result[index0 - 1], to: result[index0 + 1],
                    diagonalFirst: diagonalFirst)
                var candidate = Array(result[..<(index0 - 1)])
                candidate.append(contentsOf: shortcut)
                candidate.append(contentsOf: result[(index0 + 2)...])
                let simplified = HorizontalRoute45.simplified(candidate)

                if HorizontalRoute45.corners(of: simplified) < HorizontalRoute45.corners(of: result),
                   firstCollision(along: simplified, layer: layer, net: net, width: width,
                                  index: index, clearances: clearances, exempt: exempt) == nil {
                    result = simplified
                    changed = true
                } else {
                    index0 += 1
                }
            }
        }
        return result
    }

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

    /// The first place the route crosses something, walking it in order.
    ///
    /// Order matters: detouring around the earliest obstacle first keeps the
    /// route's shape stable as the cursor moves, instead of re-deciding the
    /// whole path when a later obstacle happens to become the cheapest.
    private static func firstCollision(
        along waypoints: [HorizontalPoint],
        layer: Int,
        net: Int,
        width: Double,
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances,
        exempt: Set<Int>
    ) -> Collision? {
        guard waypoints.count > 1 else { return nil }
        let broad = clearances.broadPhaseClearance(forTrackOn: net, layer: layer) + width / 2

        for segment in 0..<(waypoints.count - 1) {
            let a = waypoints[segment]
            let b = waypoints[segment + 1]
            guard a != b else { continue }

            // A segment running in one of the eight directions is EXACTLY its own
            // octagon — the eight half-planes pin it to the line and to its own
            // extent — so this collision test is a decision rather than an
            // approximation. That is only true because routes are 45°.
            let swept = HorizontalOctagon(from: a, to: b, width: 0)
            let query = swept.inflated(by: broad)

            var hit: Int?
            index.forEachObstacle(overlapping: query.boundingBox, on: layer) { position, obstacle in
                guard hit == nil, !exempt.contains(position) else { return }
                let clearance = clearances.clearance(
                    .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
                guard clearance > 0 || obstacle.netCode != net || net < 0 else { return }
                // `overlaps`, not `intersects`: a route exactly at its clearance
                // is legal, and a detour rides that boundary by construction.
                if obstacle.hull.inflated(by: clearance + width / 2).overlaps(swept) {
                    hit = position
                }
            }
            if let hit {
                return Collision(segment: segment, obstacle: hit)
            }
        }
        return nil
    }
}
