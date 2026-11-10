import Foundation

/// The seam between the board and the router: converts a `HorizontalBoard` into
/// the router's world once, then answers route requests in board terms.
///
/// Built once when a drawing gesture starts rather than per frame. Extracting
/// the world and indexing it costs about a millisecond on a real board — fine
/// once, wasteful sixty times a second, and the board does not change while the
/// user is dragging.
///
/// See `docs/push-shove-router.md`.
final class HorizontalBoardTrackRouterSession {
    let index: HorizontalRouterIndex
    let clearances: HorizontalRouterClearances
    private let world: HorizontalRouterWorld

    init(board: HorizontalBoard) {
        let world = HorizontalRouterWorld.extract(from: board)
        self.world = world
        self.index = HorizontalRouterIndex(world: world)
        // The router keeps each rule's routing offset beyond its clearance,
        // as Horizon's does.
        self.clearances = HorizontalRouterClearances(world: world, rules: board.rules, includesRoutingOffset: true)
    }

    /// The router's dense code for a board net id, or −1 for no net.
    func netCode(for netID: String?) -> Int {
        world.netCode(for: netID)
    }

    /// Routes between two board points, avoiding what is on the layer.
    ///
    /// Returns the route whether or not it got through: an incomplete route is
    /// still worth previewing, because seeing how far it reached and what
    /// stopped it is more useful than seeing nothing.
    func route(
        from: HorizontalPoint,
        to: HorizontalPoint,
        layer: Int,
        netID: String?,
        width: Double,
        diagonalFirst: Bool,
        budget: HorizontalRouteFinder.Budget = .interactive
    ) -> HorizontalRouteFinder.Result {
        HorizontalRouteFinder.route(
            from: from, to: to, layer: layer,
            net: netCode(for: netID), width: width,
            index: index, clearances: clearances,
            diagonalFirst: diagonalFirst, budget: budget
        )
    }

    /// Routes from `from` towards `to`, ending there if a legal route can and
    /// otherwise at the nearest point one can reach
    /// (`HorizontalRouteFinder.approach`): what the track tool previews and
    /// lays.
    ///
    /// The last few answers are kept. The canvas asks the same question
    /// several times for one cursor position — its preview, the route
    /// inspector, the click — and a route that cannot get through costs a
    /// whole search to say so; the board does not change while a session
    /// lasts, so the answer does not either.
    func approach(
        from: HorizontalPoint,
        to: HorizontalPoint,
        layer: Int,
        netID: String?,
        width: Double,
        diagonalFirst: Bool,
        budget: HorizontalRouteFinder.Budget = .interactive
    ) -> HorizontalRouteFinder.Approach {
        let net = netCode(for: netID)
        let key = ApproachKey(
            fromX: from.x, fromY: from.y, toX: to.x.rounded(), toY: to.y.rounded(),
            layer: layer, net: net, width: width, diagonalFirst: diagonalFirst,
            maxExpansions: budget.maxExpansions)
        if let known = recentApproaches.first(where: { $0.key == key }) {
            return known.approach
        }
        let approach = HorizontalRouteFinder.approach(
            from: from, to: to, layer: layer,
            net: net, width: width,
            index: index, clearances: clearances,
            diagonalFirst: diagonalFirst, budget: budget
        )
        recentApproaches.insert((key, approach), at: 0)
        if recentApproaches.count > Self.recentApproachLimit {
            recentApproaches.removeLast()
        }
        return approach
    }

    private struct ApproachKey: Equatable {
        var fromX, fromY, toX, toY: Double
        var layer: Int
        var net: Int
        var width: Double
        var diagonalFirst: Bool
        var maxExpansions: Int
    }

    private static let recentApproachLimit = 8
    private var recentApproaches: [(key: ApproachKey, approach: HorizontalRouteFinder.Approach)] = []

    /// What blocked a route, in board terms, for the UI to highlight.
    ///
    /// Only tracks and vias map back to a board object — a pad, a keepout, an
    /// unplated hole or a board edge is not something the router owns an id for,
    /// so those report nil rather than a made-up reference.
    func blockingObjectID(for result: HorizontalRouteFinder.Result) -> String? {
        let position: Int
        switch result.outcome {
        case .complete: return nil
        case .blocked(let obstacle), .exhausted(let obstacle): position = obstacle
        }
        guard index.obstacles.indices.contains(position) else { return nil }

        switch index.obstacles[position].kind {
        case .track(let i):
            guard world.tracks.indices.contains(i) else { return nil }
            return world.segmentIDForTrackID[world.tracks[i].id]
        case .via(let i):
            guard world.vias.indices.contains(i) else { return nil }
            return world.markerIDForViaID[world.vias[i].id]
        case .solid, .unplatedHole, .keepout, .boardEdge:
            return nil
        }
    }
}
