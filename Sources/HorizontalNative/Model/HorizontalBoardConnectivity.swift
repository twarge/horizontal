import Foundation

/// Recomputes board net connectivity by propagating nets outward from PADS
/// across electrically-connected copper.
///
/// Pads and holes are the immutable net sources — a pad's net comes from the
/// schematic, so copper can only ever inherit, never assign. Every track, via,
/// via-hole and junction net is therefore reset and re-derived on each pass,
/// which is what makes the following true:
///  • copper that no longer reaches a pad becomes net-less (rendered orange);
///  • a freshly drawn track only takes a net when it actually connects to one
///  (no stray/selected net);
///  • breaking a track disconnects the orphaned copper.
///
/// The editor runs `recompute` after every board edit. Connections are
/// position-based (rounded-nm point keys) — matching how the loader and the draw
/// tool place track endpoints exactly on junctions / pad centers / vias — so the
/// pass is linear in the number of copper objects.
enum HorizontalBoardConnectivity {

    /// A copy of `board` with track / via / via-hole / junction nets re-derived
    /// from pad connectivity. Copper not reachable from a single pad net gets a
    /// nil net (unconnected, or a flagged short when two nets collide).
    /// The copper graph both passes walk: which pad nets seed which layer
    /// nodes, how copper joins the nodes, and which tracks, vias and via
    /// holes stand on each.
    private struct Graph {
        var seeds = [String: Set<String>]()
        var neighbors = [String: Set<String>]()
        var trackIdx = [String: [Int]]()
        var viaIdx = [String: [Int]]()
        var viaHoleIdx = [String: [Int]]()
        var allKeys = Set<String>()
        /// The pad ("package/pad") that seeds each node, for naming them.
        var padAtKey = [String: String]()
        var copperLayers = [Int]()
    }

    static func recompute(_ board: HorizontalBoard) -> HorizontalBoard {
        let built = graph(board)
        let seeds = built.seeds, neighbors = built.neighbors, allKeys = built.allKeys
        let trackIdx = built.trackIdx, viaIdx = built.viaIdx, viaHoleIdx = built.viaHoleIdx
        let copperLayers = built.copperLayers

        // --- Flood components; each gets its single pad net (else nil) --------
        var tracks = board.tracks
        var vias = board.vias
        var viaHoles = board.viaHoles
        var netForKey = [String: String]() // layer node -> resolved net
        var visited = Set<String>()

        for start in allKeys where !visited.contains(start) {
            let component = flood(from: start, graph: built, visited: &visited)

            // Exactly one pad net in the component → that net; zero or a
            // collision (a short between nets) → nil (unconnected/flagged).
            let distinct = Set(component.nets.map(normalizedID))
            let net = distinct.count == 1 ? component.nets.first : nil
            if let net {
                for k in component.keys { netForKey[k] = net }
            }
            for i in component.tracks { tracks[i].netID = net }
            // A net collision (nil component net) never un-pins a net_set via:
            // the surrounding copper goes nil/flagged, the pin stays.
            for i in component.vias { vias[i].netID = net ?? vias[i].netSetID }
            for i in component.viaHoles { viaHoles[i].netID = net }
        }

        // --- Vacuum: drop junctions no longer incident to any copper ----------
        // A junction exists to join objects, so it is kept only while a track,
        // board line, arc, via or net-tie still meets it. Deleting a track must
        // therefore remove the junctions it leaves orphaned, or the file
        // accumulates junctions that join nothing.
        var occupied = Set<String>()
        for t in tracks { occupied.insert(pointKey(t.from)); occupied.insert(pointKey(t.to)) }
        for v in vias { occupied.insert(pointKey(v.position)) }
        for l in board.lines { occupied.insert(pointKey(l.from)); occupied.insert(pointKey(l.to)) }
        // An arc references THREE junctions — its endpoints and its centre — so
        // the centre counts as occupied even though no copper passes through it.
        // Every junction an object references is kept, or a drawn or converted
        // arc loses its centre on the next recompute and cannot be written back.
        for a in board.arcs {
            occupied.insert(pointKey(a.from))
            occupied.insert(pointKey(a.to))
            occupied.insert(pointKey(a.center))
        }
        for nt in board.netTies { occupied.insert(pointKey(nt.from)); occupied.insert(pointKey(nt.to)) }

        var junctions = board.junctions
        var junctionNetIDs = board.junctionNetIDs
        for (id, point) in board.junctions {
            let key = pointKey(point)
            guard occupied.contains(key) else {
                junctions.removeValue(forKey: id)
                junctionNetIDs.removeValue(forKey: id)
                continue
            }
            // Net = its position's component net (cleared when unconnected).
            // A junction carries no layer, so it takes the net of the copper at
            // its coordinate — but only when every layer there agrees, since a
            // junction sitting where two nets cross on different layers belongs
            // to neither.
            let netsHere = Set(copperLayers.compactMap {
                netForKey[HorizontalCopperConnectivity.node(point, layer: $0)]
            })
            if netsHere.count == 1, let net = netsHere.first {
                junctionNetIDs[id] = net
            } else {
                junctionNetIDs.removeValue(forKey: id)
            }
        }

        var result = board
        result.tracks = tracks
        result.vias = vias
        result.viaHoles = viaHoles
        result.junctions = junctions
        result.junctionNetIDs = junctionNetIDs
        return result
    }

