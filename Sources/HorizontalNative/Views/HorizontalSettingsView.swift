import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HorizontalSettingsView: View {
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    @AppStorage(HorizontalPlaneFillDefaults.updatesAutomaticallyKey) private var updatesPlanesAutomatically = false
    @AppStorage(HorizontalRulesCheckDefaults.checksAutomaticallyKey) private var checksRulesAutomatically = true
    @AppStorage(HorizontalSpotlightFraming.framesEveryViewKey) private var spotlightFramesEveryView = HorizontalSpotlightFraming.framesEveryViewByDefault

    var body: some View {
        Form {
            Section("Operation") {
                Toggle("Read-only", isOn: appearanceSettings.readOnlyOperationBinding())
            }

            HorizontalPoolsSettingsSection()

            Section("Appearance") {
                Picker("Theme", selection: appearanceSettings.appThemeBinding()) {
                    ForEach(HorizontalAppTheme.allCases) { theme in
                        Text(theme.title)
                            .tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                // Off is the standard chrome on both platforms: the system
                // toolbar background on macOS, the glass island behind the
                // top-bar buttons on iPad. On, that background goes away. The
                // canvas runs up underneath the toolbar either way; only the
                // background changes.
                Toggle("Transparent Toolbar", isOn: appearanceSettings.transparentToolbarBinding())

                Toggle(
                    "Swap View Controls and Unplaced References",
                    isOn: appearanceSettings.swapViewControlsAndUnplacedReferencesBinding()
                )
            }

            Section("Canvas") {
                Picker("Cursor Size", selection: appearanceSettings.cursorSizeBinding()) {
                    ForEach(HorizontalCursorSize.allCases) { cursorSize in
                        Text(cursorSize.title)
                            .tag(cursorSize)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Selection Handles", selection: appearanceSettings.selectionHandleShapeBinding()) {
                    ForEach(HorizontalSelectionHandleShape.allCases) { shape in
                        Text(shape.title)
                            .tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show Hover Popover", isOn: appearanceSettings.hoverPopoverBinding())

                Toggle("Show the Spotlight in Every View", isOn: $spotlightFramesEveryView)

                // As in the rules results sidebar: with the warnings off the
                // checks pause, and Check Rules Automatically hides.
                Toggle("Display Warnings on Canvas", isOn: appearanceSettings.canvasWarningsBinding())
                if appearanceSettings.shouldDisplayCanvasWarnings {
                    Toggle("Check Rules Automatically", isOn: $checksRulesAutomatically)
                }
            }

            Section("Schematic") {
                Toggle("Fill Net Label Background", isOn: appearanceSettings.netLabelBackgroundBinding())
                Toggle("Fill Closed Symbol Background", isOn: appearanceSettings.closedSymbolBackgroundBinding())
                Toggle("Show Hops Where Wires Cross", isOn: appearanceSettings.wireHopsBinding())
            }

            Section("Board") {
                // The board rail's Update Planes button hides while this is
                // on, and its context menu was the iPad's only other way back.
                Toggle("Update Planes Automatically", isOn: $updatesPlanesAutomatically)
                Toggle("Clip Silkscreen to Solder Mask", isOn: appearanceSettings.clipSilkscreenToSolderMaskBinding())
            }

            // One section, because a column's Reset puts back that canvas's
            // whole palette, the selection colours with the rest.
            Section("Canvas and Selection Colors") {
                colorMatrixHeader(columns: colorColumns)
                ForEach(canvasColorRoles) { role in
                    colorRoleRow(role)
                }
                ForEach(selectionColorRoles) { role in
                    colorRoleRow(role)
                }
                paletteResetRow()
            }

            Section("Layer Colors") {
                colorMatrixHeader(columns: layerColorColumns)
                ForEach(editableLayers, id: \.self) { layer in
                    layerColorRow(layer)
                }
                trailingResetRow("Reset Layer Colors") {
                    appearanceSettings.resetLayerColors()
                }
            }

            Section("3D View Colors") {
                threeDViewColorRow("Background", selection: appearanceSettings.boardSceneBackgroundColorBinding())
                threeDViewColorRow("Substrate", selection: appearanceSettings.boardSceneSubstrateColorBinding())
                threeDViewColorRow("Solder Mask", selection: appearanceSettings.boardSceneSolderMaskColorBinding())
                threeDViewColorRow("Silkscreen", selection: appearanceSettings.boardSceneSilkscreenColorBinding())
                threeDViewColorRow("Copper", selection: appearanceSettings.boardSceneCopperColorBinding())
                trailingResetRow("Reset 3D View Colors") {
                    appearanceSettings.resetBoardSceneColors()
                }
            }

            Section("Line Width") {
                gridLineWidthRow()
                ForEach(lineWidthKinds) { kind in
                    lineWidthRow(kind)
                }
                ForEach(HorizontalLineWidthRole.allCases) { role in
                    lineWidthRow(role)
                }
            }

            #if os(macOS)
            // The listener is macOS-only, so the switch is too.
            Section("AI Agent Access") {
                Toggle("Enable MCP Server", isOn: appearanceSettings.liveServerEnabledBinding())
                HorizontalMCPSetup()
            }
            #endif

            HorizontalDigiKeySettingsSection()

            HorizontalMouserSettingsSection()
        }
        .formStyle(.grouped)
        // The macOS Settings window (HorizontalSettingsWindow) can be made as
        // narrow as the colour matrix's four columns and a short label fit,
        // and no wider than the form has a use for; in height it goes down to
        // the minimum, where the form scrolls. On iPad the form is presented
        // in a sheet and should fill whatever size the sheet provides.
        #if os(macOS)
        .frame(minWidth: Self.minimumSize.width, maxWidth: Self.maximumWidth)
        .frame(minHeight: Self.minimumSize.height, maxHeight: .infinity)
        #endif
    }

    #if os(macOS)
    static let minimumSize = CGSize(width: 480, height: 360)
    static let maximumWidth: CGFloat = 680
    #endif

    /// A colour well's column: wide enough for the well, a small Reset button
    /// and a two-line caption heading.
    private static let colorColumnWidth: CGFloat = 64
    /// The title column of the slider rows, which have no room to give it the
    /// rest of the row as the colour tables do.
    private static let sliderLabelWidth: CGFloat = 120

    /// A section's own reset, under the rows it puts back.
    private func trailingResetRow(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.bordered)
        }
    }

    /// A Reset under each of the colour table's columns.
    private func paletteResetRow() -> some View {
        HStack(spacing: 8) {
            Text("Reset")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(colorColumns) { column in
                Button("Reset") {
                    appearanceSettings.reset(kind: column.kind, mode: column.mode)
                }
                .controlSize(.small)
                .fixedSize()
                .frame(width: Self.colorColumnWidth)
                .help("Reset the \(column.title) colors")
                .accessibilityLabel("Reset \(column.title)")
            }
        }
        .buttonStyle(.bordered)
    }

    private var canvasColorRoles: [HorizontalColorRole] {
        allCanvasColorRoles.filter { role in
            colorColumns.contains { column in
                colorRoleIsUsed(role, by: column.kind)
            }
        }
    }

    private var selectionColorRoles: [HorizontalColorRole] {
        allSelectionColorRoles.filter { role in
            colorColumns.contains { column in
                colorRoleIsUsed(role, by: column.kind)
            }
        }
    }

    private var allCanvasColorRoles: [HorizontalColorRole] {
        [
            .background,
            .grid,
            .textOverlay,
            .junction,
            .net,
            .bus,
            .frame,
            .airwire,
            .pin,
            .pinAnnotation,
            .hiddenPin,
            .symbolBoundingBox,
            .hole,
            .dimension,
            .error,
            .origin,
            .connectionLine,
            .noPopulate,
            .projection,
            .netTie,
            .diffPair,
        ]
    }

    private var allSelectionColorRoles: [HorizontalColorRole] {
        [
            .selectableOuter,
            .selectableInner,
            .selectablePrelight,
            .selectableAlways,
        ]
    }

    private func colorMatrixHeader(columns: [ColorMatrixColumn]) -> some View {
        HStack(spacing: 8) {
            Text("Color")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                Text(column.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.colorColumnWidth)
            }
        }
        .padding(.vertical, 2)
    }

    private func colorRoleRow(_ role: HorizontalColorRole) -> some View {
        colorMatrixRow(role.title, columns: colorColumns) { column in
            guard colorRoleIsUsed(role, by: column.kind) else {
                return nil
            }
            return appearanceSettings.colorBinding(for: role, kind: column.kind, mode: column.mode)
        }
    }

    private func layerColorRow(_ layer: Int) -> some View {
        colorMatrixRow(layerName(for: layer), columns: layerColorColumns) { column in
            appearanceSettings.layerColorBinding(for: layer, mode: column.mode)
        }
    }

    private func threeDViewColorRow(_ title: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: Self.sliderLabelWidth, alignment: .leading)
            ColorPicker(title, selection: selection, supportsOpacity: false)
                .labelsHidden()
            Spacer(minLength: 0)
        }
    }

    private func lineWidthRow(_ kind: HorizontalCanvasKind) -> some View {
        lineWidthSliderRow(
            kind.title,
            width: appearanceSettings.minimumLineWidthBinding(for: kind)
        ) {
            appearanceSettings.resetMinimumLineWidth(kind: kind)
        }
    }

    private func lineWidthRow(_ role: HorizontalLineWidthRole) -> some View {
        lineWidthSliderRow(
            role.title,
            width: appearanceSettings.lineWidthBinding(for: role)
        ) {
            appearanceSettings.resetLineWidth(role: role)
        }
    }

    private func gridLineWidthRow() -> some View {
        lineWidthSliderRow(
            "Grid marks",
            width: appearanceSettings.gridLineWidthBinding()
        ) {
            appearanceSettings.resetGridLineWidth()
        }
    }

    /// Every line width slider runs over the same range in the same steps,
    /// so each has the same ticks.
    private func lineWidthSliderRow(
        _ title: String,
        width: Binding<Double>,
        reset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: Self.sliderLabelWidth, alignment: .leading)
            Slider(
                value: width,
                in: HorizontalAppearanceSettings.lineWidthRange,
                step: HorizontalAppearanceSettings.lineWidthStep
            )
            Text(width.wrappedValue.formatted(.number.precision(.fractionLength(1))) + " px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Button("Reset", action: reset)
                .buttonStyle(.bordered)
        }
    }

    private func colorMatrixRow(
        _ title: String,
        columns: [ColorMatrixColumn],
        binding: @escaping (ColorMatrixColumn) -> Binding<Color>?
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                if let binding = binding(column) {
                    ColorPicker("\(title), \(column.title)", selection: binding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: Self.colorColumnWidth)
                        .accessibilityLabel("\(title), \(column.title)")
                } else {
                    Color.clear
                        .frame(width: Self.colorColumnWidth)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func colorRoleIsUsed(_ role: HorizontalColorRole, by kind: HorizontalCanvasKind) -> Bool {
        switch kind {
        case .schematic:
            schematicColorRoles.contains(role)
        case .board:
            boardColorRoles.contains(role)
        }
    }

    private func layerName(for layer: Int) -> String {
        if layer == HorizontalBoardLayers.dimensions {
            return "Dimensions"
        }
        return HorizontalBoardLayers.name(for: layer)
    }
}

#if os(macOS)
/// The sandboxed app cannot configure another app, so installation is explicit.
private struct HorizontalMCPSetup: View {
    private enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"

        var id: Self { self }

        var commands: String {
            switch self {
            case .codex:
                return """
                    codex plugin marketplace add twarge/horizontal
                    codex plugin add horizontal@twarge
                    """
            case .claudeCode:
                return """
                    claude plugin marketplace add twarge/horizontal
                    claude plugin install horizontal@twarge
                    """
            }
        }

        var guide: URL {
            let page = self == .codex ? "codex" : "claude-code"
            return URL(string: "https://github.com/twarge/horizontal/blob/main/docs/\(page).md")!
        }
    }

    @State private var client: Client = .claudeCode
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Connect with", selection: $client) {
                ForEach(Client.allCases) { client in
                    Text(client.rawValue).tag(client)
                }
            }
            .pickerStyle(.segmented)
            Text("Use the \(client.rawValue) command line tool in the terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(client.commands)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(client.commands, forType: .string)
                    copied = true
                }
                Link("Setup Guide", destination: client.guide)
                Link("Install uv", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
            }
        }
        .onChange(of: client) { _, _ in copied = false }
    }
}
#endif

