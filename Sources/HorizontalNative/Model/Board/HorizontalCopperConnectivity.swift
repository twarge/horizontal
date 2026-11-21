import Foundation

/// A layer-aware connectivity graph over board copper.
///
/// Both the loader and the post-edit recompute infer connections from GEOMETRY
/// — endpoints that land on the same coordinate — because by the time copper
/// reaches these models the file's own junction/pad *references* have been
/// resolved away to plain points.
///
/// Inference has to respect layers. Copper sharing an x/y but sitting on
/// different layers is connected only when something spans those layers: a via,
/// a via hole, or a pad present on both. Ignoring that merges electrically
/// separate nets into one component — and because a component carrying two nets
/// resolves to NO net rather than picking one, a single stray coincidence turns
/// every track in it unconnected. On a real board one bottom track ending on a
/// top pad's centre was enough to strand 51 tracks.
///
/// Horizon stores connections as references and never consults geometry, which
/// is why a file that renders correctly there can still show orange copper here.
struct HorizontalCopperConnectivity {
    /// One coordinate on one layer. Coordinates are rounded to the nanometre,
    /// matching how the loader and the draw tool place endpoints exactly on
    /// junctions, pad centres and vias.
    static func node(_ point: HorizontalPoint, layer: Int) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))|\(layer)"
    }

    private(set) var neighbors = [String: Set<String>]()

    mutating func connect(_ a: String, _ b: String) {
        guard a != b else { return }
        neighbors[a, default: []].insert(b)
        neighbors[b, default: []].insert(a)
    }

    /// Joins one physical object that exists on several layers at once — a via,
    /// a plated through-hole, or a pad with copper top and bottom. Every node is
    /// connected to every other, so the whole object is one component however
    /// the caller enumerated it.
    mutating func join(_ nodes: [String]) {
        guard nodes.count > 1 else { return }
        for (offset, node) in nodes.enumerated() {
            for other in nodes[(offset + 1)...] {
                connect(node, other)
            }
        }
    }

    /// Joins every layer in `layers` at one coordinate — the through-hole case,
    /// where the spanning object sits at a single point.
    mutating func join(_ layers: [Int], at point: HorizontalPoint) {
        join(layers.map { Self.node(point, layer: $0) })
    }

    /// Every node reachable from `start`, marking them visited.
    func component(from start: String, visited: inout Set<String>) -> [String] {
        var stack = [start]
        visited.insert(start)
        var found = [String]()
        while let node = stack.popLast() {
            found.append(node)
            for next in neighbors[node] ?? [] where !visited.contains(next) {
                visited.insert(next)
                stack.append(next)
            }
        }
        return found
    }
}

extension HorizontalCopperConnectivity {
    /// The copper that takes a node of its own, by the junction it is on.
    ///
    /// Copper is joined by where it is, and two tracks that end at one point
    /// on one layer are one piece of copper. Not where each ends on a
    /// junction of its own and the two are on different nets: a track end
    /// moved or routed onto another net's leaves both junctions standing
    /// (`BoardTrackRouting.mergeJunctions`), as Horizon's move does, and
    /// joined by their point alone the two nets were one net-less piece of
    /// copper, with nothing left to tell their ends apart when one was moved
    /// away again. So where the copper at a point on a layer is on more than
    /// one junction, each junction is a node of its own, and `join` puts
    /// back together those whose copper is on one net.
    ///
    /// A via and its hole are on the via's junction
    /// (`HorizontalBoard.junctionID(of:)`), as a track end is on the one it
    /// names. A via that names none at its point joins everything there on
    /// the layers it spans, as every via once did, and so does its hole.
    struct JunctionNodes {
        /// The junctions (lowercased ids) with a node of their own at each
        /// layer node.
        private var junctionsAt = [String: Set<String>]()
        /// The junction (lowercased id) each via at such a point stands on,
        /// by the via's lowercased id.
        private var viaJunctions = [String: String]()

        var isEmpty: Bool {
            junctionsAt.isEmpty
        }

        init() {}

        init(
            tracks: [HorizontalSegment],
            junctions: [String: HorizontalPoint],
            vias: [HorizontalMarker],
            viaHoles: [HorizontalHole],
            copperLayers: [Int]
        ) {
            // Only a point with more than one junction can hold two that
            // copper is on, and few points do: with none there is no more
            // to look at.
            var firstAt = [String: String]()
            var crowded = [String: String]()
            for (id, point) in junctions {
                let key = HorizontalBoard.junctionPointKey(point)
                if let first = firstAt[key] {
                    crowded[first] = key
                    crowded[id.lowercased()] = key
                } else {
                    firstAt[key] = id.lowercased()
                }
            }
            guard !crowded.isEmpty else {
                return
            }
            var named = [String: Set<String>]()
            for track in tracks {
                guard let layer = track.layer else {
                    continue
                }
                for (point, id) in [(track.from, track.fromJunctionID), (track.to, track.toJunctionID)] {
                    guard let id = id?.lowercased(), let key = crowded[id], key == HorizontalBoard.junctionPointKey(point) else {
                        continue
                    }
                    named[HorizontalCopperConnectivity.node(point, layer: layer), default: []].insert(id)
                }
            }
            // A via names its junction on the layers it spans, and its hole
            // on every layer, as the hole joins them. One at a crowded point
            // that names none there joins all that is at the point.
            var joinsAll = Set<String>()
            let crowdedPoints = Set(crowded.values)
            for via in vias {
                let key = HorizontalBoard.junctionPointKey(via.position)
                guard crowdedPoints.contains(key) else {
                    continue
                }
                let listed = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
                let spanned = listed.isEmpty ? copperLayers : listed
                if let junction = HorizontalBoard.junctionID(of: via, in: junctions)?.lowercased() {
                    viaJunctions[via.id.lowercased()] = junction
                    for layer in spanned {
                        named[HorizontalCopperConnectivity.node(via.position, layer: layer), default: []].insert(junction)
                    }
                } else {
                    for layer in spanned {
                        joinsAll.insert(HorizontalCopperConnectivity.node(via.position, layer: layer))
                    }
                }
            }
            for hole in viaHoles where crowdedPoints.contains(HorizontalBoard.junctionPointKey(hole.position)) {
                let junction = HorizontalBoard.viaID(ofViaHole: hole.id).flatMap { viaJunctions[$0.lowercased()] }
                for layer in copperLayers {
                    let node = HorizontalCopperConnectivity.node(hole.position, layer: layer)
                    if let junction {
                        named[node, default: []].insert(junction)
                    } else {
                        joinsAll.insert(node)
                    }
                }
            }
            junctionsAt = named.filter { $0.value.count > 1 && !joinsAll.contains($0.key) }
        }

