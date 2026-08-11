#if os(iOS)
import SwiftUI
import UIKit

struct HorizontalIPadProjectView: View {
    @Binding private var document: HorizontalProjectDocument
    private var fileURL: URL?

    @State private var project: HorizontalProject?
    @State private var activePane: HorizontalPane = .schematic
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
    // Selection details reported up from the active canvas + the property-edit command
    // sent back down (drive the inspector pane).
    @State private var selectionDetails = HorizontalSelectionDetailState.empty
    @State private var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    // Part placement: the part browser sets a request, which the schematic canvas
    // picks up (via its onAppear/onChange) to start the place-on-canvas interaction.
    @State private var placePartRequest: HorizontalPartPlacementRequest?

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(document: Binding<HorizontalProjectDocument>, fileURL: URL?) {
        self._document = document
        self.fileURL = fileURL
    }

    var body: some View {
        // No NavigationStack here: the DocumentGroup already supplies the document
        // navigation bar (filename + back-to-Files + the document menu). Wrapping
        // the content in another NavigationStack stacked a second, redundant bar
        // (the duplicate document title) beneath it.
        HorizontalInspectorSlideOver(isPresented: rightPane != nil) {
            VStack(spacing: 0) {
                if let project {
                    paneContent(for: project)
                } else {
                    statusView
                }
            }
        } inspector: {
            rightPaneContent
        }
        .toolbar {
            if let project, project.board != nil || project.schematic != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        rightPane = rightPane == .inspector ? nil : .inspector
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                }
            }
            if let project, project.board != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        rulesSheetPresented = true
                    } label: {
                        Label("Board Rules", systemImage: "checklist")
                    }
                }
            }
            if let project, project.board != nil || project.schematic != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        rightPane = rightPane == .export ? nil : .export
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if let project, availablePanes(for: project).count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    panePicker(for: project)
                }
            }
        }
        .fullScreenCover(isPresented: $rulesSheetPresented) {
            if let project {
                boardRulesCover(for: project)
            }
        }
        .onChange(of: activePane) { _, newPane in
            // Switching panes re-instantiates the schematic canvas, whose
            // "already-handled" guard (`handledPlacePartRequestID`) is per-instance and
            // resets — so a still-set request would restart placement on return. Clear
            // it when leaving the schematic. (macOS keeps one persistent canvas, so it
            // doesn't need this.)
            if newPane != .schematic {
                placePartRequest = nil
            }
        }
        .task(id: loadIdentity) {
            loadProject()
        }
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
            if selectionDetails.hasSelection {
                ScrollView {
                    HorizontalSelectionPopoverView(
                        state: selectionDetails,
                        foregroundColor: .primary,
                        backgroundColor: .clear,
                        chrome: .sidebar,
                        onChange: { change in
                            selectionPropertyChangeCommand = HorizontalSelectionPropertyChangeCommand(change: change)
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

    private func panePicker(for project: HorizontalProject) -> some View {
        Picker("View", selection: $activePane) {
            ForEach(availablePanes(for: project)) { pane in
                Label(pane.title, systemImage: pane.symbolName)
                    .tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    @ViewBuilder
    private func paneContent(for project: HorizontalProject) -> some View {
        switch activePane {
        case .parts:
            partsBrowser(for: project)
        case .schematic:
            schematicView(for: project)
        case .board:
            boardView(for: project)
        case .threeD:
            threeDView(for: project)
        }
    }

    private func partsBrowser(for project: HorizontalProject) -> some View {
        // The same cross-platform browser the macOS workspace uses: scoped search,
        // a sortable Table, and Place (double-tap a row / the Place button). Placing
        // starts the schematic place-on-canvas interaction via `placePartRequest`.
        HorizontalPartBrowserView(
            parts: project.poolParts,
            poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) },
            isReadOnly: project.schematic == nil,
            onPlacePart: { part in
                guard project.schematic != nil else { return }
                placePartRequest = HorizontalPartPlacementRequest(part: part)
                activePane = .schematic
            }
        )
    }

    @ViewBuilder
    private func schematicView(for project: HorizontalProject) -> some View {
        if let schematic = project.schematic,
           let sheet = schematic.sheets.first {
            GeometryReader { proxy in
                PaneOverlayContainer(
                    pane: .schematic,
                    safeAreaInsets: proxy.safeAreaInsets,
                    showsInfoButton: false,
                    isKeyboardFocused: true
                ) {
                    SchematicCanvasView(
                        sheet: sheet,
                        allSheets: schematic.sheets,
                        viewport: $schematicViewport,
                        displayOptions: schematicDisplayOptions,
                        fitSafeAreaInsets: proxy.safeAreaInsets,
                        highlightedNetIDs: highlightedNetIDs,
                        selectionToolSettings: selectionToolSettings,
                        onSelectedNetChange: { selectedNetIDs = $0 },
                        onHighlightNetCommand: { highlightedNetIDs = $0 },
                        onSelectionDetailsChange: { selectionDetails = $0 },
                        onCanvasCommandActionsChange: { schematicCanvasActions = $0 },
                        selectionPropertyChangeCommand: selectionPropertyChangeCommand,
                        drawingToolCommand: schematicDrawingToolCommand,
                        drawNetLineCommand: schematicDrawNetLineCommand,
                        placePartRequest: placePartRequest,
                        poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
                    )
                    .overlay(alignment: .bottom) { toolControlBar(for: schematicCanvasActions) }
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
            }
        } else {
            ContentUnavailableView("No Schematic", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    @ViewBuilder
    private func boardView(for project: HorizontalProject) -> some View {
        if let board = project.board {
            GeometryReader { proxy in
                PaneOverlayContainer(
                    pane: .board,
                    safeAreaInsets: proxy.safeAreaInsets,
                    showsInfoButton: false,
                    isKeyboardFocused: true
                ) {
                    BoardCanvasView(
                        board: board,
                        netClasses: project.schematic?.netClasses ?? [],
                        viewport: $boardViewport,
                        displayOptions: boardDisplayOptions,
                        fitSafeAreaInsets: proxy.safeAreaInsets,
                        highlightedNetIDs: highlightedNetIDs,
                        selectionToolSettings: selectionToolSettings,
                        onSelectedNetChange: { selectedNetIDs = $0 },
                        onHighlightNetCommand: { highlightedNetIDs = $0 },
                        onBoardChange: { applyEditedBoard($0) },
                        onSelectionDetailsChange: { selectionDetails = $0 },
                        onCanvasCommandActionsChange: { boardCanvasActions = $0 },
                        selectionPropertyChangeCommand: selectionPropertyChangeCommand,
                        drawingToolCommand: boardDrawingToolCommand,
                        drawTrackCommand: boardDrawTrackCommand,
                        onShowToolSettings: { boardToolSettingsPresented = true },
                        toolSettings: boardToolSettings,
                        drawingLayer: boardDrawingLayer
                    )
                    .overlay(alignment: .bottom) { toolControlBar(for: boardCanvasActions) }
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
    private func toolControlBar(for actions: HorizontalCanvasCommandActions?) -> some View {
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
            .padding(.bottom, 20)
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
            .ignoresSafeArea(edges: .bottom)
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
            activePane = defaultPane(for: loadedProject)
            schematicViewport.fit()
            boardViewport.fit()
            threeDCameraState = nil
            selectedNetIDs.removeAll()
            highlightedNetIDs.removeAll()
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
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
