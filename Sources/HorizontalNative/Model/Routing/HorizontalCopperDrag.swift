import Foundation

/// Dragging copper that stays connected: a track moved parallel to itself
/// with its two neighbours keeping their slopes (Horizon's Drag keep slope,
/// KiCad's drag), or a via moved with the ends of its tracks, their far ends
/// staying put.
///
/// A track drags as Horizon's `ToolDragKeepSlope` takes it: both its ends on
/// junctions, each junction ending exactly two tracks, this one and a
/// neighbour. Only the part of the cursor's shift across the track counts;
/// each end slides along its neighbour's line to where that meets the moved
/// track (`KeepSlopeInfo::get_pos`), so the neighbours keep their directions,
/// whichever of the eight they are, and grow or shrink. An end on a pad, a
/// via or a junction of other than two tracks can't move, and the drag is
/// refused, as Horizon leaves such a track out. Horizontal also refuses an
/// arc, a locked track or neighbour, and a neighbour running straight on from
/// the track (which no sideways move can keep in line), and stops the drag
/// before a neighbour, or the track itself, shrinks to nothing and turns over
/// (`minimumLength`), where Horizon lets it.
///
/// The drag is planned once on the board it starts from, and `applied(to:shift:)`
/// gives that board with the cursor's shift made, for the preview each step
/// and for the commit: a pure function, so Esc only drops the plan.
struct HorizontalCopperDrag: Hashable {
    /// What a drag can't start on, said as the canvas says it.
    enum Refusal: Error, Hashable {
        case nothingToDrag
        case arc
        case locked
        case endOnPad
        case endOnVia
        case junctionNotTwoTracks
        case endOnNetTie
        case neighbourArc
        case neighbourLocked
        case neighbourInLine
        case viaOnPad
        case lockedTrackOnVia

        var message: String {
            switch self {
            case .nothingToDrag: "Drag: select one track or one via."
            case .arc: "Drag: an arc track can't be dragged keeping its slopes."
            case .locked: "Drag: it is locked."
            case .endOnPad: "Drag: the track ends on a pad, which stays where it is."
            case .endOnVia: "Drag: the track ends on a via; drag the via instead."
            case .junctionNotTwoTracks: "Drag: each end must join exactly one other track."
            case .endOnNetTie: "Drag: the track ends on a net tie."
            case .neighbourArc: "Drag: a track it meets is an arc."
            case .neighbourLocked: "Drag: a track it meets is locked."
            case .neighbourInLine: "Drag: a track it meets runs straight on from it, or has no length."
            case .viaOnPad: "Drag: the via is on a pad, which stays where it is."
            case .lockedTrackOnVia: "Drag: a locked track ends on the via."
            }
        }
    }

    /// Which end of which track or net tie, by id as the board has it.
    struct SegmentEnd: Hashable {
        var trackID: String
        var isFrom: Bool
    }

    /// Which end of a board line or arc stands on a dragged junction; Horizon
    /// joins those by junction too, so they follow it.
    struct GraphicEnd: Hashable {
        enum Kind: Hashable { case line, arc }
        enum Point: Hashable { case from, to, center }
        var kind: Kind
        var id: String
        var point: Point
    }

    /// One end of the dragged track: its junction, the neighbour on it, and
    /// the neighbour's line.
    struct TrackEnd: Hashable {
        var junctionID: String
        /// Where the end is, on the board the drag starts from.
        var origin: HorizontalPoint
        /// The neighbour's other end, which stays.
        var far: HorizontalPoint
        var neighbour: SegmentEnd
        var graphics: [GraphicEnd]

        /// The neighbour, from its far end to this one.
        var direction: HorizontalPoint { origin - far }
    }

    struct TrackDrag: Hashable {
        var trackID: String
        var from: TrackEnd
        var to: TrackEnd
        /// The track's unit normal, the one direction a drag moves it in.
        var normal: HorizontalPoint
        /// How far across the track (along `normal`) the drag may take it.
        var range: ClosedRange<Double>

        /// The ends for a cursor shift: its part across the track, kept in
        /// `range`, each end on its neighbour's line.
        func ends(for shift: HorizontalPoint) -> (from: HorizontalPoint, to: HorizontalPoint) {
            let across = min(max(dragDot(shift, normal), range.lowerBound), range.upperBound)
            return (Self.end(from, across: across, normal: normal), Self.end(to, across: across, normal: normal))
        }

