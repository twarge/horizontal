#if os(iOS)
import SwiftUI
import UIKit

struct HorizontalIPadProjectView: View {
    @Binding private var document: HorizontalProjectDocument
    private var fileURL: URL?

    @State private var project: HorizontalProject?
    /// Which panes are on screen, side by side (the same model the macOS workspace
    /// uses). A compact width class — iPhone, or a narrow multitasking slice — keeps
    /// this to exactly one pane, so the split layout below collapses to a single view
    /// without needing a second code path.
    @State private var visiblePanes: Set<HorizontalPane> = [.schematic]
    /// The pane the inspector and the keyboard-focus badge follow: whichever canvas
    /// most recently reported a selection.
    @State private var focusedPane: HorizontalPane = .schematic
    @State private var paneSizeFractions: [HorizontalPane: CGFloat] = [:]
    @State private var schematicViewport = CanvasViewport()
    @State private var boardViewport = CanvasViewport()
    @StateObject private var boardToolSettings = HorizontalBoardToolSettings()
    @State private var threeDCameraState: HorizontalSceneCameraState?
    @State private var selectedNetIDs = Set<String>()
    @State private var highlightedNetIDs = Set<String>()
    @State private var loadError: String?
    @State private var isLoading = false

    // Board track-tool (autorouter) state for iPad: entering the tool, the
    // tool-settings popover, the published command surface, and the layer.
    @State private var boardDrawTrackCommand: HorizontalDrawTrackCommand?
    @State private var boardToolSettingsPresented = false
    @State private var boardCanvasActions: HorizontalCanvasCommandActions?
    @State private var boardDrawingLayer = HorizontalBoardLayers.topCopper
    @State private var boardDrawingToolCommand: HorizontalDrawingToolCommand?
    // Rail state (brought over from the macOS workspace): display options drive the
    // layer-visibility rail; selection-tool settings drive the selection rail button.
    @State private var boardDisplayOptions = BoardDisplayOptions()
    @State private var selectionToolSettings = HorizontalSelectionToolSettings()
    @State private var schematicDisplayOptions = SchematicDisplayOptions()
    @State private var schematicDrawingToolCommand: HorizontalDrawingToolCommand?
    @State private var schematicDrawNetLineCommand: HorizontalDrawNetLineCommand?
    @State private var schematicCanvasActions: HorizontalCanvasCommandActions?
    @State private var rulesSheetPresented = false
    // The right-side slide-over (the iPad analogue of the macOS workspace's right
    // sidebar) shows one pane at a time — the selection inspector or the export panel.
    @State private var rightPane: HorizontalIPadRightPane?
    // Selection details reported up from each canvas + the property-edit command sent
    // back down (drive the inspector pane). Both are keyed by pane: with two canvases
    // on screen a shared command would be applied by BOTH of them, so a schematic edit
    // would also land on whatever the board had selected.
    @State private var selectionDetailsByPane = [HorizontalPane: HorizontalSelectionDetailState]()
    @State private var selectionPropertyChangeCommands = [HorizontalPane: HorizontalSelectionPropertyChangeCommand]()
    // Part placement: the part browser sets a request, which the schematic canvas
    // picks up (via its onAppear/onChange) to start the place-on-canvas interaction.
    @State private var placePartRequest: HorizontalPartPlacementRequest?
    // App settings sheet (the iPad stand-in for the macOS Settings window).
    @State private var settingsSheetPresented = false
    // Per-file view-state persistence (the same store the macOS workspace
    // uses): which panes are open, the split-separator positions, and the
    // right slide-over. Restored in loadProject; the flag keeps the save
    // hooks from clobbering the store with defaults before that happens.
    @State private var didRestoreViewState = false
    @State private var viewStateSaveTask: Task<Void, Never>?

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(document: Binding<HorizontalProjectDocument>, fileURL: URL?) {
        self._document = document
        self.fileURL = fileURL
    }

