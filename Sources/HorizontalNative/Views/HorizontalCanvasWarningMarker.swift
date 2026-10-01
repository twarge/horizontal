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

    static func triangles(for warnings: [HorizontalCanvasWarning]) -> [HorizontalMetalScreenTrianglePrimitive] {
        let yellow = HorizontalMetalRGBA(red: 1, green: 0.8, blue: 0.05, alpha: 1)
        let black = HorizontalMetalRGBA(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        return warnings.flatMap { warning in
            func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ color: HorizontalMetalRGBA) -> HorizontalMetalScreenTrianglePrimitive {
                func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }
                return .init(a: shifted(a), b: shifted(b), c: shifted(c), color: color, worldAnchor: warning.position)
            }
            return [
                triangle(.init(x: 0, y: -8), .init(x: -9, y: 8), .init(x: 9, y: 8), black),
                triangle(.init(x: 0, y: -6), .init(x: -7, y: 7), .init(x: 7, y: 7), yellow),
                triangle(.init(x: -1, y: -2), .init(x: 1, y: -2), .init(x: 1, y: 3), black),
                triangle(.init(x: -1, y: -2), .init(x: 1, y: 3), .init(x: -1, y: 3), black),
                triangle(.init(x: -1, y: 4), .init(x: 1, y: 4), .init(x: 1, y: 6), black),
                triangle(.init(x: -1, y: 4), .init(x: 1, y: 6), .init(x: -1, y: 6), black)
            ]
        }
    }
}

struct HorizontalCanvasWarningMessages: View {
    var warning: HorizontalCanvasWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warning.messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
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
                .foregroundStyle(.yellow, .black)
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