        static func end(_ end: TrackEnd, across: Double, normal: HorizontalPoint) -> HorizontalPoint {
            guard across != 0 else {
                return end.origin
            }
            let direction = end.direction
            return (end.origin + direction * (across / dragDot(direction, normal))).rounded
        }
    }

    struct ViaDrag: Hashable {
        var viaID: String
        var position: HorizontalPoint
        var netID: String?
    }

    enum Kind: Hashable {
        case track(TrackDrag)
        case via(ViaDrag)
    }

    var kind: Kind

    /// The shortest a neighbour, or the track, may be made by a drag, in
    /// nanometres: one micrometre, so a drag stops just short of folding a
    /// corner away (one already shorter may only grow).
    static let minimumLength = 1_000.0

    /// What Undo calls the drag.
    var actionName: String {
        switch kind {
        case .track: "Drag Track"
        case .via: "Drag Via"
        }
    }

    /// Where the drag holds the copper when no cursor says: the track's
    /// middle, or the via.
    var anchor: HorizontalPoint {
        switch kind {
        case .track(let drag): ((drag.from.origin + drag.to.origin) * 0.5).rounded
        case .via(let drag): drag.position
        }
    }

    // MARK: - Starting

    /// A drag of the one selected track that can be dragged, as Horizon's
    /// tool passes over the selected tracks it can't drag (a run selected
    /// whole drags its one middle track); else of the one selected via, when
    /// no selected track can be dragged; or why there is none. Junctions and
    /// everything else in `selection` are let be.
    static func begin(selection: [HorizontalSelectableRef], on board: HorizontalBoard) -> Result<HorizontalCopperDrag, Refusal> {
        let tracks = uniqueIDs(selection.filter { $0.type == .track })
        let vias = uniqueIDs(selection.filter { $0.type == .via })
        let results = tracks.map { trackDrag(trackID: $0, on: board) }
        let draggable = results.compactMap { try? $0.get() }
        if draggable.count == 1 {
            return .success(HorizontalCopperDrag(kind: .track(draggable[0])))
        }
        guard draggable.isEmpty else {
            return .failure(.nothingToDrag)
        }
        if vias.count == 1 {
            return viaDrag(viaID: vias[0], on: board).map { HorizontalCopperDrag(kind: .via($0)) }
        }
        if vias.isEmpty, results.count == 1, case .failure(let refusal) = results[0] {
            return .failure(refusal)
        }
        return .failure(.nothingToDrag)
    }

