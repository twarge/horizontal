import Foundation

/// A small DXF reader for the entities a package or decal outline needs:
/// lines, circles, arcs and polylines (with bulges), read from the ENTITIES
/// section in drawing units and scaled to nanometres. Blocks, text and
/// dimensions are ignored, as upstream's import does.
struct HorizontalDXFImport: Hashable {
    var lines: [(HorizontalPoint, HorizontalPoint)] = []
    var arcs: [(from: HorizontalPoint, to: HorizontalPoint, center: HorizontalPoint)] = []

    var isEmpty: Bool {
        lines.isEmpty && arcs.isEmpty
    }

    static func == (lhs: HorizontalDXFImport, rhs: HorizontalDXFImport) -> Bool {
        lhs.lines.map { [$0.0, $0.1] } == rhs.lines.map { [$0.0, $0.1] }
            && lhs.arcs.map { [$0.from, $0.to, $0.center] } == rhs.arcs.map { [$0.from, $0.to, $0.center] }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(lines.count)
        hasher.combine(arcs.count)
    }
}

enum HorizontalDXFImporter {
    /// `scale` converts drawing units to nanometres (1_000_000 for millimetres).
    static func parse(_ text: String, scale: Double = 1_000_000) -> HorizontalDXFImport {
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var pairs = [(code: Int, value: String)]()
        var index = 0
        while index + 1 < rawLines.count {
            if let code = Int(rawLines[index]) {
                pairs.append((code, rawLines[index + 1]))
            }
            index += 2
        }

        var result = HorizontalDXFImport()
        var inEntities = false
        var entity: [Int: [String]] = [:]
        var entityType: String?
        var polylineVertices = [(HorizontalPoint, Double)]()
        var polylineClosed = false
        var insidePolyline = false

        func point(_ codeX: Int, _ codeY: Int, at position: Int = 0) -> HorizontalPoint? {
            guard let xs = entity[codeX], let ys = entity[codeY], position < xs.count, position < ys.count,
                  let x = Double(xs[position]), let y = Double(ys[position]) else {
                return nil
            }
            return HorizontalPoint(x: x * scale, y: y * scale)
        }
        func value(_ code: Int) -> Double? {
            entity[code]?.first.flatMap(Double.init)
        }
        func emitPolyline(_ vertices: [(HorizontalPoint, Double)], closed: Bool) {
            guard vertices.count >= 2 else {
                return
            }
            let count = closed ? vertices.count : vertices.count - 1
            for index in 0..<count {
                let (start, bulge) = vertices[index]
                let end = vertices[(index + 1) % vertices.count].0
                if start == end {
                    continue
                }
                if abs(bulge) < 1e-9 {
                    result.lines.append((start, end))
                } else {
                    result.arcs.append(Self.bulgeArc(from: start, to: end, bulge: bulge))
                }
            }
        }
        func flushEntity() {
            guard inEntities, let type = entityType else {
                return
            }
            switch type {
            case "LINE":
                if let a = point(10, 20), let b = point(11, 21), a != b {
                    result.lines.append((a, b))
                }
            case "CIRCLE":
                if let center = point(10, 20), let radius = value(40), radius > 0 {
                    let rim = HorizontalPoint(x: center.x + radius * scale, y: center.y)
                    let opposite = HorizontalPoint(x: center.x - radius * scale, y: center.y)
                    result.arcs.append((rim, opposite, center))
                    result.arcs.append((opposite, rim, center))
                }
            case "ARC":
                if let center = point(10, 20), let radius = value(40), radius > 0 {
                    let startDegrees = value(50) ?? 0
                    let endDegrees = value(51) ?? 360
                    let r = radius * scale
                    let start = HorizontalPoint(x: center.x + r * cos(startDegrees * .pi / 180), y: center.y + r * sin(startDegrees * .pi / 180))
                    let end = HorizontalPoint(x: center.x + r * cos(endDegrees * .pi / 180), y: center.y + r * sin(endDegrees * .pi / 180))
                    result.arcs.append((start, end, center))
                }
            case "LWPOLYLINE":
                let xs = entity[10] ?? []
                let ys = entity[20] ?? []
                let bulges = entity[42] ?? []
                var vertices = [(HorizontalPoint, Double)]()
                for index in 0..<min(xs.count, ys.count) {
                    guard let x = Double(xs[index]), let y = Double(ys[index]) else {
                        continue
                    }
                    let bulge = index < bulges.count ? (Double(bulges[index]) ?? 0) : 0
                    vertices.append((HorizontalPoint(x: x * scale, y: y * scale), bulge))
                }
                let flags = Int(entity[70]?.first ?? "0") ?? 0
                emitPolyline(vertices, closed: flags & 1 != 0)
            case "POLYLINE":
                insidePolyline = true
                polylineVertices = []
                polylineClosed = (Int(entity[70]?.first ?? "0") ?? 0) & 1 != 0
            case "VERTEX":
                if insidePolyline, let p = point(10, 20) {
                    polylineVertices.append((p, value(42) ?? 0))
                }
            case "SEQEND":
                if insidePolyline {
                    emitPolyline(polylineVertices, closed: polylineClosed)
                    insidePolyline = false
                    polylineVertices = []
                }
            default:
                break
            }
        }

        for pair in pairs {
            if pair.code == 0 {
                flushEntity()
                entity = [:]
                entityType = pair.value
                if pair.value == "SECTION" || pair.value == "ENDSEC" || pair.value == "EOF" {
                    entityType = nil
                    if pair.value == "ENDSEC" || pair.value == "EOF" {
                        inEntities = false
                    }
                }
                continue
            }
            if pair.code == 2, entityType == nil, pair.value == "ENTITIES" {
                inEntities = true
                continue
            }
            entity[pair.code, default: []].append(pair.value)
        }
        flushEntity()
        return result
    }

