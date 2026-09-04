import Foundation

// Identity for anything selectable on a canvas.
//
// Four coordinates are needed to name an object in a board or schematic, and
// they follow from the format's own object graph rather than from any choice:
// WHICH object (`id`, the stored UUID), of WHAT KIND (`type` — a pad and a
// track can share neither storage nor behaviour), WHICH SUB-PART (`vertex`, so
// a polygon corner or a line endpoint is addressable separately from the whole),
// and ON WHICH LAYER (`layer`, since one stored object can appear on several).
//
// The type list below is this project's own: it includes cases the reference
// has no equivalent for (`boardPanel`, `polygonArcCenter`, `polygonEdge`,
// `connectionLine`) and omits ones it does not model.

enum HorizontalObjectType: String, Hashable {
    case boardPackage
    case boardDecal
    case boardHole
    case boardArc
    case boardLine
    case boardNetTie
    case boardPanel
    case busLabel
    case busRipper
    case blockSymbolPort
    case connectionLine
    case dimension
    case junction
    case keepout
    case drawingArc
    case drawingLine
    case lineNet
    case netLabel
    case pad
    /// A padstack's own shape (circle / rectangle / obround) in the padstack
    /// editor.
    case padstackShape
    case plane
    case polygonArcCenter
    case polygonEdge
    case polygonVertex
    case powerSymbol
    case schematicBlockSymbol
    case schematicNetTie
    case schematicSymbol
    case symbolPin
    case text
    case track
    case via
}

struct HorizontalSelectableRef: Hashable {
    var id: String
    var type: HorizontalObjectType
    var vertex: Int = 0
    var layer: Int? = nil
}

extension HorizontalObjectType {
    var hasLineCenterHandle: Bool {
        switch self {
        case .lineNet, .drawingLine, .track, .boardNetTie, .boardLine, .connectionLine:
            return true
        default:
            return false
        }
    }
}

enum HorizontalSelectionTool: String, CaseIterable, Identifiable, Hashable {
    case box
    case lasso
    case paint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .box: "Box"
        case .lasso: "Lasso"
        case .paint: "Paint"
        }
    }
}

enum HorizontalSelectionQualifier: String, CaseIterable, Identifiable, Hashable {
    case auto
    case includeBox
    case includeOrigin
    case touchBox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .includeBox: "Include Box"
        case .includeOrigin: "Include Origin"
        case .touchBox: "Touch Box"
        }
    }
}

enum HorizontalSelectionModifierAction: String, CaseIterable, Identifiable, Hashable {
    case toggle
    case add
    case remove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: "Toggle"
        case .add: "Add"
        case .remove: "Remove"
        }
    }

    var clickAction: HorizontalSelectionClickAction {
        switch self {
        case .toggle: .toggle
        case .add: .add
        case .remove: .remove
        }
    }
}

struct HorizontalSelectionToolSettings: Equatable, Hashable {
    var tool: HorizontalSelectionTool = .box
    var qualifier: HorizontalSelectionQualifier = .includeOrigin
    var modifierAction: HorizontalSelectionModifierAction = .toggle
    var stickySelection = false
}

struct HorizontalSelectable: Hashable {
    static let minimumScreenSize = 20.0
    static let selectionOutlineScreenMargin: Float = 4.0
    private static let cornerExpansionWorld = 100.0

    var ref: HorizontalSelectableRef
    var center: HorizontalPoint
    var boxCenter: HorizontalPoint
    var boxSize: HorizontalPoint
    var angle: Double
    var handlePoints: [HorizontalPoint]

    init(
        ref: HorizontalSelectableRef,
        center: HorizontalPoint,
        boxCenter: HorizontalPoint,
        boxSize: HorizontalPoint,
        angle: Double = 0,
        handlePoints: [HorizontalPoint] = []
    ) {
        self.ref = ref
        self.center = center
        self.boxCenter = boxCenter
        self.boxSize = HorizontalPoint(x: abs(boxSize.x), y: abs(boxSize.y))
        self.angle = angle
        self.handlePoints = handlePoints
    }

    static func point(ref: HorizontalSelectableRef, at point: HorizontalPoint) -> HorizontalSelectable {
        HorizontalSelectable(ref: ref, center: point, boxCenter: point, boxSize: .zero, handlePoints: [point])
    }