    var body: some View {
        // No NavigationStack here: the DocumentGroup already supplies the document
        // navigation bar (filename + back-to-Files + the document menu). Wrapping
        // the content in another NavigationStack stacked a second, redundant bar
        // (the duplicate document title) beneath it.
        // The sidebar pushes the canvases aside on iPad so it never covers the board;
        // compact widths keep the overlay, where a 340pt column would crush the canvas.
        HorizontalInspectorSidebar(isPresented: rightPane != nil, pushesContent: !isCompact) {
            VStack(spacing: 0) {
                if let project {
                    paneSplit(for: project)
                } else {
                    statusView
                }
            }
        } inspector: {
            rightPaneContent
        }
        // DocumentGroup supplies the navigation bar but leaves its title menu empty
        // unless the content names the document, which is why the bar showed a bare
        // chevron. `navigationDocument` also gives the menu the file's icon and the
        // usual Rename/Move/Share entries.
        .navigationTitle(documentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NavigationDocumentModifier(url: fileURL))
        .toolbar {
            // One ToolbarItem so everything shares a single glass island — separate
            // items each get their own capsule. (The pane picker never appears without
            // a schematic or board, so this one condition covers every control.)
            if let project, project.board != nil || project.schematic != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarIsland(for: project)
                }
                .sharedBackgroundVisibility(appearanceSettings.isToolbarTransparent ? .hidden : .automatic)
            }
        }
        .sheet(isPresented: $settingsSheetPresented) {
            settingsSheet
        }
        .fullScreenCover(isPresented: $rulesSheetPresented) {
            if let project {
                boardRulesCover(for: project)
            }
        }
        .onChange(of: visiblePanes) { _, panes in
            // Hiding a pane re-instantiates its canvas on return, and the schematic's
            // "already-handled" guard (`handledPlacePartRequestID`) is per-instance and
            // resets — so a still-set request would restart placement. Clear it when the
            // schematic goes away. (macOS keeps one persistent canvas, so it doesn't
            // need this.)
            if !panes.contains(.schematic) {
                placePartRequest = nil
            }
            if !panes.contains(focusedPane) {
                focusedPane = orderedVisiblePanes.first ?? focusedPane
            }
            scheduleViewStateSave()
        }
        .onChange(of: paneSizeFractions) { _, _ in
            scheduleViewStateSave()
        }
        .onChange(of: rightPane) { _, _ in
            scheduleViewStateSave()
        }
        .onDisappear {
            viewStateSaveTask?.cancel()
            viewStateSaveTask = nil
            saveViewState()
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            // A compact width (iPhone, or a narrow Split View slice) has no room for
            // two canvases: fall back to the focused one.
            if sizeClass == .compact, visiblePanes.count > 1 {
                visiblePanes = [focusedPane]
            }
        }
        .task(id: loadIdentity) {
            loadProject()
        }
    }

    /// Name shown in the DocumentGroup navigation bar. The file on disk wins; a
    /// document opened from an in-memory archive falls back to its suggested filename,
    /// then to the project's own name.
    private var documentTitle: String {
        if let fileURL {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        if let suggested = document.archive.suggestedFilename {
            return (suggested as NSString).deletingPathExtension
        }
        return project?.name ?? "Horizontal"
    }

    /// The active right-slide-over pane — the selection inspector or the export panel
    /// (mutually exclusive, like the macOS workspace's single right sidebar).
    @ViewBuilder
    private var rightPaneContent: some View {
        switch rightPane {
        case .inspector:
            inspectorPanel
        case .export:
            if let project {
                HorizontalExportPanel(
                    project: project,
                    appearanceSettings: appearanceSettings,
                    onClose: { rightPane = nil }
                )
            }
        case nil:
            EmptyView()
        }
    }

    /// Contents of the right-side slide-over inspector. Reuses the cross-platform
    /// `HorizontalSelectionPopoverView` in its `.sidebar` chrome (the same view the macOS
    /// selection sidebar uses); edits flow back to the active canvas as a
    /// `selectionPropertyChangeCommand`.
    @ViewBuilder
    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                Button {
                    rightPane = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Inspector")
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            Divider()
            if let inspectedPane, let details = selectionDetailsByPane[inspectedPane] {
                ScrollView {
                    HorizontalSelectionPopoverView(
                        state: details,
                        foregroundColor: .primary,
                        backgroundColor: .clear,
                        chrome: .sidebar,
                        onChange: { change in
                            selectionPropertyChangeCommands[inspectedPane] =
                                HorizontalSelectionPropertyChangeCommand(change: change)
                        }
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "cursorarrow.rays",
                    description: Text("Select an object on the canvas to inspect and edit it.")
                )
                Spacer()
            }
        }
    }

    /// The pane whose selection the inspector is editing: the focused one if it has a
    /// selection, otherwise any other visible pane that does.
    private var inspectedPane: HorizontalPane? {
        if selectionDetailsByPane[focusedPane]?.hasSelection == true {
            return focusedPane
        }
        return orderedVisiblePanes.first { selectionDetailsByPane[$0]?.hasSelection == true }
    }

    /// Records a canvas's selection and, when it actually selected something, moves the
    /// focus (and so the inspector) to that pane. Mirrors the macOS workspace.
    private func setSelectionDetails(_ details: HorizontalSelectionDetailState, for pane: HorizontalPane) {
        if details.hasSelection {
            selectionDetailsByPane[pane] = details
            focusedPane = pane
        } else {
            selectionDetailsByPane.removeValue(forKey: pane)
        }
    }

    private var loadIdentity: String {
        fileURL?.standardizedFileURL.path
            ?? document.archive.suggestedFilename
            ?? "untitled-horizontal-document"
    }

    private var statusView: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                Text("Loading project")
                    .font(.headline)
            } else if let loadError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(loadError)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            } else {
                Image(systemName: "doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Open a Horizontal project")
                    .font(.headline)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// All the top-bar controls in one view, so the single ToolbarItem hosting
    /// it renders them as one shared glass island — spacing alone separates the
    /// controls.
    private func toolbarIsland(for project: HorizontalProject) -> some View {
        HStack(spacing: 14) {
            readOnlyLockButton
            Button {
                settingsSheetPresented = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
            Button {
                rightPane = rightPane == .inspector ? nil : .inspector
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            if project.board != nil {
                Button {
                    rulesSheetPresented = true
                } label: {
                    Label("Board Rules", systemImage: "checklist")
                }
            }
            Button {
                rightPane = rightPane == .export ? nil : .export
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            if availablePanes(for: project).count > 1 {
                panePicker(for: project)
            }
        }
        .labelStyle(.iconOnly)
    }

    /// The read-only lock: shows the document's effective read-only state and
    /// toggles the preference (the same one Settings offers). Release builds
    /// force read-only with no preference to flip, so there the lock is a
    /// disabled indicator rather than a control.
    private var readOnlyLockButton: some View {
        let isReadOnly = appearanceSettings.isReadOnlyOperationEnabled
        return Button {
            appearanceSettings.readOnlyOperationBinding().wrappedValue = !isReadOnly
        } label: {
            Label(
                isReadOnly ? "Read-Only" : "Editable",
                systemImage: isReadOnly ? "lock.fill" : "lock.open"
            )
        }
        .disabled(HorizontalOperationDefaults.isReadOnlyOperationForced)
        .accessibilityLabel(isReadOnly ? "Read-only. Tap to allow editing." : "Editable. Tap to make read-only.")
    }

    /// The shared settings form (the same one the macOS Settings window hosts),
    /// presented as a sheet since iOS has no Settings scene.
    private var settingsSheet: some View {
        NavigationStack {
            HorizontalSettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { settingsSheetPresented = false }
                    }
                }
        }
    }

    /// Pane chooser. A regular width class (iPad) toggles panes independently so the
    /// schematic and the board can sit side by side; a compact one (iPhone) keeps the
    /// old exclusive segmented control, since there is no room for two. Both live
    /// inside the toolbar island, so neither draws its own grouped chrome (no
    /// ControlGroup — that would nest a second bordered capsule in the island).
    @ViewBuilder
    private func panePicker(for project: HorizontalProject) -> some View {
        let panes = availablePanes(for: project)
        if isCompact {
            Picker("View", selection: exclusivePaneSelection(among: panes)) {
                ForEach(panes) { pane in
                    Label(pane.title, systemImage: pane.symbolName)
                        .tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .fixedSize()
        } else {
            ForEach(panes) { pane in
                Toggle(isOn: paneVisibilityBinding(for: pane, among: panes)) {
                    Label(pane.title, systemImage: pane.symbolName)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Show \(pane.title)")
            }
        }
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    /// Visible panes in `HorizontalPane`'s own order, which is also their left-to-right
    /// order on screen.
    private var orderedVisiblePanes: [HorizontalPane] {
        HorizontalPane.allCases.filter { visiblePanes.contains($0) }
    }

    private func exclusivePaneSelection(among panes: [HorizontalPane]) -> Binding<HorizontalPane> {
        Binding {
            orderedVisiblePanes.first ?? panes.first ?? .schematic
        } set: { pane in
            visiblePanes = [pane]
            focusedPane = pane
        }
    }

    private func paneVisibilityBinding(for pane: HorizontalPane, among panes: [HorizontalPane]) -> Binding<Bool> {
        Binding {
            visiblePanes.contains(pane)
        } set: { isVisible in
            withAnimation(.snappy(duration: 0.2)) {
                if isVisible {
                    visiblePanes.insert(pane)
                    focusedPane = pane
                } else if visiblePanes.intersection(panes).count > 1 {
                    // Never hide the last pane — that would leave an empty window.
                    visiblePanes.remove(pane)
                }
            }
        }
    }

    /// The side-by-side pane layout. `ignoresSafeArea` is what lets the canvases run
    /// edge to edge under the navigation bar and the home indicator; the insets the
    /// panes would otherwise have been given are handed to them instead, so the tool
    /// rails and the fit-to-window margins still clear the chrome.
    ///
    /// The modifier goes on the split view, NOT on the GeometryReader: a
    /// GeometryReader that ignores the safe area itself reports `safeAreaInsets` of
    /// zero, which put the rails back under the toolbar. (Same shape as the macOS
    /// workspace's `workspaceDetail`.)
    private func paneSplit(for project: HorizontalProject) -> some View {
        GeometryReader { proxy in
            let panes = orderedVisiblePanes.filter { availablePanes(for: project).contains($0) }
            let shownPanes = panes.isEmpty ? [defaultPane(for: project)] : panes

            ResizablePaneSplitView(
                panes: shownPanes,
                sizeFractions: $paneSizeFractions,
                minimumPaneWidth: 300,
                handleWidth: 16
            ) { pane, isLeadingPane in
                paneContent(
                    pane,
                    for: project,
                    safeAreaInsets: paneSafeAreaInsets(
                        proxy.safeAreaInsets,
                        isLeadingPane: isLeadingPane,
                        isTrailingPane: shownPanes.last == pane
                    )
                )
            }
            .ignoresSafeArea(.container, edges: .all)
        }
    }

    /// Splits the window's safe-area insets across the panes: every pane clears the top
    /// bar and the bottom indicator, but only the outermost panes own the side insets.
    private func paneSafeAreaInsets(
        _ insets: EdgeInsets,
        isLeadingPane: Bool,
        isTrailingPane: Bool
    ) -> EdgeInsets {
        EdgeInsets(
            top: insets.top,
            leading: isLeadingPane ? insets.leading : 0,
            bottom: insets.bottom,
            trailing: isTrailingPane ? insets.trailing : 0
        )
    }

    @ViewBuilder
    private func paneContent(
        _ pane: HorizontalPane,
        for project: HorizontalProject,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        switch pane {
        case .parts:
            partsBrowser(for: project, safeAreaInsets: safeAreaInsets)
        case .schematic:
            schematicView(for: project, safeAreaInsets: safeAreaInsets)
        case .board:
            boardView(for: project, safeAreaInsets: safeAreaInsets)
        case .threeD:
            threeDView(for: project)
        }
    }

    private func partsBrowser(for project: HorizontalProject, safeAreaInsets: EdgeInsets) -> some View {
        // The same cross-platform browser the macOS workspace uses: scoped search,
        // a sortable Table, and Place (double-tap a row / the Place button). Placing
        // starts the schematic place-on-canvas interaction via `placePartRequest`.
        HorizontalPartBrowserView(
            parts: project.poolParts,
            poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) },
            safeAreaInsets: safeAreaInsets,
            isReadOnly: project.schematic == nil,
            onPlacePart: { part in
                guard project.schematic != nil else { return }
                placePartRequest = HorizontalPartPlacementRequest(part: part)
                if isCompact {
                    visiblePanes = [.schematic]
                } else {
                    visiblePanes.insert(.schematic)
                }
                focusedPane = .schematic
            }
        )
    }

    @ViewBuilder
    private func schematicView(for project: HorizontalProject, safeAreaInsets: EdgeInsets) -> some View {
        if let schematic = project.schematic,
           let sheet = schematic.sheets.first {
            PaneOverlayContainer(
                pane: .schematic,
                safeAreaInsets: safeAreaInsets,
                showsInfoButton: false,
                isKeyboardFocused: focusedPane == .schematic
            ) {
                SchematicCanvasView(
                    sheet: sheet,
                    allSheets: schematic.sheets,
                    viewport: $schematicViewport,
                    displayOptions: schematicDisplayOptions,
                    fitSafeAreaInsets: safeAreaInsets,
                    highlightedNetIDs: highlightedNetIDs,
                    selectionToolSettings: selectionToolSettings,
                    onSelectedNetChange: { selectedNetIDs = $0 },
                    onHighlightNetCommand: { highlightedNetIDs = $0 },
                    onSheetChange: { applyEditedSchematicSheet($0) },
                    onSelectionDetailsChange: { setSelectionDetails($0, for: .schematic) },
                    onCanvasCommandActionsChange: { schematicCanvasActions = $0 },
                    selectionPropertyChangeCommand: selectionPropertyChangeCommands[.schematic],
                    drawingToolCommand: schematicDrawingToolCommand,
                    drawNetLineCommand: schematicDrawNetLineCommand,
                    placePartRequest: placePartRequest,
                    poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
                )
                .overlay(alignment: .bottom) {
                    toolControlBar(for: schematicCanvasActions, safeAreaInsets: safeAreaInsets)
                }
            } info: {
                EmptyView()
            } layers: {
                SchematicLayerControls(displayOptions: $schematicDisplayOptions)
            } grid: {
                GridControlsPanel(title: "Schematic Grid", grid: .constant(sheet.grid), isEditable: false)
            } tools: {
                SelectionToolButton(settings: $selectionToolSettings)
                DrawingToolButtonGroup { primitive in
                    schematicDrawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                }
                DrawNetLineToolButton {
                    schematicDrawNetLineCommand = HorizontalDrawNetLineCommand()
                }
                AddTextToolButton {
                    schematicCanvasActions?.dispatch(.addText)
                }
            }
        } else {
            ContentUnavailableView("No Schematic", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    @ViewBuilder
    private func boardView(for project: HorizontalProject, safeAreaInsets: EdgeInsets) -> some View {
        if let board = project.board {
            PaneOverlayContainer(
                pane: .board,
                safeAreaInsets: safeAreaInsets,
                showsInfoButton: false,
                isKeyboardFocused: focusedPane == .board
            ) {
                BoardCanvasView(
                    board: board,
                    netClasses: project.schematic?.netClasses ?? [],
                    viewport: $boardViewport,
                    displayOptions: boardDisplayOptions,
                    fitSafeAreaInsets: safeAreaInsets,
                    highlightedNetIDs: highlightedNetIDs,
                    selectionToolSettings: selectionToolSettings,
                    onSelectedNetChange: { selectedNetIDs = $0 },
                    onHighlightNetCommand: { highlightedNetIDs = $0 },
                    onBoardChange: { applyEditedBoard($0) },
                    onSelectionDetailsChange: { setSelectionDetails($0, for: .board) },
                    onCanvasCommandActionsChange: { boardCanvasActions = $0 },
                    selectionPropertyChangeCommand: selectionPropertyChangeCommands[.board],
                    drawingToolCommand: boardDrawingToolCommand,
                    drawTrackCommand: boardDrawTrackCommand,
                    onShowToolSettings: { boardToolSettingsPresented = true },
                    toolSettings: boardToolSettings,
                    drawingLayer: boardDrawingLayer
                )
                .overlay(alignment: .bottom) {
                    toolControlBar(for: boardCanvasActions, safeAreaInsets: safeAreaInsets)
                }
            } info: {
                EmptyView()
            } layers: {
                BoardLayerControls(
                    board: board,
                    displayOptions: $boardDisplayOptions,
                    selectedLayer: $boardDrawingLayer,
                    includesThreeDControls: false
                )
            } grid: {
                GridControlsPanel(title: "Board Grid", grid: boardGridBinding())
            } tools: {
                SelectionToolButton(settings: $selectionToolSettings)
                DrawTrackToolButton {
                    boardDrawTrackCommand = HorizontalDrawTrackCommand()
                }
                TrackSettingsToolButton(presented: $boardToolSettingsPresented)
                    .popover(isPresented: $boardToolSettingsPresented, arrowEdge: .bottom) {
                        HorizontalBoardToolSettingsView(settings: boardToolSettings, viaTemplate: board.viaTemplate)
                            .frame(minWidth: 320, minHeight: 320)
                    }
                DrawingToolButtonGroup { primitive in
                    boardDrawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                }
                DrawPlaneToolButton {
                    boardCanvasActions?.dispatch(.drawPlane)
                }
                AddTextToolButton {
                    boardCanvasActions?.dispatch(.addText)
                }
            }
        } else {
            ContentUnavailableView("No Board", systemImage: "cpu")
        }
    }

    /// Persisting board-grid binding (mirrors the macOS workspace): edits write
    /// through `applyEditedBoard` so the DocumentGroup sees them.
    private func boardGridBinding() -> Binding<HorizontalGridSettings> {
        Binding {
            project?.board?.grid ?? .boardDefault
        } set: { grid in
            guard var board = project?.board else { return }
            board.grid = grid.withClampedValues()
            applyEditedBoard(board)
        }
    }

    /// On-screen routing controls shown while a route is in progress (the iPad
    /// stand-in for the macOS keyboard: finish/cancel/via/flip/back). Pencil
    /// hover drives the live preview; tap places points.
    @ViewBuilder
    private func toolControlBar(
        for actions: HorizontalCanvasCommandActions?,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        if let actions, actions.canCancelInteraction {
            HStack(spacing: 16) {
                routeControl("Finish", "checkmark.circle.fill", enabled: actions.canCommitInteraction) {
                    actions.dispatch(.commitInteraction)
                }
                routeControl("Cancel", "xmark.circle", enabled: true) {
                    actions.dispatch(.cancelInteraction)
                }
                routeControl("Back", "arrow.uturn.backward", enabled: actions.canCommitInteraction) {
                    actions.dispatch(.deleteSelection)
                }
                if actions.canToggleVia {
                    routeControl("Via", "circle.circle", enabled: true) {
                        actions.dispatch(.toggleVia)
                    }
                }
                if actions.canFlipTrackPosture {
                    routeControl("Flip", "arrow.triangle.turn.up.right.diamond", enabled: true) {
                        actions.dispatch(.flipTrackPosture)
                    }
                }
                if actions.canEnterTrackWidth {
                    routeControl("Width", "lineweight", enabled: true) {
                        actions.dispatch(.enterTrackWidth)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            // The canvas runs under the home indicator now, so lift the bar clear of it.
            .padding(.bottom, safeAreaInsets.bottom + 20)
        }
    }

    private func routeControl(_ title: String, _ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }

    /// Applies an edited schematic sheet to the in-memory project and the
    /// document archive (DocumentGroup persists the binding). Mirrors the macOS
    /// workspace — without this, sheet edits rendered but never reached the
    /// document, so drawing on a schematic silently didn't save.
    private func applyEditedSchematicSheet(_ sheet: HorizontalSchematicSheet) {
        guard var updated = project, var schematic = updated.schematic else { return }
        for index in schematic.sheets.indices {
            schematic.sheets[index].grid = sheet.grid
        }
        if let index = schematic.sheets.firstIndex(where: { $0.id == sheet.id }) {
            schematic.sheets[index] = sheet
        }
        updated.schematic = schematic
        let standardizedURL = schematic.url.standardizedFileURL
        for index in updated.schematics.indices
            where updated.schematics[index].schematic.url.standardizedFileURL == standardizedURL {
            updated.schematics[index].schematic = schematic
        }
        project = updated
        do {
            try HorizontalProjectJSONApplicator.apply(
                schematicSheet: sheet,
                schematicURL: schematic.url,
                in: updated,
                to: &document.archive
            )
        } catch {
            loadError = "Couldn't save schematic changes: \(error.localizedDescription)"
        }
    }

    /// Applies a routed/edited board to the in-memory project and the document
    /// archive (DocumentGroup persists the binding). Mirrors the macOS path.
    private func applyEditedBoard(_ board: HorizontalBoard) {
        guard var updated = project else { return }
        updated.board = board
        project = updated
        do {
            try HorizontalProjectJSONApplicator.apply(board: board, in: updated, to: &document.archive)
        } catch {
            loadError = "Couldn't save board changes: \(error.localizedDescription)"
        }
    }

    /// The board design-rules (DRC) editor + checks. macOS opens this in a separate
    /// NSWindow; iPad presents the same SwiftUI view full-screen with a Done button.
    /// The view runs its own checks (the `.checks` tab), so `onChecksRun` (the macOS
    /// hook that mirrors results into a sidebar) is a no-op here.
    @ViewBuilder
    private func boardRulesCover(for project: HorizontalProject) -> some View {
        NavigationStack {
            HorizontalBoardRulesWindow(
                projectName: project.name,
                board: project.board,
                netClasses: project.schematic?.netClasses ?? [],
                initialRules: (try? HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive)) ?? [:],
                isReadOnly: false,
                onRulesChange: { applyEditedBoardRules($0) },
                onChecksRun: { _ in }
            )
            .navigationTitle("Board Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { rulesSheetPresented = false }
                }
            }
        }
    }

    private func applyEditedBoardRules(_ rules: JSONDictionary) {
        guard let project else { return }
        do {
            try HorizontalProjectJSONApplicator.apply(boardRules: rules, in: project, to: &document.archive)
        } catch {
            loadError = "Couldn't save board rules: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func threeDView(for project: HorizontalProject) -> some View {
        if let board = project.board {
            BoardSceneView(
                board: board,
                displayOptions: BoardDisplayOptions(),
                backgroundColor: appearanceSettings.boardSceneBackground,
                copperColor: appearanceSettings.boardSceneCopper,
                layerColors: appearanceSettings.boardSceneLayerColors,
                materialColors: appearanceSettings.boardSceneMaterialColors,
                cameraState: $threeDCameraState
            )
        } else {
            ContentUnavailableView("No Board", systemImage: "cube")
        }
    }

    private func loadProject() {
        isLoading = true
        loadError = nil
        project = nil

        do {
            let url = try projectURLForLoading()
            let loadedProject = try HorizontalProject.load(from: url)
            project = loadedProject
            visiblePanes = defaultVisiblePanes(for: loadedProject)
            focusedPane = orderedVisiblePanes.first ?? defaultPane(for: loadedProject)
            paneSizeFractions.removeAll()
            schematicViewport.fit()
            boardViewport.fit()
            threeDCameraState = nil
            selectedNetIDs.removeAll()
            highlightedNetIDs.removeAll()
            selectionDetailsByPane.removeAll()
            restoreViewState(for: loadedProject)
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    /// Restores the per-file view state (open panes, separator positions, the
    /// right slide-over) the last close saved. Runs after the defaults above so
    /// a file with no stored state keeps them; panes the stored state names
    /// but this project no longer offers are dropped.
    private func restoreViewState(for project: HorizontalProject) {
        didRestoreViewState = false
        guard let fileURL else {
            // An unsaved document has no identity to store under; enable the
            // save hooks anyway so they cheaply no-op instead of never running.
            didRestoreViewState = true
            return
        }

        if let stored = HorizontalFileViewStateStore.shared.load(for: fileURL) {
            var panes = stored.visiblePanes.intersection(availablePanes(for: project))
            if isCompact, panes.count > 1, let first = panes.sorted(by: { $0.rawValue < $1.rawValue }).first {
                panes = [first]
            }
            if !panes.isEmpty {
                visiblePanes = panes
                focusedPane = orderedVisiblePanes.first ?? focusedPane
            }
            paneSizeFractions = stored.paneSizeFractions.mapValues { CGFloat($0) }
            switch stored.rightSidebarPane {
            case .selection:
                rightPane = .inspector
            case .export:
                rightPane = .export
            case .rulesResults, nil:
                rightPane = nil
            }
        }
        didRestoreViewState = true
    }

    private func scheduleViewStateSave() {
        guard didRestoreViewState, fileURL != nil else {
            return
        }
        viewStateSaveTask?.cancel()
        viewStateSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }
            saveViewState()
            viewStateSaveTask = nil
        }
    }

    private func saveViewState() {
        guard didRestoreViewState, let fileURL else {
            return
        }
        // Start from the stored state so the fields this view doesn't manage
        // (viewports, display options, window size) survive the round trip.
        var state = HorizontalFileViewStateStore.shared.load(for: fileURL) ?? .default
        state.visiblePanes = visiblePanes
        state.paneSizeFractions = paneSizeFractions.mapValues(Double.init)
        switch rightPane {
        case .inspector:
            state.rightSidebarPane = .selection
        case .export:
            state.rightSidebarPane = .export
        case nil:
            state.rightSidebarPane = nil
        }
        state.showsSelectionSidebar = rightPane == .inspector
        HorizontalFileViewStateStore.shared.save(state, for: fileURL)
    }

    private func projectURLForLoading() throws -> URL {
        if let fileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalIPadViewer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = document.archive.suggestedFilename ?? "Imported.horizontal"
        let url = directory.appendingPathComponent(filename)
        try document.archive.write(to: url)
        return url
    }

    private func availablePanes(for project: HorizontalProject) -> [HorizontalPane] {
        var panes = [HorizontalPane]()
        if !project.poolParts.isEmpty {
            panes.append(.parts)
        }
        if project.schematic != nil {
            panes.append(.schematic)
        }
        if project.board != nil {
            panes.append(.board)
            panes.append(.threeD)
        }
        return panes.isEmpty ? [.schematic] : panes
    }

    private func defaultPane(for project: HorizontalProject) -> HorizontalPane {
        let panes = availablePanes(for: project)
        if panes.contains(.schematic) {
            return .schematic
        }
        return panes.first ?? .schematic
    }

    /// Opens the schematic and the board side by side where there is room for both —
    /// the macOS workspace's default — and a single pane on a compact width.
    private func defaultVisiblePanes(for project: HorizontalProject) -> Set<HorizontalPane> {
        let panes = availablePanes(for: project)
        guard !isCompact, panes.contains(.schematic), panes.contains(.board) else {
            return [defaultPane(for: project)]
        }
        return [.schematic, .board]
    }
}

/// `navigationDocument(_:)` takes a non-optional URL, and an in-memory document has
/// none — this applies it only when there is a file behind the document.
private struct NavigationDocumentModifier: ViewModifier {
    var url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}

/// iPad export UI. Presents the shared `HorizontalExportSidebarView` panel in a sheet,
/// runs `HorizontalExportBackend` into a throwaway temp directory, then hands the result
/// to a document picker so the user can save the exported files into the Files app.
/// (macOS exports straight to a user-chosen on-disk folder; the iOS sandbox can't, so
/// we export to /tmp and let the picker copy the folder out.)
/// Which pane the iPad right-side slide-over is showing (one at a time, mirroring the
/// macOS workspace's single right sidebar).
enum HorizontalIPadRightPane {
    case inspector
    case export
}

/// Right-side slide-over export panel (the iPad analogue of the macOS export
/// sidebar). Hosts the shared `HorizontalExportSidebarView`; export still runs to a temp
/// folder and offers the result via the document picker.
struct HorizontalExportPanel: View {
    let project: HorizontalProject
    let appearanceSettings: HorizontalAppearanceSettings
    var onClose: () -> Void = {}

    @State private var settings: HorizontalExportSettings
    @State private var status: HorizontalExportStatus?
    @State private var exportedFolderURL: URL?
    @State private var documentPickerPresented = false
    @State private var isExporting = false

    init(project: HorizontalProject, appearanceSettings: HorizontalAppearanceSettings, onClose: @escaping () -> Void = {}) {
        self.project = project
        self.appearanceSettings = appearanceSettings
        self.onClose = onClose
        _settings = State(initialValue: HorizontalExportSettings(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Export")
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            Divider()
            HorizontalExportSidebarView(
                project: project,
                settings: $settings,
                status: status,
                isExporting: isExporting,
                safeAreaInsets: EdgeInsets(),
                providesChrome: false,
                onExport: { section in Task { await runExport(sections: [section]) } },
                onExportAll: {
                    Task { await runExport(sections: HorizontalExportSection.allCases.filter { settings.isEnabled($0) }) }
                }
            )
        }
        .sheet(isPresented: $documentPickerPresented) {
            if let exportedFolderURL {
                HorizontalDocumentExporter(url: exportedFolderURL) {
                    documentPickerPresented = false
                }
                .ignoresSafeArea()
            }
        }
    }

    private func runExport(sections: [HorizontalExportSection]) async {
        guard !sections.isEmpty, !isExporting else { return }
        let safeName = project.name.replacingOccurrences(of: "/", with: "-")
        let folderName = safeName.isEmpty ? "Export" : "\(safeName) Export"
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalExport-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        var exportSettings = settings
        exportSettings.targetDirectory = tempRoot.path
        // Snapshot the value-type inputs on the main actor, then run the (synchronous,
        // CPU + file-IO heavy) export off-main so the spinner keeps animating.
        let exportProject = project
        let schematicPalette = appearanceSettings.palette(for: .schematic, mode: .light)
        let boardPalette = appearanceSettings.palette(for: .board, mode: .light)

        isExporting = true
        status = nil
        let result = await Task.detached(priority: .userInitiated) {
            HorizontalExportBackend.export(
                sections: sections,
                settings: exportSettings,
                project: exportProject,
                schematicPDFPalette: schematicPalette,
                boardPDFPalette: boardPalette
            )
        }.value
        isExporting = false
        status = result
        if result.kind == .success {
            exportedFolderURL = tempRoot
            documentPickerPresented = true
        }
    }
}

/// Wraps `UIDocumentPickerViewController` in "export" mode so the user can copy an
/// exported folder out of the app's sandbox into the Files app. Hosted in a SwiftUI
/// `.sheet`, the picker can't dismiss itself, so the delegate drives `onFinish` (on
/// both pick and cancel) to clear the presenting flag.
struct HorizontalDocumentExporter: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
#endif