    /// A polyline bulge (tan of a quarter of the included angle) as a
    /// counter-clockwise Horizon arc; a negative bulge sweeps clockwise, so
    /// its ends are swapped.
    static func bulgeArc(from start: HorizontalPoint, to end: HorizontalPoint, bulge: Double) -> (from: HorizontalPoint, to: HorizontalPoint, center: HorizontalPoint) {
        let chord = end - start
        let chordLength = (chord.x * chord.x + chord.y * chord.y).squareRoot()
        let sagitta = bulge * chordLength / 2
        let radius = (chordLength / 2) * (1 + bulge * bulge) / (2 * abs(bulge))
        let mid = HorizontalPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Perpendicular to the chord, towards the arc's centre.
        let normal = HorizontalPoint(x: -chord.y / chordLength, y: chord.x / chordLength)
        let centerOffset = radius - abs(sagitta)
        let center = bulge > 0
            ? HorizontalPoint(x: mid.x - normal.x * centerOffset, y: mid.y - normal.y * centerOffset)
            : HorizontalPoint(x: mid.x + normal.x * centerOffset, y: mid.y + normal.y * centerOffset)
        return bulge > 0 ? (start, end, center) : (end, start, center)
    }
}

extension HorizontalPoolDrawing {
    /// The drawing with an import's lines and arcs added on `layer` (at
    /// `width`, shifted by `offset`), junctions minted where needed.
    func adding(_ dxf: HorizontalDXFImport, layer: Int, width: Double, offset: HorizontalPoint = .zero) -> HorizontalPoolDrawing {
        func rounded(_ point: HorizontalPoint) -> HorizontalPoint {
            HorizontalPoint(x: (point.x + offset.x).rounded(), y: (point.y + offset.y).rounded())
        }
        let newLines = dxf.lines.map { pair in
            HorizontalSegment(id: UUID().uuidString.lowercased(), from: rounded(pair.0), to: rounded(pair.1), width: width, layer: layer)
        }
        let newArcs = dxf.arcs.map { arc in
            HorizontalArc(id: UUID().uuidString.lowercased(), from: rounded(arc.from), to: rounded(arc.to), center: rounded(arc.center), width: width, layer: layer)
        }
        return HorizontalPoolDrawing.from(
            junctions: junctions,
            lines: boardLines() + newLines,
            arcs: boardArcs() + newArcs,
            polygons: boardPolygons(),
            texts: boardTexts(),
            original: self
        )
    }
}