        /// The node of copper at `point` on `layer` that ends on `junction`:
        /// the junction's own where it has one, else the point's.
        func node(_ point: HorizontalPoint, layer: Int, junction: String?) -> String {
            let node = HorizontalCopperConnectivity.node(point, layer: layer)
            guard !junctionsAt.isEmpty, let junction = junction?.lowercased(),
                  junctionsAt[node]?.contains(junction) == true else {
                return node
            }
            return node + "|" + junction
        }

        /// The node `via` is on on `layer`: its junction's.
        func node(of via: HorizontalMarker, layer: Int) -> String {
            guard !junctionsAt.isEmpty else {
                return HorizontalCopperConnectivity.node(via.position, layer: layer)
            }
            return node(via.position, layer: layer, junction: viaJunctions[via.id.lowercased()])
        }

        /// The node the hole of a via is on on `layer`: its via's.
        func node(ofViaHole hole: HorizontalHole, layer: Int) -> String {
            guard !junctionsAt.isEmpty else {
                return HorizontalCopperConnectivity.node(hole.position, layer: layer)
            }
            let junction = HorizontalBoard.viaID(ofViaHole: hole.id).flatMap { viaJunctions[$0.lowercased()] }
            return node(hole.position, layer: layer, junction: junction)
        }

        /// The nodes at each point that has junctions' own, in order: the
        /// point's node, then each junction's.
        fileprivate var places: [[String]] {
            junctionsAt.keys.sorted().map { node in
                [node] + (junctionsAt[node] ?? []).sorted().map { node + "|" + $0 }
            }
        }
    }

    /// Joins the nodes `junctions` set apart at each point where the copper
    /// on them is on one net, or on none, as copper at one point always was.
    /// Where it is on more than one, only the nodes on the same net are
    /// joined: each net's copper stays its own, and copper on no net stays
    /// off them all. `seeds` are the nets each node brings.
    ///
    /// Nothing is joined that a point alone would not join, and copper is
    /// kept apart only where two nets would meet, so a board with no such
    /// point comes out as it did.
    mutating func join(_ junctions: JunctionNodes, seeds: [String: Set<String>]) {
        let places = junctions.places
        guard !places.isEmpty else {
            return
        }
        // The piece of copper each node at a place is part of, and the nets
        // of each piece, kept as pieces are joined.
        var piece = [String: Int]()
        var nets = [Set<String>]()
        var parent = [Int]()
        for place in places {
            for start in place where piece[start] == nil {
                let index = nets.count
                var found = Set<String>()
                var stack = [start]
                piece[start] = index
                while let node = stack.popLast() {
                    for net in seeds[node] ?? [] {
                        found.insert(net.lowercased())
                    }
                    for next in neighbors[node] ?? [] where piece[next] == nil {
                        piece[next] = index
                        stack.append(next)
                    }
                }
                nets.append(found)
                parent.append(index)
            }
        }
        func root(_ index: Int, _ parent: [Int]) -> Int {
            var index = index
            while parent[index] != index {
                index = parent[index]
            }
            return index
        }
        for place in places {
            // One node of each piece here.
            var pieces = [(root: Int, node: String)]()
            for node in place {
                guard let index = piece[node] else {
                    continue
                }
                let found = root(index, parent)
                if !pieces.contains(where: { $0.root == found }) {
                    pieces.append((found, node))
                }
            }
            let netsHere = pieces.reduce(into: Set<String>()) { $0.formUnion(nets[$1.root]) }
            var joinedTo = [String: (root: Int, node: String)]()
            for next in pieces {
                // On one net or none, the place is one piece; on several, a
                // piece joins those on its own net alone.
                let key: String
                if netsHere.count <= 1 {
                    key = ""
                } else if nets[next.root].count == 1, let net = nets[next.root].first {
                    key = net
                } else {
                    continue
                }
                guard let first = joinedTo[key] else {
                    joinedTo[key] = next
                    continue
                }
                connect(first.node, next.node)
                parent[next.root] = first.root
                nets[first.root].formUnion(nets[next.root])
            }
        }
    }
}
