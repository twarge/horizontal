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

    /// A warning's triangle is yellow with a black mark; an error's red with
    /// a white one, in the same black rim.
    static func triangles(for warnings: [HorizontalCanvasWarning]) -> [HorizontalMetalScreenTrianglePrimitive] {
        let yellow = HorizontalMetalRGBA(red: 1, green: 0.8, blue: 0.05, alpha: 1)
        let red = HorizontalMetalRGBA(red: 0.9, green: 0.16, blue: 0.13, alpha: 1)
        let black = HorizontalMetalRGBA(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        let white = HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        return warnings.flatMap { warning in
            func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ color: HorizontalMetalRGBA) -> HorizontalMetalScreenTrianglePrimitive {
                func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }
                return .init(a: shifted(a), b: shifted(b), c: shifted(c), color: color, worldAnchor: warning.position)
            }
            let fill = warning.isError ? red : yellow
            let mark = warning.isError ? white : black
            return [
                triangle(.init(x: 0, y: -8), .init(x: -9, y: 8), .init(x: 9, y: 8), black),
                triangle(.init(x: 0, y: -6), .init(x: -7, y: 7), .init(x: 7, y: 7), fill),
                triangle(.init(x: -1, y: -2), .init(x: 1, y: -2), .init(x: 1, y: 3), mark),
                triangle(.init(x: -1, y: -2), .init(x: 1, y: 3), .init(x: -1, y: 3), mark),
                triangle(.init(x: -1, y: 4), .init(x: 1, y: 4), .init(x: 1, y: 6), mark),
                triangle(.init(x: -1, y: 4), .init(x: 1, y: 6), .init(x: -1, y: 6), mark)
            ]
        }
    }
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
                .foregroundStyle(warning.isError ? .red : .yellow, warning.isError ? .white : .black)
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
