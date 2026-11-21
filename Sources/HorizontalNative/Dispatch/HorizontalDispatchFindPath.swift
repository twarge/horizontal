import Foundation

/// find_path: one connection, searched for and not committed. A path comes
/// back as polylines per layer with the ops that would draw it; no path comes
/// back as the items in the way.
enum HorizontalDispatchFindPath {
    typealias Geometry = HorizontalDispatchBoardGeometry
    typealias Probe = HorizontalDispatchProbe
    static let nm = 1_000_000.0

    static func findPath(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        var probe = try Probe.probe(entry, params)
        let from = try Probe.anchor(params["from"], entry: entry, key: "from")
        guard let rawTargets = params["to"] as? [Any], !rawTargets.isEmpty else {
            throw HorizontalDispatchError.invalidParams("find_path needs \"to\": an array of one or more ends, any of which will do.")
        }
        let targets = try rawTargets.enumerated().map { try Probe.anchor($1, entry: entry, key: "to[\($0)]") }
        let net = try Probe.net(params, entry: entry) ?? from.netID ?? targets.lazy.compactMap(\.netID).first
        guard let net else {
            throw HorizontalDispatchError.invalidParams("Neither end names a net, so pass \"net\".")
        }
        for end in [from] + targets {
            if let other = end.netID, other != net {
                throw HorizontalDispatchError.invalidParams(
                    "\(end.label) is on \(board.netDetails[other]?.name ?? other), not \(board.netDetails[net]?.name ?? net).")
            }
        }
        let copper = probe.items.copperLayers
        let layers = try Geometry.layers(params, board: board) ?? from.layers ?? [HorizontalBoardLayers.topCopper]
        guard !layers.isEmpty, layers.allSatisfy(copper.contains) else {
            throw HorizontalDispatchError.invalidParams("layers names the copper layers the path may use (\(copper.map(String.init).joined(separator: ", "))).")
        }
        let ordered = copper.filter(layers.contains)
        let ruled = board.rules.trackWidth(net: net, layer: ordered[0])?.widths.def
        guard let width = params.double("width_mm").map({ $0 * nm }) ?? ruled, width > 0 else {
            throw HorizontalDispatchError.invalidParams("find_path needs \"width_mm\": no track_width rule gives this net one.")
        }

        var via: HorizontalViaShape?
        if let reference = params.string("via"), !reference.isEmpty {
            via = try HorizontalViaShape.resolve(definition: reference == "rules" ? nil : reference, diameter: nil, hole: nil, net: net, board: board)
            guard via != nil else {
                throw HorizontalDispatchError.invalidParams("via \"rules\" needs a via rule that gives this net a size; name a via definition instead.")
            }
        }
        for (index, raw) in (params["avoid"] as? [JSONDictionary] ?? []).enumerated() {
            guard let box = raw["box_mm"] as? [Any], box.count == 4 else {
                throw HorizontalDispatchError.invalidParams("avoid[\(index)] is {\"layer\"?, \"box_mm\": [min_x, min_y, max_x, max_y]}.")
            }
            let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4, numbers[0] <= numbers[2], numbers[1] <= numbers[3] else {
                throw HorizontalDispatchError.invalidParams("avoid[\(index)].box_mm is [min_x, min_y, max_x, max_y].")
            }
            probe.avoid.append(.init(layer: raw.int("layer"),
                                     box: HorizontalRect(points: [HorizontalPoint(x: numbers[0] * nm, y: numbers[1] * nm),
                                                                  HorizontalPoint(x: numbers[2] * nm, y: numbers[3] * nm)])))
        }

        var request = HorizontalPathSearch.Request(
            from: from.point, fromLayers: (from.layers ?? []).filter(ordered.contains),
            targets: targets.map { .init(point: $0.point, layers: ($0.layers ?? []).filter(ordered.contains)) },
            layers: ordered, width: width, net: net, via: via)
        request.viaInPad = params.bool("via_in_pad") ?? false
        if let window = params.double("window_mm") {
            guard window >= 0 else { throw HorizontalDispatchError.invalidParams("window_mm cannot be negative.") }
            request.window = window * nm
        }
        // A pitch the caller states is the one searched. Without one the
        // search takes the finest, from 25 µm up, at which the connection
        // spans no more than a search may, and says which: two ends 40 mm
        // apart are found at 50 or 100 µm where 25 would be refused.
        var coarsened: Double?
        if let grid = params.double("grid_mm") {
            guard grid >= 0.005 else { throw HorizontalDispatchError.invalidParams("grid_mm is at least 0.005.") }
            request.pitch = grid * nm
        } else {
            let fitted = HorizontalPathSearch.fittedPitch(for: request, coarsest: 200_000)
            if fitted != request.pitch { coarsened = fitted }
            request.pitch = fitted
        }
        // An end that can be reached on no layer the path may use.
        if let fromLayers = from.layers, request.fromLayers.isEmpty {
            throw HorizontalDispatchError.invalidParams(
                "\(from.label) is on layer \(fromLayers.map(String.init).joined(separator: ", ")), which layers leaves out.")
        }

        let started = Date()
        var search = HorizontalPathSearch(probe: probe, request: request)
        let outcome = search.run()
        var result: JSONDictionary = [
            "net": net, "net_name": board.netDetails[net]?.name as Any? as Any,
            "width_mm": HorizontalDispatchJSON.mm(width), "layers": ordered,
            "grid_mm": HorizontalDispatchJSON.mm(request.pitch), "margin_mm": HorizontalDispatchJSON.mm(probe.margin),
            "planes": "not obstacles: a pour gives way to new copper, so pour_planes after committing",
        ]
        if let coarsened {
            result["grid_note"] = "No grid_mm was given and the ends are far apart, so the search ran at \(HorizontalDispatchJSON.mm(coarsened)) mm rather than 0.025; pass grid_mm for a finer one, which finds tighter slots and takes longer."
        }
        func blockers(_ list: [HorizontalPathSearch.Blocker]) -> [JSONDictionary] {
            list.prefix(24).map { blocker -> JSONDictionary in
                var json = Probe.json(blocker.obstacle, probe: probe, board: board)
                json["on_layer"] = blocker.layer
                json["wall_mm"] = HorizontalDispatchJSON.mm(Double(blocker.cells) * request.pitch)
                return json
            }
        }
        switch outcome {
        case .tooLarge(let cells):
            throw HorizontalDispatchError.invalidParams(
                "That search spans \(cells) grid positions; at most \(request.maxCells). Use fewer layers or a smaller window_mm, leave grid_mm out for the finest pitch that fits (here \(HorizontalDispatchJSON.mm(HorizontalPathSearch.fittedPitch(for: request, coarsest: 1_000_000)))), or route it in stages through a via_site.")
        case .exhausted(let fromSide):
            result["found"] = false
            result["reason"] = "budget"
            result["blocked_by"] = ["from": blockers(fromSide), "to": [JSONDictionary]()] as JSONDictionary
            result["note"] = "The search ran out of budget before it could say there is no path; a coarser grid_mm or a smaller window_mm settles it, as does a way point: route to a via_site part of the way first."
                + keptOutOfPads(search)
        case .blocked(let fromSide, let toSide, let reachedWindowEdge):
            result["found"] = false
            result["reason"] = "blocked"
            result["blocked_by"] = ["from": blockers(fromSide), "to": blockers(toSide)] as JSONDictionary
            result["reached_window_edge"] = reachedWindowEdge
            result["note"] = "blocked_by lists what bounds the area reachable from each end, the longest stretch of wall first: what to move or rip up (ignore tries it), or to go round on another layer."
                + (reachedWindowEdge ? " The search reached the edge of its window, so a way round may lie beyond it: window_mm widens it." : "")
                + keptOutOfPads(search)
            if search.viasKeptOutOfPads > 0 { result["vias_kept_out_of_pads"] = search.viasKeptOutOfPads }
        case .found(let path):
            // Measured again on the copper as it would be drawn.
            var tightest: HorizontalBoardProbe.Measurement?
            var violations = [JSONDictionary]()
            for leg in path.legs where leg.points.count >= 2 {
                let candidate = HorizontalBoardProbe.track(leg.points, width: width, net: net)
                for measurement in probe.measurements(candidate, layer: leg.layer, reach: Probe.reportReach(probe)) {
                    if tightest == nil || measurement.slack < (tightest?.slack ?? 0) { tightest = measurement }
                    if probe.violates(measurement) { violations.append(Probe.json(measurement, probe: probe, board: board)) }
                }
            }
            if let via {
                for (index, point) in path.vias.enumerated() where !path.standing.contains(index) {
                    let candidate = HorizontalBoardProbe.via(at: point, diameter: via.diameter, net: net)
                    for layer in via.layers {
                        for measurement in probe.measurements(candidate, layer: layer, reach: Probe.reportReach(probe)) {
                            if tightest == nil || measurement.slack < (tightest?.slack ?? 0) { tightest = measurement }
                            if probe.violates(measurement) { violations.append(Probe.json(measurement, probe: probe, board: board)) }
                        }
                    }
                }
            }
            result["found"] = violations.isEmpty
            if !violations.isEmpty {
                result["reason"] = "unverified"
                result["violations"] = violations
            }
            result["reached"] = path.target
            result["path"] = path.legs.filter { $0.points.count >= 2 }
                .map { ["layer": $0.layer, "points_mm": $0.points.map(Geometry.xy)] as JSONDictionary }
            // The vias the ops place, and the net's own the path changes
            // layer through, which need none.
            result["vias"] = path.vias.indices.filter { !path.standing.contains($0) }.map { HorizontalDispatchJSON.point(path.vias[$0]) }
            let through = path.standing.sorted().map { HorizontalDispatchJSON.point(path.vias[$0]) }
            if !through.isEmpty { result["through_vias"] = through }
            result["length_mm"] = HorizontalDispatchJSON.mm(path.length)
            result["bends"] = path.bends
            if let tightest { result["tightest"] = Probe.json(tightest, probe: probe, board: board) }
            result["ops"] = ops(path, from: from, to: targets[path.target], width: width, net: net, via: via, board: board)
        }
        result["search_ms"] = Int((Date().timeIntervalSince(started) * 1000).rounded())
        return result
    }

