import SwiftUI

// Cross-platform rail content components (layer/grid controls and tool buttons)
// extracted from ProjectDocumentView.swift so they compile on iOS as well as macOS.

func horizonLengthString(_ value: Double) -> String {
    let millimeters = value / 1_000_000
    return "\(millimeters.formatted(.number.precision(.fractionLength(2)))) mm"
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct LayerControlsPanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(14)
        .frame(width: 300)
        .frame(maxHeight: 520)
    }
}

struct LayerControlSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct GridControlsPanel: View {
    var title: String
    @Binding var grid: HorizontalGridSettings
    var isEditable = true

    private var modeBinding: Binding<String> {
        Binding {
            grid.mode
        } set: { mode in
            grid = grid.toggledMode(mode)
        }
    }

    private var squareSpacingBinding: Binding<Double> {
        Binding {
            grid.spacingSquare
        } set: { value in
            var draft = grid
            draft.spacingSquare = value
            grid = draft.withClampedValues()
        }
    }

    private var rectSpacingXBinding: Binding<Double> {
        Binding {
            grid.spacingRect.x
        } set: { value in
            var draft = grid
            draft.spacingRect.x = value
            grid = draft.withClampedValues()
        }
    }

    private var rectSpacingYBinding: Binding<Double> {
        Binding {
            grid.spacingRect.y
        } set: { value in
            var draft = grid
            draft.spacingRect.y = value
            grid = draft.withClampedValues()
        }
    }

    private var originXBinding: Binding<Double> {
        Binding {
            grid.origin.x
        } set: { value in
            var draft = grid
            draft.origin.x = value
            grid = draft.withClampedValues()
        }
    }

    private var originYBinding: Binding<Double> {
        Binding {
            grid.origin.y
        } set: { value in
            var draft = grid
            draft.origin.y = value
            grid = draft.withClampedValues()
        }
    }

    var body: some View {
        LayerControlsPanel(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: modeBinding) {
                    Text("Square").tag("square")
                    Text("Rect").tag("rect")
                }
                .pickerStyle(.segmented)

                LayerControlSection(title: "Spacing") {
                    if grid.mode == "rect" {
                        GridDimensionField(
                            title: "X",
                            value: rectSpacingXBinding,
                            range: HorizontalGridSettings.minimumSpacing...HorizontalGridSettings.maximumSpacing,
                            step: 10_000
                        )
                        GridDimensionField(
                            title: "Y",
                            value: rectSpacingYBinding,
                            range: HorizontalGridSettings.minimumSpacing...HorizontalGridSettings.maximumSpacing,
                            step: 10_000
                        )
                    } else {
                        GridDimensionField(
                            title: "Size",
                            value: squareSpacingBinding,
                            range: HorizontalGridSettings.minimumSpacing...HorizontalGridSettings.maximumSpacing,
                            step: 10_000
                        )
                    }
                }

                LayerControlSection(title: "Origin") {
                    GridDimensionField(
                        title: "X0",
                        value: originXBinding,
                        range: HorizontalGridSettings.minimumOrigin...HorizontalGridSettings.maximumOrigin,
                        step: 100_000
                    )
                    GridDimensionField(
                        title: "Y0",
                        value: originYBinding,
                        range: HorizontalGridSettings.minimumOrigin...HorizontalGridSettings.maximumOrigin,
                        step: 100_000
                    )
                    Button("Reset Origin") {
                        var draft = grid
                        draft.origin = .zero
                        grid = draft.withClampedValues()
                    }
                }
            }
            .disabled(!isEditable)
            .opacity(isEditable ? 1 : 0.48)
        }
    }
}

struct GridDimensionField: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    private var millimeterBinding: Binding<Double> {
        Binding {
            value / 1_000_000
        } set: { newValue in
            value = (newValue * 1_000_000).clamped(to: range)
        }
    }

    private var millimeterRange: ClosedRange<Double> {
        (range.lowerBound / 1_000_000)...(range.upperBound / 1_000_000)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 34, alignment: .leading)
            TextField(
                title,
                value: millimeterBinding,
                format: .number.precision(.fractionLength(3))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 88)
            Text("mm")
                .foregroundStyle(.secondary)
            Stepper(
                title,
                value: millimeterBinding,
                in: millimeterRange,
                step: step / 1_000_000
            )
            .labelsHidden()
        }
    }
}

struct SelectionToolButton: View {
    @Binding var settings: HorizontalSelectionToolSettings
    @State private var isPopoverPresented = false

    private var iconName: String {
        switch settings.tool {
        case .box: "square.dashed"
        case .lasso: "lasso"
        case .paint: "paintbrush"
        }
    }

    var body: some View {
        HorizontalRailHelpLabel(title: "Selection tools") {
            Button {
                isPopoverPresented.toggle()
            } label: {
                Image(systemName: iconName)
            }
            .help("Selection tools")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                SelectionToolPanel(settings: $settings)
            }
        }
    }
}

struct SelectionToolPanel: View {
    @Binding var settings: HorizontalSelectionToolSettings