    static func line(
        ref: HorizontalSelectableRef,
        from: HorizontalPoint,
        to: HorizontalPoint,
        width: Double,
        layer: Int? = nil
    ) -> HorizontalSelectable {
        let delta = to - from
        let length = delta.length
        let center = (from + to) * 0.5
        return HorizontalSelectable(
            ref: HorizontalSelectableRef(id: ref.id, type: ref.type, vertex: ref.vertex, layer: layer ?? ref.layer),
            center: center,
            boxCenter: center,
            boxSize: HorizontalPoint(x: length + max(width, 0), y: max(width, 0)),
            angle: atan2(delta.y, delta.x),
            handlePoints: [from, to]
        )
    }

    static func bounds(
        ref: HorizontalSelectableRef,
        points: [HorizontalPoint],
        fallbackCenter: HorizontalPoint,
        fallbackSize: Double
    ) -> HorizontalSelectable {
        let bounds = points.isEmpty
            ? HorizontalRect(center: fallbackCenter, size: fallbackSize)
            : HorizontalRect(points: points)
        return HorizontalSelectable(
            ref: ref,
            center: fallbackCenter,
            boxCenter: bounds.center,
            boxSize: HorizontalPoint(x: bounds.width, y: bounds.height),
            handlePoints: points
        )
    }

    func inside(_ point: HorizontalPoint, expand: Double = 0) -> Bool {
        let delta = point - boxCenter
        let rotation = -angle
        let dx = delta.x * cos(rotation) - delta.y * sin(rotation)
        let dy = delta.x * sin(rotation) + delta.y * cos(rotation)
        let halfWidth = max(boxSize.x, expand) / 2
        let halfHeight = max(boxSize.y, expand) / 2

        return dx >= -halfWidth && dx <= halfWidth && dy >= -halfHeight && dy <= halfHeight
    }

    /// Axis-aligned bounds of the (possibly rotated) selection box, with no
    /// corner expansion. Used to bucket selectables into the spatial index.
    var axisAlignedBounds: (min: HorizontalPoint, max: HorizontalPoint) {
        let halfWidth = boxSize.x / 2
        let halfHeight = boxSize.y / 2
        let c = abs(cos(angle))
        let s = abs(sin(angle))
        let extentX = halfWidth * c + halfHeight * s
        let extentY = halfWidth * s + halfHeight * c
        return (
            HorizontalPoint(x: boxCenter.x - extentX, y: boxCenter.y - extentY),
            HorizontalPoint(x: boxCenter.x + extentX, y: boxCenter.y + extentY)
        )
    }

    var area: Double {
        if boxSize.x == 0, boxSize.y == 0 {
            return 0
        }
        if boxSize.x == 0 {
            return boxSize.y
        }
        if boxSize.y == 0 {
            return boxSize.x
        }
        return boxSize.x * boxSize.y
    }

    var isPoint: Bool {
        boxSize.x == 0 && boxSize.y == 0
    }

    var isLine: Bool {
        (boxSize.x == 0) != (boxSize.y == 0)
    }

    func corners(expandedByWorld margin: Double = 0) -> [HorizontalPoint] {
        let width = boxSize.x + Self.cornerExpansionWorld + margin * 2
        let height = boxSize.y + Self.cornerExpansionWorld + margin * 2
        return [
            HorizontalPoint(x: -width, y: -height) * 0.5,
            HorizontalPoint(x: -width, y: height) * 0.5,
            HorizontalPoint(x: width, y: height) * 0.5,
            HorizontalPoint(x: width, y: -height) * 0.5
        ].map { corner in
            let rotated = HorizontalPoint(
                x: corner.x * cos(angle) - corner.y * sin(angle),
                y: corner.x * sin(angle) + corner.y * cos(angle)
            )
            return rotated + boxCenter
        }
    }

    var corners: [HorizontalPoint] {
        corners()
    }

    var snapPoints: [HorizontalPoint] {
        var points = handlePoints
        points.append(center)
        points.append(boxCenter)
        if !isPoint {
            points.append(contentsOf: corners)
        }
        return deduplicated(points)
    }

    private func deduplicated(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        var seen = Set<String>()
        var result = [HorizontalPoint]()
        for point in points where seen.insert(pointKey(point)).inserted {
            result.append(point)
        }
        return result
    }

    private func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }
}

enum HorizontalSelectableHitTest {
    private static let geometryEpsilon = 1e-6

