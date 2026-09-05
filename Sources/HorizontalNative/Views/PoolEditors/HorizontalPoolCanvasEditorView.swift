import SwiftUI

/// The canvas-shaped pool item editors — a package, padstack or decal on the
/// board canvas in that kind's mode (Horizon's `imp_package`, `imp_padstack`
/// and `imp_decal`), with the item's own fields, parameters and checks in a
/// sidebar above the selection inspector.
///
/// The item is projected into a synthetic board once; the canvas edits that
/// board with its usual tools and hands every commit back, which the model
/// absorbs through `applying(board:)`. Edits made here (a rename, a parameter
/// change, Apply) go the other way: the model changes, the board is
/// re-projected and the canvas adopts it in place.
struct HorizontalPoolCanvasEditorView: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    var undoManager: UndoManager?
    var commit: (HorizontalPoolItemModel, String) -> Void

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var board: HorizontalBoard?
    @State private var viewport = CanvasViewport()
    @State private var displayOptions: BoardDisplayOptions
    @State private var drawingLayer: Int
    @State private var selectionToolSettings = HorizontalSelectionToolSettings()
    @State private var selectionDetails: HorizontalSelectionDetailState?
    @State private var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    @State private var drawingToolCommand: HorizontalDrawingToolCommand?
    @State private var canvasActions: HorizontalCanvasCommandActions?
    @State private var syncRevision = 0
    /// The model the canvas last produced, so a model change that did not
    /// come from the canvas (a header edit, an undo of one) is recognised
    /// and re-projected.
    @State private var canvasModel: HorizontalPoolItemModel?
    @State private var pointerInsideToolbar = false
    @StateObject private var toolSettings = HorizontalBoardToolSettings()
    /// The package editor's 3D view, shown in the footprint's place.
    @State private var showsThreeD = false
    @State private var threeDCameraState: HorizontalSceneCameraState?
    /// Bumped on every change to what the 3D scene shows, so the scene is
    /// rebuilt (its cache keys on the board's identity, not its content).
    @State private var sceneRevision = 0

    init(
        session: HorizontalPoolItemEditorSession,
        isReadOnly: Bool,
        undoManager: UndoManager?,
        commit: @escaping (HorizontalPoolItemModel, String) -> Void
    ) {
        self.session = session
        self.isReadOnly = isReadOnly
        self.undoManager = undoManager
        self.commit = commit
        let profile = Self.modeProfile(for: session.category)
        var options = BoardDisplayOptions()
        options.poolEditor(mode: profile.mode)
        _displayOptions = State(initialValue: options)
        _drawingLayer = State(initialValue: profile.defaultDrawingLayer)
    }

    static func modeProfile(for category: HorizontalPoolItemCategory) -> HorizontalBoardModeProfile {
        switch category {
        case .padstack: .padstack
        case .decal: .decal
        default: .package
        }
    }

    private var modeProfile: HorizontalBoardModeProfile {
        Self.modeProfile(for: session.category)
    }

    private var context: HorizontalPoolEditorContext {
        HorizontalPoolEditorContext(
            poolURL: session.poolURL,
            packageDirectoryURL: session.category == .package ? session.itemURL.deletingLastPathComponent() : nil,
            libraryIndex: session.index
        )
    }

    private var palette: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            canvasPane
            Divider()
            sidebar
                .frame(width: 320)
        }
        .onAppear {
            if board == nil {
                board = projectBoard()
            }
        }
        .onChange(of: session.model) { _, newModel in
            guard newModel != canvasModel else {
                return
            }
            reproject()
        }
        .onChange(of: session.isIndexing) { _, indexing in
            // Padstacks that could not be resolved before the index finished
            // bake once it has; the model is unchanged, so this is a redraw.
            if !indexing, session.category == .package {
                reproject()
            }
        }
        #if os(macOS)
        .focusedSceneValue(\.horizonCanvasCommandActions, canvasActions)
        .focusedSceneValue(\.horizonBoardDisplayOptions, $displayOptions)
        .focusedSceneValue(\.horizonBoardAvailable, true)
        #endif
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvasPane: some View {
        if showsThreeD, session.category == .package {
            threeDPane
        } else {
            footprintPane
        }
    }

    private var footprintPane: some View {
        PaneOverlayContainer(
            pane: .board,
            safeAreaInsets: EdgeInsets(),
            showsInfoButton: false,
            isKeyboardFocused: true,
            onToolbarHover: { pointerInsideToolbar = $0 }
        ) {
            if let board {
                BoardCanvasView(
                    board: board,
                    viewport: $viewport,
                    displayOptions: displayOptions,
                    undoManager: undoManager,
                    selectionToolSettings: selectionToolSettings,
                    isReadOnly: isReadOnly,
                    ignoresCanvasMouseEvents: pointerInsideToolbar,
                    onBoardChange: { canvasChanged($0) },
                    onSelectionDetailsChange: { selectionDetails = $0 },
                    onCanvasCommandActionsChange: { canvasActions = $0 },
                    selectionPropertyChangeCommand: selectionPropertyChangeCommand,
                    drawingToolCommand: drawingToolCommand,
                    toolSettings: toolSettings,
                    drawingLayer: drawingLayer,
                    syncRevision: syncRevision,
                    onSelectDrawingLayer: { drawingLayer = $0 },
                    poolURL: session.poolURL,
                    modeProfile: modeProfile,
                    poolContext: context
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
            BoardLayerControls(
                board: board,
                displayOptions: $displayOptions,
                selectedLayer: $drawingLayer,
                includesThreeDControls: false,
                layers: modeProfile.layers,
                showsBoardObjectToggles: false
            )
        } grid: {
            GridControlsPanel(title: "Grid", grid: gridBinding)
        } tools: {
            if session.category == .package {
                ThreeDPreviewToggleButton(isShowingThreeD: false) {
                    showsThreeD = true
                }
            }
            SelectionToolButton(settings: $selectionToolSettings)
            if modeProfile.allowsGraphics || modeProfile.allowsPolygons {
                DrawingToolButtonGroup(primitives: drawingPrimitives) { primitive in
                    drawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                }
                .disabled(isReadOnly)
            }
            if modeProfile.allowsText {
                AddTextToolButton {
                    canvasActions?.dispatch(.addText)
                }
                .disabled(isReadOnly)
            }
            if modeProfile.placesPads {
                PlacePadToolButton {
                    canvasActions?.dispatch(.placePad)
                }
                .disabled(isReadOnly)
            }
            if modeProfile.placesShapes {
                PlaceShapeToolButtonGroup { form in
                    canvasActions?.dispatch(.placeShape(form))
                }
                .disabled(isReadOnly)
            }
            if modeProfile.placesHoles {
                PlaceHoleToolButtonGroup { shape in
                    canvasActions?.dispatch(.placeHole(shape))
                }
                .disabled(isReadOnly)
            }
        }
    }

    // MARK: 3D view

    /// Upstream's package 3D view: the package on a small slab of board,
    /// with the board 3D view's presets, surface toggles and controls. The
    /// scene follows every edit — pads, silkscreen, the models section.
    private var threeDPane: some View {
        PaneOverlayContainer(
            pane: .threeD,
            safeAreaInsets: EdgeInsets(),
            showsInfoButton: false,
            showsGridButton: false,
            isKeyboardFocused: true,
            onToolbarHover: { pointerInsideToolbar = $0 }
        ) {
            if let sceneBoard {
                BoardSceneView(
                    board: sceneBoard,
                    displayOptions: displayOptions,
                    backgroundColor: appearanceSettings.boardSceneBackground,
                    copperColor: appearanceSettings.boardSceneCopper,
                    layerColors: appearanceSettings.boardSceneLayerColors,
                    materialColors: appearanceSettings.boardSceneMaterialColors,
                    ignoresSceneMouseEvents: pointerInsideToolbar,
                    silkscreenClipping: appearanceSettings.silkscreenClipping,
                    cameraState: $threeDCameraState
                )
                .id(sceneRevision)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } info: {
            EmptyView()
        } layers: {
            BoardLayerControls(
                board: sceneBoard,
                displayOptions: $displayOptions,
                selectedLayer: $drawingLayer,
                includesThreeDControls: true,
                layers: modeProfile.layers,
                showsBoardObjectToggles: false
            )
        } grid: {
            EmptyView()
        } tools: {
            ThreeDPreviewToggleButton(isShowingThreeD: true) {
                showsThreeD = false
            }
            ThreeDViewPresetRailButtons(board: sceneBoard, displayOptions: $displayOptions, cameraState: $threeDCameraState)
            ThreeDViewControlsButton(board: sceneBoard, displayOptions: $displayOptions, cameraState: $threeDCameraState)
        }
    }

    private var sceneBoard: HorizontalBoard? {
        guard let board, case .package(let package) = session.model else {
            return nil
        }
        return package.sceneBoard(from: board, poolURL: session.poolURL)
    }

    private var drawingPrimitives: [HorizontalDrawingPrimitive] {
        var primitives = [HorizontalDrawingPrimitive]()
        if modeProfile.allowsGraphics {
            primitives += [.line, .rectangle, .circle, .arc]
        }
        if modeProfile.allowsPolygons {
            primitives.append(.polygon)
        }
        return primitives
    }

    /// The grid is a view setting here, not part of the item; changing it
    /// re-syncs the canvas so the draft picks up the new spacing.
    private var gridBinding: Binding<HorizontalGridSettings> {
        Binding {
            board?.grid ?? .boardDefault
        } set: { grid in
            guard board != nil else {
                return
            }
            board?.grid = grid.withClampedValues()
            syncRevision += 1
        }
    }

    #if os(iOS)
    /// The on-screen stand-in for the keyboard while a pad, shape or hole
    /// follows the finger: finish / cancel, and rotate / mirror for the ghost.
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
                HorizontalPoolItemParametersSection(
                    session: session,
                    isReadOnly: isReadOnly,
                    commit: commit
                )
                if session.category == .package {
                    HorizontalPackageModelsSection(session: session, isReadOnly: isReadOnly, commit: commit)
                }
                if session.category == .package || session.category == .decal {
                    HorizontalPackageToolsSection(
                        session: session,
                        isReadOnly: isReadOnly,
                        context: context,
                        selectedPadIDs: selectedPadIDs,
                        drawingLayer: drawingLayer,
                        layers: modeProfile.layers,
                        commit: commit
                    )
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

    /// The pads selected on the canvas, by uuid (refs are `<pkg>/pad/<uuid>`).
    private var selectedPadIDs: Set<String> {
        guard let selectionDetails else {
            return []
        }
        var ids = Set<String>()
        for group in selectionDetails.groups where group.type == .pad {
            for item in group.items {
                let lowered = item.ref.id.lowercased()
                if let marker = lowered.range(of: "/pad/") {
                    ids.insert(String(lowered[marker.upperBound...]))
                }
            }
        }
        return ids
    }

    // MARK: Model ↔ board

    private func projectBoard() -> HorizontalBoard? {
        switch session.model {
        case .package(let package):
            return package.makeBoard(context: context)
        case .padstack(let padstack):
            return padstack.makeBoard(context: context)
        case .decal(let decal):
            return decal.makeBoard(context: context)
        default:
            return nil
        }
    }

    private func reproject() {
        sceneRevision += 1
        guard let projected = projectBoard() else {
            return
        }
        var next = projected
        next.grid = board?.grid ?? projected.grid
        board = next
        syncRevision += 1
    }

    /// A canvas commit: keep the board as the canvas has it (so its identity,
    /// selection and draft survive) and fold the geometry into the model. The
    /// canvas already registered the undo step on the shared manager.
    private func canvasChanged(_ edited: HorizontalBoard) {
        sceneRevision += 1
        board = edited
        let model: HorizontalPoolItemModel
        switch session.model {
        case .package(let package):
            model = .package(package.applying(board: edited))
        case .padstack(let padstack):
            model = .padstack(padstack.applying(board: edited))
        case .decal(let decal):
            model = .decal(decal.applying(board: edited))
        default:
            return
        }
        canvasModel = model
        session.commit(model, actionName: "Edit", undoManager: undoManager, isReadOnly: isReadOnly, registersUndo: false)
    }
}

/// Parameter set, fixed / required flags, the parameter program and Apply —
/// Horizon's "Parameters…" window for packages and padstacks. Decals have
/// none and show nothing.
struct HorizontalPoolItemParametersSection: View {
    @ObservedObject var session: HorizontalPoolItemEditorSession
    var isReadOnly: Bool
    var commit: (HorizontalPoolItemModel, String) -> Void

    @State private var programText = ""
    @State private var loadedProgramFor: String?

    var body: some View {
        switch session.model {
        case .package(let package):
            section(
                parameterSet: package.parameterSet,
                flagTitle: "Fixed",
                flagged: Set(package.parametersFixed),
                program: package.parameterProgram,
                onSetParameter: { key, value in
                    var model = package
                    model.parameterSet[key] = value
                    commit(.package(model), "Change Parameter")
                },
                onRemoveParameter: { key in
                    var model = package
                    model.parameterSet.removeValue(forKey: key)
                    model.parametersFixed.removeAll { $0 == key }
                    commit(.package(model), "Remove Parameter")
                },
                onSetFlag: { key, flagged in
                    var model = package
                    model.parametersFixed.removeAll { $0 == key }
                    if flagged {
                        model.parametersFixed.append(key)
                        model.parametersFixed.sort()
                    }
                    commit(.package(model), flagged ? "Fix Parameter" : "Unfix Parameter")
                },
                onApply: { program in
                    var model = package
                    model.parameterProgram = program
                    commit(.package(model.applyingParameterProgram()), "Apply Parameters")
                }
            )
        case .padstack(let padstack):
            section(
                parameterSet: padstack.parameterSet,
                flagTitle: "Required",
                flagged: Set(padstack.parametersRequired),
                program: padstack.parameterProgram,
                onSetParameter: { key, value in
                    var model = padstack
                    model.parameterSet[key] = value
                    commit(.padstack(model), "Change Parameter")
                },
                onRemoveParameter: { key in
                    var model = padstack
                    model.parameterSet.removeValue(forKey: key)
                    model.parametersRequired.removeAll { $0 == key }
                    commit(.padstack(model), "Remove Parameter")
                },
                onSetFlag: { key, flagged in
                    var model = padstack
                    model.parametersRequired.removeAll { $0 == key }
                    if flagged {
                        model.parametersRequired.append(key)
                        model.parametersRequired.sort()
                    }
                    commit(.padstack(model), flagged ? "Require Parameter" : "Unrequire Parameter")
                },
                onApply: { program in
                    var model = padstack
                    model.parameterProgram = program
                    commit(.padstack(model.applyingParameterProgram()), "Apply Parameters")
                }
            )
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func section(
        parameterSet: [String: Int],
        flagTitle: String,
        flagged: Set<String>,
        program: String,
        onSetParameter: @escaping (String, Int) -> Void,
        onRemoveParameter: @escaping (String) -> Void,
        onSetFlag: @escaping (String, Bool) -> Void,
        onApply: @escaping (String) -> Void
    ) -> some View {
        Divider()
        Text("Parameters")
            .font(.headline)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(parameterSet.keys.sorted(), id: \.self) { key in
                GridRow {
                    Text(BoardCanvasView.parameterDisplayName(key))
                        .gridColumnAlignment(.trailing)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        HorizontalCommittedTextField(
                            text: HorizontalPoolItemHeaderForm.millimetres(Double(parameterSet[key] ?? 0)),
                            isReadOnly: isReadOnly
                        ) { value in
                            if let parsed = HorizontalPoolItemHeaderForm.nanometres(fromMillimetres: value) {
                                onSetParameter(key, Int(parsed.rounded()))
                            }
                        }
                        .frame(minWidth: 70)
                        Text("mm")
                            .foregroundStyle(.secondary)
                    }
                    Toggle(flagTitle, isOn: Binding(
                        get: { flagged.contains(key) },
                        set: { onSetFlag(key, $0) }
                    ))
                    .poolFlagToggleStyle()
                    .disabled(isReadOnly)
                    Button {
                        onRemoveParameter(key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly)
                    .help("Remove parameter")
                }
            }
        }
        let available = BoardCanvasView.knownParameterDisplayNames.keys
            .filter { parameterSet[$0] == nil }
            .sorted { BoardCanvasView.parameterDisplayName($0) < BoardCanvasView.parameterDisplayName($1) }
        if !available.isEmpty {
            Menu("Add Parameter") {
                ForEach(available, id: \.self) { key in
                    Button(BoardCanvasView.parameterDisplayName(key)) {
                        onSetParameter(key, 0)
                    }
                }
            }
            .fixedSize()
            .disabled(isReadOnly)
        }
        Text("Parameter program")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        TextEditor(text: $programText)
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 90, maxHeight: 180)
            .border(Color.secondary.opacity(0.3))
            .disabled(isReadOnly)
            .onAppear {
                loadProgram(program)
            }
            .onChange(of: program) { _, newProgram in
                loadProgram(newProgram)
            }
        HStack {
            Button("Apply") {
                onApply(programText)
            }
            .disabled(isReadOnly)
            .help("Run the parameter program over the stored geometry and keep the result")
            if programText != program {
                Text("Unapplied changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The editor keeps its own text while the user types; it takes the
    /// model's program whenever the model's changes (Apply, undo, open).
    private func loadProgram(_ program: String) {
        if loadedProgramFor != program {
            programText = program
            loadedProgramFor = program
        }
    }
}

extension View {
    /// A compact flag toggle: a checkbox on macOS, a small switch on iPadOS.
    @ViewBuilder
    func poolFlagToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch).controlSize(.mini)
        #endif
    }
}
