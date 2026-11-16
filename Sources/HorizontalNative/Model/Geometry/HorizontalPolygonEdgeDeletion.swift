import Foundation

/// What Delete selects after it takes a polygon's edge, so the next Delete
/// goes on along the outline: the edge that now joins the vertices either
/// side of the gap, which the two edges beside the deleted one became when
/// its two vertices went.
enum HorizontalPolygonEdgeDeletion {
    /// The new index of that edge, in a polygon of `count` vertices before
    /// edge `edge` (vertex `edge` to the next) was deleted; nil when the
    /// polygon is left with fewer than `minimumVertices` and goes, or the
    /// edge isn't one of its own.
    static func edgeIndex(afterDeleting edge: Int, vertexCount count: Int, minimumVertices: Int = 3) -> Int? {
        guard count >= 2, (0..<count).contains(edge) else {
            return nil
        }
        let removed = Set([edge, (edge + 1) % count])
        guard count - removed.count >= max(minimumVertices, 2) else {
            return nil
        }
        // The vertex before the gap starts the edge across it; the vertices
        // before it that went move it down.
        let before = (edge - 1 + count) % count
        return before - removed.filter { $0 < before }.count
    }
}

extension HorizontalPolygon {
    /// Deletes `parts` of this polygon, all of them at once: an arc centre
    /// makes its edge straight, an edge takes both its vertices and a vertex
    /// itself. The indices are all read against the polygon as it stood, so
    /// several edges selected together go as they were picked, where taking
    /// them one after another would shift the later ones onto other vertices.
    /// False when none of `parts` is one of its own.
    mutating func deleteParts(_ parts: [HorizontalSelectableRef]) -> Bool {
        var removed = Set<Int>()
        var changed = false
        for part in parts where polygonVertices.indices.contains(part.vertex) {
            switch part.type {
            case .polygonArcCenter:
                polygonVertices[part.vertex].type = .line
            case .polygonEdge:
                removed.insert(part.vertex)
                removed.insert(nextVertexIndex(after: part.vertex))
            case .polygonVertex:
                removed.insert(part.vertex)
            default:
                continue
            }
            changed = true
        }
        for index in removed.sorted(by: >) {
            polygonVertices.remove(at: index)
        }
        return changed
    }
}
