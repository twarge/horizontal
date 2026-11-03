import Foundation

/// A dimension's parts, as Horizon gives a dimension three selectables (its
/// canvas render of a Dimension): the first point, vertex 0, the second,
/// vertex 1, and the label, vertex 2, a box round the label text whose origin
/// is where the dimension line starts. Horizon's move (ToolHelperMove) moves a
/// selected point; the label moves only across the dimension, by as much of
/// the move as runs that way, which changes its distance from the points. With
/// a point of the same dimension selected the label keeps its distance and
/// goes with the points.
enum BoardDimensionParts {
    static let start = 0
    static let end = 1
    static let label = 2

    /// The dimension's selectables: its label's, when it has a length and so
    /// a label, and its two points'.
    static func selectables(for dimension: HorizontalDimension) -> [HorizontalSelectable] {
        var result = [HorizontalSelectable]()
        if let anchor = labelAnchor(of: dimension), let text = dimension.labelText {
            var selectable = HorizontalSelectable.bounds(
                ref: ref(dimension, label),
                points: text.renderBoundsPoints,
                fallbackCenter: anchor,
                fallbackSize: dimension.labelSize
            )
            selectable.snapAnchors = [anchor]
            result.append(selectable)
        }
        result.append(.point(ref: ref(dimension, start), at: dimension.p0))
        result.append(.point(ref: ref(dimension, end), at: dimension.p1))
        return result
    }

    static func ref(_ dimension: HorizontalDimension, _ part: Int) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: dimension.id, type: .dimension, vertex: part)
    }

    /// Where the dimension line starts, the label's origin (Horizon's q0), or
    /// nil for a dimension that measures nothing and so draws no label.
    static func labelAnchor(of dimension: HorizontalDimension) -> HorizontalPoint? {
        let geometry = dimension.measurementGeometry
        guard (geometry.p1Projected - geometry.p0Projected).length > 0 else {
            return nil
        }
        return geometry.p0Projected + geometry.normal * dimension.labelDistance
    }

    /// The point `part` stands for: a point, or the label's origin.
    static func anchor(of dimension: HorizontalDimension, part: Int) -> HorizontalPoint? {
        switch part {
        case start: dimension.p0
        case end: dimension.p1
        default: labelAnchor(of: dimension)
        }
    }

    /// The parts of each dimension `refs` name, by normalized id.
    static func selectedParts(in refs: [HorizontalSelectableRef]) -> [String: Set<Int>] {
        refs.reduce(into: [String: Set<Int>]()) { result, ref in
            if ref.type == .dimension {
                result[HorizontalCanvasModeSupport.normalizedID(ref.id), default: []].insert(ref.vertex)
            }
        }
    }

    /// Whether moving `parts` shifts the dimension whole: both its points
    /// move, and the label keeps its distance from them.
    static func movesWhole(_ parts: Set<Int>) -> Bool {
        parts.contains(start) && parts.contains(end)
    }

    /// `dimension` with `parts` moved by `delta`.
    static func moved(_ dimension: HorizontalDimension, parts: Set<Int>, by delta: HorizontalPoint) -> HorizontalDimension {
        var moved = dimension
        if parts.contains(start) {
            moved.p0 = moved.p0 + delta
        }
        if parts.contains(end) {
            moved.p1 = moved.p1 + delta
        }
        if parts.contains(label), !parts.contains(start), !parts.contains(end) {
            // Horizon's Dimension::project: the move along the label's normal.
            let normal = dimension.measurementGeometry.normal
            moved.labelDistance += delta.x * normal.x + delta.y * normal.y
        }
        return moved
    }
}
