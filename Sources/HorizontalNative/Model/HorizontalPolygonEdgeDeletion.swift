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
