import Foundation

/// What the canvas strokes in orange for the board findings that aren't a
/// clearance pair's (`HorizontalBoardRuleFinding.highlights`): copper that
/// joins two nets, a plane over another net's pad and a package standing
/// in a height restriction, each the edge of what is wrong as far as it runs.
extension HorizontalBoardRulesCheck {
    /// A short's tracks and vias, outlined together on each layer as a
    /// clearance finding's copper is, so the path the two nets meet along
    /// shows, where the marker at one track's end says nothing of it.
    static func highlights(of short: HorizontalBoardConnectivity.Short,
                           tracks: [String: HorizontalSegment], vias: [String: HorizontalMarker]) -> [[HorizontalPoint]] {
        HorizontalBoardClearanceCheck.outline(tracks: short.trackIDs.compactMap { tracks[$0] },
                                              vias: short.viaIDs.compactMap { vias[$0] })
    }

    /// Where `plane` covers `pads`, outlined: what of each pad the fill runs
    /// over, or the pad's own outline where nothing of it is found to be,
    /// so the pads show, where the marker at the middle of them all names
    /// none. One boolean a plane, against only the fill near the pads.
    static func highlights(of plane: HorizontalPlane, over pads: [HorizontalPolygon]) -> [[HorizontalPoint]] {
        let rings = pads.map { counterClockwise($0.renderVertices(arcPrecision: 24)) }.filter { $0.count >= 3 }
        guard !rings.isEmpty else { return [] }
        let near = HorizontalRect(points: rings.flatMap { $0 })
        // A fragment's outer contour is whole or not at all; its holes and
        // the other fragments far from every pad change nothing.
        var fill = [[HorizontalPoint]]()
        for fragment in plane.fragments {
            guard let outer = fragment.paths.first, HorizontalRect(points: outer).intersects(near) else { continue }
            fill.append(outer)
            fill += fragment.paths.dropFirst().filter { HorizontalRect(points: $0).intersects(near) }
        }
        let overlap = HorizontalPolygonBoolean.apply(.intersection, rings, fill, subjectFill: .nonZero, clipFill: .evenOdd)
        let found = overlap.compactMap { $0.first.map(HorizontalRect.init(points:)) }
        let missed = rings.filter { ring in
            let box = HorizontalRect(points: ring)
            return !found.contains { $0.intersects(box) }
        }
        return (overlap.flatMap { $0 } + missed).map(closed)
    }

    /// Where a package's outline and a height restriction overlap, as the
    /// check finds them, outlined.
    static func highlights(ofOverlap overlap: [[[HorizontalPoint]]]) -> [[HorizontalPoint]] {
        overlap.flatMap { $0 }.map(closed)
    }

    /// `ring` as a line that ends where it starts.
    static func closed(_ ring: [HorizontalPoint]) -> [HorizontalPoint] {
        guard let first = ring.first, ring.last != first else { return ring }
        return ring + [first]
    }
}
