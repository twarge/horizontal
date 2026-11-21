import Foundation

/// Which junction at a point a track or net tie end is on. Horizon joins a
/// track's ends by junction, so a track on the top and one on the bottom that
/// end at one point, with no via there, are on junctions of their own: one
/// junction would join them where the copper doesn't. The model keeps a
/// track's ends as positions, with the junctions the file named
/// (`HorizontalSegment.fromJunctionID`), and these say which junction at a
/// point belongs to copper on which layer.
///
/// A via stands on one junction too (`HorizontalMarker.junctionID`), and
/// joins the copper on that junction alone: another net's junction can stand
/// at its point, and stays its own. A via that names no junction at its
/// point, as a copy does, joins every junction there.
extension HorizontalBoard {
    /// The junction `via` stands on: the one it names, while that junction is
    /// at the via's point. Nil for a via that names none there.
    func junctionID(of via: HorizontalMarker) -> String? {
        Self.junctionID(of: via, in: junctions)
    }

    static func junctionID(of via: HorizontalMarker, in junctions: [String: HorizontalPoint]) -> String? {
        guard let named = via.junctionID, let point = junctions[named],
              junctionPointKey(point) == junctionPointKey(via.position) else {
            return nil
        }
        return named
    }

    /// The copper layers each junction joins, by lowercased id: the layers of
    /// the tracks and net ties that name it.
    func junctionLayers() -> [String: Set<Int>] {
        var layers = [String: Set<Int>]()
        for segment in tracks + netTies {
            guard let layer = segment.layer else {
                continue
            }
            for id in [segment.fromJunctionID, segment.toJunctionID].compactMap({ $0 }) {
                layers[id.lowercased(), default: []].insert(layer)
            }
        }
        return layers
    }

    /// The copper layers each junction spans, by lowercased id, as Horizon's
    /// `update_junction_connections` gives a junction its layer range: the
    /// span of a via at its point, else lowest to highest layer of the tracks
    /// and net ties on it. Those are the ones naming it and, on a junction
    /// nothing names, those ending at its point naming none (the rule of
    /// `junctionIDs(at:joining:)`). A junction on no copper has no range.
    /// Horizon's range takes in board lines and arcs too; they carry no
    /// junction ids here, and no net.
    func junctionLayerRanges() -> [String: ClosedRange<Int>] {
        func widened(_ range: ClosedRange<Int>?, by layers: ClosedRange<Int>) -> ClosedRange<Int> {
            range.map { min($0.lowerBound, layers.lowerBound)...max($0.upperBound, layers.upperBound) } ?? layers
        }
        var ranges = [String: ClosedRange<Int>]()
        var unnamedEndLayers = [String: [Int]]()
        for segment in tracks + netTies {
            guard let layer = segment.layer else {
                continue
            }
            for (point, id) in [(segment.from, segment.fromJunctionID), (segment.to, segment.toJunctionID)] {
                if let id {
                    ranges[id.lowercased()] = widened(ranges[id.lowercased()], by: layer...layer)
                } else {
                    unnamedEndLayers[Self.junctionPointKey(point), default: []].append(layer)
                }
            }
        }
        let byPoint = junctionIDsByPoint()
        let named = Set(ranges.keys)
        for (key, layers) in unnamedEndLayers {
            for id in byPoint[key] ?? [] where !named.contains(id.lowercased()) {
                ranges[id.lowercased()] = widened(ranges[id.lowercased()], by: layers.min()!...layers.max()!)
            }
        }
        var viaSpans = [String: ClosedRange<Int>]()
        for via in vias {
            let listed = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
            let span = listed.isEmpty
                ? HorizontalBoardLayers.bottomCopper...HorizontalBoardLayers.topCopper
                : listed.min()!...listed.max()!
            // On its own junction; one that names none, on all at its point.
            for id in junctionID(of: via).map({ [$0] }) ?? byPoint[Self.junctionPointKey(via.position)] ?? [] {
                viaSpans[id.lowercased()] = widened(viaSpans[id.lowercased()], by: span)
            }
        }
        ranges.merge(viaSpans) { _, span in span }
        return ranges
    }

