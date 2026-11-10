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
///
/// The board's arrays are hashed as unordered collections. The loader builds
/// them from JSON objects, whose keys come back in a different order on every
/// load, so the same board loaded twice lists its tracks, vias and pads in two
/// different orders. Hashed in order, every reload from the archive (a sheet
/// rename, a netlist sync, a part update) looked like new copper and marked
/// the fills stale.
enum HorizontalBoardPlaneInputs {
    static func signature(of board: HorizontalBoard) -> Int {
        var hasher = Hasher()

        // Copper and obstacles the pour clips around.
        combineUnordered(board.tracks, into: &hasher)
        combineUnordered(board.vias, into: &hasher)
        combineUnordered(board.viaHoles, into: &hasher)
        combineUnordered(board.polygons, into: &hasher)
        combineUnordered(board.keepouts, into: &hasher)
        combineUnordered(board.lines, into: &hasher)
        combineUnordered(board.netTies, into: &hasher)
        combineUnordered(board.texts, into: &hasher)
        combineUnordered(board.holes, into: &hasher)
        combineUnordered(board.packagePads, into: &hasher)
        combineUnordered(board.packageHoles, into: &hasher)
        combineUnordered(board.packageTexts, into: &hasher)
        // Dictionaries hash the same in any order already.
        hasher.combine(board.junctions)
        hasher.combine(board.junctionNetIDs)

        // Clearances, thermals and plane settings all come from the rules.
        hasher.combine(board.rules)
        hasher.combine(board.netDetails)

        // Plane DEFINITIONS — everything except the fill they produce.
        combineUnordered(board.planes, into: &hasher) { plane, hasher in
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

    /// Adds `elements` as a multiset: the count and the sum of each element's
    /// own hash, which no reordering changes and an edit to any element does.
    private static func combineUnordered<Element>(
        _ elements: [Element],
        into hasher: inout Hasher,
        hashing hash: (Element, inout Hasher) -> Void
    ) {
        var sum = 0
        for element in elements {
            var elementHasher = Hasher()
            hash(element, &elementHasher)
            sum &+= elementHasher.finalize()
        }
        hasher.combine(elements.count)
        hasher.combine(sum)
    }

    private static func combineUnordered<Element: Hashable>(_ elements: [Element], into hasher: inout Hasher) {
        combineUnordered(elements, into: &hasher) { element, hasher in
            hasher.combine(element)
        }
    }
}
