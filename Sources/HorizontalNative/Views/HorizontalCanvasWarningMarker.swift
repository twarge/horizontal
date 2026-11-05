import SwiftUI

enum HorizontalCanvasWarningGeometry {
    static let offset = CGPoint(x: 12, y: -12)
    static let hitSize: CGFloat = 20

    static func hitTest(_ location: CGPoint, warnings: [HorizontalCanvasWarning], transform: HorizontalCanvasTransform) -> HorizontalCanvasWarning? {
        warnings.last { warning in
            let anchor = transform.point(warning.position)
            return CGRect(x: anchor.x + offset.x - hitSize / 2,
                          y: anchor.y + offset.y - hitSize / 2,
                          width: hitSize, height: hitSize).contains(location)
        }
    }

    /// The marker is exclamationmark.triangle.fill, as the rules results
    /// sidebar draws an error, in a black rim: red with a white mark for an
    /// error, yellow with a black one for a warning.
    static func triangles(for warnings: [HorizontalCanvasWarning]) -> [HorizontalMetalScreenTrianglePrimitive] {
        let red = HorizontalMetalRGBA(red: 1, green: 0.23, blue: 0.19, alpha: 1)
        let yellow = HorizontalMetalRGBA(red: 1, green: 0.8, blue: 0.05, alpha: 1)
        let black = HorizontalMetalRGBA(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        let white = HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        return warnings.flatMap { warning in
            let colors: [GlyphPart: HorizontalMetalRGBA] = [
                .rim: black, .fill: warning.isError ? red : yellow, .mark: warning.isError ? white : black,
            ]
            return glyph.map { triangle in
                func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }
                return HorizontalMetalScreenTrianglePrimitive(a: shifted(triangle.a), b: shifted(triangle.b), c: shifted(triangle.c),
                                                              color: colors[triangle.part]!, worldAnchor: warning.position)
            }
        }
    }

    enum GlyphPart: Hashable {
        case rim, fill, mark
    }

    struct GlyphTriangle {
        var part: GlyphPart
        var a, b, c: CGPoint
    }

    /// The symbol's shape in points about the marker's centre, y down, the
    /// size the old marker was, drawn in order: a rounded triangle 18 wide
    /// and 16 high, the rim; one 1.2 inside it, the fill; and over them the
    /// exclamation mark's bar and dot. Made once.
    static let glyph: [GlyphTriangle] = {
        // Evenly spaced, with the quarter turns between added, so the outline
        // reaches its extremes exactly.
        func arc(_ center: CGPoint, _ radius: Double, from start: Double, to end: Double, steps: Int) -> [CGPoint] {
            var angles = (0...steps).map { start + (end - start) * Double($0) / Double(steps) }
            var quarter = (start / (.pi / 2)).rounded(.up) * (.pi / 2)
            while quarter < end {
                if !angles.contains(where: { abs($0 - quarter) < 1e-9 }) { angles.append(quarter) }
                quarter += .pi / 2
            }
            return angles.sorted().map { CGPoint(x: center.x + radius * cos($0), y: center.y + radius * sin($0)) }
        }
        // A rounded triangle is its corners' circles and what lies between
        // them: round each centre, from the outward normal of the edge coming
        // in to that of the edge going out, the centres going anticlockwise in
        // the plane's own sense. The rim and the fill share the centres, so
        // the rim is as wide all round.
        let rimRadius = 2.4
        let rimWidth = 1.2
        let centers = [CGPoint(x: 0, y: -8 + rimRadius), CGPoint(x: 9 - rimRadius, y: 8 - rimRadius),
                       CGPoint(x: -9 + rimRadius, y: 8 - rimRadius)]
        func roundedTriangle(radius: Double) -> [CGPoint] {
            centers.indices.flatMap { index -> [CGPoint] in
                let center = centers[index]
                let previous = centers[(index + centers.count - 1) % centers.count]
                let next = centers[(index + 1) % centers.count]
                // An edge along (x, y) faces out along (y, -x).
                let start = atan2(-(center.x - previous.x), center.y - previous.y)
                var end = atan2(-(next.x - center.x), next.y - center.y)
                if end < start { end += 2 * .pi }
                return arc(center, radius, from: start, to: end, steps: 6)
            }
        }
        // The bar a stadium, its ends' centres 3.6 apart; the dot below it.
        let bar = arc(CGPoint(x: 0, y: -2.4), 1.1, from: .pi, to: 2 * .pi, steps: 8)
            + arc(CGPoint(x: 0, y: 1.2), 1.1, from: 0, to: .pi, steps: 8)
        let dot = Array(arc(CGPoint(x: 0, y: 4.6), 1.2, from: 0, to: 2 * .pi, steps: 16).dropLast())
        // Each shape is convex, so a fan from its first point covers it.
        func fan(_ points: [CGPoint], _ part: GlyphPart) -> [GlyphTriangle] {
            (1..<(points.count - 1)).map { GlyphTriangle(part: part, a: points[0], b: points[$0], c: points[$0 + 1]) }
        }
        return fan(roundedTriangle(radius: rimRadius), .rim) + fan(roundedTriangle(radius: rimRadius - rimWidth), .fill)
            + fan(bar, .mark) + fan(dot, .mark)
    }()
}

