import Foundation

/// One thing on the board that copper has to keep clear of, with the exact
/// shape the clearance check measures: a track's centreline and width, a pad's
/// polygon, a via's or hole's disc, a fill's paths, an edge of the outline.
struct HorizontalBoardItem {
    enum Kind: Hashable {
        case track
        case netTie
        case pad
        /// A pad with a plated hole: the rules' `pad_th`.
        case padThroughHole
        case via
        case plane
        /// An unplated hole.
        case hole
        case boardEdge
        case keepout(String)
        /// A silkscreen line, arc or text: listed, never a clearance partner.
        case silkscreen

        var objectClass: HorizontalRouterClearances.ObjectClass? {
            switch self {
            case .track: .track
            case .netTie: .netTie
            case .pad: .pad
            case .padThroughHole: .padThroughHole
            case .via: .via
            case .plane: .plane
            case .hole: .holeUnplated
            case .boardEdge: .boardEdge
            case .keepout(let name): .keepout(name)
            case .silkscreen: nil
            }
        }

        var isCopper: Bool { objectClass?.isCopper ?? false }

        /// What a reply calls it; the rule tables' word where they have one.
        var name: String {
            switch self {
            case .track: "track"
            case .netTie: "net_tie"
            case .pad: "pad"
            case .padThroughHole: "pad_th"
            case .via: "via"
            case .plane: "plane"
            case .hole: "hole_npth"
            case .boardEdge: "board_edge"
            case .keepout: "keepout"
            case .silkscreen: "silkscreen"
            }
        }
    }

    enum Shape {
        /// A centreline and half the width around it.
        case path([HorizontalPoint], halfWidth: Double)
        case polygon([HorizontalPoint])
        case disc(HorizontalPoint, radius: Double)
        /// An outer path and the holes in it, filled even-odd: a plane's fragment.
        case region([[HorizontalPoint]])
    }

    var kind: Kind
    /// The track's, via's, plane's, hole's or keepout's id; a pad's
    /// "package/pad/pad" path, as a check finding names it; an outline edge's
    /// "polygon/edge/n".
    var id: String
    /// Lowercased.
    var netID: String?
    /// "Track", "Pad U3.4", "Via", "Plane", "Hole", "Board edge".
    var label: String
    /// The copper layers it is on, bottom-most first; a silkscreen item's one layer.
    var layerMin: Int
    var layerMax: Int
    var box: HorizontalRect
    var shape: Shape
    /// The board package a pad, a package's hole or its keepout belongs to, lowercased.
    var packageID: String?
    /// A keepout's `copper_patch_types`: the kinds of copper it bars, every
    /// kind when empty.
    var keepoutPatchTypes: [String] = []

    func isOn(_ layer: Int) -> Bool {
        layerMin <= layer && layer <= layerMax
    }
}

/// Every item of a board, and a coarse grid to find the ones near a place.
///
/// The shapes are the ones `HorizontalRouteClearanceProbe` and the clearance
/// check use, so a gap measured here is the gap `check` reports; this adds the
/// planes' fills and, on request, the silkscreen, and measures any two shapes
/// against each other rather than a route against the rest.
struct HorizontalBoardItems {
    private(set) var items: [HorizontalBoardItem] = []
    private let cellSize: Double
    private var originX = 0.0
    private var originY = 0.0
    private var columns = 1
    private var rows = 1
    private var cells: [[Int32]] = [[]]
    private var oversized: [Int32] = []

    /// The copper layers of the board, top first.
    let copperLayers: [Int]

    init(items: [HorizontalBoardItem], copperLayers: [Int], cellSize: Double = 500_000) {
        self.items = items
        self.copperLayers = copperLayers
        self.cellSize = cellSize
        buildIndex()
    }

    init(board: HorizontalBoard, silkscreen: Bool = false) {
        self.init(items: Self.items(of: board, silkscreen: silkscreen), copperLayers: Self.copperLayers(of: board))
    }

    static func copperLayers(of board: HorizontalBoard) -> [Int] {
        let inner = max(board.copperLayerCount - 2, 0)
        return [HorizontalBoardLayers.topCopper] + (inner > 0 ? (1...inner).map { -$0 } : []) + [HorizontalBoardLayers.bottomCopper]
    }