    var body: some View {
        LayerControlsPanel(title: "Selection") {
            VStack(alignment: .leading, spacing: 12) {
                LayerControlSection(title: "Tool") {
                    Picker("Tool", selection: $settings.tool) {
                        ForEach(HorizontalSelectionTool.allCases) { tool in
                            Text(tool.title).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                LayerControlSection(title: "Selection Mode") {
                    Picker("Mode", selection: $settings.qualifier) {
                        ForEach(qualifierOptions) { qualifier in
                            Text(qualifier.title).tag(qualifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(settings.tool == .paint)
                    Text(modeHelpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LayerControlSection(title: "Sticky Selection") {
                    Toggle("Use sticky selection", isOn: $settings.stickySelection)
                    Picker("Action", selection: $settings.modifierAction) {
                        ForEach(HorizontalSelectionModifierAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.stickySelection)
                    .opacity(settings.stickySelection ? 1 : 0.5)
                }
            }
            .onChange(of: settings.tool) { _, tool in
                normalizeSettings(for: tool)
            }
        }
    }

    private var modeHelpText: String {
        switch settings.tool {
        case .box:
            "Auto includes enclosed objects left-to-right and touches objects right-to-left."
        case .lasso:
            "Lasso can include origins, whole boxes, or anything touched by the lasso."
        case .paint:
            "Paint selection touches objects along the stroke."
        }
    }

    private var qualifierOptions: [HorizontalSelectionQualifier] {
        switch settings.tool {
        case .box:
            return HorizontalSelectionQualifier.allCases
        case .lasso:
            return HorizontalSelectionQualifier.allCases.filter { $0 != .auto }
        case .paint:
            return [.touchBox]
        }
    }

    private func normalizeSettings(for tool: HorizontalSelectionTool) {
        switch tool {
        case .box:
            break
        case .lasso:
            if settings.qualifier == .auto {
                settings.qualifier = .includeOrigin
            }
        case .paint:
            settings.qualifier = .touchBox
        }
    }
}

struct BoardSyncToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Reload board netlist from schematic") {
            Button(action: action) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Reload board netlist from schematic")
        }
    }
}

struct BoardRulesToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Board rules") {
            Button(action: action) {
                Image(systemName: "checklist.checked")
            }
            .help("Board rules")
        }
    }
}

/// The rail's plane control: pours the fills, reports that they are out of date,
/// and shows the pour's progress in place of its own icon.
///
/// Progress lives here rather than over the canvas because a pour no longer
/// blocks editing — if the board moves while it runs the result is discarded —
/// so there is nothing to cover, and the indicator belongs on the control that
/// started the work.
struct BoardUpdatePlanesToolButton: View {
    var action: () -> Void
    var isUpdating = false
    /// nil while updating means a pour too small to report a fraction.
    var progress: Double?
    /// The board changed since the last pour, so the fills on screen are stale.
    var needsUpdate = false

    private var title: String {
        if isUpdating { return "Updating plane fills..." }
        return needsUpdate ? "Plane fills are out of date" : "Update all plane fills"
    }

    var body: some View {
        HorizontalRailHelpLabel(title: title) {
            Button(action: action) {
                if isUpdating {
                    if let progress {
                        CanvasProgressRing(progress: progress, diameter: 17, showsPercentage: false)
                    } else {
                        CanvasIndeterminateRing(diameter: 17)
                    }
                } else {
                    Image(systemName: "square.stack.3d.up.badge.automatic")
                        // Stale fills are worth noticing without being an alarm:
                        // the board is still perfectly usable, the pour is just
                        // older than the copper.
                        .foregroundStyle(needsUpdate ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                        .symbolVariant(needsUpdate ? .fill : .none)
                }
            }
            .disabled(isUpdating)
            .help(title + (needsUpdate && !isUpdating ? " (Q)" : ""))
            .accessibilityLabel(title)
        }
    }
}

struct DrawNetLineToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Draw net") {
            Button(action: action) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
            }
            .help("Draw net line (N)")
        }
    }
}

struct DrawTrackToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Draw track") {
            Button(action: action) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Draw copper track (X)")
        }
    }
}

struct AddTextToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Add text") {
            Button(action: action) {
                Image(systemName: "character.textbox")
            }
            .help("Add a text annotation")
        }
    }
}

struct PlacePadToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Place pad") {
            Button(action: action) {
                Image(systemName: "circle.grid.2x2")
            }
            .help("Place pads from a padstack (P)")
        }
    }
}

struct PlaceShapeToolButtonGroup: View {
    var action: (HorizontalPadstackShapeForm) -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Place shape") {
            Menu {
                ForEach(HorizontalPadstackShapeForm.allCases, id: \.self) { form in
                    Button(form.displayName) {
                        action(form)
                    }
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle.circle")
            }
            .help("Place a circular, rectangular or obround shape")
        }
    }
}

struct PlaceHoleToolButtonGroup: View {
    var action: (HorizontalHoleShape) -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Place hole") {
            Menu {
                Button("Round") {
                    action(.round)
                }
                Button("Slot") {
                    action(.slot)
                }
            } label: {
                Image(systemName: "circle.dotted")
            }
            .help("Place a round or slot hole")
        }
    }
}

struct PlacePinToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Place pin") {
            Button(action: action) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Place the next unplaced pin (P)")
        }
    }
}

struct PlaceRefdesValueToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Place refdes and value") {
            Button(action: action) {
                Image(systemName: "textformat.abc")
            }
            .help("Place $REFDES and $VALUE texts")
        }
    }
}

struct PlaceDotToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Place dot") {
            Button(action: action) {
                Image(systemName: "circle.fill")
            }
            .help("Place a filled dot")
        }
    }
}

struct DrawPlaneToolButton: View {
    var action: () -> Void

    var body: some View {
        HorizontalRailHelpLabel(title: "Draw plane") {
            Button(action: action) {
                Image(systemName: "square.dashed")
            }
            .help("Draw a copper plane")
        }
    }
}

struct TrackSettingsToolButton: View {
    @Binding var presented: Bool

    var body: some View {
        HorizontalRailHelpLabel(title: "Track settings") {
            Button {
                presented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Track tool settings (S)")
        }
    }
}

struct BoardStackupToolButton: View {
    var board: HorizontalBoard?
    var isReadOnly: Bool
    var onBoardChange: (HorizontalBoard) -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        HorizontalRailHelpLabel(title: "Board stackup") {
            Button {
                isPopoverPresented.toggle()
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .help("Board stackup")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                if let board {
                    BoardStackupEditorPanel(
                        board: board,
                        isReadOnly: isReadOnly,
                        onBoardChange: onBoardChange
                    )
                } else {
                    Text("No board file was loaded.")
                        .padding(14)
                        .frame(width: 260)
                }
            }
        }
    }
}

struct BoardStackupEditorPanel: View {
    var board: HorizontalBoard
    var isReadOnly: Bool
    var onBoardChange: (HorizontalBoard) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    private var theme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    private var innerLayerCount: Int {
        board.stackupLayers.filter {
            HorizontalBoardLayers.category(for: $0.layer) == .innerCopper
        }.count
    }

    private var innerLayerCountBinding: Binding<Int> {
        Binding {
            innerLayerCount
        } set: { newValue in
            setInnerLayerCount(newValue)
        }
    }

    private var rows: [BoardStackupEditorRow] {
        Self.stackupRows(for: board)
    }

