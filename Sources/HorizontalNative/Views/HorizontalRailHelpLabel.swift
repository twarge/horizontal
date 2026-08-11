import SwiftUI

enum HorizontalRailHelpLabelSide {
    case leading
    case trailing
}

private struct HorizontalRailHelpLabelsVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

private struct HorizontalRailHelpLabelSideKey: EnvironmentKey {
    static let defaultValue = HorizontalRailHelpLabelSide.trailing
}

extension EnvironmentValues {
    var horizonRailHelpLabelsVisible: Bool {
        get { self[HorizontalRailHelpLabelsVisibleKey.self] }
        set { self[HorizontalRailHelpLabelsVisibleKey.self] = newValue }
    }

    var horizonRailHelpLabelSide: HorizontalRailHelpLabelSide {
        get { self[HorizontalRailHelpLabelSideKey.self] }
        set { self[HorizontalRailHelpLabelSideKey.self] = newValue }
    }
}

struct HorizontalRailHelpLabel<Content: View>: View {
    var title: String
    var labelOffset: CGFloat = 42
    @ViewBuilder var content: Content

    @Environment(\.horizonRailHelpLabelsVisible) private var isVisible
    @Environment(\.horizonRailHelpLabelSide) private var side

    var body: some View {
        content
            .overlay(alignment: alignment) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundStyle(.primary)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.primary.opacity(0.08), lineWidth: 0.7)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .opacity(isVisible ? 1 : 0)
                    .scaleEffect(isVisible ? 1 : 0.96, anchor: scaleAnchor)
                    .offset(x: side == .trailing ? labelOffset : -labelOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(.easeInOut(duration: 0.14), value: isVisible)
    }

    private var alignment: Alignment {
        side == .trailing ? .leading : .trailing
    }

    private var scaleAnchor: UnitPoint {
        side == .trailing ? .leading : .trailing
    }
}