    /// As the clearance check gathers them: a pad's polygons as the pour
    /// tessellates them, a plane's fragments one item each.
    static func items(of board: HorizontalBoard, silkscreen: Bool = false) -> [HorizontalBoardItem] {
        let top = HorizontalBoardLayers.topCopper
        let bottom = HorizontalBoardLayers.bottomCopper
        let arcPrecision = 48
        var items = [HorizontalBoardItem]()
        let bounds = HorizontalRouteClearanceProbe.bounds

        for (segments, kind, label) in [(board.tracks, HorizontalBoardItem.Kind.track, "Track"), (board.netTies, .netTie, "Net tie")] {
            for track in segments {
                guard let layer = track.layer, HorizontalBoardLayers.isCopper(layer), track.width > 0 else { continue }
                let points = track.pathPoints
                items.append(HorizontalBoardItem(
                    kind: kind, id: track.id, netID: track.netID?.lowercased(), label: label,
                    layerMin: layer, layerMax: layer, box: bounds(points, track.width / 2),
                    shape: .path(points, halfWidth: track.width / 2)))
            }
        }

        var platedPads = Set<String>()
        for hole in board.packageHoles where hole.plated {
            if let pad = padPrefix(hole.id) { platedPads.insert(pad) }
        }
        let refdes = Dictionary(board.packages.map { ($0.id.lowercased(), $0.label) }, uniquingKeysWith: { first, _ in first })
        func owner(_ id: String) -> String? {
            id.split(separator: "/").first.map { String($0).lowercased() }
        }
        for pad in board.packagePads {
            let points = pad.renderVertices(arcPrecision: arcPrecision)
            guard points.count >= 3 else { continue }
            let layerMin: Int, layerMax: Int
            if let layer = pad.layer {
                guard HorizontalBoardLayers.isCopper(layer) else { continue }
                (layerMin, layerMax) = (layer, layer)
            } else {
                (layerMin, layerMax) = (bottom, top)
            }
            let prefix = padPrefix(pad.id)
            let package = owner(pad.id)
            let name = pad.metadata["Pad"] ?? String(pad.id.split(separator: "/").dropFirst(2).first ?? "")
            let part = package.flatMap { refdes[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            items.append(HorizontalBoardItem(
                kind: pad.layer == nil || prefix.map(platedPads.contains) == true ? .padThroughHole : .pad,
                id: prefix ?? pad.id.lowercased(), netID: pad.netID?.lowercased(),
                label: "Pad " + (part.map { "\($0).\(name)" } ?? name),
                layerMin: layerMin, layerMax: layerMax, box: bounds(points, 0), shape: .polygon(points),
                packageID: package))
        }

        for via in board.vias where via.size > 0 {
            let layers = via.connectedLayers.isEmpty ? [top, bottom] : via.connectedLayers
            guard let high = layers.max(), let low = layers.min() else { continue }
            items.append(HorizontalBoardItem(
                kind: .via, id: via.id, netID: via.netID?.lowercased(), label: "Via",
                layerMin: low, layerMax: high, box: bounds([via.position], via.size / 2),
                shape: .disc(via.position, radius: via.size / 2)))
        }

        for (holes, inPackage) in [(board.holes, false), (board.packageHoles, true)] {
            for hole in holes where !hole.plated && hole.diameter > 0 {
                let radius = hole.diameter / 2
                let shape: HorizontalBoardItem.Shape
                if hole.shape == .slot, hole.effectiveLength > hole.diameter {
                    let transform = HorizontalPlacementTransform(shift: hole.position, angle: hole.angle, mirrored: false)
                    let offset = hole.effectiveLength / 2 - radius
                    shape = .path([transform.applying(to: HorizontalPoint(x: -offset, y: 0)),
                                   transform.applying(to: HorizontalPoint(x: offset, y: 0))], halfWidth: radius)
                } else {
                    shape = .disc(hole.position, radius: radius)
                }
                let package = inPackage ? owner(hole.id) : nil
                let part = package.flatMap { refdes[$0] }.flatMap { $0.isEmpty ? nil : $0 }
                items.append(HorizontalBoardItem(
                    kind: .hole, id: hole.id, netID: nil, label: part.map { "Hole \($0)" } ?? "Hole",
                    layerMin: bottom, layerMax: top, box: bounds([hole.position], hole.effectiveLength / 2),
                    shape: shape, packageID: package))
            }
        }

        for plane in board.planes {
            guard let layer = plane.layer, HorizontalBoardLayers.isCopper(layer) else { continue }
            for (index, fragment) in plane.fragments.enumerated() {
                guard let outer = fragment.paths.first, outer.count >= 3 else { continue }
                items.append(HorizontalBoardItem(
                    kind: .plane, id: plane.id, netID: plane.netID?.lowercased(),
                    label: plane.fragments.count > 1 ? "Plane (fragment \(index + 1))" : "Plane",
                    layerMin: layer, layerMax: layer, box: bounds(outer, 0), shape: .region(fragment.paths)))
            }
        }

        for polygon in board.polygons where polygon.layer == HorizontalBoardLayers.outline {
            let points = polygon.renderVertices(arcPrecision: arcPrecision)
            guard points.count >= 2 else { continue }
            for index in points.indices {
                let edge = [points[index], points[(index + 1) % points.count]]
                items.append(HorizontalBoardItem(
                    kind: .boardEdge, id: "\(polygon.id)/edge/\(index)", netID: nil, label: "Board edge",
                    layerMin: bottom, layerMax: top, box: bounds(edge, 0), shape: .path(edge, halfWidth: 0)))
            }
        }

        for keepout in board.keepouts {
            let points = keepout.polygon.renderVertices(arcPrecision: arcPrecision)
            guard points.count >= 3 else { continue }
            let layer = keepout.polygon.layer ?? top
            guard keepout.allCopperLayers || HorizontalBoardLayers.isCopper(layer) else { continue }
            let package = keepout.id.contains("/keepout/") ? owner(keepout.id) : nil
            items.append(HorizontalBoardItem(
                kind: .keepout(keepout.keepoutClass), id: keepout.id, netID: nil,
                label: keepout.keepoutClass.isEmpty ? "Keepout" : "Keepout \(keepout.keepoutClass)",
                layerMin: keepout.allCopperLayers ? bottom : layer, layerMax: keepout.allCopperLayers ? top : layer,
                box: bounds(points, 0), shape: .polygon(points), packageID: package,
                keepoutPatchTypes: keepout.copperPatchTypes))
        }

        guard silkscreen else { return items }
        let hidden = Set(board.packages.filter(\.omitSilkscreen).map { $0.id.lowercased() })
        for (segments, owned) in [(board.lines, false), (board.packageLines, true)] {
            for line in segments {
                guard let layer = line.layer, HorizontalBoardLayers.isSilkscreen(layer) else { continue }
                let package = owned ? owner(line.id) : nil
                if let package, hidden.contains(package) { continue }
                let points = line.pathPoints
                items.append(HorizontalBoardItem(
                    kind: .silkscreen, id: line.id, netID: nil, label: "Silkscreen line",
                    layerMin: layer, layerMax: layer, box: bounds(points, line.width / 2),
                    shape: .path(points, halfWidth: line.width / 2), packageID: package))
            }
        }
        for (arcs, owned) in [(board.arcs, false), (board.packageArcs, true)] {
            for arc in arcs {
                guard let layer = arc.layer, HorizontalBoardLayers.isSilkscreen(layer) else { continue }
                let package = owned ? owner(arc.id) : nil
                if let package, hidden.contains(package) { continue }
                let points = arc.polyline()
                items.append(HorizontalBoardItem(
                    kind: .silkscreen, id: arc.id, netID: nil, label: "Silkscreen arc",
                    layerMin: layer, layerMax: layer, box: bounds(points, arc.width / 2),
                    shape: .path(points, halfWidth: arc.width / 2), packageID: package))
            }
        }
        for text in HorizontalBoardTextExtents.drawnTexts(of: board) {
            guard let layer = text.text.layer, HorizontalBoardLayers.isSilkscreen(layer) else { continue }
            let extent = HorizontalBoardTextExtents.extent(of: text.text)
            items.append(HorizontalBoardItem(
                kind: .silkscreen, id: text.text.id, netID: nil, label: "Silkscreen text \(text.text.text)",
                layerMin: layer, layerMax: layer, box: extent.box, shape: .polygon(extent.corners),
                packageID: text.packageID))
        }
        return items
    }

    /// "package/pad/pad-id" of a pad's polygon or hole id.
    static func padPrefix(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: "/")
        guard parts.count >= 3, parts[1] == "pad" else { return nil }
        return parts[0...2].joined(separator: "/")
    }

    // MARK: - Index

    private mutating func buildIndex() {
        guard !items.isEmpty else { return }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
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
            if (range.maxColumn - range.minColumn + 1) * (range.maxRow - range.minRow + 1) > 1024 {
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

    /// The indices of the items whose box meets `box`, in order, each once.
    func indices(overlapping box: HorizontalRect) -> [Int] {
        guard !items.isEmpty else { return [] }
        let range = cellRange(box)
        var found = Set<Int32>(oversized)
        for row in range.minRow...range.maxRow {
            for column in range.minColumn...range.maxColumn {
                found.formUnion(cells[row * columns + column])
            }
        }
        return found.map(Int.init).filter { index in
            let other = items[index].box
            return other.maxX >= box.minX && other.minX <= box.maxX && other.maxY >= box.minY && other.minY <= box.maxY
        }.sorted()
    }

    /// Calls `body` with the index of every item whose cells `box` reaches:
    /// a superset of the items near it, and an item in several cells more
    /// than once. For the searches, which ask this a hundred thousand times
    /// and test each item's own box themselves.
    func visit(near box: HorizontalRect, _ body: (Int) -> Void) {
        guard !items.isEmpty else { return }
        for index in oversized { body(Int(index)) }
        let range = cellRange(box)
        for row in range.minRow...range.maxRow {
            for column in range.minColumn...range.maxColumn {
                for index in cells[row * columns + column] { body(Int(index)) }
            }
        }
    }

    // MARK: - Rules

    /// What the rules ask between two items on a layer both are on, as the
    /// clearance check asks it, and the rule that says so; nil where they ask
    /// nothing: copper of one net, two pieces of copper on no net, two things
    /// that are not copper, a keepout that does not bar that kind of copper.
    static func required(
        _ a: HorizontalBoardItem, _ b: HorizontalBoardItem, layer: Int, rules: HorizontalBoardRules,
        tiedNets: Set<String> = []
    ) -> (clearance: Double, kind: HorizontalBoardRuleKind, ruleID: String?)? {
        guard let classA = a.kind.objectClass, let classB = b.kind.objectClass else { return nil }
        func id(_ id: String) -> String? { id.isEmpty ? nil : id }
        if case .keepout(let name) = a.kind {
            guard classB.isCopper else { return nil }
            // A keepout bars the kinds of copper it lists and no other, as
            // the clearance check and the pour read it: one that lists none
            // bars nothing.
            guard a.keepoutPatchTypes.contains(classB.patchType.jsonString) else { return nil }
            let rule = rules.clearanceCopperKeepout(net: b.netID, keepoutClass: name)
            return (Double(rule.clearance(classB.patchType)), .clearanceCopperKeepout, id(rule.id))
        }
        if case .keepout = b.kind { return required(b, a, layer: layer, rules: rules, tiedNets: tiedNets) }
        switch (classA.isCopper, classB.isCopper) {
        case (true, true):
            guard a.netID != b.netID else { return nil }
            if a.kind == .netTie || b.kind == .netTie, let netA = a.netID, let netB = b.netID,
               tiedNets.contains(HorizontalBoardClearanceCheck.netPairKey(netA, netB)) {
                return nil
            }
            let rule = rules.clearanceCopper(net1: a.netID, net2: b.netID, layer: layer)
            return (Double(rule.clearance(classA.patchType, classB.patchType)), .clearanceCopper, id(rule.id))
        case (true, false):
            let rule = rules.clearanceCopperOther(net: a.netID, layer: layer)
            return (Double(rule.clearance(copper: classA.patchType, nonCopper: classB.patchType)), .clearanceCopperOther, id(rule.id))
        case (false, true):
            return required(b, a, layer: layer, rules: rules, tiedNets: tiedNets)
        case (false, false):
            return nil
        }
    }
}

// MARK: - Geometry

extension HorizontalBoardItem.Shape {
    /// The edges the shape is measured from, and how far its copper reaches
    /// beyond them.
    var edges: (segments: [(HorizontalPoint, HorizontalPoint)], radius: Double) {
        func ring(_ points: [HorizontalPoint]) -> [(HorizontalPoint, HorizontalPoint)] {
            points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
        }
        switch self {
        case .path(let points, let halfWidth):
            return (points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst())), halfWidth)
        case .disc(let center, let radius):
            return ([(center, center)], radius)
        case .polygon(let points):
            return (ring(points), 0)
        case .region(let paths):
            return (paths.flatMap(ring), 0)
        }
    }

    /// Whether `point` is inside the shape's filled area; a path and a disc
    /// have none beyond what their radius gives.
    func encloses(_ point: HorizontalPoint) -> Bool {
        switch self {
        case .path, .disc:
            return false
        case .polygon(let points):
            return HorizontalBoardOutlines.contains(point, in: points)
        case .region(let paths):
            return paths.reduce(false) { $0 != HorizontalBoardOutlines.contains(point, in: $1) }
        }
    }

    /// A point of the shape's own copper.
    var anchor: HorizontalPoint? {
        switch self {
        case .path(let points, _): points.first
        case .disc(let center, _): center
        case .polygon(let points): points.first
        case .region(let paths): paths.first?.first
        }
    }

    /// The shape moved by `offset`.
    func translated(by offset: HorizontalPoint) -> HorizontalBoardItem.Shape {
        func moved(_ point: HorizontalPoint) -> HorizontalPoint {
            HorizontalPoint(x: point.x + offset.x, y: point.y + offset.y)
        }
        switch self {
        case .path(let points, let halfWidth): return .path(points.map(moved), halfWidth: halfWidth)
        case .disc(let center, let radius): return .disc(moved(center), radius: radius)
        case .polygon(let points): return .polygon(points.map(moved))
        case .region(let paths): return .region(paths.map { $0.map(moved) })
        }
    }
}

/// The gap between two shapes: copper to copper, zero where they touch or one
/// lies in the other, with the nearest point of each.
struct HorizontalShapeGap {
    var distance: Double
    var first: HorizontalPoint
    var second: HorizontalPoint