    private var finishedThickness: Double {
        rows
            .filter(\.isCopper)
            .reduce(0) { total, row in
                let stackupLayer = board.stackupLayers.first(where: { $0.layer == row.layer })
                    ?? Self.defaultStackupLayer(for: row.layer)
                return total + stackupLayer.copperThickness + stackupLayer.substrateThickness
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stackup")
                    .font(.headline.weight(.semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Finished Thickness")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(horizonLengthString(finishedThickness))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
            }

            innerLayerControl

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        BoardStackupLayerRow(
                            row: row,
                            color: color(for: row),
                            isReadOnly: isReadOnly,
                            canAddUserLayer: board.userLayers.count < HorizontalBoardLayers.maxUserLayers,
                            copperThickness: copperThicknessBinding(for: row.layer),
                            substrateThickness: substrateThicknessBinding(for: row.layer),
                            userLayerName: userLayerNameBinding(for: row.layer),
                            userLayerType: userLayerTypeBinding(for: row.layer),
                            userLayerColor: userLayerColorBinding(for: row.layer),
                            addUserLayer: { order in addUserLayer(relativeTo: row.layer, order: order) },
                            deleteUserLayer: { deleteUserLayer(row.layer) },
                            moveUserLayer: { direction in moveUserLayer(row.layer, direction: direction) }
                        )
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .padding(14)
        .frame(width: 620)
        .frame(maxHeight: 680)
    }

    private var innerLayerControl: some View {
        HStack(spacing: 10) {
            Text("Inner Layers")
                .foregroundStyle(.secondary)
            TextField(
                "Inner Layers",
                value: innerLayerCountBinding,
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            Stepper(
                "Inner Layers",
                value: innerLayerCountBinding,
                in: 0...HorizontalBoardLayers.maxInnerLayers
            )
            .labelsHidden()
            Spacer()
        }
        .disabled(isReadOnly)
        .opacity(isReadOnly ? 0.55 : 1)
    }

    private func color(for row: BoardStackupEditorRow) -> Color {
        if let userLayer = row.userLayer {
            return theme.layerColor(for: userLayer.colorLayer)
        }
        return theme.layerColor(for: row.layer)
    }

    private func copperThicknessBinding(for layer: Int) -> Binding<Double> {
        Binding {
            let value = board.stackupLayers.first(where: { $0.layer == layer })?.copperThickness
                ?? Self.defaultStackupLayer(for: layer).copperThickness
            return value / Self.unitsPerMillimeter
        } set: { newValue in
            updateStackup(layer: layer) { stackupLayer in
                stackupLayer.copperThickness = Self.nanometers(fromMillimeters: newValue)
            }
        }
    }

    private func substrateThicknessBinding(for layer: Int) -> Binding<Double> {
        Binding {
            let value = board.stackupLayers.first(where: { $0.layer == layer })?.substrateThickness
                ?? Self.defaultStackupLayer(for: layer).substrateThickness
            return value / Self.unitsPerMillimeter
        } set: { newValue in
            updateStackup(layer: layer) { stackupLayer in
                stackupLayer.substrateThickness = Self.nanometers(fromMillimeters: newValue)
            }
        }
    }

    private func userLayerNameBinding(for layer: Int) -> Binding<String> {
        Binding {
            board.userLayers.first(where: { $0.id == layer })?.name ?? HorizontalBoardLayers.name(for: layer)
        } set: { newValue in
            updateUserLayer(layer) { userLayer in
                userLayer.name = newValue
            }
        }
    }

    private func userLayerTypeBinding(for layer: Int) -> Binding<String> {
        Binding {
            board.userLayers.first(where: { $0.id == layer })?.type ?? Self.userLayerTypes[0].id
        } set: { newValue in
            updateUserLayer(layer) { userLayer in
                userLayer.type = newValue
            }
        }
    }

    private func userLayerColorBinding(for layer: Int) -> Binding<Int> {
        Binding {
            board.userLayers.first(where: { $0.id == layer })?.colorLayer ?? layer
        } set: { newValue in
            updateUserLayer(layer) { userLayer in
                userLayer.colorLayer = newValue
            }
        }
    }

    private func setInnerLayerCount(_ count: Int) {
        let clampedCount = count.clamped(to: 0...HorizontalBoardLayers.maxInnerLayers)
        updateBoard { draft in
            draft.stackupLayers = Self.normalizedStackupLayers(
                from: draft.stackupLayers,
                userLayers: draft.userLayers,
                innerLayerCount: clampedCount
            )
        }
    }

    private func updateStackup(
        layer: Int,
        mutate: (inout HorizontalBoardStackupLayer) -> Void
    ) {
        updateBoard { draft in
            if let index = draft.stackupLayers.firstIndex(where: { $0.layer == layer }) {
                mutate(&draft.stackupLayers[index])
            } else {
                var stackupLayer = Self.defaultStackupLayer(for: layer)
                mutate(&stackupLayer)
                draft.stackupLayers.append(stackupLayer)
            }
            draft.stackupLayers = Self.normalizedStackupLayers(
                from: draft.stackupLayers,
                userLayers: draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
        }
    }

    private func updateUserLayer(
        _ layer: Int,
        mutate: (inout HorizontalBoardUserLayer) -> Void
    ) {
        updateBoard { draft in
            guard let index = draft.userLayers.firstIndex(where: { $0.id == layer }) else {
                return
            }
            mutate(&draft.userLayers[index])
            draft.userLayers = Self.assignedUserLayerPositions(
                draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
            draft.stackupLayers = Self.normalizedStackupLayers(
                from: draft.stackupLayers,
                userLayers: draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
        }
    }

    private func addUserLayer(relativeTo layer: Int, order: BoardStackupUserLayerOrder) {
        guard board.userLayers.count < HorizontalBoardLayers.maxUserLayers else {
            return
        }
        updateBoard { draft in
            guard let id = Self.nextAvailableUserLayerID(in: draft.userLayers) else {
                return
            }
            let offset = 1.0 / Double(2 * HorizontalBoardLayers.maxUserLayers)
            let referencePosition = Self.position(of: layer, in: draft)
            let position = referencePosition + offset * Double(order.rawValue)
            draft.userLayers.append(
                HorizontalBoardUserLayer(
                    id: id,
                    colorLayer: id,
                    name: "User Layer \(id - HorizontalBoardLayers.firstUserLayer)",
                    type: Self.userLayerTypes[0].id,
                    position: position
                )
            )
            draft.userLayers = Self.assignedUserLayerPositions(
                draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
            draft.stackupLayers = Self.normalizedStackupLayers(
                from: draft.stackupLayers,
                userLayers: draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
        }
    }

    private func deleteUserLayer(_ layer: Int) {
        updateBoard { draft in
            draft.userLayers.removeAll { $0.id == layer }
            draft.stackupLayers.removeAll { $0.layer == layer }
            draft.userLayers = Self.assignedUserLayerPositions(
                draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
            draft.stackupLayers = Self.normalizedStackupLayers(
                from: draft.stackupLayers,
                userLayers: draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
        }
    }

    private func moveUserLayer(_ layer: Int, direction: Int) {
        updateBoard { draft in
            guard let index = draft.userLayers.firstIndex(where: { $0.id == layer }),
                  let adjacentLayer = Self.adjacentLayer(to: layer, direction: direction, in: draft) else {
                return
            }
            let offset = 1.0 / Double(2 * HorizontalBoardLayers.maxUserLayers)
            draft.userLayers[index].position = Self.position(of: adjacentLayer, in: draft)
                + offset * Double(direction > 0 ? 1 : -1)
            draft.userLayers = Self.assignedUserLayerPositions(
                draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
            draft.stackupLayers = Self.normalizedStackupLayers(
                from: draft.stackupLayers,
                userLayers: draft.userLayers,
                innerLayerCount: Self.innerLayerCount(in: draft.stackupLayers)
            )
        }
    }

    private func updateBoard(_ mutate: (inout HorizontalBoard) -> Void) {
        guard !isReadOnly else {
            return
        }
        var draft = board
        mutate(&draft)
        onBoardChange(draft)
    }

    private static let unitsPerMillimeter = 1_000_000.0
    private static let defaultCopperThickness = 35_000.0
    private static let defaultSubstrateThickness = 100_000.0
    private static let defaultTopSubstrateThickness = 1_600_000.0
    private static let maximumThickness = 10_000_000.0

    static let userLayerTypes: [(id: String, title: String)] = [
        ("documentation", "Documentation"),
        ("stiffener", "Stiffener"),
        ("bend_area", "Bend area"),
        ("flex_area", "Flex area"),
        ("rigid_area", "Rigid area"),
        ("carbon_mask", "Carbon mask"),
        ("silver_mask", "Silver mask"),
        ("covercoat", "Covercoat"),
        ("coverlay", "Coverlay"),
        ("psa", "PSA")
    ]

    private static func nanometers(fromMillimeters value: Double) -> Double {
        (value * unitsPerMillimeter).clamped(to: 0...maximumThickness)
    }

    private static func defaultStackupLayer(for layer: Int) -> HorizontalBoardStackupLayer {
        let substrateThickness: Double
        if layer == HorizontalBoardLayers.topCopper {
            substrateThickness = defaultTopSubstrateThickness
        } else if layer == HorizontalBoardLayers.bottomCopper {
            substrateThickness = 0
        } else {
            substrateThickness = defaultSubstrateThickness
        }
        return HorizontalBoardStackupLayer(
            layer: layer,
            copperThickness: defaultCopperThickness,
            substrateThickness: substrateThickness
        )
    }

    private static func innerLayerCount(in stackupLayers: [HorizontalBoardStackupLayer]) -> Int {
        stackupLayers.filter {
            HorizontalBoardLayers.category(for: $0.layer) == .innerCopper
        }.count
    }

    private static func normalizedStackupLayers(
        from stackupLayers: [HorizontalBoardStackupLayer],
        userLayers: [HorizontalBoardUserLayer],
        innerLayerCount: Int
    ) -> [HorizontalBoardStackupLayer] {
        let existing = Dictionary(uniqueKeysWithValues: stackupLayers.map { ($0.layer, $0) })
        var requiredLayers = [HorizontalBoardLayers.topCopper]
        if innerLayerCount > 0 {
            requiredLayers.append(contentsOf: (1...innerLayerCount).map { -$0 })
        }
        requiredLayers.append(HorizontalBoardLayers.bottomCopper)
        requiredLayers.append(contentsOf: userLayers.map(\.id))

        return requiredLayers
            .map { existing[$0] ?? defaultStackupLayer(for: $0) }
            .sorted { stackupSortKey($0.layer) < stackupSortKey($1.layer) }
    }

    private static func stackupSortKey(_ layer: Int) -> Int {
        if layer == HorizontalBoardLayers.topCopper {
            return 0
        }
        if HorizontalBoardLayers.category(for: layer) == .innerCopper {
            return abs(layer)
        }
        if layer == HorizontalBoardLayers.bottomCopper {
            return 10_000
        }
        return 20_000 + layer
    }

    private static func stackupRows(for board: HorizontalBoard) -> [BoardStackupEditorRow] {
        let fixedLayers = [
            HorizontalBoardLayers.topNotes,
            HorizontalBoardLayers.outlineNotes,
            HorizontalBoardLayers.outline,
            HorizontalBoardLayers.topCourtyard,
            HorizontalBoardLayers.topAssembly,
            HorizontalBoardLayers.topPackage,
            HorizontalBoardLayers.topPaste,
            HorizontalBoardLayers.topSilkscreen,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper
        ] + board.stackupLayers
            .map(\.layer)
            .filter { HorizontalBoardLayers.category(for: $0) == .innerCopper }
            .sorted { abs($0) < abs($1) }
        + [
            HorizontalBoardLayers.bottomCopper,
            HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.bottomSilkscreen,
            HorizontalBoardLayers.bottomPaste,
            HorizontalBoardLayers.bottomPackage,
            HorizontalBoardLayers.bottomAssembly,
            HorizontalBoardLayers.bottomCourtyard,
            HorizontalBoardLayers.bottomNotes
        ]

        let fixedRows = fixedLayers.map {
            BoardStackupEditorRow(layer: $0, title: HorizontalBoardLayers.name(for: $0), position: Double($0), userLayer: nil)
        }
        let userRows = board.userLayers.map {
            BoardStackupEditorRow(layer: $0.id, title: $0.name, position: $0.position ?? Double($0.id), userLayer: $0)
        }
        return (fixedRows + userRows).sorted {
            if $0.position == $1.position {
                return $0.layer > $1.layer
            }
            return $0.position > $1.position
        }
    }

    private static func assignedUserLayerPositions(
        _ userLayers: [HorizontalBoardUserLayer],
        innerLayerCount: Int
    ) -> [HorizontalBoardUserLayer] {
        guard !userLayers.isEmpty else {
            return []
        }

        let fixedLayers = [
            HorizontalBoardLayers.topNotes,
            HorizontalBoardLayers.outlineNotes,
            HorizontalBoardLayers.outline,
            HorizontalBoardLayers.topCourtyard,
            HorizontalBoardLayers.topAssembly,
            HorizontalBoardLayers.topPackage,
            HorizontalBoardLayers.topPaste,
            HorizontalBoardLayers.topSilkscreen,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper
        ] + (innerLayerCount > 0 ? (1...innerLayerCount).map { -$0 } : [])
        + [
            HorizontalBoardLayers.bottomCopper,
            HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.bottomSilkscreen,
            HorizontalBoardLayers.bottomPaste,
            HorizontalBoardLayers.bottomPackage,
            HorizontalBoardLayers.bottomAssembly,
            HorizontalBoardLayers.bottomCourtyard,
            HorizontalBoardLayers.bottomNotes
        ]

        enum LayerPositionKind {
            case fixed(Int)
            case user(Int)
        }

        let fixedPositions = fixedLayers.map {
            (kind: LayerPositionKind.fixed($0), position: Double($0))
        }
        let userPositions = userLayers.map {
            (kind: LayerPositionKind.user($0.id), position: $0.position ?? Double($0.id))
        }
        let orderedLayers = (fixedPositions + userPositions).sorted { lhs, rhs in
            if lhs.position == rhs.position {
                switch (lhs.kind, rhs.kind) {
                case (.fixed(let lhsLayer), .fixed(let rhsLayer)):
                    return lhsLayer < rhsLayer
                case (.user(let lhsLayer), .user(let rhsLayer)):
                    return lhsLayer < rhsLayer
                case (.fixed, .user):
                    return true
                case (.user, .fixed):
                    return false
                }
            }
            return lhs.position < rhs.position
        }

        var byID = Dictionary(uniqueKeysWithValues: userLayers.map { ($0.id, $0) })
        let step = 1.0 / Double(HorizontalBoardLayers.maxUserLayers)
        var position = Double(HorizontalBoardLayers.bottomNotes - 1)
        for layer in orderedLayers {
            switch layer.kind {
            case .fixed(let fixedLayer):
                position = Double(fixedLayer)
            case .user(let userLayer):
                position += step
                byID[userLayer]?.position = position
            }
        }

        return byID.values.sorted {
            ($0.position ?? Double($0.id)) < ($1.position ?? Double($1.id))
        }
    }

    private static func nextAvailableUserLayerID(in userLayers: [HorizontalBoardUserLayer]) -> Int? {
        let used = Set(userLayers.map(\.id))
        return (HorizontalBoardLayers.firstUserLayer...HorizontalBoardLayers.lastUserLayer)
            .first { !used.contains($0) }
    }

    private static func position(of layer: Int, in board: HorizontalBoard) -> Double {
        if let userLayer = board.userLayers.first(where: { $0.id == layer }) {
            return userLayer.position ?? Double(layer)
        }
        return Double(layer)
    }

    private static func adjacentLayer(to layer: Int, direction: Int, in board: HorizontalBoard) -> Int? {
        let currentPosition = position(of: layer, in: board)
        let candidates = stackupRows(for: board).filter { $0.layer != layer }
        if direction > 0 {
            return candidates
                .filter { $0.position > currentPosition }
                .min { $0.position < $1.position }?
                .layer
        }
        return candidates
            .filter { $0.position < currentPosition }
            .max { $0.position < $1.position }?
            .layer
    }
}

enum BoardStackupUserLayerOrder: Int {
    case above = 1
    case below = -1
}

struct BoardStackupEditorRow: Identifiable {
    var layer: Int
    var title: String
    var position: Double
    var userLayer: HorizontalBoardUserLayer?

    var id: String {
        userLayer == nil ? "layer-\(layer)" : "user-\(layer)"
    }

    var isCopper: Bool {
        HorizontalBoardLayers.isCopper(layer) && userLayer == nil
    }

    var isBottomCopper: Bool {
        layer == HorizontalBoardLayers.bottomCopper
    }

    var isUserLayer: Bool {
        userLayer != nil
    }
}

struct BoardStackupLayerRow: View {
    var row: BoardStackupEditorRow
    var color: Color
    var isReadOnly: Bool
    var canAddUserLayer: Bool
    @Binding var copperThickness: Double
    @Binding var substrateThickness: Double
    @Binding var userLayerName: String
    @Binding var userLayerType: String
    @Binding var userLayerColor: Int
    var addUserLayer: (BoardStackupUserLayerOrder) -> Void
    var deleteUserLayer: () -> Void
    var moveUserLayer: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(color)
                .frame(width: 22, height: row.isCopper ? 44 : 22)
                .overlay {
                    Rectangle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                }

            layerTitle
                .frame(minWidth: 170, maxWidth: 210, alignment: .leading)

            Spacer(minLength: 8)

            if row.isCopper {
                VStack(alignment: .trailing, spacing: 3) {
                    BoardStackupDimensionField(title: "Height", value: $copperThickness)
                    if !row.isBottomCopper {
                        BoardStackupDimensionField(title: "Substrate height", value: $substrateThickness)
                    }
                }
            } else if row.isUserLayer {
                userLayerControls
            }

            userLayerEditButtons
        }
        .padding(.horizontal, 2)
        .padding(.vertical, row.isCopper ? 2 : 2)
        .disabled(isReadOnly)
        .opacity(isReadOnly ? 0.55 : 1)
    }

    @ViewBuilder
    private var layerTitle: some View {
        if row.isUserLayer {
            TextField("Layer name", text: $userLayerName)
                .textFieldStyle(.roundedBorder)
        } else {
            Text(row.title)
                .lineLimit(1)
        }
    }

    private var userLayerControls: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Picker("Type", selection: $userLayerType) {
                ForEach(BoardStackupEditorPanel.userLayerTypes, id: \.id) { item in
                    Text(item.title).tag(item.id)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            Picker("Color", selection: $userLayerColor) {
                ForEach(HorizontalBoardLayers.firstUserLayer...HorizontalBoardLayers.lastUserLayer, id: \.self) { layer in
                    Text(HorizontalBoardLayers.name(for: layer)).tag(layer)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private var userLayerEditButtons: some View {
        HStack(spacing: 6) {
            if row.isUserLayer {
                VStack(spacing: 4) {
                    Button {
                        moveUserLayer(1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help("Move user layer up")

                    Button {
                        moveUserLayer(-1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help("Move user layer down")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    deleteUserLayer()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .help("Delete user layer")
            }

            Menu {
                Button("Add user layer above") {
                    addUserLayer(.above)
                }
                Button("Add user layer below") {
                    addUserLayer(.below)
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .help(canAddUserLayer ? "Add user layer" : "No more user layers available")
            .disabled(!canAddUserLayer)
        }
        .frame(width: row.isUserLayer ? 92 : 38, alignment: .trailing)
    }
}

struct BoardStackupDimensionField: View {
    var title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            TextField(
                title,
                value: $value,
                format: .number.precision(.fractionLength(5))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 86)
            Text("mm")
                .foregroundStyle(.secondary)
            Stepper(title, value: $value, in: 0...10, step: 0.001)
                .labelsHidden()
        }
        .controlSize(.small)
    }
}

struct DrawingToolButtonGroup: View {
    var primitives: [HorizontalDrawingPrimitive] = [.line, .rectangle, .circle, .arc]
    var onSelect: (HorizontalDrawingPrimitive) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(primitives) { primitive in
                HorizontalRailHelpLabel(title: "Draw \(primitive.title.lowercased())") {
                    Button {
                        onSelect(primitive)
                    } label: {
                        DrawingPrimitiveIcon(primitive: primitive)
                    }
                    .help("Draw \(primitive.title.lowercased())")
                }
            }
        }
    }
}

struct DrawingPrimitiveIcon: View {
    var primitive: HorizontalDrawingPrimitive

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            var path = Path()

            switch primitive {
            case .line:
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            case .rectangle:
                path.addRect(rect)
            case .circle:
                path.addEllipse(in: rect)
            case .arc:
                path.addArc(
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) * 0.46,
                    startAngle: .degrees(205),
                    endAngle: .degrees(20),
                    clockwise: false
                )
            case .polygon:
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.08))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY - rect.height * 0.08))
                path.closeSubpath()
            }

            context.stroke(
                path,
                with: .color(.primary),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 19, height: 19)
        .accessibilityLabel(primitive.title)
    }
}

struct NetClassToolButton: View {
    @Binding var netClasses: [HorizontalNetClass]
    var usedNetClassIDs: Set<String>
    @State private var isPopoverPresented = false

    var body: some View {
        HorizontalRailHelpLabel(title: "Schematic net classes") {
            Button {
                isPopoverPresented.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help("Schematic net classes")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                NetClassEditorPanel(netClasses: $netClasses, usedNetClassIDs: usedNetClassIDs)
            }
        }
    }
}

struct NetClassEditorPanel: View {
    @Binding var netClasses: [HorizontalNetClass]
    var usedNetClassIDs: Set<String>

    var body: some View {
        LayerControlsPanel(title: "Net Classes") {
            HStack(spacing: 8) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addNetClass()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add net class")
            }

            if netClasses.isEmpty {
                Text("No net classes")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach($netClasses) { $netClass in
                        let isUsed = isNetClassUsed(netClass.id)
                        HStack(spacing: 8) {
                            TextField("Name", text: $netClass.name)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1)
                            Button {
                                removeNetClass(id: netClass.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.secondary.opacity(isUsed ? 0.38 : 1))
                            .disabled(isUsed)
                            .help(isUsed ? "This net class is used in the design" : "Remove net class")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 260)
    }

    private func addNetClass() {
        netClasses.append(HorizontalNetClass(id: uniqueNetClassID(), name: uniqueNetClassName()))
    }

    private func removeNetClass(id: String) {
        guard !isNetClassUsed(id) else {
            return
        }
        let normalized = normalizedID(id)
        netClasses.removeAll { normalizedID($0.id) == normalized }
    }

    private func isNetClassUsed(_ id: String) -> Bool {
        usedNetClassIDs.contains(normalizedID(id))
    }

    private func uniqueNetClassID() -> String {
        var id: String
        repeat {
            id = UUID().uuidString.lowercased()
        } while netClasses.contains { normalizedID($0.id) == id }
        return id
    }

    private func uniqueNetClassName() -> String {
        let existingNames = Set(netClasses.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !existingNames.contains("New class") {
            return "New class"
        }

        var index = 2
        while existingNames.contains("New class \(index)") {
            index += 1
        }
        return "New class \(index)"
    }

    private func normalizedID(_ id: String) -> String {
        id.lowercased()
    }
}

struct SchematicLayerControls: View {
    @Binding var displayOptions: SchematicDisplayOptions
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    private var theme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .schematic, colorScheme: colorScheme)
    }

    var body: some View {
        LayerControlsPanel(title: "Schematic Layers") {
            SchematicDisplayPresetButtons(displayOptions: $displayOptions)

            LayerControlSection(title: "Layers") {
                BoardDisplayToggle(title: "Frame", isOn: $displayOptions.frame)
                BoardDisplayToggle(title: "Drawing", isOn: $displayOptions.drawing)
                BoardDisplayToggle(title: "Symbols", isOn: $displayOptions.symbols)
                BoardDisplayToggle(title: "Block Symbols", isOn: $displayOptions.blockSymbols)
                BoardDisplayToggle(title: "Nets", color: theme.net, isOn: $displayOptions.nets)
                BoardDisplayToggle(title: "Net Labels", color: theme.net, isOn: $displayOptions.netLabels)
                BoardDisplayToggle(title: "Junctions", color: theme.junction, isOn: $displayOptions.junctions)
                BoardDisplayToggle(title: "Net Ties", color: theme.netTie, isOn: $displayOptions.netTies)
                BoardDisplayToggle(title: "Buses", color: theme.bus, isOn: $displayOptions.buses)
                BoardDisplayToggle(title: "Power", color: theme.net, isOn: $displayOptions.power)
                BoardDisplayToggle(title: "Text", isOn: $displayOptions.text)
            }

            LayerControlSection(title: "View") {
                BoardDisplayToggle(title: "Grid", isOn: $displayOptions.grid)
                BoardDisplayToggle(title: "Origin", color: theme.origin, isOn: $displayOptions.origin)
                BoardDisplayToggle(title: "Coordinates", isOn: $displayOptions.coordinates)
            }
        }
    }
}

struct SchematicDisplayPresetButtons: View {
    @Binding var displayOptions: SchematicDisplayOptions

    var body: some View {
        HStack(spacing: 6) {
            Button {
                displayOptions.showAll()
            } label: {
                Image(systemName: "square.stack.3d.up.fill")
            }
            .help("Show all schematic layers")

            Button {
                displayOptions.logicalOnly()
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .help("Show schematic connectivity")

            Button {
                displayOptions.artworkOnly()
            } label: {
                Image(systemName: "pencil.and.outline")
            }
            .help("Show schematic artwork")

            Button {
                displayOptions.labelsOnly()
            } label: {
                Image(systemName: "tag")
            }
            .help("Show schematic labels and connectivity")

            Button {
                displayOptions.cleanView()
            } label: {
                Image(systemName: "camera.filters")
            }
            .help("Show schematic content without view aids")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

struct BoardLayerControls: View {
    var board: HorizontalBoard?
    @Binding var displayOptions: BoardDisplayOptions
    @Binding var selectedLayer: Int
    var includesThreeDControls: Bool
    /// A pool item editor's fixed layer set, top to bottom; nil lists the
    /// board's full stack.
    var layers: [Int]? = nil
    /// Board-only object toggles (vias, connections, decals) are hidden for
    /// pool items, which have none.
    var showsBoardObjectToggles = true

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    private var theme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layers")
                .font(.headline.weight(.semibold))
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                layersTab
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 320)
        .frame(maxHeight: 560)
    }

    private var layersTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardDisplayPresetButtons(displayOptions: $displayOptions)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Divider()
                .padding(.bottom, 6)

            ForEach(layerEntries) { entry in
                BoardLayerRow(
                    entry: entry,
                    color: colorBinding(for: entry),
                    fillMode: fillModeBinding(for: entry),
                    isSelected: !entry.isDimensions && selectedLayer == entry.layer,
                    isVisible: visibilityBinding(for: entry),
                    options: AnyView(layerOptions(for: entry))
                ) {
                    if !entry.isDimensions {
                        selectedLayer = entry.layer
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            LayerControlSection(title: "View") {
                if !includesThreeDControls {
                    BoardDisplayToggle(title: "Grid", isOn: $displayOptions.grid)
                }
                BoardDisplayToggle(title: "Panel Labels", isOn: $displayOptions.panelLabels)
                BoardDisplayToggle(title: "Scale Bar", isOn: $displayOptions.scaleBar)
                BoardDisplayToggle(title: "Coordinates", isOn: $displayOptions.coordinates)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            LayerControlSection(title: "Rendering") {
                HStack(spacing: 10) {
                    Text("Layer Opacity")
                    Text("\(Int((displayOptions.layerOpacity * 100).rounded()))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                    Slider(value: $displayOptions.layerOpacity, in: 0...1)
                }

                Picker("Highlight Mode", selection: $displayOptions.highlightMode) {
                    Text("Dim other").tag("dim_other")
                    Text("As is").tag("as_is")
                    Text("Hide other").tag("hide_other")
                }

                Picker("Layer Mode", selection: $displayOptions.layerMode) {
                    Text("As is").tag("as_is")
                    Text("Current only").tag("current_only")
                    Text("Current and adjacent").tag("current_adjacent")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            LayerControlSection(title: "Objects") {
                if showsBoardObjectToggles {
                    BoardDisplayToggle(title: "Track Labels", isOn: $displayOptions.trackLabels)
                    BoardDisplayToggle(title: "Vias", color: theme.hole, isOn: $displayOptions.vias)
                    BoardDisplayToggle(title: "Via Labels", color: theme.hole, isOn: $displayOptions.viaLabels)
                }
                BoardDisplayToggle(title: "Pads", color: theme.layerColor(for: HorizontalBoardLayers.topCopper), isOn: $displayOptions.pads)
                BoardDisplayToggle(title: "Pad Labels", color: theme.layerColor(for: HorizontalBoardLayers.topCopper), isOn: $displayOptions.padLabels)
                BoardDisplayToggle(title: "Holes", color: theme.hole, isOn: $displayOptions.holes)
                if showsBoardObjectToggles {
                    BoardDisplayToggle(title: "Packages", isOn: $displayOptions.packages)
                }
                BoardDisplayToggle(title: "Text", isOn: $displayOptions.text)
                BoardDisplayToggle(title: "Keepouts", isOn: $displayOptions.keepouts)
                BoardDisplayToggle(title: "Dimensions", isOn: $displayOptions.dimensions)
                if showsBoardObjectToggles {
                    BoardDisplayToggle(title: "Connections", color: theme.airwire, isOn: $displayOptions.connectionLines)
                    BoardDisplayToggle(title: "Connection Labels", color: theme.connectionLine, isOn: $displayOptions.connectionLabels)
                    BoardDisplayToggle(title: "Decals", isOn: $displayOptions.decals)
                }
            }
            .padding([.horizontal, .bottom], 12)
            .padding(.top, 10)
        }
        .padding(.vertical, 8)
    }

    private var layerEntries: [BoardLayerEntry] {
        if let layers {
            return layers.map { BoardLayerEntry(layer: $0) }
        }
        var entries = [
            BoardLayerEntry(layer: HorizontalBoardLayers.topNotes),
            BoardLayerEntry(layer: HorizontalBoardLayers.outlineNotes),
            BoardLayerEntry(layer: HorizontalBoardLayers.outline),
            BoardLayerEntry(layer: HorizontalBoardLayers.topCourtyard),
            BoardLayerEntry(layer: HorizontalBoardLayers.topAssembly),
            BoardLayerEntry(layer: HorizontalBoardLayers.topPackage),
            BoardLayerEntry(layer: HorizontalBoardLayers.topPaste),
            BoardLayerEntry(layer: HorizontalBoardLayers.topSilkscreen),
            BoardLayerEntry(layer: HorizontalBoardLayers.topMask),
            BoardLayerEntry(layer: HorizontalBoardLayers.topCopper)
        ]

        entries.append(contentsOf: innerCopperLayerEntries)
        entries.append(contentsOf: [
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomCopper),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomMask),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomSilkscreen),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomPaste),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomPackage),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomAssembly),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomCourtyard),
            BoardLayerEntry(layer: HorizontalBoardLayers.bottomNotes),
            BoardLayerEntry.dimensions
        ])

        entries.append(contentsOf: board?.userLayers.map { BoardLayerEntry(layer: $0.id, title: $0.name) } ?? [])
        return entries
    }

    private var innerCopperLayerEntries: [BoardLayerEntry] {
        let innerLayers = board?.stackupLayers
            .map(\.layer)
            .filter { HorizontalBoardLayers.category(for: $0) == .innerCopper }
            .sorted { abs($0) < abs($1) }
            ?? [HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.in2Copper]
        return innerLayers.map { BoardLayerEntry(layer: $0) }
    }

    @ViewBuilder
    private func layerOptions(for entry: BoardLayerEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title)
                .font(.headline)

            if entry.layer == HorizontalBoardLayers.outline {
                Divider()
                BoardDisplayToggle(title: "Board Body", color: theme.layerColor(for: HorizontalBoardLayers.outline), isOn: $displayOptions.boardBody)
            }

            if HorizontalBoardLayers.isSilkscreen(entry.layer) {
                Divider()
                BoardDisplayToggle(title: "Text", isOn: $displayOptions.text)
                BoardDisplayToggle(title: "Graphics", isOn: visibilityBinding(for: entry))
            }

            if HorizontalBoardLayers.isCopper(entry.layer) {
                Divider()
                BoardDisplayToggle(title: "Show Keepouts", isOn: $displayOptions.keepouts)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func visibilityBinding(for entry: BoardLayerEntry) -> Binding<Bool> {
        if entry.isDimensions {
            return $displayOptions.dimensions
        }

        return Binding {
            displayOptions.isLayerVisible(entry.layer)
        } set: { isVisible in
            displayOptions.setLayerVisibility(entry.layer, isVisible: isVisible)
        }
    }

    private func colorBinding(for entry: BoardLayerEntry) -> Binding<Color> {
        let colorLayer = board?.userLayers.first(where: { $0.id == entry.layer })?.colorLayer ?? entry.layer
        return appearanceSettings.layerColorBinding(for: colorLayer)
    }

    private func fillModeBinding(for entry: BoardLayerEntry) -> Binding<Bool>? {
        guard !entry.isDimensions,
              Self.supportsFillMode(for: entry.layer) else {
            return nil
        }

        return Binding {
            displayOptions.isLayerFilled(entry.layer)
        } set: { isFilled in
            displayOptions.setLayerFilled(entry.layer, isFilled: isFilled)
        }
    }

    private static func supportsFillMode(for layer: Int) -> Bool {
        switch HorizontalBoardLayers.category(for: layer) {
        case .topCopper, .innerCopper, .bottomCopper, .solderMask, .paste, .silkscreen, .outline, .fabrication, .user:
            return true
        case .other:
            return false
        }
    }
}

struct BoardLayerEntry: Identifiable {
    var layer: Int
    var title: String
    var isDimensions: Bool

    var id: Int { layer }

    static let dimensions = BoardLayerEntry(layer: HorizontalBoardLayers.dimensions, title: "Dimensions", isDimensions: true)

    init(layer: Int, title: String? = nil, isDimensions: Bool = false) {
        self.layer = layer
        self.title = title ?? HorizontalBoardLayers.name(for: layer)
        self.isDimensions = isDimensions
    }
}

struct BoardLayerRow: View {
    var entry: BoardLayerEntry
    @Binding var color: Color
    var fillMode: Binding<Bool>?
    var isSelected: Bool
    @Binding var isVisible: Bool
    var options: AnyView
    var select: () -> Void

    @State private var isOptionsPresented = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isVisible ? Color.primary : Color.secondary.opacity(0.65))
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(isVisible ? "Hide \(entry.title)" : "Show \(entry.title)")

            // `.controlSize(.small)` gives the well a properly sized natural
            // layout. It used to be squeezed into an 18pt frame and then
            // `.scaleEffect`-ed — scaleEffect scales the rendering but NOT the
            // layout frame, so the well drew wider than its box and crowded the
            // layer name.
            ColorPicker("\(entry.title) color", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .help("\(entry.title) color")

            Text(entry.title)
                .lineLimit(1)
                .foregroundStyle(isVisible ? Color.primary : Color.secondary)

            Spacer(minLength: 0)

            if let fillMode {
                Button {
                    fillMode.wrappedValue.toggle()
                } label: {
                    Image(systemName: fillMode.wrappedValue ? "square.fill" : "square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(fillMode.wrappedValue ? "Show \(entry.title) outlines" : "Fill \(entry.title)")
            }

            Button {
                isOptionsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("\(entry.title) options")
            .popover(isPresented: $isOptionsPresented, arrowEdge: .trailing) {
                options
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(selectionBackground)
        .onTapGesture(perform: select)
    }

    private var selectionBackground: Color {
        guard isSelected else {
            return Color.clear
        }
        #if os(macOS)
        return Color(nsColor: .controlAccentColor).opacity(0.8)
        #else
        return Color.accentColor.opacity(0.8)
        #endif
    }
}

struct BoardDisplayPresetButtons: View {
    @Binding var displayOptions: BoardDisplayOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("")
                    .frame(width: 42, alignment: .leading)
                presetHeader("Silkscreen")
                presetHeader("Placement")
                presetHeader("Routing")
            }

            presetRow(
                title: "Top",
                silkscreen: { displayOptions.topSilkscreenView() },
                placement: { displayOptions.topPlacementView() },
                routing: { displayOptions.topRoutingView() }
            )

            presetRow(
                title: "Bottom",
                silkscreen: { displayOptions.bottomSilkscreenView() },
                placement: { displayOptions.bottomPlacementView() },
                routing: { displayOptions.bottomRoutingView() }
            )
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }

    private func presetHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 74)
    }

    private func presetRow(
        title: String,
        silkscreen: @escaping () -> Void,
        placement: @escaping () -> Void,
        routing: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Button("Silk", action: silkscreen)
                .frame(width: 74)
                .help("\(title) silkscreen: mask, silkscreen, and outline")

            Button("Place", action: placement)
                .frame(width: 74)
                .help("\(title) placement: copper and courtyard")

            Button("Route", action: routing)
                .frame(width: 74)
                .help("\(title) routing: copper only")
        }
    }
}

struct BoardDisplayToggle: View {
    var title: String
    var color: Color? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                if let color {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 10, height: 10)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(.secondary.opacity(0.35), lineWidth: 0.5)
                        }
                }
                Text(title)
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
    }
}