    /// Copper that joins pads of more than one net: what recompute leaves
    /// net-less and flags. A pin moved to another net with its tracks left on
    /// it makes one, and the netlist never knows.
    struct Short {
        var nets: Set<String>
        /// The pads it joins ("package/pad"), each with the net it brings.
        var pads: [String: String]
        var trackIDs: [String]
        var viaIDs: [String]
        /// Where one of its tracks starts, for finding it.
        var position: HorizontalPoint?
    }

    static func shorts(_ board: HorizontalBoard) -> [Short] {
        let built = graph(board)
        var visited = Set<String>()
        var found = [Short]()
        for start in built.allKeys.sorted() where !visited.contains(start) {
            let component = flood(from: start, graph: built, visited: &visited)
            let nets = Set(component.nets.map(normalizedID))
            guard nets.count > 1 else { continue }
            var pads = [String: String]()
            for key in component.keys {
                guard let pad = built.padAtKey[key], let net = built.seeds[key]?.first else { continue }
                pads[pad] = normalizedID(net)
            }
            let tracks = component.tracks.sorted()
            found.append(Short(nets: nets, pads: pads, trackIDs: tracks.map { board.tracks[$0].id },
                               viaIDs: component.vias.sorted().map { board.vias[$0].id },
                               position: tracks.first.map { board.tracks[$0].from }))
        }
        return found
    }

    private struct Component {
        var keys = [String]()
        var nets = Set<String>()
        var tracks = Set<Int>()
        var vias = Set<Int>()
        var viaHoles = Set<Int>()
    }

    private static func flood(from start: String, graph: Graph, visited: inout Set<String>) -> Component {
        var component = Component()
        var stack = [start]
        visited.insert(start)
        while let k = stack.popLast() {
            component.keys.append(k)
            component.nets.formUnion(graph.seeds[k] ?? [])
            for i in graph.trackIdx[k] ?? [] { component.tracks.insert(i) }
            for i in graph.viaIdx[k] ?? [] { component.vias.insert(i) }
            for i in graph.viaHoleIdx[k] ?? [] { component.viaHoles.insert(i) }
            for n in graph.neighbors[k] ?? [] where !visited.contains(n) {
                visited.insert(n)
                stack.append(n)
            }
        }
        return component
    }

    private static func graph(_ board: HorizontalBoard) -> Graph {
        // --- Pad / hole net seeds (the only immutable sources) ---------------
        // Keyed by LAYER NODE, not by bare coordinate: a pad seeds only the
        // layers it has copper on. See HorizontalCopperConnectivity for why
        // ignoring layers strands whole nets.
        //
        // Two coverages so both DRAWN endpoints (snapped to packagePadPositions
        // centers) and LOADED endpoints (pad-polygon centroids) match a seed.
        let copperLayers = boardCopperLayers(board)
        var seeds = [String: Set<String>]() // layer node -> distinct pad net ids
        func seed(_ point: HorizontalPoint, layer: Int, _ netID: String?) {
            guard let netID else { return }
            seeds[HorizontalCopperConnectivity.node(point, layer: layer), default: []].insert(netID)
        }
        /// Drill holes have no layer of their own; they reach every copper layer.
        func seedSpanning(_ point: HorizontalPoint, _ netID: String?) {
            for layer in copperLayers { seed(point, layer: layer, netID) }
        }

        var graph = HorizontalCopperConnectivity()
        var padNetByPath = [String: String]()
        var padLayersByPath = [String: Set<Int>]()
        var padNodesByPath = [String: [String]]()
        // Horizon attaches a track to a pad only through an explicit pad
        // reference; a junction sitting on the pad's centre is *not* one (it is
        // what Disconnect leaves behind, and what the writer emits when a
        // junction is there). So a pad whose centre carries a junction seeds
        // nothing: copper meeting it is detached, as it is on disk.
        let junctionKeys = Set(board.junctions.values.map(pointKey))
        var padAtKey = [String: String]()
        for pad in board.packagePads {
            guard let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) else { continue }
            let center = HorizontalRect(points: pad.renderVertices(arcPrecision: 24)).center
            guard !junctionKeys.contains(pointKey(center)) else { continue }
            seed(center, layer: layer, pad.netID)
            guard let path = padPath(forPolygonID: pad.id) else { continue }
            padAtKey[HorizontalCopperConnectivity.node(center, layer: layer)] = path
            if let net = pad.netID { padNetByPath[path] = net }
            padLayersByPath[path, default: []].insert(layer)
            // One physical pad is one electrical object across every layer its
            // copper reaches, however many shapes describe it.
            padNodesByPath[path, default: []]
                .append(HorizontalCopperConnectivity.node(center, layer: layer))
        }
        for (path, center) in board.packagePadPositions where !junctionKeys.contains(pointKey(center)) {
            let normalized = normalizedID(path)
            for layer in padLayersByPath[normalized] ?? [] {
                seed(center, layer: layer, padNetByPath[normalized])
                padNodesByPath[normalized, default: []]
                    .append(HorizontalCopperConnectivity.node(center, layer: layer))
            }
        }
        for hole in board.packageHoles {
            seedSpanning(hole.position, hole.netID)
        }
        // A via with a pinned net (Horizon `net_set` — plane-stitching vias,
        // and router-placed vias generally) is a net SOURCE like a pad: its
        // net must survive with no track path to a pad, and copper reaching
        // the via inherits it. Without this, any edit commit stripped the net
        // (and its display name) off every stitching via.
        for via in board.vias {
            guard let netSetID = via.netSetID else { continue }
            for layer in viaSpan(via, copperLayers: copperLayers) {
                seed(via.position, layer: layer, netSetID)
            }
        }

