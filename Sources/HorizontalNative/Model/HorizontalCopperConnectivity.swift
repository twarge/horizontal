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
