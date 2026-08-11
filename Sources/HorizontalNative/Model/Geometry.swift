import CoreGraphics
import Foundation

struct HorizontalPoint: Hashable {
    var x: Double
    var y: Double

    static let zero = HorizontalPoint(x: 0, y: 0)

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct HorizontalPlacementTransform: Hashable {
    var shift: HorizontalPoint
    var angle: Int
    var mirrored: Bool

    static let identity = HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false)

    init(shift: HorizontalPoint, angle: Int, mirrored: Bool) {
        self.shift = shift
        self.angle = Self.wrap(angle)
        self.mirrored = mirrored
    }

    init?(json: JSONDictionary?, mirrorOverride: Bool? = nil) {
        guard let json,
              let shift = json.point("shift") else {
            return nil
        }

        self.init(
            shift: shift,
            angle: json.int("angle") ?? 0,
            mirrored: mirrorOverride ?? json.bool("mirror") ?? false
        )
    }

    func applying(to point: HorizontalPoint) -> HorizontalPoint {
        // Required order: mirror, then rotate, then translate. The order is not
        // a free choice — swapping mirror and rotation puts mirrored placements
        // with a non-zero angle 180° out, which shows up as bottom-side
        // components sitting rotated half a turn from where the file says.
        // Cardinal angles are handled exactly rather than through trigonometry
        // so a 90° placement lands on integer nanometres.
        var x = mirrored ? -point.x : point.x
        var y = point.y

        switch Self.wrap(angle) {
        case 0:
            break
        case 16_384:
            let nx = -y
            y = x
            x = nx
        case 32_768:
            x = -x
            y = -y
        case 49_152:
            let nx = y
            y = -x
            x = nx
        default:
            let radians = Double(angle) / 65_536.0 * Double.pi * 2
            let cosA = cos(radians)
            let sinA = sin(radians)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        return HorizontalPoint(x: x + shift.x, y: y + shift.y)
    }

    func accumulated(with child: HorizontalPlacementTransform) -> HorizontalPlacementTransform {
        // Composing a child onto a parent frame. When the parent is mirrored the
        // child's rotation enters that frame reversed — handedness flips with
        // the mirror, so adding the angles would rotate nested content the wrong
        // way on bottom-side packages.
        let combinedAngle = mirrored ? angle - child.angle : angle + child.angle
        return HorizontalPlacementTransform(
            shift: applying(to: child.shift),
            angle: combinedAngle,
            mirrored: mirrored != child.mirrored
        )
    }

    func accumulatedText(with child: HorizontalPlacementTransform) -> HorizontalPlacementTransform {
        let accumulated = accumulated(with: child)
        let childAngle = child.angle
        let effectiveAngle = (accumulated.mirrored ? 32_768 - childAngle : childAngle)
            + (mirrored ? -angle : angle)
        return HorizontalPlacementTransform(
            shift: accumulated.shift,
            angle: effectiveAngle,
            mirrored: accumulated.mirrored
        )
    }

    func rectangle(width: Double, height: Double) -> [HorizontalPoint] {
        let halfWidth = width / 2
        let halfHeight = height / 2
        return [
            HorizontalPoint(x: -halfWidth, y: -halfHeight),
            HorizontalPoint(x: halfWidth, y: -halfHeight),
            HorizontalPoint(x: halfWidth, y: halfHeight),
            HorizontalPoint(x: -halfWidth, y: halfHeight)
        ].map(applying)
    }

    func roundedRectangle(width: Double, height: Double, radius: Double, segments: Int = 8) -> [HorizontalPoint] {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let radius = min(max(radius, 0), halfWidth, halfHeight)
        guard radius > 0 else {
            return rectangle(width: width, height: height)
        }

        let centers = [
            HorizontalPoint(x: halfWidth - radius, y: -halfHeight + radius),
            HorizontalPoint(x: halfWidth - radius, y: halfHeight - radius),
            HorizontalPoint(x: -halfWidth + radius, y: halfHeight - radius),
            HorizontalPoint(x: -halfWidth + radius, y: -halfHeight + radius)
        ]
        let angleRanges = [
            (-Double.pi / 2, 0.0),
            (0.0, Double.pi / 2),
            (Double.pi / 2, Double.pi),
            (Double.pi, Double.pi * 3 / 2)
        ]
        let steps = max(segments, 2)

        return zip(centers, angleRanges).flatMap { center, range in
            (0...steps).map { index in
                let fraction = Double(index) / Double(steps)
                let angle = range.0 + (range.1 - range.0) * fraction
                return HorizontalPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            }
        }.map(applying)
    }

    func circle(diameter: Double, segments: Int = 20) -> [HorizontalPoint] {
        let radius = diameter / 2
        return (0..<segments).map { index in
            let angle = Double(index) / Double(segments) * Double.pi * 2
            return applying(to: HorizontalPoint(x: cos(angle) * radius, y: sin(angle) * radius))
        }
    }

    func obround(width: Double, height: Double, segments: Int = 10) -> [HorizontalPoint] {
        let radius = min(width, height) / 2
        let offset = max(width, height) / 2 - radius

        if width >= height {
            let right = (0...segments).map { index in
                let angle = -Double.pi / 2 + Double(index) / Double(segments) * Double.pi
                return HorizontalPoint(x: offset + cos(angle) * radius, y: sin(angle) * radius)
            }
            let left = (0...segments).map { index in
                let angle = Double.pi / 2 + Double(index) / Double(segments) * Double.pi
                return HorizontalPoint(x: -offset + cos(angle) * radius, y: sin(angle) * radius)
            }
            return (right + left).map(applying)
        }

        let top = (0...segments).map { index in
            let angle = Double(index) / Double(segments) * Double.pi
            return HorizontalPoint(x: cos(angle) * radius, y: offset + sin(angle) * radius)
        }
        let bottom = (0...segments).map { index in
            let angle = Double.pi + Double(index) / Double(segments) * Double.pi
            return HorizontalPoint(x: cos(angle) * radius, y: -offset + sin(angle) * radius)
        }
        return (top + bottom).map(applying)
    }

    private static func wrap(_ angle: Int) -> Int {
        let wrapped = angle % 65_536
        return wrapped < 0 ? wrapped + 65_536 : wrapped
    }
}

struct HorizontalRect: Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    static let empty = HorizontalRect(minX: 0, minY: 0, maxX: 0, maxY: 0)

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: HorizontalPoint { HorizontalPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    init(points: [HorizontalPoint]) {
        guard let first = points.first else {
            self = .empty
            return
        }

        minX = first.x
        minY = first.y
        maxX = first.x
        maxY = first.y

        for point in points.dropFirst() {
            include(point)
        }
    }

    mutating func include(_ point: HorizontalPoint) {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }

    func padded(_ fraction: Double = 0.08) -> HorizontalRect {
        guard !isEmpty else {
            return self
        }

        let padX = max(width * fraction, 1)
        let padY = max(height * fraction, 1)
        return HorizontalRect(minX: minX - padX, minY: minY - padY, maxX: maxX + padX, maxY: maxY + padY)
    }

    func expanded(by amount: Double) -> HorizontalRect {
        guard !isEmpty else {
            return self
        }

        return HorizontalRect(
            minX: minX - amount,
            minY: minY - amount,
            maxX: maxX + amount,
            maxY: maxY + amount
        )
    }

    func intersects(_ other: HorizontalRect) -> Bool {
        guard !isEmpty, !other.isEmpty else {
            return false
        }

        return minX <= other.maxX
            && maxX >= other.minX
            && minY <= other.maxY
            && maxY >= other.minY
    }

    init(center: HorizontalPoint, size: Double) {
        let radius = size / 2
        self.init(
            minX: center.x - radius,
            minY: center.y - radius,
            maxX: center.x + radius,
            maxY: center.y + radius
        )
    }

    private init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

struct HorizontalSegment: Identifiable, Hashable {
    var id: String
    var from: HorizontalPoint
    var to: HorizontalPoint
    var width: Double
    var layer: Int?
    var center: HorizontalPoint? = nil
    var reverse: Bool = false
    var netID: String? = nil
}

extension HorizontalSegment {
    var arc: HorizontalArc? {
        center.map {
            HorizontalArc(
                id: id,
                from: from,
                to: to,
                center: $0,
                width: width,
                layer: layer,
                reverse: reverse,
                netID: netID
            )
        }
    }

    var pathPoints: [HorizontalPoint] {
        if let arc {
            return arc.polyline()
        }
        return [from, to]
    }

    var length: Double {
        let points = pathPoints
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + (pair.1 - pair.0).length
        }
    }

    func withNetID(_ netID: String?) -> HorizontalSegment {
        var segment = self
        segment.netID = netID
        return segment
    }
}

struct HorizontalArc: Identifiable, Hashable {
    var id: String
    var from: HorizontalPoint
    var to: HorizontalPoint
    var center: HorizontalPoint
    var width: Double
    var layer: Int?
    var reverse: Bool = false
    var netID: String? = nil
}

extension HorizontalArc {
    var projectedCenter: HorizontalPoint {
        projectOntoPerpendicularBisector(from, to, center)
    }

