import Foundation

/// Draw Dimension's three clicks: the two points it measures between, then
/// where its line goes. From the second click the dimension is previewed
/// whole, its line following the cursor, and the third click sets how far
/// from the points it lies and on which side (`labelDistance`).
enum BoardDrawDimension {
    /// How far a dimension is drawn from its points when nothing says: Return
    /// with the cursor still on the line between them.
    static let defaultLabelDistance = 1_000_000.0
    static let labelSize = 1_500_000.0

    /// The points clicked so far that count: a click on the point before it
    /// adds nothing, so a double-click is one point.
    static func distinct(_ points: [HorizontalPoint], pointKey: (HorizontalPoint) -> String) -> [HorizontalPoint] {
        points.reduce(into: [HorizontalPoint]()) { result, point in
            if result.last.map({ pointKey($0) != pointKey(point) }) ?? true {
                result.append(point)
            }
        }
    }

    /// How far `offset` lies from the line through the two points, along the
    /// dimension's own normal: positive on the side a dimension is drawn on
    /// by default, negative on the other.
    static func labelDistance(from p0: HorizontalPoint, to p1: HorizontalPoint, through offset: HorizontalPoint) -> Double {
        let normal = HorizontalDimension(id: "", p0: p0, p1: p1, labelDistance: 0, labelSize: labelSize, mode: .distance)
            .measurementGeometry.normal
        let vector = offset - p0
        return (vector.x * normal.x + vector.y * normal.y).rounded()
    }

    /// The dimension between the first two of `points`, its line through
    /// the third, or through `cursor` where there is no third yet. With
    /// neither, or with that point on the line between the two, it is drawn
    /// the default distance away. Nil until there are two points apart.
    static func dimension(
        id: String,
        points: [HorizontalPoint],
        cursor: HorizontalPoint?,
        pointKey: (HorizontalPoint) -> String
    ) -> HorizontalDimension? {
        let points = distinct(points, pointKey: pointKey)
        guard points.count >= 2 else {
            return nil
        }
        let p0 = points[0], p1 = points[1]
        var distance = defaultLabelDistance
        if let offset = points.count >= 3 ? points[2] : cursor {
            let measured = labelDistance(from: p0, to: p1, through: offset)
            if measured != 0 {
                distance = measured
            }
        }
        return HorizontalDimension(id: id, p0: p0, p1: p1, labelDistance: distance, labelSize: labelSize, mode: .distance)
    }

    /// Everything a dimension draws, as strokes, for the preview: its two
    /// extension lines, its line (parted round the label where the label
    /// fits between the arrows), its arrowheads and its label, as the board's
    /// scene draws a dimension.
    static func strokes(of dimension: HorizontalDimension) -> [(from: HorizontalPoint, to: HorizontalPoint)] {
        let geometry = dimension.measurementGeometry
        let vector = geometry.p1Projected - geometry.p0Projected
        let length = hypot(vector.x, vector.y)
        guard length > 0 else {
            return []
        }
        let direction = vector.normalized
        let normal = geometry.normal
        let sign = dimension.labelDistance >= 0 ? 1.0 : -1.0
        let q0 = geometry.p0Projected + normal * dimension.labelDistance
        let q1 = geometry.p1Projected + normal * dimension.labelDistance
        let extensionLength = dimension.labelDistance + sign * dimension.labelSize / 2
        var strokes: [(from: HorizontalPoint, to: HorizontalPoint)] = [
            (dimension.p0, geometry.p0Projected + normal * extensionLength),
            (dimension.p1, geometry.p1Projected + normal * extensionLength),
        ]

        let labelWidth = HorizontalOutlineTextRenderer.textWidth(dimension.label, font: .simplex, size: dimension.labelSize)
        if labelWidth + dimension.labelSize * 2 <= length {
            let center = q0 + vector * 0.5
            let gap = labelWidth / 2 + dimension.labelSize * 0.45
            strokes.append((q0, center - direction * gap))
            strokes.append((center + direction * gap, q1))
        } else {
            strokes.append((q0, q1))
        }

        let angle = atan2(direction.y, direction.x)
        func arrowhead(at origin: HorizontalPoint, pointing: Double) {
            func turned(_ point: HorizontalPoint) -> HorizontalPoint {
                HorizontalPoint(x: point.x * cos(angle) - point.y * sin(angle), y: point.x * sin(angle) + point.y * cos(angle))
            }
            let size = dimension.labelSize
            strokes.append((origin, origin + turned(HorizontalPoint(x: pointing * size, y: size / 2))))
            strokes.append((origin, origin + turned(HorizontalPoint(x: pointing * size, y: -size / 2))))
        }
        let inward = length > dimension.labelSize * 2 ? 1.0 : -1.0
        arrowhead(at: q0, pointing: inward)
        arrowhead(at: q1, pointing: -inward)

        if let label = dimension.labelText {
            strokes += HorizontalOutlineTextRenderer.outlineSegments(for: label).map { (from: $0.0, to: $0.1) }
        }
        return strokes
    }
}