        // --- Connectivity graph over copper positions ------------------------
        var trackIdx = [String: [Int]]()
        var viaIdx = [String: [Int]]()
        var viaHoleIdx = [String: [Int]]()
        var allKeys = Set<String>(seeds.keys)

        for nodes in padNodesByPath.values {
            graph.join(nodes)
            allKeys.formUnion(nodes)
        }
        for (i, track) in board.tracks.enumerated() {
            // Data with no layer is treated as spanning rather than dropped.
            for layer in track.layer.map({ [$0] }) ?? copperLayers {
                let f = HorizontalCopperConnectivity.node(track.from, layer: layer)
                let t = HorizontalCopperConnectivity.node(track.to, layer: layer)
                graph.connect(f, t)
                trackIdx[f, default: []].append(i)
                trackIdx[t, default: []].append(i)
                allKeys.insert(f)
                allKeys.insert(t)
            }
        }
        // Vias and drill holes are what legitimately tie layers together at one
        // coordinate. A blind or buried via spans only its own layers, so use
        // them when present; an empty span means through-hole.
        for (i, via) in board.vias.enumerated() {
            let spanned = viaSpan(via, copperLayers: copperLayers)
            graph.join(spanned, at: via.position)
            for layer in spanned {
                let k = HorizontalCopperConnectivity.node(via.position, layer: layer)
                viaIdx[k, default: []].append(i)
                allKeys.insert(k)
            }
        }
        for (i, hole) in board.viaHoles.enumerated() {
            graph.join(copperLayers, at: hole.position)
            for layer in copperLayers {
                let k = HorizontalCopperConnectivity.node(hole.position, layer: layer)
                viaHoleIdx[k, default: []].append(i)
                allKeys.insert(k)
            }
        }
        var built = Graph()
        built.seeds = seeds
        built.neighbors = graph.neighbors
        built.trackIdx = trackIdx
        built.viaIdx = viaIdx
        built.viaHoleIdx = viaHoleIdx
        built.allKeys = allKeys
        built.padAtKey = padAtKey
        built.copperLayers = copperLayers
        return built
    }

    // MARK: - Helpers (kept local to match the loader's keying exactly)

    /// "{packageID}/pad/{padID}[/…]" → normalized "packageID/padID"; nil for
    /// non-pad polygons. Mirrors `BoardTrackRouting.padPath(forPolygonID:)`.
    private static func padPath(forPolygonID id: String) -> String? {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "pad" else { return nil }
        return normalizedID(parts[0]) + "/" + normalizedID(parts[2])
    }

    private static func normalizedID(_ id: String) -> String { id.lowercased() }

    /// The copper layers a via actually connects. Blind and buried vias list
    /// their span; an empty list means a plain through-hole via.
    private static func viaSpan(_ via: HorizontalMarker, copperLayers: [Int]) -> [Int] {
        let listed = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
        return listed.isEmpty ? copperLayers : listed
    }

    /// The copper layers this board uses. Top and bottom are always included
    /// because a via reaches them whether or not anything is routed there yet.
    private static func boardCopperLayers(_ board: HorizontalBoard) -> [Int] {
        var layers: Set<Int> = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
        for track in board.tracks {
            if let layer = track.layer, HorizontalBoardLayers.isCopper(layer) { layers.insert(layer) }
        }
        for pad in board.packagePads {
            if let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) { layers.insert(layer) }
        }
        for stackup in board.stackupLayers where HorizontalBoardLayers.isCopper(stackup.layer) {
            layers.insert(stackup.layer)
        }
        return layers.sorted()
    }

    private static func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }
}
