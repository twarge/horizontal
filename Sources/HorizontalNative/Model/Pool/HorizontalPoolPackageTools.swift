import Foundation

// MARK: - Renumber pads

/// Horizon's renumber-pads window: pads are ordered along an axis (rows or
/// columns, in either direction) or around the package's centre, then named
/// `prefix + n` counting from `start` by `step`.
struct HorizontalRenumberPadsSettings: Hashable {
    enum Origin: String, CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight

        var displayName: String {
            switch self {
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
    }

    var circular = false
    /// Axis mode: x varies fastest (rows) when true, y fastest (columns) otherwise.
    var xFirst = true
    var right = true
    var down = true
    var origin: Origin = .topLeft
    var clockwise = true
    var prefix = ""
    var start = 1
    var step = 1
}

extension HorizontalPoolPackage {
    /// `RenumberPadsWindow::renumber`: the order the pads take.
    static func renumberOrder(of pads: [HorizontalPad], settings: HorizontalRenumberPadsSettings) -> [HorizontalPad] {
        guard !pads.isEmpty else {
            return []
        }
        var sorted = pads
        if !settings.circular {
            func stableSort(byX: Bool, ascending: Bool) {
                sorted = sorted.enumerated().sorted { lhs, rhs in
                    let a = byX ? lhs.element.placement.shift.x : lhs.element.placement.shift.y
                    let b = byX ? rhs.element.placement.shift.x : rhs.element.placement.shift.y
                    if a == b {
                        return lhs.offset < rhs.offset
                    }
                    return ascending ? a < b : a > b
                }.map(\.element)
            }
            // The last sort is the primary key, as upstream's stable sorts.
            if settings.xFirst {
                stableSort(byX: true, ascending: settings.right)
                stableSort(byX: false, ascending: !settings.down)
            } else {
                stableSort(byX: false, ascending: !settings.down)
                stableSort(byX: true, ascending: settings.right)
            }
            return sorted
        }

        var low = sorted[0].placement.shift
        var high = low
        for pad in sorted {
            low = HorizontalPoint(x: min(low.x, pad.placement.shift.x), y: min(low.y, pad.placement.shift.y))
            high = HorizontalPoint(x: max(high.x, pad.placement.shift.x), y: max(high.y, pad.placement.shift.y))
        }
        let center = HorizontalPoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2)
        let lowRelative = low - center
        let highRelative = high - center
        func angle(_ point: HorizontalPoint) -> Double {
            var value = atan2(point.y, point.x)
            if value < 0 {
                value += .pi * 2
            }
            return value
        }
        var offset: Double
        switch settings.origin {
        case .topLeft: offset = angle(HorizontalPoint(x: lowRelative.x, y: highRelative.y))
        case .topRight: offset = angle(HorizontalPoint(x: highRelative.x, y: highRelative.y))
        case .bottomLeft: offset = angle(HorizontalPoint(x: lowRelative.x, y: lowRelative.y))
        case .bottomRight: offset = angle(HorizontalPoint(x: highRelative.x, y: lowRelative.y))
        }
        // Compensate for rounding, as upstream does.
        offset += settings.clockwise ? 1e-3 : -1e-3
        func relative(_ pad: HorizontalPad) -> Double {
            var value = angle(pad.placement.shift - center) - offset
            while value < 0 {
                value += .pi * 2
            }
            while value >= .pi * 2 {
                value -= .pi * 2
            }
            return value
        }
        return sorted.sorted { lhs, rhs in
            settings.clockwise ? relative(rhs) < relative(lhs) : relative(lhs) < relative(rhs)
        }
    }

    /// The package with `padIDs` (all pads when nil) renamed in the settings'
    /// order.
    func renumberingPads(ids padIDs: Set<String>? = nil, settings: HorizontalRenumberPadsSettings) -> HorizontalPoolPackage {
        let chosen = sortedPads.filter { pad in
            padIDs.map { $0.contains(pad.id.lowercased()) } ?? true
        }
        var package = self
        var number = settings.start
        for pad in Self.renumberOrder(of: chosen, settings: settings) {
            package.pads[pad.id]?.name = settings.prefix + String(number)
            number += max(settings.step, 1)
        }
        return package
    }
}

// MARK: - Courtyard

