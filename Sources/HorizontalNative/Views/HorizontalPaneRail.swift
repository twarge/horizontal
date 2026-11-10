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
    /// The selection tools, drawn right under the Grid button; nil for a pane
    /// that has none.
    var selectionToolSettings: Binding<HorizontalSelectionToolSettings>? = nil
    /// Shows the keyboard-focus badge in the pane's lower left (this pane
    /// receives keyboard commands), where the canvas starts its scale bar
    /// to the right of it.
    var isKeyboardFocused = false
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
        // Room for the badge whether or not this pane has the keyboard, so
        // the scale bar stays put as focus moves between panes.
        .environment(\.horizonScaleBarLeadingClearance, showsTools ? PaneKeyboardFocusBadge.scaleBarClearance : 0)
        .overlay {
            // In the corner rather than atop the rail, where it pushed every
            // rail button down a place each time focus moved between panes;
            // in the same place on every pane, scale bar or not. Lifted, not
            // pushed along, out of a rounded window or display corner, so the
            // scale bar beside it keeps its place and still runs past the
            // badge's lower edge.
            if showsTools, isKeyboardFocused {
                Color.clear
                    .allowsHitTesting(false)
                    .cornerAdaptiveOverlay(alignment: .bottomLeading, padding: 9, axis: .vertical) {
                        // Its 3 pt padding and the symbol's side bearing taken
                        // off, so the scope's edge lines up with where a canvas
                        // without one starts its scale bar.
                        PaneKeyboardFocusBadge()
                            .padding(.leading, -2)
                            #if os(macOS)
                            .onHover(perform: onToolbarHover)
                            .onDisappear {
                                onToolbarHover(false)
                            }
                            #endif
                    }
                    // The pane runs under the bars and is handed their insets
                    // instead; given back here, the corner is measured from the
                    // same edges as the padding.
                    .safeAreaPadding(safeAreaInsets)
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
                    selectionToolSettings: selectionToolSettings,
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

private struct HorizontalScaleBarLeadingClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far right of the canvas's leading inset its scale bar starts:
    /// the room a pane's keyboard-focus badge takes in that corner.
    var horizonScaleBarLeadingClearance: CGFloat {
        get { self[HorizontalScaleBarLeadingClearanceKey.self] }
        set { self[HorizontalScaleBarLeadingClearanceKey.self] = newValue }
    }
}

/// The pane's keyboard-focus mark: a tinted scope, no button behind it.
struct PaneKeyboardFocusBadge: View {
    #if os(iOS)
    private static let iconSize: CGFloat = 20
    #else
    private static let iconSize: CGFloat = 16
    #endif

    /// How much further right than usual a canvas under the badge starts its
    /// scale bar, whose line runs through the badge's corner: the scope's
    /// width and a gap.
    static let scaleBarClearance: CGFloat = iconSize + 8

    var body: some View {
        Image(systemName: "scope")
            .font(.system(size: Self.iconSize, weight: .semibold))
            .foregroundStyle(.tint)
            .padding(3)
            .contentShape(Rectangle())
            .help("This view receives keyboard commands")
            .accessibilityLabel("Keyboard focus")
    }
}

/// The vertical rail itself: Info / Layers / Grid popover buttons (Info / Grid /
/// Layers on the board) plus the free-form `tools` column beneath them.
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
    var selectionToolSettings: Binding<HorizontalSelectionToolSettings>? = nil
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
            infoButton
            if pane == .board {
                gridButton
                selectionToolButton
                layerButton
            } else {
                layerButton
                gridButton
                selectionToolButton
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

    @ViewBuilder
    private var infoButton: some View {
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
    }

    @ViewBuilder
    private var layerButton: some View {
        if showsLayerButton {
            HorizontalRailHelpLabel(title: "\(pane.title) layers") {
                Button {
                    isLayerPopoverPresented.toggle()
                } label: {
                    Image(systemName: pane == .board ? "square.2.layers.3d.top.filled" : "square.3.layers.3d")
                }
                .help("\(pane.title) layers")
                .popover(isPresented: $isLayerPopoverPresented, arrowEdge: .trailing) {
                    layers
                }
            }
        }
    }

    @ViewBuilder
    private var gridButton: some View {
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
    }

    @ViewBuilder
    private var selectionToolButton: some View {
        if let selectionToolSettings {
            SelectionToolButton(settings: selectionToolSettings, showsBoardFilter: pane == .board)
        }
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
