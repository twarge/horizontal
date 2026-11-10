import Foundation

/// The geometry of rounding off one polygon corner, as Horizon's
/// `ToolRoundOffVertex` does it: the corner becomes an arc tangent to both
/// of its edges. The arc starts on the edge to the previous vertex and ends
/// on the edge to the next, both `delta = r / tan(alpha)` from the corner,
/// and its centre lies `u = r / sin(alpha)` along the corner's bisector,
/// where `alpha` is half the angle between the edges.
///
/// A corner already rounded off can be rounded again, which Horizon refuses:
/// its arc is taken out and the corner its edges meet at put back, so the
/// radius can grow, shrink or go to zero, a sharp corner again.
struct HorizontalPolygonRounding: Equatable {
    /// The arc already on the corner, when it is one rounded off before:
    /// its radius and direction, and whether its end is the polygon's first
    /// vertex (the arc starting on the last), which a new arc keeps.
    struct Existing: Equatable {
        var radius: Double
        var reverse: Bool
        var endIsFirst: Bool
    }

    /// Below this radius (1 nm) there is no arc: the corner stays sharp.
    static let minimumRadius = 1.0

    /// The polygon with the corner sharp: the one given, or, for a corner
    /// rounded off before, the one with its arc taken out.
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
    var existing: Existing? = nil

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

    /// The rounding of a corner rounded off before: the arc starting at
    /// `start` runs from a straight edge to a straight edge, tangent to
    /// both, as rounding a corner leaves it, whichever way it runs. The
    /// corner is where the arc's two tangents meet. Nil for any other arc:
    /// one an arc runs into or out of, one not tangent to its edges, a half
    /// circle (its tangents never meet), or a corner that cannot be rounded.
    init?(roundedCornerOf polygon: HorizontalPolygon, arcStart start: Int) {
        let vertices = polygon.polygonVertices
        let count = vertices.count
        guard count >= 4, vertices.indices.contains(start), vertices[start].type == .arc else {
            return nil
        }
        let end = (start + 1) % count
        let previous = (start - 1 + count) % count
        guard vertices[previous].type != .arc, vertices[end].type != .arc else {
            return nil
        }
        let arcStart = vertices[start].position
        let arcEnd = vertices[end].position
        let center = vertices[start].arcCenter
        let radius = ((arcStart - center).length + (arcEnd - center).length) / 2
        guard radius >= Self.minimumRadius,
              let corner = Self.tangentIntersection(arcStart - center, at: arcStart, arcEnd - center, at: arcEnd) else {
            return nil
        }
        var sharp = vertices
        sharp[start].type = .line
        sharp[start].position = corner
        sharp.remove(at: end)
        var sharpPolygon = polygon
        sharpPolygon.polygonVertices = sharp
        guard var rounding = HorizontalPolygonRounding(polygon: sharpPolygon, vertexIndex: end == 0 ? start - 1 : start) else {
            return nil
        }
        let arcReverse = vertices[start].arcReverse
        rounding.existing = Existing(radius: radius, reverse: arcReverse, endIsFirst: end == 0)
        // The arc is the one rounding the corner gives at its radius: its
        // ends on the edges, not past the neighbouring vertices.
        let tolerance = 5 + radius * 1e-4
        let rebuilt = rounding.polygon(radius: radius, reverse: arcReverse).polygonVertices
        let rebuiltStart = rounding.vertexIndex(roundedAt: radius)
        guard radius <= rounding.maxRadius + tolerance,
              rebuilt.count == count,
              (rebuilt[rebuiltStart].position - arcStart).length <= tolerance,
              (rebuilt[rebuiltStart].arcCenter - center).length <= tolerance,
              (rebuilt[(rebuiltStart + 1) % count].position - arcEnd).length <= tolerance else {
            return nil
        }
        self = rounding
    }

    /// The rounding a vertex of a corner rounded off before belongs to: the
    /// arc's start, or its end.
    static func roundedCorner(of polygon: HorizontalPolygon, vertexIndex index: Int) -> HorizontalPolygonRounding? {
        let count = polygon.polygonVertices.count
        guard polygon.polygonVertices.indices.contains(index) else {
            return nil
        }
        return HorizontalPolygonRounding(roundedCornerOf: polygon, arcStart: index)
            ?? HorizontalPolygonRounding(roundedCornerOf: polygon, arcStart: (index - 1 + count) % count)
    }

    /// Where the tangent at `start` (a radius `startRadius` out from the
    /// centre) meets the tangent at `end`; nil when they are parallel.
    private static func tangentIntersection(
        _ startRadius: HorizontalPoint, at start: HorizontalPoint,
        _ endRadius: HorizontalPoint, at end: HorizontalPoint
    ) -> HorizontalPoint? {
        let startDirection = HorizontalPoint(x: -startRadius.y, y: startRadius.x)
        let endDirection = HorizontalPoint(x: -endRadius.y, y: endRadius.x)
        let denominator = startDirection.x * endDirection.y - startDirection.y * endDirection.x
        let scale = startDirection.length * endDirection.length
        guard scale > 0, abs(denominator) > 1e-9 * scale else {
            return nil
        }
        let offset = end - start
        let t = (offset.x * endDirection.y - offset.y * endDirection.x) / denominator
        return start + startDirection * t
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
    /// becomes the arc's start and a new vertex after it its end, on whole
    /// nanometres as Horizon's `to_coordi` puts them. Below the minimum
    /// radius the corner is sharp: the original polygon.
    func polygon(radius: Double, reverse: Bool? = nil) -> HorizontalPolygon {
        let r = clamped(radius)
        guard r >= Self.minimumRadius else {
            return original
        }
        let delta = r / tan(halfAngle)
        let u = r / sin(halfAngle)
        var vertices = original.polygonVertices
        var start = vertices[vertexIndex]
        start.type = .arc
        start.position = Self.wholeNanometres(corner + towardPrevious * delta)
        start.arcCenter = Self.wholeNanometres(corner + bisector * u)
        start.arcReverse = reverse ?? self.reverse
        vertices[vertexIndex] = start
        vertices.insert(HorizontalPolygonVertex(position: Self.wholeNanometres(corner + towardNext * delta)), at: vertexIndex + 1)
        if existing?.endIsFirst == true {
            // The corner is the last vertex: its arc's end goes back first.
            vertices.insert(vertices.removeLast(), at: 0)
        }
        var polygon = original
        polygon.polygonVertices = vertices
        return polygon
    }

    /// Where `polygon(radius:)` puts the arc's start, or with no arc the
    /// corner.
    func vertexIndex(roundedAt radius: Double) -> Int {
        clamped(radius) >= Self.minimumRadius && existing?.endIsFirst == true ? vertexIndex + 1 : vertexIndex
    }

    private static func wholeNanometres(_ point: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(x: point.x.rounded(), y: point.y.rounded())
    }
}