extension HorizontalPoolPackage {
    /// `ToolGenerateCourtyard`: a rectangle around the pads' copper and the
    /// package-layer polygons (always spanning the origin, as upstream's
    /// zero-initialised bounds do), written as the courtyard polygon —
    /// replacing an existing one. Nil when there is nothing to enclose.
    func generatingCourtyard(context: HorizontalPoolEditorContext) -> HorizontalPoolPackage? {
        let board = makeBoard(context: context)
        var low = HorizontalPoint.zero
        var high = HorizontalPoint.zero
        func include(_ point: HorizontalPoint) {
            low = HorizontalPoint(x: min(low.x, point.x), y: min(low.y, point.y))
            high = HorizontalPoint(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        for polygon in board.packagePads where polygon.layer.map(HorizontalBoardLayers.isCopper) == true {
            polygon.vertices.forEach(include)
        }
        for polygon in drawing.polygons.values where polygon.layer == HorizontalBoardLayers.topPackage {
            polygon.vertices.map(\.position).forEach(include)
        }
        guard low != .zero, high != .zero else {
            return nil
        }

        var package = self
        let vertices = [
            low,
            HorizontalPoint(x: low.x, y: high.y),
            high,
            HorizontalPoint(x: high.x, y: low.y),
        ].map { HorizontalPolygonVertex(position: $0) }
        if let existing = package.drawing.polygons.values.first(where: { $0.layer == HorizontalBoardLayers.topCourtyard }) {
            package.drawing.polygons[existing.id]?.parameterClass = "courtyard"
            package.drawing.polygons[existing.id]?.vertices = vertices
        } else {
            let id = UUID().uuidString.lowercased()
            package.drawing.polygons[id] = HorizontalPoolPolygon(
                id: id,
                layer: HorizontalBoardLayers.topCourtyard,
                parameterClass: "courtyard",
                vertices: vertices
            )
        }
        return package
    }
}

// MARK: - Silkscreen

/// `ToolGenerateSilkscreen`'s settings, upstream's defaults.
struct HorizontalSilkscreenSettings: Hashable {
    var expandSilk = 200_000.0
    var expandPad = 200_000.0
    var lineWidth = 150_000.0
}

extension HorizontalPoolPackage {
    /// `ToolGenerateSilkscreen`: the package-layer outline, expanded, with the
    /// stretches that run over (expanded) pads and holes cut away, as
    /// silkscreen lines. Existing silkscreen lines are replaced. Nil when
    /// there is no package outline or the expansion fails.
    func generatingSilkscreen(
        context: HorizontalPoolEditorContext,
        settings: HorizontalSilkscreenSettings = HorizontalSilkscreenSettings()
    ) -> HorizontalPoolPackage? {
        let outlines = drawing.polygons.values
            .filter { $0.layer == HorizontalBoardLayers.topPackage && $0.vertices.count >= 3 }
            .map { HorizontalPolygon(id: $0.id, polygonVertices: $0.vertices, layer: $0.layer) }
        guard let outline = outlines.max(by: { abs($0.area) < abs($1.area) }) else {
            return nil
        }
        guard let expanded = HorizontalParameterProgramEvaluator.offsetContour(
            outline.renderVertices(arcPrecision: 16),
            by: settings.expandSilk + 75_000
        ), expanded.count >= 3 else {
            return nil
        }

        // Pads: the copper on top plus every hole, each grown by the pad
        // clearance and half the line width.
        let board = makeBoard(context: context)
        let growth = settings.expandPad + settings.lineWidth / 2 + 1
        var obstacles = [[HorizontalPoint]]()
        for polygon in board.packagePads where polygon.layer == HorizontalBoardLayers.topCopper {
            if let grown = HorizontalParameterProgramEvaluator.offsetContour(polygon.renderVertices(arcPrecision: 16), by: growth) {
                obstacles.append(grown)
            }
        }
        for hole in board.packageHoles {
            let points = hole.boundsPoints
            if points.count >= 3,
               let grown = HorizontalParameterProgramEvaluator.offsetContour(points, by: growth) {
                obstacles.append(grown)
            } else if points.count >= 2 {
                // A hole reported as a bbox pair: grow the box.
                let rect = HorizontalRect(points: points)
                let box = [
                    HorizontalPoint(x: rect.minX - growth, y: rect.minY - growth),
                    HorizontalPoint(x: rect.maxX + growth, y: rect.minY - growth),
                    HorizontalPoint(x: rect.maxX + growth, y: rect.maxY + growth),
                    HorizontalPoint(x: rect.minX - growth, y: rect.maxY + growth),
                ]
                obstacles.append(box)
            }
        }

        // Walk the closed outline and keep the pieces outside every obstacle.
        var pieces = [(HorizontalPoint, HorizontalPoint)]()
        let closed = expanded + [expanded[0]]
        for index in 0..<(closed.count - 1) {
            let a = closed[index]
            let b = closed[index + 1]
            var cuts: [Double] = [0, 1]
            for obstacle in obstacles {
                for edgeIndex in obstacle.indices {
                    let c = obstacle[edgeIndex]
                    let d = obstacle[(edgeIndex + 1) % obstacle.count]
                    if let t = Self.segmentIntersectionParameter(a, b, c, d) {
                        cuts.append(t)
                    }
                }
            }
            cuts.sort()
            for cutIndex in 0..<(cuts.count - 1) {
                let t0 = cuts[cutIndex]
                let t1 = cuts[cutIndex + 1]
                guard t1 - t0 > 1e-9 else {
                    continue
                }
                let p0 = HorizontalPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                let p1 = HorizontalPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                let mid = HorizontalPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                if !obstacles.contains(where: { Self.polygon($0, contains: mid) }) {
                    pieces.append((p0, p1))
                }
            }
        }

        var package = self
        let kept = drawing.boardLines().filter { $0.layer != HorizontalBoardLayers.topSilkscreen }
        let newLines = pieces.enumerated().map { index, piece in
            HorizontalSegment(
                id: "silk-\(index)-\(UUID().uuidString.lowercased())",
                from: HorizontalPoint(x: piece.0.x.rounded(), y: piece.0.y.rounded()),
                to: HorizontalPoint(x: piece.1.x.rounded(), y: piece.1.y.rounded()),
                width: settings.lineWidth,
                layer: HorizontalBoardLayers.topSilkscreen
            )
        }.filter { $0.from != $0.to }
        package.drawing = HorizontalPoolDrawing.from(
            junctions: drawing.junctions,
            lines: kept + newLines,
            arcs: drawing.boardArcs(),
            polygons: drawing.boardPolygons(),
            texts: drawing.boardTexts(),
            original: drawing
        )
        return package
    }

    /// Where segment ab crosses segment cd, as a parameter along ab, or nil.
    static func segmentIntersectionParameter(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> Double? {
        let r = b - a
        let s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else {
            return nil
        }
        let qp = c - a
        let t = (qp.x * s.y - qp.y * s.x) / denominator
        let u = (qp.x * r.y - qp.y * r.x) / denominator
        guard t >= 0, t <= 1, u >= 0, u <= 1 else {
            return nil
        }
        return t
    }

    /// Ray-casting point-in-polygon.
    static func polygon(_ polygon: [HorizontalPoint], contains point: HorizontalPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let x = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < x {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }
}

// MARK: - Footprint generator

/// Horizon's footprint generator: rows of pads (single / dual), a quad
/// arrangement, or a BGA grid, from one padstack.
struct HorizontalFootprintGeneratorSettings: Hashable {
    enum Mode: String, CaseIterable, Hashable {
        case single, dual, quad, grid

        var displayName: String {
            switch self {
            case .single: "Single row"
            case .dual: "Dual row"
            case .quad: "Quad"
            case .grid: "Grid"
            }
        }
    }

    var mode: Mode = .dual
    /// Single: pads in the row; dual: pads in total (even).
    var padCount = 8
    /// Quad: pads per vertical side; grid: rows.
    var padCountV = 4
    /// Quad: pads per horizontal side; grid: columns.
    var padCountH = 4
    var pitch = 1_000_000.0
    /// Grid: the vertical pitch (`pitch` is horizontal).
    var pitchV = 1_000_000.0
    /// Dual: half the distance between the rows; quad: for the vertical sides.
    var spacing = 3_000_000.0
    /// Quad: half the distance between the horizontal sides.
    var spacingV = 3_000_000.0
    var padWidth = 1_000_000.0
    var padHeight = 2_000_000.0
    var zigzag = false
    var padstackID = ""

    static let bgaLetters = Array("ABCDEFGHJKLMNPRTUVWY")

    /// `get_bga_letter`: A…Y, then AA, AB… (I, O, Q, S, X, Z skipped).
    static func bgaLetter(_ oneBased: Int) -> String {
        let x = oneBased - 1
        let count = bgaLetters.count
        if x < count {
            return String(bgaLetters[x])
        }
        return String(bgaLetters[(x / count) - 1]) + String(bgaLetters[x % count])
    }
}

extension HorizontalPoolPackage {
    /// The package with the generated pads appended (existing pads stay).
    func appendingGeneratedPads(
        settings: HorizontalFootprintGeneratorSettings,
        padstackJSON: JSONDictionary?
    ) -> HorizontalPoolPackage {
        var package = self
        let parameterKeys = Set(padstackJSON?.dictionary("parameter_set")?.keys.map { $0 } ?? [])
        func makePad(name: String, x: Double, y: Double, angleDegrees: Int) -> HorizontalPad {
            var pad = HorizontalPad(
                id: UUID().uuidString.lowercased(),
                name: name,
                padstackID: settings.padstackID,
                placement: HorizontalPlacementTransform(
                    shift: HorizontalPoint(x: x.rounded(), y: y.rounded()),
                    angle: angleDegrees * 65_536 / 360,
                    mirrored: false
                )
            )
            // `update_pad_parameters`: round pads take a diameter, others a
            // width and height plus a corner radius when the padstack has one.
            let width = Int(settings.padWidth.rounded())
            let height = Int(settings.padHeight.rounded())
            if parameterKeys.contains("pad_diameter") {
                pad.parameterSet["pad_diameter"] = min(width, height)
            } else {
                pad.parameterSet["pad_height"] = height
                pad.parameterSet["pad_width"] = width
                if parameterKeys.contains("corner_radius") {
                    pad.parameterSet["corner_radius"] = min(250_000, min(width, height) / 4)
                }
            }
            return pad
        }
        func add(_ pad: HorizontalPad) {
            package.pads[pad.id] = pad
        }

        switch settings.mode {
        case .single:
            let count = max(settings.padCount, 1)
            let y0 = Double(count - 1) * (settings.pitch / 2)
            for index in 0..<count {
                add(makePad(name: String(index + 1), x: 0, y: y0 - settings.pitch * Double(index), angleDegrees: 270))
            }
        case .dual:
            let count = max(settings.padCount / 2, 1)
            let total = count * 2
            let y0 = Double(count - 1) * (settings.pitch / 2)
            for side in [-1.0, 1.0] {
                for index in 0..<count {
                    let name: String
                    if settings.zigzag {
                        name = String(side < 0 ? index * 2 + 1 : index * 2 + 2)
                    } else {
                        name = String(side < 0 ? index + 1 : total - index)
                    }
                    add(makePad(
                        name: name,
                        x: side * settings.spacing,
                        y: y0 - settings.pitch * Double(index),
                        angleDegrees: side < 0 ? 270 : 90
                    ))
                }
            }
        case .quad:
            let countV = max(settings.padCountV, 1)
            let countH = max(settings.padCountH, 1)
            let y0 = Double(countV - 1) * (settings.pitch / 2)
            for side in [-1.0, 1.0] {
                for index in 0..<countV {
                    let name = side < 0 ? String(index + 1) : String(countV * 2 + countH - index)
                    add(makePad(
                        name: name,
                        x: side * settings.spacing,
                        y: y0 - settings.pitch * Double(index),
                        angleDegrees: side < 0 ? 270 : 90
                    ))
                }
            }
            let x0 = Double(countH - 1) * (settings.pitch / 2) * -1
            for side in [-1.0, 1.0] {
                for index in 0..<countH {
                    let name = side < 0 ? String(index + 1 + countV) : String(countV * 2 + countH * 2 - index)
                    add(makePad(
                        name: name,
                        x: x0 + settings.pitch * Double(index),
                        y: side * settings.spacingV,
                        angleDegrees: side < 0 ? 0 : 180
                    ))
                }
            }
        case .grid:
            let columns = max(settings.padCountH, 1)
            let rows = max(settings.padCountV, 1)
            for column in 0..<columns {
                for row in 0..<rows {
                    add(makePad(
                        name: HorizontalFootprintGeneratorSettings.bgaLetter(column + 1) + String(row + 1),
                        x: settings.pitch * Double(column) - (settings.pitch * Double(columns - 1)) / 2,
                        y: -settings.pitchV * Double(row) + (settings.pitchV * Double(rows - 1)) / 2,
                        angleDegrees: 0
                    ))
                }
            }
        }
        return package
    }
}
