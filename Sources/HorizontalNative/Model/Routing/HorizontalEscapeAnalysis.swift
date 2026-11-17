import Foundation

/// Whether a set of nets can leave a region — the pad field of a BGA, say —
/// and which of them cannot share a layer, worked out before anything is
/// routed.
///
/// Four questions, each answered on the board's exact shapes:
///
///  * **Gates.** The gaps in the region's perimeter on each layer, and how
///    many tracks each takes (`HorizontalChannelCapacity`).
///  * **Reach.** Which gates each net's start can get to on each layer,
///    through whatever channels there are between the pads and vias inside.
///  * **Feasibility.** Whether every net can have a gate at once, the gates'
///    capacities allowing; if not, the nets and the too-few gates they share.
///  * **Crossings.** For nets with somewhere to go, whether two of them can
///    be on one layer: each is routed with the other already drawn, both
///    ways round. A pair that fails both ways on a layer must cross there.
///
/// The crossing test is evidence, not proof: the path the first net takes is
/// the search's shortest, and another might leave room. It has been right
/// where it mattered: two nets whose ends interleave round an obstacle.
struct HorizontalEscapeAnalysis {
    struct Net {
        /// Lowercased.
        var id: String
        var start: HorizontalPoint
        /// The layers it can leave on: its pad's, and a via's standing in it.
        var startLayers: [Int]
        var target: HorizontalPoint?
        /// Empty for any.
        var targetLayers: [Int] = []
    }

    struct Gate {
        var layer: Int
        /// "north", "east", "south" or "west".
        var side: String
        var gap: HorizontalChannelCapacity.Gap
    }

    struct Pair {
        var first: String
        var second: String
        /// Layers both have a path on alone and can be on together.
        var shared: [Int]
        /// Layers both have a path on alone and cannot.
        var crossing: [Int]
    }

    struct Result {
        var gates: [Gate] = []
        /// Net → the gates it reaches, as indices into `gates`.
        var reach: [String: [Int]] = [:]
        /// Net → its gate, when every net can have one.
        var assignment: [String: Int] = [:]
        /// The nets that cannot all get out, and the gates they have between them.
        var bottleneck: (nets: [String], gates: [Int], capacity: Int)?
        /// Net → the layers it has a path to its target on, alone.
        var alone: [String: [Int]] = [:]
        var pairs: [Pair] = []
        /// Net → a layer, no two that must cross on one; nil where the layers ran out.
        var layerAssignment: [String: Int?] = [:]
    }

    var board: HorizontalBoard
    var region: HorizontalRect
    var nets: [Net]
    var layers: [Int]
    var width: Double
    var margin = 0.0
    var pitch = 50_000.0
    /// How far beyond its ends' box a crossing test's search may go.
    var window = 2_000_000.0
    var ignored = Set<String>()

    private func probe(_ board: HorizontalBoard) -> HorizontalBoardProbe {
        var probe = HorizontalBoardProbe(board: board)
        probe.margin = margin
        probe.ignored = ignored
        return probe
    }

