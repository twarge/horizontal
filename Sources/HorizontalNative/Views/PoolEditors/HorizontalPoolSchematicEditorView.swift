import SwiftUI

/// The schematic-shaped pool item editors — a symbol or a frame on the
/// schematic canvas in that kind's mode (Horizon's `imp_symbol` and
/// `imp_frame`), with the item's own fields and checks in a sidebar above the
/// selection inspector. The unplaced-pins column inside the canvas is the
/// symbol editor's pin list.
///
/// Same flow as the board host: the item is projected into a synthetic sheet
/// once, the canvas edits it and hands every commit back through
/// `applying(sheet:)`; header edits (and their undo) re-project the sheet and
/// the canvas adopts it in place.
struct HorizontalPoolSchematicEditorView: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    var undoManager: UndoManager?
    var commit: (HorizontalPoolItemModel, String) -> Void

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var sheet: HorizontalSchematicSheet?
    @State private var viewport = CanvasViewport()
    @State private var displayOptions = SchematicDisplayOptions()
    @State private var selectionToolSettings = HorizontalSelectionToolSettings()
    @State private var selectionDetails: HorizontalSelectionDetailState?
    @State private var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    @State private var drawingToolCommand: HorizontalDrawingToolCommand?
    @State private var canvasActions: HorizontalCanvasCommandActions?
    @State private var syncRevision = 0
    @State private var canvasModel: HorizontalPoolItemModel?
    @State private var pointerInsideToolbar = false
    @State private var pinDisplayMode = HorizontalSymbolEditorPinDisplayMode.primary
    @State private var showsJunctionsAndHiddenNames = false
    @State private var unitPickerPresented = false
    /// nil = the editor; a view = Horizon's text placement preview for it.
    @State private var textPlacementView: HorizontalSymbolTextPlacementView?

    private var mode: HorizontalSchematicEditorMode {
        session.category == .frame ? .frame : .symbol
    }

    private var profile: HorizontalSchematicEditorProfile {
        .profile(for: mode)
    }

    private var symbol: HorizontalPoolSymbol? {
        if case .symbol(let symbol) = session.model {
            return symbol
        }
        return nil
    }

    private var unit: HorizontalPoolUnit? {
        guard let symbol, let json = session.index.json(.unit, uuid: symbol.unitID) else {
            return nil
        }
        return try? HorizontalPoolUnit(json: json)
    }

    private var symbolContext: HorizontalSymbolEditorContext? {
        guard let symbol else {
            return nil
        }
        return HorizontalSymbolEditorContext(
            symbolID: symbol.uuid,
            unitID: symbol.unitID,
            unitJSON: session.index.json(.unit, uuid: symbol.unitID).map(HorizontalPreservedJSON.init),
            poolURL: session.poolURL,
            pinDisplayMode: pinDisplayMode,
            showsJunctionsAndHiddenNames: showsJunctionsAndHiddenNames,
            view: textPlacementView
        )
    }

    private var palette: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .schematic, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            canvasPane
            Divider()
            sidebar
                .frame(width: 320)
        }
        .onAppear {
            if sheet == nil {
                sheet = projectSheet()
            }
        }
        .onChange(of: session.model) { _, newModel in
            guard newModel != canvasModel else {
                return
            }
            reproject()
        }
        .onChange(of: session.isIndexing) { _, indexing in
            // Pin names come from the unit, which the index resolves.
            if !indexing, mode == .symbol {
                reproject()
            }
        }
        .onChange(of: pinDisplayMode) { _, _ in
            reproject()
        }
        .onChange(of: showsJunctionsAndHiddenNames) { _, _ in
            reproject()
        }
        .onChange(of: textPlacementView) { _, _ in
            reproject()
        }
        .sheet(isPresented: $unitPickerPresented) {
            HorizontalPoolItemPickerSheet(
                title: "Change Unit",
                category: .unit,
                index: session.index,
                onPick: { item in
                    unitPickerPresented = false
                    changeUnit(to: item)
                },
                onCancel: { unitPickerPresented = false }
            )
        }
        #if os(macOS)
        .focusedSceneValue(\.horizonCanvasCommandActions, canvasActions)
        .focusedSceneValue(\.horizonSchematicDisplayOptions, $displayOptions)
        .focusedSceneValue(\.horizonSchematicAvailable, true)
        #endif
    }

    // MARK: Canvas

    private var canvasPane: some View {
        PaneOverlayContainer(
            pane: .schematic,
            safeAreaInsets: EdgeInsets(),
            showsInfoButton: false,
            isKeyboardFocused: true,
            onToolbarHover: { pointerInsideToolbar = $0 }
        ) {
            if let sheet {
                SchematicCanvasView(
                    sheet: sheet,
                    viewport: $viewport,
                    displayOptions: displayOptions,
                    undoManager: undoManager,
                    selectionToolSettings: selectionToolSettings,
                    isReadOnly: isReadOnly,
                    ignoresCanvasMouseEvents: pointerInsideToolbar,
                    onSheetChange: { canvasChanged($0) },
                    onSelectionDetailsChange: { selectionDetails = $0 },
                    onCanvasCommandActionsChange: { canvasActions = $0 },
                    selectionPropertyChangeCommand: selectionPropertyChangeCommand,
                    drawingToolCommand: drawingToolCommand,
                    poolURL: session.poolURL,
                    mode: mode,
                    symbolEditorContext: symbolContext,
                    syncRevision: syncRevision
                )
                #if os(iOS)
                .overlay(alignment: .bottom) {
                    placementControlBar
                }
                #endif
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } info: {
            EmptyView()
        } layers: {
            SchematicLayerControls(displayOptions: $displayOptions)
        } grid: {
            GridControlsPanel(title: "Grid", grid: .constant(sheet?.grid ?? .schematicDefault), isEditable: false)
        } tools: {
            SelectionToolButton(settings: $selectionToolSettings)
            DrawingToolButtonGroup(primitives: [.line, .rectangle, .circle, .arc, .polygon]) { primitive in
                drawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
            }
            .disabled(isReadOnly)
            AddTextToolButton {
                canvasActions?.dispatch(.addText)
            }
            .disabled(isReadOnly)
            if profile.supportsPins {
                PlacePinToolButton {
                    canvasActions?.dispatch(.placePin)
                }
                .disabled(isReadOnly)
                PlaceRefdesValueToolButton {
                    canvasActions?.dispatch(.placeRefdesAndValue)
                }
                .disabled(isReadOnly)
                PlaceDotToolButton {
                    canvasActions?.dispatch(.placeDot)
                }
                .disabled(isReadOnly)
                ResizeSymbolToolButton {
                    canvasActions?.dispatch(.resizeSymbol)
                }
                .disabled(isReadOnly || canvasActions?.canResizeSymbol != true)
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var placementControlBar: some View {
        if let actions = canvasActions, actions.canCancelInteraction {
            HStack(spacing: 16) {
                control("Finish", "checkmark.circle.fill", enabled: actions.canCommitInteraction) {
                    actions.dispatch(.commitInteraction)
                }
                control("Cancel", "xmark.circle", enabled: true) {
                    actions.dispatch(.cancelInteraction)
                }
                if actions.hasPlacementInteraction {
                    control("Rotate", "rotate.right", enabled: true) {
                        actions.dispatch(.rotateSelection)
                    }
                    control("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", enabled: true) {
                        actions.dispatch(.mirrorSelection)
                    }
                    if actions.canAutoplacePins {
                        control("Next", "forward.frame", enabled: true) {
                            actions.dispatch(.autoplaceNextPin)
                        }
                        control("All", "forward.end", enabled: true) {
                            actions.dispatch(.autoplaceAllPins)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 20)
        }
    }

    private func control(_ title: String, _ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }
    #endif

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HorizontalPoolItemHeaderForm(session: session, isReadOnly: isReadOnly, commit: commit)
                if let symbol {
                    symbolViewSection(symbol)
                }
                if let selectionDetails, selectionDetails.hasSelection || selectionDetails.hovered != nil {
                    Divider()
                    Text("Selection")
                        .font(.headline)
                    HorizontalSelectionPopoverView(
                        state: selectionDetails,
                        foregroundColor: .primary,
                        backgroundColor: palette.overlayBackground,
                        chrome: .sidebar,
                        isReadOnly: isReadOnly
                    ) { change in
                        guard !isReadOnly else {
                            return
                        }
                        selectionPropertyChangeCommand = HorizontalSelectionPropertyChangeCommand(change: change)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    /// Horizon's symbol header widgets the shared form does not carry: the
    /// unit change, the pin display mode and the junctions / hidden names view.
    @ViewBuilder
    private func symbolViewSection(_ symbol: HorizontalPoolSymbol) -> some View {
        Divider()
        Text("Symbol")
            .font(.headline)
        HStack {
            Text(session.index.name(.unit, uuid: symbol.unitID) ?? symbol.unitID)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Change Unit…") {
                unitPickerPresented = true
            }
            .disabled(isReadOnly)
        }
        Picker("Pin names", selection: $pinDisplayMode) {
            ForEach(HorizontalSymbolEditorPinDisplayMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        Toggle("Junctions and hidden names", isOn: $showsJunctionsAndHiddenNames)
        Picker("Text placement", selection: $textPlacementView) {
            Text("Editing").tag(HorizontalSymbolTextPlacementView?.none)
            ForEach(HorizontalSymbolTextPlacementView.all) { view in
                Text(view.displayName + (symbol.textPlacements[view.key]?.isEmpty == false ? " •" : "")).tag(Optional(view))
            }
        }
        if let view = textPlacementView {
            HStack {
                Text("Drag the texts as they should sit when the symbol is placed this way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    commit(.symbol(symbol.clearingTextPlacements(for: view)), "Clear Text Placements")
                }
                .disabled(isReadOnly || symbol.textPlacements[view.key] == nil)
                .help("Use the default placement in this orientation")
            }
        }
        if let unit {
            let placed = Set(symbol.pins.keys.map { $0.lowercased() })
            let unplaced = unit.pins.values.filter { !placed.contains($0.id.lowercased()) }.count
            Text(unplaced == 0 ? "All \(unit.pins.count) pins placed" : "\(unplaced) of \(unit.pins.count) pins unplaced")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if session.isIndexing {
            Text("Resolving unit…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Unit not found in the pool", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Model ↔ sheet

    private func projectSheet() -> HorizontalSchematicSheet? {
        switch session.model {
        case .symbol(let symbol):
            guard let context = symbolContext else {
                return nil
            }
            return symbol.makeSheet(context: context, unit: unit)
        case .frame(let frame):
            return frame.makeSheet()
        default:
            return nil
        }
    }

    private func reproject() {
        guard let projected = projectSheet() else {
            return
        }
        sheet = projected
        syncRevision += 1
    }

    private func canvasChanged(_ edited: HorizontalSchematicSheet) {
        sheet = edited
        let model: HorizontalPoolItemModel
        switch session.model {
        case .symbol(let symbol):
            model = .symbol(symbol.applying(sheet: edited, view: textPlacementView))
        case .frame(let frame):
            model = .frame(frame.applying(sheet: edited))
        default:
            return
        }
        canvasModel = model
        session.commit(model, actionName: "Edit", undoManager: undoManager, isReadOnly: isReadOnly, registersUndo: false)
    }

    private func changeUnit(to item: HorizontalPoolLibraryItem) {
        guard let symbol,
              let json = session.index.json(.unit, uuid: item.uuid),
              let newUnit = try? HorizontalPoolUnit(json: json) else {
            return
        }
        commit(.symbol(symbol.changingUnit(to: newUnit, from: unit)), "Change Unit")
    }
}