    /// The junction ids at each point (`junctionPointKey`), sorted, for many
    /// `junctionIDs(at:joining:)` lookups without a scan of every junction
    /// each.
    func junctionIDsByPoint() -> [String: [String]] {
        var byPoint = [String: [String]]()
        for (id, point) in junctions {
            byPoint[Self.junctionPointKey(point), default: []].append(id)
        }
        return byPoint.mapValues { $0.sorted() }
    }

    /// The junctions at `point` copper on `layer` can end on, by id: every one
    /// there when a via there reaches the layer, the via's own first; else
    /// those tracks on the layer name, then those nothing names; never one
    /// only copper on another layer is on, nor one only a via that doesn't
    /// reach the layer stands on. Every junction at the point when `layer` is
    /// nil. Which of them copper may be joined to is for its net to say
    /// (`BoardTrackRouting.mergeJunctions`).
    func junctionIDs(
        at point: HorizontalPoint,
        joining layer: Int?,
        layers: [String: Set<Int>]? = nil,
        byPoint: [String: [String]]? = nil,
        viasByPoint: [String: [HorizontalMarker]]? = nil
    ) -> [String] {
        let key = Self.junctionPointKey(point)
        let here = byPoint.map { $0[key] ?? [] }
            ?? junctions.filter { Self.junctionPointKey($0.value) == key }.map(\.key).sorted()
        guard let layer, !here.isEmpty else {
            return here
        }
        let viasHere = viasByPoint.map { $0[key] ?? [] } ?? vias.filter { Self.junctionPointKey($0.position) == key }
        let reaching = viasHere.filter { $0.spansCopperLayer(layer) }
        if !reaching.isEmpty {
            let own = Set(reaching.compactMap { junctionID(of: $0) })
            return here.filter(own.contains) + here.filter { !own.contains($0) }
        }
        let layers = layers ?? junctionLayers()
        let named = here.filter { layers[$0.lowercased()]?.contains(layer) == true }
        let onVias = Set(viasHere.compactMap { junctionID(of: $0) })
        let unnamed = here.filter { layers[$0.lowercased()] == nil && !onVias.contains($0) }
        return named + unnamed
    }

    /// What ends on junction `id`, which Horizon's delete takes with it: the
    /// tracks and net ties with an end naming it, or an end naming none at its
    /// point that the layer rule gives it (`junctionIDs(at:joining:)`), the
    /// lines and arcs with an end (or an arc's centre) at its point, and the
    /// vias standing on it, which are nothing without their junction: those
    /// that name it, and those at its point that name none.
    func refsEnding(onJunction id: String, layers: [String: Set<Int>]? = nil) -> [HorizontalSelectableRef] {
        let target = id.lowercased()
        guard let point = junctions.first(where: { $0.key.lowercased() == target })?.value else {
            return []
        }
        let layers = layers ?? junctionLayers()
        let key = Self.junctionPointKey(point)
        func endsOnIt(_ segment: HorizontalSegment) -> Bool {
            for (end, junction) in [(segment.from, segment.fromJunctionID), (segment.to, segment.toJunctionID)] {
                if let junction {
                    if junction.lowercased() == target { return true }
                } else if Self.junctionPointKey(end) == key,
                          junctionIDs(at: point, joining: segment.layer, layers: layers).contains(where: { $0.lowercased() == target }) {
                    return true
                }
            }
            return false
        }
        var refs = tracks.filter(endsOnIt).map { HorizontalSelectableRef(id: $0.id, type: .track) }
        refs += netTies.filter(endsOnIt).map { HorizontalSelectableRef(id: $0.id, type: .boardNetTie) }
        refs += lines
            .filter { Self.junctionPointKey($0.from) == key || Self.junctionPointKey($0.to) == key }
            .map { HorizontalSelectableRef(id: $0.id, type: .boardLine) }
        refs += arcs
            .filter { [$0.from, $0.to, $0.center].contains { Self.junctionPointKey($0) == key } }
            .map { HorizontalSelectableRef(id: $0.id, type: .boardArc) }
        refs += vias
            .filter { Self.junctionPointKey($0.position) == key && (junctionID(of: $0).map { $0.lowercased() == target } ?? true) }
            .map { HorizontalSelectableRef(id: $0.id, type: .via) }
        return refs
    }

