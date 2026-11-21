import Foundation

/// The via a route drops at its end: what `v` arms on the track tool.
///
/// A track is on one layer and a via is on every layer it spans, so where the
/// route may end with one armed is decided by more than the route's own
/// layer: the via has to keep its clearance from another net's copper on each
/// of its layers, and its hole from the same.
struct HorizontalRouteEndVia: Equatable {
    /// The via's copper, on every layer it spans.
    var diameter: Double
    var holeDiameter: Double
    /// The copper layers it spans: all of them for a through via, which is
    /// what the track tool drops (`BoardTrackRouting.throughViaLayers`), the
    /// ones it connects for a blind or buried one.
    var layers: [Int]
}

/// Where a via may stand: the clearance oracle for the via at a route's end,
/// as `HorizontalRouteCollider` is for the route's track.
///
/// Each obstacle that shares a layer with the via is grown by what the via
/// owes it there: the via's clearance and its radius, or its hole's clearance
/// and the hole's radius, whichever is more, and the most of that over the
/// layers they share, since a rule may be scoped to one. The via's centre
/// staying outside every such hull means the via is legal on all its layers.
///
/// Copper of the via's own net is no obstacle: joining it is what a via is
/// for. A via on no net joins whatever copper it lands on, as a route on no
/// net does (`joining`).
final class HorizontalRouteViaCollider {
    let index: HorizontalRouterIndex
    let clearances: HorizontalRouterClearances
    let via: HorizontalRouteEndVia
    let net: Int
    /// The furthest a grown hull reaches beyond its obstacle's own copper.
    let reach: Double

    private var exempt = Set<Int>()
    private var hulls: [HorizontalOctagon?]
    private var resolved: [Bool]

    /// `joining` is where the route is aimed. A route on no net takes the net
    /// of the copper its via lands on there, so that copper is exempt, when
    /// it is all of one net: on two nets at once a via would short them.
    init(
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances,
        via: HorizontalRouteEndVia,
        net: Int,
        joining target: HorizontalPoint? = nil
    ) {
        self.index = index
        self.clearances = clearances
        self.via = via
        self.net = net
        var reach = 0.0
        for layer in via.layers {
            reach = max(
                reach,
                clearances.broadPhaseClearance(for: .via, on: net, layer: layer) + via.diameter / 2,
                clearances.broadPhaseClearance(for: .holePlated, on: net, layer: layer) + via.holeDiameter / 2)
        }
        self.reach = reach
        self.hulls = [HorizontalOctagon?](repeating: nil, count: index.obstacles.count)
        self.resolved = [Bool](repeating: false, count: index.obstacles.count)

        if net < 0, let target {
            var landed = Set<Int>()
            var nets = Set<Int>()
            forEachObstacle(overlapping: HorizontalRect(points: [target, target])) { position, obstacle in
                guard obstacle.hull.contains(target) else { return }
                switch obstacle.kind {
                case .track, .solid, .via:
                    landed.insert(position)
                    nets.insert(obstacle.netCode)
                case .unplatedHole, .keepout, .boardEdge:
                    break
                }
            }
            if nets.count == 1 {
                exempt = landed
            }
        }
    }

    /// Every obstacle on any of the via's layers whose box overlaps `box`,
    /// once each, in obstacle order.
    private func forEachObstacle(
        overlapping box: HorizontalRect, _ body: (Int, HorizontalRouterIndex.Obstacle) -> Void
    ) {
        guard via.layers.count > 1 else {
            if let layer = via.layers.first {
                index.forEachObstacle(overlapping: box, on: layer, body)
            }
            return
        }
        var found = Set<Int>()
        for layer in via.layers {
            index.forEachObstacle(overlapping: box, on: layer) { position, _ in
                found.insert(position)
            }
        }
        for position in found.sorted() {
            body(position, index.obstacles[position])
        }
    }

