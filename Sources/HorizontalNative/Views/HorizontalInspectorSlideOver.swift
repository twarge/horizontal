import SwiftUI

/// A right-edge slide-over inspector pane, matching the macOS workspace's selection
/// sidebar: a fixed-width panel that animates in over the trailing edge of the
/// content (it overlays rather than pushing). Cross-platform — the macOS workspace
/// and the iPad project view can both present their inspector through this.
struct HorizontalInspectorSlideOver<Content: View, Inspector: View>: View {
    var isPresented: Bool
    var width: CGFloat = 340
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector

    var body: some View {
        ZStack(alignment: .trailing) {
            content

            if isPresented {
                inspector
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .leading) {
                        // Hairline divider against the canvas, like the macOS sidebar.
                        Rectangle()
                            .fill(.primary.opacity(0.1))
                            .frame(width: 0.7)
                            .frame(maxHeight: .infinity)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: isPresented)
    }
}