    var radius: Double {
        (from - projectedCenter).length
    }

    var length: Double {
        let points = polyline()
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + (pair.1 - pair.0).length
        }
    }

    func polyline(precision: Int = 48) -> [HorizontalPoint] {
        horizonArcPolyline(from: from, to: to, centerHint: center, reverse: reverse, precision: precision)
    }

    func withNetID(_ netID: String?) -> HorizontalArc {
        var arc = self
        arc.netID = netID
        return arc
    }
}

struct HorizontalMarker: Identifiable, Hashable {
    var id: String
    var position: HorizontalPoint
    var size: Double
    var holeSize: Double? = nil
    var layer: Int?
    var connectedLayers: [Int] = []
    var netID: String? = nil

    var boundsPoints: [HorizontalPoint] {
        let radius = size / 2
        return [
            HorizontalPoint(x: position.x - radius, y: position.y - radius),
            HorizontalPoint(x: position.x + radius, y: position.y + radius),
        ]
    }
}

/// What a newly drawn via should look like, harvested at parse time from the
/// board's via definitions (preferred) or an existing via. Carries the pool
/// padstack UUID a new via must reference plus default geometry. Nil when the
/// board has neither a via definition nor any via to clone, in which case the
/// track tool cannot create a valid via.
struct HorizontalBoardViaTemplate: Equatable {
    var padstackID: String
    var diameter: Double
    var holeDiameter: Double
}

