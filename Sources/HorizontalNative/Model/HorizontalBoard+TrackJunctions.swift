import Foundation

/// Which junction at a point a track or net tie end is on. Horizon joins a
/// track's ends by junction, so a track on the top and one on the bottom that
/// end at one point, with no via there, are on junctions of their own: one
/// junction would join them where the copper doesn't. The model keeps a
/// track's ends as positions, with the junctions the file named
/// (`HorizontalSegment.fromJunctionID`), and these say which junction at a
/// point belongs to copper on which layer.
extension HorizontalBoard {
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

    /// The junctions at `point` copper on `layer` can end on, by id: every one
    /// there when a via there reaches the layer; else those tracks on the
    /// layer name, then those nothing names; never one only copper on another
    /// layer is on. Every junction at the point when `layer` is nil.
    func junctionIDs(
        at point: HorizontalPoint,
        joining layer: Int?,
        layers: [String: Set<Int>]? = nil
    ) -> [String] {
        let key = Self.junctionPointKey(point)
        let here = junctions.filter { Self.junctionPointKey($0.value) == key }.map(\.key).sorted()
        guard let layer, !here.isEmpty else {
            return here
        }
        if vias.contains(where: { Self.junctionPointKey($0.position) == key && $0.spansCopperLayer(layer) }) {
            return here
        }
        let layers = layers ?? junctionLayers()
        let named = here.filter { layers[$0.lowercased()]?.contains(layer) == true }
        let unnamed = here.filter { layers[$0.lowercased()] == nil }
        return named + unnamed
    }

    /// Points the track and net tie ends that name a junction in `folded` at
    /// `kept` instead, as junctions at one point are folded into one.
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
    }

    static func junctionPointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
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