    /// The region the via's centre must stay out of to keep its distance from
    /// obstacle `position`, or nil when that obstacle does not constrain the
    /// via: copper of its own net, or something on none of its layers.
    func hull(_ position: Int) -> HorizontalOctagon? {
        if resolved[position] { return hulls[position] }
        resolved[position] = true
        guard !exempt.contains(position) else { return nil }
        let obstacle = index.obstacles[position]
        var keepOff: Double?
        for layer in via.layers where obstacle.layerMin <= layer && layer <= obstacle.layerMax {
            let copper = clearances.clearance(
                .via, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
            let hole = clearances.clearance(
                .holePlated, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
            // Same-net copper at zero clearance is what the via joins. A
            // same-net obstacle that still carries a clearance stays one.
            guard copper > 0 || hole > 0 || obstacle.netCode != net || net < 0 else { continue }
            keepOff = max(keepOff ?? 0, copper + via.diameter / 2, hole + via.holeDiameter / 2)
        }
        guard let keepOff else { return nil }
        let hull = obstacle.hull.inflated(by: keepOff)
        hulls[position] = hull
        return hull
    }

    /// The first obstacle a via centred on `point` comes too close to, on any
    /// of its layers, or nil where it may stand. A via exactly at its
    /// clearance is legal, as a track is.
    func blocker(at point: HorizontalPoint) -> Int? {
        let here = HorizontalOctagon(from: point, to: point, width: 0)
        var hit: Int?
        forEachObstacle(overlapping: here.inflated(by: reach).boundingBox) { position, _ in
            guard hit == nil, let hull = self.hull(position) else { return }
            if hull.overlaps(here) {
                hit = position
            }
        }
        return hit
    }

    /// How far inside the grown hulls `point` is: 0 where the via may stand.
    func depth(of point: HorizontalPoint) -> Double {
        let supports = HorizontalOctagon.supports(point)
        let box = HorizontalOctagon(from: point, to: point, width: 0).inflated(by: reach).boundingBox
        var depth = 0.0
        forEachObstacle(overlapping: box) { position, _ in
            if let hull = self.hull(position) {
                depth = max(depth, -hull.separation(from: supports))
            }
        }
        return depth
    }

    /// The grown hulls that may come within `radius` of `point`.
    func hulls(within radius: Double, of point: HorizontalPoint) -> [HorizontalOctagon] {
        var result: [HorizontalOctagon] = []
        let supports = HorizontalOctagon.supports(point)
        let box = HorizontalOctagon(from: point, to: point, width: 0)
            .inflated(by: radius + reach).boundingBox
        forEachObstacle(overlapping: box) { position, _ in
            if let hull = self.hull(position), hull.separation(from: supports) < radius {
                result.append(hull)
            }
        }
        return result
    }

    /// `points`, a clear 45° route, cut back from its end to the last point
    /// on it where the via may stand: the route that stops short of its goal
    /// stops where its track may, which need not be where its via may. Just
    /// its start when the via may stand nowhere along it.
    func trimmed(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        guard let end = points.last, points.count > 1, blocker(at: end) != nil else { return points }
        var result = points
        while result.count > 1 {
            let b = result.removeLast()
            guard let a = result.last else { break }
            let dx = b.x - a.x
            let dy = b.y - a.y
            let steps = max(abs(dx), abs(dy))
            guard steps > 0 else { continue }
            let unit = HorizontalPoint(x: dx / steps, y: dy / steps)
            func along(_ k: Int) -> HorizontalPoint {
                HorizontalPoint(x: a.x + unit.x * Double(k), y: a.y + unit.y * Double(k))
            }
            func inside(_ hull: HorizontalOctagon, _ k: Int) -> Bool {
                let p = along(k)
                return hull.overlaps(HorizontalOctagon(from: p, to: p, width: 0))
            }
            // Back from the far end, out of each hull in the way in turn. A
            // hull is convex, so it covers one stretch of the segment, and
            // where that stretch begins is found by bisection.
            var k = Int(steps.rounded(.down))
            while k > 0, let position = blocker(at: along(k)), let hull = hull(position) {
                if inside(hull, 0) {
                    k = 0
                    break
                }
                var low = 0
                var high = k
                while high - low > 1 {
                    let middle = (low + high) / 2
                    if inside(hull, middle) {
                        high = middle
                    } else {
                        low = middle
                    }
                }
                k = low
            }
            if k > 0 {
                result.append(along(k))
                return HorizontalRoute45.simplified(result)
            }
            if blocker(at: a) == nil {
                return result
            }
        }
        return Array(points.prefix(1))
    }
}