    func run() -> Result {
        var result = Result()
        let probe = probe(board)

        // Gates: each side of the region, cut on each layer.
        let corners = [HorizontalPoint(x: region.minX, y: region.minY), HorizontalPoint(x: region.maxX, y: region.minY),
                       HorizontalPoint(x: region.maxX, y: region.maxY), HorizontalPoint(x: region.minX, y: region.maxY)]
        let sides = [("south", corners[0], corners[1]), ("east", corners[1], corners[2]),
                     ("north", corners[3], corners[2]), ("west", corners[0], corners[3])]
        for layer in layers {
            for (name, from, to) in sides {
                for gap in HorizontalChannelCapacity.gaps(probe: probe, from: from, to: to, layer: layer, width: width, net: nil) {
                    result.gates.append(Gate(layer: layer, side: name, gap: gap))
                }
            }
        }

        // Reach: a flood from each net's start, layer by layer.
        let columns = max(Int(((region.maxX - region.minX) / pitch).rounded(.down)) + 1, 1)
        let rows = max(Int(((region.maxY - region.minY) / pitch).rounded(.down)) + 1, 1)
        func position(_ cell: Int) -> HorizontalPoint {
            HorizontalPoint(x: region.minX + Double(cell % columns) * pitch, y: region.minY + Double(cell / columns) * pitch)
        }
        let step = pitch * 2.squareRoot()
        for net in nets {
            var reached = Set<Int>()
            for layer in layers where net.startLayers.contains(layer) {
                var state = [UInt8](repeating: 0, count: columns * rows)
                func clear(_ cell: Int) -> Bool {
                    if state[cell] != 0 { return state[cell] == 1 }
                    let candidate = HorizontalBoardProbe.Candidate(kind: .track, netID: net.id, shape: .disc(position(cell), radius: width / 2))
                    let fits = probe.firstViolation(candidate, layer: layer) { step * step / (8 * (width / 2 + $0)) } == nil
                    state[cell] = fits ? 1 : 2
                    return fits
                }
                let column = min(max(Int(((net.start.x - region.minX) / pitch).rounded()), 0), columns - 1)
                let row = min(max(Int(((net.start.y - region.minY) / pitch).rounded()), 0), rows - 1)
                let start = row * columns + column
                guard clear(start) else { continue }
                var seen = Set([start])
                var pending = [start]
                while let cell = pending.popLast() {
                    let c = cell % columns, r = cell / columns
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nc = c + dx, nr = r + dy
                            guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                            let next = nr * columns + nc
                            if !seen.contains(next), clear(next) {
                                seen.insert(next)
                                pending.append(next)
                            }
                        }
                    }
                }
                // The cells on the region's edge say which gates it got to.
                for cell in seen {
                    let c = cell % columns, r = cell / columns
                    guard c == 0 || r == 0 || c == columns - 1 || r == rows - 1 else { continue }
                    let at = position(cell)
                    for (index, gate) in result.gates.enumerated() where gate.layer == layer && !reached.contains(index) {
                        if HorizontalRouteClearanceProbe.pointSegmentDistance(at, gate.gap.from, gate.gap.to) <= pitch * 1.01 {
                            reached.insert(index)
                        }
                    }
                }
            }
            result.reach[net.id] = reached.sorted()
        }

        // Feasibility: each net a gate, no gate more than it holds.
        var load = [Int](repeating: 0, count: result.gates.count)
        var holders = [[String]](repeating: [], count: result.gates.count)
        var gateOf = [String: Int]()
        func place(_ net: String, _ visited: inout Set<Int>) -> Bool {
            for gate in result.reach[net] ?? [] where !visited.contains(gate) {
                visited.insert(gate)
                if load[gate] < result.gates[gate].gap.tracks {
                    load[gate] += 1
                    holders[gate].append(net)
                    gateOf[net] = gate
                    return true
                }
                for other in holders[gate] where place(other, &visited) {
                    holders[gate].removeAll { $0 == other }
                    holders[gate].append(net)
                    gateOf[net] = gate
                    return true
                }
            }
            return false
        }
        var stuck: (net: String, visited: Set<Int>)?
        for net in nets {
            var visited = Set<Int>()
            if !place(net.id, &visited), stuck == nil { stuck = (net.id, visited) }
        }
        if let stuck {
            // The gates it tried and everything holding them: more nets than room.
            let gates = stuck.visited.sorted()
            let crowd = Set(gates.flatMap { holders[$0] }).union([stuck.net])
            result.bottleneck = (crowd.sorted(), gates, gates.reduce(0) { $0 + result.gates[$1].gap.tracks })
        } else {
            result.assignment = gateOf
        }

        // Crossings: nets with somewhere to go, alone and then in pairs.
        let bound = nets.filter { $0.target != nil }
        guard !bound.isEmpty else { return result }
        func path(_ net: Net, on layer: Int, in board: HorizontalBoard) -> HorizontalPathSearch.Path? {
            guard let target = net.target, net.startLayers.contains(layer),
                  net.targetLayers.isEmpty || net.targetLayers.contains(layer) else { return nil }
            var request = HorizontalPathSearch.Request(from: net.start, fromLayers: [layer], targets: [.init(point: target, layers: [])],
                                                       layers: [layer], width: width, net: net.id)
            request.pitch = pitch
            request.window = window
            var search = HorizontalPathSearch(probe: self.probe(board), request: request)
            if case .found(let path) = search.run() { return path }
            return nil
        }
        func drawn(_ path: HorizontalPathSearch.Path, net: String, on layer: Int) -> HorizontalBoard {
            var board = self.board
            for leg in path.legs {
                for index in leg.points.indices.dropLast() {
                    board.tracks.append(HorizontalSegment(id: "escape-analysis/\(net)/\(index)", from: leg.points[index], to: leg.points[index + 1],
                                                          width: width, layer: layer, netID: net))
                }
            }
            return board
        }
        var alone = [String: [Int: HorizontalPathSearch.Path]]()
        for net in bound {
            for layer in layers {
                if let found = path(net, on: layer, in: board) { alone[net.id, default: [:]][layer] = found }
            }
            result.alone[net.id] = layers.filter { alone[net.id]?[$0] != nil }
        }
        var crossing = Set<String>()   // "a|b|layer"
        for (index, a) in bound.enumerated() {
            for b in bound[(index + 1)...] {
                var shared = [Int](), blocked = [Int]()
                for layer in layers {
                    guard let pathA = alone[a.id]?[layer], let pathB = alone[b.id]?[layer] else { continue }
                    if path(b, on: layer, in: drawn(pathA, net: a.id, on: layer)) != nil
                        || path(a, on: layer, in: drawn(pathB, net: b.id, on: layer)) != nil {
                        shared.append(layer)
                    } else {
                        blocked.append(layer)
                        crossing.insert("\(a.id)|\(b.id)|\(layer)")
                    }
                }
                result.pairs.append(Pair(first: a.id, second: b.id, shared: shared, crossing: blocked))
            }
        }
        // A layer each, taking the first that holds no net it must cross.
        var onLayer = [Int: [String]]()
        for net in bound {
            let free = layers.first { layer in
                alone[net.id]?[layer] != nil && (onLayer[layer] ?? []).allSatisfy { other in
                    !crossing.contains("\(other)|\(net.id)|\(layer)") && !crossing.contains("\(net.id)|\(other)|\(layer)")
                }
            }
            result.layerAssignment[net.id] = free
            if let free { onLayer[free, default: []].append(net.id) }
        }
        return result
    }
}
