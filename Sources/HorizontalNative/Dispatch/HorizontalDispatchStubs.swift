import Foundation

/// find_stubs: copper that goes nowhere. Dead-end runs of track with what
/// each end touches, vias joined on fewer than two layers, and tracks lying
/// wholly inside one pad.
///
/// What an end touches is said twice over, by the netlist of junctions and by
/// the copper: a run whose free end is on no junction with anything else can
/// still lie in a pad or across a track of its net, and is then carrying
/// current. Removing one of those for a stub breaks a connection.
enum HorizontalDispatchStubs {
    typealias Geometry = HorizontalDispatchBoardGeometry

    static func findStubs(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        let items = try Geometry.items(entry)
        let wanted = try params.string("net").flatMap { $0.isEmpty ? nil : $0 }.map { try Geometry.netID($0, entry: entry) }
        let region = try Geometry.region(params)
        let names = HorizontalBoardRulesCheck.padNames(board)
        func key(_ point: HorizontalPoint) -> String { "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))" }

        var padAt = [String: String]()
        for (path, point) in board.packagePadPositions { padAt[key(point)] = path.lowercased() }
        var viaAt = [String: HorizontalMarker]()
        for via in board.vias { viaAt[key(via.position)] = via }

        /// What a track's end is on: its junction, or the pad it is bound to.
        struct Node: Hashable { var id: String }
        func node(_ track: HorizontalSegment, _ first: Bool) -> Node {
            if let junction = first ? track.fromJunctionID : track.toJunctionID { return Node(id: "j:" + junction.lowercased()) }
            let point = first ? track.from : track.to
            if let pad = padAt[key(point)] { return Node(id: "p:" + pad) }
            return Node(id: "x:" + key(point) + ":\(track.layer ?? 0)")
        }
        var ends = [Node: [(track: Int, first: Bool)]]()
        var position = [Node: HorizontalPoint]()
        for (index, track) in board.tracks.enumerated() {
            for first in [true, false] {
                let at = node(track, first)
                ends[at, default: []].append((index, first))
                position[at] = first ? track.from : track.to
            }
        }
        func describe(_ at: Node, layer: Int?, excluding chain: Set<String>) -> JSONDictionary {
            let point = position[at] ?? .zero
            var json: JSONDictionary = HorizontalDispatchJSON.point(point)
            let count = ends[at]?.count ?? 0
            if at.id.hasPrefix("p:") {
                let path = String(at.id.dropFirst(2))
                json["touches"] = "pad"
                json["pad"] = names[path] ?? path
            } else if let via = viaAt[key(point)] {
                json["touches"] = "via"
                json["via"] = via.id
            } else if count > 1 {
                json["touches"] = "junction"
                json["tracks"] = count
            } else {
                json["touches"] = "nothing"
            }
            // The copper the end lies in, whatever the junctions say.
            if json.string("touches") == "nothing", let layer {
                let here = HorizontalBoardItem.Shape.disc(point, radius: 0)
                var lying = [String]()
                for index in items.indices(overlapping: HorizontalRouteClearanceProbe.bounds([point], growth: 1)) {
                    let item = items.items[index]
                    guard item.isOn(layer), item.kind.isCopper, !chain.contains(item.id.lowercased()),
                          HorizontalShapeGap.between(here, item.shape, limit: 0) != nil else { continue }
                    lying.append(item.kind == .track ? "Track \(item.id)" : item.label)
                }
                if !lying.isEmpty {
                    json["lies_in"] = Array(Set(lying)).sorted()
                    json["touches"] = "copper it shares no junction with"
                }
            }
            return json
        }

        // Dead ends: an end alone on a plain junction. The run is walked on
        // through junctions of two tracks to where it branches, lands or ends.
        var chains = [JSONDictionary]()
        var walked = Set<Int>()
        for (start, list) in ends.sorted(by: { $0.key.id < $1.key.id }) {
            guard list.count == 1, !start.id.hasPrefix("p:"), viaAt[key(position[start] ?? .zero)] == nil else { continue }
            var tracks = [Int]()
            var at = start
            var next = list[0]
            while true {
                guard walked.insert(next.track).inserted else { break }
                tracks.append(next.track)
                at = node(board.tracks[next.track], !next.first)
                let others = (ends[at] ?? []).filter { $0.track != next.track }
                guard others.count == 1, !at.id.hasPrefix("p:"), viaAt[key(position[at] ?? .zero)] == nil else { break }
                next = others[0]
            }
            guard !tracks.isEmpty else { continue }
            let segments = tracks.map { board.tracks[$0] }
            let net = segments.first?.netID?.lowercased()
            if let wanted, net != wanted { continue }
            if let region, !segments.contains(where: { Geometry.reaches(.path($0.pathPoints, halfWidth: $0.width / 2), into: region) }) { continue }
            let ids = Set(segments.map { $0.id.lowercased() })
            let layer = segments.first?.layer
            let free = describe(start, layer: layer, excluding: ids)
            let far = describe(at, layer: segments.last?.layer, excluding: ids)
            let live = free["lies_in"] != nil
            chains.append([
                "tracks": segments.map(\.id), "net": net as Any? as Any,
                "net_name": net.flatMap { board.netDetails[$0]?.name } as Any? as Any,
                "layers": Array(Set(segments.compactMap(\.layer))).sorted(by: >),
                "length_mm": HorizontalDispatchJSON.mm(segments.reduce(0) { $0 + HorizontalRoute45.length(of: $1.pathPoints) }),
                "ends": [free, far],
                "dead_end": !live,
                "note": live
                    ? "Its free end shares no junction with anything but lies in copper of the board: it may be carrying its net there. Check before removing it."
                    : (far.string("touches") == "nothing" ? "Both ends are free: it joins nothing." : "One end is free: a stub."),
            ])
        }

        // Vias that join fewer than two layers.
        var loneVias = [JSONDictionary]()
        for via in board.vias {
            let net = via.netID?.lowercased()
            if let wanted, net != wanted { continue }
            if let region, !Geometry.reaches(.disc(via.position, radius: via.size / 2), into: region) { continue }
            let here = HorizontalBoardItem.Shape.disc(via.position, radius: via.size / 2)
            var joined = Set<Int>()
            for index in items.indices(overlapping: HorizontalRouteClearanceProbe.bounds([via.position], growth: via.size / 2)) {
                let item = items.items[index]
                guard item.kind.isCopper, item.kind != .via, item.netID == net, net != nil,
                      HorizontalShapeGap.between(here, item.shape, limit: 0) != nil else { continue }
                joined.formUnion(via.copperLayers.filter(item.isOn))
            }
            guard joined.count < 2 else { continue }
            loneVias.append(["via": via.id, "net": net as Any? as Any, "net_name": net.flatMap { board.netDetails[$0]?.name } as Any? as Any,
                             "x_mm": HorizontalDispatchJSON.mm(via.position.x), "y_mm": HorizontalDispatchJSON.mm(via.position.y),
                             "layers": via.copperLayers.sorted(by: >), "joined_on": joined.sorted(by: >)])
        }

        // Tracks with both ends in one pad.
        var inPad = [JSONDictionary]()
        for track in board.tracks {
            guard let layer = track.layer else { continue }
            let net = track.netID?.lowercased()
            if let wanted, net != wanted { continue }
            if let region, !Geometry.reaches(.path(track.pathPoints, halfWidth: track.width / 2), into: region) { continue }
            for index in items.indices(overlapping: HorizontalRouteClearanceProbe.bounds([track.from, track.to], growth: 1)) {
                let item = items.items[index]
                guard item.kind == .pad || item.kind == .padThroughHole, item.isOn(layer),
                      item.shape.encloses(track.from), item.shape.encloses(track.to) else { continue }
                inPad.append(["track": track.id, "pad": item.label, "pad_id": item.id, "layer": layer,
                              "length_mm": HorizontalDispatchJSON.mm(HorizontalRoute45.length(of: track.pathPoints))])
                break
            }
        }

        let limit = min(max(params.int("limit") ?? 200, 1), 5000)
        func capped(_ list: [JSONDictionary]) -> [JSONDictionary] { Array(list.prefix(limit)) }
        return [
            "stubs": capped(chains), "stub_count": chains.count,
            "vias_on_one_layer": capped(loneVias), "via_count": loneVias.count,
            "tracks_in_a_pad": capped(inPad), "in_pad_count": inPad.count,
            "truncated": max(chains.count, loneVias.count, inPad.count) > limit,
            "note": "A stub is a run of track with an end on nothing; ends says what each end touches, by junction and by the copper it lies in. A via is listed when copper of its net meets it on fewer than two of its layers, fills as last poured included.",
        ] as JSONDictionary
    }
}
