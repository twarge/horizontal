import Foundation

/// Horizon's Lock, Unlock and Unlock All (`ToolLock`) on tracks and vias, and
/// what a lock holds.
///
/// The flag is Horizon's `locked` on a track or via, which the board file
/// keeps and the loader reads. Locked copper stays where it is: a move,
/// rotate or mirror of a selection leaves it, and so does a delete, as a
/// fixed package stays (`HorizontalPlacement.fixed`). So do a junction and
/// a via where a locked track ends or a locked via stands, which would
/// otherwise take the locked copper with them. The route tool's loop removal keeps
/// a chain with locked copper in it, and block layout sync already leaves
/// locked copper alone (`HorizontalBlockLayoutSync`).
///
/// A track moved off locked copper keeps its end there, as an end on a pad
/// stays (`pinnedEndPositions`, `BoardTrackPadEnds`).
enum BoardCopperLock {
    private static func normalized(_ id: String) -> String {
        HorizontalCanvasModeSupport.normalizedID(id)
    }

    /// Whether `ref` is a track or via, the copper Lock and Unlock take.
    static func isLockable(_ ref: HorizontalSelectableRef) -> Bool {
        ref.type == .track || ref.type == .via
    }

    /// Whether `ref` is a track or via that is locked on `board`.
    static func isLocked(_ ref: HorizontalSelectableRef, in board: HorizontalBoard) -> Bool {
        let id = normalized(ref.id)
        switch ref.type {
        case .track:
            return board.tracks.contains { $0.locked && normalized($0.id) == id }
        case .via:
            return board.vias.contains { $0.locked && normalized($0.id) == id }
        default:
            return false
        }
    }

    /// What the lock holds on `board`, by normalized id: the locked tracks
    /// and vias, and the junctions and vias at their ends.
    struct Held {
        var trackIDs = Set<String>()
        var viaIDs = Set<String>()
        var junctionIDs = Set<String>()

        var isEmpty: Bool { trackIDs.isEmpty && viaIDs.isEmpty }

        func holds(_ ref: HorizontalSelectableRef) -> Bool {
            switch ref.type {
            case .track: return trackIDs.contains(HorizontalCanvasModeSupport.normalizedID(ref.id))
            case .via: return viaIDs.contains(HorizontalCanvasModeSupport.normalizedID(ref.id))
            case .junction: return junctionIDs.contains(HorizontalCanvasModeSupport.normalizedID(ref.id))
            default: return false
            }
        }
    }

    static func held(in board: HorizontalBoard) -> Held {
        var held = Held()
        var points = Set<String>()
        for track in board.tracks where track.locked {
            held.trackIDs.insert(normalized(track.id))
            for junction in [track.fromJunctionID, track.toJunctionID].compactMap({ $0 }) {
                held.junctionIDs.insert(normalized(junction))
            }
            points.insert(HorizontalCanvasModeSupport.pointKey(track.from))
            points.insert(HorizontalCanvasModeSupport.pointKey(track.to))
        }
        for via in board.vias where via.locked {
            held.viaIDs.insert(normalized(via.id))
            points.insert(HorizontalCanvasModeSupport.pointKey(via.position))
        }
        guard !points.isEmpty else {
            return held
        }
        // A track end the file puts on no junction id the model kept is
        // still on the junction at its point; and a via there carries the
        // point, and with it the locked track's end, wherever it goes.
        for (id, point) in board.junctions where points.contains(HorizontalCanvasModeSupport.pointKey(point)) {
            held.junctionIDs.insert(normalized(id))
        }
        for via in board.vias where points.contains(HorizontalCanvasModeSupport.pointKey(via.position)) {
            held.viaIDs.insert(normalized(via.id))
        }
        return held
    }

    /// `refs` without what the lock holds on `board`, in order.
    static func removingHeld(_ refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> [HorizontalSelectableRef] {
        guard board.tracks.contains(where: \.locked) || board.vias.contains(where: \.locked) else {
            return refs
        }
        let held = held(in: board)
        return refs.filter { !held.holds($0) }
    }

    /// The points a moving track's end stays on (`BoardTrackPadEnds`): the
    /// pads' centres, and the ends of locked tracks and the locked vias, so
    /// a track moved off locked copper swings about it rather than taking
    /// the locked copper's end with it, as one moved off a pad does.
    static func pinnedEndPositions(_ board: HorizontalBoard) -> [String: HorizontalPoint] {
        var positions = board.packagePadPositions
        guard hasLocked(board) else {
            return positions
        }
        for track in board.tracks where track.locked {
            positions["locked-track:\(track.id):from"] = track.from
            positions["locked-track:\(track.id):to"] = track.to
        }
        for via in board.vias where via.locked {
            positions["locked-via:\(via.id)"] = via.position
        }
        return positions
    }

    /// Whether Lock (`locked` true) or Unlock (false) would change any of
    /// `refs`: one of them is a track or via that isn't so already.
    static func canSet(_ locked: Bool, on refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> Bool {
        let ids = lockableIDs(refs)
        return board.tracks.contains { $0.locked != locked && ids.tracks.contains(normalized($0.id)) }
            || board.vias.contains { $0.locked != locked && ids.vias.contains(normalized($0.id)) }
    }

    /// Lock or Unlock: `locked` on every track and via of `refs`. Returns
    /// whether anything changed.
    @discardableResult
    static func setLocked(_ locked: Bool, on refs: [HorizontalSelectableRef], in board: inout HorizontalBoard) -> Bool {
        let ids = lockableIDs(refs)
        var changed = false
        for index in board.tracks.indices
            where board.tracks[index].locked != locked && ids.tracks.contains(normalized(board.tracks[index].id)) {
            board.tracks[index].locked = locked
            changed = true
        }
        for index in board.vias.indices
            where board.vias[index].locked != locked && ids.vias.contains(normalized(board.vias[index].id)) {
            board.vias[index].locked = locked
            changed = true
        }
        return changed
    }

    /// Which of Lock, Unlock and Unlock All `refs` on `board` offer, as bits,
    /// for a canvas to notice when that changes.
    static func commandSignature(_ refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> Int {
        let lockable = refs.filter(isLockable)
        var bits = hasLocked(board) ? 1 : 0
        if !lockable.isEmpty {
            bits |= canSet(true, on: lockable, in: board) ? 2 : 0
            bits |= canSet(false, on: lockable, in: board) ? 4 : 0
        }
        return bits
    }

    /// Whether the board has a locked track or via for Unlock All to free.
    static func hasLocked(_ board: HorizontalBoard) -> Bool {
        board.tracks.contains(where: \.locked) || board.vias.contains(where: \.locked)
    }

    /// Unlock All: every track and via on the board unlocked. Returns whether
    /// anything changed.
    @discardableResult
    static func unlockAll(in board: inout HorizontalBoard) -> Bool {
        var changed = false
        for index in board.tracks.indices where board.tracks[index].locked {
            board.tracks[index].locked = false
            changed = true
        }
        for index in board.vias.indices where board.vias[index].locked {
            board.vias[index].locked = false
            changed = true
        }
        return changed
    }

    private static func lockableIDs(_ refs: [HorizontalSelectableRef]) -> (tracks: Set<String>, vias: Set<String>) {
        var tracks = Set<String>(), vias = Set<String>()
        for ref in refs {
            switch ref.type {
            case .track: tracks.insert(normalized(ref.id))
            case .via: vias.insert(normalized(ref.id))
            default: break
            }
        }
        return (tracks, vias)
    }
}
