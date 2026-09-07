import Foundation

/// Finds enclosed faces in symbol artwork, including the line segments used
/// to render arcs. Pins and wires are deliberately absent from this input.
enum SchematicSymbolBackground {
    static func polygons(for lines: [HorizontalSegment]) -> [HorizontalPolygon] {
        var linesBySymbol: [String: [HorizontalSegment]] = [:]
        for line in lines {
            guard let symbolID = schematicMetalSymbolID(forGeometryID: line.id) else { continue }
            linesBySymbol[symbolID, default: []].append(line)
        }
        // Keep coincident/touching instances separate, and stabilize the retained
        // primitive order even when the source JSON dictionaries change order.
        return linesBySymbol.keys.sorted().flatMap { symbolID in
            contours(for: linesBySymbol[symbolID]!.sorted { $0.id < $1.id })
                .enumerated().map { index, vertices in
                    HorizontalPolygon(
                        id: "\(symbolID)/polygon/background/\(index)",
                        vertices: vertices,
                        layer: nil
                    )
                }
        }
    }

    private struct Edge: Hashable {
        var from: Int
        var to: Int
    }

    private static func contours(for lines: [HorizontalSegment]) -> [[HorizontalPoint]] {
        var points: [HorizontalPoint] = []
        var indexByPoint: [HorizontalPoint: Int] = [:]
        var neighbors: [Set<Int>] = []

        func node(for point: HorizontalPoint) -> Int {
            // World coordinates are nanometres. Snap only sub-nanometre arc /
            // placement rounding errors, so a visibly open outline stays open.
            let key = HorizontalPoint(x: point.x.rounded(), y: point.y.rounded())
            if let index = indexByPoint[key] { return index }
            let index = points.count
            indexByPoint[key] = index
            points.append(point)
            neighbors.append([])
            return index
        }

        for line in lines {
            guard line.from.x.isFinite, line.from.y.isFinite,
                  line.to.x.isFinite, line.to.y.isFinite else { continue }
            let from = node(for: line.from)
            let to = node(for: line.to)
            guard from != to else { continue }
            neighbors[from].insert(to)
            neighbors[to].insert(from)
        }

        // Remove open tails before walking faces. Otherwise an internal dangling
        // stroke would be visited twice and make the fill contour self-touching.
        var leaves = neighbors.indices.filter { neighbors[$0].count == 1 }
        while let leaf = leaves.popLast() {
            guard let next = neighbors[leaf].first, neighbors[leaf].count == 1 else { continue }
            neighbors[leaf].remove(next)
            neighbors[next].remove(leaf)
            if neighbors[next].count == 1 { leaves.append(next) }
        }

        let orderedNeighbors = neighbors.indices.map { node in
            neighbors[node].sorted { lhs, rhs in
                let a = points[lhs] - points[node]
                let b = points[rhs] - points[node]
                let angleA = atan2(a.y, a.x)
                let angleB = atan2(b.y, b.x)
                return angleA == angleB ? lhs < rhs : angleA < angleB
            }
        }
        var visited = Set<Edge>()
        var contours: [[HorizontalPoint]] = []
        for from in orderedNeighbors.indices {
            for to in orderedNeighbors[from] {
                let start = Edge(from: from, to: to)
                guard !visited.contains(start) else { continue }
                var edge = start
                var vertices: [Int] = []
                repeat {
                    guard visited.insert(edge).inserted else { break }
                    vertices.append(edge.from)
                    let onward = orderedNeighbors[edge.to]
                    guard let reverseIndex = onward.firstIndex(of: edge.from) else { break }
                    // Follow the face on the left of this directed edge.
                    let next = onward[(reverseIndex + onward.count - 1) % onward.count]
                    edge = Edge(from: edge.to, to: next)
                } while edge != start

                guard edge == start, vertices.count >= 3,
                      Set(vertices).count == vertices.count else { continue }
                let contour = vertices.map { points[$0] }
                // Translate before summing to retain precision far from origin.
                let origin = contour[0]
                let twiceArea = zip(contour, contour.dropFirst() + [origin]).reduce(0.0) { area, pair in
                    let a = pair.0 - origin
                    let b = pair.1 - origin
                    return area + a.x * b.y - b.x * a.y
                }
                // Bounded faces run counterclockwise. Discard the unbounded
                // exterior and degenerate paths instead of filling their bounds.
                if twiceArea > 1 { contours.append(contour) }
            }
        }
        return contours
    }
}