extension HorizontalCanvasWarning {
    /// `warnings` and `others` as the canvas draws them: one marker for each
    /// point, with every message either gives there.
    static func merging(_ warnings: [HorizontalCanvasWarning], _ others: [HorizontalCanvasWarning]) -> [HorizontalCanvasWarning] {
        guard !others.isEmpty else { return warnings }
        var merged = [String: HorizontalCanvasWarning]()
        for warning in warnings + others {
            guard var existing = merged[warning.id] else {
                merged[warning.id] = warning
                continue
            }
            existing.messages += warning.messages.filter { !existing.messages.contains($0) }
            existing.errorMessages.formUnion(warning.errorMessages)
            merged[warning.id] = existing
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    /// A marker where each clearance finding's copper comes closest, every
    /// one an error.
    static func markers(clearanceFindings findings: [HorizontalClearanceFinding]) -> [HorizontalCanvasWarning] {
        merging([], findings.map { finding in
            let message = "\(finding.title): \(finding.detail)"
            return HorizontalCanvasWarning(position: finding.location, messages: [message], errorMessages: [message])
        })
    }

    /// A marker where each board finding is, the clearance ones among them:
    /// red for what Horizon fails, yellow for what it warns of.
    static func markers(boardFindings findings: [HorizontalBoardRuleFinding]) -> [HorizontalCanvasWarning] {
        merging([], findings.compactMap { finding in
            guard let location = finding.location else { return nil }
            let message = finding.clearance.map { "\($0.title): \($0.detail)" } ?? finding.text
            return HorizontalCanvasWarning(position: location, messages: [message],
                                           errorMessages: finding.level == .error ? [message] : [])
        })
    }

    /// A marker for each schematic finding drawn on the sheet `sheetID`,
    /// red for the checks Horizon fails.
    static func markers(schematicFindings findings: [HorizontalSchematicRuleFinding], sheetID: String) -> [HorizontalCanvasWarning] {
        merging([], findings.compactMap { finding in
            guard let place = finding.place, place.sheetID.caseInsensitiveCompare(sheetID) == .orderedSame else { return nil }
            return HorizontalCanvasWarning(position: place.position, messages: [finding.message],
                                           errorMessages: finding.isError ? [finding.message] : [])
        })
    }
}

struct HorizontalCanvasWarningMessages: View {
    var warning: HorizontalCanvasWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warning.messages, id: \.self) { message in
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(warning.errorMessages.contains(message) ? .red : .yellow)
                }
            }
        }
        .font(.callout)
        .padding(12)
        .presentationCompactAdaptation(.popover)
    }
}

struct HorizontalCanvasWarningMarker: View {
    var warning: HorizontalCanvasWarning
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                // With two colours the first is the mark's, the second the triangle's.
                .foregroundStyle(warning.isError ? .white : .black, warning.isError ? .red : .yellow)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(warning.messages.joined(separator: "\n"))
        .accessibilityLabel(warning.messages.joined(separator: ". "))
        .popover(isPresented: $isPresented) {
            HorizontalCanvasWarningMessages(warning: warning)
        }
    }
}