private struct ColorMatrixColumn: Identifiable {
    var kind: HorizontalCanvasKind
    var mode: HorizontalPaletteMode

    var id: String {
        "\(kind.rawValue)-\(mode.rawValue)"
    }

    var title: String {
        "\(kind.title) \(mode.title)"
    }
}

private let colorColumns: [ColorMatrixColumn] = [
    ColorMatrixColumn(kind: .schematic, mode: .light),
    ColorMatrixColumn(kind: .schematic, mode: .dark),
    ColorMatrixColumn(kind: .board, mode: .light),
    ColorMatrixColumn(kind: .board, mode: .dark),
]

/// Board layers draw in the light or the dark theme's colours whichever canvas
/// shows them, so their columns are just the board's.
private let layerColorColumns = colorColumns.filter { $0.kind == .board }

private let lineWidthKinds: [HorizontalCanvasKind] = [
    .schematic,
    .board,
]

private let schematicColorRoles: Set<HorizontalColorRole> = [
    .background,
    .grid,
    .textOverlay,
    .junction,
    .net,
    .bus,
    .frame,
    .pin,
    .pinAnnotation,
    .symbolBoundingBox,
    .error,
    .origin,
    .noPopulate,
    .netTie,
    .selectableOuter,
    .selectableInner,
    .selectablePrelight,
]

private let boardColorRoles: Set<HorizontalColorRole> = [
    .background,
    .grid,
    .textOverlay,
    .hole,
    .dimension,
    .error,
    .origin,
    .airwire,
    .connectionLine,
    .selectableOuter,
    .selectableInner,
    .selectablePrelight,
]