enum HorizontalHoleShape: String, Hashable {
    case round
    case slot
}

struct HorizontalHole: Identifiable, Hashable {
    var id: String
    var position: HorizontalPoint
    var diameter: Double
    var length: Double? = nil
    var shape: HorizontalHoleShape = .round
    var angle: Int = 0
    var plated: Bool
    var netID: String? = nil

    var effectiveLength: Double {
        max(length ?? diameter, diameter)
    }

    var boundsPoints: [HorizontalPoint] {
        if shape == .slot, effectiveLength > diameter {
            return outlinePoints(precision: 16)
        }

        let radius = diameter / 2
        return [
            HorizontalPoint(x: position.x - radius, y: position.y - radius),
            HorizontalPoint(x: position.x + radius, y: position.y + radius),
        ]
    }

    func outlinePoints(precision: Int = 32) -> [HorizontalPoint] {
        let radius = diameter / 2
        let transform = HorizontalPlacementTransform(shift: position, angle: angle, mirrored: false)
        let segments = max(precision, 8)

        if shape == .round || effectiveLength <= diameter {
            return (0..<segments).map { index in
                let angle = Double(index) / Double(segments) * Double.pi * 2
                return transform.applying(to: HorizontalPoint(x: cos(angle) * radius, y: sin(angle) * radius))
            }
        }

        let arcSegments = max(segments / 2, 4)
        let offset = max(effectiveLength / 2 - radius, 0)
        let rightArc = (0...arcSegments).map { index in
            let angle = Double.pi / 2 - Double(index) / Double(arcSegments) * Double.pi
            return HorizontalPoint(x: offset + cos(angle) * radius, y: sin(angle) * radius)
        }
        let leftArc = (0...arcSegments).map { index in
            let angle = -Double.pi / 2 - Double(index) / Double(arcSegments) * Double.pi
            return HorizontalPoint(x: -offset + cos(angle) * radius, y: sin(angle) * radius)
        }
        return (rightArc + leftArc).map(transform.applying(to:))
    }
}

enum HorizontalTextOrigin: String, Hashable {
    case baseline
    case center
    case bottom
}

enum HorizontalTextFont: String, Hashable {
    case simplex
    case complex
    case complexItalic = "complex_italic"
    case complexSmall = "complex_small"
    case complexSmallItalic = "complex_small_italic"
    case duplex
    case triplex
    case triplexItalic = "triplex_italic"
    case small
    case smallItalic = "small_italic"
    case scriptSimplex = "script_simplex"
    case scriptComplex = "script_complex"
}

struct HorizontalText: Identifiable, Hashable {
    var id: String
    var text: String
    var position: HorizontalPoint
    var size: Double
    var layer: Int?
    var netID: String? = nil
    var angle: Int = 0
    var mirrored: Bool = false
    var width: Double = 0
    var origin: HorizontalTextOrigin = .center
    var font: HorizontalTextFont = .simplex
    var allowUpsideDown: Bool = false
    var centered: Bool = false
    /// True for a board-level text extracted from a package by "Smash"
    /// (`from_smash`). Such a text is independently editable/selectable and is
    /// persisted to the board's `texts` (referenced by the package); a package's
    /// own (un-smashed) pool text has this false.
    var fromSmash: Bool = false
}

extension HorizontalText {
    var renderBoundsPoints: [HorizontalPoint] {
        let segments = HorizontalOutlineTextRenderer.outlineSegments(for: self)
        let points = [position] + segments.flatMap { [$0.0, $0.1] }
        let bounds = HorizontalRect(points: points)
        let padding = max(size / 4, width / 2)

        // Proper rectangle winding (CCW), not a Z-order bowtie, and without the
        // appended position point — so this is a valid closed polygon for clip
        // operations (e.g. plane text cutouts) as well as bounds accumulation.
        return [
            HorizontalPoint(x: bounds.minX - padding, y: bounds.minY - padding),
            HorizontalPoint(x: bounds.maxX + padding, y: bounds.minY - padding),
            HorizontalPoint(x: bounds.maxX + padding, y: bounds.maxY + padding),
            HorizontalPoint(x: bounds.minX - padding, y: bounds.maxY + padding)
        ]
    }
}

