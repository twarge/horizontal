import Foundation

/// Corner geometry for a routed track: a 90° L-bend, a 45° diagonal elbow, or a
/// tangent quarter-arc rounding the same corner. Posture (which leg leads) is
/// chosen separately. Persisted via the tool settings, so it lives at module
/// scope rather than nested in the view.
enum BoardTrackCornerStyle: String, CaseIterable, Identifiable {
    case ninety
    case fortyFive
    case arc

    var id: String { rawValue }
    var isDiagonal: Bool { self == .fortyFive }
    var isArc: Bool { self == .arc }

    var label: String {
        switch self {
        case .ninety: "90°"
        case .fortyFive: "45°"
        case .arc: "Arc"
        }
    }

    mutating func cycle() {
        switch self {
        case .ninety: self = .fortyFive
        case .fortyFive: self = .arc
        case .arc: self = .ninety
        }
    }
}

/// One leg of a routed path: a straight segment (`center == nil`) or, for the
/// arc corner style, a tangent quarter-arc whose center is a coordinate.
/// `from`/`to` are in route (flow) order.
struct BoardTrackSegmentSpec: Equatable {
    var from: HorizontalPoint
    var to: HorizontalPoint
    var center: HorizontalPoint?

    /// Endpoints ordered so that an arc renders as the minor (≤180°) sweep,
    /// since the persisted form has no reverse flag — Horizon encodes direction
    /// in from/to order. Straight segments are returned unchanged.
    var renderEndpoints: (from: HorizontalPoint, to: HorizontalPoint) {
        guard let center else {
            return (from, to)
        }
        return BoardTrackRouting.orientedArc(from: from, to: to, center: center)
    }

    /// Flattened points in route (flow) order, so consecutive legs chain.
    func polyline(arcPrecision: Int = 48) -> [HorizontalPoint] {
        guard let center else {
            return [from, to]
        }
        let ends = renderEndpoints
        let points = horizonArcPolyline(from: ends.from, to: ends.to, centerHint: center, precision: arcPrecision)
        // `renderEndpoints` may swap to draw the minor arc; restore flow order.
        return ends.from == from ? points : points.reversed()
    }
}

/// Pure, view-independent helpers for the board track-drawing tool. Extracted
/// from `BoardCanvasView` so the routing geometry, net resolution and width
/// heuristics can be unit-tested without standing up a SwiftUI view. Mirrors the
/// non-router manual mode of ToolDrawTrack.
enum BoardTrackRouting {
    static let defaultTrackWidth: Double = 200_000 // 0.2 mm in nm

    /// Route from `anchor` to `point` as a list of leg specs honoring the
    /// corner style: straight 90° L, 45° diagonal, or a tangent quarter-arc
    /// corner. Posture (`horizontalFirst`) chooses which leg leads.
    static func route(
        from anchor: HorizontalPoint,
        to point: HorizontalPoint,
        horizontalFirst: Bool,
        cornerStyle: BoardTrackCornerStyle
    ) -> [BoardTrackSegmentSpec] {
        switch cornerStyle {
        case .ninety:
            return straightSpecs(path(from: anchor, to: point, horizontalFirst: horizontalFirst, diagonal: false))
        case .fortyFive:
            return straightSpecs(path(from: anchor, to: point, horizontalFirst: horizontalFirst, diagonal: true))
        case .arc:
            return arcSpecs(from: anchor, to: point, horizontalFirst: horizontalFirst)
        }
    }

    /// Straight legs along an already-routed polyline, for paths that come from
    /// the obstacle router rather than from a corner style.
    static func specs(alongPath points: [HorizontalPoint]) -> [BoardTrackSegmentSpec] {
        straightSpecs(points)
    }

    private static func straightSpecs(_ points: [HorizontalPoint]) -> [BoardTrackSegmentSpec] {
        var specs = [BoardTrackSegmentSpec]()
        for pair in zip(points, points.dropFirst()) where key(pair.0) != key(pair.1) {
            specs.append(BoardTrackSegmentSpec(from: pair.0, to: pair.1, center: nil))
        }
        return specs
    }

