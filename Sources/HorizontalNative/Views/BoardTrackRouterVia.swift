import Foundation

/// The armed via of a route drawn around obstacles: where the route may end
/// so that the via the click drops there is legal.
///
/// The router holds the route's track to its own layer. The via `v` arms goes
/// through the board, so with one armed the route's end is also held to where
/// the via may stand on every layer (`HorizontalRouteEndVia`): the preview
/// stops, or is pushed aside, where the via would come too close to another
/// net's copper on any of them, and the click lays what the preview shows.
///
/// Not every click drops the armed via. One that ends the route — in a pad,
/// on copper it joins on its layer, or closing a loop there — drops none, and
/// the route must still get there over whatever lies on the other layers. So
/// such a click is first routed as a track alone, and takes that route when
/// it arrives; one that stops short ends on bare board, where the via drops,
/// and is routed again for the via.
enum BoardTrackRouterVia {
    /// The via the router keeps clear: `via`'s copper and hole, through every
    /// copper layer, as the track tool drops it (`BoardTrackRouting.dropVia`).
    static func endVia(_ via: HorizontalBoardViaTemplate, copperLayerCount: Int) -> HorizontalRouteEndVia {
        HorizontalRouteEndVia(
            diameter: via.diameter,
            holeDiameter: via.holeDiameter,
            layers: BoardTrackRouting.throughViaLayers(copperLayerCount: max(copperLayerCount, 2)))
    }

    /// The route from `from` towards `to` (`HorizontalBoardTrackRouterSession.approach`),
    /// ending where `via` may stand when the click drops it. `via` is nil
    /// with none armed. `endsRoute` says whether a click that reaches `to`
    /// ends the route there and so drops no via (`BoardTrackLoops.endsRoute`);
    /// it is asked only with a via armed.
    static func approach(
        session: HorizontalBoardTrackRouterSession,
        from: HorizontalPoint,
        to: HorizontalPoint,
        layer: Int,
        netID: String?,
        width: Double,
        diagonalFirst: Bool,
        via: HorizontalBoardViaTemplate?,
        endsRoute: () -> Bool
    ) -> HorizontalRouteFinder.Approach {
        func route(_ endVia: HorizontalRouteEndVia?) -> HorizontalRouteFinder.Approach {
            session.approach(
                from: from, to: to, layer: layer, netID: netID,
                width: width, diagonalFirst: diagonalFirst, endVia: endVia)
        }
        guard let via else {
            return route(nil)
        }
        if endsRoute() {
            let plain = route(nil)
            if plain.reachesTarget {
                return plain
            }
        }
        return route(endVia(via, copperLayerCount: session.copperLayerCount))
    }
}
