import Foundation

/// channel_capacity and escape_analysis: how much fits through a gap, and
/// whether a set of nets can leave a region and share a layer once out.
enum HorizontalDispatchChannels {
    typealias Geometry = HorizontalDispatchBoardGeometry
    typealias Probe = HorizontalDispatchProbe
    static let nm = 1_000_000.0

    private static func pair(_ value: Any?, _ name: String) throws -> HorizontalPoint {
        guard let list = value as? [Any], list.count == 2,
              let x = (list[0] as? NSNumber)?.doubleValue, let y = (list[1] as? NSNumber)?.doubleValue else {
            throw HorizontalDispatchError.invalidParams("\(name) is [x, y] in millimetres.")
        }
        return HorizontalPoint(x: x * nm, y: y * nm)
    }

    static func json(_ gap: HorizontalChannelCapacity.Gap, probe: HorizontalBoardProbe, board: HorizontalBoard) -> JSONDictionary {
        var json: JSONDictionary = [
            "from_mm": Geometry.xy(gap.from), "to_mm": Geometry.xy(gap.to),
            "centres_mm": HorizontalDispatchJSON.mm(gap.centres), "tracks": gap.tracks,
        ]
        json["bounded_by"] = [gap.before, gap.after].map { obstacle -> Any in
            obstacle.map { Probe.json($0, probe: probe, board: board) as Any } ?? NSNull()
        }
        return json
    }

    // MARK: - channel_capacity