    static func smallestSelectable(
        at point: HorizontalPoint,
        in selectables: [HorizontalSelectable],
        expand: Double
    ) -> HorizontalSelectableRef? {
        var selected: HorizontalSelectable?
        for selectable in selectables where selectable.inside(point, expand: expand) {
            if selected == nil || selectablePrecedes(selectable, selected!) {
                selected = selectable
            }
        }
        return selected?.ref
    }

    static func selectables(
        at point: HorizontalPoint,
        in selectables: [HorizontalSelectable],
        expand: Double
    ) -> [HorizontalSelectableRef] {
        let hits = selectables.filter { $0.inside(point, expand: expand) }
        let pointHits = hits.filter(\.isPoint)
        if pointHits.count == 1 {
            return pointHits.map(\.ref)
        }

        let lineHits = hits.filter(\.isLine)
        if lineHits.count == 1, pointHits.isEmpty {
            return lineHits.map(\.ref)
        }

        return hits.map(\.ref)
    }

    static func allSelectables(
        at point: HorizontalPoint,
        in selectables: [HorizontalSelectable],
        expand: Double
    ) -> [HorizontalSelectableRef] {
        selectables
            .filter { $0.inside(point, expand: expand) }
            .sorted(by: selectablePrecedes)
            .map(\.ref)
    }

    private static func selectablePrecedes(_ lhs: HorizontalSelectable, _ rhs: HorizontalSelectable) -> Bool {
        if abs(lhs.area - rhs.area) > geometryEpsilon {
            return lhs.area < rhs.area
        }

        let lhsPriority = priority(for: lhs.ref.type)
        let rhsPriority = priority(for: rhs.ref.type)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if lhs.ref.type.rawValue != rhs.ref.type.rawValue {
            return lhs.ref.type.rawValue < rhs.ref.type.rawValue
        }

        // Stable tie-break so the winner is deterministic regardless of iteration
        // order. Without this, two equally-"smallest" selectables resolve by
        // whatever order they're visited — which differs between a linear scan
        // and the spatial index, and makes selection nondeterministic on exact
        // overlaps. Ordering by id/layer/vertex makes it a total order.
        if lhs.ref.id != rhs.ref.id {
            return lhs.ref.id < rhs.ref.id
        }
        if lhs.ref.layer != rhs.ref.layer {
            return (lhs.ref.layer ?? Int.min) < (rhs.ref.layer ?? Int.min)
        }
        return lhs.ref.vertex < rhs.ref.vertex
    }

    private static func priority(for type: HorizontalObjectType) -> Int {
        switch type {
        case .polygonArcCenter, .polygonVertex:
            return 0
        case .polygonEdge:
            return 1
        default:
            return 10
        }
    }

    static func selectables(
        inBoxFrom start: HorizontalPoint,
        to end: HorizontalPoint,
        selectables: [HorizontalSelectable],
        qualifier requestedQualifier: HorizontalSelectionQualifier
    ) -> [HorizontalSelectableRef] {
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        let box = [
            HorizontalPoint(x: minX, y: minY),
            HorizontalPoint(x: maxX, y: minY),
            HorizontalPoint(x: maxX, y: maxY),
            HorizontalPoint(x: minX, y: maxY)
        ]
        let qualifier: HorizontalSelectionQualifier
        if requestedQualifier == .auto {
            qualifier = start.x < end.x ? .includeBox : .touchBox
        } else {
            qualifier = requestedQualifier
        }

        return selectables
            .filter { selectable in
                matches(selectable, polygon: box, qualifier: qualifier)
            }
            .map(\.ref)
    }

    static func selectables(
        inLasso path: [HorizontalPoint],
        selectables: [HorizontalSelectable],
        qualifier requestedQualifier: HorizontalSelectionQualifier
    ) -> [HorizontalSelectableRef] {
        guard path.count >= 3 else {
            return []
        }
        let qualifier = requestedQualifier == .auto ? HorizontalSelectionQualifier.includeOrigin : requestedQualifier
        return selectables
            .filter { selectable in
                matches(selectable, polygon: path, qualifier: qualifier)
            }
            .map(\.ref)
    }

    static func selectables(
        touchedBy path: [HorizontalPoint],
        selectables: [HorizontalSelectable]
    ) -> [HorizontalSelectableRef] {
        guard path.count >= 2 else {
            return []
        }
        return selectables
            .filter { selectable in
                polyline(path, intersects: selectable.selectionPolygon)
            }
            .map(\.ref)
    }