struct HorizontalBusLabel: Identifiable, Hashable {
    var id: String
    var text: String
    var position: HorizontalPoint
    var size: Double
    var orientation: String
    var netID: String? = nil
}

struct HorizontalSchematicNetLabel: Identifiable, Hashable {
    var id: String
    var text: String
    var position: HorizontalPoint
    var size: Double
    var orientation: String
    var netID: String? = nil

    var points: [HorizontalPoint] {
        [position, position + labelShift(size: size, orientation: orientation)]
    }
}

private func labelShift(size: Double, orientation: String) -> HorizontalPoint {
    switch orientation {
    case "left":
        return HorizontalPoint(x: -size, y: 0)
    case "up":
        return HorizontalPoint(x: 0, y: size)
    case "down":
        return HorizontalPoint(x: 0, y: -size)
    default:
        return HorizontalPoint(x: size, y: 0)
    }
}

struct HorizontalPowerSymbol: Identifiable, Hashable {
    var id: String
    var junctionID: String
    var netID: String?
    var orientation: String
    var mirrored: Bool
}

struct HorizontalSchematicNetTie: Identifiable, Hashable {
    var id: String
    var from: HorizontalPoint
    var to: HorizontalPoint
    var label: String
    var netIDs: Set<String> = []

    var points: [HorizontalPoint] {
        let center = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let vector = to - from
        let normal = HorizontalPoint(x: vector.y, y: -vector.x).normalized
        return [from, to, center + normal * 1_500_000]
    }
}

struct HorizontalPolygonVertex: Hashable {
    enum EdgeType: String, Hashable {
        case line
        case arc
    }

    var type: EdgeType
    var position: HorizontalPoint
    var arcCenter: HorizontalPoint
    var arcReverse: Bool

    init(type: EdgeType = .line, position: HorizontalPoint, arcCenter: HorizontalPoint = .zero, arcReverse: Bool = false) {
        self.type = type
        self.position = position
        self.arcCenter = arcCenter
        self.arcReverse = arcReverse
    }

    init?(_ json: JSONDictionary) {
        guard let position = json.point("position") else {
            return nil
        }
        self.init(
            type: EdgeType(rawValue: json.string("type") ?? "") ?? .line,
            position: position,
            arcCenter: json.point("arc_center") ?? .zero,
            arcReverse: json.bool("arc_reverse") ?? false
        )
    }

    func transformed(_ transform: (HorizontalPoint) -> HorizontalPoint, flipsArcReverse: Bool = false) -> HorizontalPolygonVertex {
        var vertex = self
        vertex.position = transform(position)
        vertex.arcCenter = transform(arcCenter)
        if flipsArcReverse, vertex.type == .arc {
            vertex.arcReverse.toggle()
        }
        return vertex
    }
}

/// Intrinsic axis-aligned frame of a pad shape (rect / roundrect / circle /
/// obround) in board-world coordinates. Captured at parse time so renderers
/// can place pad labels using the pad's *actual* placement angle and inner
/// dimensions instead of re-deriving them from the rendered polygon's edges.
///
/// The polygon-edge derivation in `BoardCanvasView.padLabelFrame(for:padText:netText:)`
/// works for true rectangles (4 axis-aligned edges) but is unreliable for
/// roundrect (~36 chord segments around the corners — each is long enough to
/// pass the "minimum edge length" filter, so dozens of bogus rotated axes are
/// scored against each other) and for circles (every edge has the same length
/// at a different angle, so the picked angle is arbitrary). This descriptor
/// matches what the label layout consumes:
/// the pad's intrinsic width/height plus its placement angle.
///
/// `halfWidth` and `halfHeight` are pre-rotation extents in pad-local axes;
/// `angle` is int-angle convention (0..65535 == 0..2π) and is the
/// pad's *raw* placement angle — `BoardPadLabelLayout` inverts it for mirrored
/// (bottom-side) pads, exactly as `draw_bitmap_text_box` does with
/// `if (p.mirror) p.invert_angle()`. Keeping the raw placement here means the
/// descriptor composes with an outer placement (panelisation) like any other
/// transform.
struct PadLabelFrameDescriptor: Hashable {
    var center: HorizontalPoint
    var halfWidth: Double
    var halfHeight: Double
    var angle: Int
    var mirrored: Bool = false

    /// Larger descriptors win the "first non-nil" merge in pad-label group
    /// construction — useful when one pad contributes both a copper shape and
    /// a (smaller) mask aperture into the same label group.
    var area: Double { 4 * halfWidth * halfHeight }
}

