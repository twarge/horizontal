#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI

enum ProjectNavigatorSelection: Hashable {
    case package
    case projectFile
    case blocksFile
    case pool
    case block(String)
    case sheet(blockID: String, sheetID: String)
    case standaloneSheet(String)
    case board
    case diagnostics
}

struct ProjectDocumentView: View {
    let configuration: FileDocumentConfiguration<HorizontalProjectDocument>
    @Binding var document: HorizontalProjectDocument

    @State private var state = ProjectLoadState.loading
    @State private var visiblePanes: Set<HorizontalPane> = [.schematic, .board]
    @State private var selectedNetIDs = Set<String>()
    @State private var highlightedNetIDs = Set<String>()
    @State private var selectedComponentIDs = Set<String>()
    @State private var highlightedComponentIDs = Set<String>()
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    private var windowTheme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    var body: some View {
        content
            .frame(minWidth: 980, minHeight: 640)
            .background(WindowChromeConfigurator(isTransparent: appearanceSettings.isToolbarTransparent))
            .containerBackground(windowTheme.background, for: .window)
            .toolbarBackgroundVisibility(
                appearanceSettings.isToolbarTransparent ? .hidden : .visible,
                for: .windowToolbar
            )
            .task(id: configuration.fileURL) {
                await loadProject()
            }
            // Unlocking mid-session (the toolbar lock or the Settings toggle):
            // a project opened read-only skipped completing its writable
            // archive, so reload to build it. The workspace keeps its own state
            // (same view identity) — only `document.archive` refreshes.
            .onChange(of: appearanceSettings.isReadOnlyOperationEnabled) { wasReadOnly, isReadOnly in
                if wasReadOnly, !isReadOnly {
                    Task { await loadProject() }
                }
            }
            .focusedSceneValue(\.horizonVisiblePanes, $visiblePanes)
            .focusedSceneValue(\.horizonHighlightNetAction, highlightSelectedNet)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
        case .failed(let message):
            ContentUnavailableView("Could Not Open Project", systemImage: "exclamationmark.triangle", description: Text(message))
        case .needsFolderAccess(let message):
            ContentUnavailableView {
                Label("Needs Folder Access", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Grant Access…") {
                    Task { await loadProject() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded(let project):
            ProjectWorkspaceView(
                project: project,
                document: $document,
                visiblePanes: $visiblePanes,
                selectedNetIDs: $selectedNetIDs,
                highlightedNetIDs: $highlightedNetIDs,
                selectedComponentIDs: $selectedComponentIDs,
                highlightedComponentIDs: $highlightedComponentIDs
            )
                .id(project.url)
                .navigationTitle(project.displayTitle)
        case .pool(let poolURL):
            HorizontalPoolBrowserView(root: .pool(poolURL))
                .id(poolURL)
                .navigationTitle(HorizontalPoolRegistryStore.poolInfo(at: poolURL).name)
                .navigationSubtitle(poolURL.path)
        }
    }

    private func highlightSelectedNet() {
        highlightedNetIDs = selectedNetIDs
        highlightedComponentIDs = selectedComponentIDs
    }

    private func loadProject() async {
        guard let url = configuration.fileURL else {
            await loadUntitledProject()
            return
        }

        if Self.isPoolManifest(url) {
            await loadPool(manifestURL: url)
            return
        }

        state = .loading
        // Sandbox: a bare .hprj only carries a grant for the file itself, but
        // the loaders read siblings (board, blocks, pool). Restore or prompt
        // for enclosing-folder access before kicking off the load tasks.
        await HorizontalFolderAccessStore.prepareProjectAccess(for: url)
        // Refuse to open rather than showing a project with an empty board.
        // `HorizontalProject.load` records an unreadable sibling as a non-fatal
        // diagnostic and carries on, so a revoked or never-granted folder would
        // otherwise surface as a window whose board, schematic and 3D panes are
        // all silently blank — with the real cause buried in the Diagnostics
        // list. Checked AFTER prepareProjectAccess so this only reports a grant
        // the user actually declined (or one that has since been revoked).
        guard HorizontalFolderAccessStore.hasProjectFolderAccess(for: url) else {
            state = .needsFolderAccess(HorizontalFolderAccessStore.projectFolderAccessMessage(for: url))
            return
        }
        let loadStart = BoardLoadTimer.timingStart()
        defer {
            BoardLoadTimer.recordStandalone(
                "Document UI load total (\(url.lastPathComponent))",
                nanoseconds: BoardLoadTimer.elapsedNanoseconds(since: loadStart)
            )
        }

        do {
            let archiveTask: Task<HorizontalProjectArchive, Error>? = appearanceSettings.isReadOnlyOperationEnabled
                ? nil
                : Task.detached(priority: .userInitiated) {
                    try BoardLoadTimer.measureStandalone("Complete writable project archive") {
                        try HorizontalProjectArchive.completeProject(from: url)
                    }
                }
            let projectTask = Task.detached(priority: .userInitiated) {
                try HorizontalProject.load(from: url)
            }
            let project = try await projectTask.value
            if let archive = try await archiveTask?.value,
               document.archive != archive {
                document.archive = archive
            }
            state = .loaded(project)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// A `pool.json` opened as a document — the project type accepts plain
    /// JSON, and Horizon's own manager opens pools this way — is a pool, not a
    /// project: show the library browser rooted at its folder instead of
    /// failing to find a project inside the file.
    private static func isPoolManifest(_ url: URL) -> Bool {
        guard url.lastPathComponent.caseInsensitiveCompare("pool.json") == .orderedSame,
              let json = try? JSONHelper.loadDictionary(from: url) else {
            return false
        }
        return json.string("type") == "pool"
    }

    private func loadPool(manifestURL url: URL) async {
        state = .loading
        // Sandbox: the open grants pool.json alone; the browser lists the
        // whole folder, so restore or prompt for that first.
        await HorizontalFolderAccessStore.preparePoolAccess(for: url)
        guard HorizontalFolderAccessStore.hasPoolFolderAccess(for: url) else {
            state = .needsFolderAccess(HorizontalFolderAccessStore.poolFolderAccessMessage(for: url))
            return
        }
        state = .pool(url.deletingLastPathComponent().standardizedFileURL)
    }

    /// File > New: the document has no URL until its first save, so materialize
    /// the in-memory template archive in a temporary folder and load from there
    /// (the iPad view does the same for URL-less documents). The archive is
    /// already a complete package, so there is no folder-access or
    /// `completeProject` step; the first save writes it wherever the user
    /// chooses and the `.task(id: configuration.fileURL)` reload takes over.
    private func loadUntitledProject() async {
        state = .loading
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HorizontalUntitled", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(document.archive.suggestedFilename ?? "Untitled.horizontal")
            try document.archive.write(to: url)
            let project = try await Task.detached(priority: .userInitiated) {
                try HorizontalProject.load(from: url)
            }.value
            state = .loaded(project)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private enum ProjectLoadState {
    case loading
    case loaded(HorizontalProject)
    /// A pool.json opened as a document: the library browser on its folder.
    case pool(URL)
    case failed(String)
    /// The sandbox can't read the folder holding a bare `.hprj`'s siblings.
    /// Distinct from `.failed` so it can explain the grant and offer to ask for
    /// it again, rather than reading as a corrupt or unsupported project.
    case needsFolderAccess(String)
}

private enum BoardSyncError: LocalizedError {
    case missingBoard

    var errorDescription: String? {
        switch self {
        case .missingBoard:
            "The project snapshot did not contain a board after reloading schematic data."
        }
    }
}

private struct DistractionFreeRestoreState {
    var columnVisibility: NavigationSplitViewVisibility
    var rightSidebarPane: HorizontalWorkspaceRightSidebar?
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    var activationID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.focus(nsView, activationID: activationID)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        private var focusedActivationID: Int?

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else {
                return
            }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }

            if parent.text.isEmpty {
                parent.isPresented = false
            } else {
                parent.text = ""
                control.stringValue = ""
            }
            return true
        }

        func focus(_ field: NSSearchField, activationID: Int) {
            guard focusedActivationID != activationID else {
                return
            }

            focusedActivationID = activationID
            Self.focus(field, attemptsRemaining: 4)
        }

        private static func focus(_ field: NSSearchField, attemptsRemaining: Int) {
            DispatchQueue.main.async { [weak field] in
                guard let field else {
                    return
                }

                if let window = field.window {
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                } else if attemptsRemaining > 0 {
                    focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }
}

private struct WorkspaceKeyCommandMonitor: NSViewRepresentable {
    var onFind: () -> Void
    var onDistractionFree: () -> Void
    var onHighlightSelection: () -> Void

    func makeNSView(context: Context) -> KeyCommandMonitorView {
        let view = KeyCommandMonitorView()
        view.onFind = onFind
        view.onDistractionFree = onDistractionFree
        view.onHighlightSelection = onHighlightSelection
        return view
    }

    func updateNSView(_ nsView: KeyCommandMonitorView, context: Context) {
        nsView.onFind = onFind
        nsView.onDistractionFree = onDistractionFree
        nsView.onHighlightSelection = onHighlightSelection
    }

    final class KeyCommandMonitorView: NSView {
        var onFind: (() -> Void)?
        var onDistractionFree: (() -> Void)?
        var onHighlightSelection: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rebuildMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func rebuildMonitor() {
            removeMonitor()
            guard window != nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      event.window === self.window else {
                    return event
                }

                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let characters = event.charactersIgnoringModifiers?.lowercased()

                if characters == "l", modifiers.isEmpty, !self.isTextInputActive {
                    self.onHighlightSelection?()
                    return nil
                }

                guard characters == "f" else {
                    return event
                }

                if modifiers == .command {
                    self.onFind?()
                    return nil
                }

                if modifiers == [.command, .option] {
                    self.onDistractionFree?()
                    return nil
                }

                return event
            }
        }

        private var isTextInputActive: Bool {
            guard let firstResponder = window?.firstResponder else {
                return false
            }
            return firstResponder is NSTextView || firstResponder is NSTextField
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private struct ToolbarFindControl: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    var activationID: Int

    @State private var localActivationID = 0

    var body: some View {
        Group {
            if isPresented {
                ToolbarSearchField(
                    text: $text,
                    isPresented: $isPresented,
                    activationID: activationID + localActivationID
                )
                .frame(width: 220, height: 30)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                Button {
                    showAndFocus()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .controlSize(.large)
                .help("Find")
            }
        }
        .onChange(of: activationID) { _, _ in
            showAndFocus()
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                localActivationID += 1
            }
        }
    }

    private func showAndFocus() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isPresented = true
        }
        localActivationID += 1
    }
}

struct ProjectWorkspaceView: View {
    @State private var project: HorizontalProject
    @Binding var document: HorizontalProjectDocument
    @Binding var visiblePanes: Set<HorizontalPane>
    @Binding var selectedNetIDs: Set<String>
    @Binding var highlightedNetIDs: Set<String>
    @Binding var selectedComponentIDs: Set<String>
    @Binding var highlightedComponentIDs: Set<String>

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var navigatorSelection: ProjectNavigatorSelection?
    @State private var schematicDisplayOptions = SchematicDisplayOptions()
    @State private var boardDisplayOptions = BoardDisplayOptions()
    @State private var windowSize: HorizontalWindowSize?
    @State private var schematicViewport = CanvasViewport()
    @State private var boardViewport = CanvasViewport()
    @State private var threeDCameraState: HorizontalSceneCameraState?
    @State private var paneSizeFractions: [HorizontalPane: CGFloat] = [:]
    @State private var selectionToolSettings = HorizontalSelectionToolSettings()
    @State private var navigatorSearchText = ""
    @State private var findIsPresented = false
    @State private var findActivationID = 0
    @State private var fallbackUndoManager = UndoManager()
    @State private var selectionDetailsByPane = [HorizontalPane: HorizontalSelectionDetailState]()
    @State private var selectionPropertyChangeCommands = [HorizontalPane: HorizontalSelectionPropertyChangeCommand]()
    @State private var schematicNetSegmentSelection: HorizontalNetSegmentSelectionSidebarState?
    @State private var schematicNetSegmentSelectionCommand: HorizontalNetSegmentSelectionCommand?
    @State private var schematicDrawingToolCommand: HorizontalDrawingToolCommand?
    @State private var schematicDrawNetLineCommand: HorizontalDrawNetLineCommand?
    @State private var boardDrawingToolCommand: HorizontalDrawingToolCommand?
    @State private var boardDrawTrackCommand: HorizontalDrawTrackCommand?
    @StateObject private var boardToolSettings = HorizontalBoardToolSettings()
    @State private var boardToolSettingsPresented = false
    @State private var boardDrawingLayer = HorizontalBoardLayers.topCopper
    /// Set while a single layer is soloed (the working layer's number pressed a
    /// second time). Nil is the normal, un-soloed state.
    @State private var soloedBoardLayer: Int?
    @State private var pendingPartPlacement: HorizontalPartPlacementRequest?
    @State private var canvasCommandActionsByPane = [HorizontalPane: HorizontalCanvasCommandActions]()
    @State private var activeCanvasCommandPane: HorizontalPane?
    @State private var rightSidebarPane: HorizontalWorkspaceRightSidebar?
    @State private var rulesResultsState: HorizontalBoardRulesResultState?
    @State private var exportSettings: HorizontalExportSettings
    @State private var exportStatus: HorizontalExportStatus?
    @State private var isExporting = false
    @State private var didRestoreFileViewState = false
    @State private var fileViewStateSaveTask: Task<Void, Never>?
    @State private var boardSyncRevision = 0
    /// Gates the plane-pour indicator. Separate from `planePourProgress` because
    /// that is nil both when idle and when a pour is deliberately indeterminate.
    @State private var isPouringPlanes = false
    @State private var planePourProgress: Double?
    /// What each plane was last poured from, so a re-pour only redoes the planes
    /// an edit could have changed.
    @State private var planePourCache = HorizontalPlanePourCache()
    /// The board changed in a way that invalidates the current fills. Set from
    /// the edit funnel rather than recomputed while rendering, so the (whole
    /// board) fingerprint is taken once per edit instead of once per frame.
    @State private var planesNeedUpdate = false
    @State private var panesWithPointerInsideToolbar = Set<HorizontalPane>()
    /// True while the pointer is over the trailing inspector sidebar, which is
    /// overlaid on top of the canvas in a `ZStack`. The canvas reads board input
    /// through a window-level event monitor that only gates on canvas bounds, so
    /// without this a click on a sidebar control lands as an empty-space canvas
    /// click and clears the selection before the control's edit even runs. Feeding
    /// this into the canvas's `ignoresCanvasMouseEvents` makes the canvas pass
    /// sidebar clicks straight through to the controls (mirrors the in-canvas
    /// overlay popover's `pointerInsideSelectionPopover`).
    @State private var pointerInsideRightSidebar = false
    @State private var isDistractionFree = false
    @State private var isWindowToolbarHidden = false
    @State private var distractionFreeRestoreState: DistractionFreeRestoreState?
    @State private var boardRulesWindowController: HorizontalBoardRulesWindowController?
    @StateObject private var boardUndoTarget = HorizontalUndoTarget<HorizontalBoard>()
    @Environment(\.undoManager) private var documentUndoManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(
        project: HorizontalProject,
        document: Binding<HorizontalProjectDocument>,
        visiblePanes: Binding<Set<HorizontalPane>>,
        selectedNetIDs: Binding<Set<String>>,
        highlightedNetIDs: Binding<Set<String>>,
        selectedComponentIDs: Binding<Set<String>>,
        highlightedComponentIDs: Binding<Set<String>>
    ) {
        let fileViewState = HorizontalFileViewStateStore.shared.load(for: project.url)
        _project = State(initialValue: project)
        _document = document
        _visiblePanes = visiblePanes
        _selectedNetIDs = selectedNetIDs
        _highlightedNetIDs = highlightedNetIDs
        _selectedComponentIDs = selectedComponentIDs
        _highlightedComponentIDs = highlightedComponentIDs
        _columnVisibility = State(initialValue: Self.initialColumnVisibility(fileViewState: fileViewState, project: project))
        _schematicDisplayOptions = State(initialValue: fileViewState?.schematicDisplayOptions ?? SchematicDisplayOptions())
        _boardDisplayOptions = State(initialValue: fileViewState?.boardDisplayOptions ?? BoardDisplayOptions())
        _windowSize = State(initialValue: fileViewState?.windowSize)
        _schematicViewport = State(initialValue: fileViewState?.schematicViewport ?? CanvasViewport())
        _boardViewport = State(initialValue: fileViewState?.boardViewport ?? CanvasViewport())
        _threeDCameraState = State(initialValue: fileViewState?.threeDCameraState)
        _paneSizeFractions = State(initialValue: (fileViewState?.paneSizeFractions ?? [:]).mapValues { CGFloat($0) })
        // Falls back to the shared default (closed) rather than a literal, so
        // the "no stored view state" case can't drift from
        // HorizontalFileViewState.default.
        _rightSidebarPane = State(
            initialValue: fileViewState?.rightSidebarPane
                ?? ((fileViewState?.showsSelectionSidebar ?? HorizontalFileViewState.default.showsSelectionSidebar)
                    ? .selection
                    : nil)
        )
        _exportSettings = State(initialValue: HorizontalExportSettings(project: project))
    }

    /// First-open sidebar state: a remembered choice wins; otherwise the
    /// navigator only earns its column when there is more than one sheet to
    /// navigate — a fresh single-sheet project opens on the canvases alone.
    private static func initialColumnVisibility(
        fileViewState: HorizontalFileViewState?,
        project: HorizontalProject
    ) -> NavigationSplitViewVisibility {
        if let fileViewState {
            return fileViewState.showsNavigatorSidebar ? .all : .detailOnly
        }
        let sheetCount = project.schematics.reduce(0) { $0 + $1.schematic.sheets.count }
        return sheetCount > 1 ? .all : .detailOnly
    }

    private var activeHighlightedNetIDs: Set<String> {
        highlightedNetIDs
    }

    private var activeHighlightedComponentIDs: Set<String> {
        highlightedComponentIDs
    }

    private var activeUndoManager: UndoManager? {
        documentUndoManager ?? fallbackUndoManager
    }

    private var isReadOnly: Bool {
        appearanceSettings.isReadOnlyOperationEnabled
    }

    private var sidebarTheme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    private var documentViewActions: HorizontalDocumentViewActions {
        HorizontalDocumentViewActions(
            canShowTopSchematic: defaultNavigatorSelection != nil,
            canShowBoard: project.board != nil,
            canShowDiagnostics: !project.diagnostics.isEmpty,
            showPackage: showPackageView,
            showTopSchematic: showTopSchematicView,
            showBoard: showBoardView,
            showDiagnostics: showDiagnosticsView,
            revealPackageInFinder: { revealInFinder(project.url) },
            openProjectFile: { openURL(project.projectFileURL) },
            copyPackagePath: { copyToPasteboard(project.url.path) },
            copyProjectFilePath: { copyToPasteboard(project.projectFileURL.path) }
        )
    }

    var body: some View {
        workspaceContent
            .focusedSceneValue(\.horizonBoardDisplayOptions, $boardDisplayOptions)
            .focusedSceneValue(\.horizonBoardAvailable, project.board != nil)
            .focusedSceneValue(\.horizonReadOnlyOperation, isReadOnly)
            .focusedSceneValue(\.horizonSchematicDisplayOptions, $schematicDisplayOptions)
            .focusedSceneValue(\.horizonSchematicAvailable, selectedSchematicAvailable)
            .focusedSceneValue(\.horizonDocumentViewActions, documentViewActions)
            .focusedSceneValue(\.horizonCanvasCommandActions, activeCanvasCommandActions)
            .focusedSceneValue(\.horizonFindAction, activateFind)
            .focusedSceneValue(\.horizonDistractionFreeMode, $isDistractionFree)
            .focusedSceneValue(\.horizonWindowToolbarHidden, $isWindowToolbarHidden)
            .focusedSceneValue(\.horizonToggleRightSidebarAction, { toggleRightSidebar(.selection) })
            .focusedSceneValue(\.horizonUpdateAllPlanesAction, updateAllBoardPlanes)
            .focusedSceneValue(\.horizonClearAllPlanesAction, clearAllBoardPlanes)
            .focusedSceneValue(\.horizonBoardRulesAction, showBoardRulesWindow)
            .background(WorkspaceKeyCommandMonitor(
                onFind: activateFind,
                onDistractionFree: toggleDistractionFreeMode,
                onHighlightSelection: highlightSelectedNet
            ))
            .background(WindowSizeObserver(savedSize: windowSize, onSizeChange: updateWindowSize))
            .onAppear(perform: appear)
            .onChange(of: navigatorSelection) { _, selection in
                syncPanesForSelection(selection)
            }
            .onChange(of: visiblePanes) { _, panes in
                clearSelectionDetailsForHiddenPanes(panes)
                saveFileViewState()
            }
            .onChange(of: columnVisibility) { _, _ in
                saveFileViewState()
            }
            .onChange(of: rightSidebarPane) { _, _ in
                saveFileViewState()
            }
            .onChange(of: isDistractionFree) { _, isEnabled in
                updateDistractionFreeMode(isEnabled)
            }
            .onChange(of: project.board?.uuid) { _, _ in
                exportSettings.refreshBoardLayers(from: project.board)
            }
            .onChange(of: schematicDisplayOptions) { _, _ in
                scheduleFileViewStateSave()
            }
            .onChange(of: boardDisplayOptions) { _, _ in
                scheduleFileViewStateSave()
            }
            .onChange(of: windowSize) { _, _ in
                scheduleFileViewStateSave()
            }
            .onChange(of: schematicViewport) { _, _ in
                scheduleFileViewStateSave()
            }
            .onChange(of: boardViewport) { _, _ in
                scheduleFileViewStateSave()
            }
            .onChange(of: threeDCameraState) { _, _ in
                scheduleFileViewStateSave()
            }
            .onChange(of: paneSizeFractions) { _, _ in
                scheduleFileViewStateSave()
            }
            .onDisappear {
                fileViewStateSaveTask?.cancel()
                fileViewStateSaveTask = nil
                saveFileViewState()
            }
    }

    private var workspaceContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectNavigatorView(
                project: project,
                selection: $navigatorSelection,
                searchText: $navigatorSearchText,
                allowsSheetEditing: !isReadOnly,
                onRenameSheet: { schematicURL, sheetID, name in
                    renameSheet(sheetID: sheetID, to: name, schematicURL: schematicURL)
                },
                onReorderSheets: { schematicURL, orderedIDs in
                    reorderSheets(orderedIDs, schematicURL: schematicURL)
                }
            )
            // Without an explicit column width the sidebar is compressible to
            // nothing: the detail column below demanded the window's entire
            // minimum width, so at small sizes AppKit squeezed the sidebar
            // narrower than its rows and clipped their text at BOTH edges
            // ("Schematic" rendering as "ematic").
            .navigationSplitViewColumnWidth(min: 110, ideal: 130, max: 420)
        } detail: {
            workspaceDetail
        }
        .toolbar {
            workspaceToolbar
        }
        .toolbar(isWindowToolbarHidden || isDistractionFree ? .hidden : .visible, for: .windowToolbar)
    }

    /// Canvas content runs up underneath the toolbar only when the toolbar is
    /// transparent — that is what there is to see through it. With the standard
    /// toolbar the canvas stops below the title bar, so the bar keeps its own
    /// background instead of having board artwork painted over it.
    private var extendsUnderToolbar: Bool {
        appearanceSettings.isToolbarTransparent
    }

    /// The overlays inside each pane (tool rails, info buttons) pad themselves
    /// down by `top` to clear a floating toolbar. Once the canvas no longer
    /// extends under the toolbar, that clearance is already in the layout and
    /// padding again would push them a toolbar's height too low.
    private func canvasSafeAreaInsets(_ insets: EdgeInsets) -> EdgeInsets {
        guard !extendsUnderToolbar else {
            return insets
        }
        return EdgeInsets(top: 0, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
    }

    private var workspaceDetail: some View {
        GeometryReader { proxy in
            // The right sidebar is a real column: opening it pushes the pane
            // split narrower so the rightmost canvas stays fully visible,
            // rather than sliding over and obscuring it.
            let canvasInsets = canvasSafeAreaInsets(proxy.safeAreaInsets)

            HStack(spacing: 0) {
                splitContent(safeAreaInsets: canvasInsets)
                    .ignoresSafeArea(.container, edges: extendsUnderToolbar ? [.top, .leading] : [.leading])
                    .frame(maxWidth: .infinity)

                if let rightSidebarPane {
                    rightSidebarView(rightSidebarPane, safeAreaInsets: canvasInsets)
                        .frame(width: 340)
                        .ignoresSafeArea(
                            .container,
                            edges: extendsUnderToolbar ? [.top, .bottom, .trailing] : [.bottom, .trailing]
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        // Tell the canvas to pass mouse events through to the
                        // sidebar's controls instead of treating them as
                        // empty-space canvas clicks (which deselect) — still
                        // needed mid-transition, while the sidebar slides
                        // across the canvas.
                        .onHover { pointerInsideRightSidebar = $0 }
                }
            }
            .animation(.snappy(duration: 0.18), value: rightSidebarPane)
        }
        // Must leave room for the navigator sidebar inside the window minimum
        // (980). This was also 980, so the detail alone claimed the whole
        // window and the navigator got whatever was left — nothing. The right
        // sidebar IS part of this: with it open the pane split compresses to
        // what remains, and the split view divides evenly once panes go below
        // their preferred minimum.
        .frame(minWidth: 660)
    }

    @ViewBuilder
    private func rightSidebarView(_ pane: HorizontalWorkspaceRightSidebar, safeAreaInsets: EdgeInsets) -> some View {
        switch pane {
        case .selection:
            SelectionSidebarView(
                sections: selectionSidebarSections,
                netSegmentSelection: schematicNetSegmentSelection,
                safeAreaInsets: safeAreaInsets,
                foregroundColor: .primary,
                backgroundColor: sidebarTheme.overlayBackground,
                isReadOnly: isReadOnly,
                onChange: applySelectionPropertyChange,
                onNetSegmentSelectionCommand: { command in
                    schematicNetSegmentSelectionCommand = command
                }
            )
        case .export:
            HorizontalExportSidebarView(
                project: project,
                settings: $exportSettings,
                status: exportStatus,
                isExporting: isExporting,
                safeAreaInsets: safeAreaInsets,
                onExport: exportSection,
                onExportAll: exportAllEnabledSections
            )
        case .rulesResults:
            HorizontalRulesResultsSidebarView(
                result: rulesResultsState,
                safeAreaInsets: safeAreaInsets
            )
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        // One ToolbarItem so every control shares a single glass island, the
        // way the iPad toolbar does — separate items (and ControlGroups) each
        // rendered their own capsule, which read as scattered buttons.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 14) {
                readOnlyLockButton

                paneSelector

                ToolbarFindControl(
                    text: $navigatorSearchText,
                    isPresented: $findIsPresented,
                    activationID: findActivationID
                )

                Button {
                    toggleRightSidebar(.selection)
                } label: {
                    Label(selectionSidebarToggleTitle, systemImage: "sidebar.trailing")
                }
                .help(selectionSidebarToggleTitle)
                .accessibilityLabel(selectionSidebarToggleTitle)

                Button {
                    toggleRightSidebar(.export)
                } label: {
                    Label(exportSidebarToggleTitle, systemImage: "square.and.arrow.up")
                }
                .help(exportSidebarToggleTitle)
                .accessibilityLabel(exportSidebarToggleTitle)

                Button {
                    toggleRightSidebar(.rulesResults)
                } label: {
                    Label(rulesResultsSidebarToggleTitle, systemImage: "checklist.checked")
                }
                .help(rulesResultsSidebarToggleTitle)
                .accessibilityLabel(rulesResultsSidebarToggleTitle)
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
        }
    }

    /// The read-only lock: shows the document's effective read-only state and
    /// toggles the preference (the same one Settings offers). Release builds
    /// force read-only with no preference to flip, so there the lock is a
    /// disabled indicator rather than a control. Unlocking re-runs the outer
    /// view's project load (via its isReadOnlyOperationEnabled onChange) so a
    /// document opened read-only gains the writable archive it skipped.
    private var readOnlyLockButton: some View {
        Button {
            appearanceSettings.readOnlyOperationBinding().wrappedValue = !isReadOnly
        } label: {
            Label(
                isReadOnly ? "Read-Only" : "Editable",
                systemImage: isReadOnly ? "lock.fill" : "lock.open"
            )
        }
        .disabled(HorizontalOperationDefaults.isReadOnlyOperationForced)
        .help(
            HorizontalOperationDefaults.isReadOnlyOperationForced
                ? "This build of Horizontal cannot modify project files."
                : (isReadOnly ? "Read-only — click to allow editing" : "Editable — click to make read-only")
        )
        .accessibilityLabel(isReadOnly ? "Read-only. Click to allow editing." : "Editable. Click to make read-only.")
    }

    @ViewBuilder
    private var paneSelector: some View {
        ForEach(HorizontalPane.allCases) { pane in
            Toggle(isOn: paneVisibilityBinding(for: pane)) {
                Label(pane.title, systemImage: pane.symbolName)
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .controlSize(.large)
            .disabled(visiblePanes.count == 1 && visiblePanes.contains(pane))
            .help(pane.title)
        }
    }

    private func paneVisibilityBinding(for pane: HorizontalPane) -> Binding<Bool> {
        Binding {
            visiblePanes.contains(pane)
        } set: { isVisible in
            if isVisible {
                visiblePanes.insert(pane)
            } else if visiblePanes.count > 1 {
                visiblePanes.remove(pane)
            }
        }
    }

    private var selectionSidebarToggleTitle: String {
        rightSidebarPane == .selection ? "Hide Selection Sidebar" : "Show Selection Sidebar"
    }

    private var exportSidebarToggleTitle: String {
        rightSidebarPane == .export ? "Hide Export Sidebar" : "Show Export Sidebar"
    }

    private var rulesResultsSidebarToggleTitle: String {
        rightSidebarPane == .rulesResults ? "Hide Rules Results Sidebar" : "Show Rules Results Sidebar"
    }

    private func toggleRightSidebar(_ pane: HorizontalWorkspaceRightSidebar) {
        rightSidebarPane = rightSidebarPane == pane ? nil : pane
    }

    private func toggleDistractionFreeMode() {
        isDistractionFree.toggle()
    }

    private func updateDistractionFreeMode(_ isEnabled: Bool) {
        if isEnabled {
            if distractionFreeRestoreState == nil {
                distractionFreeRestoreState = DistractionFreeRestoreState(
                    columnVisibility: columnVisibility,
                    rightSidebarPane: rightSidebarPane
                )
            }

            withAnimation(.snappy(duration: 0.18)) {
                columnVisibility = .detailOnly
                rightSidebarPane = nil
            }
            panesWithPointerInsideToolbar.removeAll()
        } else if let restoreState = distractionFreeRestoreState {
            withAnimation(.snappy(duration: 0.18)) {
                columnVisibility = restoreState.columnVisibility
                rightSidebarPane = restoreState.rightSidebarPane
            }
            distractionFreeRestoreState = nil
        }
    }

    private func setPointerInsideToolbar(_ inside: Bool, for pane: HorizontalPane) {
        if inside {
            panesWithPointerInsideToolbar.insert(pane)
        } else {
            panesWithPointerInsideToolbar.remove(pane)
        }
    }

    private func appear() {
        restoreFileViewStateIfNeeded()
        if navigatorSelection == nil {
            navigatorSelection = defaultNavigatorSelection
        }
    }

    private func restoreFileViewStateIfNeeded() {
        guard !didRestoreFileViewState else {
            return
        }

        if let savedPanes = HorizontalFileViewStateStore.shared.load(for: project.url)?.visiblePanes,
           !savedPanes.isEmpty {
            visiblePanes = savedPanes
        } else {
            visiblePanes = HorizontalFileViewState.default.visiblePanes
        }
        didRestoreFileViewState = true
    }

    private func saveFileViewState() {
        guard didRestoreFileViewState else {
            return
        }

        let savedColumnVisibility = isDistractionFree
            ? (distractionFreeRestoreState?.columnVisibility ?? columnVisibility)
            : columnVisibility
        let savedRightSidebarPane = isDistractionFree
            ? distractionFreeRestoreState?.rightSidebarPane
            : rightSidebarPane

        let state = HorizontalFileViewState(
            visiblePanes: visiblePanes,
            showsNavigatorSidebar: savedColumnVisibility != .detailOnly,
            showsSelectionSidebar: savedRightSidebarPane == .selection,
            rightSidebarPane: savedRightSidebarPane,
            windowSize: windowSize,
            schematicViewport: schematicViewport,
            boardViewport: boardViewport,
            threeDCameraState: threeDCameraState,
            schematicDisplayOptions: schematicDisplayOptions,
            boardDisplayOptions: boardDisplayOptions,
            paneSizeFractions: paneSizeFractions.mapValues(Double.init)
        )
        HorizontalFileViewStateStore.shared.save(state, for: project.url)
    }

    private func scheduleFileViewStateSave() {
        guard didRestoreFileViewState else {
            return
        }

        fileViewStateSaveTask?.cancel()
        fileViewStateSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }
            saveFileViewState()
            fileViewStateSaveTask = nil
        }
    }

    private func updateWindowSize(_ size: HorizontalWindowSize) {
        guard size.isValid, size != windowSize else {
            return
        }

        windowSize = size
    }

    private func activateFind() {
        findIsPresented = true
        findActivationID += 1
    }

    private func exportSection(_ section: HorizontalExportSection) {
        Task { @MainActor in
            await prepareExportFolderAccess()
            await runExport(sections: [section])
        }
    }

    private func exportAllEnabledSections() {
        Task { @MainActor in
            await prepareExportFolderAccess()
            await runExport(sections: HorizontalExportSection.allCases.filter { exportSettings.isEnabled($0) })
        }
    }

    private func runExport(sections: [HorizontalExportSection]) async {
        guard !sections.isEmpty, !isExporting else {
            return
        }
        // Snapshot the value-type inputs on the main actor, then run the (synchronous,
        // CPU + file-IO heavy) export off-main so the spinner keeps animating. The
        // security-scoped folder access granted above is process-wide, so the
        // background write still has it.
        let settings = exportSettings
        let exportProject = project
        let schematicPalette = appearanceSettings.palette(for: .schematic, mode: .light)
        let boardPalette = appearanceSettings.palette(for: .board, mode: .light)

        isExporting = true
        exportStatus = nil
        let result = await Task.detached(priority: .userInitiated) {
            HorizontalExportBackend.export(
                sections: sections,
                settings: settings,
                project: exportProject,
                schematicPDFPalette: schematicPalette,
                boardPDFPalette: boardPalette
            )
        }.value
        isExporting = false
        exportStatus = result
    }

    /// Sandbox: exports write outside the opened document (the default target
    /// is a sibling "<Name> Export" folder, and custom targets may be absolute
    /// paths), so no powerbox grant covers them. Restore or prompt for access
    /// to the target's folder before the backend writes.
    private func prepareExportFolderAccess() async {
        guard let target = try? HorizontalExportSettings.exportTargetDirectory(
            for: project,
            requestedPath: exportSettings.targetDirectory
        ) else {
            return
        }
        await HorizontalFolderAccessStore.prepareExportAccess(to: target)
    }

    @ViewBuilder
    private func splitContent(safeAreaInsets: EdgeInsets) -> some View {
        let panes = HorizontalPane.allCases.filter { visiblePanes.contains($0) }

        ResizablePaneSplitView(panes: panes, sizeFractions: $paneSizeFractions) { pane, isLeadingPane in
            paneView(
                pane,
                fitSafeAreaInsets: paneFitSafeAreaInsets(
                    safeAreaInsets,
                    isLeadingPane: isLeadingPane,
                    isTrailingPane: panes.last == pane
                )
            )
        }
    }

    @ViewBuilder
    private func paneView(_ pane: HorizontalPane, fitSafeAreaInsets: EdgeInsets) -> some View {
        switch pane {
        case .parts:
            ViewerPane(title: "Parts", subtitle: project.poolDirectory ?? "Project Pool") {
                HorizontalPartBrowserView(
                    parts: project.poolParts,
                    poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) },
                    safeAreaInsets: fitSafeAreaInsets,
                    isReadOnly: isReadOnly,
                    onPlacePart: beginPartPlacement
                )
            }
        case .library:
            ViewerPane(title: "Library", subtitle: "Pools") {
                HorizontalPoolBrowserView(
                    root: .project(poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }),
                    safeAreaInsets: fitSafeAreaInsets
                )
            }
        case .schematic:
            ViewerPane(title: "Schematic", subtitle: selectedSchematic?.subtitle ?? "Unavailable") {
                PaneOverlayContainer(
                    pane: .schematic,
                    safeAreaInsets: fitSafeAreaInsets,
                    infoEnabled: selectedSchematic != nil,
                    showsTools: !isDistractionFree && !isWindowToolbarHidden,
                    isKeyboardFocused: activeCanvasCommandPane == .schematic,
                    onToolbarHover: { setPointerInsideToolbar($0, for: .schematic) }
                ) {
                    if let selectedSchematic {
                        WindowAttachedCanvasHost(
                            loadID: "schematic-\(selectedSchematic.url.path)-\(selectedSchematic.sheet.id)",
                            backgroundColor: appearanceSettings.palette(for: .schematic, colorScheme: colorScheme).background,
                            loadingLabel: "Loading Schematic..."
                        ) {
                            SchematicCanvasView(
                                sheet: selectedSchematic.sheet,
                                allSheets: selectedSchematic.sheets,
                                viewport: $schematicViewport,
                                displayOptions: schematicDisplayOptions,
                                fitSafeAreaInsets: fitSafeAreaInsets,
                                highlightedNetIDs: activeHighlightedNetIDs,
                                highlightedComponentIDs: activeHighlightedComponentIDs,
                                undoManager: activeUndoManager,
                                selectionToolSettings: selectionToolSettings,
                                isReadOnly: isReadOnly,
                                ignoresCanvasMouseEvents: panesWithPointerInsideToolbar.contains(.schematic) || pointerInsideRightSidebar,
                                onSelectedNetChange: selectNet,
                                onSelectedComponentChange: selectComponents,
                                onHighlightNetCommand: highlightSelectedNet,
                                onHighlightComponentCommand: highlightSelectedComponents,
                                onSheetChange: { sheet in
                                    applyEditedSchematicSheet(sheet, schematicURL: selectedSchematic.url)
                                },
                                onNetClassChange: { netID, netClassID in
                                    applyEditedNetClass(netID: netID, netClassID: netClassID, selectedSchematic: selectedSchematic)
                                },
                                onComponentRefdesChange: { componentID, refdes in
                                    applyEditedComponentRefdes(
                                        componentID: componentID,
                                        refdes: refdes,
                                        selectedSchematic: selectedSchematic
                                    )
                                },
                                onComponentPinNamesChange: { componentID, pins in
                                    applyEditedComponentPinNames(
                                        componentID: componentID,
                                        pins: pins,
                                        selectedSchematic: selectedSchematic
                                    )
                                },
                                onSelectionDetailsChange: { details in
                                    setSelectionDetails(details, for: .schematic)
                                },
                                onNetSegmentSelectionChange: setSchematicNetSegmentSelection,
                                onCanvasCommandActionsChange: { actions in
                                    setCanvasCommandActions(actions, for: .schematic)
                                },
                                hasKeyboardFocus: activeCanvasCommandPane == .schematic,
                                onRequestKeyboardFocus: { activeCanvasCommandPane = .schematic },
                                selectionPropertyChangeCommand: selectionPropertyChangeCommands[.schematic],
                                netSegmentSelectionCommand: schematicNetSegmentSelectionCommand,
                                drawingToolCommand: schematicDrawingToolCommand,
                                drawNetLineCommand: schematicDrawNetLineCommand,
                                placePartRequest: pendingPartPlacement,
                                poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
                            )
                        }
                    } else {
                        MissingPaneView(message: "No schematic file was loaded.")
                    }
                } info: {
                    if let summary = selectedSchematic.map(schematicInfoSummary) {
                        PaneInformationPanel(
                            summary: summary,
                            projectMetadataRows: projectMetaRows,
                            isProjectMetadataEditable: !isReadOnly,
                            onProjectMetadataChange: applyEditedProjectMetadata
                        )
                    }
                } layers: {
                    SchematicLayerControls(displayOptions: $schematicDisplayOptions)
                } grid: {
                    if selectedSchematic != nil {
                        GridControlsPanel(
                            title: "Schematic Grid",
                            grid: .constant(.schematicDefault),
                            isEditable: false
                        )
                    }
                } tools: {
                    SelectionToolButton(settings: $selectionToolSettings)
                    DrawingToolButtonGroup { primitive in
                        schematicDrawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                    }
                    .disabled(isReadOnly)
                    DrawNetLineToolButton {
                        schematicDrawNetLineCommand = HorizontalDrawNetLineCommand()
                    }
                    .disabled(isReadOnly || selectedSchematic == nil)
                    AddTextToolButton {
                        canvasCommandActionsByPane[.schematic]?.dispatch(.addText)
                    }
                    .disabled(isReadOnly || selectedSchematic == nil)
                    if let selectedSchematic {
                        NetClassToolButton(
                            netClasses: schematicNetClassesBinding(for: selectedSchematic),
                            usedNetClassIDs: usedNetClassIDs(for: selectedSchematic)
                        )
                        .disabled(isReadOnly)
                    }
                }
            }
        case .board:
            ViewerPane(title: "Board", subtitle: project.board?.name ?? "Unavailable") {
                PaneOverlayContainer(
                    pane: .board,
                    safeAreaInsets: fitSafeAreaInsets,
                    infoEnabled: project.board != nil,
                    showsTools: !isDistractionFree && !isWindowToolbarHidden,
                    isKeyboardFocused: activeCanvasCommandPane == .board,
                    onToolbarHover: { setPointerInsideToolbar($0, for: .board) }
                ) {
                    if let board = project.board {
                        // Identity only, deliberately WITHOUT the sync revision:
                        // a re-pour or any other external board change must not
                        // tear the canvas down and show the loading spinner
                        // again. The canvas adopts those in place, via
                        // `syncRevision` below.
                        let boardLoadID = "board-\(board.uuid)"
                        BoardLoadingHost(loadID: boardLoadID, backgroundColor: sidebarTheme.background) {
                            BoardCanvasView(
                                board: board,
                                netClasses: selectedSchematic?.sheet.netClasses ?? [],
                                viewport: $boardViewport,
                                displayOptions: boardCanvasDisplayOptions,
                                fitSafeAreaInsets: fitSafeAreaInsets,
                                highlightedNetIDs: activeHighlightedNetIDs,
                                highlightedComponentIDs: activeHighlightedComponentIDs,
                                undoManager: activeUndoManager,
                                selectionToolSettings: selectionToolSettings,
                                isReadOnly: isReadOnly,
                                ignoresCanvasMouseEvents: panesWithPointerInsideToolbar.contains(.board) || pointerInsideRightSidebar,
                                onSelectedNetChange: selectNet,
                                onSelectedComponentChange: selectComponents,
                                onHighlightNetCommand: highlightSelectedNet,
                                onHighlightComponentCommand: highlightSelectedComponents,
                                onBoardChange: { board in
                                    applyEditedBoard(board)
                                },
                                onPlaneEdit: { board, actionName in
                                    applyBoardPlaneEdit(board, actionName: actionName)
                                },
                                onNetClassChange: { netID, netClassID in
                                    if let selectedSchematic {
                                        applyEditedNetClass(
                                            netID: netID,
                                            netClassID: netClassID,
                                            selectedSchematic: selectedSchematic
                                        )
                                    }
                                },
                                onComponentRefdesChange: { componentID, refdes in
                                    if let selectedSchematic {
                                        applyEditedComponentRefdes(
                                            componentID: componentID,
                                            refdes: refdes,
                                            selectedSchematic: selectedSchematic
                                        )
                                    }
                                },
                                onSelectionDetailsChange: { details in
                                    setSelectionDetails(details, for: .board)
                                },
                                onCanvasCommandActionsChange: { actions in
                                    setCanvasCommandActions(actions, for: .board)
                                },
                                hasKeyboardFocus: activeCanvasCommandPane == .board,
                                onRequestKeyboardFocus: { activeCanvasCommandPane = .board },
                                selectionPropertyChangeCommand: selectionPropertyChangeCommands[.board],
                                drawingToolCommand: boardDrawingToolCommand,
                                drawTrackCommand: boardDrawTrackCommand,
                                onShowToolSettings: { boardToolSettingsPresented = true },
                                toolSettings: boardToolSettings,
                                drawingLayer: boardDrawingLayer,
                                syncRevision: boardSyncRevision,
                                onSelectDrawingLayer: { selectOrSoloBoardLayer($0) },
                                onSelectBoardLayerView: { applyBoardLayerViewPreset($0) },
                                poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
                            )
                            .id(boardLoadID)
                        }
                    } else {
                        MissingPaneView(message: "No board file was loaded.")
                    }
                } info: {
                    if let summary = project.board.map({ boardInfoSummary($0, subtitle: $0.url.lastPathComponent) }) {
                        PaneInformationPanel(summary: summary)
                    }
                } layers: {
                    BoardLayerControls(
                        board: project.board,
                        displayOptions: $boardDisplayOptions,
                        selectedLayer: $boardDrawingLayer,
                        includesThreeDControls: false
                    )
                } grid: {
                    if project.board != nil {
                        GridControlsPanel(title: "Board Grid", grid: boardGridBinding())
                    }
                } tools: {
                    BoardStackupToolButton(
                        board: project.board,
                        isReadOnly: isReadOnly,
                        onBoardChange: { board in
                            applyEditedBoard(board)
                        }
                    )
                    .disabled(project.board == nil)
                    BoardRulesToolButton(action: showBoardRulesWindow)
                        .disabled(project.board == nil)
                    BoardUpdatePlanesToolButton(
                        action: updateAllBoardPlanes,
                        isUpdating: isPouringPlanes,
                        progress: planePourProgress,
                        needsUpdate: planesNeedUpdate
                    )
                    .disabled(isReadOnly || project.board?.planes.isEmpty != false)
                    BoardSyncToolButton(action: syncBoardWithSchematicData)
                        .disabled(isReadOnly || project.board == nil)
                    SelectionToolButton(settings: $selectionToolSettings)
                    DrawTrackToolButton {
                        boardDrawTrackCommand = HorizontalDrawTrackCommand()
                    }
                    .disabled(isReadOnly || project.board == nil)
                    TrackSettingsToolButton(presented: $boardToolSettingsPresented)
                        .disabled(isReadOnly || project.board == nil)
                        .popover(isPresented: $boardToolSettingsPresented, arrowEdge: .bottom) {
                            HorizontalBoardToolSettingsView(
                                settings: boardToolSettings,
                                viaTemplate: project.board?.viaTemplate
                            )
                        }
                    DrawingToolButtonGroup(primitives: HorizontalDrawingPrimitive.allCases) { primitive in
                        boardDrawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                    }
                    .disabled(isReadOnly)
                    DrawPlaneToolButton {
                        canvasCommandActionsByPane[.board]?.dispatch(.drawPlane)
                    }
                    .disabled(isReadOnly || project.board == nil)
                    AddTextToolButton {
                        canvasCommandActionsByPane[.board]?.dispatch(.addText)
                    }
                    .disabled(isReadOnly || project.board == nil)
                }
            }
        case .threeD:
            ViewerPane(title: "3D Board", subtitle: project.board?.name ?? "Unavailable") {
                PaneOverlayContainer(
                    pane: .threeD,
                    safeAreaInsets: fitSafeAreaInsets,
                    showsTools: !isDistractionFree && !isWindowToolbarHidden,
                    showsInfoButton: false,
                    showsLayerButton: false,
                    showsGridButton: false,
                    onToolbarHover: { setPointerInsideToolbar($0, for: .threeD) }
                ) {
                    if let board = project.board {
                        BoardSceneView(
                            board: board,
                            displayOptions: boardDisplayOptions,
                            backgroundColor: appearanceSettings.boardSceneBackground,
                            copperColor: appearanceSettings.boardSceneCopper,
                            layerColors: appearanceSettings.boardSceneLayerColors,
                            materialColors: appearanceSettings.boardSceneMaterialColors,
                            ignoresSceneMouseEvents: panesWithPointerInsideToolbar.contains(.threeD),
                            cameraState: $threeDCameraState
                        )
                    } else {
                        MissingPaneView(message: "No board file was loaded.")
                    }
                } info: {
                    EmptyView()
                } layers: {
                    BoardLayerControls(
                        board: project.board,
                        displayOptions: $boardDisplayOptions,
                        selectedLayer: $boardDrawingLayer,
                        includesThreeDControls: true
                    )
                } grid: {
                    EmptyView()
                } tools: {
                    ThreeDViewPresetRailButtons(
                        board: project.board,
                        displayOptions: $boardDisplayOptions,
                        cameraState: $threeDCameraState
                    )
                    ThreeDViewControlsButton(
                        board: project.board,
                        displayOptions: $boardDisplayOptions,
                        cameraState: $threeDCameraState
                    )
                }
            }
        }
    }

    private func schematicInfoSummary(_ selectedSchematic: SelectedSchematic) -> NavigatorSelectionSummary {
        let sheet = selectedSchematic.sheet
        return NavigatorSelectionSummary(
            id: "pane-sheet-\(sheet.id)",
            title: sheet.name,
            subtitle: selectedSchematic.subtitle,
            url: selectedSchematic.url,
            rows: schematicInfoRows(for: sheet)
        )
    }

    private func boardInfoSummary(_ board: HorizontalBoard, subtitle: String) -> NavigatorSelectionSummary {
        NavigatorSelectionSummary(
            id: "board-\(subtitle)",
            title: board.name,
            subtitle: subtitle,
            url: board.url,
            rows: boardInfoRows(for: board)
        )
    }

    private func schematicInfoRows(for sheet: HorizontalSchematicSheet) -> [NavigatorSelectionDetail] {
        [
            workspaceDetail("Symbols", sheet.symbolCount.formatted()),
            workspaceDetail("Pins", sheet.symbolPinCount.formatted()),
            workspaceDetail("Nets", sheet.netLineCount.formatted()),
            workspaceDetail("Labels", sheet.netLabelCount.formatted()),
            workspaceDetail("Junctions", sheet.junctionCount.formatted()),
            workspaceDetail("Power Symbols", sheet.powerSymbolCount.formatted()),
            workspaceDetail("Block Symbols", sheet.blockSymbolCount.formatted()),
            workspaceDetail("Net Ties", sheet.netTieCount.formatted()),
            workspaceDetail("Bus Labels", sheet.busLabelCount.formatted()),
            workspaceDetail("Bus Rippers", sheet.busRipperCount.formatted()),
            workspaceDetail("Bus Ripper Length", horizonLengthString(sheet.totalBusRipperLength)),
            workspaceDetail("Drawing Lines", sheet.drawingLineCount.formatted()),
            workspaceDetail("Text", sheet.textCount.formatted()),
            workspaceDetail("Wire Length", horizonLengthString(sheet.totalNetLength)),
            workspaceDetail("Grid", gridSpacingString(sheet.grid))
        ]
    }

    private func boardInfoRows(for board: HorizontalBoard) -> [NavigatorSelectionDetail] {
        var rows = [
            workspaceDetail("Panels", board.boardPanels.count.formatted()),
            workspaceDetail("Packages", board.packages.count.formatted()),
            workspaceDetail("Tracks", board.tracks.count.formatted()),
            workspaceDetail("Net Ties", board.netTies.count.formatted()),
            workspaceDetail("Connections", (board.connectionLines.count + board.airwires.count).formatted()),
            workspaceDetail("Vias", board.vias.count.formatted()),
            workspaceDetail("Pads", board.packagePads.count.formatted()),
            workspaceDetail("Holes", board.drillCount.formatted())
        ]

        let packageArtworkCount = board.packagePolygons.count + board.packageLines.count + board.packageTexts.count
        if packageArtworkCount > 0 {
            rows.append(
                workspaceDetail(
                    "Package Artwork",
                    "\(board.packagePolygons.count.formatted()) poly / \(board.packageLines.count.formatted()) line / \(board.packageTexts.count.formatted()) text"
                )
            )
        }

        let unresolvedCount = unresolvedPackageCount(for: board)
        if unresolvedCount > 0 {
            rows.append(workspaceDetail("Unresolved Packages", unresolvedCount.formatted()))
        }
        if board.bottomPackageCount > 0 {
            rows.append(workspaceDetail("Package Sides", "\(board.topPackageCount.formatted()) top / \(board.bottomPackageCount.formatted()) bottom"))
        }
        if board.totalNetTieLength > 0 {
            rows.append(workspaceDetail("Net Tie Length", horizonLengthString(board.totalNetTieLength)))
        }
        if board.totalConnectionLength > 0 {
            rows.append(workspaceDetail("Connection Span", horizonLengthString(board.totalConnectionLength)))
        }
        if board.totalTrackLength > 0 {
            rows.append(workspaceDetail("Track Length", horizonLengthString(board.totalTrackLength)))
        }
        if board.topTrackLength > 0 || board.innerTrackLength > 0 || board.bottomTrackLength > 0 {
            rows.append(
                workspaceDetail(
                    "Track Sides",
                    "\(horizonLengthString(board.topTrackLength)) top / \(horizonLengthString(board.innerTrackLength)) inner / \(horizonLengthString(board.bottomTrackLength)) bottom"
                )
            )
        }
        if board.topPadCount > 0 || board.bottomPadCount > 0 {
            rows.append(workspaceDetail("Pad Sides", "\(board.topPadCount.formatted()) top / \(board.bottomPadCount.formatted()) bottom"))
        }
        if board.topPadArea > 0 || board.bottomPadArea > 0 {
            rows.append(workspaceDetail("Pad Area", "\(horizonAreaString(board.topPadArea)) top / \(horizonAreaString(board.bottomPadArea)) bottom"))
        }
        if board.drillCount > 0 {
            rows.append(workspaceDetail("Hole Sources", "\(board.holes.count.formatted()) board / \(board.viaHoles.count.formatted()) via / \(board.packageHoles.count.formatted()) pad"))
            rows.append(workspaceDetail("Hole Plating", "\(board.platedHoleCount.formatted()) plated / \(board.unplatedHoleCount.formatted()) unplated"))
        }
        if !board.physicalBounds.isEmpty {
            rows.append(workspaceDetail("Size", horizonSizeString(board.physicalBounds)))
            rows.append(workspaceDetail("Area", horizonAreaString(board.physicalBounds.width * board.physicalBounds.height)))
        }
        if board.copperLayerCount > 0 {
            rows.append(workspaceDetail("Copper Layers", board.copperLayerCount.formatted()))
        }
        if board.totalSubstrateThickness > 0 {
            rows.append(workspaceDetail("Thickness", horizonLengthString(board.totalSubstrateThickness)))
        }
        if let color = board.colors.solderMask {
            rows.append(workspaceDetail("Solder Mask", color.hexString))
        }
        if let color = board.colors.silkscreen {
            rows.append(workspaceDetail("Silkscreen", color.hexString))
        }
        if let color = board.colors.substrate {
            rows.append(workspaceDetail("Substrate", color.hexString))
        }
        rows.append(workspaceDetail("Grid", gridSpacingString(board.grid)))
        rows.append(contentsOf: board.stackupLayers.map {
            workspaceDetail("Stackup \(stackupLayerTitle($0.layer))", stackupLayerDetail($0))
        })
        rows.append(workspaceDetail("Planes", board.planes.count.formatted()))
        if board.planeFragmentCount > 0 {
            rows.append(workspaceDetail("Plane Geometry", "\(board.planeFragmentCount.formatted()) fragments / \(horizonAreaString(board.totalPlaneArea))"))
        }
        rows.append(workspaceDetail("Keepouts", board.keepouts.count.formatted()))
        if board.totalKeepoutArea > 0 {
            rows.append(workspaceDetail("Keepout Area", horizonAreaString(board.totalKeepoutArea)))
        }
        rows.append(workspaceDetail("Dimensions", board.dimensions.count.formatted()))
        rows.append(workspaceDetail("Decals", board.decals.count.formatted()))
        rows.append(workspaceDetail("User Layers", board.userLayers.count.formatted()))
        rows.append(workspaceDetail("Board Artwork", "\(board.polygons.count.formatted()) poly / \(board.lines.count.formatted()) line / \(board.texts.count.formatted()) text"))
        rows.append(contentsOf: board.userLayers.map {
            workspaceDetail("User Layer \($0.name)", "Layer \($0.id) - \($0.type)")
        })
        rows.append(contentsOf: board.boardPanels.map {
            workspaceDetail("Panel \($0.boardName)", panelDetail($0))
        })

        return rows
    }

    private func unresolvedPackageCount(for board: HorizontalBoard) -> Int {
        let geometryIDs = board.packagePads.map(\.id)
            + board.packagePolygons.map(\.id)
            + board.packageLines.map(\.id)

        return board.packages.filter { package in
            let normalizedPackageID = normalizedID(package.id)
            return !geometryIDs.contains {
                geometryBelongsToPackage($0, normalizedPackageID: normalizedPackageID)
            }
        }.count
    }

    private func geometryBelongsToPackage(_ geometryID: String, normalizedPackageID: String) -> Bool {
        let normalizedGeometryID = normalizedID(geometryID)
        return normalizedGeometryID == normalizedPackageID
            || normalizedGeometryID.hasPrefix("\(normalizedPackageID)/")
    }

    private func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    private func stackupLayerTitle(_ layer: Int) -> String {
        HorizontalBoardLayers.name(for: layer)
    }

    private func stackupLayerDetail(_ layer: HorizontalBoardStackupLayer) -> String {
        let copper = horizonLengthString(layer.copperThickness)
        let substrate = horizonLengthString(layer.substrateThickness)
        return "Cu \(copper), substrate \(substrate)"
    }

    private func panelDetail(_ panel: HorizontalBoardPanel) -> String {
        let filename = URL(fileURLWithPath: panel.projectFilename).lastPathComponent
        guard !panel.bounds.isEmpty else {
            return filename
        }

        return "\(filename) - \(horizonSizeString(panel.bounds))"
    }

    private func workspaceDetail(_ title: String, _ value: String) -> NavigatorSelectionDetail {
        NavigatorSelectionDetail(title: title, value: value)
    }

    private func paneFitSafeAreaInsets(_ safeAreaInsets: EdgeInsets, isLeadingPane: Bool, isTrailingPane: Bool) -> EdgeInsets {
        EdgeInsets(
            top: safeAreaInsets.top,
            leading: isLeadingPane ? safeAreaInsets.leading : 0,
            bottom: safeAreaInsets.bottom,
            trailing: isTrailingPane ? safeAreaInsets.trailing : 0
        )
    }

    private var selectionSidebarSections: [SelectionSidebarSection] {
        HorizontalPane.allCases.compactMap { pane in
            guard visiblePanes.contains(pane),
                  let state = selectionDetailsByPane[pane],
                  state.hasSelection else {
                return nil
            }
            return SelectionSidebarSection(pane: pane, state: state)
        }
    }

    private var activeCanvasCommandActions: HorizontalCanvasCommandActions? {
        let preferredPanes = [
            activeCanvasCommandPane,
            visiblePanes.contains(.schematic) ? .schematic : nil,
            visiblePanes.contains(.board) ? .board : nil
        ].compactMap { $0 }

        for pane in preferredPanes where visiblePanes.contains(pane) {
            if let actions = canvasCommandActionsByPane[pane] {
                return actions
            }
        }
        return nil
    }

    private func setSelectionDetails(_ details: HorizontalSelectionDetailState, for pane: HorizontalPane) {
        var selectionDetails = details
        selectionDetails.hovered = nil

        if selectionDetails.hasSelection {
            selectionDetailsByPane[pane] = selectionDetails
            activeCanvasCommandPane = pane
        } else {
            selectionDetailsByPane.removeValue(forKey: pane)
        }
    }

    private func setCanvasCommandActions(_ actions: HorizontalCanvasCommandActions?, for pane: HorizontalPane) {
        if let actions {
            canvasCommandActionsByPane[pane] = actions
            if activeCanvasCommandPane == nil || activeCanvasCommandPane.map({ !visiblePanes.contains($0) }) == true {
                activeCanvasCommandPane = pane
            }
        } else {
            canvasCommandActionsByPane.removeValue(forKey: pane)
            if activeCanvasCommandPane == pane {
                activeCanvasCommandPane = canvasCommandActionsByPane.keys
                    .filter { visiblePanes.contains($0) }
                    .sorted { $0.rawValue < $1.rawValue }
                    .first
            }
        }
    }

    private func setSchematicNetSegmentSelection(_ selection: HorizontalNetSegmentSelectionSidebarState?) {
        schematicNetSegmentSelection = selection
        if selection != nil {
            rightSidebarPane = .selection
        }
    }

    private func applySelectionPropertyChange(_ change: HorizontalSelectionPropertyChange, in pane: HorizontalPane) {
        guard !isReadOnly else {
            return
        }
        selectionPropertyChangeCommands[pane] = HorizontalSelectionPropertyChangeCommand(change: change)
    }

    private func clearSelectionDetailsForHiddenPanes(_ panes: Set<HorizontalPane>) {
        for pane in HorizontalPane.allCases where !panes.contains(pane) {
            selectionDetailsByPane.removeValue(forKey: pane)
            canvasCommandActionsByPane.removeValue(forKey: pane)
        }
        if !panes.contains(.schematic) {
            schematicNetSegmentSelection = nil
        }
        if let activeCanvasCommandPane,
           !panes.contains(activeCanvasCommandPane) {
            self.activeCanvasCommandPane = canvasCommandActionsByPane.keys
                .filter { panes.contains($0) }
                .sorted { $0.rawValue < $1.rawValue }
                .first
        }
    }

    private func selectNet(_ netIDs: Set<String>) {
        if netIDs != selectedNetIDs {
            highlightedNetIDs.removeAll()
        }
        selectedNetIDs = netIDs
    }

    private func selectComponents(_ componentIDs: Set<String>) {
        if componentIDs != selectedComponentIDs {
            highlightedComponentIDs.removeAll()
        }
        selectedComponentIDs = componentIDs
    }

    private func highlightSelectedNet() {
        highlightSelectedNet(selectedNetIDs)
        highlightSelectedComponents(selectedComponentIDs)
    }

    private func highlightSelectedNet(_ netIDs: Set<String>) {
        highlightedNetIDs = netIDs
    }

    private func highlightSelectedComponents(_ componentIDs: Set<String>) {
        highlightedComponentIDs = componentIDs
    }

    private func applyEditedBoard(_ board: HorizontalBoard, writesPlaneCache: Bool = false) {
        guard !isReadOnly else {
            return
        }
        var timings = [(String, UInt64)]()
        func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = try body()
            let end = DispatchTime.now().uptimeNanoseconds
            timings.append((label, end >= start ? end - start : 0))
            return value
        }

        // Does this edit invalidate the fills? Compared here, in the one funnel
        // every board edit passes through, so the answer is computed once per
        // edit. A pour's own result is the answer, not a question.
        let previousPlaneInputs = project.board.map(HorizontalBoardPlaneInputs.signature)
        measure("assign project board") {
            project.board = board
        }
        if writesPlaneCache {
            planesNeedUpdate = false
        } else if let previousPlaneInputs,
                  !board.planes.isEmpty,
                  HorizontalBoardPlaneInputs.signature(of: board) != previousPlaneInputs {
            planesNeedUpdate = true
        }
        do {
            try measure("apply board JSON") {
                try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &document.archive)
            }
            if writesPlaneCache {
                try measure("apply plane cache") {
                    try HorizontalProjectJSONApplicator.applyPlaneCache(board: board, in: project, to: &document.archive)
                }
            }
        } catch {
            measure("record failure") {
                recordArchiveApplyFailure(error)
            }
        }
        HorizontalMoveCommitDiagnostics.reportProjectBoardChange(timings: timings)
    }

    private func showBoardRulesWindow() {
        guard project.board != nil else {
            return
        }
        do {
            let rules = try HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive)
            let controller = boardRulesWindowController ?? HorizontalBoardRulesWindowController()
            boardRulesWindowController = controller
            controller.show(
                projectName: project.name,
                board: project.board,
                netClasses: selectedSchematic?.sheet.netClasses ?? [],
                initialRules: rules,
                isReadOnly: isReadOnly,
                onRulesChange: applyEditedBoardRules,
                onChecksRun: presentBoardRulesResults
            )
        } catch {
            recordDiagnostic("Could not load board rules: \(error.localizedDescription)")
        }
    }

    private func presentBoardRulesResults(_ result: HorizontalBoardRulesResultState) {
        rulesResultsState = result
        rightSidebarPane = .rulesResults
    }

    private func applyEditedBoardRules(_ rules: JSONDictionary) {
        guard !isReadOnly else {
            return
        }
        do {
            try HorizontalProjectJSONApplicator.apply(boardRules: rules, in: project, to: &document.archive)
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func applyEditedProjectMetadata(key: String, value: String) {
        guard !isReadOnly else {
            return
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            project.projectMeta.removeValue(forKey: key)
        } else {
            project.projectMeta[key] = trimmedValue
        }

        do {
            try HorizontalProjectJSONApplicator.apply(
                projectMeta: project.projectMeta,
                targetURL: projectMetadataTargetURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private var projectMetadataTargetURL: URL {
        if let topBlockFilename = project.blocks.first(where: \.isTop)?.blockFilename ?? project.blockFilename,
           !topBlockFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return project.baseURL.appendingPathComponent(topBlockFilename)
        }
        return project.projectFileURL
    }

    private func syncBoardWithSchematicData() {
        guard !isReadOnly else {
            return
        }
        guard let previousBoard = project.board else {
            recordDiagnostic(BoardSyncError.missingBoard.localizedDescription)
            return
        }

        do {
            var archive = document.archive
            try HorizontalProjectJSONApplicator.apply(board: previousBoard, in: project, to: &archive)
            let reloadedProject = try loadProjectSnapshot(from: archive)
            guard var syncedBoard = reloadedProject.board else {
                throw BoardSyncError.missingBoard
            }

            syncedBoard.url = previousBoard.url
            rebasePackageModelURLs(in: &syncedBoard)
            removePlanesWithDeletedNets(from: &syncedBoard)
            registerBoardSyncUndo(previousBoard)
            applyEditedBoard(syncedBoard)
            boardSyncRevision += 1
            selectionDetailsByPane[.board] = .empty
        } catch {
            recordDiagnostic("Could not sync board with schematic data: \(error.localizedDescription)")
        }
    }

    /// Board options with the working layer stamped in, so the layer selected in
    /// the layer list renders even when its eye is off. Derived per hand-off
    /// rather than stored, which keeps the selection in one place
    /// (`boardDrawingLayer`) instead of two that could disagree.
    private var boardCanvasDisplayOptions: BoardDisplayOptions {
        var options = boardDisplayOptions
        options.selectedLayer = boardDrawingLayer
        options.soloLayer = soloedBoardLayer
        return options
    }

    /// A number key names a layer; pressing the SAME one again solos it, and a
    /// third press restores the previous view. Solo is reversible from the same
    /// key that turned it on — otherwise the only way back is the menus, which
    /// is exactly the trap a hidden layer sets.
    ///
    /// Naming a different layer while soloed moves the solo rather than dropping
    /// it, so the number keys step through layers one at a time.
    private func selectOrSoloBoardLayer(_ layer: Int) {
        guard boardDrawingLayer == layer else {
            boardDrawingLayer = layer
            if soloedBoardLayer != nil {
                soloedBoardLayer = layer
            }
            return
        }
        soloedBoardLayer = soloedBoardLayer == layer ? nil : layer
    }

    /// A view preset replaces the whole visibility picture, so it also drops any
    /// solo — leaving one on would silently hide most of what the preset just
    /// asked to show.
    private func applyBoardLayerViewPreset(_ preset: HorizontalBoardLayerViewPreset) {
        soloedBoardLayer = nil
        boardDisplayOptions.apply(preset)
    }

    private func updateAllBoardPlanes() {
        guard !isReadOnly else {
            return
        }
        guard let previousBoard = project.board,
              !previousBoard.planes.isEmpty else {
            return
        }

        Task {
            await pourAllPlanes(from: previousBoard, pouring: previousBoard, undo: .updateAll)
        }
    }

    /// Pours, persists, and registers undo for a plane create/edit the canvas
    /// already applied to `editedBoard` (e.g. a freshly drawn plane). Mirrors the
    /// manual "Update All Planes" path so a new plane fills immediately and its
    /// fragments are cached; the bumped `boardSyncRevision` re-feeds the canvas.
    private func applyBoardPlaneEdit(_ editedBoard: HorizontalBoard, actionName: String) {
        guard !isReadOnly else {
            return
        }
        guard let previousBoard = project.board else {
            return
        }
        Task {
            await pourAllPlanes(
                from: previousBoard,
                pouring: editedBoard,
                undo: .edit(actionName: actionName)
            )
        }
    }

    /// Which undo entry a pour registers. An enum rather than a closure so
    /// nothing non-Sendable has to survive the `await` in `pourAllPlanes`.
    private enum PlanePourUndo {
        case updateAll
        case edit(actionName: String)
    }

    /// Pours every plane off the main thread, publishing progress so the board
    /// pane can show a determinate ring.
    ///
    /// This ran inline until it grew a progress indicator, which is what forced
    /// the move: a pour is seconds of clipping on a dense board, and on the main
    /// thread it froze the window — including any indicator it tried to draw.
    ///
    /// Progress arrives over an `AsyncStream` rather than a callback that writes
    /// state directly. The pour runs on a detached task, so a closure writing
    /// `planePourProgress` would be a main-actor write from a background thread;
    /// yielding to a stream and consuming it here keeps every state write on the
    /// main actor, where the `for await` loop already is.
    private func pourAllPlanes(
        from previousBoard: HorizontalBoard,
        pouring boardToPour: HorizontalBoard,
        undo: PlanePourUndo
    ) async {
        // A second pour would work from a stale snapshot and clobber the first.
        // Reachable because Q stays live while the overlay covers only the canvas.
        guard !isPouringPlanes else {
            return
        }
        isPouringPlanes = true
        // A single plane can only ever report 0% then 100%, so a ring stuck at
        // zero for the whole pour would read as hung. Spin instead.
        let isDeterminate = boardToPour.planes.count > 1
        planePourProgress = isDeterminate ? 0 : nil

        // What the pour is working from. If the board moves while it runs, the
        // result describes copper that no longer exists.
        let pouredInputs = HorizontalBoardPlaneInputs.signature(of: boardToPour)

        let (progressUpdates, progress) = AsyncStream<Double>.makeStream()
        let cache = planePourCache
        let pour = Task.detached(priority: .userInitiated) {
            let poured = HorizontalBoardPlaneUpdater.updateAllPlanes(
                in: boardToPour, cache: cache
            ) { completed, total in
                progress.yield(total > 0 ? Double(completed) / Double(total) : 1)
            }
            progress.finish()
            return poured
        }

        for await fraction in progressUpdates where isDeterminate {
            planePourProgress = fraction
        }
        let (pouredBoard, updatedCache) = await pour.value

        isPouringPlanes = false
        planePourProgress = nil

        // Editing stays live during a pour — nothing covers the canvas — so the
        // board can have moved under it. Applying the result would silently
        // clobber that edit, so drop it and leave the fills marked stale; the
        // rail button already says so and one press redoes the work.
        guard project.board.map(HorizontalBoardPlaneInputs.signature) == pouredInputs else {
            planesNeedUpdate = true
            return
        }

        planePourCache = updatedCache

        switch undo {
        case .updateAll:
            registerBoardPlaneUpdateUndo(previousBoard)
        case .edit(let actionName):
            registerBoardPlaneEditUndo(previousBoard, actionName: actionName)
        }
        applyEditedBoard(pouredBoard, writesPlaneCache: true)
        boardSyncRevision += 1
        selectionDetailsByPane[.board] = .empty
    }

    /// Diagnostic: empties every plane's `fragments` so the board renders without
    /// plane fills. Mirrors "clear all planes" for A/B-testing
    /// whether plane geometry is responsible for sluggish interaction. Run
    /// "Update All Planes" (Q) afterwards to recompute. Bypasses both isReadOnly
    /// and the document archive write — this is a transient in-memory render
    /// change, never persisted to disk.
    private func clearAllBoardPlanes() {
        guard let previousBoard = project.board,
              previousBoard.planes.contains(where: { !$0.fragments.isEmpty }) else {
            return
        }

        var updatedBoard = previousBoard
        updatedBoard.planes = updatedBoard.planes.map { plane in
            var plane = plane
            plane.fragments = []
            return plane
        }
        // In-memory mutation only; do not write to document archive.
        project.board = updatedBoard
        boardSyncRevision += 1
        selectionDetailsByPane[.board] = .empty
    }

    private func loadProjectSnapshot(from archive: HorizontalProjectArchive) throws -> HorizontalProject {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalBoardSync-\(UUID().uuidString)")
            .appendingPathExtension("horizontal")
        try archive.write(to: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        return try HorizontalProject.load(from: temporaryURL)
    }

    private func registerBoardSyncUndo(_ previousBoard: HorizontalBoard) {
        boardUndoTarget.configure(
            currentValue: { project.board ?? previousBoard },
            restoreValue: { board in
                applyEditedBoard(board)
                boardSyncRevision += 1
                selectionDetailsByPane[.board] = .empty
            }
        )
        boardUndoTarget.registerUndo(
            from: previousBoard,
            actionName: "Sync Board",
            undoManager: activeUndoManager
        )
    }

    private func registerBoardPlaneUpdateUndo(_ previousBoard: HorizontalBoard) {
        boardUndoTarget.configure(
            currentValue: { project.board ?? previousBoard },
            restoreValue: { board in
                applyEditedBoard(board, writesPlaneCache: true)
                boardSyncRevision += 1
                selectionDetailsByPane[.board] = .empty
            }
        )
        boardUndoTarget.registerUndo(
            from: previousBoard,
            actionName: "Update All Planes",
            undoManager: activeUndoManager
        )
    }

    private func registerBoardPlaneEditUndo(_ previousBoard: HorizontalBoard, actionName: String) {
        boardUndoTarget.configure(
            currentValue: { project.board ?? previousBoard },
            restoreValue: { board in
                applyEditedBoard(board, writesPlaneCache: true)
                boardSyncRevision += 1
                selectionDetailsByPane[.board] = .empty
            }
        )
        boardUndoTarget.registerUndo(
            from: previousBoard,
            actionName: actionName,
            undoManager: activeUndoManager
        )
    }

    private func removePlanesWithDeletedNets(from board: inout HorizontalBoard) {
        let validNetIDs = Set(board.netDetails.keys.map(normalizedID))
        board.planes.removeAll { plane in
            guard let netID = plane.netID.map(normalizedID) else {
                return true
            }
            return !validNetIDs.contains(netID)
        }
    }

    private func rebasePackageModelURLs(in board: inout HorizontalBoard) {
        guard let poolURL = project.poolDirectory.map({ project.baseURL.appendingPathComponent($0) }) else {
            return
        }

        for index in board.packages.indices {
            guard var model = board.packages[index].model3D,
                  !model.filename.hasPrefix("/") else {
                continue
            }

            let candidate = model.filename
                .split(separator: "/")
                .reduce(poolURL) { url, component in
                    url.appendingPathComponent(String(component))
                }
            if let fileURL = existingFileURL(candidate) {
                model.fileURL = fileURL
                board.packages[index].model3D = model
            }
        }
    }

    private func existingFileURL(_ url: URL) -> URL? {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return url
        }

        let directory = url.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return children.first {
            $0.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
        }
    }

    private func applyEditedSchematicSheet(_ sheet: HorizontalSchematicSheet, schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        let standardizedURL = schematicURL.standardizedFileURL
        for index in project.schematics.indices
            where project.schematics[index].schematic.url.standardizedFileURL == standardizedURL {
            replace(sheet, in: &project.schematics[index].schematic)
        }

        if var schematic = project.schematic,
           schematic.url.standardizedFileURL == standardizedURL {
            replace(sheet, in: &schematic)
            project.schematic = schematic
        }

        do {
            try HorizontalProjectJSONApplicator.apply(
                schematicSheet: sheet,
                schematicURL: schematicURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func renameSheet(sheetID: String, to name: String, schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        updateSchematics(at: schematicURL) { schematic in
            guard let index = schematic.sheets.firstIndex(where: { $0.id == sheetID }) else {
                return
            }
            schematic.sheets[index].name = name
        }
        do {
            try HorizontalProjectJSONApplicator.apply(
                sheetName: name,
                forSheetID: sheetID,
                schematicURL: schematicURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func reorderSheets(_ orderedSheetIDs: [String], schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        updateSchematics(at: schematicURL) { schematic in
            schematic.sheets.sort { lhs, rhs in
                (orderedSheetIDs.firstIndex(of: lhs.id) ?? .max)
                    < (orderedSheetIDs.firstIndex(of: rhs.id) ?? .max)
            }
            for index in schematic.sheets.indices {
                schematic.sheets[index].index = index + 1
            }
        }
        do {
            try HorizontalProjectJSONApplicator.apply(
                sheetOrder: orderedSheetIDs,
                schematicURL: schematicURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// Applies one mutation to every in-memory copy of the schematic at `url`:
    /// the per-block schematics list and the top-schematic mirror.
    private func updateSchematics(at url: URL, _ mutate: (inout HorizontalSchematic) -> Void) {
        let standardizedURL = url.standardizedFileURL
        for index in project.schematics.indices
            where project.schematics[index].schematic.url.standardizedFileURL == standardizedURL {
            mutate(&project.schematics[index].schematic)
        }
        if var schematic = project.schematic, schematic.url.standardizedFileURL == standardizedURL {
            mutate(&schematic)
            project.schematic = schematic
        }
    }

    private func replace(_ sheet: HorizontalSchematicSheet, in schematic: inout HorizontalSchematic) {
        for index in schematic.sheets.indices {
            schematic.sheets[index].grid = sheet.grid
        }
        guard let index = schematic.sheets.firstIndex(where: { $0.id == sheet.id }) else {
            return
        }
        schematic.sheets[index] = sheet
    }

    private func boardGridBinding() -> Binding<HorizontalGridSettings> {
        Binding {
            project.board?.grid ?? .boardDefault
        } set: { grid in
            guard !isReadOnly else {
                return
            }
            guard var board = project.board else {
                return
            }
            board.grid = grid.withClampedValues()
            applyEditedBoard(board)
        }
    }

    private func schematicGridBinding(for selectedSchematic: SelectedSchematic) -> Binding<HorizontalGridSettings> {
        Binding {
            self.selectedSchematic?.sheet.grid ?? selectedSchematic.sheet.grid
        } set: { grid in
            guard !isReadOnly else {
                return
            }
            var sheet = self.selectedSchematic?.sheet ?? selectedSchematic.sheet
            sheet.grid = grid.withClampedValues()
            applyEditedSchematicSheet(sheet, schematicURL: selectedSchematic.url)
        }
    }

    private func schematicNetClassesBinding(for selectedSchematic: SelectedSchematic) -> Binding<[HorizontalNetClass]> {
        Binding {
            self.selectedSchematic?.sheet.netClasses ?? selectedSchematic.sheet.netClasses
        } set: { netClasses in
            guard !isReadOnly else {
                return
            }
            applyEditedNetClasses(netClasses, selectedSchematic: selectedSchematic)
        }
    }

    private func applyEditedNetClasses(_ netClasses: [HorizontalNetClass], selectedSchematic: SelectedSchematic) {
        guard !isReadOnly else {
            return
        }
        let normalizedClasses = netClasses.map {
            HorizontalNetClass(id: normalizedID($0.id), name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func update(_ sheet: inout HorizontalSchematicSheet) {
            sheet.netClasses = normalizedClasses
            sheet.netDetails = netDetails(sheet.netDetails, renamedBy: normalizedClasses)
        }

        let standardizedURL = selectedSchematic.url.standardizedFileURL
        for schematicIndex in project.schematics.indices
            where project.schematics[schematicIndex].schematic.url.standardizedFileURL == standardizedURL {
            for sheetIndex in project.schematics[schematicIndex].schematic.sheets.indices {
                update(&project.schematics[schematicIndex].schematic.sheets[sheetIndex])
            }
            project.schematics[schematicIndex].schematic.netClasses = normalizedClasses
            project.schematics[schematicIndex].schematic.netDetails = netDetails(
                project.schematics[schematicIndex].schematic.netDetails,
                renamedBy: normalizedClasses
            )
        }

        if var schematic = project.schematic,
           schematic.url.standardizedFileURL == standardizedURL {
            for sheetIndex in schematic.sheets.indices {
                update(&schematic.sheets[sheetIndex])
            }
            schematic.netClasses = normalizedClasses
            schematic.netDetails = netDetails(schematic.netDetails, renamedBy: normalizedClasses)
            project.schematic = schematic
        }

        if var board = project.board {
            board.netDetails = netDetails(board.netDetails, renamedBy: normalizedClasses)
            project.board = board
        }

        guard let blockURL = selectedSchematic.blockURL else {
            return
        }

        do {
            try HorizontalProjectJSONApplicator.apply(
                netClasses: normalizedClasses,
                blockURL: blockURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func usedNetClassIDs(for selectedSchematic: SelectedSchematic) -> Set<String> {
        var usedIDs = Set<String>()

        func collect(from details: [String: HorizontalNetDetails]) {
            for detail in details.values {
                if let netClassID = detail.netClassID.map(normalizedID) {
                    usedIDs.insert(netClassID)
                }
            }
        }

        collect(from: selectedSchematic.sheet.netDetails)

        let standardizedURL = selectedSchematic.url.standardizedFileURL
        for schematic in project.schematics
            where schematic.schematic.url.standardizedFileURL == standardizedURL {
            collect(from: schematic.schematic.netDetails)
            for sheet in schematic.schematic.sheets {
                collect(from: sheet.netDetails)
            }
        }

        if let schematic = project.schematic,
           schematic.url.standardizedFileURL == standardizedURL {
            collect(from: schematic.netDetails)
            for sheet in schematic.sheets {
                collect(from: sheet.netDetails)
            }
        }

        if let board = project.board {
            collect(from: board.netDetails)
        }

        return usedIDs
    }

    private func applyEditedNetClass(netID: String, netClassID: String?, selectedSchematic: SelectedSchematic) {
        guard !isReadOnly else {
            return
        }
        let normalizedNetID = normalizedID(netID)
        let normalizedClassID = netClassID.map(normalizedID)
        let netClasses = self.selectedSchematic?.sheet.netClasses ?? selectedSchematic.sheet.netClasses
        let className = normalizedClassID.flatMap { classID in
            netClasses.first { normalizedID($0.id) == classID }?.name
        }

        func update(_ details: inout [String: HorizontalNetDetails]) {
            var detail = details[normalizedNetID] ?? HorizontalNetDetails(
                id: normalizedNetID,
                name: String(normalizedNetID.prefix(8)),
                netClassID: nil,
                netClassName: nil
            )
            detail.netClassID = normalizedClassID
            detail.netClassName = className
            details[normalizedNetID] = detail
        }

        let standardizedURL = selectedSchematic.url.standardizedFileURL
        for schematicIndex in project.schematics.indices
            where project.schematics[schematicIndex].schematic.url.standardizedFileURL == standardizedURL {
            update(&project.schematics[schematicIndex].schematic.netDetails)
            for sheetIndex in project.schematics[schematicIndex].schematic.sheets.indices {
                update(&project.schematics[schematicIndex].schematic.sheets[sheetIndex].netDetails)
            }
        }

        if var schematic = project.schematic,
           schematic.url.standardizedFileURL == standardizedURL {
            update(&schematic.netDetails)
            for sheetIndex in schematic.sheets.indices {
                update(&schematic.sheets[sheetIndex].netDetails)
            }
            project.schematic = schematic
        }

        if var board = project.board {
            update(&board.netDetails)
            project.board = board
        }

        guard let blockURL = selectedSchematic.blockURL else {
            return
        }

        do {
            try HorizontalProjectJSONApplicator.apply(
                netClassID: normalizedClassID,
                forNetID: normalizedNetID,
                blockURL: blockURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func applyEditedComponentRefdes(
        componentID: String,
        refdes: String,
        selectedSchematic: SelectedSchematic
    ) {
        guard !isReadOnly else {
            return
        }
        let normalizedComponentID = normalizedID(componentID)

        func update(_ sheet: inout HorizontalSchematicSheet) {
            for index in sheet.symbols.indices
                where sheet.symbols[index].componentID.map(normalizedID) == normalizedComponentID {
                let oldRefdes = sheet.symbols[index].componentDetails?.refdes
                updatePlacementRefdes(&sheet.symbols[index], refdes: refdes)
                updateSymbolTextRefdes(symbolID: sheet.symbols[index].id, oldRefdes: oldRefdes, newRefdes: refdes, sheet: &sheet)
            }
        }

        let standardizedURL = selectedSchematic.url.standardizedFileURL
        for schematicIndex in project.schematics.indices
            where project.schematics[schematicIndex].schematic.url.standardizedFileURL == standardizedURL {
            for sheetIndex in project.schematics[schematicIndex].schematic.sheets.indices {
                update(&project.schematics[schematicIndex].schematic.sheets[sheetIndex])
            }
        }

        if var schematic = project.schematic,
           schematic.url.standardizedFileURL == standardizedURL {
            for sheetIndex in schematic.sheets.indices {
                update(&schematic.sheets[sheetIndex])
            }
            project.schematic = schematic
        }

        if var board = project.board {
            for index in board.packages.indices
                where board.packages[index].componentID.map(normalizedID) == normalizedComponentID {
                let oldRefdes = board.packages[index].componentDetails?.refdes
                updatePlacementRefdes(&board.packages[index], refdes: refdes)
                updatePackageTextRefdes(packageID: board.packages[index].id, oldRefdes: oldRefdes, newRefdes: refdes, board: &board)
            }
            project.board = board
        }

        guard let blockURL = selectedSchematic.blockURL else {
            return
        }

        do {
            try HorizontalProjectJSONApplicator.apply(
                componentRefdes: refdes,
                forComponentID: normalizedComponentID,
                blockURL: blockURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func applyEditedComponentPinNames(
        componentID: String,
        pins: [HorizontalSymbolPinName],
        selectedSchematic: SelectedSchematic
    ) {
        guard !isReadOnly else {
            return
        }
        let normalizedComponentID = normalizedID(componentID)

        func update(_ sheet: inout HorizontalSchematicSheet) {
            for symbolIndex in sheet.symbols.indices
                where sheet.symbols[symbolIndex].componentID.map(normalizedID) == normalizedComponentID {
                for pin in pins {
                    guard let index = sheet.symbols[symbolIndex].symbolPinNames.firstIndex(where: {
                        normalizedID($0.gatePinPath) == normalizedID(pin.gatePinPath)
                    }) else {
                        continue
                    }
                    sheet.symbols[symbolIndex].symbolPinNames[index].state = pin.state
                }
            }
        }

        let standardizedURL = selectedSchematic.url.standardizedFileURL
        for schematicIndex in project.schematics.indices
            where project.schematics[schematicIndex].schematic.url.standardizedFileURL == standardizedURL {
            for sheetIndex in project.schematics[schematicIndex].schematic.sheets.indices {
                update(&project.schematics[schematicIndex].schematic.sheets[sheetIndex])
            }
        }

        if var schematic = project.schematic,
           schematic.url.standardizedFileURL == standardizedURL {
            for sheetIndex in schematic.sheets.indices {
                update(&schematic.sheets[sheetIndex])
            }
            project.schematic = schematic
        }

        guard let blockURL = selectedSchematic.blockURL else {
            return
        }

        do {
            try HorizontalProjectJSONApplicator.apply(
                symbolPinNames: pins,
                forComponentID: normalizedComponentID,
                blockURL: blockURL,
                in: project,
                to: &document.archive
            )
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func updatePlacementRefdes(_ placement: inout HorizontalPlacement, refdes: String) {
        guard var details = placement.componentDetails else {
            return
        }
        details.refdes = refdes
        placement.componentDetails = details
        placement.label = details.displayLabel
    }

    private func updateSymbolTextRefdes(
        symbolID: String,
        oldRefdes: String?,
        newRefdes: String,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let oldRefdes = nonEmpty(oldRefdes), oldRefdes != newRefdes else {
            return
        }
        let normalizedSymbolID = normalizedID(symbolID)
        for index in sheet.symbolTexts.indices
            where self.symbolID(forGeometryID: sheet.symbolTexts[index].id).map(normalizedID) == normalizedSymbolID {
            sheet.symbolTexts[index].text = sheet.symbolTexts[index].text.replacingOccurrences(of: oldRefdes, with: newRefdes)
        }
    }

    private func updatePackageTextRefdes(
        packageID: String,
        oldRefdes: String?,
        newRefdes: String,
        board: inout HorizontalBoard
    ) {
        guard let oldRefdes = nonEmpty(oldRefdes), oldRefdes != newRefdes else {
            return
        }
        let normalizedPackageID = normalizedID(packageID)
        for index in board.packageTexts.indices
            where self.packageID(forGeometryID: board.packageTexts[index].id).map(normalizedID) == normalizedPackageID {
            board.packageTexts[index].text = board.packageTexts[index].text.replacingOccurrences(of: oldRefdes, with: newRefdes)
        }
    }

    private func symbolID(forGeometryID geometryID: String) -> String? {
        objectIDPrefix(
            in: geometryID,
            separators: ["arc", "line", "pin", "pin-connector", "pin-connector-text", "pin-decoration", "pin-direction", "pin-name", "pin-pad", "polygon", "text"]
        )
    }

    private func packageID(forGeometryID geometryID: String) -> String? {
        objectIDPrefix(
            in: geometryID,
            separators: ["arc", "hole", "line", "pad", "polygon", "text"]
        )
    }

    private func objectIDPrefix(in geometryID: String, separators: Set<String>) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
              separatorIndex > components.startIndex else {
            return nil
        }
        return components[..<separatorIndex].joined(separator: "/")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func netDetails(
        _ details: [String: HorizontalNetDetails],
        renamedBy netClasses: [HorizontalNetClass]
    ) -> [String: HorizontalNetDetails] {
        let namesByID = Dictionary(uniqueKeysWithValues: netClasses.map { (normalizedID($0.id), $0.name) })
        return details.mapValues { detail in
            var detail = detail
            if let netClassID = detail.netClassID.map(normalizedID) {
                detail.netClassName = namesByID[netClassID]
            }
            return detail
        }
    }

    private func recordArchiveApplyFailure(_ error: Error) {
        recordDiagnostic("Could not apply edit to project JSON: \(error.localizedDescription)")
    }

    private func recordDiagnostic(_ message: String) {
        guard !project.diagnostics.contains(where: { $0.message == message }) else {
            return
        }
        project.diagnostics.append(HorizontalDiagnostic(message: message))
    }

    private func showPackageView() {
        columnVisibility = .all
        navigatorSelection = .package
    }

    private func beginPartPlacement(_ part: HorizontalPoolPart) {
        guard !isReadOnly else {
            return
        }
        guard selectedSchematic != nil else {
            return
        }
        visiblePanes.insert(.schematic)
        pendingPartPlacement = HorizontalPartPlacementRequest(part: part)
    }

    private func showTopSchematicView() {
        guard let defaultNavigatorSelection else {
            return
        }
        columnVisibility = .all
        navigatorSelection = defaultNavigatorSelection
        syncPanesForSelection(defaultNavigatorSelection)
    }

    private func showBoardView() {
        guard project.board != nil else {
            return
        }
        columnVisibility = .all
        navigatorSelection = .board
        visiblePanes.insert(.board)
    }

    private func showDiagnosticsView() {
        guard !project.diagnostics.isEmpty else {
            return
        }
        columnVisibility = .all
        navigatorSelection = .diagnostics
    }

    private func syncPanesForSelection(_ selection: ProjectNavigatorSelection?) {
        switch selection {
        case .pool:
            visiblePanes.insert(.parts)
        case .block, .sheet, .standaloneSheet:
            visiblePanes.insert(.schematic)
        case .board:
            visiblePanes.insert(.board)
        default:
            break
        }
    }

    private var selectedSchematicAvailable: Bool {
        selectedSchematic != nil
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var defaultNavigatorSelection: ProjectNavigatorSelection? {
        if let schematic = project.schematics.first,
           let sheet = schematic.schematic.sheets.first {
            return .sheet(blockID: schematic.block.uuid, sheetID: sheet.id)
        }

        if let sheet = project.schematic?.sheets.first {
            return .standaloneSheet(sheet.id)
        }

        return nil
    }

    private var projectMetaRows: [ProjectMetadataRow] {
        let preferredKeys = ["project_title", "project_name", "rev", "author", "date", "license"]
        var seenValues = Set<String>()
        var rows = [ProjectMetadataRow]()

        func append(key: String, value: String?, includesEmpty: Bool = false) {
            let displayValue = value ?? ""
            let trimmedValue = displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard includesEmpty || !trimmedValue.isEmpty,
                  trimmedValue.isEmpty || !seenValues.contains(trimmedValue) else {
                return
            }
            if !trimmedValue.isEmpty {
                seenValues.insert(trimmedValue)
            }
            rows.append(ProjectMetadataRow(key: key, title: projectMetaTitle(key), value: displayValue))
        }

        for key in preferredKeys {
            append(key: key, value: project.projectMeta[key], includesEmpty: true)
        }

        let remainingKeys = project.projectMeta.keys
            .filter { !preferredKeys.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for key in remainingKeys {
            append(key: key, value: project.projectMeta[key])
        }

        return rows
    }

    private func projectMetaTitle(_ key: String) -> String {
        switch key {
        case "project_title": "Title"
        case "project_name": "Project"
        case "rev": "Revision"
        case "author": "Author"
        case "date": "Date"
        case "license": "License"
        default:
            key.split(separator: "_")
                .map { $0.localizedCapitalized }
                .joined(separator: " ")
        }
    }

    private var selectedSchematic: SelectedSchematic? {
        if let navigatorSelection {
            switch navigatorSelection {
            case .sheet(let blockID, let sheetID):
                if let schematic = project.schematics.first(where: { $0.block.uuid == blockID }),
                   let sheet = schematic.schematic.sheets.first(where: { $0.id == sheetID }) {
                    return SelectedSchematic(
                        subtitle: "\(schematic.block.displayName) / \(sheet.name)",
                        url: schematic.schematic.url,
                        blockURL: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                        sheets: schematic.schematic.sheets,
                        sheet: sheet
                    )
                }
            case .block(let blockID):
                if let schematic = project.schematics.first(where: { $0.block.uuid == blockID }),
                   let sheet = schematic.schematic.sheets.first {
                    return SelectedSchematic(
                        subtitle: "\(schematic.block.displayName) / \(sheet.name)",
                        url: schematic.schematic.url,
                        blockURL: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                        sheets: schematic.schematic.sheets,
                        sheet: sheet
                    )
                }
            case .standaloneSheet(let sheetID):
                if let schematic = project.schematic,
                   let sheet = schematic.sheets.first(where: { $0.id == sheetID }) {
                    return SelectedSchematic(
                        subtitle: sheet.name,
                        url: schematic.url,
                        blockURL: nil,
                        sheets: schematic.sheets,
                        sheet: sheet
                    )
                }
            default:
                break
            }
        }

        if let schematic = project.schematics.first,
           let sheet = schematic.schematic.sheets.first {
            return SelectedSchematic(
                subtitle: "\(schematic.block.displayName) / \(sheet.name)",
                url: schematic.schematic.url,
                blockURL: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                sheets: schematic.schematic.sheets,
                sheet: sheet
            )
        }

        if let schematic = project.schematic,
           let sheet = schematic.sheets.first {
            return SelectedSchematic(
                subtitle: sheet.name,
                url: schematic.url,
                blockURL: nil,
                sheets: schematic.sheets,
                sheet: sheet
            )
        }

        return nil
    }
}

struct SelectedSchematic {
    var subtitle: String
    var url: URL
    var blockURL: URL?
    var sheets: [HorizontalSchematicSheet]
    var sheet: HorizontalSchematicSheet
}

struct ProjectNavigatorView: View {
    var project: HorizontalProject
    @Binding var selection: ProjectNavigatorSelection?
    @Binding var searchText: String
    var allowsSheetEditing = false
    /// (schematic URL, sheet ID, new name)
    var onRenameSheet: (URL, String, String) -> Void = { _, _, _ in }
    /// (schematic URL, sheet IDs in their new order)
    var onReorderSheets: (URL, [String]) -> Void = { _, _ in }

    @State private var renameTarget: SheetRenameTarget?
    @State private var renameDraft = ""

    private struct SheetRenameTarget: Identifiable {
        var schematicURL: URL
        var sheetID: String
        var currentName: String
        var id: String { sheetID }
    }

    var body: some View {
        List(selection: $selection) {
            if !project.schematics.isEmpty {
                Section("Blocks") {
                    ForEach(project.schematics.filter(schematicMatchesSearch)) { schematic in
                        let blockMatches = blockMatchesSearch(schematic.block, schematicFilename: schematic.schematicFilename)
                        let sheets = sheetsForSearch(in: schematic, blockMatches: blockMatches)

                        if blockMatches || !isSearching {
                            NavigatorRow(
                                icon: schematic.block.isTop ? "target" : "square.stack.3d.up",
                                title: navigatorTitle(for: schematic.block),
                                detail: schematic.schematicFilename
                            )
                            .tag(ProjectNavigatorSelection.block(schematic.block.uuid))
                        }

                        ForEach(sheets) { sheet in
                            if matchesSearch("sheet", sheet.name, navigatorTitle(for: schematic.block)) || blockMatches || !isSearching {
                                NavigatorRow(
                                    icon: "rectangle.grid.1x2",
                                    title: sheet.name
                                )
                                .padding(.leading, 18)
                                .tag(ProjectNavigatorSelection.sheet(blockID: schematic.block.uuid, sheetID: sheet.id))
                                .contextMenu {
                                    sheetContextMenu(for: sheet, schematicURL: schematic.schematic.url)
                                }
                            }
                        }
                        .onMove(perform: sheetMoveHandler(orderedIDs: schematic.schematic.sheets.map(\.id), schematicURL: schematic.schematic.url))
                    }
                }
            }

            if let schematic = project.schematic, project.schematics.isEmpty {
                Section("Schematic") {
                    if matchesSearch("schematic", schematic.url.lastPathComponent) {
                        NavigatorRow(
                            icon: "doc.text.magnifyingglass",
                            title: schematic.url.lastPathComponent,
                            detail: "Schematic"
                        )
                    }
                    ForEach(schematic.sheets.filter { matchesSearch("sheet", $0.name) }) { sheet in
                        NavigatorRow(
                            icon: "rectangle.grid.1x2",
                            title: sheet.name
                        )
                        .tag(ProjectNavigatorSelection.standaloneSheet(sheet.id))
                        .contextMenu {
                            sheetContextMenu(for: sheet, schematicURL: schematic.url)
                        }
                    }
                    .onMove(perform: sheetMoveHandler(orderedIDs: schematic.sheets.map(\.id), schematicURL: schematic.url))
                }
            }

            if let board = project.board {
                Section("Board") {
                    if matchesSearch("board", board.url.lastPathComponent, board.name) {
                        NavigatorRow(icon: "cpu", title: board.url.lastPathComponent, detail: board.name)
                            .tag(ProjectNavigatorSelection.board)
                    }
                }
            }

            if let selectedSummary {
                Section("Selection") {
                    NavigatorSelectionSummaryView(summary: selectedSummary)
                }
            }

            if !project.diagnostics.isEmpty {
                Section("Diagnostics") {
                    NavigatorRow(icon: "exclamationmark.triangle", title: "Diagnostics", detail: "\(project.diagnostics.count) messages")
                        .tag(ProjectNavigatorSelection.diagnostics)
                    ForEach(project.diagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .alert("Rename Sheet", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    @ViewBuilder
    private func sheetContextMenu(for sheet: HorizontalSchematicSheet, schematicURL: URL) -> some View {
        if allowsSheetEditing {
            Button("Rename…") {
                renameDraft = sheet.name
                renameTarget = SheetRenameTarget(
                    schematicURL: schematicURL,
                    sheetID: sheet.id,
                    currentName: sheet.name
                )
            }
        }
    }

    /// Drag-reordering for a sheets ForEach. `nil` (disabling the drag) while a
    /// search filters the rows — the visible indices wouldn't map onto the real
    /// sheet order — or when the project is read-only.
    private func sheetMoveHandler(orderedIDs: [String], schematicURL: URL) -> ((IndexSet, Int) -> Void)? {
        guard allowsSheetEditing, !isSearching, orderedIDs.count > 1 else {
            return nil
        }
        return { source, destination in
            var reordered = orderedIDs
            reordered.move(fromOffsets: source, toOffset: destination)
            guard reordered != orderedIDs else {
                return
            }
            onReorderSheets(schematicURL, reordered)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding {
            renameTarget != nil
        } set: { presented in
            if !presented {
                renameTarget = nil
            }
        }
    }

    private func commitRename() {
        guard let target = renameTarget else {
            return
        }
        renameTarget = nil
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.currentName else {
            return
        }
        onRenameSheet(target.schematicURL, target.sheetID, name)
    }

    private var isSearching: Bool {
        !searchTokens.isEmpty
    }

    private var searchTokens: [String] {
        searchText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).lowercased() }
    }

    private func matchesSearch(_ values: String...) -> Bool {
        let tokens = searchTokens
        guard !tokens.isEmpty else {
            return true
        }

        let haystack = values
            .joined(separator: " ")
            .lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func blockMatchesSearch(_ block: HorizontalProjectBlock, schematicFilename: String) -> Bool {
        matchesSearch(
            "block schematic sheet",
            navigatorTitle(for: block),
            block.displayName,
            block.uuid,
            block.blockFilename ?? "",
            schematicFilename,
            block.symbolFilename ?? ""
        )
    }

    private func navigatorTitle(for block: HorizontalProjectBlock) -> String {
        block.isTop ? "Schematic" : block.displayName
    }

    private func schematicMatchesSearch(_ schematic: HorizontalProjectSchematic) -> Bool {
        blockMatchesSearch(schematic.block, schematicFilename: schematic.schematicFilename)
            || schematic.schematic.sheets.contains {
                matchesSearch("sheet", $0.name)
            }
    }

    private func sheetsForSearch(in schematic: HorizontalProjectSchematic, blockMatches: Bool) -> [HorizontalSchematicSheet] {
        if !isSearching || blockMatches {
            return schematic.schematic.sheets
        }

        return schematic.schematic.sheets.filter {
            matchesSearch("sheet", $0.name)
        }
    }

    private var selectedSummary: NavigatorSelectionSummary? {
        guard let selection else {
            return nil
        }

        switch selection {
        case .package:
            return NavigatorSelectionSummary(
                id: "package",
                title: project.url.lastPathComponent,
                subtitle: "Document Package",
                url: project.url,
                rows: [
                    detail("Project", project.projectFileURL.lastPathComponent),
                    detail("Blocks", project.blocks.count.formatted()),
                    detail("Sheets", totalSheetCount.formatted()),
                    detail("Diagnostics", project.diagnostics.count.formatted())
                ]
            )
        case .projectFile:
            return NavigatorSelectionSummary(
                id: "project-file",
                title: project.projectFileURL.lastPathComponent,
                subtitle: ".hprj Project File",
                url: project.projectFileURL,
                rows: [
                    detail("UUID", project.uuid),
                    detail("Title", project.displayTitle),
                    detail("Base", project.baseURL.lastPathComponent)
                ]
            )
        case .blocksFile:
            return NavigatorSelectionSummary(
                id: "blocks-file",
                title: project.blocksFilename,
                subtitle: "Block Graph",
                url: project.baseURL.appendingPathComponent(project.blocksFilename),
                rows: [
                    detail("Blocks", project.blocks.count.formatted()),
                    detail("Top Block", project.blocks.first(where: \.isTop)?.displayName ?? "Unavailable")
                ]
            )
        case .pool:
            guard let poolDirectory = project.poolDirectory else {
                return nil
            }
            return NavigatorSelectionSummary(
                id: "pool",
                title: poolDirectory,
                subtitle: "Project Pool",
                url: project.baseURL.appendingPathComponent(poolDirectory),
                rows: [
                    detail("Location", project.baseURL.appendingPathComponent(poolDirectory).path)
                ]
            )
        case .block(let blockID):
            guard let schematic = project.schematics.first(where: { $0.block.uuid == blockID }) else {
                return nil
            }
            return NavigatorSelectionSummary(
                id: "block-\(blockID)",
                title: schematic.block.displayName,
                subtitle: schematic.block.isTop ? "Top Block" : "Block",
                url: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                rows: [
                    detail("UUID", schematic.block.uuid),
                    detail("Schematic", schematic.schematicFilename)
                ]
            )
        case .sheet, .standaloneSheet:
            return nil
        case .board:
            return nil
        case .diagnostics:
            return NavigatorSelectionSummary(
                id: "diagnostics",
                title: "Diagnostics",
                subtitle: "\(project.diagnostics.count.formatted()) messages",
                url: nil,
                rows: project.diagnostics.prefix(5).enumerated().map { index, diagnostic in
                    detail("Message \(index + 1)", diagnostic.message)
                }
            )
        }
    }

    private var totalSheetCount: Int {
        if project.schematics.isEmpty {
            return project.schematic?.sheets.count ?? 0
        }
        return project.schematics.reduce(0) { $0 + $1.schematic.sheets.count }
    }

    private func detail(_ title: String, _ value: String) -> NavigatorSelectionDetail {
        NavigatorSelectionDetail(title: title, value: value)
    }

    private func unresolvedPackageCount(for board: HorizontalBoard) -> Int {
        let geometryIDs = board.packagePads.map(\.id)
            + board.packagePolygons.map(\.id)
            + board.packageLines.map(\.id)

        return board.packages.filter { package in
            let normalizedPackageID = normalizedID(package.id)
            return !geometryIDs.contains {
                geometryBelongsToPackage($0, normalizedPackageID: normalizedPackageID)
            }
        }.count
    }

    private func geometryBelongsToPackage(_ geometryID: String, normalizedPackageID: String) -> Bool {
        let normalizedGeometryID = normalizedID(geometryID)
        return normalizedGeometryID == normalizedPackageID
            || normalizedGeometryID.hasPrefix("\(normalizedPackageID)/")
    }

    private func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    private func stackupLayerTitle(_ layer: Int) -> String {
        HorizontalBoardLayers.name(for: layer)
    }

    private func stackupLayerDetail(_ layer: HorizontalBoardStackupLayer) -> String {
        let copper = horizonLengthString(layer.copperThickness)
        let substrate = horizonLengthString(layer.substrateThickness)
        return "Cu \(copper), substrate \(substrate)"
    }

    private func panelDetail(_ panel: HorizontalBoardPanel) -> String {
        let filename = URL(fileURLWithPath: panel.projectFilename).lastPathComponent
        guard !panel.bounds.isEmpty else {
            return filename
        }

        return "\(filename) - \(horizonSizeString(panel.bounds))"
    }
}

private struct ProjectMetadataRow: Identifiable {
    var key: String
    var title: String
    var value: String

    var id: String { key }
}

private struct NavigatorSelectionSummary: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var url: URL?
    var rows: [NavigatorSelectionDetail]
}

private struct NavigatorSelectionDetail: Identifiable {
    var title: String
    var value: String

    var id: String { "\(title):\(value)" }
}

private struct SelectionSidebarSection: Identifiable {
    var pane: HorizontalPane
    var state: HorizontalSelectionDetailState

    var id: HorizontalPane { pane }
}

private enum SelectionSidebarScrollTarget: Hashable {
    case netSegmentSelection(UUID)
}

private struct HorizontalNetSegmentSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var activationID: UUID
    var isEnabled: Bool
    var onMoveSelection: (Int) -> Void
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.focus(nsView, activationID: activationID)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: HorizontalNetSegmentSearchField
        private var focusedActivationID: UUID?

        init(_ parent: HorizontalNetSegmentSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else {
                return
            }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func focus(_ field: NSSearchField, activationID: UUID) {
            guard focusedActivationID != activationID else {
                return
            }

            focusedActivationID = activationID
            Self.focus(field, attemptsRemaining: 4)
        }

        private static func focus(_ field: NSSearchField, attemptsRemaining: Int) {
            DispatchQueue.main.async { [weak field] in
                guard let field else {
                    return
                }

                if let window = field.window {
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                } else if attemptsRemaining > 0 {
                    focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }
}

private struct HorizontalNetSegmentSelectionSidebarView: View {
    var state: HorizontalNetSegmentSelectionSidebarState
    var isReadOnly: Bool
    var onCommand: (HorizontalNetSegmentSelectionCommand) -> Void

    @State private var query = ""
    @State private var selectedOptionID: String?

    private var filteredOptions: [HorizontalNetSegmentSelectionOption] {
        let terms = query
            .split { $0.isWhitespace }
            .map { $0.lowercased() }
        guard !terms.isEmpty else {
            return state.options
        }

        return state.options.filter { option in
            let haystack = [option.name, option.id, option.netClassName ?? ""]
                .joined(separator: " ")
                .lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move Net Segment")
                        .font(.body.weight(.semibold))
                    Text(state.currentNetName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    send(.cancel)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isReadOnly)
                .help("Cancel")
            }

            HorizontalNetSegmentSearchField(
                text: $query,
                placeholder: "Search Nets",
                activationID: state.id,
                isEnabled: !isReadOnly,
                onMoveSelection: moveSelection(by:),
                onCommit: commitSelectedOption,
                onCancel: { send(.cancel) }
            )
            .frame(height: 24)

            if state.canCreateNewNet {
                Button {
                    send(.createNew)
                } label: {
                    Label("New Unnamed Net", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReadOnly)
                .help("Move the segment to a new unnamed net")
            }

            if filteredOptions.isEmpty {
                Text("No matching named nets")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredOptions) { option in
                        Button {
                            selectedOptionID = option.id
                            send(.selectExisting(option.id))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.isPower ? "bolt.fill" : "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(.secondary)
                                    .font(.body)
                                    .frame(width: 16)
                                Text(option.name)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let netClassName = option.netClassName,
                                   !netClassName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(netClassName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background {
                                if selectedOptionID == option.id {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.16))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isReadOnly)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: query) { _, _ in
            normalizeSelection()
        }
        .onChange(of: state.id) { _, _ in
            query = ""
            selectedOptionID = nil
        }
    }

    private func send(_ action: HorizontalNetSegmentSelectionCommandAction) {
        onCommand(HorizontalNetSegmentSelectionCommand(selectionID: state.id, action: action))
    }

    private func normalizeSelection() {
        guard let selectedOptionID,
              filteredOptions.contains(where: { $0.id == selectedOptionID }) else {
            selectedOptionID = nil
            return
        }
    }

    private func moveSelection(by offset: Int) {
        let options = filteredOptions
        guard !options.isEmpty else {
            selectedOptionID = nil
            return
        }

        guard let selectedOptionID,
              let index = options.firstIndex(where: { $0.id == selectedOptionID }) else {
            selectedOptionID = offset < 0 ? options.last?.id : options.first?.id
            return
        }

        let nextIndex = min(max(index + offset, options.startIndex), options.index(before: options.endIndex))
        self.selectedOptionID = options[nextIndex].id
    }

    private func commitSelectedOption() {
        guard !isReadOnly,
              let option = selectedOptionID.flatMap({ id in filteredOptions.first { $0.id == id } }) ?? filteredOptions.first else {
            return
        }

        selectedOptionID = option.id
        send(.selectExisting(option.id))
    }
}

private struct SelectionSidebarView: View {
    var sections: [SelectionSidebarSection]
    var netSegmentSelection: HorizontalNetSegmentSelectionSidebarState?
    var safeAreaInsets: EdgeInsets
    var foregroundColor: Color
    var backgroundColor: Color
    var isReadOnly: Bool
    var onChange: (HorizontalSelectionPropertyChange, HorizontalPane) -> Void
    var onNetSegmentSelectionCommand: (HorizontalNetSegmentSelectionCommand) -> Void

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                if sections.isEmpty && netSegmentSelection == nil {
                    Section("Selection") {
                        Label("No selection", systemImage: "scope")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                } else {
                    if let netSegmentSelection {
                        Section("Schematic") {
                            HorizontalNetSegmentSelectionSidebarView(
                                state: netSegmentSelection,
                                isReadOnly: isReadOnly,
                                onCommand: onNetSegmentSelectionCommand
                            )
                            .id(SelectionSidebarScrollTarget.netSegmentSelection(netSegmentSelection.id))
                            .padding(.vertical, 4)
                        }
                    }
                    ForEach(sections) { section in
                        Section(section.pane.title) {
                            HorizontalSelectionPopoverView(
                                state: section.state,
                                foregroundColor: foregroundColor,
                                backgroundColor: backgroundColor,
                                chrome: .sidebar,
                                isReadOnly: isReadOnly
                            ) { change in
                                onChange(change, section.pane)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, safeAreaInsets.top)
            .background(.regularMaterial)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.primary.opacity(0.1))
                    .frame(width: 0.7)
            }
            .onAppear {
                scrollToNetSegmentSelection(using: scrollProxy)
            }
            .onChange(of: netSegmentSelection?.id) { _, _ in
                scrollToNetSegmentSelection(using: scrollProxy)
            }
        }
    }

    private func scrollToNetSegmentSelection(using proxy: ScrollViewProxy) {
        guard let netSegmentSelection else {
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(SelectionSidebarScrollTarget.netSegmentSelection(netSegmentSelection.id), anchor: .top)
        }
    }
}

private struct HorizontalRulesResultsSidebarView: View {
    var result: HorizontalBoardRulesResultState?
    var safeAreaInsets: EdgeInsets

    var body: some View {
        List {
            Section("Rules Results") {
                if let result {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.ruleTitle)
                            .fontWeight(.semibold)
                        Text(result.checkedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("No checks run", systemImage: "checklist")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }

            if let result {
                Section("Results") {
                    if result.messages.isEmpty {
                        Label("No structural issues", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(result.messages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: message.level.iconName)
                                    .foregroundStyle(message.level.color)
                                    .frame(width: 18)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(message.title)
                                    Text(message.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.top, safeAreaInsets.top)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(width: 0.7)
        }
    }
}

private struct NavigatorSelectionSummaryView: View {
    var summary: NavigatorSelectionSummary
    var usesSystemValueText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(summary.rows) { row in
                NavigatorValueRow(title: row.title, value: row.value, usesSystemValueText: usesSystemValueText)
            }

            if let url = summary.url {
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy Path")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BoardLoadingHost<Content: View>: View {
    var loadID: String
    var backgroundColor: Color
    @ViewBuilder var content: Content

    @State private var activeLoadID: String?
    @State private var shouldMountContent = false
    @State private var showsLoadingOverlay = true
    @State private var mountTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            backgroundColor

            if shouldMountContent {
                content
                    .transition(.opacity)
                    .onAppear {
                        scheduleLoadingDismissal(for: loadID)
                    }
            }

            if showsLoadingOverlay {
                CanvasLoadingOverlay(label: "Loading Board...", accessibilityLabel: "Loading board")
                    .transition(.opacity)
            }
        }
        .onAppear {
            resetIfNeeded()
        }
        .onChange(of: loadID) { _, _ in
            resetIfNeeded()
        }
        .onDisappear {
            mountTask?.cancel()
            hideTask?.cancel()
        }
    }

    private func resetIfNeeded() {
        guard activeLoadID != loadID else {
            return
        }
        activeLoadID = loadID
        shouldMountContent = false
        showsLoadingOverlay = true
        mountTask?.cancel()
        hideTask?.cancel()

        mountTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, activeLoadID == loadID else {
                return
            }
            withAnimation(.easeOut(duration: 0.12)) {
                shouldMountContent = true
            }
        }
    }

    private func scheduleLoadingDismissal(for id: String) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, activeLoadID == id else {
                return
            }
            withAnimation(.easeOut(duration: 0.16)) {
                showsLoadingOverlay = false
            }
        }
    }
}

private struct WindowAttachedCanvasHost<Content: View>: View {
    var loadID: String
    var backgroundColor: Color
    var loadingLabel: String
    @ViewBuilder var content: Content

    @State private var activeLoadID: String?
    @State private var isAttachedToWindow = false
    @State private var shouldMountContent = false
    @State private var showsLoadingOverlay = true
    @State private var mountTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            backgroundColor

            WindowAttachmentObserver(isAttached: $isAttachedToWindow)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            if shouldMountContent {
                content
                    .transition(.opacity)
                    .onAppear {
                        scheduleLoadingDismissal(for: loadID)
                    }
            }

            if showsLoadingOverlay {
                CanvasLoadingOverlay(label: loadingLabel, accessibilityLabel: loadingLabel)
                    .transition(.opacity)
            }
        }
        .onAppear {
            resetIfNeeded()
            scheduleMountIfReady()
        }
        .onChange(of: loadID) { _, _ in
            resetIfNeeded()
            scheduleMountIfReady()
        }
        .onChange(of: isAttachedToWindow) { _, _ in
            scheduleMountIfReady()
        }
        .onDisappear {
            mountTask?.cancel()
            hideTask?.cancel()
        }
    }

    private func resetIfNeeded() {
        guard activeLoadID != loadID else {
            return
        }
        activeLoadID = loadID
        shouldMountContent = false
        showsLoadingOverlay = true
        mountTask?.cancel()
        hideTask?.cancel()
    }

    private func scheduleMountIfReady() {
        guard isAttachedToWindow,
              activeLoadID == loadID,
              !shouldMountContent else {
            return
        }

        mountTask?.cancel()
        mountTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  activeLoadID == loadID,
                  isAttachedToWindow else {
                return
            }
            withAnimation(.easeOut(duration: 0.12)) {
                shouldMountContent = true
            }
        }
    }

    private func scheduleLoadingDismissal(for id: String) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, activeLoadID == id else {
                return
            }
            withAnimation(.easeOut(duration: 0.16)) {
                showsLoadingOverlay = false
            }
        }
    }
}

private struct WindowAttachmentObserver: NSViewRepresentable {
    @Binding var isAttached: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onAttachmentChange = { isAttached in
            self.isAttached = isAttached
        }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onAttachmentChange = { isAttached in
            self.isAttached = isAttached
        }
        nsView.reportAttachment()
    }

    final class ObservingView: NSView {
        var onAttachmentChange: ((Bool) -> Void)?
        private var lastReportedAttachment: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportAttachment()
        }

        func reportAttachment() {
            let isAttached = window != nil
            guard lastReportedAttachment != isAttached else {
                return
            }
            lastReportedAttachment = isAttached
            Task { @MainActor [weak self] in
                self?.onAttachmentChange?(isAttached)
            }
        }
    }
}

private struct CanvasLoadingOverlay: View {
    var label: String
    var accessibilityLabel: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)

            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.1), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct PaneInformationPanel: View {
    var summary: NavigatorSelectionSummary
    var projectMetadataRows: [ProjectMetadataRow] = []
    var isProjectMetadataEditable = false
    var onProjectMetadataChange: (String, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !projectMetadataRows.isEmpty {
                        ProjectMetadataEditorView(
                            rows: projectMetadataRows,
                            isEditable: isProjectMetadataEditable,
                            onChange: onProjectMetadataChange
                        )

                        Divider()
                    }

                    NavigatorSelectionSummaryView(summary: summary, usesSystemValueText: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(14)
        .frame(width: 400)
        .frame(maxHeight: 520)
    }
}

private struct ProjectMetadataEditorView: View {
    var rows: [ProjectMetadataRow]
    var isEditable: Bool
    var onChange: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project Metadata")
                .font(.body.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.title)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 104, alignment: .leading)

                        TextField(row.title, text: Binding(
                            get: { row.value },
                            set: { onChange(row.key, $0) }
                        ))
                        .font(.body)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!isEditable)
                    }
                }
            }
        }
    }
}

private struct ThreeDViewPresetRailButtons: View {
    var board: HorizontalBoard?
    @Binding var displayOptions: BoardDisplayOptions
    @Binding var cameraState: HorizontalSceneCameraState?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(HorizontalBoard3DViewPreset.allCases) { preset in
                HorizontalRailHelpLabel(title: preset.title) {
                    Button {
                        applyViewPreset(preset)
                    } label: {
                        Image(systemName: preset.systemImage)
                    }
                    .disabled(board == nil)
                    .help(preset.title)
                }
            }
        }
    }

    private func applyViewPreset(_ preset: HorizontalBoard3DViewPreset) {
        guard let board else {
            return
        }
        displayOptions.threeDProjection = preset.projection
        cameraState = horizonSceneCameraState(for: preset, board: board)
    }
}

private struct ThreeDViewControlsButton: View {
    var board: HorizontalBoard?
    @Binding var displayOptions: BoardDisplayOptions
    @Binding var cameraState: HorizontalSceneCameraState?

    @State private var isControlsPresented = false

    var body: some View {
        HorizontalRailHelpLabel(title: "3D Board controls") {
            Button {
                isControlsPresented.toggle()
            } label: {
                Image(systemName: isControlsPresented ? "cube.fill" : "cube")
            }
            .help("3D Board controls")
            .popover(isPresented: $isControlsPresented, arrowEdge: .trailing) {
                ThreeDViewControlsPanel(
                    board: board,
                    displayOptions: $displayOptions,
                    cameraState: $cameraState
                )
            }
        }
    }
}

private struct ThreeDViewControlsPanel: View {
    var board: HorizontalBoard?
    @Binding var displayOptions: BoardDisplayOptions
    @Binding var cameraState: HorizontalSceneCameraState?

    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    var body: some View {
        LayerControlsPanel(title: "3D Controls") {
            VStack(alignment: .leading, spacing: 11) {
                explodeControl
                colorToggleRow(
                    "Solder mask",
                    isOn: $displayOptions.solderMask,
                    color: appearanceSettings.boardSceneSolderMaskColorBinding()
                )
                solderMaskTransparencyControl
                colorToggleRow(
                    "Silkscreen",
                    isOn: $displayOptions.silkscreen,
                    color: appearanceSettings.boardSceneSilkscreenColorBinding()
                )
                BoardDisplayToggle(title: "Solder paste", isOn: $displayOptions.paste)
                colorToggleRow(
                    "Substrate",
                    isOn: $displayOptions.boardBody,
                    color: appearanceSettings.boardSceneSubstrateColorBinding()
                )
                segmentedPickerRow("Copper", selection: copperModeBinding) {
                    ForEach(HorizontalBoardSceneCopperMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                viaPlatingControl
                modelModeControl
                colorToggleRow(
                    "Background",
                    isOn: $displayOptions.threeDBackground,
                    color: appearanceSettings.boardSceneBackgroundColorBinding()
                )
                segmentedPickerRow("Projection", selection: projectionBinding) {
                    ForEach(HorizontalBoardSceneProjection.allCases) { projection in
                        Text(projection.title).tag(projection)
                    }
                }
            }
        }
    }

    private var explodeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Explode")
                Spacer()
                Text(String(format: "%.1f mm", displayOptions.threeDExplode))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $displayOptions.threeDExplode, in: 0...12, step: 0.25)
        }
    }

    private var solderMaskTransparencyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Solder mask transparency")
                Spacer()
                Text("\((displayOptions.threeDSolderMaskTransparency * 100).formatted(.number.precision(.fractionLength(0))))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: solderMaskTransparencyBinding, in: 0...1, step: 0.01)
                .disabled(!displayOptions.solderMask)
        }
    }

    private var viaPlatingControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Via plating")
                Spacer()
                Text("\(displayOptions.threeDViaPlatingMicrons.formatted(.number.precision(.fractionLength(0)))) µm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField(
                    "Via plating",
                    value: viaPlatingBinding,
                    format: .number.precision(.fractionLength(0))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
                Text("µm")
                    .foregroundStyle(.secondary)
                Stepper("Via plating", value: viaPlatingBinding, in: 0...250, step: 1)
                    .labelsHidden()
            }
            Text("Applies to via wall thickness and top/bottom protrusion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var viaPlatingBinding: Binding<Double> {
        Binding {
            displayOptions.threeDViaPlatingMicrons
        } set: { value in
            displayOptions.threeDViaPlatingMicrons = value.clamped(to: 0...250)
        }
    }

    private var solderMaskTransparencyBinding: Binding<Double> {
        Binding {
            displayOptions.threeDSolderMaskTransparency
        } set: { value in
            displayOptions.threeDSolderMaskTransparency = value.clamped(to: 0...1)
        }
    }

    private var modelModeControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("3D Models")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                ForEach(HorizontalBoardSceneModelMode.allCases) { mode in
                    let isSelected = displayOptions.threeDModelMode == mode
                    Button {
                        modelModeBinding.wrappedValue = mode
                    } label: {
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 0.75)
                    }
                }
            }
            .padding(3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.75)
            }
        }
    }

    private var copperModeBinding: Binding<HorizontalBoardSceneCopperMode> {
        $displayOptions.threeDCopperMode
    }

    private var modelModeBinding: Binding<HorizontalBoardSceneModelMode> {
        Binding {
            displayOptions.threeDModelMode
        } set: { mode in
            displayOptions.threeDModelMode = mode
            displayOptions.threeDModels = mode != .none
        }
    }

    private var projectionBinding: Binding<HorizontalBoardSceneProjection> {
        Binding {
            displayOptions.threeDProjection
        } set: { projection in
            displayOptions.threeDProjection = projection
            syncCameraStateProjection(projection)
        }
    }

    private func syncCameraStateProjection(_ projection: HorizontalBoardSceneProjection) {
        guard let board else {
            return
        }

        let orthographicScale = projection == .orthogonal
            ? (cameraState?.orthographicScale ?? horizonSceneDefaultOrthographicScale(for: board))
            : nil

        if let cameraState, cameraState.isValid {
            self.cameraState = HorizontalSceneCameraState(
                transform: cameraState.transform,
                orthographicScale: orthographicScale
            )
        } else {
            let fallback = horizonSceneCameraState(for: .defaultPerspective, board: board)
            self.cameraState = HorizontalSceneCameraState(
                transform: fallback.transform,
                orthographicScale: orthographicScale
            )
        }
    }

    private func colorToggleRow(_ title: String, isOn: Binding<Bool>, color: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
            Spacer()
            ColorPicker(title, selection: color, supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func segmentedPickerRow<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                content()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

}

private struct NavigatorRow: View {
    var icon: String
    var title: String
    var detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NavigatorMetricRow: View {
    var title: String
    var value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct NavigatorValueRow: View {
    var title: String
    var value: String
    var usesSystemValueText = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(usesSystemValueText ? .body.monospacedDigit() : .caption.monospacedDigit())
                .foregroundStyle(usesSystemValueText ? .primary : .secondary)
        }
    }
}

private struct NavigatorColorRow: View {
    var title: String
    var color: HorizontalRGBColor

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(color.color)
                .frame(width: 18, height: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(.secondary.opacity(0.35), lineWidth: 0.5)
                }
            Text(color.hexString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Standard window chrome by default — the title bar draws the system toolbar
/// background over the canvas. With the Transparent Toolbar preference on, that
/// background goes away and the canvas shows through.
///
/// `.fullSizeContentView` stays on either way. It is what keeps the toolbar
/// laid out across the split columns — sidebar toggle over the navigator, title
/// at the leading edge of the detail, controls at its trailing edge. Dropping
/// it for the opaque case rearranged every item into one packed row, so the two
/// states differed in layout and not just in background.
private struct WindowChromeConfigurator: NSViewRepresentable {
    var isTransparent: Bool

    func makeNSView(context: Context) -> ConfiguringView {
        let view = ConfiguringView()
        view.isTransparent = isTransparent
        return view
    }

    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.isTransparent = isTransparent
        nsView.configureWindow()
    }

    final class ConfiguringView: NSView {
        var isTransparent = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else {
                return
            }

            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = isTransparent
        }
    }
}

private struct WindowSizeObserver: NSViewRepresentable {
    var savedSize: HorizontalWindowSize?
    var onSizeChange: (HorizontalWindowSize) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.savedSize = savedSize
        view.onSizeChange = onSizeChange
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.savedSize = savedSize
        nsView.onSizeChange = onSizeChange
        nsView.scheduleConfigureWindow()
    }

    final class ObservingView: NSView {
        var savedSize: HorizontalWindowSize?
        var onSizeChange: ((HorizontalWindowSize) -> Void)?

        private var didRestoreSize = false
        private var resizeObserver: NSObjectProtocol?
        private var configureTask: Task<Void, Never>?
        private var lastReportedSize: HorizontalWindowSize?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfigureWindow()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeResizeObserver()
                configureTask?.cancel()
                configureTask = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func scheduleConfigureWindow() {
            configureTask?.cancel()
            configureTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else {
                    return
                }
                self?.configureWindow()
            }
        }

        func configureWindow() {
            guard let window else {
                return
            }

            restoreSizeIfNeeded(window)
            configureResizeObserver(for: window)
            report(window.frame.size)
        }

        private func restoreSizeIfNeeded(_ window: NSWindow) {
            guard !didRestoreSize else {
                return
            }

            didRestoreSize = true
            guard let savedSize, savedSize.isValid else {
                return
            }

            let width = max(savedSize.width, 980)
            let height = max(savedSize.height, 640)
            var frame = window.frame
            guard abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 else {
                return
            }

            let top = frame.maxY
            frame.size = NSSize(width: width, height: height)
            frame.origin.y = top - height
            window.setFrame(frame, display: false)
        }

        private func configureResizeObserver(for window: NSWindow) {
            if resizeObserver != nil {
                return
            }

            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else {
                        return
                    }

                    self.report(window.frame.size)
                }
            }
        }

        private func removeResizeObserver() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
        }

        private func report(_ size: CGSize) {
            let state = HorizontalWindowSize(width: Double(size.width), height: Double(size.height))
            guard state.isValid, state != lastReportedSize else {
                return
            }

            lastReportedSize = state
            onSizeChange?(state)
        }
    }
}

private func horizonSizeString(_ bounds: HorizontalRect) -> String {
    "\(horizonLengthString(bounds.width)) x \(horizonLengthString(bounds.height))"
}

private func horizonAreaString(_ value: Double) -> String {
    let squareMillimeters = value / 1_000_000_000_000
    return "\(squareMillimeters.formatted(.number.precision(.fractionLength(2)))) mm^2"
}

private func gridSpacingString(_ grid: HorizontalGridSettings) -> String {
    if grid.mode == "rect", grid.spacing.x != grid.spacing.y {
        return "\(horizonLengthString(grid.spacing.x)) x \(horizonLengthString(grid.spacing.y))"
    }
    return horizonLengthString(grid.spacing.x)
}

private extension HorizontalRGBColor {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var hexString: String {
        let red = Int((self.red * 255).rounded()).clamped(to: 0...255)
        let green = Int((self.green * 255).rounded()).clamped(to: 0...255)
        let blue = Int((self.blue * 255).rounded()).clamped(to: 0...255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

struct ViewerPane<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        content
    }
}

struct MissingPaneView: View {
    var message: String

    var body: some View {
        ContentUnavailableView(message, systemImage: "doc.questionmark")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
