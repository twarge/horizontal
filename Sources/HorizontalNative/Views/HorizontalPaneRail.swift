import SwiftUI

// The canvas button-rail shell, shared by the macOS workspace and the iPad project
// view. Extracted from the (macOS-only) ProjectDocumentView so iOS can use it. The
// Info popover content is a generic closure (the macOS info panel depends on
// macOS-only types, so it's supplied by the caller rather than baked in here).

/// Overlays a `PaneToolColumn` (Info / Layers / Grid / Tools) on the top-trailing
/// (or top-leading, if swapped) edge of the pane content.
struct PaneOverlayContainer<
    Content: View,
    InfoContent: View,
    LayersContent: View,
    GridContent: View,
    ToolsContent: View
>: View {
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    var pane: HorizontalPane
    var safeAreaInsets: EdgeInsets
    var infoEnabled = true
    var showsTools = true
    var showsInfoButton = true
    var showsLayerButton = true
    var showsGridButton = true
    /// Shows the keyboard-focus badge in the pane's lower left, above the
    /// canvas's scale bar (this pane receives keyboard commands).
    var isKeyboardFocused = false
    /// The canvas draws its scale bar in the lower left, which the focus badge
    /// then stands over: a board's, when its Scale Bar option is on. A
    /// schematic draws none.
    var showsScaleBar = false
    /// macOS: tracks pointer-over-rail so the canvas can ignore those mouse events.
    /// No-op on iOS (touch has no hover).
    var onToolbarHover: (Bool) -> Void = { _ in }
    @ViewBuilder var content: Content
    @ViewBuilder var info: InfoContent
    @ViewBuilder var layers: LayersContent
    @ViewBuilder var grid: GridContent
    @ViewBuilder var tools: ToolsContent

    var body: some View {
        content
        .overlay(alignment: .bottomLeading) {
            // In the corner rather than atop the rail, where it pushed every
            // rail button down a place each time focus moved between panes.
            if showsTools, isKeyboardFocused {
                // Its 3 pt padding and the symbol's side bearing taken off, so
                // the scope's edge stands over the scale bar's left tick.
                PaneKeyboardFocusBadge()
                    .padding(.leading, safeAreaInsets.leading + 7)
                    .padding(.bottom, safeAreaInsets.bottom + keyboardFocusBadgeBottomPadding)
                    #if os(macOS)
                    .onHover(perform: onToolbarHover)
                    .onDisappear {
                        onToolbarHover(false)
                    }
                    #endif
            }
        }
        .overlay(alignment: toolColumnAlignment) {
            if showsTools {
                PaneToolColumn(
                    pane: pane,
                    showsInfoButton: showsInfoButton,
                    infoEnabled: infoEnabled,
                    showsLayerButton: showsLayerButton,
                    showsGridButton: showsGridButton,
                    labelSide: appearanceSettings.shouldSwapViewControlsAndUnplacedReferences ? .trailing : .leading
                ) {
                    info
                } layers: {
                    layers
                } grid: {
                    grid
                } tools: {
                    tools
                }
                .padding(.top, safeAreaInsets.top + 12)
                .padding(toolColumnHorizontalEdge, toolColumnHorizontalPadding)
                .contentShape(Rectangle())
                #if os(macOS)
                .onHover(perform: onToolbarHover)
                .onDisappear {
                    onToolbarHover(false)
                }
                #endif
            }
        }
    }

    /// In the corner, or clear of the scale bar: its line sits 18 pt over the
    /// canvas's bottom safe area and its label 20 pt over that
    /// (`InteractiveCanvasView.drawScaleBar`).
    private var keyboardFocusBadgeBottomPadding: CGFloat {
        showsScaleBar ? 18 + 20 + 3 : 9
    }

    private var toolColumnAlignment: Alignment {
        appearanceSettings.shouldSwapViewControlsAndUnplacedReferences ? .topLeading : .topTrailing
    }

    private var toolColumnHorizontalEdge: Edge.Set {
        appearanceSettings.shouldSwapViewControlsAndUnplacedReferences ? .leading : .trailing
    }

    private var toolColumnHorizontalPadding: CGFloat {
        let inset = appearanceSettings.shouldSwapViewControlsAndUnplacedReferences
            ? safeAreaInsets.leading
            : safeAreaInsets.trailing
        return inset + 12
    }
}

