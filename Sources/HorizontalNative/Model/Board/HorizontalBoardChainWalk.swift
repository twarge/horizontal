import Foundation

/// "Walk the chain" selection after a delete. Deleting exactly one track or via
/// selects the single neighbouring track that shared an endpoint with it, so
/// pressing Delete repeatedly unzips a trace from its free end inward.
///
/// The rules, and why each exists:
///  • Only for a single deleted track or via. Unzipping a multi-object delete
///    has no meaningful "next".
///  • An endpoint landing on a PAD is not walked through, so deleting never
///    jumps across a component pad onto an unrelated trace — the pad is a
///    boundary between nets' worth of copper, not a link in the chain.
///  • More than one neighbour across both endpoints — a fork, or a mid-chain
///    segment with a neighbour at each end — is ambiguous, so nothing is
///    selected. Guessing would delete copper the user did not point at.
///  • A via at the shared point is selected in preference to the track, so the
///    unzip continues through the via rather than stopping at it or skipping
///    over it.
///
/// Position-based, matching `HorizontalBoardConnectivity` and the draw tool: two
/// pieces of copper connect when they share a rounded-nm point key.
enum HorizontalBoardChainWalk {

    /// The object to select after deleting `ref`, or nil when there is no single
    /// unambiguous neighbour. `board` is the pre-delete board.
    static func selection(afterDeleting ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalSelectableRef? {
        switch ref.type {
        case .track:
            guard let track = board.tracks.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            let pads = padPositionKeys(in: board)
            // Walk only through endpoints that are NOT on a pad (is_junc()).
            let keys = [pointKey(track.from), pointKey(track.to)].filter { !pads.contains($0) }
            return neighbor(excludingTrackID: track.id, at: keys, in: board, preferViaAtSharedPoint: true)
        case .via:
            guard let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            // A via walks to its single connected track (no via preference — the
            // via at this point is the one being deleted).
            return neighbor(excludingTrackID: nil, at: [pointKey(via.position)], in: board, preferViaAtSharedPoint: false)
        default:
            return nil
        }
    }

    // MARK: - Internals

    private static func neighbor(
        excludingTrackID excludeID: String?,
        at keys: [String],
        in board: HorizontalBoard,
        preferViaAtSharedPoint: Bool
    ) -> HorizontalSelectableRef? {
        guard !keys.isEmpty else { return nil }
        let exclude = excludeID.map(normalizedID)
        var found: HorizontalSegment?
        var sharedKey: String?
        var hits = 0
        for key in keys {
            for track in board.tracks where normalizedID(track.id) != exclude {
                guard pointKey(track.from) == key || pointKey(track.to) == key else { continue }
                hits += 1
                if hits > 1 {
                    return nil // a second neighbour → fork / mid-chain → ambiguous
                }
                found = track
                sharedKey = key
            }
        }
        guard let found, let sharedKey else { return nil }
        if preferViaAtSharedPoint,
           let via = board.vias.first(where: { pointKey($0.position) == sharedKey }) {
            return HorizontalSelectableRef(id: via.id, type: .via)
        }
        return HorizontalSelectableRef(id: found.id, type: .track, layer: found.layer)
    }

    /// All pad / hole anchor points (rounded-nm keys), from the same three
    /// position sources as `HorizontalBoardConnectivity`'s seeds (drawn endpoints
    /// snap to `packagePadPositions` centres; loaded ones to pad-polygon
    /// centroids; through-hole pads at `packageHoles`). Unlike connectivity —
    /// which only *seeds* nets from net-bearing pads — this includes every pad
    /// regardless of net, because pad-ness here is structural: it mirrors
    /// `is_junc()` guard (a track end on a pad is never walked), which
    /// is independent of whether the pad carries a net.
    private static func padPositionKeys(in board: HorizontalBoard) -> Set<String> {
        var keys = Set<String>()
        for pad in board.packagePads {
            keys.insert(pointKey(HorizontalRect(points: pad.renderVertices(arcPrecision: 24)).center))
        }
        for (_, center) in board.packagePadPositions {
            keys.insert(pointKey(center))
        }
        for hole in board.packageHoles {
            keys.insert(pointKey(hole.position))
        }
        return keys
    }

    private static func normalizedID(_ id: String) -> String { id.lowercased() }

    private static func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }
}
