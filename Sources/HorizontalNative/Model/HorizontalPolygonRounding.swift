import Foundation

/// The geometry of rounding off one polygon corner, as Horizon's
/// `ToolRoundOffVertex` does it: the corner becomes an arc tangent to both
/// of its edges. The arc starts on the edge to the previous vertex and ends
/// on the edge to the next, both `delta = r / tan(alpha)` from the corner,
/// and its centre lies `u = r / sin(alpha)` along the corner's bisector,
/// where `alpha` is half the angle between the edges.
struct HorizontalPolygonRounding: Equatable {
    var original: HorizontalPolygon
    var vertexIndex: Int
    var corner: HorizontalPoint
    /// Unit vectors from the corner along its two edges and their bisector.
    var towardPrevious: HorizontalPoint
    var towardNext: HorizontalPoint
    var bisector: HorizontalPoint
    /// Half the angle between the two edges.
    var halfAngle: Double
    /// The radius at which the arc reaches the nearer neighbouring vertex.
    var maxRadius: Double
    /// Whether the arc runs clockwise, so it bulges toward the outside of
    /// the corner for either polygon winding.
    var reverse: Bool

    /// The rounding for the corner at `vertexIndex`, or nil when it cannot be
    /// rounded: fewer than three vertices, a vertex that already starts an
    /// arc or follows one, a zero-length edge, or collinear (or folded) edges.
    init?(polygon: HorizontalPolygon, vertexIndex index: Int) {
        let vertices = polygon.polygonVertices
        let count = vertices.count
        guard count >= 3, vertices.indices.contains(index) else {
            return nil
        }
        let previousIndex = (index - 1 + count) % count
        let nextIndex = (index + 1) % count
        guard vertices[index].type != .arc, vertices[previousIndex].type != .arc else {
            return nil
        }
        let corner = vertices[index].position
        let toNext = vertices[nextIndex].position - corner
        let toPrevious = vertices[previousIndex].position - corner
        guard toNext.length > 0, toPrevious.length > 0 else {
            return nil
        }
        let towardNext = toNext * (1 / toNext.length)
        let towardPrevious = toPrevious * (1 / toPrevious.length)
        let sum = towardNext + towardPrevious
        guard sum.length > 1e-9 else {
            return nil
        }
        let bisector = sum * (1 / sum.length)
        let cosine = bisector.x * towardPrevious.x + bisector.y * towardPrevious.y
        let halfAngle = acos(max(-1, min(1, cosine)))
        // Collinear edges have nothing to round; folded ones no room.
        guard halfAngle.isFinite, halfAngle > 1e-6, halfAngle <= 0.99 * (Double.pi / 2) else {
            return nil
        }
        self.original = polygon
        self.vertexIndex = index
        self.corner = corner
        self.towardPrevious = towardPrevious
        self.towardNext = towardNext
        self.bisector = bisector
        self.halfAngle = halfAngle
        self.maxRadius = tan(halfAngle) * min(toNext.length, toPrevious.length)
        self.reverse = (towardNext.x * towardPrevious.y - towardNext.y * towardPrevious.x) < 0
    }

    func clamped(_ radius: Double) -> Double {
        min(maxRadius, max(0, radius))
    }

    /// The radius whose arc centre is `cursor`'s projection onto the
    /// bisector, so dragging away from the corner grows the arc; zero on
    /// the far side of the corner.
    func radius(for cursor: HorizontalPoint) -> Double {
        let offset = cursor - corner
        let distance = offset.length
        guard distance > 0 else {
            return 0
        }
        let along = max(distance * ((bisector.x * offset.x + bisector.y * offset.y) / distance), 0)
        return clamped(along * sin(halfAngle))
    }

    /// The polygon with the corner rounded at `radius`: the corner vertex
    /// becomes the arc's start and a new vertex after it its end.
    func polygon(radius: Double, reverse: Bool? = nil) -> HorizontalPolygon {
        let r = clamped(radius)
        let delta = r / tan(halfAngle)
        let u = r / sin(halfAngle)
        var vertices = original.polygonVertices
        var start = vertices[vertexIndex]
        start.type = .arc
        start.position = corner + towardPrevious * delta
        start.arcCenter = corner + bisector * u
        start.arcReverse = reverse ?? self.reverse
        vertices[vertexIndex] = start
        vertices.insert(HorizontalPolygonVertex(position: corner + towardNext * delta), at: vertexIndex + 1)
        var polygon = original
        polygon.polygonVertices = vertices
        return polygon
    }
}
