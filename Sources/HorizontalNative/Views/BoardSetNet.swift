import Foundation

/// Set Net… on a track or via: Horizon's Set via net, and the way a track
/// gets one too.
///
/// Copper on a board holds no net of its own. A track's net is what its pads
/// and vias give it (`Board::propagate_nets`), and the only net the board
/// file keeps on copper is a via's pinned one (`net_set`), as a stitching via
/// has. So the net goes on every via in the run of copper the track or via is
/// part of, and the run takes it from them: that run is the one
/// `HorizontalBoardConnectivity.recompute` floods to give the copper its net.
///
/// A run that reaches a pad has the pad's net, which is the schematic's to
/// give: setting another there would short the pad to it, and Horizon drops
/// a track whose net isn't its pad's. A run with no via has nothing to hold
/// a net. Set Net… is unavailable on both, and says why.
enum BoardSetNet {
    enum Availability: Equatable {
        /// The net goes on these vias, every one in the run.
        case available(viaIDs: [String])
        /// A track whose run reaches no via, nor pad.
        case needsVia
        /// A run on no net, or two, that reaches a pad.
        case reachesPad

        var reason: String? {
            switch self {
            case .available:
                return nil
            case .needsVia:
                return "A track takes its net from the pads and vias it reaches, and this one reaches neither. Place a via on it to give it a net."
            case .reachesPad:
                return "Its copper reaches a pad, which takes its net from the schematic."
            }
        }
    }

    /// Whether Set Net… may have something to say about `ref`, without
    /// looking at the copper it is part of: a track or via on no net, or on
    /// one a via pins, which is the only other net copper off a pad can have.
    static func candidate(
        _ ref: HorizontalSelectableRef,
        in board: HorizontalBoard,
        pinnedNets: Set<String>
    ) -> HorizontalBoardConnectivity.Copper? {
        let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
        func open(_ netID: String?) -> Bool {
            netID.map { pinnedNets.contains(HorizontalCanvasModeSupport.normalizedID($0)) } ?? true
        }
        switch ref.type {
        case .track:
            guard let track = board.tracks.first(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }),
                  open(track.netID) else {
                return nil
            }
            return .track(track.id)
        case .via:
            guard let via = board.vias.first(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }),
                  open(via.netID) else {
                return nil
            }
            return .via(via.id)
        default:
            return nil
        }
    }

    /// What Set Net… does for each of `refs`, in order: nil where it offers
    /// nothing, which is a ref that isn't a track or via, or copper on a
    /// pad's net.
    static func availability(of refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> [Availability?] {
        let pinnedNets = Set(board.vias.compactMap(\.netSetID).map(HorizontalCanvasModeSupport.normalizedID))
        let candidates = refs.map { candidate($0, in: board, pinnedNets: pinnedNets) }
        var runs = HorizontalBoardConnectivity.runs(of: candidates.compactMap { $0 }, in: board).makeIterator()
        return candidates.map { candidate in
            guard candidate != nil, let run = runs.next() ?? nil else {
                return nil
            }
            if !run.pads.isEmpty {
                // One net is the pad's, which the copper has; none, or a
                // short between two, is a pad Set Net… can't overrule.
                return run.nets.count == 1 ? nil : .reachesPad
            }
            return run.viaIDs.isEmpty ? .needsVia : .available(viaIDs: run.viaIDs)
        }
    }

    static func availability(of ref: HorizontalSelectableRef, in board: HorizontalBoard) -> Availability? {
        availability(of: [ref], in: board).first ?? nil
    }

    /// Pins `netID` on the vias of every run among `refs` that can take it.
    /// Returns whether anything changed; the caller recomputes connectivity,
    /// which gives the run's tracks and junctions the net.
    @discardableResult
    static func setNet(_ netID: String, on refs: [HorizontalSelectableRef], in board: inout HorizontalBoard) -> Bool {
        let net = HorizontalCanvasModeSupport.normalizedID(netID)
        var viaIDs = Set<String>()
        for case .available(let ids)? in availability(of: refs, in: board) {
            viaIDs.formUnion(ids.map(HorizontalCanvasModeSupport.normalizedID))
        }
        var changed = false
        for index in board.vias.indices where viaIDs.contains(HorizontalCanvasModeSupport.normalizedID(board.vias[index].id)) {
            guard board.vias[index].netSetID.map(HorizontalCanvasModeSupport.normalizedID) != net
                    || board.vias[index].netID.map(HorizontalCanvasModeSupport.normalizedID) != net else {
                continue
            }
            board.vias[index].netSetID = net
            board.vias[index].netID = net
            changed = true
        }
        return changed
    }
}