    static func trackDrag(trackID: String, on board: HorizontalBoard) -> Result<TrackDrag, Refusal> {
        guard let track = board.tracks.first(where: { same($0.id, trackID) }) else {
            return .failure(.nothingToDrag)
        }
        guard track.center == nil else { return .failure(.arc) }
        guard !track.locked else { return .failure(.locked) }
        let layers = board.junctionLayers()
        let byPoint = board.junctionIDsByPoint()
        let padKeys = Set(board.packagePadPositions.values.map(HorizontalBoard.junctionPointKey))

        func end(isFrom: Bool) -> Result<TrackEnd, Refusal> {
            let point = isFrom ? track.from : track.to
            let key = HorizontalBoard.junctionPointKey(point)
            guard !padKeys.contains(key) else { return .failure(.endOnPad) }
            let named = isFrom ? track.fromJunctionID : track.toJunctionID
            // An end the file names no junction for is on a pad, unless the
            // layer rule finds it one (`junctionIDs(at:joining:)`).
            guard let junctionID = named
                    ?? board.junctionIDs(at: point, joining: track.layer, layers: layers, byPoint: byPoint).first else {
                return .failure(.endOnPad)
            }
            if board.vias.contains(where: { HorizontalBoard.junctionPointKey($0.position) == key && netsMatch($0.netID, track.netID) }) {
                return .failure(.endOnVia)
            }
            let ends = segmentEnds(onJunction: junctionID, at: point, in: board, layers: layers, byPoint: byPoint)
            guard ends.netTies.isEmpty else { return .failure(.endOnNetTie) }
            let others = ends.tracks.filter { !same($0.trackID, track.id) }
            guard ends.tracks.count == 2, others.count == 1, let other = others.first,
                  let neighbour = board.tracks.first(where: { same($0.id, other.trackID) }) else {
                return .failure(.junctionNotTwoTracks)
            }
            guard neighbour.center == nil else { return .failure(.neighbourArc) }
            guard !neighbour.locked else { return .failure(.neighbourLocked) }
            let far = other.isFrom ? neighbour.to : neighbour.from
            return .success(TrackEnd(
                junctionID: junctionID,
                origin: point,
                far: far,
                neighbour: other,
                graphics: graphicEnds(at: point, in: board)
            ))
        }

        let from: TrackEnd, to: TrackEnd
        switch (end(isFrom: true), end(isFrom: false)) {
        case (.failure(let refusal), _), (_, .failure(let refusal)):
            return .failure(refusal)
        case (.success(let a), .success(let b)):
            from = a
            to = b
        }
        guard !same(from.junctionID, to.junctionID), !same(from.neighbour.trackID, to.neighbour.trackID) else {
            // A loop of two tracks: each would be the other's neighbour.
            return .failure(.junctionNotTwoTracks)
        }
        let along = track.to - track.from
        let length = along.length
        guard length > 0 else { return .failure(.neighbourInLine) }
        let unit = along * (1 / length)
        let normal = HorizontalPoint(x: -unit.y, y: unit.x)

        // Each neighbour's length goes as 1 + across / (direction · normal),
        // and the track's as its length plus across times the difference of
        // its ends' slides along it: all linear in `across`, so each bounds it
        // on one side.
        var lower = -Double.infinity, upper = Double.infinity
        func bound(constant: Double, slope: Double, atLeast minimum: Double) {
            guard slope != 0 else { return }
            let limit = (minimum - constant) / slope
            if slope > 0 { lower = max(lower, limit) } else { upper = min(upper, limit) }
        }
        var slides = [Double]()
        for end in [from, to] {
            let direction = end.direction
            let reach = direction.length
            let across = dragDot(direction, normal)
            // Running on in line (within a nanometre over its length) or of no
            // length, the neighbour's line meets the moved track nowhere.
            guard reach > 0, abs(across) > 1e-6 * reach else { return .failure(.neighbourInLine) }
            bound(constant: 1, slope: 1 / across, atLeast: min(1, minimumLength / reach))
            slides.append(dragDot(direction, unit) / across)
        }
        bound(constant: length, slope: slides[1] - slides[0], atLeast: min(length, minimumLength))
        guard lower <= 0, upper >= 0 else {
            return .failure(.neighbourInLine)
        }
        return .success(TrackDrag(trackID: track.id, from: from, to: to, normal: normal, range: lower...upper))
    }

    static func viaDrag(viaID: String, on board: HorizontalBoard) -> Result<ViaDrag, Refusal> {
        guard let via = board.vias.first(where: { same($0.id, viaID) }) else {
            return .failure(.nothingToDrag)
        }
        guard !via.locked else { return .failure(.locked) }
        let key = HorizontalBoard.junctionPointKey(via.position)
        if board.packagePadPositions.values.contains(where: { HorizontalBoard.junctionPointKey($0) == key }) {
            return .failure(.viaOnPad)
        }
        let lockedEnd = board.tracks.contains { track in
            track.locked && netsMatch(track.netID, via.netID)
                && [track.from, track.to].contains { HorizontalBoard.junctionPointKey($0) == key }
        }
        guard !lockedEnd else { return .failure(.lockedTrackOnVia) }
        return .success(ViaDrag(viaID: via.id, position: via.position, netID: via.netID))
    }

    // MARK: - Dragging

    /// `board`, the one the drag was planned on, with the cursor's `shift`
    /// made.
    func applied(to board: HorizontalBoard, shift: HorizontalPoint) -> HorizontalBoard {
        var result = board
        switch kind {
        case .track(let drag):
            let ends = drag.ends(for: shift)
            Self.move(drag.from, to: ends.from, trackID: drag.trackID, isFrom: true, on: &result)
            Self.move(drag.to, to: ends.to, trackID: drag.trackID, isFrom: false, on: &result)
        case .via(let drag):
            let target = (drag.position + shift).rounded
            // The via, its drill, its junctions and the ends of its net's
            // tracks on every layer it joins, once each and folded where they
            // land, as a move takes them.
            var points = BoardMovingPoints()
            points.add(drag.position, to: target, netID: drag.netID)
            points.apply(from: board, to: &result)
        }
        return result
    }

