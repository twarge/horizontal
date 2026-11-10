import Foundation

/// How close a route comes to what it passes on its layer, measured on the
/// copper itself, with the clearance the rules ask of each: the route
/// inspector's Nearest list.
///
/// The router's own index (`HorizontalRouterIndex`) holds octagons, which are
/// right for deciding a collision conservatively and wrong for saying how far
/// apart two things are: a pad's octagon stands well off its corners. This
/// keeps each object's exact shape — a track's centreline and width, a pad's
/// polygon, a via's or hole's disc, an edge of the board — and a coarse grid
/// to find the ones near the route. Built once when a route starts, from the
/// board as it was then; the route's own copper is its net's and is never
/// measured.
final class HorizontalRouteClearanceProbe {
    enum Kind: Hashable {
        case track
        case pad
        /// A pad with a plated hole: the rules' `pad_th`.
        case padThroughHole
        case via
        /// An unplated hole, governed by the copper-to-other rules.
        case hole
        case boardEdge
        case keepout(String)

        /// What the rule tables call it.
        var patchType: HorizontalPatchType {
            switch self {
            case .track: .track
            case .pad: .pad
            case .padThroughHole: .padTH
            case .via: .via
            case .hole: .holeNPTH
            case .boardEdge: .boardEdge
            case .keepout: .other
            }
        }

        var isCopper: Bool {
            switch self {
            case .track, .pad, .padThroughHole, .via: true
            case .hole, .boardEdge, .keepout: false
            }
        }
    }

    enum Shape {
        /// A centreline and half the width around it: a track, or an edge of
        /// the board with none.
        case path([HorizontalPoint], halfWidth: Double)
        case polygon([HorizontalPoint])
        case disc(HorizontalPoint, radius: Double)
    }

    struct Item {
        var kind: Kind
        var id: String
        /// Lowercased.
        var netID: String?
        var label: String
        var layerMin: Int
        var layerMax: Int
        var box: HorizontalRect
        var shape: Shape
    }

    /// One object near the route.
    struct Measurement: Identifiable, Equatable {
        var kind: Kind
        var objectID: String
        var label: String
        var netID: String?
        /// Copper to copper, in nanometres; zero or less where they touch.
        var gap: Double
        /// What the rules ask between the two.
        var required: Double
        /// What Horizon's router keeps beyond that: the rule's routing offset.
        var routingOffset: Double = 0
        /// The rule that asks it.
        var rule: String

        var margin: Double { gap - required }
        /// Legal, but closer than the router would lay it.
        var isInsideRoutingOffset: Bool { margin >= 0 && margin < routingOffset }
        var id: String { objectID }
    }

    private(set) var items: [Item] = []
    private let cellSize: Double
    private var originX = 0.0
    private var originY = 0.0
    private var columns = 1
    private var rows = 1
    private var cells: [[Int32]] = [[]]
    private var oversized: [Int32] = []
    private var stamp: [UInt32] = []
    private var generation: UInt32 = 0

    init(items: [Item], cellSize: Double = 1_000_000) {
        self.items = items
        self.cellSize = cellSize
        buildIndex()
    }

    /// Everything on the board a track can come near: its tracks and net
    /// ties, pads, vias, unplated holes, the edges of its outline, and the
    /// keepouts that bar tracks.
    convenience init(board: HorizontalBoard) {
        self.init(items: Self.items(of: board))
    }