    /// Rounded corner: a straight leg covering the longer axis's surplus plus a
    /// tangent quarter-arc (radius = shorter axis) that turns the horizontal run
    /// into the vertical one — the curved analog of the 45° elbow. Posture picks
    /// whether the straight leg leads (horizontal-first) or trails.
    private static func arcSpecs(
        from anchor: HorizontalPoint,
        to point: HorizontalPoint,
        horizontalFirst: Bool
    ) -> [BoardTrackSegmentSpec] {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let adx = abs(dx)
        let ady = abs(dy)
        if adx == 0 || ady == 0 {
            return key(anchor) == key(point) ? [] : [BoardTrackSegmentSpec(from: anchor, to: point, center: nil)]
        }
        let sx: Double = dx > 0 ? 1 : -1
        let sy: Double = dy > 0 ? 1 : -1
        let r = min(adx, ady)

        var specs = [BoardTrackSegmentSpec]()
        func straight(_ p: HorizontalPoint, _ q: HorizontalPoint) {
            if key(p) != key(q) {
                specs.append(BoardTrackSegmentSpec(from: p, to: q, center: nil))
            }
        }
        func arc(_ p: HorizontalPoint, _ q: HorizontalPoint, _ center: HorizontalPoint) {
            specs.append(BoardTrackSegmentSpec(from: p, to: q, center: center))
        }

        if horizontalFirst {
            // Leave the anchor horizontally, arrive at the point vertically.
            if adx >= ady {
                let p1 = HorizontalPoint(x: point.x - sx * r, y: anchor.y)
                let center = HorizontalPoint(x: point.x - sx * r, y: anchor.y + sy * r)
                straight(anchor, p1)
                arc(p1, point, center)
            } else {
                let p2 = HorizontalPoint(x: point.x, y: anchor.y + sy * r)
                let center = HorizontalPoint(x: anchor.x, y: anchor.y + sy * r)
                arc(anchor, p2, center)
                straight(p2, point)
            }
        } else {
            // Leave vertically, arrive horizontally.
            if ady >= adx {
                let p1 = HorizontalPoint(x: anchor.x, y: point.y - sy * r)
                let center = HorizontalPoint(x: anchor.x + sx * r, y: point.y - sy * r)
                straight(anchor, p1)
                arc(p1, point, center)
            } else {
                let p2 = HorizontalPoint(x: anchor.x + sx * r, y: point.y)
                let center = HorizontalPoint(x: anchor.x + sx * r, y: anchor.y)
                arc(anchor, p2, center)
                straight(p2, point)
            }
        }
        return specs
    }

    /// Orders an arc's endpoints so `horizonArcPolyline` (which sweeps CCW from
    /// `from`) renders the minor (≤180°) arc — the quarter turn, not its 270°
    /// complement.
    static func orientedArc(
        from p: HorizontalPoint,
        to q: HorizontalPoint,
        center: HorizontalPoint
    ) -> (from: HorizontalPoint, to: HorizontalPoint) {
        let resolved = projectOntoPerpendicularBisector(p, q, center)
        var a0 = atan2(p.y - resolved.y, p.x - resolved.x)
        var a1 = atan2(q.y - resolved.y, q.x - resolved.x)
        if a0 < 0 { a0 += 2 * .pi }
        if a1 < 0 { a1 += 2 * .pi }
        var delta = a1 - a0
        if delta < 0 { delta += 2 * .pi }
        return delta <= .pi ? (p, q) : (q, p)
    }

    /// Orthogonal two-segment route between `anchor` and `point`. When
    /// `horizontalFirst` is true the route runs along x first then y
    /// (the `.xy` posture), otherwise y first then x. Collapses to a single segment
    /// when the points already share a row or column.
    static func path(
        from anchor: HorizontalPoint,
        to point: HorizontalPoint,
        horizontalFirst: Bool,
        diagonal: Bool = false
    ) -> [HorizontalPoint] {
        if diagonal {
            return diagonalPath(from: anchor, to: point, straightFirst: horizontalFirst)
        }
        let bend = horizontalFirst
            ? HorizontalPoint(x: point.x, y: anchor.y)
            : HorizontalPoint(x: anchor.x, y: point.y)
        if key(bend) == key(anchor) || key(bend) == key(point) {
            return [anchor, point]
        }
        return [anchor, bend, point]
    }