struct HorizontalPolygon: Identifiable, Hashable {
    var id: String
    var polygonVertices: [HorizontalPolygonVertex]
    var layer: Int?
    var netID: String? = nil
    var metadata: [String: String] = [:]
    /// Populated for *every* pad polygon — through-hole, via, mechanical,
    /// shape-defined and polygon-defined padstacks alike — from the padstack's
    /// local bbox plus the pad's placement, mirroring
    /// the padstack's own bounding box. Nil for non-pad polygons. See
    /// `PadLabelFrameDescriptor` for why.
    var padLabelFrame: PadLabelFrameDescriptor? = nil

    var vertices: [HorizontalPoint] {
        get {
            polygonVertices.map(\.position)
        }
        set {
            polygonVertices = newValue.enumerated().map { index, point in
                if polygonVertices.indices.contains(index) {
                    var vertex = polygonVertices[index]
                    vertex.position = point
                    return vertex
                }
                return HorizontalPolygonVertex(position: point)
            }
        }
    }

    init(
        id: String,
        vertices: [HorizontalPoint],
        layer: Int?,
        netID: String? = nil,
        metadata: [String: String] = [:],
        padLabelFrame: PadLabelFrameDescriptor? = nil
    ) {
        self.id = id
        self.polygonVertices = vertices.map { HorizontalPolygonVertex(position: $0) }
        self.layer = layer
        self.netID = netID
        self.metadata = metadata
        self.padLabelFrame = padLabelFrame
    }

    init(
        id: String,
        polygonVertices: [HorizontalPolygonVertex],
        layer: Int?,
        netID: String? = nil,
        metadata: [String: String] = [:],
        padLabelFrame: PadLabelFrameDescriptor? = nil
    ) {
        self.id = id
        self.polygonVertices = polygonVertices
        self.layer = layer
        self.netID = netID
        self.metadata = metadata
        self.padLabelFrame = padLabelFrame
    }
}

extension HorizontalPolygon {
    var area: Double {
        horizonPolygonArea(renderVertices(arcPrecision: 16))
    }

    var hasArcEdges: Bool {
        polygonVertices.contains { $0.type == .arc }
    }

    func renderVertices(arcPrecision: Int = 16) -> [HorizontalPoint] {
        guard polygonVertices.count >= 2 else {
            return vertices
        }

        var rendered = [HorizontalPoint]()
        rendered.reserveCapacity(polygonVertices.count)
        for index in polygonVertices.indices {
            let vertex = polygonVertices[index]
            if vertex.type == .arc {
                let next = polygonVertices[nextVertexIndex(after: index)]
                let points = horizonArcPolyline(
                    from: vertex.position,
                    to: next.position,
                    centerHint: vertex.arcCenter,
                    reverse: vertex.arcReverse,
                    precision: arcPrecision
                )
                rendered.append(contentsOf: points.dropLast())
            } else {
                rendered.append(vertex.position)
            }
        }
        return rendered
    }

    func edgePolyline(at index: Int, arcPrecision: Int = 24) -> [HorizontalPoint] {
        guard polygonVertices.indices.contains(index) else {
            return []
        }
        let vertex = polygonVertices[index]
        let next = polygonVertices[nextVertexIndex(after: index)]
        if vertex.type == .arc {
            return horizonArcPolyline(
                from: vertex.position,
                to: next.position,
                centerHint: vertex.arcCenter,
                reverse: vertex.arcReverse,
                precision: arcPrecision
            )
        }
        return [vertex.position, next.position]
    }

    func nextVertexIndex(after index: Int) -> Int {
        index >= polygonVertices.count - 1 ? 0 : index + 1
    }

    func transformed(_ transform: (HorizontalPoint) -> HorizontalPoint, flipsArcReverse: Bool = false) -> HorizontalPolygon {
        var polygon = self
        polygon.polygonVertices = polygonVertices.map {
            $0.transformed(transform, flipsArcReverse: flipsArcReverse)
        }
        // NOTE: `padLabelFrame` is deliberately NOT transformed here. This is
        // also the load path, where the frame is composed with the package (and
        // panel) placement explicitly by the caller — doing it here as well
        // applies the placement twice, which moves the frame and, because the
        // pour reads it for thermal spoke placement, silently changes poured
        // copper. Editing transforms carry it in
        // `HorizontalCanvasModeSupport.shifted` / `rotated` instead.
        return polygon
    }
}

struct HorizontalCircle: Identifiable, Hashable {
    var id: String
    var center: HorizontalPoint
    var radius: Double
    var layer: Int?
    var netID: String? = nil
}

struct HorizontalPlaneFragment: Hashable {
    var paths: [[HorizontalPoint]]
    var orphan: Bool
}

extension HorizontalPlaneFragment {
    var area: Double {
        paths.reduce(0) { $0 + horizonPolygonArea($1) }
    }
}