/// The pane's keyboard-focus mark: a tinted scope, no button behind it.
struct PaneKeyboardFocusBadge: View {
    #if os(iOS)
    private let iconSize: CGFloat = 20
    #else
    private let iconSize: CGFloat = 16
    #endif

    var body: some View {
        Image(systemName: "scope")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.tint)
            .padding(3)
            .contentShape(Rectangle())
            .help("This view receives keyboard commands")
            .accessibilityLabel("Keyboard focus")
    }
}

/// The vertical rail itself: Info / Layers / Grid popover buttons plus the free-form
/// `tools` column beneath them.
struct PaneToolColumn<
    InfoContent: View,
    LayersContent: View,
    GridContent: View,
    ToolsContent: View
>: View {
    var pane: HorizontalPane
    var showsInfoButton = true
    var infoEnabled = true
    var showsLayerButton = true
    var showsGridButton = true
    var labelSide = HorizontalRailHelpLabelSide.trailing
    @ViewBuilder var info: InfoContent
    @ViewBuilder var layers: LayersContent
    @ViewBuilder var grid: GridContent
    @ViewBuilder var tools: ToolsContent

    @State private var isInfoPopoverPresented = false
    @State private var isLayerPopoverPresented = false
    @State private var isGridPopoverPresented = false
    @State private var isRailHovered = false

    var body: some View {
        VStack(spacing: 8) {
            if showsInfoButton {
                HorizontalRailHelpLabel(title: "\(pane.title) information") {
                    Button {
                        isInfoPopoverPresented.toggle()
                    } label: {
                        Image(systemName: isInfoPopoverPresented ? "info.circle.fill" : "info.circle")
                    }
                    .disabled(!infoEnabled)
                    .help("\(pane.title) information")
                    .popover(isPresented: $isInfoPopoverPresented, arrowEdge: .trailing) {
                        info
                    }
                }
            }

            if showsLayerButton {
                HorizontalRailHelpLabel(title: "\(pane.title) layers") {
                    Button {
                        isLayerPopoverPresented.toggle()
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .help("\(pane.title) layers")
                    .popover(isPresented: $isLayerPopoverPresented, arrowEdge: .trailing) {
                        layers
                    }
                }
            }

            if showsGridButton {
                HorizontalRailHelpLabel(title: "\(pane.title) grid") {
                    Button {
                        isGridPopoverPresented.toggle()
                    } label: {
                        Image(systemName: "square.grid.3x3")
                    }
                    .help("\(pane.title) grid")
                    .popover(isPresented: $isGridPopoverPresented, arrowEdge: .trailing) {
                        grid
                    }
                }
            }

            tools
        }
        .buttonStyle(PaneToolButtonStyle())
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .environment(\.horizonRailHelpLabelsVisible, isRailHovered)
        .environment(\.horizonRailHelpLabelSide, labelSide)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isRailHovered = $0 }
        #endif
    }
}

struct PaneToolButtonStyle: ButtonStyle {
    // Rail buttons are 25% larger on iOS for finger-friendly targets (≈42pt, toward
    // the 44pt HIG minimum); macOS keeps the tighter mouse-sized rail.
    #if os(iOS)
    private let buttonSize: CGFloat = 42.5
    private let iconSize: CGFloat = 20
    private let cornerRadius: CGFloat = 10
    #else
    private let buttonSize: CGFloat = 34
    private let iconSize: CGFloat = 16
    private let cornerRadius: CGFloat = 8
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? .secondary : .primary)
            .frame(width: buttonSize, height: buttonSize)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.primary.opacity(configuration.isPressed ? 0.16 : 0.08), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