    static func channelCapacity(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        let probe = try Probe.probe(entry, params)
        let net = try Probe.net(params, entry: entry)
        var from: HorizontalPoint, to: HorizontalPoint
        var shared: [Int]?
        if let cut = params.dictionary("cut") {
            from = try pair(cut["from_mm"], "cut.from_mm")
            to = try pair(cut["to_mm"], "cut.to_mm")
        } else if let between = params["between"] as? [String], between.count == 2 {
            // From the nearest point of one item's copper to the other's.
            func items(_ id: String) throws -> [HorizontalBoardItem] {
                let found = probe.items.items.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame }
                guard !found.isEmpty else { throw HorizontalDispatchError.notFound("No track, via, pad or hole \(id) on the board.") }
                return found
            }
            var best: HorizontalShapeGap?
            for a in try items(between[0]) {
                for b in try items(between[1]) where a.layerMin <= b.layerMax && b.layerMin <= a.layerMax {
                    guard let gap = HorizontalShapeGap.between(a.shape, b.shape) else { continue }
                    if best == nil || gap.distance < (best?.distance ?? 0) {
                        best = gap
                        shared = probe.items.copperLayers.filter { a.isOn($0) && b.isOn($0) }
                    }
                }
            }
            guard let best, best.distance > 0 else {
                throw HorizontalDispatchError.invalidParams("Those two share no layer, or touch: there is no gap between them to measure.")
            }
            (from, to) = (best.first, best.second)
        } else {
            throw HorizontalDispatchError.invalidParams(
                "channel_capacity needs \"cut\": {\"from_mm\": [x, y], \"to_mm\": [x, y]}, a line across the corridor, or \"between\": two item ids.")
        }
        guard hypot(to.x - from.x, to.y - from.y) > 0 else {
            throw HorizontalDispatchError.invalidParams("The cut needs two different ends.")
        }
        let layers = try Geometry.layers(params, board: board) ?? shared ?? probe.items.copperLayers
        guard let width = params.double("width_mm"), width > 0 else {
            throw HorizontalDispatchError.invalidParams("channel_capacity needs \"width_mm\": the width of the tracks to fit.")
        }
        let spacing = params.double("spacing_mm").map { $0 * nm }
        return [
            "cut": ["from_mm": Geometry.xy(from), "to_mm": Geometry.xy(to),
                    "length_mm": HorizontalDispatchJSON.mm(hypot(to.x - from.x, to.y - from.y))] as JSONDictionary,
            "width_mm": width, "margin_mm": HorizontalDispatchJSON.mm(probe.margin),
            "layers": layers.filter(probe.items.copperLayers.contains).map { layer -> JSONDictionary in
                let gaps = HorizontalChannelCapacity.gaps(probe: probe, from: from, to: to, layer: layer, width: width * nm, net: net,
                                                          spacing: spacing)
                return ["layer": layer, "tracks": gaps.reduce(0) { $0 + $1.tracks },
                        "gaps": gaps.map { json($0, probe: probe, board: board) }]
            },
            "note": "centres_mm is the stretch of the cut a track's centre may lie on; tracks is how many of that width fit side by side in it, each keeping the track to track clearance and the margin from the next.",
        ] as JSONDictionary
    }

    // MARK: - escape_analysis

    static func escapeAnalysis(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        let probe = try Probe.probe(entry, params)
        let copper = probe.items.copperLayers
        let layers = copper.filter((try Geometry.layers(params, board: board) ?? copper).contains)
        guard let width = params.double("width_mm"), width > 0 else {
            throw HorizontalDispatchError.invalidParams("escape_analysis needs \"width_mm\": the width of the tracks that leave.")
        }
        let targets = params.dictionary("targets") ?? [:]
        let starts = params.dictionary("starts") ?? [:]
        let named = params["nets"] as? [String]
        var via: HorizontalViaShape?
        if let reference = params.string("via"), !reference.isEmpty {
            via = try HorizontalViaShape.resolve(definition: reference == "rules" ? nil : reference, diameter: nil, hole: nil, net: nil, board: board)
        }

        var region: HorizontalRect
        var nets = [HorizontalEscapeAnalysis.Net]()
        var labels = [String: String]()   // net id → where it starts
        func name(_ net: String) -> String {
            let name = board.netDetails[net]?.name ?? ""
            return name.isEmpty ? net : name
        }
        func target(_ net: String) throws -> Probe.Anchor? {
            guard let key = targets.keys.first(where: { (try? Geometry.netID($0, entry: entry)) == net }) else { return nil }
            return try Probe.anchor(targets[key], entry: entry, key: "targets.\(key)")
        }

        if let reference = params.string("component"), !reference.isEmpty {
            let package = try Geometry.package(reference, entry: entry)
            let pads = Geometry.pads(of: board).filter { $0.package.id == package.id }
            guard !pads.isEmpty else { throw HorizontalDispatchError.notFound("\(package.label) has no pads on the board.") }
            let ring = (params.double("ring_mm") ?? 0.3) * nm
            region = HorizontalRouteClearanceProbe.bounds(pads.flatMap { [HorizontalPoint(x: $0.box.minX, y: $0.box.minY),
                                                                         HorizontalPoint(x: $0.box.maxX, y: $0.box.maxY)] }, growth: ring)
            var wanted: [String]
            if let named {
                wanted = try named.map { try Geometry.netID($0, entry: entry) }
            } else {
                // The nets of its pads that still have somewhere to go.
                let unrouted = Set(board.airwires.compactMap { $0.netID?.lowercased() })
                wanted = Array(Set(pads.compactMap(\.netID)).intersection(unrouted)).sorted { name($0) < name($1) }
                guard wanted.count <= 24 else {
                    throw HorizontalDispatchError.invalidParams(
                        "\(package.label) has \(wanted.count) nets with airwires; name up to 24 of them in \"nets\".")
                }
            }
            for net in wanted {
                guard let pad = pads.first(where: { $0.netID == net }),
                      let at = board.packagePadPositions["\(package.id.lowercased())/\(pad.padID)"] else {
                    throw HorizontalDispatchError.notFound("\(package.label) has no pad on \(name(net)).")
                }
                var own = Set<Int>()
                for polygon in pad.copper {
                    if let layer = polygon.layer { own.insert(layer) } else { own.formUnion(copper) }
                }
                // A via standing on the pad's centre takes it to its layers;
                // so would the via the request names, where it fits there.
                for placed in board.vias where placed.netID?.lowercased() == net && hypot(placed.position.x - at.x, placed.position.y - at.y) < 1 {
                    own.formUnion(placed.copperLayers)
                }
                if let via, !via.layers.allSatisfy(own.contains) {
                    let candidate = HorizontalBoardProbe.via(at: at, diameter: via.diameter, net: net)
                    if via.layers.allSatisfy({ probe.firstViolation(candidate, layer: $0) == nil }) { own.formUnion(via.layers) }
                }
                let end = try target(net)
                nets.append(.init(id: net, start: at, startLayers: layers.filter(own.contains), target: end?.point,
                                  targetLayers: (end?.layers ?? []).filter(layers.contains)))
                labels[net] = "\(package.label).\(pad.name)"
            }
        } else if let box = try Geometry.region(params) {
            region = box
            guard !starts.isEmpty else {
                throw HorizontalDispatchError.invalidParams("With \"region\", escape_analysis needs \"starts\": {net: where it enters or begins}.")
            }
            for (key, value) in starts.sorted(by: { $0.key < $1.key }) {
                let net = try Geometry.netID(key, entry: entry)
                let anchor = try Probe.anchor(value, entry: entry, key: "starts.\(key)")
                let end = try target(net)
                nets.append(.init(id: net, start: anchor.point, startLayers: (anchor.layers ?? layers).filter(layers.contains),
                                  target: end?.point, targetLayers: (end?.layers ?? []).filter(layers.contains)))
                labels[net] = anchor.label
            }
        } else {
            throw HorizontalDispatchError.invalidParams("escape_analysis needs \"component\", or \"region\" with \"starts\".")
        }
        guard !nets.isEmpty else { throw HorizontalDispatchError.invalidParams("There are no nets to analyse; name them in \"nets\".") }
        let bound = nets.filter { $0.target != nil }.count
        guard bound <= 10 else {
            throw HorizontalDispatchError.invalidParams("\(bound) nets have targets; the crossing test takes at most 10 a call.")
        }
        let pitch = (params.double("grid_mm") ?? 0.05) * nm
        guard pitch >= 5_000 else { throw HorizontalDispatchError.invalidParams("grid_mm is at least 0.005.") }
        let cells = (region.width / pitch) * (region.height / pitch) * Double(layers.count) * Double(nets.count)
        guard cells <= 6_000_000 else {
            throw HorizontalDispatchError.invalidParams(
                "That is \(Int(cells)) grid positions to flood; at most 6000000. Use a coarser grid_mm, fewer nets or fewer layers.")
        }

        var analysis = HorizontalEscapeAnalysis(board: board, region: region, nets: nets, layers: layers, width: width * nm)
        analysis.margin = probe.margin
        analysis.pitch = pitch
        analysis.ignored = probe.ignored
        if let window = params.double("window_mm") { analysis.window = window * nm }
        let result = analysis.run()

        func gateID(_ index: Int) -> String { "g\(index)" }
        var reply: JSONDictionary = [
            "region": Geometry.box(region), "layers": layers, "width_mm": width, "margin_mm": HorizontalDispatchJSON.mm(probe.margin),
            "gates": result.gates.enumerated().map { index, gate -> JSONDictionary in
                var json = json(gate.gap, probe: probe, board: board)
                json["gate"] = gateID(index)
                json["layer"] = gate.layer
                json["side"] = gate.side
                json["capacity"] = gate.gap.tracks
                return json
            },
            "reach": nets.map { net -> JSONDictionary in
                var byLayer = [String: [String]]()
                for index in result.reach[net.id] ?? [] {
                    byLayer[String(result.gates[index].layer), default: []].append(gateID(index))
                }
                return ["net": name(net.id), "net_id": net.id, "from": labels[net.id] ?? "", "start_layers": net.startLayers,
                        "gates": byLayer, "trapped": (result.reach[net.id] ?? []).isEmpty]
            },
        ]
        if let bottleneck = result.bottleneck {
            reply["feasible"] = false
            reply["bottleneck"] = ["nets": bottleneck.nets.map(name), "gates": bottleneck.gates.map(gateID), "capacity": bottleneck.capacity,
                                   "note": "These nets have only these gates between them, and the gates hold fewer tracks than there are nets."] as JSONDictionary
        } else {
            reply["feasible"] = true
            reply["assignment"] = Dictionary(uniqueKeysWithValues: result.assignment.map { (name($0.key), gateID($0.value)) })
        }
        if bound > 0 {
            reply["paths_alone"] = Dictionary(uniqueKeysWithValues: result.alone.map { (name($0.key), $0.value) })
            reply["cannot_share"] = result.pairs.filter { !$0.crossing.isEmpty }.map { pair -> JSONDictionary in
                ["nets": [name(pair.first), name(pair.second)], "layers": pair.crossing, "can_share": pair.shared]
            }
            reply["layer_assignment"] = Dictionary(uniqueKeysWithValues: result.layerAssignment.map { (name($0.key), $0.value.map { $0 as Any } ?? NSNull()) })
            reply["crossing_note"] = "cannot_share lists pairs that each have a path to their target on a layer alone and none with the other drawn first, either way round: evidence that they must cross there. layer_assignment gives each net the first layer that holds no net it must cross; null where the layers ran out."
        }
        reply["note"] = "Nothing was routed. A gate is a gap in the region's edge on a layer, with the tracks it holds; reach is the gates each net's start gets to through the channels inside, on the layers it can start on (its pad's, and a via's standing in the pad)."
        return reply
    }
}