    static func items(of board: HorizontalBoard) -> [Item] {
        let top = HorizontalBoardLayers.topCopper
        let bottom = HorizontalBoardLayers.bottomCopper
        var items = [Item]()

        func box(_ points: [HorizontalPoint], growth: Double) -> HorizontalRect {
            bounds(points, growth: growth)
        }

        for (segments, label) in [(board.tracks, "Track"), (board.netTies, "Net tie")] {
            for track in segments {
                guard let layer = track.layer, HorizontalBoardLayers.isCopper(layer), track.width > 0 else { continue }
                let points = track.pathPoints
                items.append(Item(
                    kind: .track, id: track.id, netID: track.netID?.lowercased(), label: label,
                    layerMin: layer, layerMax: layer,
                    box: box(points, growth: track.width / 2),
                    shape: .path(points, halfWidth: track.width / 2)))
            }
        }

        // A pad whose padstack has a plated hole is a through-hole pad.
        var platedPads = Set<String>()
        for hole in board.packageHoles where hole.plated {
            if let pad = padPrefix(hole.id) {
                platedPads.insert(pad)
            }
        }
        let refdes = Dictionary(board.packages.map { ($0.id.lowercased(), $0.label) }, uniquingKeysWith: { first, _ in first })
        for pad in board.packagePads {
            let points = pad.renderVertices(arcPrecision: 24)
            guard points.count >= 3 else { continue }
            let layerMin: Int
            let layerMax: Int
            if let layer = pad.layer {
                guard HorizontalBoardLayers.isCopper(layer) else { continue }
                layerMin = layer
                layerMax = layer
            } else {
                layerMin = bottom
                layerMax = top
            }
            let prefix = padPrefix(pad.id)
            let isThroughHole = pad.layer == nil || prefix.map(platedPads.contains) == true
            let packageID = pad.id.split(separator: "/").first.map { String($0).lowercased() }
            let padName = pad.metadata["Pad"] ?? String(pad.id.split(separator: "/").last ?? "")
            let owner = packageID.flatMap { refdes[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            items.append(Item(
                kind: isThroughHole ? .padThroughHole : .pad,
                id: pad.id, netID: pad.netID?.lowercased(),
                label: "Pad " + (owner.map { "\($0).\(padName)" } ?? padName),
                layerMin: layerMin, layerMax: layerMax,
                box: box(points, growth: 0), shape: .polygon(points)))
        }

        let throughLayers = BoardTrackRouting.throughViaLayers(copperLayerCount: max(board.copperLayerCount, 2))
        for via in board.vias where via.size > 0 {
            let layers = via.connectedLayers.isEmpty ? throughLayers : via.connectedLayers
            guard let high = layers.max(), let low = layers.min() else { continue }
            let radius = via.size / 2
            items.append(Item(
                kind: .via, id: via.id, netID: via.netID?.lowercased(), label: "Via",
                layerMin: low, layerMax: high,
                box: bounds([via.position], growth: radius),
                shape: .disc(via.position, radius: radius)))
        }

        for hole in board.holes + board.packageHoles where !hole.plated && hole.diameter > 0 {
            let shape: Shape
            if hole.shape == .slot, hole.effectiveLength > hole.diameter {
                shape = .polygon(hole.outlinePoints(precision: 16))
            } else {
                shape = .disc(hole.position, radius: hole.diameter / 2)
            }
            items.append(Item(
                kind: .hole, id: hole.id, netID: nil, label: "Hole",
                layerMin: bottom, layerMax: top,
                box: bounds([hole.position], growth: hole.effectiveLength / 2),
                shape: shape))
        }

        for polygon in board.polygons where polygon.layer == HorizontalBoardLayers.outline {
            let points = polygon.renderVertices(arcPrecision: 24)
            guard points.count >= 2 else { continue }
            for index in points.indices {
                let edge = [points[index], points[(index + 1) % points.count]]
                items.append(Item(
                    kind: .boardEdge, id: "\(polygon.id)/edge/\(index)", netID: nil, label: "Board edge",
                    layerMin: bottom, layerMax: top,
                    box: box(edge, growth: 0), shape: .path(edge, halfWidth: 0)))
            }
        }

        for keepout in board.keepouts
        where keepout.copperPatchTypes.isEmpty || keepout.copperPatchTypes.contains("track") {
            let points = keepout.polygon.renderVertices(arcPrecision: 24)
            guard points.count >= 3 else { continue }
            let layer = keepout.polygon.layer ?? top
            items.append(Item(
                kind: .keepout(keepout.keepoutClass), id: keepout.id, netID: nil,
                label: keepout.keepoutClass.isEmpty ? "Keepout" : "Keepout \(keepout.keepoutClass)",
                layerMin: keepout.allCopperLayers ? bottom : layer,
                layerMax: keepout.allCopperLayers ? top : layer,
                box: box(points, growth: 0), shape: .polygon(points)))
        }
        return items
    }

    /// The box around `points`, grown on every side. Not
    /// `HorizontalRect.expanded`, which leaves a box with no area as it is:
    /// a straight track's, or a via's.
    static func bounds(_ points: [HorizontalPoint], growth: Double) -> HorizontalRect {
        let box = HorizontalRect(points: points)
        let low = HorizontalPoint(x: box.minX - growth, y: box.minY - growth)
        let high = HorizontalPoint(x: box.maxX + growth, y: box.maxY + growth)
        return HorizontalRect(points: [low, high])
    }

    /// "package/pad/pad-id" of a pad's polygon or hole id.
    private static func padPrefix(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: "/")
        guard parts.count >= 3, parts[1] == "pad" else { return nil }
        return parts[0...2].joined(separator: "/")
    }

    /// The objects on `layer` within `radius` of a track of `width` along
    /// `route` (its polylines; a single point is a route about to start), the
    /// one with the least margin of each kind, least margin first.
    ///
    /// Copper on the route's own `net` is passed over; it may touch. So is
    /// whatever lies under one of `connecting` — the copper the route starts
    /// from and, while it has no net, what its next click would join — which
    /// it touches by design. `required` gives the clearance the rules ask
    /// between the route and an object, the routing offset the router keeps
    /// beyond it, and the rule that asks it.
    func nearest(
        route: [[HorizontalPoint]],
        width: Double,
        layer: Int,
        net: String?,
        connecting: [HorizontalPoint],
        radius: Double,
        required: (Item) -> (clearance: Double, routingOffset: Double, rule: String)
    ) -> [Measurement] {
        let points = route.flatMap { $0 }
        guard !points.isEmpty, !items.isEmpty else {
            return []
        }
        var segments = [(HorizontalPoint, HorizontalPoint)]()
        for polyline in route {
            if polyline.count == 1 {
                segments.append((polyline[0], polyline[0]))
            }
            for index in polyline.indices.dropLast() {
                segments.append((polyline[index], polyline[index + 1]))
            }
        }
        let halfWidth = width / 2
        let net = net?.lowercased()
        let query = Self.bounds(points, growth: radius + halfWidth)

        var best = [Kind: Measurement]()
        forEachItem(overlapping: query, on: layer) { item in
            if let net, item.kind.isCopper, item.netID == net {
                return
            }
            if connecting.contains(where: { Self.distance(from: [($0, $0)], to: item.shape) <= 0 }) {
                return
            }
            let gap = Self.distance(from: segments, to: item.shape) - halfWidth
            guard gap <= radius else {
                return
            }
            let rule = required(item)
            let measurement = Measurement(
                kind: item.kind, objectID: item.id, label: item.label, netID: item.netID,
                gap: gap, required: rule.clearance, routingOffset: rule.routingOffset, rule: rule.rule)
            if let current = best[item.kind] {
                guard measurement.margin < current.margin
                        || (measurement.margin == current.margin && measurement.objectID < current.objectID) else {
                    return
                }
            }
            best[item.kind] = measurement
        }
        return best.values.sorted { lhs, rhs in
            lhs.margin != rhs.margin ? lhs.margin < rhs.margin : lhs.objectID < rhs.objectID
        }
    }

    // MARK: - Index

    private func buildIndex() {
        stamp = [UInt32](repeating: 0, count: items.count)
        guard !items.isEmpty else { return }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for item in items {
            minX = min(minX, item.box.minX)
            minY = min(minY, item.box.minY)
            maxX = max(maxX, item.box.maxX)
            maxY = max(maxY, item.box.maxY)
        }
        originX = minX
        originY = minY
        columns = max(1, min(1024, Int(((maxX - minX) / cellSize).rounded(.up)) + 1))
        rows = max(1, min(1024, Int(((maxY - minY) / cellSize).rounded(.up)) + 1))
        cells = [[Int32]](repeating: [], count: columns * rows)
        for (index, item) in items.enumerated() {
            let range = cellRange(item.box)
            if (range.maxColumn - range.minColumn + 1) * (range.maxRow - range.minRow + 1) > 4096 {
                oversized.append(Int32(index))
                continue
            }
            for row in range.minRow...range.maxRow {
                for column in range.minColumn...range.maxColumn {
                    cells[row * columns + column].append(Int32(index))
                }
            }
        }
    }

    private func cellRange(_ box: HorizontalRect) -> (minColumn: Int, maxColumn: Int, minRow: Int, maxRow: Int) {
        func column(_ x: Double) -> Int { min(max(Int(((x - originX) / cellSize).rounded(.down)), 0), columns - 1) }
        func row(_ y: Double) -> Int { min(max(Int(((y - originY) / cellSize).rounded(.down)), 0), rows - 1) }
        return (column(box.minX), column(box.maxX), row(box.minY), row(box.maxY))
    }

    private func forEachItem(overlapping box: HorizontalRect, on layer: Int, _ body: (Item) -> Void) {
        generation &+= 1
        if generation == 0 {
            stamp = [UInt32](repeating: 0, count: items.count)
            generation = 1
        }
        let range = cellRange(box)
        var candidates = oversized
        for row in range.minRow...range.maxRow {
            for column in range.minColumn...range.maxColumn {
                candidates.append(contentsOf: cells[row * columns + column])
            }
        }
        for candidate in candidates {
            let index = Int(candidate)
            guard stamp[index] != generation else { continue }
            stamp[index] = generation
            let item = items[index]
            guard item.layerMin <= layer, layer <= item.layerMax,
                  item.box.maxX >= box.minX, item.box.minX <= box.maxX,
                  item.box.maxY >= box.minY, item.box.minY <= box.maxY else { continue }
            body(item)
        }
    }

    // MARK: - Geometry

    /// The least distance from the centrelines `segments` to `shape`'s copper;
    /// zero where they touch or one lies inside the other.
    static func distance(from segments: [(HorizontalPoint, HorizontalPoint)], to shape: Shape) -> Double {
        var least = Double.greatestFiniteMagnitude
        switch shape {
        case .path(let points, let halfWidth):
            let path = points.count == 1 ? [(points[0], points[0])] : zip(points, points.dropFirst()).map { ($0, $1) }
            for (a, b) in segments {
                for (c, d) in path {
                    least = min(least, segmentDistance(a, b, c, d))
                }
            }
            return max(least - halfWidth, 0)
        case .disc(let center, let radius):
            for (a, b) in segments {
                least = min(least, pointSegmentDistance(center, a, b))
            }
            return max(least - radius, 0)
        case .polygon(let points):
            for (a, b) in segments where contains(points, a) || contains(points, b) {
                return 0
            }
            for (a, b) in segments {
                for index in points.indices {
                    least = min(least, segmentDistance(a, b, points[index], points[(index + 1) % points.count]))
                    if least == 0 {
                        return 0
                    }
                }
            }
            return least
        }
    }

    static func pointSegmentDistance(_ p: HorizontalPoint, _ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func segmentDistance(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> Double {
        if segmentsIntersect(a, b, c, d) {
            return 0
        }
        return min(
            pointSegmentDistance(a, c, d), pointSegmentDistance(b, c, d),
            pointSegmentDistance(c, a, b), pointSegmentDistance(d, a, b))
    }

    private static func segmentsIntersect(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> Bool {
        func cross(_ o: HorizontalPoint, _ p: HorizontalPoint, _ q: HorizontalPoint) -> Double {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        let d1 = cross(c, d, a)
        let d2 = cross(c, d, b)
        let d3 = cross(a, b, c)
        let d4 = cross(a, b, d)
        // Collinear and overlapping counts too, but pointSegmentDistance
        // answers that case already (it gives zero).
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    private static func contains(_ polygon: [HorizontalPoint], _ point: HorizontalPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y),
               point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
