import Foundation

/// A fingerprint of everything a plane pour reads.
///
/// When it changes, the fills on screen no longer describe the board — copper
/// has moved, a clearance rule changed, a plane was redefined — so the pour is
/// stale and has to be recomputed. This is what lets the app say so instead of
/// leaving the user to remember.
///
/// It deliberately EXCLUDES each plane's `fragments`, which are the pour's
/// output: including them would make every pour immediately invalidate itself.
/// It also excludes anything a pour never reads (packages' silkscreen, decals,
/// dimensions, display state), so cosmetic edits do not claim the fills are out
/// of date.
///
/// The hash is only ever compared within one run — `Hasher` is seeded per
/// process — which is all that is needed, since staleness is tracked from the
/// board that was last poured.
enum HorizontalBoardPlaneInputs {
    static func signature(of board: HorizontalBoard) -> Int {
        var hasher = Hasher()

        // Copper and obstacles the pour clips around.
        hasher.combine(board.tracks)
        hasher.combine(board.vias)
        hasher.combine(board.viaHoles)
        hasher.combine(board.polygons)
        hasher.combine(board.keepouts)
        hasher.combine(board.lines)
        hasher.combine(board.netTies)
        hasher.combine(board.texts)
        hasher.combine(board.holes)
        hasher.combine(board.packagePads)
        hasher.combine(board.packageHoles)
        hasher.combine(board.packageTexts)
        hasher.combine(board.junctions)
        hasher.combine(board.junctionNetIDs)

        // Clearances, thermals and plane settings all come from the rules.
        hasher.combine(board.rules)
        hasher.combine(board.netDetails)

        // Plane DEFINITIONS — everything except the fill they produce.
        for plane in board.planes {
            hasher.combine(plane.id)
            hasher.combine(plane.netID)
            hasher.combine(plane.polygonID)
            hasher.combine(plane.layer)
            hasher.combine(plane.priority)
            hasher.combine(plane.fillStyle)
            hasher.combine(plane.minWidth)
            hasher.combine(plane.keepOrphans)
            hasher.combine(plane.fallbackPolygon)
            hasher.combine(plane.fromRules)
            hasher.combine(plane.settings)
        }

        return hasher.finalize()
    }
}
