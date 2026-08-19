import SwiftUI

/// A right-edge inspector pane, matching the macOS workspace's selection sidebar: a
/// fixed-width panel on the trailing edge of the content. Where there is room
/// (`pushesContent`) it takes its own column so the canvas is never covered; on a
/// compact width — where giving up 340pt would crush the canvas — it overlays
/// instead, like a slide-over.
struct HorizontalInspectorSidebar<Content: View, Inspector: View>: View {
    var isPresented: Bool
    var pushesContent = true
    var width: CGFloat = 340
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector

    var body: some View {
        layout
            .animation(.snappy(duration: 0.18), value: isPresented)
    }

    @ViewBuilder
    private var layout: some View {
        if pushesContent {
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented {
                    inspectorPanel
                }
            }
        } else {
            ZStack(alignment: .trailing) {
                content
                if isPresented {
                    inspectorPanel
                }
            }
        }
    }

    private var inspectorPanel: some View {
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