private func horizonPolygonArea(_ vertices: [HorizontalPoint]) -> Double {
    guard vertices.count >= 3 else {
        return 0
    }

    var sum = 0.0
    for index in vertices.indices {
        let nextIndex = index == vertices.index(before: vertices.endIndex) ? vertices.startIndex : vertices.index(after: index)
        sum += vertices[index].x * vertices[nextIndex].y - vertices[nextIndex].x * vertices[index].y
    }
    return abs(sum) / 2
}

struct HorizontalPlane: Identifiable, Hashable {
    var id: String
    var netID: String?
    var polygonID: String
    var layer: Int?
    var priority: Int
    var fillStyle: String
    var minWidth: Double
    var keepOrphans: Bool
    var fragments: [HorizontalPlaneFragment]
    var fallbackPolygon: HorizontalPolygon?
    /// When true (default), the effective pour settings come from the
    /// board's plane rules rather than this plane's own `settings` object.
    var fromRules: Bool = true
    /// The plane's own settings as written in board.json. Used directly when
    /// `fromRules == false`, and as the fallback if no plane rule matches.
    var settings: HorizontalPlaneSettings = .default

    var renderFragments: [HorizontalPlaneFragment] {
        if !fragments.isEmpty {
            return fragments
        }

        guard let fallbackPolygon else {
            return []
        }

        return [HorizontalPlaneFragment(paths: [fallbackPolygon.vertices], orphan: true)]
    }

    var points: [HorizontalPoint] {
        renderFragments.flatMap { fragment in
            fragment.paths.flatMap { $0 }
        }
    }
}

struct HorizontalRGBColor: Hashable {
    var red: Double
    var green: Double
    var blue: Double
}

struct HorizontalNetClass: Identifiable, Hashable {
    var id: String
    var name: String
}

struct HorizontalNetDetails: Hashable {
    var id: String
    var name: String
    var netClassID: String?
    var netClassName: String?
    var isPower: Bool = false
    var isPort: Bool = false
    var portDirection: String?
    var powerSymbolStyle: String?
}

struct HorizontalSchematicComponentRecord: Identifiable, Hashable {
    var id: String
    var entityID: String
    var partID: String
    var refdes: String
    var tagID: String
}

struct HorizontalComponentDetails: Hashable {
    var componentID: String?
    var refdes: String
    var value: String
    var partID: String?
    var noPopulate: Bool = false
    var mpn: String?
    var manufacturer: String?
    var packageName: String?
    var description: String?
    var datasheet: String?
    var parametricValues: [String: String] = [:]

    var displayLabel: String {
        if !refdes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return refdes
        }
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return componentID.map { String($0.prefix(8)) } ?? "Component"
    }
}

struct HorizontalUnplacedObject: Identifiable, Hashable {
    var id: String
    var label: String
    var subtitle: String
    var componentID: String?
    var gateID: String?
    var symbolID: String? = nil
    var details: HorizontalComponentDetails?
}

struct HorizontalBoardColors: Hashable {
    var silkscreen: HorizontalRGBColor?
    var solderMask: HorizontalRGBColor?
    var substrate: HorizontalRGBColor?
}

struct HorizontalBoardStackupLayer: Identifiable, Hashable {
    var id: Int { layer }

    var layer: Int
    var copperThickness: Double
    var substrateThickness: Double
}

struct HorizontalBoardUserLayer: Identifiable, Hashable {
    var id: Int
    var colorLayer: Int
    var name: String
    var type: String
    var position: Double?
}

struct HorizontalKeepout: Identifiable, Hashable {
    var id: String
    var polygonID: String
    var polygon: HorizontalPolygon
    var keepoutClass: String
    var allCopperLayers: Bool
    var exposedCopperOnly: Bool
    var copperPatchTypes: [String]

    var points: [HorizontalPoint] {
        polygon.vertices
    }
}

enum HorizontalDimensionMode: String, Hashable {
    case distance
    case horizontal
    case vertical
}

struct HorizontalDimension: Identifiable, Hashable {
    var id: String
    var p0: HorizontalPoint
    var p1: HorizontalPoint
    var labelDistance: Double
    var labelSize: Double
    var mode: HorizontalDimensionMode

    var length: Double {
        switch mode {
        case .distance:
            return hypot(p0.x - p1.x, p0.y - p1.y)
        case .horizontal:
            return abs(p0.x - p1.x)
        case .vertical:
            return abs(p0.y - p1.y)
        }
    }

    var label: String {
        String(format: "%07.3f mm", length / 1_000_000)
    }

    var points: [HorizontalPoint] {
        let geometry = measurementGeometry
        let extensionDistance = labelDistance + (labelDistance >= 0 ? labelSize : -labelSize)
        return [
            p0,
            p1,
            geometry.p0Projected + geometry.normal * extensionDistance,
            geometry.p1Projected + geometry.normal * extensionDistance
        ] + (labelText?.renderBoundsPoints ?? [])
    }