    /// Points the track and net tie ends that name a junction in `folded`,
    /// and the vias that stand on one, at `kept` instead, as junctions at one
    /// point are folded into one.
    mutating func repointJunctionEnds(from folded: Set<String>, to kept: String) {
        let folded = Set(folded.map { $0.lowercased() })
        guard !folded.isEmpty else {
            return
        }
        func repoint(_ segments: inout [HorizontalSegment]) {
            for index in segments.indices {
                if let id = segments[index].fromJunctionID, folded.contains(id.lowercased()) {
                    segments[index].fromJunctionID = kept
                }
                if let id = segments[index].toJunctionID, folded.contains(id.lowercased()) {
                    segments[index].toJunctionID = kept
                }
            }
        }
        repoint(&tracks)
        repoint(&netTies)
        for index in vias.indices {
            if let id = vias[index].junctionID, folded.contains(id.lowercased()) {
                vias[index].junctionID = kept
            }
        }
    }

    static func junctionPointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }

    /// What holds the junctions of a board: which are kept, and which layers
    /// each takes its net from. The loader and the editor's connectivity pass
    /// both read it, so a board is on the same nets as it opens as after its
    /// next edit.
    struct JunctionHolds {
        /// The points (`junctionPointKey`) where something holds a junction
        /// by its position alone: a line, an arc, a track or net tie end
        /// that names no junction there, a via that names none.
        var heldByPosition = Set<String>()
        /// The junctions a track or net tie end names, or a via stands on,
        /// by lowercased id.
        var named = Set<String>()
        /// The layers of the tracks and net ties that name each junction,
        /// and those the via on it spans, by lowercased id.
        var layers = [String: Set<Int>]()

        /// The copper layers a junction takes its net from. A junction
        /// carries no layer, and a point can hold one a layer: where a bend
        /// of one net lies over a bend of another on another layer, each
        /// junction belongs to its own tracks. So one that only the tracks,
        /// net ties and via naming it hold takes the net of their layers. One
        /// that something holds by position joins whatever is at its point,
        /// and takes the net of every layer there, or none where they differ.
        func netLayers(of id: String, at point: HorizontalPoint, copperLayers: [Int]) -> [Int] {
            if heldByPosition.contains(HorizontalBoard.junctionPointKey(point)) {
                return copperLayers
            }
            return layers[id.lowercased()].map { Array($0) } ?? copperLayers
        }
    }

    /// `segments` are the tracks and net ties; `heldPoints` the places of
    /// what holds a junction without naming it: the ends of lines, and the
    /// ends and centres of arcs. A via holds the junction it stands on, on
    /// the layers it spans (all of `copperLayers` where it lists none), and
    /// one that names none holds its point.
    static func junctionHolds(
        junctions: [String: HorizontalPoint],
        segments: [HorizontalSegment],
        vias: [HorizontalMarker],
        copperLayers: [Int],
        heldPoints: [HorizontalPoint]
    ) -> JunctionHolds {
        var holds = JunctionHolds()
        let junctionKeys = Dictionary(
            junctions.map { ($0.key.lowercased(), junctionPointKey($0.value)) }, uniquingKeysWith: { first, _ in first })
        for segment in segments {
            for (point, id) in [(segment.from, segment.fromJunctionID), (segment.to, segment.toJunctionID)] {
                if let id, junctionKeys[id.lowercased()] == junctionPointKey(point) {
                    holds.named.insert(id.lowercased())
                } else {
                    holds.heldByPosition.insert(junctionPointKey(point))
                }
                if let id, let layer = segment.layer {
                    holds.layers[id.lowercased(), default: []].insert(layer)
                }
            }
        }
        for via in vias {
            guard let id = junctionID(of: via, in: junctions)?.lowercased() else {
                holds.heldByPosition.insert(junctionPointKey(via.position))
                continue
            }
            holds.named.insert(id)
            let listed = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
            holds.layers[id, default: []].formUnion(listed.isEmpty ? copperLayers : listed)
        }
        for point in heldPoints {
            holds.heldByPosition.insert(junctionPointKey(point))
        }
        return holds
    }
}

extension HorizontalMarker {
    /// Whether the via has copper on `layer`. One that lists no copper layers
    /// spans them all, as connectivity takes it.
    func spansCopperLayer(_ layer: Int) -> Bool {
        let listed = connectedLayers.filter(HorizontalBoardLayers.isCopper)
        return listed.isEmpty || listed.contains(layer)
    }
}
