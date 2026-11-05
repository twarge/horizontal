import Foundation

/// Horizon's Select More (+) and Select More (stop at vias) (=), which a
/// double-click on a track runs too: the run of copper a selection's tracks,
/// junctions and vias are part of, out to where it ends on pads.
///
/// As `ImpBoard::handle_select_more` does it: every track with an end on a
/// junction the selection holds joins it, with the junction at its other
/// end, until nothing more is reached, and the selection becomes those
/// tracks and junctions. A selected via stands for its junction. A track end
/// on a pad is on no junction, so the run stops there; stopping at vias, it
/// stops at a junction a via stands on too, taking one only when the
/// selection held it or its via.
///
/// Horizon's via has one junction, which every track at it ends on. A point
/// here can hold a junction per layer, which a via there joins
/// (`HorizontalBoard+TrackJunctions`), so the junctions at a via are one
/// stop on the run, as Horizon's one junction is.
enum BoardSelectMore {
    /// Whether Select More has anything to start from: a track, junction or
    /// via, as Horizon makes the action sensitive.
    static func canSelectMore(from selection: [HorizontalSelectableRef]) -> Bool {
        selection.contains { [.track, .junction, .via].contains($0.type) }
    }

    /// The tracks and junctions Select More reaches from `selection`, which
    /// it replaces: the tracks in the board's order, then the junctions by
    /// id, each ref as the board's selectables name it. Empty when the
    /// selection holds no track, junction or via on the board.
    static func selection(
        from selection: [HorizontalSelectableRef],
        in board: HorizontalBoard,
        stopsAtVias: Bool
    ) -> [HorizontalSelectableRef] {
        guard canSelectMore(from: selection) else {
            return []
        }
        let runs = Runs(board: board)

        var tracks = Set<Int>()
        var stops = Set<Stop>()
        var heldJunctions = Set<String>()
        for ref in selection {
            let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
            switch ref.type {
            case .track:
                if let index = runs.trackIndex[id] {
                    tracks.insert(index)
                }
            case .junction:
                if let junction = runs.junctionKeys[id] {
                    heldJunctions.insert(junction)
                    stops.insert(runs.stop(forJunction: junction, layer: nil))
                }
            case .via:
                if let via = board.vias.first(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }) {
                    stops.insert(.via(HorizontalBoard.junctionPointKey(via.position)))
                }
            default:
                continue
            }
        }

        var trackQueue = Array(tracks)
        var stopQueue = Array(stops)
        while !trackQueue.isEmpty || !stopQueue.isEmpty {
            while let index = trackQueue.popLast() {
                for stop in runs.trackStops[index] where !(stopsAtVias && stop.isVia) {
                    if stops.insert(stop).inserted {
                        stopQueue.append(stop)
                    }
                }
            }
            while let stop = stopQueue.popLast() {
                for index in runs.stopTracks[stop] ?? [] where tracks.insert(index).inserted {
                    trackQueue.append(index)
                }
            }
        }

        var junctions = heldJunctions
        for stop in stops {
            junctions.formUnion(runs.stopJunctions[stop] ?? [])
        }
        return tracks.sorted().map { HorizontalSelectableRef(id: board.tracks[$0].id, type: .track, layer: board.tracks[$0].layer) }
            + junctions.sorted().map { HorizontalSelectableRef(id: $0, type: .junction) }
    }

    /// Where tracks meet on a run: a junction, or the junctions at a via's
    /// point, which the via joins into one.
    private enum Stop: Hashable {
        /// A junction's normalized id.
        case junction(String)
        /// A via's point (`HorizontalBoard.junctionPointKey`).
        case via(String)

        var isVia: Bool {
            if case .via = self { return true }
            return false
        }
    }

    /// The board's tracks by the stops at their ends, and the junctions at
    /// each stop.
    private struct Runs {
        /// Track index by normalized id.
        var trackIndex = [String: Int]()
        /// The board's junction key by normalized id.
        var junctionKeys = [String: String]()
        /// Each track's stops, by index: one an end, an end on no junction
        /// (a pad's) none.
        var trackStops = [[Stop]]()
        var stopTracks = [Stop: [Int]]()
        /// The board's junction keys at each stop.
        var stopJunctions = [Stop: Set<String>]()
        private var viasByPoint = [String: [HorizontalMarker]]()
        private let board: HorizontalBoard

        init(board: HorizontalBoard) {
            self.board = board
            for id in board.junctions.keys {
                junctionKeys[HorizontalCanvasModeSupport.normalizedID(id)] = id
            }
            for via in board.vias {
                viasByPoint[HorizontalBoard.junctionPointKey(via.position), default: []].append(via)
            }
            let byPoint = board.junctionIDsByPoint()
            let layers = board.junctionLayers()
            // A via's junctions are its stop's whether or not a track ends on
            // them, so a selected via brings the junction it stands on.
            for key in viasByPoint.keys {
                stopJunctions[.via(key), default: []].formUnion(byPoint[key] ?? [])
            }
            for (index, track) in board.tracks.enumerated() {
                let id = HorizontalCanvasModeSupport.normalizedID(track.id)
                if trackIndex[id] == nil {
                    trackIndex[id] = index
                }
                var stops = [Stop]()
                for (point, named) in [(track.from, track.fromJunctionID), (track.to, track.toJunctionID)] {
                    guard let junction = endJunction(named: named, at: point, layer: track.layer, layers: layers, byPoint: byPoint) else {
                        continue
                    }
                    let stop = stop(forJunction: junction, layer: track.layer)
                    stops.append(stop)
                    stopTracks[stop, default: []].append(index)
                    stopJunctions[stop, default: []].insert(junction)
                }
                trackStops.append(stops)
            }
        }

        /// The stop a junction is on: its via's, when a via at its point
        /// reaches `layer` (any via there, for nil), else its own.
        func stop(forJunction junction: String, layer: Int?) -> Stop {
            if let point = board.junctions[junction] {
                let key = HorizontalBoard.junctionPointKey(point)
                if let vias = viasByPoint[key], vias.contains(where: { layer.map($0.spansCopperLayer) ?? true }) {
                    return .via(key)
                }
            }
            return .junction(HorizontalCanvasModeSupport.normalizedID(junction))
        }

        /// The junction a track end is on, as the writer gives it one: the
        /// junction the file names, while it is there, else one copper on
        /// `layer` ends on at the point. None on a pad, which holds no
        /// junction.
        private func endJunction(
            named name: String?,
            at point: HorizontalPoint,
            layer: Int?,
            layers: [String: Set<Int>],
            byPoint: [String: [String]]
        ) -> String? {
            let key = HorizontalBoard.junctionPointKey(point)
            if let name, let junction = junctionKeys[HorizontalCanvasModeSupport.normalizedID(name)],
               let position = board.junctions[junction],
               HorizontalBoard.junctionPointKey(position) == key {
                return junction
            }
            return board.junctionIDs(at: point, joining: layer, layers: layers, byPoint: byPoint).first
        }
    }
}