    /// A 45° "elbow" route: one axis-aligned leg covering the surplus of the
    /// longer axis, plus a 45° diagonal leg covering the shorter axis in both
    /// directions. `straightFirst` (driven by posture) puts the axis-aligned
    /// leg before the diagonal; otherwise the diagonal leads.
    private static func diagonalPath(
        from anchor: HorizontalPoint,
        to point: HorizontalPoint,
        straightFirst: Bool
    ) -> [HorizontalPoint] {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let adx = abs(dx)
        let ady = abs(dy)
        // Pure horizontal/vertical or perfect diagonal needs no corner.
        if adx == 0 || ady == 0 || adx == ady {
            return [anchor, point]
        }
        let sx: Double = dx > 0 ? 1 : -1
        let sy: Double = dy > 0 ? 1 : -1
        let diag = min(adx, ady)
        let bend: HorizontalPoint
        if straightFirst {
            // Axis-aligned along the longer axis, then diagonal into `point`.
            bend = adx > ady
                ? HorizontalPoint(x: point.x - sx * diag, y: anchor.y)
                : HorizontalPoint(x: anchor.x, y: point.y - sy * diag)
        } else {
            // Diagonal first, then axis-aligned along the longer axis.
            bend = HorizontalPoint(x: anchor.x + sx * diag, y: anchor.y + sy * diag)
        }
        if key(bend) == key(anchor) || key(bend) == key(point) {
            return [anchor, point]
        }
        return [anchor, bend, point]
    }

    /// Corner posture seeded from an existing orthogonal track touching `point`,
    /// so a branch continues in a sensible direction. Returns nil when nothing
    /// touches the point. `true` == horizontal-first (`.xy`).
    static func bendModeHorizontalFirst(
        at point: HorizontalPoint,
        tracks: [HorizontalSegment]
    ) -> Bool? {
        let pointKey = key(point)
        for track in tracks where track.center == nil
        && (key(track.from) == pointKey || key(track.to) == pointKey) {
            let vector = track.to - track.from
            return abs(vector.y) < abs(vector.x)
        }
        return nil
    }