    var location: HorizontalPoint {
        HorizontalPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    /// Nil when the two are further apart than `limit`, which lets a caller
    /// with many pairs skip the far ones cheaply.
    static func between(_ a: HorizontalBoardItem.Shape, _ b: HorizontalBoardItem.Shape,
                        limit: Double = .greatestFiniteMagnitude) -> HorizontalShapeGap? {
        if let point = b.anchor, a.encloses(point) { return HorizontalShapeGap(distance: 0, first: point, second: point) }
        if let point = a.anchor, b.encloses(point) { return HorizontalShapeGap(distance: 0, first: point, second: point) }
        let (edgesA, radiusA) = a.edges
        let (edgesB, radiusB) = b.edges
        var least = Double.greatestFiniteMagnitude
        var nearest = (HorizontalPoint.zero, HorizontalPoint.zero)
        for (p, q) in edgesA {
            for (r, s) in edgesB {
                let (distance, onA, onB) = closest(p, q, r, s)
                if distance < least {
                    least = distance
                    nearest = (onA, onB)
                    if distance == 0 { break }
                }
            }
            if least == 0 { break }
        }
        guard least < .greatestFiniteMagnitude else { return nil }
        let gap = max(least - radiusA - radiusB, 0)
        guard gap <= limit else { return nil }
        // The nearest points of the copper, not of the centrelines.
        let span = least
        func toward(_ from: HorizontalPoint, _ to: HorizontalPoint, _ amount: Double) -> HorizontalPoint {
            guard span > 0 else { return from }
            let t = min(amount / span, 1)
            return HorizontalPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
        return HorizontalShapeGap(distance: gap, first: toward(nearest.0, nearest.1, radiusA),
                                  second: toward(nearest.1, nearest.0, radiusB))
    }

    /// The least distance between segments pq and rs, and the point of each
    /// it is measured at.
    static func closest(_ p: HorizontalPoint, _ q: HorizontalPoint, _ r: HorizontalPoint, _ s: HorizontalPoint)
        -> (Double, HorizontalPoint, HorizontalPoint) {
        func cross(_ o: HorizontalPoint, _ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(r, s, p), d2 = cross(r, s, q), d3 = cross(p, q, r), d4 = cross(p, q, s)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            let t = d1 / (d1 - d2)
            let point = HorizontalPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
            return (0, point, point)
        }
        func project(_ point: HorizontalPoint, _ a: HorizontalPoint, _ b: HorizontalPoint) -> HorizontalPoint {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return a }
            let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
            return HorizontalPoint(x: a.x + t * dx, y: a.y + t * dy)
        }
        var best = (Double.greatestFiniteMagnitude, p, r)
        for (onA, onB) in [(p, project(p, r, s)), (q, project(q, r, s)), (project(r, p, q), r), (project(s, p, q), s)] {
            let distance = hypot(onA.x - onB.x, onA.y - onB.y)
            if distance < best.0 { best = (distance, onA, onB) }
        }
        return best
    }
}