    var measurementGeometry: (p0Projected: HorizontalPoint, p1Projected: HorizontalPoint, normal: HorizontalPoint) {
        let p0Projected = p0
        var p1Projected = p1

        switch mode {
        case .distance:
            break
        case .horizontal:
            p1Projected.y = p0Projected.y
        case .vertical:
            p1Projected.x = p0Projected.x
        }

        let vector = p1Projected - p0Projected
        var normal = HorizontalPoint(x: -vector.y, y: vector.x).normalized
        if mode == .horizontal {
            normal.y = abs(normal.y)
        } else if mode == .vertical {
            normal.x = abs(normal.x)
        }

        return (p0Projected, p1Projected, normal.normalized)
    }

    var labelText: HorizontalText? {
        let geometry = measurementGeometry
        let vector = geometry.p1Projected - geometry.p0Projected
        let length = hypot(vector.x, vector.y)
        guard length > 0 else {
            return nil
        }

        let direction = vector.normalized
        let q0 = geometry.p0Projected + geometry.normal * labelDistance
        let q1 = geometry.p1Projected + geometry.normal * labelDistance
        let labelWidth = HorizontalOutlineTextRenderer.textWidth(label, font: .simplex, size: labelSize)
        let center = q0 + vector * 0.5
        let labelFitsBetweenArrows = labelWidth + labelSize * 2 <= length

        let textPosition: HorizontalPoint
        if length <= labelSize * 2 {
            textPosition = q1 + direction * labelSize
        } else if labelFitsBetweenArrows {
            textPosition = center - direction * (labelWidth / 2)
        } else {
            textPosition = q1
        }

        return HorizontalText(
            id: "\(id)/label",
            text: label,
            position: textPosition,
            size: labelSize,
            layer: nil,
            angle: Self.angleUnits(fromRadians: atan2(direction.y, direction.x)),
            width: max(labelSize * 0.035, 35_000),
            origin: .center,
            font: .simplex
        )
    }

    private static func angleUnits(fromRadians radians: Double) -> Int {
        Int((radians / (Double.pi * 2)) * 65_536)
    }
}

struct HorizontalBoardDecal: Identifiable, Hashable {
    var id: String
    var decalID: String
    var name: String
    var polygons: [HorizontalPolygon]
    var lines: [HorizontalSegment]
    var arcs: [HorizontalArc]
    var texts: [HorizontalText]

    var points: [HorizontalPoint] {
        polygons.flatMap(\.vertices)
            + lines.flatMap { [$0.from, $0.to] }
            + arcs.flatMap { $0.polyline(precision: 24) }
            + texts.flatMap(\.renderBoundsPoints)
    }
}

struct HorizontalBoardPanel: Identifiable {
    var id: String
    var includedBoardID: String
    var projectFilename: String
    var boardName: String
    var placement: HorizontalPlacementTransform
    var omitOutline: Bool
    var bounds: HorizontalRect
}

struct HorizontalPlacement: Identifiable, Hashable {
    var id: String
    var position: HorizontalPoint
    var angle: Int
    var mirrored: Bool
    var label: String
    var componentID: String? = nil
    var componentDetails: HorizontalComponentDetails? = nil
    var customValue: String? = nil
    var gateID: String? = nil
    var symbolID: String? = nil
    var pinDisplayMode: String = HorizontalSymbolPinDisplayMode.selectedOnly.rawValue
    var symbolPinNames: [HorizontalSymbolPinName] = []
    var packageID: String? = nil
    var modelID: String? = nil
    var model3D: HorizontalPackage3DModel? = nil
    /// `smashed`: the package's own text is replaced by independently
    /// editable board-level `fromSmash` texts (see `HorizontalText.fromSmash`). When
    /// true the pool silk is retained (in `packageTexts`) but hidden so Unsmash
    /// can restore it.
    var smashed: Bool = false
    /// `omit_silkscreen`: hides the package's own silkscreen GRAPHICS
    /// (lines/arcs/polygons on silk layers). Set by "Smash silkscreen graphics"
    /// (the graphics move to the board) or toggled directly.
    var omitSilkscreen: Bool = false
    /// `omit_outline`: hides the package's outline polygons.
    var omitOutline: Bool = false
    /// `fixed`: the package is locked — it can't be moved or deleted.
    var fixed: Bool = false
}

enum HorizontalSymbolPinDisplayMode: String, CaseIterable, Identifiable, Hashable {
    case selectedOnly = "selected_only"
    case customOnly = "custom_only"
    case both
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectedOnly: "Selected only"
        case .customOnly: "Custom only"
        case .both: "Both"
        case .all: "All"
        }
    }
}

struct HorizontalSymbolPinNameOption: Identifiable, Hashable {
    var id: String
    var name: String
    var direction: String
}

struct HorizontalSymbolPinNameState: Hashable {
    var pinNames: [String] = []
    var usePrimaryName: Bool = false
    var useCustomName: Bool = false
    var customName: String = ""
    var customDirection: String = "bidirectional"
}

