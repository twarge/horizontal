import SwiftUI

struct HorizontalSettingsView: View {
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    var body: some View {
        Form {
            Section("Operation") {
                if HorizontalOperationDefaults.isReadOnlyOperationForced {
                    // Release builds are read-only and the toggle is not
                    // offered. Say so rather than showing a disabled switch or
                    // an empty section, so the state doesn't look like a bug.
                    Label("Read-only", systemImage: "lock")
                    Text("This build cannot modify project files. Selection, search, view options, and app preferences all work as normal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Read-only", isOn: appearanceSettings.readOnlyOperationBinding())
                    Text("Prevents project files from being modified. Selection, search, view options, and app preferences still work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("App Theme") {
                Picker("Theme", selection: appearanceSettings.appThemeBinding()) {
                    ForEach(HorizontalAppTheme.allCases) { theme in
                        Text(theme.title)
                            .tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("View Layout") {
                Toggle(
                    "Swap View Controls and Unplaced References",
                    isOn: appearanceSettings.swapViewControlsAndUnplacedReferencesBinding()
                )
            }

            Section("3D View Colors") {
                threeDViewColorRow("Background", selection: appearanceSettings.boardSceneBackgroundColorBinding())
                threeDViewColorRow("Substrate", selection: appearanceSettings.boardSceneSubstrateColorBinding())
                threeDViewColorRow("Solder Mask", selection: appearanceSettings.boardSceneSolderMaskColorBinding())
                threeDViewColorRow("Silkscreen", selection: appearanceSettings.boardSceneSilkscreenColorBinding())
                threeDViewColorRow("Copper", selection: appearanceSettings.boardSceneCopperColorBinding())

                HStack {
                    Spacer()
                    Button("Reset 3D View Colors") {
                        appearanceSettings.resetBoardSceneColors()
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("Cursor") {
                Picker("Size", selection: appearanceSettings.cursorSizeBinding()) {
                    ForEach(HorizontalCursorSize.allCases) { cursorSize in
                        Text(cursorSize.title)
                            .tag(cursorSize)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Selection Handles") {
                Picker("Shape", selection: appearanceSettings.selectionHandleShapeBinding()) {
                    ForEach(HorizontalSelectionHandleShape.allCases) { shape in
                        Text(shape.title)
                            .tag(shape)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Schematic") {
                Toggle("Fill Net Label Background", isOn: appearanceSettings.netLabelBackgroundBinding())
            }

            Section("Hover") {
                Toggle("Show Hover Popover", isOn: appearanceSettings.hoverPopoverBinding())
            }

            Section("Canvas Colors") {
                colorMatrixHeader(columns: colorColumns)
                ForEach(canvasColorRoles) { role in
                    colorRoleRow(role)
                }
            }

            Section("Selection Colors") {
                colorMatrixHeader(columns: colorColumns)
                ForEach(selectionColorRoles) { role in
                    colorRoleRow(role)
                }
            }

            Section("Layer Colors") {
                ForEach(editableLayers, id: \.self) { layer in
                    layerColorRow(layer)
                }
            }

            Section("Line Width") {
                gridLineWidthRow()
                ForEach(lineWidthKinds) { kind in
                    lineWidthRow(kind)
                }
            }

            Section("Reset") {
                resetControls
            }
        }
        .formStyle(.grouped)
        .frame(width: 680)
        .frame(minHeight: 640)
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
        HStack(spacing: 10) {
            Text("Color")
                .frame(width: 170, alignment: .leading)
            ForEach(columns) { column in
                Text(column.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 96)
            }
        }
        .padding(.vertical, 2)
    }

    private var resetControls: some View {
        HStack(spacing: 12) {
            ForEach(colorColumns) { column in
                Button("Reset \(column.title)") {
                    appearanceSettings.reset(kind: column.kind, mode: column.mode)
                }
            }
            Button("Reset Layer Colors") {
                appearanceSettings.resetLayerColors()
            }
        }
        .buttonStyle(.bordered)
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
        HStack(spacing: 10) {
            Text(layerName(for: layer))
                .frame(width: 170, alignment: .leading)
            ColorPicker(
                "\(layerName(for: layer)) Layer Color",
                selection: appearanceSettings.layerColorBinding(for: layer),
                supportsOpacity: false
            )
            .labelsHidden()
            Spacer(minLength: 0)
        }
    }

    private func threeDViewColorRow(_ title: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 170, alignment: .leading)
            ColorPicker(title, selection: selection, supportsOpacity: false)
                .labelsHidden()
            Spacer(minLength: 0)
        }
    }

    private func lineWidthRow(_ kind: HorizontalCanvasKind) -> some View {
        HStack(spacing: 12) {
            Text(kind.title)
                .frame(width: 170, alignment: .leading)
            Slider(
                value: appearanceSettings.minimumLineWidthBinding(for: kind),
                in: 0.5...4.0,
                step: 0.1
            )
            Text(
                appearanceSettings
                    .minimumLineWidthBinding(for: kind)
                    .wrappedValue
                    .formatted(.number.precision(.fractionLength(1))) + " px"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
            Button("Reset") {
                appearanceSettings.resetMinimumLineWidth(kind: kind)
            }
            .buttonStyle(.bordered)
        }
    }

    private func gridLineWidthRow() -> some View {
        HStack(spacing: 12) {
            Text("Grid marks")
                .frame(width: 170, alignment: .leading)
            Slider(
                value: appearanceSettings.gridLineWidthBinding(),
                in: 0.5...4.0,
                step: 0.1
            )
            Text(
                appearanceSettings
                    .gridLineWidthBinding()
                    .wrappedValue
                    .formatted(.number.precision(.fractionLength(1))) + " px"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
            Button("Reset") {
                appearanceSettings.resetGridLineWidth()
            }
            .buttonStyle(.bordered)
        }
    }

    private func colorMatrixRow(
        _ title: String,
        columns: [ColorMatrixColumn],
        binding: @escaping (ColorMatrixColumn) -> Binding<Color>?
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 170, alignment: .leading)
            ForEach(columns) { column in
                if let binding = binding(column) {
                    ColorPicker("\(title), \(column.title)", selection: binding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 96)
                        .accessibilityLabel("\(title), \(column.title)")
                } else {
                    Color.clear
                        .frame(width: 96)
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
    .connectionLine,
    .selectableOuter,
    .selectableInner,
    .selectablePrelight,
]
