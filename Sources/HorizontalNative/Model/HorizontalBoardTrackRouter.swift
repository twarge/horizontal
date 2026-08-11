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
        self.clearances = HorizontalRouterClearances(world: world, rules: board.rules)
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