    private static func matches(
        _ selectable: HorizontalSelectable,
        polygon: [HorizontalPoint],
        qualifier: HorizontalSelectionQualifier
    ) -> Bool {
        switch qualifier {
        case .auto:
            return false
        case .includeOrigin:
            return contains(selectable.center, in: polygon)
        case .includeBox:
            return selectable.selectionPolygon.allSatisfy { contains($0, in: polygon) }
        case .touchBox:
            return polygonsIntersect(selectable.selectionPolygon, polygon)
        }
    }

    private static func polyline(_ path: [HorizontalPoint], intersects polygon: [HorizontalPoint]) -> Bool {
        guard polygon.count >= 2 else {
            return false
        }
        if path.contains(where: { contains($0, in: polygon) }) {
            return true
        }
        for segment in zip(path, path.dropFirst()) {
            for edge in polygonEdges(polygon) where segmentsIntersect(segment.0, segment.1, edge.0, edge.1) {
                return true
            }
        }
        return false
    }

    private static func polygonsIntersect(_ lhs: [HorizontalPoint], _ rhs: [HorizontalPoint]) -> Bool {
        guard lhs.count >= 2, rhs.count >= 2 else {
            return false
        }
        if lhs.contains(where: { contains($0, in: rhs) }) || rhs.contains(where: { contains($0, in: lhs) }) {
            return true
        }
        for leftEdge in polygonEdges(lhs) {
            for rightEdge in polygonEdges(rhs) where segmentsIntersect(leftEdge.0, leftEdge.1, rightEdge.0, rightEdge.1) {
                return true
            }
        }
        return false
    }

    private static func polygonEdges(_ polygon: [HorizontalPoint]) -> [(HorizontalPoint, HorizontalPoint)] {
        guard polygon.count >= 2 else {
            return []
        }
        return polygon.indices.map { index in
            (polygon[index], polygon[(index + 1) % polygon.count])
        }
    }