struct HorizontalSymbolPinName: Identifiable, Hashable {
    var id: String
    var gateID: String
    var gatePinPath: String
    var primaryName: String
    var primaryDirection: String
    var alternateNames: [HorizontalSymbolPinNameOption]
    var state: HorizontalSymbolPinNameState
}

struct HorizontalPackage3DModel: Hashable {
    var id: String
    var filename: String
    var fileURL: URL
    var x: Double
    var y: Double
    var z: Double
    var roll: Int
    var pitch: Int
    var yaw: Int
    var heightTop: Double
    var heightBottom: Double
}

struct HorizontalPackageGeometry {
    var pads: [HorizontalPolygon]
    var polygons: [HorizontalPolygon]
    var lines: [HorizontalSegment]
    var arcs: [HorizontalArc]
    var texts: [HorizontalText]
    var holes: [HorizontalHole]
    var padPositions: [String: HorizontalPoint]
    var padNetIDs: [String: String]

    static let empty = HorizontalPackageGeometry(pads: [], polygons: [], lines: [], arcs: [], texts: [], holes: [], padPositions: [:], padNetIDs: [:])

    var points: [HorizontalPoint] {
        var result = [HorizontalPoint]()
        result.append(contentsOf: pads.flatMap(\.vertices))
        result.append(contentsOf: polygons.flatMap(\.vertices))
        result.append(contentsOf: lines.flatMap { [$0.from, $0.to] })
        result.append(contentsOf: arcs.flatMap { $0.polyline(precision: 24) })
        result.append(contentsOf: texts.flatMap(\.renderBoundsPoints))
        result.append(contentsOf: holes.flatMap(\.boundsPoints))
        result.append(contentsOf: padPositions.values)
        return result
    }

    mutating func append(_ other: HorizontalPackageGeometry) {
        pads.append(contentsOf: other.pads)
        polygons.append(contentsOf: other.polygons)
        lines.append(contentsOf: other.lines)
        arcs.append(contentsOf: other.arcs)
        texts.append(contentsOf: other.texts)
        holes.append(contentsOf: other.holes)
        padPositions.merge(other.padPositions) { current, _ in current }
        padNetIDs.merge(other.padNetIDs) { current, _ in current }
    }
}

func horizonArcPolyline(
    from start: HorizontalPoint,
    to end: HorizontalPoint,
    centerHint: HorizontalPoint,
    reverse: Bool = false,
    precision: Int = 48
) -> [HorizontalPoint] {
    guard precision > 1 else {
        return [start, end]
    }

    let center = projectOntoPerpendicularBisector(start, end, centerHint)
    var radius = (start - center).length
    let endRadius = (end - center).length
    guard radius > 0, endRadius > 0 else {
        return [start, end]
    }

    var startAngle = atan2(start.y - center.y, start.x - center.x)
    var endAngle = atan2(end.y - center.y, end.x - center.x)
    if startAngle < 0 {
        startAngle += Double.pi * 2
    }
    if endAngle < 0 {
        endAngle += Double.pi * 2
    }

    var delta = endAngle - startAngle
    if delta < 0 {
        delta += Double.pi * 2
    }
    if reverse {
        delta -= Double.pi * 2
    }

    let angleStep = delta / Double(precision)
    let radiusStep = (endRadius - radius) / Double(precision)

    var points = [start]
    for stepIndex in 1..<precision {
        let angle = startAngle + angleStep * Double(stepIndex)
        points.append(
            HorizontalPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        )
        radius += radiusStep
    }
    points.append(end)
    return points
}

func projectOntoPerpendicularBisector(
    _ start: HorizontalPoint,
    _ end: HorizontalPoint,
    _ point: HorizontalPoint
) -> HorizontalPoint {
    let midpoint = HorizontalPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    let delta = HorizontalPoint(x: end.x - start.x, y: end.y - start.y)
    let magnitudeSquared = delta.x * delta.x + delta.y * delta.y
    guard magnitudeSquared != 0 else {
        return point
    }

    let projectedDistance = (horizonDot(delta, midpoint) - horizonDot(delta, point)) / magnitudeSquared
    return HorizontalPoint(
        x: point.x + delta.x * projectedDistance,
        y: point.y + delta.y * projectedDistance
    )
}

private func horizonDot(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y
}

extension HorizontalPoint {
    static func + (lhs: HorizontalPoint, rhs: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: HorizontalPoint, rhs: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: HorizontalPoint, rhs: Double) -> HorizontalPoint {
        HorizontalPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    var length: Double {
        hypot(x, y)
    }

    var normalized: HorizontalPoint {
        let magnitude = hypot(x, y)
        guard magnitude > 0 else {
            return .zero
        }
        return HorizontalPoint(x: x / magnitude, y: y / magnitude)
    }
}