    /// The track's end and its junction to `target`, with the neighbour's
    /// end and the lines and arcs on the junction.
    private static func move(_ end: TrackEnd, to target: HorizontalPoint, trackID: String, isFrom: Bool, on board: inout HorizontalBoard) {
        guard target != end.origin else {
            return
        }
        if let key = board.junctions.keys.first(where: { same($0, end.junctionID) }) {
            board.junctions[key] = target
        }
        for segmentEnd in [SegmentEnd(trackID: trackID, isFrom: isFrom), end.neighbour] {
            guard let index = board.tracks.firstIndex(where: { same($0.id, segmentEnd.trackID) }) else { continue }
            if segmentEnd.isFrom {
                board.tracks[index].from = target
            } else {
                board.tracks[index].to = target
            }
        }
        for graphic in end.graphics {
            switch graphic.kind {
            case .line:
                guard let index = board.lines.firstIndex(where: { same($0.id, graphic.id) }) else { continue }
                switch graphic.point {
                case .from: board.lines[index].from = target
                case .to: board.lines[index].to = target
                case .center: board.lines[index].center = target
                }
            case .arc:
                guard let index = board.arcs.firstIndex(where: { same($0.id, graphic.id) }) else { continue }
                switch graphic.point {
                case .from: board.arcs[index].from = target
                case .to: board.arcs[index].to = target
                case .center: board.arcs[index].center = target
                }
            }
        }
    }

    // MARK: - What stands on a junction

    /// The track and net tie ends on junction `id` at `point`: those naming
    /// it, and those naming none at its point that the layer rule gives it,
    /// as `HorizontalBoard.refsEnding(onJunction:)` finds them, with which
    /// end each is.
    static func segmentEnds(
        onJunction id: String,
        at point: HorizontalPoint,
        in board: HorizontalBoard,
        layers: [String: Set<Int>],
        byPoint: [String: [String]]
    ) -> (tracks: [SegmentEnd], netTies: [SegmentEnd]) {
        let key = HorizontalBoard.junctionPointKey(point)
        func ends(of segments: [HorizontalSegment]) -> [SegmentEnd] {
            var found = [SegmentEnd]()
            for segment in segments {
                for (isFrom, end, junction) in [(true, segment.from, segment.fromJunctionID), (false, segment.to, segment.toJunctionID)] {
                    if let junction {
                        if same(junction, id) { found.append(SegmentEnd(trackID: segment.id, isFrom: isFrom)) }
                    } else if HorizontalBoard.junctionPointKey(end) == key,
                              board.junctionIDs(at: point, joining: segment.layer, layers: layers, byPoint: byPoint)
                                .contains(where: { same($0, id) }) {
                        found.append(SegmentEnd(trackID: segment.id, isFrom: isFrom))
                    }
                }
            }
            return found
        }
        return (ends(of: board.tracks), ends(of: board.netTies))
    }

    private static func graphicEnds(at point: HorizontalPoint, in board: HorizontalBoard) -> [GraphicEnd] {
        let key = HorizontalBoard.junctionPointKey(point)
        func at(_ other: HorizontalPoint) -> Bool { HorizontalBoard.junctionPointKey(other) == key }
        var ends = [GraphicEnd]()
        for line in board.lines {
            if at(line.from) { ends.append(GraphicEnd(kind: .line, id: line.id, point: .from)) }
            if at(line.to) { ends.append(GraphicEnd(kind: .line, id: line.id, point: .to)) }
        }
        for arc in board.arcs {
            if at(arc.from) { ends.append(GraphicEnd(kind: .arc, id: arc.id, point: .from)) }
            if at(arc.to) { ends.append(GraphicEnd(kind: .arc, id: arc.id, point: .to)) }
            if at(arc.center) { ends.append(GraphicEnd(kind: .arc, id: arc.id, point: .center)) }
        }
        return ends
    }

    // MARK: - Helpers

    private static func uniqueIDs(_ refs: [HorizontalSelectableRef]) -> [String] {
        var seen = Set<String>()
        return refs.map(\.id).filter { seen.insert($0.lowercased()).inserted }
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    private static func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return same(lhs, rhs)
    }
}

private func dragDot(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y
}