    private static func contains(_ point: HorizontalPoint, in polygon: [HorizontalPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if ((current.y > point.y) != (previous.y > point.y)) {
                let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < x {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    private static func segmentsIntersect(
        _ a: HorizontalPoint,
        _ b: HorizontalPoint,
        _ c: HorizontalPoint,
        _ d: HorizontalPoint
    ) -> Bool {
        let d1 = direction(c, d, a)
        let d2 = direction(c, d, b)
        let d3 = direction(a, b, c)
        let d4 = direction(a, b, d)

        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)),
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        return abs(d1) < geometryEpsilon && isOnSegment(a, from: c, to: d)
            || abs(d2) < geometryEpsilon && isOnSegment(b, from: c, to: d)
            || abs(d3) < geometryEpsilon && isOnSegment(c, from: a, to: b)
            || abs(d4) < geometryEpsilon && isOnSegment(d, from: a, to: b)
    }

    private static func direction(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint) -> Double {
        (c.x - a.x) * (b.y - a.y) - (b.x - a.x) * (c.y - a.y)
    }

    private static func isOnSegment(_ point: HorizontalPoint, from start: HorizontalPoint, to end: HorizontalPoint) -> Bool {
        point.x >= min(start.x, end.x) - geometryEpsilon
            && point.x <= max(start.x, end.x) + geometryEpsilon
            && point.y >= min(start.y, end.y) - geometryEpsilon
            && point.y <= max(start.y, end.y) + geometryEpsilon
    }
}

/// Uniform-grid spatial index over a set of selectables, so point hit-testing
/// (run on every mouse-move) is O(candidates) instead of O(all selectables).
/// Selectables are bucketed by their axis-aligned bounds; ones that would span
/// too many cells go in an always-scanned `largeItems` overflow list. Point
/// queries gather candidates from the cells overlapping the query margin, then
/// the caller applies the exact `inside` + precedence test — so results are
/// identical to a full linear scan, just cheaper.
struct HorizontalSelectableSpatialIndex {
    let selectables: [HorizontalSelectable]
    private let originX: Double
    private let originY: Double
    private let cellSize: Double
    private let cols: Int
    private let rows: Int
    private let cells: [[Int32]]
    private let largeItems: [Int32]

    init(_ selectables: [HorizontalSelectable]) {
        self.selectables = selectables

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var bounds = [(min: HorizontalPoint, max: HorizontalPoint)]()
        bounds.reserveCapacity(selectables.count)
        for selectable in selectables {
            let b = selectable.axisAlignedBounds
            bounds.append(b)
            minX = min(minX, b.min.x); minY = min(minY, b.min.y)
            maxX = max(maxX, b.max.x); maxY = max(maxY, b.max.y)
        }

        guard !selectables.isEmpty, maxX >= minX, maxY >= minY,
              (maxX > minX || maxY > minY) else {
            originX = 0; originY = 0; cellSize = 1; cols = 0; rows = 0
            cells = []
            largeItems = selectables.indices.map { Int32($0) }
            return
        }

        let width = max(maxX - minX, 1)
        let height = max(maxY - minY, 1)
        let count = Double(selectables.count)
        // Target ~1 selectable per cell on average, then cap the grid dimensions
        // so pathological bounds can't blow up memory.
        let targetCell = max((width * height / max(count, 1)).squareRoot(), 1)
        let maxDim = 512
        let colCount = min(maxDim, max(1, Int((width / targetCell).rounded(.up))))
        let rowCount = min(maxDim, max(1, Int((height / targetCell).rounded(.up))))
        let cell = max(width / Double(colCount), height / Double(rowCount), 1)

        func colIndex(_ x: Double) -> Int { min(colCount - 1, max(0, Int((x - minX) / cell))) }
        func rowIndex(_ y: Double) -> Int { min(rowCount - 1, max(0, Int((y - minY) / cell))) }

        var grid = [[Int32]](repeating: [], count: colCount * rowCount)
        var large = [Int32]()
        let maxSpanCells = 32
        for index in selectables.indices {
            let b = bounds[index]
            let c0 = colIndex(b.min.x), c1 = colIndex(b.max.x)
            let r0 = rowIndex(b.min.y), r1 = rowIndex(b.max.y)
            if (c1 - c0 + 1) * (r1 - r0 + 1) > maxSpanCells {
                large.append(Int32(index))
                continue
            }
            for r in r0...r1 {
                let base = r * colCount
                for c in c0...c1 {
                    grid[base + c].append(Int32(index))
                }
            }
        }

        originX = minX; originY = minY; cellSize = cell
        cols = colCount; rows = rowCount
        cells = grid
        largeItems = large
    }

    private func colIndex(_ x: Double) -> Int { min(cols - 1, max(0, Int((x - originX) / cellSize))) }
    private func rowIndex(_ y: Double) -> Int { min(rows - 1, max(0, Int((y - originY) / cellSize))) }

    /// Candidate selectables whose cells overlap the query point's `expand`
    /// margin, plus all oversized items. A superset of the true hits.
    func candidates(at point: HorizontalPoint, expand: Double) -> [HorizontalSelectable] {
        guard cols > 0, rows > 0 else {
            return largeItems.map { selectables[Int($0)] }
        }
        let margin = max(expand, 0)
        let c0 = colIndex(point.x - margin), c1 = colIndex(point.x + margin)
        let r0 = rowIndex(point.y - margin), r1 = rowIndex(point.y + margin)

        var seen = Set<Int32>(largeItems)
        var result = largeItems.map { selectables[Int($0)] }
        for r in r0...r1 {
            let base = r * cols
            for c in c0...c1 {
                for index in cells[base + c] where seen.insert(index).inserted {
                    result.append(selectables[Int(index)])
                }
            }
        }
        return result
    }

    func smallestSelectable(at point: HorizontalPoint, expand: Double) -> HorizontalSelectableRef? {
        HorizontalSelectableHitTest.smallestSelectable(at: point, in: candidates(at: point, expand: expand), expand: expand)
    }

    func allSelectables(at point: HorizontalPoint, expand: Double) -> [HorizontalSelectableRef] {
        HorizontalSelectableHitTest.allSelectables(at: point, in: candidates(at: point, expand: expand), expand: expand)
    }
}

private extension HorizontalSelectable {
    var selectionPolygon: [HorizontalPoint] {
        if isPoint {
            return [
                HorizontalPoint(x: center.x - 50, y: center.y - 50),
                HorizontalPoint(x: center.x + 50, y: center.y - 50),
                HorizontalPoint(x: center.x + 50, y: center.y + 50),
                HorizontalPoint(x: center.x - 50, y: center.y + 50)
            ]
        }
        return corners
    }
}