    /// What to say of a search that found nothing and passed over places a
    /// via fitted because they were in a pad of the net.
    private static func keptOutOfPads(_ search: HorizontalPathSearch) -> String {
        search.viasKeptOutOfPads > 0
            ? " No via was tried in a pad of the net, though one fitted: via_in_pad allows that, for a board made with filled vias."
            : ""
    }

    /// The ops that draw a path: its segments in order, each layer change a
    /// via placed before the tracks that leave it. The via holds no net of
    /// its own (`net_pinned` false): its tracks give it theirs, as Horizon's
    /// router leaves the vias it drops.
    static func ops(_ path: HorizontalPathSearch.Path, from: Probe.Anchor, to: Probe.Anchor, width: Double, net: String,
                    via: HorizontalViaShape?, board: HorizontalBoard) -> [JSONDictionary] {
        let name = board.netDetails[net]?.name ?? ""
        let netReference = name.isEmpty ? net : name
        var ops = [JSONDictionary]()
        for (legIndex, leg) in path.legs.enumerated() {
            if legIndex > 0, let via, legIndex - 1 < path.vias.count, !path.standing.contains(legIndex - 1) {
                let at = path.vias[legIndex - 1]
                var op: JSONDictionary = ["op": "place_via", "x_mm": HorizontalDispatchJSON.mm(at.x), "y_mm": HorizontalDispatchJSON.mm(at.y),
                                          "net": netReference, "net_pinned": false]
                if let definition = via.definition {
                    op["definition"] = definition
                } else if via.source == "local" {
                    op["diameter_mm"] = HorizontalDispatchJSON.mm(via.diameter)
                    op["hole_mm"] = HorizontalDispatchJSON.mm(via.hole)
                }
                ops.append(op)
            }
            guard leg.points.count >= 2 else { continue }
            for index in leg.points.indices.dropLast() {
                let first = legIndex == 0 && index == 0
                let last = legIndex == path.legs.count - 1 && index == leg.points.count - 2
                ops.append(["op": "place_track",
                            "from": first ? from.end : HorizontalDispatchJSON.point(leg.points[index]),
                            "to": last ? to.end : HorizontalDispatchJSON.point(leg.points[index + 1]),
                            "layer": leg.layer, "width_mm": HorizontalDispatchJSON.mm(width), "net": netReference])
            }
        }
        return ops
    }
}