    /// Resolves the net of whatever copper sits under `point`: junction, via,
    /// track (endpoint or body), package pad, or pad hole. Position-based, like
    /// the rest of Horizontal's connectivity model.
    static func netID(
        at point: HorizontalPoint,
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker],
        tracks: [HorizontalSegment],
        packagePads: [HorizontalPolygon],
        packageHoles: [HorizontalHole]
    ) -> String? {
        let pointKey = key(point)

        if let junctionID = junctions.first(where: { key($0.value) == pointKey })?.key,
           let net = junctionNetIDs[junctionID] {
            return net
        }
        for via in vias where via.netID != nil && key(via.position) == pointKey {
            return via.netID
        }
        for track in tracks where track.netID != nil {
            if key(track.from) == pointKey
                || key(track.to) == pointKey
                || pointLiesOnSegment(point, track) {
                return track.netID
            }
        }
        for pad in packagePads where pad.netID != nil {
            if pointInPolygon(point, pad.renderVertices(arcPrecision: 24)) {
                return pad.netID
            }
        }
        for hole in packageHoles where hole.netID != nil && key(hole.position) == pointKey {
            return hole.netID
        }
        return nil
    }

    /// A direct pad connection target under `point`: the serializable pad path
    /// ("package_uuid/pad_uuid", as Track::Connection::serialize
    /// emits) plus the pad center to snap the track endpoint to. Pad polygons
    /// on other copper layers are skipped (nil-layer polygons match any), but
    /// an exact center hit matches layer-agnostically so through-hole pads
    /// connect from either side.
    static func padReference(
        at point: HorizontalPoint,
        layer: Int?,
        packagePads: [HorizontalPolygon],
        padPositions: [String: HorizontalPoint]
    ) -> (path: String, center: HorizontalPoint)? {
        let pointKey = key(point)
        if let exact = padPositions.first(where: { key($0.value) == pointKey }) {
            return (exact.key, exact.value)
        }
        for pad in packagePads {
            if let layer, let padLayer = pad.layer, padLayer != layer {
                continue
            }
            guard pointInPolygon(point, pad.renderVertices(arcPrecision: 24)),
                  let path = padPath(forPolygonID: pad.id),
                  let center = padPositions[path] else {
                continue
            }
            return (path, center)
        }
        return nil
    }

    /// Converts a pad polygon id ("{packageID}/pad/{padID}[/suffix…]") to the
    /// serializable pad path ("packageID/padID", normalized). Returns nil for
    /// ids that are not pad geometry.
    static func padPath(forPolygonID id: String) -> String? {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "pad" else {
            return nil
        }
        return HorizontalCanvasModeSupport.normalizedID(parts[0])
            + "/"
            + HorizontalCanvasModeSupport.normalizedID(parts[2])
    }

    /// The width of an existing track touching `point` (endpoint or body), if
    /// any. Lets a new track branch inherit the width of the track it starts on,
    /// matching "continue at the same width" behavior.
    static func trackWidth(at point: HorizontalPoint, tracks: [HorizontalSegment]) -> Double? {
        let pointKey = key(point)
        for track in tracks where track.width > 0 {
            if key(track.from) == pointKey
                || key(track.to) == pointKey
                || pointLiesOnSegment(point, track) {
                return track.width
            }
        }
        return nil
    }

    /// Default width for a freshly drawn track: the most common width already in
    /// use on the same net, else the board's most common track width, else
    /// `fallback`. (Horizontal does not model per-net-class default widths.)
    static func defaultWidth(
        tracks: [HorizontalSegment],
        net netID: String?,
        fallback: Double = defaultTrackWidth
    ) -> Double {
        if let netID {
            let netWidths = tracks
                .filter { $0.netID.map(HorizontalCanvasModeSupport.normalizedID)
                    == HorizontalCanvasModeSupport.normalizedID(netID) }
                .map(\.width)
            if let width = mostCommonWidth(netWidths) {
                return width
            }
        }
        if let width = mostCommonWidth(tracks.map(\.width)) {
            return width
        }
        return fallback
    }

    // MARK: - Vias

    /// Copper layers a through via spans for a board with `copperLayerCount`
    /// layers: top, inner1…innerN, bottom. Used as the via's connectedLayers so
    /// it renders on every copper layer.
    static func throughViaLayers(copperLayerCount: Int) -> [Int] {
        let innerCount = max(copperLayerCount - 2, 0)
        let innerLayers = innerCount > 0 ? (1...innerCount).map { -$0 } : []
        return [HorizontalBoardLayers.topCopper] + innerLayers + [HorizontalBoardLayers.bottomCopper]
    }

    /// The copper layer to continue routing on after dropping a via. Toggles
    /// between the outer layers (top↔bottom); from an inner layer it surfaces
    /// to top.
    static func oppositeRoutingLayer(_ layer: Int) -> Int {
        layer == HorizontalBoardLayers.topCopper
            ? HorizontalBoardLayers.bottomCopper
            : HorizontalBoardLayers.topCopper
    }

    // MARK: - Geometry helpers

    static func pointLiesOnSegment(_ point: HorizontalPoint, _ segment: HorizontalSegment) -> Bool {
        guard segment.center == nil else {
            return false
        }
        let minX = min(segment.from.x, segment.to.x)
        let maxX = max(segment.from.x, segment.to.x)
        let minY = min(segment.from.y, segment.to.y)
        let maxY = max(segment.from.y, segment.to.y)
        guard point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY else {
            return false
        }
        let line = segment.to - segment.from
        let candidate = point - segment.from
        let cross = line.x * candidate.y - line.y * candidate.x
        return abs(cross) < 1
    }

    static func pointInPolygon(_ point: HorizontalPoint, _ polygon: [HorizontalPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < x {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    // MARK: - Private

    private static func mostCommonWidth(_ widths: [Double]) -> Double? {
        let valid = widths.filter { $0 > 0 }
        guard !valid.isEmpty else {
            return nil
        }
        var counts = [Int64: Int]()
        for width in valid {
            counts[Int64(width.rounded()), default: 0] += 1
        }
        let best = counts.max { lhs, rhs in
            lhs.value < rhs.value || (lhs.value == rhs.value && lhs.key > rhs.key)
        }
        return best.map { Double($0.key) }
    }

    private static func key(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
    }
}
