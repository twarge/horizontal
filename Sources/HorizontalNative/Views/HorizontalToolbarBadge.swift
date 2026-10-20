import SwiftUI

/// A count on a toolbar icon, as the Dock badges an app: something behind
/// the button wants a look — parts behind their pools, issues the last rules
/// check found. Nothing shows at zero.
struct HorizontalToolbarBadge: ViewModifier {
    var count: Int
    var color: Color

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(color))
                    .fixedSize()
                    .offset(x: 9, y: -7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func toolbarBadge(_ count: Int, color: Color = .orange) -> some View {
        modifier(HorizontalToolbarBadge(count: count, color: color))
    }
}

extension HorizontalPartLibraryMonitor {
    /// The parts the info bar is about — out of date, or in no attached
    /// pool — as the Parts pane's badge counts them.
    var attentionCount: Int {
        guard let review else { return 0 }
        return review.outdatedInUse.count + review.notInAttachedPoolInUse.count
    }
}

extension HorizontalBoardRulesResultState {
    /// The badge on the rules results button: the last run's findings, red
    /// when any is an error.
    var badgeCount: Int { messages.count }

    var badgeColor: Color {
        messages.contains { $0.level == .error } ? .red : .orange
    }
}
