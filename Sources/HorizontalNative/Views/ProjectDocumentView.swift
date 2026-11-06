#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI

struct ProjectDocumentView: View {
    let configuration: FileDocumentConfiguration<HorizontalProjectDocument>
    @Binding var document: HorizontalProjectDocument

    @State private var state = ProjectLoadState.loading
    /// The project a new document was loaded from until its first save: the
    /// copy in a temporary folder.
    @State private var untitledProjectURL: URL?
    /// What the workspace was made for, the loaded project's URL. A first
    /// save moves the project without making a new workspace, so this keeps
    /// the temporary folder's.
    @State private var workspaceIdentity: URL?
    @State private var visiblePanes: Set<HorizontalPane> = [.schematic, .board]
    @State private var selectedNetIDs = Set<String>()
    @State private var highlightedNetIDs = Set<String>()
    @State private var selectedComponentIDs = Set<String>()
    @State private var highlightedComponentIDs = Set<String>()
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    /// The canvas chrome the window wears: the schematic palette for symbol
    /// and frame editors, the board palette for everything else.
    private var windowTheme: HorizontalCanvasPalette {
        let kind: HorizontalCanvasKind = switch poolItemCategory {
        case .symbol, .frame: .schematic
        default: .board
        }
        return appearanceSettings.palette(for: kind, colorScheme: colorScheme)
    }

    private var poolItemCategory: HorizontalPoolItemCategory? {
        if case .poolItem(let session) = state {
            return session.category
        }
        return nil
    }

    /// Pool item editors are a form beside a preview, not a two-canvas
    /// workspace, so they don't need the workspace's width.
    private var minimumWindowWidth: CGFloat {
        if case .poolItem = state {
            return 760
        }
        return 980
    }

    /// Pool item editors are ordinary document windows with a standard title
    /// bar. The form editors (unit, entity, part) sit on the system window
    /// background; the canvas editors keep the canvas chrome, like the board
    /// and schematic editors they are modes of.
    private var isPoolItemWindow: Bool {
        poolItemCategory != nil
    }

    private var isPoolFormWindow: Bool {
        switch poolItemCategory {
        case .unit, .entity, .part: true
        default: false
        }
    }

    var body: some View {
        content
            .frame(minWidth: minimumWindowWidth, minHeight: 640)
            .background(WindowChromeConfigurator(
                isTransparent: appearanceSettings.isToolbarTransparent && !isPoolItemWindow,
                usesStandardTitleBar: isPoolItemWindow
            ))
            .containerBackground(
                isPoolFormWindow ? AnyShapeStyle(.background) : AnyShapeStyle(windowTheme.background),
                for: .window
            )
            .toolbarBackgroundVisibility(
                appearanceSettings.isToolbarTransparent && !isPoolItemWindow ? .hidden : .visible,
                for: .windowToolbar
            )
            .task(id: Self.documentIdentity(configuration.fileURL)) {
                await loadProject()
            }
            // The document holding its `.hprj` alone while it could hold the
            // tree: unlocking mid-session (the toolbar lock or the Settings
            // toggle), when a project opened read-only skipped completing its
            // writable archive, and a Revert or a re-read of the file in place,
            // which hands the document the one file again at the same URL, so
            // the task above never runs. Either way, gather the tree again; every
            // edit until then fails on files the archive doesn't have.
            .onChange(of: needsProjectTree) { _, needs in
                if needs {
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
                projectURL: project.url,
                document: $document,
                visiblePanes: $visiblePanes,
                selectedNetIDs: $selectedNetIDs,
                highlightedNetIDs: $highlightedNetIDs,
                selectedComponentIDs: $selectedComponentIDs,
                highlightedComponentIDs: $highlightedComponentIDs
            )
                .id(workspaceIdentity ?? Self.documentIdentity(project.url))
                .navigationTitle(project.displayTitle)
        case .pool(let poolURL):
            HorizontalPoolBrowserView(root: .pool(poolURL))
                .id(poolURL)
                .navigationTitle(HorizontalPoolRegistryStore.poolInfo(at: poolURL).name)
                .navigationSubtitle(poolURL.path)
        case .poolItem(let session):
            HorizontalPoolItemDocumentView(session: session, document: $document)
                .id(session.itemURL)
                .navigationSubtitle(session.subtitle)
        }
    }

    private func highlightSelectedNet() {
        highlightedNetIDs = selectedNetIDs
        highlightedComponentIDs = selectedComponentIDs
    }

    /// AppKit can change a saved document URL's spelling (for example /tmp
    /// and /private/tmp) without changing the document. Rebuilding its
    /// workspace then detaches the live/undo closures from the visible state.
    static func documentIdentity(_ url: URL?) -> URL? {
        url?.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether the document holds only its `.hprj` where it should hold the
    /// project's files: a writable `.hprj` document between being read and
    /// its load gathering the rest, or after AppKit read it again.
    private var needsProjectTree: Bool {
        guard let url = configuration.fileURL, url.pathExtension.caseInsensitiveCompare("hprj") == .orderedSame,
              !appearanceSettings.isReadOnlyOperationEnabled,
              case .regularFile = document.archive.root else { return false }
        return true
    }

    private func loadProject() async {
        guard let url = configuration.fileURL else {
            await loadUntitledProject()
            return
        }
        if moveSavedUntitledProject(to: url) {
            return
        }
        untitledProjectURL = nil

        if Self.isPoolManifest(url) {
            await loadPool(manifestURL: url)
            return
        }
        if case .regularFile(let data) = document.archive.root,
           let category = JSONHelper.poolItemCategory(in: data) {
            await loadPoolItem(url: url, category: category, data: data)
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

        let loadingDocument = document
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
            let archive = try await archiveTask?.value
            guard !Task.isCancelled else { return }
            if let archive, !document.completeLoading(with: archive, from: loadingDocument) {
                // The document changed under the load. Read again into the
                // one file it holds now, or keep the tree a newer load (the
                // file watcher's) put there.
                if case .regularFile = document.archive.root { return await loadProject() }
            }
            workspaceIdentity = Self.documentIdentity(project.url)
            state = .loaded(project)
        } catch {
            guard !Task.isCancelled else { return }
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

    /// A unit, symbol, package, … opened as a document: its editor, once the
    /// pool around it (which its cross-references resolve through) is
    /// readable. The document's bytes are already in the archive, so nothing
    /// is re-read from disk here.
    private func loadPoolItem(url: URL, category: HorizontalPoolItemCategory, data: Data) async {
        state = .loading
        let poolRoot = HorizontalPoolLibrary.poolRoot(forItemURL: url)
        await HorizontalFolderAccessStore.preparePoolItemAccess(for: url, poolRoot: poolRoot)
        guard HorizontalFolderAccessStore.hasPoolItemAccess(for: url, poolRoot: poolRoot) else {
            state = .needsFolderAccess(HorizontalFolderAccessStore.poolItemAccessMessage(for: url, poolRoot: poolRoot))
            return
        }
        do {
            let session = try HorizontalPoolItemEditorSession(
                itemURL: url,
                poolURL: poolRoot,
                category: category,
                data: data
            )
            state = .poolItem(session)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// File > New: the document has no URL until its first save, so materialize
    /// the in-memory template archive in a temporary folder and load from there
    /// (the iPad view does the same for URL-less documents). The archive is
    /// already a complete package, so there is no folder-access or
    /// `completeProject` step; the first save writes it wherever the user
    /// chooses, and the project moves there (`moveSavedUntitledProject`).
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
            untitledProjectURL = project.url
            workspaceIdentity = Self.documentIdentity(project.url)
            state = .loaded(project)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// A new document's first save wrote the files the window shows, so the
    /// project moves to them where it is: the workspace keeps its canvases,
    /// tools and undo, and nothing is read back. A save that wrote anything
    /// but the package the project came from is loaded as any document is.
    private func moveSavedUntitledProject(to url: URL) -> Bool {
        guard let untitledProjectURL, case .loaded(var project) = state,
              Self.documentIdentity(project.url) == Self.documentIdentity(untitledProjectURL),
              url.pathExtension.caseInsensitiveCompare("horizontal") == .orderedSame,
              case .directory = document.archive.root,
              FileManager.default.fileExists(
                atPath: HorizontalProject.file(project.projectFileURL, movedFrom: project.url, to: url).path
              ) else {
            return false
        }
        self.untitledProjectURL = nil
        // The workspace follows `project.url` and moves its own project,
        // whose design has moved on since it was loaded; this one names the
        // window.
        project.move(to: url)
        state = .loaded(project)
        return true
    }
}

private enum ProjectLoadState {
    case loading
    case loaded(HorizontalProject)
    /// A pool.json opened as a document: the library browser on its folder.
    case pool(URL)
    /// A pool item (unit, symbol, package, …) opened as a document: its editor.
    case poolItem(HorizontalPoolItemEditorSession)
    case failed(String)
    /// The sandbox can't read the folder holding a bare `.hprj`'s siblings.
    /// Distinct from `.failed` so it can explain the grant and offer to ask for
    /// it again, rather than reading as a corrupt or unsupported project.
    case needsFolderAccess(String)
}

/// The files changed on disk while the document had edits it hadn't written.
private struct HorizontalDiskConflict {
    /// What the files hold, to accept if the document keeps its own version.
    var fingerprint: HorizontalProjectFingerprint
    /// Lets the document's held saves go ahead.
    var releaseSaves: () -> Void
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

struct WorkspaceKeyCommandMonitor: NSViewRepresentable {
    var onFind: () -> Void
    var onDistractionFree: () -> Void
    var onHighlightSelection: () -> Void
    var onUpdateAllPlanes: () -> Void
    var onClearAllPlanes: () -> Void
    var onControlKeyboardFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> KeyCommandMonitorView {
        let view = KeyCommandMonitorView()
        view.onFind = onFind
        view.onDistractionFree = onDistractionFree
        view.onHighlightSelection = onHighlightSelection
        view.onUpdateAllPlanes = onUpdateAllPlanes
        view.onClearAllPlanes = onClearAllPlanes
        view.onControlKeyboardFocusChange = onControlKeyboardFocusChange
        return view
    }

    func updateNSView(_ nsView: KeyCommandMonitorView, context: Context) {
        nsView.onFind = onFind
        nsView.onDistractionFree = onDistractionFree
        nsView.onHighlightSelection = onHighlightSelection
        nsView.onUpdateAllPlanes = onUpdateAllPlanes
        nsView.onClearAllPlanes = onClearAllPlanes
        nsView.onControlKeyboardFocusChange = onControlKeyboardFocusChange
    }

    final class KeyCommandMonitorView: NSView {
        var onFind: (() -> Void)?
        var onDistractionFree: (() -> Void)?
        var onHighlightSelection: (() -> Void)?
        var onUpdateAllPlanes: (() -> Void)?
        var onClearAllPlanes: (() -> Void)?
        /// Whether a text field or a list (the Pools pane's table, the
        /// navigator) has the keyboard, so the canvas's keyboard-focus badge
        /// can stand down: the keys go to one or the other, never both.
        var onControlKeyboardFocusChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var firstResponderObservation: NSKeyValueObservation?
        private var reportedControlFocus: Bool?

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
            guard let window else {
                return
            }

            // Reported on the next turn: focus moves in the middle of view
            // updates, and the field editor takes over from its field.
            firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportControlFocus() }
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      event.window === self.window else {
                    return event
                }

                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let characters = event.charactersIgnoringModifiers?.lowercased()

                if characters == "l", modifiers.isEmpty, !self.isControlActive {
                    self.onHighlightSelection?()
                    return nil
                }

                // Q and ⇧Q, the Design menu's Update and Clear All Planes. As
                // menu shortcuts they would take Q from every text field, and
                // from a list's type-select.
                if characters == "q", modifiers.isEmpty || modifiers == .shift, !self.isControlActive {
                    (modifiers.isEmpty ? self.onUpdateAllPlanes : self.onClearAllPlanes)?()
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

        /// A text field, selected text or a list has the keyboard, and with
        /// it its keys.
        private var isControlActive: Bool {
            HorizontalKeyboardResponder(window?.firstResponder).isControl
        }

        private func reportControlFocus() {
            let focused = window != nil && isControlActive
            guard focused != reportedControlFocus else { return }
            reportedControlFocus = focused
            onControlKeyboardFocusChange?(focused)
        }

        private func removeMonitor() {
            firstResponderObservation = nil
            reportedControlFocus = nil
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
    /// Where the document's files are: the project's own URL, until a new
    /// document's first save moves them out of their temporary folder.
    let projectURL: URL
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
    /// The board rail's airwire filter popover, which Design ▸ Filter
    /// Airwires… opens too.
    @State private var isBoardAirwireFilterPresented = false
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
    /// Canvases `selectComponents` just changed on another view's behalf.
    /// Their next selection report is the one they were given (104).
    @State private var crossProbedPanes = Set<HorizontalPane>()
    @State private var selectionPropertyChangeCommands = [HorizontalPane: HorizontalSelectionPropertyChangeCommand]()
    @State private var schematicNetSegmentSelection: HorizontalNetSegmentSelectionSidebarState?
    @State private var schematicNetSegmentSelectionCommand: HorizontalNetSegmentSelectionCommand?
    @State private var schematicDrawingToolCommand: HorizontalDrawingToolCommand?
    @State private var schematicDrawNetLineCommand: HorizontalDrawNetLineCommand?
    @State private var boardDrawingToolCommand: HorizontalDrawingToolCommand?
    @State private var boardDrawTrackCommand: HorizontalDrawTrackCommand?
    /// Fed by the board canvas while a track is routed, and shown in the
    /// sidebar. Plain state, not observed here, so a cursor move redraws the
    /// sidebar and not the window.
    @State private var routeInspector = HorizontalRouteInspectorModel()
    @State private var routeWidthCommand: HorizontalRouteWidthCommand?
    /// Bumped when the board's rules change without a reload, for the canvas.
    @State private var boardRulesRevision = 0
    /// Bumped with `boardRulesRevision` when applying the new rules changed
    /// the board, for the canvas to draw it again.
    @State private var boardRuleShapeRevision = 0
    /// The pane the open sidebar showed before routing turned it to the route
    /// inspector, put back when the route ends; nil when routing didn't turn
    /// it, or the sidebar was changed by hand since.
    @State private var sidebarBeforeRouting: SidebarBeforeRouting?
    /// Routing's start was seen, so the sidebar turns once per route even
    /// when the start is reported again.
    @State private var seesRouting = false
    /// Puts the sidebar's pane back a moment after a route ends, so it
    /// doesn't flip back and forth between one route and the next.
    @State private var sidebarRestoreTask: Task<Void, Never>?
    @StateObject private var boardRulesUndoTarget = HorizontalUndoTarget<JSONDictionary>()
    @StateObject private var boardToolSettings = HorizontalBoardToolSettings()
    @State private var boardDrawingLayer = HorizontalBoardLayers.topCopper
    /// Set while a single layer is soloed (the working layer's number pressed a
    /// second time). Nil is the normal, un-soloed state.
    @State private var soloedBoardLayer: Int?
    @State private var pendingPartPlacement: HorizontalPartPlacementRequest?
    /// The Pools pane's Place on a decal, for the board canvas to take up.
    @State private var pendingDecalPlacement: HorizontalBoardDecalPlacementRequest?
    @State private var pendingBlockPlacement: HorizontalBlockPlacementRequest?
    /// Horizon's instance path, as far as pushing into blocks goes: each
    /// block opened from a block symbol, with the sheet it was opened from,
    /// so Leave Block goes back there.
    @State private var blockTrail: [BlockTrailStep] = []
    /// The block symbol editor wrote the symbol since the sheets were baked.
    @State private var blockSymbolNeedsReload = false
    @State private var annotatePopoverPresented = false
    /// The project's parts against their pools, for the Parts pane, the
    /// updates sheet and the info bar that says when they fall behind.
    @StateObject private var partLibrary = HorizontalPartLibraryMonitor()
    @State private var showsPartUpdates = false
    /// A copy of a part into an attached pool, waiting on its confirmation.
    @State private var pendingPoolCopy: HorizontalPoolPartCopy?
    /// What Move to Other Sheet took across, for the canvas to pick up there.
    @State private var pendingSchematicMove: HorizontalSchematicMoveRequest?
    @State private var canvasCommandActionsByPane = [HorizontalPane: HorizontalCanvasCommandActions]()
    @State private var activeCanvasCommandPane: HorizontalPane?
    /// The project pool cleanup on show, reviewed when it opened.
    @State private var poolCleanupReview: HorizontalPoolCacheCleanupReview?
    /// A text field or a list has the keyboard, so no canvas shows the
    /// keyboard-focus badge.
    @State private var isKeyboardInControl = false
    @State private var rightSidebarPane: HorizontalWorkspaceRightSidebar?
    @State private var rulesResultsState: HorizontalBoardRulesResultState?
    /// The rules results sidebar's closed sections, whose findings the
    /// canvases don't mark.
    @State private var collapsedRuleSections = Set<String>()
    /// The copper clearance check the results sidebar is waiting on.
    @State private var clearanceCheckTask: Task<Void, Never>?
    @State private var schematicCheckTask: Task<Void, Never>?
    @State private var exportSettings: HorizontalExportSettings
    @State private var exportStatus: HorizontalExportStatus?
    @State private var isExporting = false
    @State private var didRestoreFileViewState = false
    @State private var fileViewStateSaveTask: Task<Void, Never>?
    @State private var boardSyncRevision = 0
    /// Bumped when "Update All Planes" lands, so the board canvas re-clips its
    /// silkscreen then rather than on every edit.
    @State private var planePourRevision = 0
    /// Counts every change to `project.board`'s content, so the 3D view
    /// knows to rebuild its scene (lazily, in the background).
    @State private var boardEditRevision = 0
    /// Bumped by every schematic mutation, for the live channel's change
    /// detection (the board has its own two counters).
    @State private var schematicEditRevision = 0
    /// External replacements only: a canvas's own edit must not cancel its tool.
    @State private var schematicSyncRevision = 0
    /// The live channel's handle for this document (docs/automation.md).
    @State private var liveHandle: Int?
    /// Watches the project's files for changes something other than this
    /// document makes, such as a git checkout (item 121).
    @State private var fileWatcher: HorizontalProjectFileWatcher?
    /// The files changed on disk while the document had edits it hadn't
    /// written yet: the window asks which to keep, and saves wait for the answer.
    @State private var diskConflict: HorizontalDiskConflict?
    /// Why the files that changed on disk couldn't be loaded.
    @State private var diskReloadError: String?
    @StateObject private var voiceControl = HorizontalVoiceControl()
    @StateObject private var liveUndoTarget = HorizontalUndoTarget<HorizontalLiveSnapshot>()
    /// The board's netlist reload from the schematic, waiting for edits to
    /// settle or running; see `scheduleBoardNetlistSync`.
    @State private var boardNetlistSyncTask: Task<Void, Never>?
    @State private var boardNetlistSyncRequested = false
    @State private var powerNetsPopoverPresented = false
    /// "Show in Project Pool Manager": the item the Library pane should select.
    @State private var libraryRevealRequest: HorizontalPoolRevealRequest?
    @State private var libraryPlacementError: String?
    /// The selected components as the Pools pane's Replace sees them, read
    /// from the archive when the selection or the schematic changes, and only
    /// while the pane is open.
    @State private var libraryPartReplacement: HorizontalPartReplacement?
    @State private var libraryReplacementError: String?
    /// Why a bus, ripper or net tie could not be drawn — the editor's own
    /// refusal, which is written for whoever has to fix the request.
    @State private var projectEditError: String?
    /// Why a schematic edit was not made: a net merge Horizon refuses, a
    /// command with nothing it can apply to.
    @State private var schematicEditMessage: String?
    /// Horizon's info bar for a `.gitignore` missing its recommended lines,
    /// shown once when the document opens.
    @State private var gitignoreNeedsFixing = false
    /// Pours the planes off the main thread: on Q and plane edits, and after
    /// every change when they update automatically.
    @StateObject private var planePourScheduler = HorizontalPlanePourScheduler()
    @AppStorage(HorizontalPlaneFillDefaults.updatesAutomaticallyKey) private var updatesPlanesAutomatically = false
    /// The rules checks run again on every change; off, when asked.
    @AppStorage(HorizontalRulesCheckDefaults.checksAutomaticallyKey) private var checksRulesAutomatically = true
    /// The board changed in a way that invalidates the current fills. Set from
    /// the edit funnel rather than recomputed while rendering, so the (whole
    /// board) fingerprint is taken once per edit instead of once per frame.
    @State private var planesNeedUpdate = false
    /// What the board's fills were poured from
    /// (`HorizontalBoardPlaneInputs.signature`): nil until the board is
    /// first seen, when the fills its files hold are taken to be its own.
    @State private var pouredPlaneInputs: Int?
    /// The `boardEditRevision` whose fills were last checked, so a change
    /// that asked for its pour directly is not checked again.
    @State private var checkedPlaneInputsRevision: Int?
    /// The newest pour's fills for the board canvas, which takes them in
    /// without being reset. `planeFillRevision` counts them.
    @State private var planeFillDelivery: HorizontalPlaneFillDelivery?
    @State private var planeFillRevision = 0
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
    /// Horizon's Length Tuning list, kept while the document is open, and
    /// its window.
    @StateObject private var lengthTuning = HorizontalLengthTuningModel()
    @State private var lengthTuningWindowController: HorizontalLengthTuningWindowController?
    @StateObject private var boardUndoTarget = HorizontalUndoTarget<HorizontalBoard>()
    @Environment(\.undoManager) private var documentUndoManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(
        project: HorizontalProject,
        projectURL: URL? = nil,
        document: Binding<HorizontalProjectDocument>,
        visiblePanes: Binding<Set<HorizontalPane>>,
        selectedNetIDs: Binding<Set<String>>,
        highlightedNetIDs: Binding<Set<String>>,
        selectedComponentIDs: Binding<Set<String>>,
        highlightedComponentIDs: Binding<Set<String>>
    ) {
        let fileViewState = HorizontalFileViewStateStore.shared.load(for: project.url, projectID: project.uuid)
        _project = State(initialValue: project)
        self.projectURL = projectURL ?? project.url
        _document = document
        _visiblePanes = visiblePanes
        _selectedNetIDs = selectedNetIDs
        _highlightedNetIDs = highlightedNetIDs
        _selectedComponentIDs = selectedComponentIDs
        _highlightedComponentIDs = highlightedComponentIDs
        _columnVisibility = State(initialValue: Self.initialColumnVisibility(fileViewState: fileViewState, project: project))
        _schematicDisplayOptions = State(initialValue: fileViewState?.schematicDisplayOptions ?? SchematicDisplayOptions())
        _boardDisplayOptions = State(initialValue: BoardDisplayOptions.opening(fileViewState?.boardDisplayOptions))
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
        workspaceWithViewStateObservers
    }

    /// SwiftUI type-checks a modifier chain as a single expression, and this
    /// one — fifteen scene values, thirteen observers, the window monitors —
    /// grew past what the Xcode 26 toolchain would finish, so CI failed to
    /// build while ours still (just) got through at about ten seconds for the
    /// one expression. The slices below apply in the same order the one chain
    /// did; each is its own expression, so each is type-checked on its own.
    private var workspaceWithFocusedValues: some View {
        workspaceContentWithAlerts
            .onReceive(
                NotificationCenter.default.publisher(for: HorizontalPoolLibrary.itemDidSaveNotification)
                    .receive(on: RunLoop.main)
            ) { notification in
                if let payload = notification.userInfo?[HorizontalPoolLibrary.itemDidSavePayloadKey]
                    as? HorizontalPoolLibrary.ItemDidSavePayload {
                    handlePoolItemSaved(payload)
                }
            }
            .focusedSceneValue(\.horizonBoardDisplayOptions, $boardDisplayOptions)
            .focusedSceneValue(\.horizonBoardAvailable, project.board != nil)
            .focusedSceneValue(\.horizonReadOnlyOperation, isReadOnly)
            .focusedSceneValue(\.horizonSchematicDisplayOptions, $schematicDisplayOptions)
            .focusedSceneValue(\.horizonSchematicAvailable, selectedSchematicAvailable)
    }

    /// The actions the menu bar sends back to this document.
    private var workspaceWithSceneActions: some View {
        workspaceWithFocusedValues
            .focusedSceneValue(\.horizonDocumentViewActions, documentViewActions)
            .focusedSceneValue(\.horizonCanvasCommandActions, activeCanvasCommandActions)
            .focusedSceneValue(\.horizonFindAction, activateFind)
            .focusedSceneValue(\.horizonListenAction, HorizontalVoiceControl.isAvailable ? { voiceControl.toggle() } : nil)
            .focusedSceneValue(\.horizonDistractionFreeMode, $isDistractionFree)
            .focusedSceneValue(\.horizonWindowToolbarHidden, $isWindowToolbarHidden)
    }

    private var workspaceWithBoardSceneActions: some View {
        workspaceWithSceneActions
            .focusedSceneValue(\.horizonToggleRightSidebarAction, { toggleRightSidebar(.selection) })
            .focusedSceneValue(\.horizonUpdateAllPlanesAction, updateAllBoardPlanes)
            .focusedSceneValue(\.horizonPowerNetsAction, showPowerNets)
            .focusedSceneValue(\.horizonLeaveBlockAction, canLeaveBlock ? { leaveBlock() } : nil)
            .focusedSceneValue(\.horizonClearAllPlanesAction, clearAllBoardPlanes)
            .focusedSceneValue(\.horizonBoardRulesAction, showBoardRulesWindow)
            .focusedSceneValue(\.horizonLengthTuningActions, lengthTuningActions)
            .onChange(of: boardEditRevision) { _, _ in
                // The window's lengths follow the board, as Horizon updates
                // its tuning window on every canvas update.
                lengthTuning.update(board: project.board)
            }
            .focusedSceneValue(\.horizonCleanUpProjectPoolAction, poolCleanupAction)
            .sheet(isPresented: Binding(get: { poolCleanupReview != nil }, set: { if !$0 { poolCleanupReview = nil } })) {
                if let poolCleanupReview {
                    HorizontalPoolCleanupSheet(review: poolCleanupReview, isReadOnly: isReadOnly, onRemove: cleanUpProjectPool)
                }
            }
    }

    /// An open sidebar shows the route inspector while a track is routed,
    /// and goes back to what it showed when the route ends.
    private var workspaceWithRouteInspector: some View {
        workspaceWithBoardSceneActions
            .onReceive(routeInspector.$isRouting.removeDuplicates()) { isRouting in
                routingChanged(isRouting)
            }
            .onChange(of: rightSidebarPane) { _, pane in
                // Changed by hand while routing: it stays as it was left.
                if sidebarBeforeRouting != nil, pane != .selection {
                    sidebarBeforeRouting = nil
                }
            }
    }

    /// The parts review: kept current as the design and its pools change,
    /// and the updates sheet the Parts pane and the info bar open.
    private var workspaceWithPartLibrary: some View {
        workspaceWithRouteInspector
            .task(id: "\(boardEditRevision):\(schematicEditRevision):\(project.baseURL.path):\(project.poolDirectory ?? ""):\(isReadOnly)") {
                partLibrary.update(partLibraryInputs)
            }
            .sheet(isPresented: $showsPartUpdates) {
                if let review = partLibrary.review {
                    HorizontalPartUpdatesSheet(review: review, isReadOnly: isReadOnly, isRefreshing: partLibrary.isChecking,
                                               onRefresh: partLibrary.recheck, onChooseSource: partLibrary.chooseSource,
                                               onUpdate: updateProjectParts)
                }
            }
            .alert("Library Review", isPresented: Binding(get: { partLibrary.error != nil }, set: { if !$0 { partLibrary.error = nil } })) {
                Button("OK") { partLibrary.error = nil }
            } message: { Text(partLibrary.error ?? "") }
            .alert(pendingPoolCopy.map { "Copy \($0.partName) to \($0.targetName)?" } ?? "",
                   isPresented: Binding(get: { pendingPoolCopy != nil }, set: { if !$0 { pendingPoolCopy = nil } }),
                   presenting: pendingPoolCopy) { copy in
                Button("Copy") { commitPoolCopy(copy) }
                Button("Cancel", role: .cancel) {}
            } message: { copy in
                Text(copy.summary)
            }
    }

    /// The attached pools a part can go to, for one no attached pool has.
    private func poolCopyTargets(forPart partID: String) -> [HorizontalPoolCopyTarget] {
        guard !isReadOnly, let directory = project.poolDirectory,
              partLibrary.review?.parts.first(where: { $0.id.caseInsensitiveCompare(partID) == .orderedSame })?.isInNoAttachedPool == true else {
            return []
        }
        return HorizontalPoolPartCopier.targets(forProjectPool: project.baseURL.appendingPathComponent(directory))
    }

    /// Plans a copy of a part into a pool, for the confirmation to show.
    private func preparePoolCopy(partID: String, to target: URL) {
        guard !isReadOnly, let directory = project.poolDirectory else { return }
        do {
            pendingPoolCopy = try HorizontalPoolPartCopier.plan(
                partID: partID, projectFiles: HorizontalPoolCacheUpdater.files(in: document.archive, poolDirectory: directory),
                projectPoolURL: project.baseURL.appendingPathComponent(directory), into: target)
        } catch {
            partLibrary.error = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    /// Writes the part into the pool, then has the project take it from
    /// there, as one undoable edit of the project.
    private func commitPoolCopy(_ copy: HorizontalPoolPartCopy) {
        guard !isReadOnly, let directory = project.poolDirectory else { return }
        do {
            try HorizontalPoolPartCopier.writePoolFiles(copy)
            var archive = document.archive
            try HorizontalPoolPartCopier.track(copy, in: &archive, poolDirectory: directory,
                                               projectPoolURL: project.baseURL.appendingPathComponent(directory))
            try applyLiveArchive(archive, actionName: "Copy to \(copy.targetName)")
            partLibrary.recheck()
        } catch {
            partLibrary.error = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    private var partLibraryInputs: HorizontalPartLibraryInputs {
        HorizontalPartLibraryInputs(
            poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) },
            files: project.poolDirectory.map { HorizontalPoolCacheUpdater.files(in: document.archive, poolDirectory: $0) } ?? [:],
            references: HorizontalPoolCacheUpdater.references(in: document.archive, project: project),
            partIDs: project.poolParts.map(\.id),
            isReadOnly: isReadOnly
        )
    }

    private var workspaceWithWindowObservers: some View {
        workspaceWithPartLibrary
            .background(WorkspaceKeyCommandMonitor(
                onFind: activateFind,
                onDistractionFree: toggleDistractionFreeMode,
                onHighlightSelection: highlightSelectedNet,
                onUpdateAllPlanes: updateAllBoardPlanes,
                onClearAllPlanes: clearAllBoardPlanes,
                onControlKeyboardFocusChange: { isKeyboardInControl = $0 }
            ))
            .background(WindowSizeObserver(savedSize: windowSize, onSizeChange: updateWindowSize))
            .onAppear(perform: appear)
            .onDisappear(perform: disappear)
            .onChange(of: projectURL) { _, url in
                moveProject(to: url)
            }
    }

    /// What the panes and the window show.
    private var workspaceWithSelectionObservers: some View {
        workspaceWithWindowObservers
            .onChange(of: boardSyncRevision, initial: true) { _, _ in
                rulesInputsChanged()
            }
            // Every change to the board passes here; most asked for their pour
            // already, and this catches the rest.
            .onChange(of: boardEditRevision) { _, _ in
                checkPlaneFills()
                boardChangedForRules()
            }
            // A pour's fills are copper too.
            .onChange(of: planeFillRevision) { _, _ in
                boardChangedForRules()
            }
            .onChange(of: updatesPlanesAutomatically) { _, _ in
                checkPlaneFills(again: true)
            }
            // Turned back on, the checks catch up with what changed while off.
            .onChange(of: checksRulesAutomatically) { _, checksAutomatically in
                if checksAutomatically {
                    refreshRulesResults()
                }
            }
            .onChange(of: isReadOnly) { _, _ in
                checkPlaneFills(again: true)
            }
            .onChange(of: navigatorSelection) { previous, selection in
                syncPanesForSelection(selection)
                refreshLibraryPartReplacement()
                // The sheets drawing the block take up its edited symbol.
                if case .blockSymbol = previous, blockSymbolNeedsReload {
                    reloadProjectFromArchive()
                }
            }
            .onChange(of: visiblePanes) { _, panes in
                clearSelectionDetailsForHiddenPanes(panes)
                saveFileViewState()
                refreshLibraryPartReplacement()
                // A board made afresh would take a still-set decal up again.
                if !panes.contains(.board) {
                    pendingDecalPlacement = nil
                }
            }
            .onChange(of: selectedComponentIDs) { _, _ in
                refreshLibraryPartReplacement()
            }
            .onChange(of: schematicEditRevision) { _, _ in
                refreshLibraryPartReplacement()
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
    }

    /// What is written back to the file's saved view state.
    private var workspaceWithViewStateObservers: some View {
        workspaceWithSelectionObservers
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

    /// Kept off `body`'s modifier chain, which is already as long as the type
    /// checker tolerates.
    private var workspaceContentWithAlerts: some View {
        workspaceContent
            .environment(\.horizonPoolRevealAction, revealInPools)
            .alert("Could Not Place Part", isPresented: libraryPlacementErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(libraryPlacementError ?? "")
            }
            .alert("Could Not Replace Part", isPresented: Binding(
                get: { libraryReplacementError != nil },
                set: { if !$0 { libraryReplacementError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(libraryReplacementError ?? "")
            }
            .alert("Can't Make That Edit", isPresented: Binding(
                get: { schematicEditMessage != nil },
                set: { if !$0 { schematicEditMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(schematicEditMessage ?? "")
            }
            .alert("Could Not Draw That", isPresented: projectEditErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(projectEditError ?? "")
            }
            .alert("“\(project.displayTitle)” Changed on Disk", isPresented: diskConflictPresented) {
                Button("Reload from Disk", role: .destructive) { resolveDiskConflict(reload: true) }
                Button("Keep My Version", role: .cancel) { resolveDiskConflict(reload: false) }
            } message: {
                Text("Another program, such as git, changed the project's files while this window had edits it hadn't saved yet. "
                    + "Reloading takes the files as they are now and discards those edits. Keeping your version saves it over the files' changes.")
            }
            .alert("Couldn't Reload “\(project.displayTitle)”", isPresented: diskReloadErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Its files changed on disk, but they couldn't be loaded: \(diskReloadError ?? ""). "
                    + "The window still shows the project as it was. Close it and open the project again once the files are complete.")
            }
    }

    private var diskConflictPresented: Binding<Bool> {
        Binding(get: { diskConflict != nil }, set: { _ in })
    }

    private var diskReloadErrorPresented: Binding<Bool> {
        Binding(get: { diskReloadError != nil }, set: { if !$0 { diskReloadError = nil } })
    }

    private var workspaceContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectNavigatorView(
                project: project,
                selection: $navigatorSelection,
                searchText: $navigatorSearchText,
                highlightedNetIDs: highlightedNetIDs,
                markedComponentIDs: selectedComponentIDs.union(highlightedComponentIDs),
                highlightColor: appearanceSettings.palette(for: .schematic, colorScheme: colorScheme).junction,
                allowsSheetEditing: !isReadOnly,
                allowsBlockEditing: true,
                onRenameSheet: { schematicURL, sheetID, name in
                    renameSheet(sheetID: sheetID, to: name, schematicURL: schematicURL)
                },
                onReorderSheets: { schematicURL, orderedIDs in
                    reorderSheets(orderedIDs, schematicURL: schematicURL)
                },
                onSetSheetFrame: { schematicURL, sheetID, frame in
                    setSheetFrame(frame, sheetID: sheetID, schematicURL: schematicURL)
                },
                onAddSheet: { schematicURL in
                    addSheet(schematicURL: schematicURL)
                },
                onRemoveSheet: { schematicURL, sheetID in
                    removeSheet(sheetID, schematicURL: schematicURL)
                },
                onAddBlock: { addBlock(named: $0) },
                onRenameBlock: { renameBlock($0, to: $1) },
                onRemoveBlock: { removeBlock($0) },
                onPlaceBlock: selectedSchematic == nil || isReadOnly || isEditingBlockSymbol ? nil : { placeBlock($0) },
                placeableBlockIDs: placeableBlockIDs,
                onSelectComponent: { sheet, componentID, position in
                    showComponent(componentID, at: position, on: sheet)
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

    /// Canvas content always runs up underneath the toolbar, whether or not the
    /// toolbar is transparent; the preference never moves the canvas down, so
    /// the layout is the same in both states. The overlays inside each pane
    /// (tool rails, info buttons) pad themselves down by the top safe-area
    /// inset to clear the bar.
    ///
    /// The pane split sits inside a scroll view that cannot scroll: its content
    /// is exactly the viewport, toolbar strip included. That is what gives the
    /// standard toolbar its background. On macOS 26 and later the title bar
    /// draws nothing of its own over full-size content; the only system-drawn
    /// toolbar background is the scroll-edge effect, and it renders only over a
    /// scroll view's own content — not over a sibling beneath a transparent
    /// scroll view, and not in the hard style unless the content is real. Being
    /// the system's effect, it follows the Liquid Glass and Reduce Transparency
    /// settings and looks the same whether the window is active or not, like
    /// Mail's toolbar. The canvases take their wheel and pinch events through a
    /// local event monitor before the scroll view could see them, and scrolling
    /// is disabled besides. Transparent toolbar: the effect is hidden and the
    /// canvas shows through.
    private var workspaceDetail: some View {
        GeometryReader { proxy in
            // The right sidebar is a real column: opening it pushes the pane
            // split narrower so the rightmost canvas stays fully visible,
            // rather than sliding over and obscuring it.
            let canvasInsets = proxy.safeAreaInsets

            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    splitContent(safeAreaInsets: canvasInsets)
                        .frame(height: proxy.size.height + canvasInsets.top)
                }
                .scrollDisabled(true)
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .scrollEdgeEffectHidden(appearanceSettings.isToolbarTransparent, for: .top)
                .ignoresSafeArea(.container, edges: [.top, .leading])
                .frame(maxWidth: .infinity)

                if let rightSidebarPane {
                    rightSidebarView(rightSidebarPane, safeAreaInsets: canvasInsets)
                        .frame(width: 340)
                        .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
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
            .overlay(alignment: .bottom) {
                HorizontalVoiceTranscriptOverlay(control: voiceControl)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if gitignoreNeedsFixing {
                        gitignoreInfoBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if partLibrary.showsNotice {
                        HorizontalPartLibraryNotice(library: partLibrary) { showsPartUpdates = true }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, canvasInsets.top + 8)
            }
            .animation(.snappy(duration: 0.18), value: gitignoreNeedsFixing)
            .animation(.snappy(duration: 0.18), value: partLibrary.showsNotice)
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
                netSegmentSelection: visiblePanes.contains(.schematic) ? schematicNetSegmentSelection : nil,
                routeInspector: routeInspector,
                showsRoute: visiblePanes.contains(.board),
                toolSettings: boardToolSettings,
                safeAreaInsets: safeAreaInsets,
                foregroundColor: .primary,
                backgroundColor: sidebarTheme.overlayBackground,
                isReadOnly: isReadOnly,
                onChange: applySelectionPropertyChange,
                onNetSegmentSelectionCommand: { command in
                    schematicNetSegmentSelectionCommand = command
                },
                onRouteInspectorCommand: handleRouteInspectorCommand
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
                safeAreaInsets: safeAreaInsets,
                checksAutomatically: $checksRulesAutomatically,
                onCheckNow: project.board == nil ? nil : { refreshRulesResults() },
                onOpenRules: { showBoardRulesWindow() },
                onShowFinding: showBoardFinding,
                onShowRule: { finding in
                    showBoardRulesWindow(focus: finding.kind.map { HorizontalBoardRuleFocus(kind: $0, ruleID: finding.ruleID) })
                },
                onShowSchematicFinding: showSchematicFinding,
                onShowSchematicRule: { showBoardRulesWindow(focus: .schematicConnectivity()) },
                collapsedSections: $collapsedRuleSections
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
                ToolbarFindControl(
                    text: $navigatorSearchText,
                    isPresented: $findIsPresented,
                    activationID: findActivationID
                )

                if HorizontalVoiceControl.isAvailable {
                    HorizontalVoiceControlButton(control: voiceControl)
                }

                paneSelector

                Button {
                    toggleRightSidebar(.selection)
                } label: {
                    Label(selectionSidebarToggleTitle, systemImage: "sidebar.trailing")
                }
                .help(selectionSidebarToggleTitle)
                .accessibilityLabel(selectionSidebarToggleTitle)

                Button {
                    toggleRightSidebar(.rulesResults)
                } label: {
                    Label {
                        Text(rulesResultsSidebarToggleTitle)
                    } icon: {
                        Image(systemName: "checklist.checked")
                            .toolbarBadge(rulesBadgeCount, color: rulesResultsState?.badgeColor ?? .orange)
                    }
                }
                .help(rulesResultsHelp)
                .accessibilityLabel(rulesResultsSidebarToggleTitle)
                .accessibilityValue(rulesResultsHelp)

                Button {
                    toggleRightSidebar(.export)
                } label: {
                    Label(exportSidebarToggleTitle, systemImage: "square.and.arrow.up")
                }
                .help(exportSidebarToggleTitle)
                .accessibilityLabel(exportSidebarToggleTitle)
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
        }
    }

    @ViewBuilder
    private var paneSelector: some View {
        ForEach(HorizontalPane.allCases) { pane in
            let badge = toolbarBadgeCount(for: pane)
            Toggle(isOn: paneVisibilityBinding(for: pane)) {
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbolName)
                        .toolbarBadge(badge)
                }
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .controlSize(.large)
            .disabled(visiblePanes.count == 1 && visiblePanes.contains(pane))
            .help(badge > 0 ? "\(pane.title) — \(partLibrary.noticeText)" : pane.title)
            .accessibilityValue(badge > 0 ? partLibrary.noticeText : "")
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

    /// What the pane's toolbar button badges: the parts the info bar is
    /// about, on the Parts pane.
    private func toolbarBadgeCount(for pane: HorizontalPane) -> Int {
        pane == .parts ? partLibrary.attentionCount : 0
    }

    private var rulesBadgeCount: Int {
        rulesResultsState?.toolbarBadgeCount(displayingWarnings: appearanceSettings.shouldDisplayCanvasWarnings) ?? 0
    }

    private var rulesResultsHelp: String {
        guard let result = rulesResultsState, rulesBadgeCount > 0 else {
            return rulesResultsSidebarToggleTitle
        }
        let errors = result.errorCount
        let warnings = result.warningCount
        let found = [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil,
                     warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil].compactMap { $0 }
        let since = result.isOutOfDate ? ", before the latest changes" : ""
        return "\(rulesResultsSidebarToggleTitle) — the last rules check found \(found.joined(separator: " and "))\(since)"
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
        planePourScheduler.deliver = { applyPouredPlanes($0) }
        checkPlaneFills()
        registerLiveDocument()
        startFileWatcher()
        gitignoreNeedsFixing = !isReadOnly && document.archive.gitignoreNeedsFixing
        if navigatorSelection == nil {
            navigatorSelection = defaultNavigatorSelection
        }
    }

    private func disappear() {
        unregisterLiveDocument()
        fileWatcher?.stop()
        fileWatcher = nil
        diskConflict?.releaseSaves()
        diskConflict = nil
    }

    /// A new document's first save put its files at `url`: the project, the
    /// live channel and the file watcher go there, and the canvases, tools
    /// and undo stay as they are.
    private func moveProject(to url: URL) {
        guard ProjectDocumentView.documentIdentity(url) != ProjectDocumentView.documentIdentity(project.url) else {
            return
        }
        let previous = project
        let previousLiveHandle = liveHandle
        fileWatcher?.stop()
        fileWatcher = nil
        project.move(to: url)
        // Export settings no one changed are named and placed for the saved
        // project; changed ones keep what was chosen, and the folder moves
        // when it was still the one beside the old project.
        let previousExportSettings = HorizontalExportSettings(project: previous)
        if exportSettings == previousExportSettings {
            exportSettings = HorizontalExportSettings(project: project)
        } else if exportSettings.targetDirectory == previousExportSettings.targetDirectory {
            exportSettings.targetDirectory = HorizontalExportSettings(project: project).targetDirectory
        }
        // Served at the new URL before the old one goes, so the live channel
        // always has a document and keeps listening on its port.
        liveHandle = nil
        registerLiveDocument()
        if let previousLiveHandle {
            HorizontalDispatchSession.shared.unregisterLive(handle: previousLiveHandle)
        }
        startFileWatcher()
    }

    // MARK: - Changes on disk

    /// The document autosaves in place, but nothing told it when something
    /// else changed its files: it went on showing the old design, and its
    /// next autosave wrote that back over a checkout (item 121). Now a change
    /// from outside reloads a document with nothing unsaved, as Revert would,
    /// and asks what to keep when it has edits its files don't.
    private func startFileWatcher() {
        guard fileWatcher == nil, HorizontalDocumentSaving.document(for: project.url) != nil else {
            // An untitled document lives in a temporary folder of its own
            // until its first save gives it a URL (`moveProject`).
            return
        }
        let watcher = HorizontalProjectFileWatcher(projectURL: project.url, handlers: .init(
            document: { document },
            holdsCompleteArchive: { documentHoldsCompleteArchive },
            hasUnsavedChanges: { HorizontalDocumentSaving.isEdited(url: project.url) },
            changedOnDisk: { disk, fingerprint, hasUnsavedChanges in
                if hasUnsavedChanges || diskConflict != nil {
                    presentDiskConflict(fingerprint)
                } else {
                    reloadFromDisk(disk, fingerprint: fingerprint)
                }
            }
        ))
        watcher.start()
        fileWatcher = watcher
    }

    /// A writable document gathers every file the project references when it
    /// opens; one opened read-only holds only its `.hprj` and can't write.
    private var documentHoldsCompleteArchive: Bool {
        guard !isReadOnly, case .directory = document.archive.root else { return false }
        return true
    }

    private func presentDiskConflict(_ fingerprint: HorizontalProjectFingerprint) {
        if diskConflict != nil {
            diskConflict?.fingerprint = fingerprint
            return
        }
        diskConflict = HorizontalDiskConflict(fingerprint: fingerprint,
                                              releaseSaves: HorizontalDocumentSaving.holdSaves(url: project.url))
    }

    private func resolveDiskConflict(reload: Bool) {
        guard let conflict = diskConflict else { return }
        if reload {
            do {
                // What the files hold now, which may have moved on since the
                // window asked.
                let disk = try HorizontalProjectArchive.completeProject(from: project.url)
                reloadFromDisk(disk, fingerprint: HorizontalProjectFingerprint(archive: disk))
            } catch {
                diskReloadError = error.localizedDescription
            }
        } else {
            fileWatcher?.accept(conflict.fingerprint)
        }
        diskConflict = nil
        conflict.releaseSaves()
    }

    /// Takes the project as the files hold it, as Revert does: the canvases,
    /// the live channel and the document all follow, and undo starts over,
    /// since what it would take back is not what the files hold.
    private func reloadFromDisk(_ disk: HorizontalProjectArchive, fingerprint: HorizontalProjectFingerprint) {
        do {
            var reloaded = try HorizontalProject.loadSnapshot(of: disk)
            if project.poolModelFiles != nil
                || HorizontalProject.poolModelsChanged(from: document.archive, to: disk, poolDirectory: project.poolDirectory) {
                try reloaded.retainPoolModels(in: disk, reusing: project.poolModelFiles)
            }
            rebaseProjectURLs(&reloaded, onto: project)
            // The files' fills are the board's own again, as when it opened.
            pouredPlaneInputs = nil
            installLiveSnapshot(HorizontalLiveSnapshot(archive: disk, project: reloaded), installsArchive: !isReadOnly)
            HorizontalDocumentSaving.didReloadFromDisk(url: project.url)
            documentUndoManager?.removeAllActions()
            fallbackUndoManager.removeAllActions()
            fileWatcher?.accept(fingerprint)
            gitignoreNeedsFixing = !isReadOnly && disk.gitignoreNeedsFixing
        } catch {
            diskReloadError = error.localizedDescription
        }
    }

    // MARK: - Live channel

    /// Exposes this document to the dispatch layer (docs/automation.md): the
    /// Python package and MCP server read its in-memory state, highlight and
    /// select through it, and submit edits that land as one undoable step.
    private func registerLiveDocument() {
        guard liveHandle == nil else {
            return
        }
        let live = HorizontalLiveDocument(url: project.url, title: project.displayTitle, project: project, archive: document.archive)
        live.currentProject = { project }
        live.revision = { "\(boardEditRevision):\(boardSyncRevision):\(schematicEditRevision)" }
        live.planeFillRevision = { planeFillRevision }
        live.archive = { document.archive }
        live.isReadOnly = { isReadOnly }
        live.selection = {
            HorizontalLiveSelection(
                netIDs: selectedNetIDs,
                componentIDs: selectedComponentIDs,
                highlightedNetIDs: highlightedNetIDs,
                highlightedComponentIDs: highlightedComponentIDs,
                panes: visiblePanes.map { "\($0)" }
            )
        }
        live.setHighlight = { nets, components in
            highlightedNetIDs = nets
            highlightedComponentIDs = components
        }
        live.setSelection = { nets, components in
            selectNet(nets)
            selectComponents(components)
        }
        live.applyArchive = { archive, actionName in
            try applyLiveArchive(archive, actionName: actionName)
        }
        live.applyLoadedArchive = { archive, loaded, actionName in
            try applyLiveArchive(archive, loaded: loaded, actionName: actionName)
        }
        #if os(macOS)
        // The document system owns saving; find this document by its URL
        // rather than sending the Save action, which would go to whichever
        // window happens to be key.
        let documentURL = live.url
        live.isEdited = { HorizontalDocumentSaving.isEdited(url: documentURL) }
        live.save = { try HorizontalDocumentSaving.save(url: documentURL) }
        // The document's own undo stack, which is the one an edit made through
        // this channel now registers on and the one the Edit menu drives.
        live.undoActionName = {
            let manager = HorizontalDocumentSaving.undoManager(url: documentURL)
            return manager?.canUndo == true ? manager?.undoActionName : nil
        }
        live.redoActionName = {
            let manager = HorizontalDocumentSaving.undoManager(url: documentURL)
            return manager?.canRedo == true ? manager?.redoActionName : nil
        }
        live.undo = {
            guard let manager = HorizontalDocumentSaving.undoManager(url: documentURL), manager.canUndo else {
                return nil
            }
            let name = manager.undoActionName
            manager.undo()
            return name
        }
        live.redo = {
            guard let manager = HorizontalDocumentSaving.undoManager(url: documentURL), manager.canRedo else {
                return nil
            }
            let name = manager.redoActionName
            manager.redo()
            return name
        }
        #endif
        live.visibleBounds = { pane in
            visiblePanes.contains(pane) ? canvasCommandActionsByPane[pane]?.visibleWorldBounds?() : nil
        }
        live.drawnAirwires = {
            visiblePanes.contains(.board) ? canvasCommandActionsByPane[.board]?.drawnAirwires?() : nil
        }
        live.frame = { pane, rect in
            let wasVisible = visiblePanes.contains(pane)
            visiblePanes.insert(pane)
            if pane == .threeD {
                // The 3D pane has no world rectangle to frame; it has a
                // camera, and the rectangle is on the board.
                if let board = project.board {
                    threeDCameraState = horizonSceneCameraState(
                        framing: rect, board: board, current: threeDCameraState,
                        projection: boardDisplayOptions.threeDProjection
                    )
                }
                return
            }
            guard wasVisible else {
                // A hidden pane's canvas, mounted or not, has no size to
                // frame in: frame once it has come up and laid out, the same
                // wait zoom_to gives a sheet swap.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    canvasCommandActionsByPane[pane]?.frameWorldRect?(rect)
                }
                return
            }
            canvasCommandActionsByPane[pane]?.frameWorldRect?(rect)
        }
        live.setLayerPreset = { preset in
            // A side-less preset ("show silkscreen") takes the side that is
            // up; the view presets also turn the board over and put the tools
            // on that side's copper, or its silkscreen for a silkscreen view.
            let side = boardDisplayOptions.visibleSide ?? (boardViewport.mirrored ? .bottom : .top)
            let resolved = preset.resolved(for: side)
            boardDisplayOptions.applyLayerPreset(resolved)
            if let mirrors = resolved.mirrorsView {
                boardViewport.mirrored = mirrors
            }
            if let layer = resolved.drawingLayer {
                boardDrawingLayer = layer
            }
            visiblePanes.insert(.board)
        }
        live.showBoardSide = { side in
            // Framing a part on the far side: a sided view turns over to it.
            showBoardSide(side)
        }
        live.zoomBy = { pane, factor in
            let candidates: [HorizontalPane?] = [pane, activeCanvasCommandPane, .board, .schematic, .threeD]
            guard let target = candidates.compactMap({ $0 }).first(where: { $0.hasCanvas && visiblePanes.contains($0) }) else {
                return
            }
            if target == .threeD {
                if let board = project.board {
                    if factor <= 0 {
                        threeDCameraState = horizonSceneCameraState(for: .defaultPerspective, board: board)
                        return
                    }
                    threeDCameraState = horizonSceneCameraState(
                        zooming: threeDCameraState, by: factor, board: board, projection: boardDisplayOptions.threeDProjection
                    )
                }
                return
            }
            canvasCommandActionsByPane[target]?.zoomBy?(factor)
        }
        live.setPanes = { panes in
            visiblePanes = panes
        }
        live.showSheet = { blockID, sheetID in
            visiblePanes.insert(.schematic)
            navigatorSelection = blockID.map { .sheet(blockID: $0, sheetID: sheetID) } ?? .standaloneSheet(sheetID)
        }
        live.currentSheet = {
            switch navigatorSelection {
            case .sheet(_, let sheetID), .standaloneSheet(let sheetID):
                return sheetID
            default:
                return nil
            }
        }
        let handle = HorizontalDispatchSession.shared.registerLive(live)
        liveHandle = handle
        // Spoken commands act on this window's document, not whichever is
        // in front when the words land.
        voiceControl.attach(handle: handle)
    }

    private func unregisterLiveDocument() {
        guard let liveHandle else {
            return
        }
        voiceControl.detach()
        HorizontalDispatchSession.shared.unregisterLive(handle: liveHandle)
        self.liveHandle = nil
    }

    /// An edited archive from the live channel becomes the document: the
    /// model reloads from it, URLs are pointed back at the real project (the
    /// snapshot loads from a temporary copy), and the previous archive and
    /// model go on the undo stack as one step.
    private func updateProjectParts(_ review: HorizontalPoolCacheReview, _ ids: Set<String>, _ allowProjectChanges: Bool) throws {
        guard !isReadOnly, let directory = project.poolDirectory else {
            throw HorizontalDispatchError.failed("This project's library is read-only.")
        }
        let updated = try HorizontalPoolCacheUpdater.applying(review, selecting: ids, allowProjectChanges: allowProjectChanges,
                                                              to: document.archive, poolDirectory: directory)
        try HorizontalPoolCacheUpdater.validate(updated, against: project)
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
        try applyLiveArchive(updated, actionName: "Update Project Parts", beforeInstall: { try review.requireSourcesCurrent() })
    }

    /// The Parts pane's Clean Up… and the Design menu's Clean Up Project Pool…,
    /// where the document can be edited and has a pool.
    private var poolCleanupAction: (() -> Void)? {
        guard !isReadOnly, project.poolDirectory != nil else { return nil }
        return { showPoolCleanup() }
    }

    /// Opens the project pool cleanup on what nothing in the design reaches now.
    private func showPoolCleanup() {
        guard let directory = project.poolDirectory else { return }
        var files = HorizontalPoolCacheUpdater.files(in: document.archive, poolDirectory: directory)
        if files.isEmpty, let onDisk = try? HorizontalPoolCacheUpdater.filesOnDisk(in: project.baseURL.appendingPathComponent(directory)) {
            files = onDisk
        }
        poolCleanupReview = HorizontalPoolCacheCleanup.review(archive: document.archive, project: project, files: files)
    }

    private func cleanUpProjectPool(_ review: HorizontalPoolCacheCleanupReview, _ ids: Set<String>) throws {
        guard !isReadOnly, let directory = project.poolDirectory else {
            throw HorizontalDispatchError.failed("This project's library is read-only.")
        }
        let cleaned = try HorizontalPoolCacheCleanup.applying(review, removing: ids, to: document.archive, project: project, poolDirectory: directory)
        try HorizontalPoolCacheUpdater.validate(cleaned, against: project)
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
        try applyLiveArchive(cleaned, actionName: "Clean Up Project Pool")
    }

    /// Upstream's wording and choices (`info_bar_gitignore`): fix it, or leave
    /// the file as it is.
    private var gitignoreInfoBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("This project's gitignore is missing one or more recommended lines.")
                .font(.callout)
            Button("Fix") { fixGitignore() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss") { gitignoreNeedsFixing = false }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 1)
    }

    /// Appends the missing lines to the `.gitignore` beside the project file
    /// as one undoable edit, which the document saves like any other.
    private func fixGitignore() {
        gitignoreNeedsFixing = false
        var archive = document.archive
        do {
            guard try archive.fixGitignore() else { return }
            try applyLiveArchive(archive, actionName: "Fix .gitignore")
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    /// `refreshesRulesWindow` false leaves an open rules window as it is, for
    /// an edit it made itself: telling it again would reset a field being
    /// typed in. Otherwise a change to the rules shows there.
    private func applyLiveArchive(_ archive: HorizontalProjectArchive, loaded: HorizontalProject? = nil, actionName: String,
                                  refreshesRulesWindow: Bool = true,
                                  beforeInstall: () throws -> Void = {}) throws {
        guard !isReadOnly else {
            throw HorizontalDispatchError.failed("Read-only operation is enabled in Horizontal.")
        }
        guard diskConflict == nil else {
            throw HorizontalDispatchError(
                code: .staleRevision,
                message: "The project's files changed on disk while it had edits it hadn't saved, and its window is asking "
                    + "which to keep. Answer there, then read the project again."
            )
        }
        // A change the watcher hasn't looked at yet, such as a checkout a
        // moment ago: look now, rather than edit a document the files no
        // longer match and autosave it over them.
        if let fileWatcher, fileWatcher.checkNow() {
            throw HorizontalDispatchError(
                code: .staleRevision,
                message: "The project's files changed on disk since this edit was prepared. Horizontal has reloaded them, "
                    + "or is asking in its window whether to. Read the project again before editing."
            )
        }
        var previousProject = project
        // A commit hands over the project it loaded from this archive to
        // validate the edit; loading it again would double the wait.
        var reloaded = try loaded ?? HorizontalProject.loadSnapshot(of: archive)
        if previousProject.poolModelFiles != nil || HorizontalProject.poolModelsChanged(from: document.archive, to: archive, poolDirectory: project.poolDirectory) {
            try previousProject.retainPoolModels(in: document.archive, reusing: previousProject.poolModelFiles)
            try reloaded.retainPoolModels(in: archive, reusing: previousProject.poolModelFiles)
        }
        let previous = HorizontalLiveSnapshot(archive: document.archive, project: previousProject)
        rebaseProjectURLs(&reloaded, onto: project)
        try beforeInstall()
        liveUndoTarget.configure(
            currentValue: { HorizontalLiveSnapshot(archive: document.archive, project: project) },
            restoreValue: { snapshot in
                let rules = boardRulesData(in: document.archive)
                installLiveSnapshot(snapshot)
                refreshBoardRulesWindow(ifChangedFrom: rules)
            }
        )
        // The document's own undo manager, not the view's environment one: an
        // edit arriving while the app is in the background would otherwise land
        // on the view's fallback, where Undo never looks, and the user could
        // not take an automation client's edit back.
        var undoManager = activeUndoManager
        #if os(macOS)
        undoManager = HorizontalDocumentSaving.undoManager(url: project.url) ?? undoManager
        #endif
        liveUndoTarget.registerUndo(from: previous, actionName: actionName, undoManager: undoManager)
        let rules = boardRulesData(in: document.archive)
        installLiveSnapshot(HorizontalLiveSnapshot(archive: archive, project: reloaded))
        if refreshesRulesWindow {
            refreshBoardRulesWindow(ifChangedFrom: rules)
        }
        #if os(macOS)
        // The undo registration above may have gone to the view's fallback
        // manager rather than the document's — it does whenever the app is not
        // frontmost, which is every automation edit — and the document system
        // only learns of a change through its own. Telling it directly is what
        // makes Save work, and what makes closing the window ask.
        HorizontalDocumentSaving.markEdited(url: project.url)
        #endif
    }

    /// The board's rules and the schematic's as `archive` has them, written
    /// out to compare.
    private func boardRulesData(in archive: HorizontalProjectArchive) -> Data? {
        guard let board = try? HorizontalProjectJSONApplicator.boardRules(in: project, from: archive) else {
            return nil
        }
        let schematic = (try? HorizontalProjectJSONApplicator.schematicRules(in: project, from: archive)) ?? [:]
        return try? JSONSerialization.data(withJSONObject: ["board": board, "schematic": schematic], options: [.sortedKeys])
    }

    /// The schematic's rules as `archive` has them; nil where there is no
    /// schematic to keep them in.
    private func schematicRules(in archive: HorizontalProjectArchive) -> HorizontalSchematicRules? {
        guard project.schematic != nil else { return nil }
        return HorizontalSchematicRules(json: try? HorizontalProjectJSONApplicator.schematicRules(in: project, from: archive))
    }

    /// An open rules window shows the board's rules as they are now, and the
    /// schematic's, where they differ from `previous`: an undo, or an
    /// automation client's edit.
    private func refreshBoardRulesWindow(ifChangedFrom previous: Data?) {
        guard let boardRulesWindowController, boardRulesData(in: document.archive) != previous,
              let rules = try? HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive) else {
            return
        }
        boardRulesWindowController.refresh(rules: rules, board: project.board, schematicRules: schematicRules(in: document.archive))
    }

    /// `installsArchive` is false only for a read-only document reloading from
    /// disk: it holds just its `.hprj`, and giving it the rest would mark it
    /// edited with nothing it is allowed to save.
    private func installLiveSnapshot(_ snapshot: HorizontalLiveSnapshot, installsArchive: Bool = true) {
        if let board = snapshot.project.board, let previous = project.board,
           HorizontalBoardPlaneInputs.signature(of: board) != HorizontalBoardPlaneInputs.signature(of: previous) {
            planePourScheduler.forgetCache()
        }
        if installsArchive {
            document.archive = snapshot.archive
        }
        var installed = snapshot.project
        // An undo past a new document's first save takes back a project
        // that still names the temporary folder it was made in.
        if ProjectDocumentView.documentIdentity(installed.url) != ProjectDocumentView.documentIdentity(project.url) {
            installed.rebaseURLs(onto: project)
        }
        project = installed
        boardEditRevision += 1
        boardSyncRevision += 1
        schematicEditRevision += 1
        schematicSyncRevision += 1
        selectionDetailsByPane = [:]
        // At once rather than when SwiftUI next updates: an automation
        // client's next request may be an export, which waits only for a
        // pour that has been asked for.
        checkPlaneFills()
    }

    private func rebaseProjectURLs(_ reloaded: inout HorizontalProject, onto current: HorizontalProject) {
        reloaded.rebaseURLs(onto: current)
    }

    private func restoreFileViewStateIfNeeded() {
        guard !didRestoreFileViewState else {
            return
        }

        if let savedPanes = HorizontalFileViewStateStore.shared.load(for: project.url, projectID: project.uuid)?.visiblePanes,
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
        HorizontalFileViewStateStore.shared.save(state, for: project.url, projectID: project.uuid)
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
        isExporting = true
        exportStatus = nil
        // Fabrication outputs are made from the fills: a pour asked for and
        // not yet landed would leave them describing copper that is gone.
        await planePourScheduler.settled()
        // Snapshot the value-type inputs on the main actor, then run the (synchronous,
        // CPU + file-IO heavy) export off-main so the spinner keeps animating. The
        // security-scoped folder access granted above is process-wide, so the
        // background write still has it.
        let settings = exportSettings
        let exportProject = project
        let schematicPalette = appearanceSettings.palette(for: .schematic, mode: .light)
        let boardPalette = appearanceSettings.palette(for: .board, mode: .light)
        let silkscreenClipping = appearanceSettings.silkscreenClipping

        let result = await Task.detached(priority: .userInitiated) {
            HorizontalExportBackend.export(
                sections: sections,
                settings: settings,
                project: exportProject,
                schematicPDFPalette: schematicPalette,
                boardPDFPalette: boardPalette,
                silkscreenClipping: silkscreenClipping
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

        // The leading pane runs under the navigator sidebar; its minimum
        // counts only what shows beside it. The schematic and the board stay
        // mounted once shown, so Tab between them doesn't load the other
        // each time; what reads a pane's canvas reads it only while the pane
        // is visible.
        ResizablePaneSplitView(
            panes: panes,
            sizeFractions: $paneSizeFractions,
            leadingInset: safeAreaInsets.leading,
            keepsMounted: Set(HorizontalPane.allCases.filter(\.staysMountedWhenHidden))
        ) { pane, isLeadingPane in
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
                    onPlacePart: beginPartPlacement,
                    library: partLibrary,
                    usedPartIDs: Set(HorizontalPoolCacheUpdater.references(in: document.archive, project: project).keys),
                    populatedPartIDs: HorizontalPoolCacheUpdater.populatedPartIDs(in: document.archive, project: project),
                    copyTargets: project.poolDirectory.map { HorizontalPoolPartCopier.targets(forProjectPool: project.baseURL.appendingPathComponent($0)) } ?? [],
                    onCopyToPool: isReadOnly ? nil : { partID, target in preparePoolCopy(partID: partID, to: target) },
                    onReviewUpdates: { showsPartUpdates = true },
                    onCleanUp: poolCleanupAction,
                    onSelectUses: { selectComponents(usingPart: $0) }
                )
                .claimsKeyboardOnClick(leadingInset: fitSafeAreaInsets.leading) { activeCanvasCommandPane = .parts }
            }
        case .library:
            ViewerPane(title: "Pools", subtitle: poolsPaneSubtitle) {
                HorizontalPoolBrowserView(
                    root: .project(poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }),
                    safeAreaInsets: fitSafeAreaInsets,
                    revealRequest: libraryRevealRequest,
                    partActions: libraryPartActions
                )
                .claimsKeyboardOnClick(leadingInset: fitSafeAreaInsets.leading) { activeCanvasCommandPane = .library }
            }
        case .schematic:
            if case .blockSymbol(let blockID) = navigatorSelection, let blockSymbol = blockSymbolForEditing(blockID) {
                ViewerPane(title: "Block Symbol", subtitle: blockSymbol.name) {
                    HorizontalBlockSymbolEditorPane(
                        blockSymbol: blockSymbol,
                        revision: schematicSyncRevision,
                        poolURL: project.baseURL.appendingPathComponent(project.poolDirectory ?? HorizontalProjectArchive.projectPoolDirectoryName),
                        portNets: portNetSummaries(blockID: blockID, blockSymbol: blockSymbol),
                        isReadOnly: isReadOnly,
                        undoManager: activeUndoManager,
                        safeAreaInsets: fitSafeAreaInsets,
                        showsTools: !isDistractionFree && !isWindowToolbarHidden,
                        isKeyboardFocused: activeCanvasCommandPane == .schematic && !isKeyboardInControl,
                        displayOptions: $schematicDisplayOptions,
                        selectionToolSettings: $selectionToolSettings,
                        selectionPropertyChangeCommand: selectionPropertyChangeCommands[.schematic],
                        drawingToolCommand: schematicDrawingToolCommand,
                        onDrawingTool: { schematicDrawingToolCommand = HorizontalDrawingToolCommand(primitive: $0) },
                        onChange: { applyEditedBlockSymbol($0, blockID: blockID) },
                        onPortNetCommand: { applyPortNetCommand($0, blockID: blockID) },
                        onSelectionDetailsChange: { setSelectionDetails($0, for: .schematic) },
                        onCanvasCommandActionsChange: { setCanvasCommandActions($0, for: .schematic) },
                        onToolbarHover: { setPointerInsideToolbar($0, for: .schematic) }
                    )
                }
            } else {
            ViewerPane(title: "Schematic", subtitle: selectedSchematic?.subtitle ?? "Unavailable") {
                PaneOverlayContainer(
                    pane: .schematic,
                    safeAreaInsets: fitSafeAreaInsets,
                    infoEnabled: selectedSchematic != nil,
                    showsTools: !isDistractionFree && !isWindowToolbarHidden,
                    selectionToolSettings: $selectionToolSettings,
                    isKeyboardFocused: activeCanvasCommandPane == .schematic && !isKeyboardInControl,
                    onToolbarHover: { setPointerInsideToolbar($0, for: .schematic) }
                ) {
                    if let selectedSchematic {
                        WindowAttachedCanvasHost(
                            // By file, not by sheet: flipping pages updates the
                            // canvas in place, where each page's scene is cached.
                            loadID: "schematic-\(selectedSchematic.url.path)",
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
                                onSelectedComponentChange: { selectComponents($0, from: .schematic) },
                                onHighlightNetCommand: highlightSelectedNet,
                                onHighlightComponentCommand: highlightSelectedComponents,
                                onSelectionClearedBySheetChange: clearSelectionKeepingHighlight,
                                onSheetChange: { sheet in
                                    applyEditedSchematicSheet(sheet, schematicURL: selectedSchematic.url)
                                },
                                onDeleteSelection: { sheet in
                                    deleteSchematicSelection(sheet, schematicURL: selectedSchematic.url)
                                },
                                onMergeNetsSheetChange: { sheet, merges, actionName in
                                    applyEditedSchematicSheet(sheet, mergingNets: merges, actionName: actionName,
                                                              schematicURL: selectedSchematic.url)
                                },
                                onEditMessage: { schematicEditMessage = $0 },
                                onCopySelection: { sheet, refs, anchor in
                                    copySchematicSelection(refs, from: sheet, anchor: anchor, selectedSchematic: selectedSchematic)
                                },
                                onPreparePaste: { clipboard, point, actionName in
                                    prepareSchematicPaste(clipboard, at: point, actionName: actionName, selectedSchematic: selectedSchematic)
                                },
                                onClipboardError: { projectEditError = HorizontalCanvasProjectEdit.message(for: $0) },
                                onApplyProjectEdit: { operations, actionName in
                                    applyProjectEdit(operations, actionName: actionName, schematicURL: selectedSchematic.url)
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
                                onSetNoPopulate: canSetNoPopulate(in: selectedSchematic) ? { componentIDs, noPopulate in
                                    applyEditedNoPopulate(componentIDs: componentIDs, noPopulate: noPopulate, selectedSchematic: selectedSchematic)
                                } : nil,
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
                                onSwitchPane: { switchCanvasPane(from: .schematic) },
                                selectionPropertyChangeCommand: selectionPropertyChangeCommands[.schematic],
                                netSegmentSelectionCommand: schematicNetSegmentSelectionCommand,
                                drawingToolCommand: schematicDrawingToolCommand,
                                drawNetLineCommand: schematicDrawNetLineCommand,
                                placePartRequest: pendingPartPlacement,
                                placeBlockRequest: pendingBlockPlacement,
                                onOpenBlock: { openBlock($0, from: selectedSchematic) },
                                onEditBlockSymbol: { blockID in
                                    navigatorSelection = .blockSymbol(blockID)
                                },
                                allowsPortNets: block(of: selectedSchematic)?.isTop == false,
                                onMoveToOtherSheet: isReadOnly ? nil : { items, sheetID in
                                    moveSchematicItems(items, toSheet: sheetID, from: selectedSchematic)
                                },
                                moveRequest: pendingSchematicMove,
                                poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) },
                                onRevealPoolSymbol: { symbolID, target in
                                    revealPoolItem(.symbol, uuid: symbolID, in: target)
                                },
                                syncRevision: schematicSyncRevision,
                                ruleMarkers: HorizontalCanvasWarning.markers(
                                    schematicFindings: rulesResultsState?.canvasSchematicFindings(collapsedSections: collapsedRuleSections) ?? [],
                                    sheetID: selectedSchematic.sheet.id
                                )
                            )
                        }
                        .overlay(alignment: .top) {
                            leaveBlockChip(for: selectedSchematic)
                                .padding(.top, fitSafeAreaInsets.top + 10)
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
                    // Locked, the tools that would change the design are not
                    // shown at all. A rail of dimmed buttons says "this app is
                    // broken" where an absent one says "this document is
                    // read-only", which is what the lock means. Same rule the
                    // canvas context menus already follow.
                    if !isReadOnly {
                        DrawingToolButtonGroup { primitive in
                            schematicDrawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                        }
                        DrawNetToolButton(
                            onDrawNet: { schematicDrawNetLineCommand = HorizontalDrawNetLineCommand() },
                            onPlaceBusRipper: { canvasCommandActionsByPane[.schematic]?.dispatch(.placeBusRipper) },
                            canPlaceBusRipper: canvasCommandActionsByPane[.schematic]?.canPlaceBusRipper == true
                        )
                        LabelNetToolButton(
                            onLabelNet: { canvasCommandActionsByPane[.schematic]?.dispatch(.placeNetLabel) },
                            canLabelNet: canvasCommandActionsByPane[.schematic]?.canPlaceNetLabel == true,
                            onLabelBus: { canvasCommandActionsByPane[.schematic]?.dispatch(.placeBusLabel) },
                            canLabelBus: canvasCommandActionsByPane[.schematic]?.canPlaceBusLabel == true
                        )
                        PlacePowerSymbolToolButton {
                            powerNetsPopoverPresented.toggle()
                        }
                        .popover(isPresented: $powerNetsPopoverPresented, arrowEdge: .trailing) {
                            HorizontalPowerNetsPopover(
                                nets: powerNetSummaries,
                                isReadOnly: isReadOnly,
                                onCommand: { canvasCommandActionsByPane[.schematic]?.dispatch(.managePowerNet($0)) },
                                onDismiss: { powerNetsPopoverPresented = false }
                            )
                        }
                        .disabled(selectedSchematic == nil)
                        TieNetsToolButton {
                            canvasCommandActionsByPane[.schematic]?.dispatch(.tieNets)
                        }
                        .disabled(canvasCommandActionsByPane[.schematic]?.canTieNets != true)
                        AnnotateToolButton {
                            annotatePopoverPresented.toggle()
                        }
                        .popover(isPresented: $annotatePopoverPresented, arrowEdge: .trailing) {
                            HorizontalAnnotatePopover(options: annotationOptions, isReadOnly: isReadOnly) { options in
                                annotatePopoverPresented = false
                                annotate(options)
                            }
                        }
                        .disabled(selectedSchematic == nil)
                        PlaceBlockToolButton(
                            choices: placeBlockChoices,
                            onPlace: { placeBlock($0) },
                            onNewBlock: {
                                // As the navigator's New Block: named for
                                // now, its symbol shown to draw.
                                if let blockID = addBlock(named: project.newBlockName) {
                                    navigatorSelection = .blockSymbol(blockID)
                                }
                            }
                        )
                        .disabled(selectedSchematic == nil)
                        AddTextToolButton {
                            canvasCommandActionsByPane[.schematic]?.dispatch(.addText)
                        }
                        .disabled(selectedSchematic == nil)
                        if let selectedSchematic {
                            NetClassToolButton(
                                netClasses: schematicNetClassesBinding(for: selectedSchematic),
                                usedNetClassIDs: usedNetClassIDs(for: selectedSchematic)
                            )
                        }
                    }
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
                    selectionToolSettings: $selectionToolSettings,
                    isKeyboardFocused: activeCanvasCommandPane == .board && !isKeyboardInControl,
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
                                onSelectedComponentChange: { selectComponents($0, from: .board) },
                                onHighlightNetCommand: highlightSelectedNet,
                                onHighlightComponentCommand: highlightSelectedComponents,
                                onBoardChange: { board in
                                    applyEditedBoard(board)
                                },
                                onPlaneEdit: { board, actionName in
                                    applyBoardPlaneEdit(board, actionName: actionName)
                                },
                                onUpdateAllPlanes: updateAllBoardPlanes,
                                onNetClassChange: { netID, netClassID in
                                    if let selectedSchematic {
                                        applyEditedNetClass(
                                            netID: netID,
                                            netClassID: netClassID,
                                            selectedSchematic: selectedSchematic
                                        )
                                    }
                                },
                                onEditDiffpair: boardDiffpairEditing,
                                onMeasureTracks: { tracks, allTracks in
                                    measureTracks(tracks, allTracks: allTracks)
                                },
                                blockInstances: project.flattenedBlock?.boardInstances,
                                tuningReferenceLength: lengthTuning.referenceLength,
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
                                onSwitchPane: { switchCanvasPane(from: .board) },
                                selectionPropertyChangeCommand: selectionPropertyChangeCommands[.board],
                                drawingToolCommand: boardDrawingToolCommand,
                                drawTrackCommand: boardDrawTrackCommand,
                                placeDecalRequest: pendingDecalPlacement,
                                routeWidthCommand: routeWidthCommand,
                                routeInspector: routeInspector,
                                rulesRevision: boardRulesRevision,
                                rulesShapeRevision: boardRuleShapeRevision,
                                onShowToolSettings: { rightSidebarPane = .selection },
                                toolSettings: boardToolSettings,
                                drawingLayer: boardDrawingLayer,
                                syncRevision: boardSyncRevision,
                                planePourRevision: planePourRevision,
                                planeFillDelivery: planeFillDelivery,
                                onSelectDrawingLayer: { selectOrSoloBoardLayer($0) },
                                onSelectBoardLayerView: { applyBoardLayerViewPreset($0) },
                                onFilterAirwires: { isBoardAirwireFilterPresented = true },
                                poolURL: project.poolDirectory.map { project.baseURL.appendingPathComponent($0) },
                                canRevealPoolPackages: true,
                                onRevealPoolPackage: { packageID, target in
                                    revealPoolItem(.package, uuid: packageID, in: target)
                                },
                                ruleMarkers: HorizontalCanvasWarning.markers(
                                    boardFindings: rulesResultsState?.canvasBoardFindings(collapsedSections: collapsedRuleSections) ?? []
                                )
                            )
                            .id(boardLoadID)
                        }
                    } else {
                        MissingPaneView(message: "No board file was loaded.")
                    }
                } info: {
                    if let board = project.board {
                        DeferredPaneInformationPanel {
                            boardInfoSummary(board, subtitle: board.url.lastPathComponent)
                        }
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
                    // Like the stackup it stays when locked: it changes only
                    // which airwires are drawn, never the file.
                    boardAirwireFilterButton(board: project.board)
                        .disabled(project.board == nil)
                    // Pouring rewrites the board, so it goes with the drawing
                    // tools rather than staying as a dimmed button; the
                    // stackup above stays, as locked it is how the board is
                    // read. Pouring automatically leaves the button nothing to
                    // do, and the menu turns it off again. The rules open from
                    // the rules results sidebar and the Board menu, and the
                    // netlist follows the schematic on its own.
                    if !isReadOnly, !updatesPlanesAutomatically {
                        BoardUpdatePlanesToolButton(
                            action: updateAllBoardPlanes,
                            isUpdating: planePourScheduler.isPouring,
                            progress: planePourScheduler.progress,
                            needsUpdate: planesNeedUpdate,
                            updatesAutomatically: $updatesPlanesAutomatically
                        )
                        .disabled(project.board?.planes.isEmpty != false)
                    }
                    if !isReadOnly {
                        DrawTrackToolButton {
                            boardDrawTrackCommand = HorizontalDrawTrackCommand()
                        }
                        .disabled(project.board == nil)
                        DrawingToolButtonGroup(primitives: HorizontalDrawingPrimitive.polygonRail) { primitive in
                            boardDrawingToolCommand = HorizontalDrawingToolCommand(primitive: primitive)
                        }
                        DrawDimensionToolButton {
                            canvasCommandActionsByPane[.board]?.dispatch(.drawDimension)
                        }
                        .disabled(canvasCommandActionsByPane[.board]?.canDrawDimension != true)
                        TuneTrackToolButton {
                            canvasCommandActionsByPane[.board]?.dispatch(.tuneTrack)
                        }
                        .disabled(canvasCommandActionsByPane[.board]?.canTuneTrack != true)
                        AddTextToolButton {
                            canvasCommandActionsByPane[.board]?.dispatch(.addText)
                        }
                        .disabled(project.board == nil)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // With the rail hidden (distraction free, no toolbar) the
                    // menu item's popover comes from the pane's corner.
                    if isDistractionFree || isWindowToolbarHidden {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .padding(.top, fitSafeAreaInsets.top + 12)
                            .padding(.trailing, fitSafeAreaInsets.trailing + 12)
                            .popover(isPresented: $isBoardAirwireFilterPresented, arrowEdge: .trailing) {
                                boardAirwireFilterPanel(board: project.board)
                            }
                    }
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
                            silkscreenClipping: appearanceSettings.silkscreenClipping,
                            // Both only count up, so their sum changes with
                            // either: an edit, or new fills from a pour.
                            revision: boardEditRevision + planeFillRevision,
                            highlightedComponentIDs: highlightedComponentIDs,
                            selectedComponentIDs: selectedComponentIDs,
                            onSelectComponent: { componentID, extend in
                                // A click in 3D selects the way a click on
                                // the board does: one part, or one more with
                                // shift or command, and empty space clears.
                                if let componentID {
                                    selectComponents(extend ? selectedComponentIDs.union([componentID]) : [componentID])
                                } else if !extend {
                                    selectComponents([])
                                }
                            },
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
        HorizontalBoard.unresolvedPackageCount(
            packageIDs: board.packages.map(\.id),
            geometryIDs: board.packagePads.map(\.id) + board.packagePolygons.map(\.id) + board.packageLines.map(\.id)
        )
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

    /// The Edit menu's canvas commands: the keyboard-focused canvas's, or,
    /// while a pane without a canvas (Pools, Parts) has the keyboard, none, so
    /// ⌘A there is no Select All in the schematic.
    private var activeCanvasCommandActions: HorizontalCanvasCommandActions? {
        if let activeCanvasCommandPane, !activeCanvasCommandPane.hasCanvas, visiblePanes.contains(activeCanvasCommandPane) {
            return nil
        }
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
        // A selection pushed into this pane from another view (104) updates
        // its inspector but leaves the keyboard where the user is working,
        // as does one a hidden pane's canvas reports, kept mounted.
        let pushed = crossProbedPanes.remove(pane) != nil

        if selectionDetails.hasSelection {
            selectionDetailsByPane[pane] = selectionDetails
            if !pushed, visiblePanes.contains(pane) {
                activeCanvasCommandPane = pane
            }
        } else {
            selectionDetailsByPane.removeValue(forKey: pane)
        }
    }

    private func setCanvasCommandActions(_ actions: HorizontalCanvasCommandActions?, for pane: HorizontalPane) {
        if let actions {
            canvasCommandActionsByPane[pane] = actions
            if visiblePanes.contains(pane),
               activeCanvasCommandPane == nil || activeCanvasCommandPane.map({ !visiblePanes.contains($0) }) == true {
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

    /// "Show in Pool Manager" from a canvas: the item (a board's package, a
    /// sheet's symbol) in the registered pool that carries it, in that pool's
    /// window; "Show in Project Pool Manager": the project's own copy, in this
    /// window's Library pane. An item no registered pool carries falls back
    /// to the Library pane.
    private func revealPoolItem(_ category: HorizontalPoolItemCategory, uuid: String, in target: HorizontalPoolRevealTarget) {
        let request = HorizontalPoolRevealRequest(category: category, uuid: uuid)
        switch target {
        case .projectPool:
            revealInPools(request)
        case .registeredPool:
            let projectPoolURL = project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
            let candidates = projectPoolURL.map { HorizontalPoolPadstacks.basePoolURLs(for: $0) } ?? HorizontalPoolRegistryStore.poolURLs()
            let normalized = uuid.lowercased()
            for poolURL in candidates {
                let name = HorizontalPoolRegistryStore.poolInfo(at: poolURL).name
                let carriesItem = HorizontalPoolLibrary.items(inPool: poolURL, poolName: name)
                    .contains { $0.category == category && $0.uuid == normalized }
                if carriesItem {
                    HorizontalPoolWindowManager.shared.open(poolURL: poolURL, reveal: request, appearanceSettings: appearanceSettings)
                    return
                }
            }
            revealInPools(request)
        }
    }

    /// Shows an item, or a search, in this window's Pools pane, opening the
    /// pane when it is hidden.
    private func revealInPools(_ request: HorizontalPoolRevealRequest) {
        libraryRevealRequest = request
        if !visiblePanes.contains(.library) {
            visiblePanes.insert(.library)
        }
    }

    private var poolsPaneSubtitle: String {
        project.poolDirectory.map { "\($0) and registered pools" } ?? "Registered pools"
    }

    private func applySelectionPropertyChange(_ change: HorizontalSelectionPropertyChange, in pane: HorizontalPane) {
        // Measuring a track changes nothing, so a locked document measures too.
        guard !isReadOnly || HorizontalTrackSelectionSummary.measuresAllTracks(change.propertyID) != nil else {
            return
        }
        selectionPropertyChangeCommands[pane] = HorizontalSelectionPropertyChangeCommand(change: change)
    }

    /// A hidden pane's selection and canvas commands go, except a pane's that
    /// stays mounted: its canvas keeps them, and shown again has no reason to
    /// report them anew. What reads them (the selection sidebar, the Edit
    /// menu, the live channel) reads the visible panes' alone.
    private func clearSelectionDetailsForHiddenPanes(_ panes: Set<HorizontalPane>) {
        for pane in HorizontalPane.allCases where !panes.contains(pane) {
            // Its rail is gone from under the pointer, whether or not the
            // hover's end was seen.
            panesWithPointerInsideToolbar.remove(pane)
            guard !pane.staysMountedWhenHidden else {
                continue
            }
            selectionDetailsByPane.removeValue(forKey: pane)
            canvasCommandActionsByPane.removeValue(forKey: pane)
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

    /// The workspace's component selection, the last one made: what the 3D
    /// view, the navigator and the live channel show. `origin` is the canvas
    /// it was made in, if any, and a canvas keeps its selection to itself,
    /// so a part picked on the board is not selected in the schematic or the
    /// other way round. A click in the 3D view, Find, the Parts pane or the
    /// live channel (no `origin`) selects in both canvases; a canvas already
    /// showing the set ignores it, and every one it changes is marked, so its
    /// report doesn't take the focus.
    private func selectComponents(_ componentIDs: Set<String>, from origin: HorizontalPane? = nil,
                                  keepingHighlight: Bool = false) {
        if componentIDs != selectedComponentIDs, !keepingHighlight {
            highlightedComponentIDs.removeAll()
        }
        selectedComponentIDs = componentIDs
        for pane in HorizontalPane.componentSelectionTargets(from: origin) {
            if canvasCommandActionsByPane[pane]?.selectComponents?(componentIDs) == true {
                crossProbedPanes.insert(pane)
            }
        }
    }

    /// Find's component rows: the schematic on the component's sheet, the
    /// component selected, and framed as `zoom_to` frames one, 20 mm about
    /// its symbol and a margin. Another sheet swaps the canvas, which drops
    /// its selection, so selecting and framing wait for it, as `zoom_to`
    /// waits; so does a hidden schematic, which has no size to frame in
    /// until it is shown.
    private func showComponent(_ componentID: String, at position: HorizontalPoint, on sheet: ProjectNavigatorSelection) {
        let wasVisible = visiblePanes.contains(.schematic)
        visiblePanes.insert(.schematic)
        let rect = HorizontalRect(center: position, size: 26_000_000)
        let changesSheet = navigatorSelection != sheet
        navigatorSelection = sheet
        let reveal = {
            selectComponents([componentID])
            canvasCommandActionsByPane[.schematic]?.frameWorldRect?(rect)
        }
        if changesSheet || !wasVisible {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                reveal()
            }
        } else {
            reveal()
        }
    }

    /// The Parts pane's Select Components Using This Part: every component
    /// fitted with the part, selected and highlighted on the board and in
    /// the schematic. When the schematic shows a sheet that draws none of
    /// them, it goes to the first sheet that does, as `zoom_to` would; the
    /// highlight follows a page change where the selection doesn't.
    private func selectComponents(usingPart partID: String) {
        let users = HorizontalDesignIndex(project: project).sortedComponents
            .filter { $0.partID?.caseInsensitiveCompare(partID) == .orderedSame }
        guard !users.isEmpty else { return }
        let componentIDs = Set(users.map(\.id))
        let placements = users.flatMap(\.symbolPlacements)
        let currentSheetID: String? = switch navigatorSelection {
        case .sheet(_, let sheetID), .standaloneSheet(let sheetID): sheetID
        default: nil
        }
        if visiblePanes.contains(.schematic),
           !placements.contains(where: { $0.sheetID == currentSheetID }),
           let first = placements.min(by: { $0.sheetIndex < $1.sheetIndex }) {
            navigatorSelection = first.blockID.map { .sheet(blockID: $0, sheetID: first.sheetID) } ?? .standaloneSheet(first.sheetID)
        }
        selectComponents(componentIDs)
        highlightSelectedComponents(componentIDs)
    }

    /// A schematic page change drops the page's selection, and only the
    /// schematic's, but a highlight is by net and component, so it follows
    /// onto the next page.
    private func clearSelectionKeepingHighlight() {
        selectedNetIDs = []
        selectComponents([], from: .schematic, keepingHighlight: true)
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

    /// Returns whether the document's files changed.
    @discardableResult
    private func applyEditedBoard(_ board: HorizontalBoard, writesPlaneCache: Bool = false) -> Bool {
        guard !isReadOnly else {
            return false
        }
        var timings = [(String, UInt64)]()
        func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = try body()
            let end = DispatchTime.now().uptimeNanoseconds
            timings.append((label, end >= start ? end - start : 0))
            return value
        }

        var board = board
        // A board from before a new document's first save, a canvas's copy or
        // an undo's, still names the temporary folder it was made in.
        if let current = project.board?.url, board.url != current,
           ProjectDocumentView.documentIdentity(board.url) != ProjectDocumentView.documentIdentity(current) {
            board.url = current
            if let boardPoolURL {
                board.rebasePackageModelURLs(poolURL: boardPoolURL)
            }
            project.poolModelFiles?.apply(to: &board)
        }
        let previousPackageIDs = Set(project.board?.packages.map(\.id) ?? [])
        measure("assign project board") {
            project.board = board
        }
        boardEditRevision += 1
        if Set(board.packages.map(\.id)) != previousPackageIDs {
            scheduleBoardNetlistSync()
        }
        // Does this edit invalidate the fills? Asked here, in the one funnel
        // every board edit passes through, so the answer is computed once per
        // edit. A board put back with its fills (Undo of a pour) brings its
        // answer with it.
        if writesPlaneCache {
            pouredPlaneInputs = HorizontalBoardPlaneInputs.signature(of: board)
            checkedPlaneInputsRevision = boardEditRevision
            planesNeedUpdate = false
        } else {
            measure("check plane fills") {
                checkPlaneFills()
            }
        }
        // Every assignment through the document binding is an undo step and an
        // edit to SwiftUI, so one that would change nothing isn't made.
        var archive = document.archive
        var changed = false
        do {
            changed = try measure("apply board JSON") {
                try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
            }
            if writesPlaneCache {
                let cacheChanged = try measure("apply plane cache") {
                    try HorizontalProjectJSONApplicator.applyPlaneCache(board: board, in: project, to: &archive)
                }
                changed = changed || cacheChanged
            }
        } catch {
            measure("record failure") {
                recordArchiveApplyFailure(error)
            }
        }
        if changed {
            measure("assign document archive") {
                document.archive = archive
            }
        }
        HorizontalMoveCommitDiagnostics.reportProjectBoardChange(timings: timings)
        return changed
    }

    /// Applies a board that follows from an edit already on the undo stack, the
    /// netlist sync after a placement or the pour after a plane edit, without a
    /// step of its own. SwiftUI puts every document assignment on the stack
    /// unnamed, so a sync landing after "Place Package" was a nameless step on
    /// top, and Undo took back the sync rather than the placement. Undoing the
    /// step before it restores the whole board, this included.
    private func applyFollowUpBoard(_ board: HorizontalBoard, writesPlaneCache: Bool = false) {
        let changed = withoutUndoRegistration {
            applyEditedBoard(board, writesPlaneCache: writesPlaneCache)
        }
        #if os(macOS)
        // With nothing registered the document wouldn't know it changed.
        if changed {
            HorizontalDocumentSaving.markEdited(url: project.url)
        }
        #endif
    }

    /// Runs `body` with undo registration off on every undo manager a
    /// document assignment could register with.
    private func withoutUndoRegistration<T>(_ body: () -> T) -> T {
        var managers = [UndoManager]()
        #if os(macOS)
        if let manager = HorizontalDocumentSaving.undoManager(url: project.url) {
            managers.append(manager)
        }
        #endif
        if let manager = activeUndoManager, !managers.contains(where: { $0 === manager }) {
            managers.append(manager)
        }
        managers.forEach { $0.disableUndoRegistration() }
        defer { managers.forEach { $0.enableUndoRegistration() } }
        return body()
    }

    private func showBoardRulesWindow() {
        showBoardRulesWindow(focus: nil)
    }

    // MARK: - Length tuning and diff pairs

    /// The tracks selected on the board, by id, as its inspector lists them.
    private var selectedBoardTrackIDs: Set<String> {
        Set(selectionDetailsByPane[.board]?.groups.first { $0.type == .track }?.items.map { $0.ref.id.lowercased() } ?? [])
    }

    /// The Design menu's Length Tuning…, Measure Tracks, Measure All
    /// Tracks, Set Diff Pair and Clear Diff Pair.
    private var lengthTuningActions: HorizontalLengthTuningActions? {
        guard project.board != nil else {
            return nil
        }
        let tracks = selectedBoardTrackIDs
        // Only a selection of one or two nets can pair or clear.
        let details = (1...2).contains(selectedNetIDs.count) ? selectedNetDetails : [:]
        let pairing = isReadOnly ? nil : HorizontalDiffpairProperty.pairing(of: selectedNetIDs, in: details)
        let clearing = isReadOnly ? nil : HorizontalDiffpairProperty.clearing(of: selectedNetIDs, in: details)
        return HorizontalLengthTuningActions(
            showWindow: showLengthTuningWindow,
            measure: tracks.isEmpty ? nil : { allTracks in measureTracks(tracks, allTracks: allTracks) },
            setDiffpair: pairing.map { edit in { applyProjectEdit(edit.ops, actionName: edit.actionName) } },
            clearDiffpair: clearing.map { edit in { applyProjectEdit(edit.ops, actionName: edit.actionName) } }
        )
    }

    /// The nets of the top block the selection can name: the schematic's,
    /// with the board's for any it lacks.
    private var selectedNetDetails: [String: HorizontalNetDetails] {
        var details = project.schematic?.netDetails ?? [:]
        for (id, detail) in project.board?.netDetails ?? [:] where details[id] == nil && boardNetIsTopBlocks(id) {
            details[id] = detail
        }
        return details
    }

    /// Whether a board net is one of the top block's own, which its
    /// schematic pairs; an instance's net is its block's.
    private func boardNetIsTopBlocks(_ netID: String) -> Bool {
        guard let flattened = project.flattenedBlock, flattened.isHierarchical else {
            return true
        }
        return flattened.netPaths[netID.lowercased()]?.contains { $0.count == 1 } ?? false
    }

    /// The board inspector's Diff pair row edits the top block's nets.
    private var boardDiffpairEditing: HorizontalDiffpairEditing? {
        guard !isReadOnly else {
            return nil
        }
        return HorizontalDiffpairEditing(
            canEdit: { boardNetIsTopBlocks($0) },
            apply: { ops, actionName in applyProjectEdit(ops, actionName: actionName) }
        )
    }

    private func showLengthTuningWindow() {
        lengthTuning.update(board: project.board)
        let controller = lengthTuningWindowController ?? HorizontalLengthTuningWindowController()
        lengthTuningWindowController = controller
        controller.show(projectName: project.name, model: lengthTuning)
    }

    /// Horizon's Measure Track and Measure All Tracks: the tracks into the
    /// list, and the window up.
    private func measureTracks(_ trackIDs: Set<String>, allTracks: Bool) {
        lengthTuning.update(board: project.board)
        lengthTuning.add(trackIDs: trackIDs, allTracks: allTracks)
        showLengthTuningWindow()
    }

    /// The rules window, at `focus` when there is one.
    private func showBoardRulesWindow(focus: HorizontalBoardRuleFocus?) {
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
                onCheckAndApply: checkAndApplyBoardRules,
                schematicRules: schematicRules(in: document.archive),
                onSchematicRulesChange: applyEditedSchematicRules,
                focus: focus,
                appearanceSettings: appearanceSettings
            )
        } catch {
            recordDiagnostic("Could not load board rules: \(error.localizedDescription)")
        }
    }

    /// Where a board finding is: the board framed on it, with the nets and
    /// parts it is about highlighted, turned to its side when the view shows
    /// one side and the finding is on the other's copper only. A net with a
    /// plane lights up most of the board, so it is highlighted only where a
    /// plane is what the finding is about, or every net it names has one.
    private func showBoardFinding(_ finding: HorizontalBoardRuleFinding) {
        let planeNets = Set(project.board?.planes.compactMap { $0.netID?.lowercased() } ?? [])
        let nets = finding.netIDs
        let quiet = nets.filter { !planeNets.contains($0) }
        highlightSelectedNet(Set(finding.showsPlane || quiet.isEmpty ? nets : quiet))
        highlightSelectedComponents(Set(finding.componentIDs))
        if let side = boardDisplayOptions.visibleSide {
            let layers = Set(finding.layers)
            if !layers.contains(side.copperLayer), layers.contains(side.other.copperLayer) {
                showBoardSide(side.other)
            }
        }
        guard let region = finding.region else { return }
        if visiblePanes.contains(.board), let frame = canvasCommandActionsByPane[.board]?.frameWorldRect {
            frame(region)
            return
        }
        // The board pane comes up first, and is framed once it has.
        visiblePanes.insert(.board)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            canvasCommandActionsByPane[.board]?.frameWorldRect?(region)
        }
    }

    /// Where a schematic finding is: its sheet, framed on it, with its net or
    /// part highlighted. The sheet comes up first when another shows, and is
    /// framed once it has.
    private func showSchematicFinding(_ finding: HorizontalSchematicRuleFinding) {
        guard let place = finding.place, let region = finding.region else {
            return
        }
        highlightSelectedNet(Set([finding.netID].compactMap { $0 }))
        highlightSelectedComponents(Set([finding.componentID].compactMap { $0 }))
        let showing: String? = switch navigatorSelection {
        case .sheet(_, let sheetID), .standaloneSheet(let sheetID): sheetID
        default: nil
        }
        if visiblePanes.contains(.schematic), showing?.caseInsensitiveCompare(place.sheetID) == .orderedSame,
           let frame = canvasCommandActionsByPane[.schematic]?.frameWorldRect {
            frame(region)
            return
        }
        visiblePanes.insert(.schematic)
        navigatorSelection = place.blockID.map { .sheet(blockID: $0, sheetID: place.sheetID) } ?? .standaloneSheet(place.sheetID)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            canvasCommandActionsByPane[.schematic]?.frameWorldRect?(region)
        }
    }

    /// The rules window's change to the schematic's rules: written into the
    /// top schematic, one undoable edit, and the schematic checked again.
    private func applyEditedSchematicRules(_ rules: HorizontalSchematicRules) {
        guard !isReadOnly else {
            return
        }
        do {
            var archive = document.archive
            let current = try HorizontalProjectJSONApplicator.schematicRules(in: project, from: archive)
            try HorizontalProjectJSONApplicator.apply(schematicRules: rules.json(updating: current), in: project, to: &archive)
            // The window shows what it sent already.
            try applyLiveArchive(archive, actionName: "Change Schematic Rules", refreshesRulesWindow: false)
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// Turns a sided board view over to `side`, keeping its mode
    /// (silkscreen stays silkscreen); the all-layers view belongs to no side
    /// and stays.
    private func showBoardSide(_ side: HorizontalBoardSide) {
        guard let current = boardDisplayOptions.visibleSide, current != side else {
            return
        }
        let resolved = boardDisplayOptions.visibleViewMode(on: current).resolved(for: side)
        boardDisplayOptions.applyLayerPreset(resolved)
        if boardViewport.mirrored {
            // Seen from below and turning to the top: stop mirroring.
            boardViewport.mirrored = side == .bottom
        }
        boardDrawingLayer = resolved.drawingLayer ?? side.copperLayer
    }

    private func applyEditedBoardRules(_ rules: JSONDictionary) {
        guard !isReadOnly else {
            return
        }
        do {
            let previous = try HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive)
            // The rules' parameters shape the pads and vias as the board
            // loads, so a change to them is applied by a reload, one undoable
            // edit with the rules.
            if HorizontalBoardRuleApplication.parametersChange(from: previous, to: rules) {
                var archive = document.archive
                try HorizontalProjectJSONApplicator.apply(boardRules: rules, in: project, to: &archive)
                if var board = project.board {
                    board.takeRules(rules)
                    if !HorizontalBoardRuleApplication.apply(to: &board, poolURL: boardPoolURL).isEmpty {
                        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
                    }
                }
                try applyLiveArchive(archive, actionName: "Change Board Rules", refreshesRulesWindow: false)
                return
            }
            // The window shows what it sent already; telling it again would
            // reset a field being typed in.
            try installBoardRules(rules, refreshesWindow: false)
            registerBoardRulesUndo(from: previous, actionName: "Change Board Rules")
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// A change the route inspector makes to the rules. One undoable edit,
    /// made without a reload so the route in progress carries on with them.
    /// Says whether the rules now hold it: made, or one that changes nothing.
    @discardableResult
    private func applyRouteRuleEdit(_ edit: HorizontalRouteRuleEdit) -> Bool {
        guard !isReadOnly, let board = project.board else {
            return false
        }
        do {
            let previous = try HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive)
            let copperLayers = board.stackupLayers.map(\.layer).filter(HorizontalBoardLayers.isCopper)
            guard let rules = HorizontalRouteRuleEditing.applying(edit, to: previous, copperLayers: copperLayers) else {
                return true
            }
            try installBoardRules(rules, refreshesWindow: true)
            registerBoardRulesUndo(from: previous, actionName: edit.actionName)
            return true
        } catch {
            recordArchiveApplyFailure(error)
            return false
        }
    }

    /// The board's rules as `rules`: in the archive, and in the board without
    /// a reload, which would cancel whatever the canvas is doing. They are
    /// applied to the board at once (`HorizontalBoardRuleApplication`): a
    /// track whose width is the rules' takes the new one, a via its shape, a
    /// plane its settings. The canvas takes them into the board it is editing
    /// and applies them too (`boardRulesRevision`), the fills are checked
    /// against them and the results sidebar runs them. Undo puts the rules
    /// back and applies those, which gives what follows them their old shape.
    private func installBoardRules(_ rules: JSONDictionary, refreshesWindow: Bool) throws {
        var archive = document.archive
        try HorizontalProjectJSONApplicator.apply(boardRules: rules, in: project, to: &archive)
        var board = project.board
        board?.takeRules(rules)
        var applied = HorizontalBoardRuleApplication.Changes()
        if var ruled = board {
            applied = HorizontalBoardRuleApplication.apply(to: &ruled, poolURL: boardPoolURL)
            if !applied.isEmpty {
                try HorizontalProjectJSONApplicator.apply(board: ruled, in: project, to: &archive)
                board = ruled
            }
        }
        // The undo step is registerBoardRulesUndo's, which puts the board's
        // rules back too; the document binding's own would leave them.
        withoutUndoRegistration {
            document.archive = archive
        }
        #if os(macOS)
        HorizontalDocumentSaving.markEdited(url: project.url)
        #endif
        project.board = board
        if !applied.isEmpty {
            boardRuleShapeRevision += 1
        }
        boardRulesRevision += 1
        boardEditRevision += 1
        rulesInputsChanged()
        if refreshesWindow {
            boardRulesWindowController?.refresh(rules: rules, board: project.board, schematicRules: schematicRules(in: document.archive))
        }
    }

    private func registerBoardRulesUndo(from previous: JSONDictionary, actionName: String) {
        boardRulesUndoTarget.configure(
            currentValue: {
                (try? HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive)) ?? [:]
            },
            restoreValue: { rules in
                do {
                    try installBoardRules(rules, refreshesWindow: true)
                } catch {
                    recordArchiveApplyFailure(error)
                }
            }
        )
        // The document's own undo manager, as applyLiveArchive's: the view's
        // environment one is a fallback whenever the app isn't frontmost,
        // where the Edit menu never looks.
        var undoManager = activeUndoManager
        #if os(macOS)
        undoManager = HorizontalDocumentSaving.undoManager(url: project.url) ?? undoManager
        #endif
        boardRulesUndoTarget.registerUndo(from: previous, actionName: actionName, undoManager: undoManager)
    }

    private func handleRouteInspectorCommand(_ command: HorizontalRouteInspectorCommand) {
        switch command {
        case .selectLayer(let layer):
            if boardDrawingLayer != layer {
                selectOrSoloBoardLayer(layer)
            }
        case .useRuleWidth:
            boardToolSettings.setExplicitTrackWidth(nil)
            routeWidthCommand = HorizontalRouteWidthCommand()
        case .useCustomWidth(let width):
            guard width > 0 else { return }
            boardToolSettings.setExplicitTrackWidth(width)
        case .useRuleVia:
            boardToolSettings.setVia(diameter: nil, holeDiameter: nil)
        case .useCustomVia(let diameter, let holeDiameter):
            guard diameter > 0, holeDiameter > 0 else { return }
            boardToolSettings.setVia(diameter: diameter, holeDiameter: holeDiameter)
        case .editRule(let edit):
            applyRouteRuleEdit(edit)
        case .defineWidthRule(let edit):
            // The width the rules now give is the custom one, which the route
            // then takes from them.
            guard applyRouteRuleEdit(edit) else { return }
            boardToolSettings.setExplicitTrackWidth(nil)
            routeWidthCommand = HorizontalRouteWidthCommand()
        case .defineViaRule(let edit):
            guard applyRouteRuleEdit(edit) else { return }
            boardToolSettings.setVia(diameter: nil, holeDiameter: nil)
        case .showRules(let kind, let ruleID):
            showBoardRulesWindow(focus: HorizontalBoardRuleFocus(kind: kind, ruleID: ruleID))
        }
    }

    /// The track tool started or ended: an open sidebar turns to the route
    /// inspector, and goes back to the pane it showed when the route ends. A
    /// closed sidebar stays closed, and an open one is never closed.
    private func routingChanged(_ isRouting: Bool) {
        if isRouting {
            guard !seesRouting else { return }
            seesRouting = true
            sidebarRestoreTask?.cancel()
            sidebarRestoreTask = nil
            guard sidebarBeforeRouting == nil, let pane = rightSidebarPane, pane != .selection else { return }
            sidebarBeforeRouting = SidebarBeforeRouting(pane: pane)
            rightSidebarPane = .selection
        } else {
            seesRouting = false
            guard sidebarBeforeRouting != nil else { return }
            sidebarRestoreTask?.cancel()
            sidebarRestoreTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                // Not while a route is under way again, or once the sidebar
                // has a selection to show.
                guard !Task.isCancelled, !routeInspector.isRouting, selectionSidebarSections.isEmpty,
                      let before = sidebarBeforeRouting else { return }
                sidebarBeforeRouting = nil
                if rightSidebarPane == .selection {
                    rightSidebarPane = before.pane
                }
            }
        }
    }

    /// The project pool, where a via's padstack is read.
    private var boardPoolURL: URL? {
        project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
    }

    /// Apply & Check, the rules window's and the results sidebar's: every
    /// rule applied to the board as it stands, as Horizon's Apply gives them,
    /// as one undoable edit through the archive and a reload; then every
    /// check run, with the results in the sidebar. The rules are applied as
    /// the board and they change, so applying here catches up a board that
    /// disagrees with them, as one Horizon wrote can.
    private func checkAndApplyBoardRules() {
        if !isReadOnly, var board = project.board {
            let changes = HorizontalBoardRuleApplication.apply(to: &board, poolURL: boardPoolURL)
            if changes.summary != nil {
                do {
                    var archive = document.archive
                    try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
                    try applyLiveArchive(archive, actionName: "Apply Board Rules")
                } catch {
                    recordArchiveApplyFailure(error)
                }
            }
        }
        refreshRulesResults()
        rightSidebarPane = .rulesResults
    }

    /// A change to the design or its rules: every check runs again while
    /// they run on their own, and while they run only when asked, what the
    /// sidebar shows is marked out of date.
    private func rulesInputsChanged() {
        if checksRulesAutomatically {
            refreshRulesResults()
        } else {
            rulesResultsState?.isOutOfDate = true
        }
    }

    /// A change to the board's copper or fills alone: the board checks run
    /// again, as `rulesInputsChanged` has them.
    private func boardChangedForRules() {
        if checksRulesAutomatically {
            scheduleClearanceCheck()
        } else {
            rulesResultsState?.isOutOfDate = true
        }
    }

    /// The rules checks over every kind, as the board's rules now stand, so
    /// the results sidebar and its toolbar badge say what is wrong without a
    /// run in the rules window first; what Check Now runs.
    private func refreshRulesResults() {
        guard project.board != nil, let rules = try? HorizontalProjectJSONApplicator.boardRules(in: project, from: document.archive) else {
            clearanceCheckTask?.cancel()
            clearanceCheckTask = nil
            schematicCheckTask?.cancel()
            schematicCheckTask = nil
            rulesResultsState = nil
            return
        }
        let context = HorizontalBoardRuleContext(board: project.board, netClasses: selectedSchematic?.sheet.netClasses ?? [])
        rulesResultsState = HorizontalBoardRulesResultState(
            ruleTitle: "Design Rules",
            messages: HorizontalBoardRulesValidator.validateAll(rules: rules, context: context),
            clearanceFindings: rulesResultsState?.clearanceFindings,
            boardFindings: rulesResultsState?.boardFindings,
            schematicFindings: rulesResultsState?.schematicFindings
        )
        scheduleClearanceCheck()
        scheduleSchematicCheck()
    }

    /// The schematic's Connectivity rule, in the background, on the design as
    /// the archive now holds it, for the results sidebar, its badge and the
    /// sheets' markers; as the clearance check, it waits for edits to settle
    /// and keeps the last findings up until the new ones are in.
    private func scheduleSchematicCheck() {
        schematicCheckTask?.cancel()
        guard rulesResultsState != nil, let rules = schematicRules(in: document.archive) else {
            schematicCheckTask = nil
            // No schematic, nothing to find.
            rulesResultsState?.schematicFindings = []
            rulesResultsState?.isCheckingSchematic = false
            return
        }
        rulesResultsState?.isCheckingSchematic = true
        let checked = project
        let archive = document.archive
        schematicCheckTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  let findings = await HorizontalSchematicRulesCheck.backgroundFindings(project: checked, archive: archive, rules: rules),
                  !Task.isCancelled else {
                return
            }
            rulesResultsState?.schematicFindings = findings
            rulesResultsState?.isCheckingSchematic = false
            schematicCheckTask = nil
        }
    }

    /// The board's rules checks (`HorizontalBoardRulesCheck`), in the
    /// background, on the board as it stands, for the results sidebar, its
    /// badge and the board's markers. An edit often comes with others, so
    /// the check waits for them to settle; a later one cancels it. The last
    /// findings stay up until the new ones are in.
    private func scheduleClearanceCheck() {
        clearanceCheckTask?.cancel()
        guard let board = project.board, rulesResultsState != nil else {
            clearanceCheckTask = nil
            return
        }
        rulesResultsState?.isCheckingClearance = true
        let tiedNets = HorizontalBoardClearanceCheck.tiedNets(of: project)
        clearanceCheckTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  let results = await HorizontalBoardRulesCheck.results(board: board, tiedNets: tiedNets),
                  !Task.isCancelled else {
                return
            }
            rulesResultsState?.clearanceFindings = results.clearance
            rulesResultsState?.boardFindings = results.findings
            rulesResultsState?.isCheckingClearance = false
            clearanceCheckTask = nil
        }
    }

    /// A title-block value edited in the information panel goes through the
    /// archive and a reload, like other edits: the loader bakes the values into
    /// each sheet's title block and the board's texts, so patching the model
    /// alone left the drawing showing the old value. The schematic's own copy
    /// of a key, which older files keep and which wins on its sheets, changes
    /// with the block's. The reload also puts the change on the undo stack.
    private func applyEditedProjectMetadata(key: String, value: String) {
        guard !isReadOnly else {
            return
        }
        do {
            var archive = document.archive
            let changed = try HorizontalProjectJSONApplicator.apply(
                titleBlockChanges: HorizontalTitleBlockChanges(key: key, value: value),
                in: project,
                to: &archive
            )
            guard !changed.isEmpty else {
                return
            }
            try applyLiveArchive(archive, actionName: "Edit Project Metadata")
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// The block's power nets for the editor popover, as the sheet being
    /// edited knows them.
    private var powerNetSummaries: [HorizontalPowerNetSummary] {
        project.schematic?.powerNetSummaries(currentSheetID: selectedSchematic?.sheet.id) ?? []
    }

    /// Design ▸ Power Nets…: the editor popover on the schematic rail, or
    /// the plain net prompt when the rail is hidden.
    private func showPowerNets() {
        guard selectedSchematic != nil else {
            return
        }
        visiblePanes.insert(.schematic)
        if !isDistractionFree, !isWindowToolbarHidden {
            powerNetsPopoverPresented = true
        } else {
            canvasCommandActionsByPane[.schematic]?.dispatch(.placePowerSymbol)
        }
    }

    private func boardAirwireFilterButton(board: HorizontalBoard?) -> some View {
        BoardAirwireFilterToolButton(
            board: board,
            displayOptions: $boardDisplayOptions,
            isPresented: $isBoardAirwireFilterPresented,
            highlightedNetIDs: activeHighlightedNetIDs,
            onHighlightNets: highlightSelectedNet
        )
    }

    private func boardAirwireFilterPanel(board: HorizontalBoard?) -> some View {
        BoardAirwireFilterPanel(
            board: board,
            displayOptions: $boardDisplayOptions,
            highlightedNetIDs: activeHighlightedNetIDs,
            onHighlightNets: highlightSelectedNet
        )
    }

    /// Board options with the working layer stamped in, so the layer selected in
    /// the layer list renders even when its eye is off, and the board's copper,
    /// which the layer mode finds the working layer's neighbours in. Derived per
    /// hand-off rather than stored, which keeps the selection in one place
    /// (`boardDrawingLayer`) instead of two that could disagree.
    private var boardCanvasDisplayOptions: BoardDisplayOptions {
        var options = boardDisplayOptions
        options.selectedLayer = boardDrawingLayer
        options.soloLayer = soloedBoardLayer
        options.copperStack = project.board?.copperStack
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
    /// asked to show. The tools go on the preset's side, as the rail's preset
    /// buttons put them: the working layer always shows, so top copper left
    /// working would show in a bottom view.
    private func applyBoardLayerViewPreset(_ preset: HorizontalBoardLayerViewPreset) {
        soloedBoardLayer = nil
        boardDisplayOptions.applyLayerPreset(preset.layerPreset)
        if let layer = preset.layerPreset.drawingLayer {
            boardDrawingLayer = layer
        }
    }

    private func updateAllBoardPlanes() {
        guard !isReadOnly else {
            return
        }
        guard let board = project.board, !board.planes.isEmpty else {
            // Nothing to pour, but Q still refreshes the silkscreen clip.
            planePourRevision += 1
            return
        }
        requestPlanePour(for: board, isManual: true, registersUndo: true)
    }

    /// Persists a plane create/edit the canvas already applied to `editedBoard`
    /// (a drawn or defined plane, changed settings), then pours it so the fill
    /// shows at once. The definition lands first, under the named undo, so it
    /// survives whatever happens to the pour: a pour is discarded when the
    /// board moves under it, and that must only ever cost the fills. (Pouring
    /// the edit and applying the result afterwards lost the plane entirely:
    /// the project board never matched a board with one more plane on it.)
    private func applyBoardPlaneEdit(_ editedBoard: HorizontalBoard, actionName: String) {
        guard !isReadOnly, let previousBoard = project.board else {
            return
        }
        registerBoardPlaneEditUndo(previousBoard, actionName: actionName)
        applyEditedBoard(editedBoard)
        if let board = project.board, !board.planes.isEmpty {
            requestPlanePour(for: board, isManual: true, registersUndo: false)
        }
    }

    /// Whether the fills still match the board, and, when the planes update
    /// automatically, a pour for the board when they don't. Every change to
    /// the board ends here: the funnels call it at once, and a change to
    /// `boardEditRevision` that none of them made calls it when SwiftUI
    /// next updates. `again` checks a revision already checked, for a change
    /// of setting rather than of board.
    private func checkPlaneFills(again: Bool = false) {
        guard again || checkedPlaneInputsRevision != boardEditRevision else {
            return
        }
        checkedPlaneInputsRevision = boardEditRevision
        guard let board = project.board, !board.planes.isEmpty else {
            planesNeedUpdate = false
            return
        }
        let inputs = HorizontalBoardPlaneInputs.signature(of: board)
        guard let pouredPlaneInputs else {
            // First sight of the board: the fills its files hold are its own.
            // Opening a document must not pour it, which would mark it edited.
            self.pouredPlaneInputs = inputs
            planesNeedUpdate = false
            return
        }
        planesNeedUpdate = inputs != pouredPlaneInputs
        if planesNeedUpdate, updatesPlanesAutomatically, !isReadOnly {
            requestPlanePour(for: board, inputs: inputs)
        }
    }

    private func requestPlanePour(for board: HorizontalBoard, inputs: Int? = nil, isManual: Bool = false, registersUndo: Bool = false) {
        planePourScheduler.request(HorizontalPlanePourRequest(
            board: board,
            inputs: inputs ?? HorizontalBoardPlaneInputs.signature(of: board),
            isManual: isManual,
            registersUndo: registersUndo,
            makesPlanesFile: project.planesFilename != nil,
            knownFragmentKeys: planeFillDelivery?.fragmentKeys ?? []
        ))
    }

    /// Takes a finished pour into the board, if the board still has the
    /// copper it was poured around. Only the fills and the airwires change,
    /// so the board canvas takes them in place (`planeFillDelivery`) rather
    /// than being reset, and nothing else is written: the board's own file
    /// holds no fill, and the planes file the pour made already. A pour has
    /// no undo step of its own unless it is Q's; Undo of the edit it follows
    /// puts the board back with the fills it had.
    ///
    /// The live channel's revision does not move: an automation client
    /// planning against the board would otherwise find it changed by every
    /// pour it set off.
    private func applyPouredPlanes(_ result: HorizontalPlanePourResult) {
        guard !isReadOnly, var board = project.board else {
            return
        }
        guard HorizontalBoardPlaneInputs.signature(of: board) == result.fills.inputs else {
            // The board moved while this pour ran. An automatic pour for it
            // is already asked for; a manual one leaves the fills marked out
            // of date, and one press of Q redoes the work.
            checkPlaneFills(again: true)
            return
        }
        let previousBoard = board
        board.takePlaneFills(result.fills)
        if result.registersUndo {
            registerBoardPlaneUpdateUndo(previousBoard)
        }
        project.board = board
        pouredPlaneInputs = result.fills.inputs
        planesNeedUpdate = false
        if let data = result.planesFileData {
            writePlanesFile(data, registersUndo: result.registersUndo)
        }
        planeFillRevision += 1
        planeFillDelivery = HorizontalPlaneFillDelivery(revision: planeFillRevision, result: result)
        if result.isManual {
            // Q doubles as the silkscreen re-clip; a pour after an edit does
            // not, since the re-clip rebuilds the whole scene.
            planePourRevision += 1
        }
    }

    /// The planes file a pour made, into the archive. A step of its own only
    /// for Q, whose undo registration this joins.
    private func writePlanesFile(_ data: Data, registersUndo: Bool) {
        var archive = document.archive
        do {
            guard try HorizontalProjectJSONApplicator.applyPlaneCache(data: data, in: project, to: &archive) else {
                return
            }
        } catch {
            recordArchiveApplyFailure(error)
            return
        }
        guard !registersUndo else {
            document.archive = archive
            return
        }
        withoutUndoRegistration {
            document.archive = archive
        }
        #if os(macOS)
        // With nothing registered the document wouldn't know it changed.
        HorizontalDocumentSaving.markEdited(url: project.url)
        #endif
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
        boardEditRevision += 1
        selectionDetailsByPane[.board] = .empty
    }

    /// A pool item saved from its own editor window that lives inside this
    /// project's pool. The in-memory archive still holds the file as it was
    /// opened, and the next project save writes every differing file back to
    /// disk — so without this refresh that save would put the stale copy over
    /// the edit. Then the board is re-read from the refreshed archive (kept in
    /// memory, no write) so a changed package or padstack shows at once.
    /// A pool item saved from an item editor. One of this project's own
    /// takes effect at once, as Horizon's editors reload the pool when it
    /// changes: the archive takes the file and the whole project reloads, its
    /// schematic and parts as well as its board. One in a pool the project
    /// draws from leaves the project's copy as it was; the parts review runs
    /// again, and the info bar says what fell behind.
    private func handlePoolItemSaved(_ payload: HorizontalPoolLibrary.ItemDidSavePayload) {
        partLibrary.recheck()
        guard !isReadOnly,
              case .directory = document.archive.root,
              let relativePath = archiveRelativePath(for: payload.url) else {
            return
        }
        do {
            try document.archive.replaceRegularFileData(relativePath: relativePath, with: payload.data)
            var reloaded = try HorizontalProject.loadSnapshot(of: document.archive)
            if project.poolModelFiles != nil {
                try reloaded.retainPoolModels(in: document.archive, reusing: project.poolModelFiles)
            }
            rebaseProjectURLs(&reloaded, onto: project)
            installLiveSnapshot(HorizontalLiveSnapshot(archive: document.archive, project: reloaded), installsArchive: false)
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// Where `url` lives inside the document archive, or nil when it is not
    /// part of this project (the applicator resolves paths the same way).
    private func archiveRelativePath(for url: URL) -> String? {
        if let path = document.archive.manifest?.relativePath(for: url) {
            return path
        }
        let base = project.baseURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else {
            return nil
        }
        return String(target.dropFirst(prefix.count))
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
        board.removePlanesWithDeletedNets()
    }

    private func rebasePackageModelURLs(in board: inout HorizontalBoard) {
        guard let poolURL = project.poolDirectory.map({ project.baseURL.appendingPathComponent($0) }) else {
            return
        }
        board.rebasePackageModelURLs(poolURL: poolURL)
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

    /// Runs a canvas tool's edit operations against the whole project.
    ///
    /// The objects these tools draw — a bus and its members, a net tie — live
    /// in the block as much as on the sheet, which the sheet applier cannot
    /// reach. What comes back is a whole archive, so it lands the same way an
    /// edit from the automation channel does: the document adopts it, the
    /// project reloads, and the step goes on the undo stack under the tool's
    /// own name.
    /// The block whose schematic is at `url`, when it isn't the top one:
    /// what an edit made on that schematic's sheets names as its `block`.
    private func subBlockID(forSchematicURL url: URL) -> String? {
        let url = url.standardizedFileURL
        let block = project.schematics.first { $0.schematic.url.standardizedFileURL == url }?.block
        return block?.isTop == false ? block?.uuid : nil
    }

    /// `schematicURL` is the schematic the edit was made on: its block is
    /// the one edited, so a net renamed on a sub-block's sheet is renamed in
    /// that block rather than looked for in the top one.
    private func applyProjectEdit(_ operations: [JSONDictionary], actionName: String, schematicURL: URL? = nil) {
        guard !isReadOnly, !operations.isEmpty else {
            return
        }
        do {
            let edited = try HorizontalCanvasProjectEdit.archive(
                applying: operations,
                to: document.archive,
                in: project,
                block: schematicURL.flatMap(subBlockID(forSchematicURL:))
            )
            try applyLiveArchive(edited.archive, actionName: actionName)
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    // MARK: - Blocks

    struct BlockTrailStep: Equatable {
        /// The sheet the block was opened from.
        var parent: ProjectNavigatorSelection
        var parentSheetName: String
        /// The block opened, and the instance it was opened through.
        var blockID: String
        var instanceID: String
        var refdes: String
    }

    /// Horizon's instance path for the sheet showing: the instances it was
    /// reached through from the top block, when it was reached that way. Its
    /// components then show, and take, that instance's own refdes.
    private var currentInstancePath: [String]? {
        guard let last = blockTrail.last, let first = blockTrail.first else { return nil }
        switch navigatorSelection {
        case .sheet(let blockID, _) where blockID.caseInsensitiveCompare(last.blockID) == .orderedSame:
            break
        default:
            return nil
        }
        guard case .sheet(let firstParent, _) = first.parent,
              project.blocks.first(where: { $0.uuid.caseInsensitiveCompare(firstParent) == .orderedSame })?.isTop == true else {
            return nil
        }
        for (step, next) in zip(blockTrail, blockTrail.dropFirst()) {
            guard case .sheet(let parent, _) = next.parent, parent.caseInsensitiveCompare(step.blockID) == .orderedSame else {
                return nil
            }
        }
        return blockTrail.map { $0.instanceID.lowercased() }
    }

    /// Sheets reached by `path` with their frames numbered across the
    /// design, as Horizon numbers a hierarchy's pages; a design without
    /// instances keeps its own numbers.
    private func pageNumbered(_ sheets: [HorizontalSchematicSheet], path: [String]) -> [HorizontalSchematicSheet] {
        guard project.flattenedBlock?.isHierarchical == true else {
            return sheets
        }
        let pages = project.schematicPages
        return sheets.map { sheet in
            guard let page = pages.first(where: { $0.path == path && $0.sheet.id == sheet.id }) else { return sheet }
            return sheet.numbered(page.number, of: pages.count)
        }
    }

    /// The refdes an instance path's mapping gives its block's components.
    private func instanceRefdes(_ path: [String]) -> [String: String] {
        project.flattenedBlock?.instanceRefdes[path.joined(separator: "/")] ?? [:]
    }

    /// The schematic at `url` is showing through an instance: its path, and
    /// the refdes and do-not-populate the canvas draws for it.
    private func instanceView(forSchematicURL url: URL) -> (path: [String], refdes: [String: String], noPopulate: [String: Bool])? {
        guard let path = currentInstancePath, let last = blockTrail.last,
              let schematic = project.schematics.first(where: { $0.block.uuid.caseInsensitiveCompare(last.blockID) == .orderedSame }),
              schematic.schematic.url.standardizedFileURL == url.standardizedFileURL else {
            return nil
        }
        return (path, instanceRefdes(path), project.flattenedBlock?.instanceNoPopulate[path.joined(separator: "/")] ?? [:])
    }

    /// A sheet edited through an instance, with its components' own refdes
    /// back, as the block keeps them: an instance's are its mapping's.
    private func definitionSheet(_ sheet: HorizontalSchematicSheet, schematicURL: URL) -> HorizontalSchematicSheet {
        guard instanceView(forSchematicURL: schematicURL) != nil,
              let original = project.schematics.first(where: { $0.schematic.url.standardizedFileURL == schematicURL.standardizedFileURL })?
                .schematic.sheets.first(where: { $0.id == sheet.id }) else {
            return sheet
        }
        return sheet.showingRefdes(original.drawnRefdes)
    }

    /// Runs block ops through the edit vocabulary as one undoable step,
    /// `block` the block they edit (the top one when nil). Returns what
    /// they changed, or nil when refused, which is said.
    @discardableResult
    private func applyBlockEdit(_ operations: [JSONDictionary], block: String? = nil, actionName: String) -> [JSONDictionary]? {
        guard !isReadOnly else {
            return nil
        }
        do {
            let edited = try HorizontalCanvasProjectEdit.archive(applying: operations, to: document.archive, in: project, block: block)
            try applyLiveArchive(edited.archive, actionName: actionName)
            return edited.changes
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
            return nil
        }
    }

    /// The top schematic's annotation options, as Horizon keeps them.
    private var annotationOptions: HorizontalAnnotationOptions {
        let top = project.blocks.first(where: \.isTop)
        return HorizontalAnnotationOptions(json: documentJSON(top?.schematicFilename ?? project.schematicFilename)?.dictionary("annotation"))
    }

    /// Horizon's Annotate, over the whole design, on one undo step.
    private func annotate(_ options: HorizontalAnnotationOptions) {
        guard let changes = applyBlockEdit([options.operation], actionName: "Annotate"),
              let count = changes.first?["annotated"] as? Int else {
            return
        }
        schematicEditMessage = count == 0 ? "Every part was annotated already." : "Annotated \(count) part\(count == 1 ? "" : "s")."
    }

    /// Horizon's Add Block. Returns the new block's id.
    private func addBlock(named name: String) -> String? {
        applyBlockEdit([["op": "add_block", "name": name]], actionName: "New Block")?.first?["block"] as? String
    }

    private func renameBlock(_ blockID: String, to name: String) {
        applyBlockEdit([["op": "rename_block", "block": blockID, "name": name]], actionName: "Rename Block")
    }

    private func removeBlock(_ blockID: String) -> Bool {
        let removed = applyBlockEdit([["op": "remove_block", "block": blockID]], actionName: "Delete Block") != nil
        if removed {
            blockTrail.removeAll { $0.blockID.caseInsensitiveCompare(blockID) == .orderedSame }
        }
        return removed
    }

    /// The block the schematic showing belongs to.
    /// Horizon sets do not populate only in the hierarchy: on the top
    /// block's sheets, or a block's reached through an instance of it — not
    /// on a block opened by itself, which no board is made from.
    private func canSetNoPopulate(in selectedSchematic: SelectedSchematic) -> Bool {
        !isReadOnly && (block(of: selectedSchematic)?.isTop != false || instanceView(forSchematicURL: selectedSchematic.url) != nil)
    }

    /// Horizon's Mark do not populate / Mark populate, one undo step: through
    /// an instance it is that instance's, written to its mapping, and the
    /// block's own is left alone, as for a refdes.
    private func applyEditedNoPopulate(componentIDs: [String], noPopulate: Bool, selectedSchematic: SelectedSchematic) {
        let instance = instanceView(forSchematicURL: selectedSchematic.url)?.path.joined(separator: "/")
        let operations: [JSONDictionary] = componentIDs.map { componentID in
            var operation: JSONDictionary = ["op": "set_no_populate", "component": componentID, "no_populate": noPopulate]
            if let instance { operation["instance"] = instance }
            return operation
        }
        applyProjectEdit(operations, actionName: noPopulate ? "Mark Do Not Populate" : "Mark Populate", schematicURL: selectedSchematic.url)
    }

    private func block(of selectedSchematic: SelectedSchematic) -> HorizontalProjectBlock? {
        let url = selectedSchematic.url.standardizedFileURL
        return project.schematics.first { $0.schematic.url.standardizedFileURL == url }?.block
    }

    /// Which blocks each block draws instances of, by lowercased uuid.
    private var drawnBlockUses: [String: Set<String>] {
        project.schematics.reduce(into: [String: Set<String>]()) { result, schematic in
            result[schematic.block.uuid.lowercased(), default: []].formUnion(
                schematic.schematic.sheets.flatMap { $0.blockSymbols.map(\.blockID) }
            )
        }
    }

    /// The blocks the sheet showing can place: not the top one, not its own
    /// block, and not one that uses its block, however deep (Horizon's
    /// `can_add_block_instance`).
    private var placeableBlockIDs: Set<String> {
        guard let selectedSchematic, let current = block(of: selectedSchematic)?.uuid.lowercased() else {
            return []
        }
        let uses = drawnBlockUses
        func reaches(_ start: String) -> Set<String> {
            var seen = Set<String>(), pending = [start]
            while let next = pending.popLast() {
                for child in uses[next] ?? [] where seen.insert(child).inserted { pending.append(child) }
            }
            return seen
        }
        return Set(project.blocks.filter { !$0.isTop }.map { $0.uuid.lowercased() }.filter { $0 != current && !reaches($0).contains(current) })
    }

    private var placeBlockChoices: [PlaceBlockToolButton.Choice] {
        let placeable = placeableBlockIDs
        return project.blocks.filter { !$0.isTop }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { PlaceBlockToolButton.Choice(id: $0.uuid, name: $0.displayName, isEnabled: placeable.contains($0.uuid.lowercased())) }
    }

    /// The JSON a project file holds in the document as it stands.
    private func documentJSON(_ relativePath: String?) -> JSONDictionary? {
        guard let relativePath, !relativePath.isEmpty,
              let path = archiveRelativePath(for: project.baseURL.appendingPathComponent(relativePath)),
              let data = document.archive.regularFileData(relativePath: path) else {
            return nil
        }
        return try? JSONHelper.loadDictionary(from: data)
    }

    /// Horizon's Place Block on the sheet showing: the block's symbol
    /// follows the cursor there until a click places an instance of it.
    private func placeBlock(_ blockID: String) {
        guard !isReadOnly, selectedSchematic != nil,
              let block = project.blocks.first(where: { $0.uuid.caseInsensitiveCompare(blockID) == .orderedSame }) else {
            return
        }
        guard placeableBlockIDs.contains(block.uuid.lowercased()) else {
            projectEditError = "\(block.displayName) can't be placed here: a block can't use itself, or a block that uses it."
            return
        }
        guard let symbolFilename = block.symbolFilename, let symbolJSON = documentJSON(symbolFilename) else {
            projectEditError = "\(block.displayName) has no symbol to draw it with."
            return
        }
        let resource = HorizontalSchematicBlockResource(
            symbolURL: project.baseURL.appendingPathComponent(symbolFilename),
            blockJSON: documentJSON(block.blockFilename),
            fallbackName: block.displayName
        )
        visiblePanes.insert(.schematic)
        activeCanvasCommandPane = .schematic
        pendingBlockPlacement = HorizontalBlockPlacementRequest(blockSymbol: HorizontalSchematicBlockSymbol(
            id: "", instanceID: "", blockID: block.uuid.lowercased(), refdes: "I?", placement: .identity,
            connections: [:], resource: resource, symbolJSON: symbolJSON
        ))
    }

    private var isEditingBlockSymbol: Bool {
        if case .blockSymbol = navigatorSelection { return true }
        return false
    }

    /// The block symbol editor's symbol, read from the document as it stands.
    private func blockSymbolForEditing(_ blockID: String) -> HorizontalBlockSymbol? {
        guard let block = project.blocks.first(where: { $0.uuid.caseInsensitiveCompare(blockID) == .orderedSame }),
              let symbolJSON = documentJSON(block.symbolFilename) else {
            return nil
        }
        return try? HorizontalBlockSymbol(symbolJSON: symbolJSON, blockJSON: documentJSON(block.blockFilename), name: block.displayName)
    }

    private func portNetSummaries(blockID: String, blockSymbol: HorizontalBlockSymbol) -> [HorizontalPortNetSummary] {
        let sheets = project.schematics.first { $0.block.uuid.caseInsensitiveCompare(blockID) == .orderedSame }?.schematic.sheets ?? []
        return blockSymbol.portNets.map { portID, net in
            HorizontalPortNetSummary(
                id: net.netID,
                name: net.name,
                direction: HorizontalPinDirection(rawValue: net.direction) ?? .bidirectional,
                isPlaced: blockSymbol.symbol.pins[portID] != nil,
                isInUse: sheets.contains { $0.containsAnyNet([net.netID]) }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A gesture in the block symbol editor: the symbol file as it now is.
    private func applyEditedBlockSymbol(_ blockSymbol: HorizontalBlockSymbol, blockID: String) {
        guard !isReadOnly,
              let block = project.blocks.first(where: { $0.uuid.caseInsensitiveCompare(blockID) == .orderedSame }),
              let symbolFilename = block.symbolFilename else {
            return
        }
        do {
            try HorizontalProjectJSONApplicator.apply(
                blockSymbol: blockSymbol.json(),
                symbolURL: project.baseURL.appendingPathComponent(symbolFilename),
                in: project,
                to: &document.archive
            )
            blockSymbolNeedsReload = true
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// Horizon's Manage Port Nets, as edits of the block.
    private func applyPortNetCommand(_ command: HorizontalPortNetCommand, blockID: String) {
        switch command {
        case .add(let name):
            applyBlockEdit([["op": "ensure_net", "name": name], ["op": "set_net_port", "net": name]],
                           block: blockID, actionName: "Add Port Net")
        case .rename(let netID, let name):
            applyBlockEdit([["op": "rename_net", "net": netID, "name": name]], block: blockID, actionName: "Rename Port Net")
        case .setDirection(let netID, let direction):
            applyBlockEdit([["op": "set_net_port", "net": netID, "port_direction": direction.rawValue]],
                           block: blockID, actionName: "Set Port Direction")
        case .delete(let netID):
            applyBlockEdit([["op": "set_net_port", "net": netID, "is_port": false], ["op": "retire_net", "net": netID]],
                           block: blockID, actionName: "Delete Port Net")
        }
        blockSymbolNeedsReload = false
    }

    /// The project again from the document, so every sheet draws what the
    /// files now say.
    private func reloadProjectFromArchive() {
        blockSymbolNeedsReload = false
        do {
            var reloaded = try HorizontalProject.loadSnapshot(of: document.archive)
            rebaseProjectURLs(&reloaded, onto: project)
            installLiveSnapshot(HorizontalLiveSnapshot(archive: document.archive, project: reloaded), installsArchive: false)
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// Horizon's Push into block: the block a block symbol uses, at its
    /// first sheet, remembering where it was opened from.
    private func openBlock(_ blockSymbol: HorizontalSchematicBlockSymbol, from selectedSchematic: SelectedSchematic) {
        guard let schematic = project.schematics.first(where: { $0.block.uuid.caseInsensitiveCompare(blockSymbol.blockID) == .orderedSame }),
              let firstSheet = schematic.schematic.sheets.first else {
            return
        }
        let parent: ProjectNavigatorSelection = block(of: selectedSchematic).map {
            .sheet(blockID: $0.uuid, sheetID: selectedSchematic.sheet.id)
        } ?? .standaloneSheet(selectedSchematic.sheet.id)
        // Opening a block from a sheet that isn't the end of the trail
        // starts a new one there.
        if let last = blockTrail.last, block(of: selectedSchematic)?.uuid.caseInsensitiveCompare(last.blockID) != .orderedSame {
            blockTrail.removeAll()
        }
        blockTrail.append(BlockTrailStep(parent: parent, parentSheetName: selectedSchematic.sheet.name,
                                         blockID: schematic.block.uuid, instanceID: blockSymbol.instanceID, refdes: blockSymbol.refdes))
        visiblePanes.insert(.schematic)
        navigatorSelection = .sheet(blockID: schematic.block.uuid, sheetID: firstSheet.id)
    }

    /// A block opened from a block symbol shows, so Leave Block has
    /// somewhere to go back to.
    private var canLeaveBlock: Bool {
        guard let step = blockTrail.last, case .sheet(let blockID, _) = navigatorSelection else { return false }
        return blockID.caseInsensitiveCompare(step.blockID) == .orderedSame
    }

    /// Horizon's Pop to parent block.
    private func leaveBlock() {
        guard let step = blockTrail.popLast() else {
            return
        }
        navigatorSelection = step.parent
    }

    /// The way back out of a block opened from a block symbol, while one of
    /// its sheets shows.
    @ViewBuilder
    private func leaveBlockChip(for selectedSchematic: SelectedSchematic) -> some View {
        if let step = blockTrail.last,
           block(of: selectedSchematic)?.uuid.caseInsensitiveCompare(step.blockID) == .orderedSame {
            Button(action: leaveBlock) {
                Label {
                    Text(([blockTrail.first?.parentSheetName ?? step.parentSheetName] + blockTrail.map(\.refdes)).joined(separator: " \u{203A} "))
                } icon: {
                    Image(systemName: "chevron.backward")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Leave Block: back to \(step.parentSheetName), where \(step.refdes) is drawn")
            .accessibilityLabel("Leave Block")
        }
    }

    /// Horizon's Move to other sheet: `move_to_other_sheet` takes the items,
    /// and everything drawn connected to them, to the other sheet as one
    /// undoable edit; then that sheet shows, and the canvas there picks up
    /// what arrived to move it, as Horizon begins its Move tool.
    private func moveSchematicItems(_ items: [String], toSheet sheetID: String, from selectedSchematic: SelectedSchematic) {
        guard !isReadOnly, !items.isEmpty else {
            return
        }
        let url = selectedSchematic.url.standardizedFileURL
        let block = project.schematics.first { $0.schematic.url.standardizedFileURL == url }?.block
        do {
            let edited = try HorizontalCanvasProjectEdit.archive(
                applying: [["op": "move_to_other_sheet", "items": items, "sheet": selectedSchematic.sheet.id, "to_sheet": sheetID]],
                to: document.archive,
                in: project,
                block: subBlockID(forSchematicURL: selectedSchematic.url)
            )
            try applyLiveArchive(edited.archive, actionName: "Move to Other Sheet")
            let moved = edited.changes.first?.dictionary("moved") ?? [:]
            let refs = HorizontalSchematicMoveToSheet.refs(moved: moved)
            visiblePanes.insert(.schematic)
            navigatorSelection = block.map { .sheet(blockID: $0.uuid, sheetID: sheetID) } ?? .standaloneSheet(sheetID)
            pendingSchematicMove = HorizontalSchematicMoveRequest(
                sheetID: sheetID, refs: refs,
                placement: arrivalPlacement(HorizontalSchematicMoveToSheet.ids(moved: moved), refs: refs, sheetID: sheetID, schematicURL: url)
            )
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    /// What Move to Other Sheet brought onto `sheetID`, to place as a paste
    /// is placed; nil leaves the canvas its ordinary move.
    private func arrivalPlacement(
        _ ids: Set<String>, refs: [HorizontalSelectableRef], sheetID: String, schematicURL: URL
    ) -> HorizontalSchematicPastePlacement? {
        guard let sheet = project.schematics
            .first(where: { $0.schematic.url.standardizedFileURL == schematicURL })?.schematic.sheets
            .first(where: { $0.id.caseInsensitiveCompare(sheetID) == .orderedSame }),
              let paste = try? HorizontalSchematicClipboardEditor.arrival(
                  ids, refs: refs, on: sheet, schematicURL: schematicURL, archive: document.archive, project: project
              ) else {
            return nil
        }
        return HorizontalSchematicPastePlacement(paste: paste) { transform, wiring in
            do {
                try applyLiveArchive(paste.placedArchive(transform, in: document.archive, wiring: wiring,
                                                         schematicURL: schematicURL, project: project),
                                     actionName: "Move")
            } catch { projectEditError = HorizontalCanvasProjectEdit.message(for: error) }
        }
    }

    private func copySchematicSelection(
        _ refs: [HorizontalSelectableRef], from sheet: HorizontalSchematicSheet, anchor: HorizontalPoint, selectedSchematic: SelectedSchematic
    ) -> HorizontalSchematicClipboard? {
        do {
            // Locked .hprj documents may have loaded only their entry file.
            // Copy is read-only, but still needs the component/pool snapshot.
            var archive = document.archive
            if isReadOnly, let path = project.blockFilename, archive.regularFileData(relativePath: path) == nil {
                archive = try HorizontalProjectArchive.completeProject(from: project.url)
            }
            return try HorizontalSchematicClipboardEditor.copy(
                refs, from: sheet, schematicURL: selectedSchematic.url, anchor: anchor,
                archive: archive, project: project
            )
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
            return nil
        }
    }

    private func prepareSchematicPaste(
        _ clipboard: HorizontalSchematicClipboard, at point: HorizontalPoint, actionName: String,
        selectedSchematic: SelectedSchematic
    ) -> HorizontalSchematicPastePlacement? {
        guard !isReadOnly else { return nil }
        do {
            let paste = try HorizontalSchematicClipboardEditor.prepare(
                clipboard, at: point, sheetID: selectedSchematic.sheet.id, schematicURL: selectedSchematic.url,
                archive: document.archive, project: project
            )
            return HorizontalSchematicPastePlacement(paste: paste) { transform, wiring in
                do {
                    try applyLiveArchive(paste.placedArchive(transform, in: document.archive, wiring: wiring,
                                                             schematicURL: selectedSchematic.url, project: project),
                                         actionName: actionName)
                } catch { projectEditError = HorizontalCanvasProjectEdit.message(for: error) }
            }
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
            return nil
        }
    }

    private func deleteSchematicSelection(_ sheet: HorizontalSchematicSheet, schematicURL: URL) {
        guard !isReadOnly else { return }
        let sheet = definitionSheet(sheet, schematicURL: schematicURL)
        do {
            let archive = try HorizontalCanvasProjectEdit.archive(
                deletingSelectionFrom: sheet,
                schematicURL: schematicURL,
                to: document.archive,
                in: project
            )
            try applyLiveArchive(archive, actionName: "Delete")
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    /// A schematic edit that merged nets the project already had: the sheet
    /// is written, the merged nets are rewritten wherever else the project
    /// names them, and the project reloads, so every sheet and the board see
    /// one net, on one undo step.
    private func applyEditedSchematicSheet(
        _ sheet: HorizontalSchematicSheet,
        mergingNets merges: [String: String],
        actionName: String,
        schematicURL: URL
    ) {
        guard !isReadOnly else { return }
        let sheet = definitionSheet(sheet, schematicURL: schematicURL)
        do {
            var archive = document.archive
            try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematicURL, in: project, to: &archive)
            try HorizontalProjectJSONApplicator.apply(netMerges: merges, schematicURL: schematicURL, in: project, to: &archive)
            try applyLiveArchive(archive, actionName: actionName)
        } catch {
            projectEditError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    private func applyEditedSchematicSheet(_ sheet: HorizontalSchematicSheet, schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        let sheet = definitionSheet(sheet, schematicURL: schematicURL)
        let standardizedURL = schematicURL.standardizedFileURL
        let previousSignature = project.schematic?.sheets.first { $0.id == sheet.id }?.netlistSignature
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

        if previousSignature != sheet.netlistSignature {
            // The board's unplaced column follows at once; nets, pad
            // connections and airwires come with the reload behind it.
            refreshBoardPlaceableObjects(from: sheet)
            scheduleBoardNetlistSync()
        }
    }

    /// The board's unplaced-package column from the schematic's components,
    /// so a part placed on a sheet can be placed on the board straight away.
    private func refreshBoardPlaceableObjects(from sheet: HorizontalSchematicSheet) {
        guard var board = project.board else {
            return
        }
        let objects = HorizontalBoard.placeableObjects(fromSchematicComponents: sheet.componentInfo)
        guard objects != board.placeableObjects else {
            return
        }
        board.replacePlaceableObjects(objects)
        project.board = board
        boardEditRevision += 1
        boardSyncRevision += 1
    }

    /// Reloads the board from the archive once schematic edits have settled,
    /// off the main thread, so the board's nets, pad connections and airwires
    /// follow the schematic (Horizon reloads the netlist when the schematic
    /// is saved). One reload at a time; edits that land meanwhile get one
    /// more. A board edited while the reload ran is left alone and the
    /// reload runs again from the newer archive.
    private func scheduleBoardNetlistSync() {
        guard !isReadOnly, project.board != nil else {
            return
        }
        boardNetlistSyncRequested = true
        guard boardNetlistSyncTask == nil else {
            return
        }
        boardNetlistSyncTask = Task { @MainActor in
            defer { boardNetlistSyncTask = nil }
            while boardNetlistSyncRequested {
                boardNetlistSyncRequested = false
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else {
                    return
                }
                await performBoardNetlistSync()
            }
        }
    }

    private func performBoardNetlistSync() async {
        guard !isReadOnly, let previousBoard = project.board else {
            return
        }
        let archive = document.archive
        let revisionAtStart = boardEditRevision
        let reloaded: HorizontalProject
        do {
            reloaded = try await Task.detached(priority: .userInitiated) {
                try HorizontalProject.loadSnapshot(of: archive)
            }.value
        } catch {
            recordDiagnostic("Could not sync board with schematic data: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled, boardEditRevision == revisionAtStart else {
            // The board moved on while the snapshot loaded: go again from it.
            boardNetlistSyncRequested = true
            return
        }
        guard var syncedBoard = reloaded.board else {
            recordDiagnostic(BoardSyncError.missingBoard.localizedDescription)
            return
        }
        syncedBoard.url = previousBoard.url
        rebasePackageModelURLs(in: &syncedBoard)
        removePlanesWithDeletedNets(from: &syncedBoard)
        // A net that changed its class, or a track its net, takes what the
        // rules give it now.
        HorizontalBoardRuleApplication.apply(to: &syncedBoard, poolURL: boardPoolURL)
        // A pour that landed while the snapshot loaded is in memory, and may
        // not be in what the snapshot read.
        if let current = project.board {
            syncedBoard.carryPlaneFills(from: current)
        }
        applyFollowUpBoard(syncedBoard)
        // What the board was flattened from, for the BOM and the rest.
        project.flattenedBlock = reloaded.flattenedBlock
        boardSyncRevision += 1
        selectionDetailsByPane[.board] = .empty
    }

    /// Sheet edits go through the archive and a reload, like every other edit:
    /// the loader bakes each page's number, the page count and its title into
    /// the title block, and the page numbers into net labels' off-sheet
    /// references, so changing the model alone left the drawing saying the old
    /// numbers. The reload also puts the change on the undo stack.
    private func renameSheet(sheetID: String, to name: String, schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        do {
            var archive = document.archive
            try HorizontalProjectJSONApplicator.apply(
                sheetName: name,
                forSheetID: sheetID,
                schematicURL: schematicURL,
                in: project,
                to: &archive
            )
            try applyLiveArchive(archive, actionName: "Rename Sheet")
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// The navigator's Frame menu. Through the archive and a reload, like a
    /// rename: the loader draws the frame and bakes the title block into it.
    /// A frame from a base pool is cached into the project pool in the same
    /// edit, so undo takes both back.
    private func setSheetFrame(_ frame: HorizontalSheetFrameOption?, sheetID: String, schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        do {
            var archive = document.archive
            if let source = frame?.source {
                try HorizontalProjectJSONApplicator.cacheFrame(source, in: project, to: &archive)
            }
            try HorizontalProjectJSONApplicator.apply(
                sheetFrame: frame?.id,
                forSheetID: sheetID,
                schematicURL: schematicURL,
                in: project,
                to: &archive
            )
            try applyLiveArchive(archive, actionName: "Set Sheet Frame")
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    /// The navigator's New Sheet. Returns the new sheet's ID for the
    /// navigator to show it.
    private func addSheet(schematicURL: URL) -> String? {
        guard !isReadOnly else {
            return nil
        }
        do {
            var archive = document.archive
            let sheetID = try HorizontalProjectJSONApplicator.addSheet(schematicURL: schematicURL, in: project, to: &archive)
            try applyLiveArchive(archive, actionName: "New Sheet")
            return sheetID
        } catch {
            recordArchiveApplyFailure(error)
            return nil
        }
    }

    /// The navigator's Delete Sheet, for an empty sheet.
    private func removeSheet(_ sheetID: String, schematicURL: URL) -> Bool {
        guard !isReadOnly else {
            return false
        }
        do {
            var archive = document.archive
            try HorizontalProjectJSONApplicator.removeSheet(sheetID, schematicURL: schematicURL, in: project, to: &archive)
            try applyLiveArchive(archive, actionName: "Delete Sheet")
            return true
        } catch {
            recordArchiveApplyFailure(error)
            return false
        }
    }

    private func reorderSheets(_ orderedSheetIDs: [String], schematicURL: URL) {
        guard !isReadOnly else {
            return
        }
        do {
            var archive = document.archive
            try HorizontalProjectJSONApplicator.apply(
                sheetOrder: orderedSheetIDs,
                schematicURL: schematicURL,
                in: project,
                to: &archive
            )
            try applyLiveArchive(archive, actionName: "Reorder Sheets")
        } catch {
            recordArchiveApplyFailure(error)
        }
    }

    private func replace(_ sheet: HorizontalSchematicSheet, in schematic: inout HorizontalSchematic) {
        schematic.replaceSheet(sheet)
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
            boardEditRevision += 1
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
            boardEditRevision += 1
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
        // Through an instance, a refdes is that instance's: Horizon writes it
        // to the instance mapping and leaves the block's own alone.
        if let instance = instanceView(forSchematicURL: selectedSchematic.url) {
            applyProjectEdit([["op": "set_refdes", "component": normalizedComponentID, "refdes": refdes,
                               "instance": instance.path.joined(separator: "/")]],
                             actionName: "Set Reference Designator", schematicURL: selectedSchematic.url)
            return
        }

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
            boardEditRevision += 1
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
            board.packageTexts[index].redraw { $0.replacingOccurrences(of: oldRefdes, with: newRefdes) }
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

    private var projectEditErrorPresented: Binding<Bool> {
        Binding(
            get: { projectEditError != nil },
            set: { presented in
                if !presented {
                    projectEditError = nil
                }
            }
        )
    }

    private var libraryPlacementErrorPresented: Binding<Bool> {
        Binding(
            get: { libraryPlacementError != nil },
            set: { presented in
                if !presented {
                    libraryPlacementError = nil
                }
            }
        )
    }

    /// The Pools pane's Place and Replace, and its Place for a decal.
    private var libraryPartActions: HorizontalPoolPartActions {
        HorizontalPoolPartActions(
            place: isReadOnly || selectedSchematic == nil ? nil : { item in placePartFromLibrary(item) },
            placeUnavailableReason: isReadOnly
                ? "Read-only operation is enabled in Horizontal."
                : selectedSchematic == nil ? "This project has no schematic to place parts in." : nil,
            replacement: libraryPartReplacement,
            replace: isReadOnly ? nil : { item, packageName, replacement in
                replacePartsFromLibrary(item, packageName: packageName, replacement)
            },
            copyTargets: { item in
                // A part of this project's pool, which no attached pool has.
                guard let directory = project.poolDirectory,
                      HorizontalPoolLibrary.canonicalURL(item.poolURL) == HorizontalPoolLibrary.canonicalURL(project.baseURL.appendingPathComponent(directory)) else {
                    return []
                }
                return poolCopyTargets(forPart: item.uuid)
            },
            copyToPool: isReadOnly ? nil : { item, target in preparePoolCopy(partID: item.uuid, to: target) },
            placeDecal: isReadOnly || project.board == nil ? nil : { item in placeDecalFromLibrary(item) },
            placeDecalUnavailableReason: isReadOnly
                ? "Read-only operation is enabled in Horizontal."
                : project.board == nil ? "This project has no board to place decals on." : nil
        )
    }

    /// The block the schematic pane shows, for a selection made in a
    /// sub-block's sheet.
    private var selectedSchematicBlock: HorizontalProjectBlock? {
        guard let url = selectedSchematic?.url.standardizedFileURL else {
            return nil
        }
        return project.schematics.first { $0.schematic.url.standardizedFileURL == url }?.block
    }

    private func refreshLibraryPartReplacement() {
        let replacement = visiblePanes.contains(.library)
            ? HorizontalPartReplacement.current(componentIDs: selectedComponentIDs, archive: document.archive, project: project,
                                                preferredBlock: selectedSchematicBlock)
            : nil
        if replacement != libraryPartReplacement {
            libraryPartReplacement = replacement
        }
    }

    /// "Place in Schematic" from the Library pane: the part is cached into
    /// the project pool, then the placement starts exactly as from the Parts
    /// pane.
    private func placePartFromLibrary(_ item: HorizontalPoolLibraryItem) {
        guard !isReadOnly else {
            return
        }
        guard selectedSchematic != nil else {
            libraryPlacementError = "This project has no schematic to place “\(item.name)” in."
            return
        }
        do {
            beginPartPlacement(try cacheLibraryPart(item))
        } catch {
            libraryPlacementError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    /// "Place on Board" from the Pools pane: the board is shown, given the
    /// keyboard for R, E, S and Esc, and the decal follows the cursor there
    /// as one chosen in Place Decal…'s chooser does. The board's writer
    /// caches it into the project pool when it is put down.
    private func placeDecalFromLibrary(_ item: HorizontalPoolLibraryItem) {
        guard !isReadOnly, project.board != nil else {
            return
        }
        visiblePanes.insert(.board)
        activeCanvasCommandPane = .board
        pendingDecalPlacement = HorizontalBoardDecalPlacementRequest(item: item)
    }

    /// Replace from the Pools pane, Horizon's Assign Part: the part is cached
    /// into the project pool as Place caches it, then every selected
    /// component is given it with `set_part`, as one undoable edit. The
    /// entity stays, so their connections do, and the schematic and board
    /// reload showing the part's MPN, value and package. A package change
    /// under a routed component is refused before anything is written.
    private func replacePartsFromLibrary(_ item: HorizontalPoolLibraryItem, packageName: String, _ replacement: HorizontalPartReplacement) {
        guard !isReadOnly else {
            return
        }
        if let refusal = replacement.refusal(for: item, packageName: packageName, project: project, archive: document.archive) {
            libraryReplacementError = refusal
            return
        }
        do {
            let part = try cacheLibraryPart(item)
            let edited = try HorizontalCanvasProjectEdit.archive(
                applying: replacement.operations(partID: part.id),
                to: document.archive,
                in: project,
                block: replacement.blockID
            )
            try applyLiveArchive(edited.archive, actionName: replacement.targets.count == 1 ? "Replace Part" : "Replace Parts")
        } catch {
            libraryReplacementError = HorizontalCanvasProjectEdit.message(for: error)
        }
    }

    /// A Pools pane part and everything it needs cached into the project pool
    /// (Horizon's project pool cache), the open archive told of the new
    /// files, and the part as the project pool now has it.
    private func cacheLibraryPart(_ item: HorizontalPoolLibraryItem) throws -> HorizontalPoolPart {
        let poolURL = project.baseURL.appendingPathComponent(project.poolDirectory ?? HorizontalProjectArchive.projectPoolDirectoryName)
        // Documents made before new projects carried a pool have none: make
        // Horizon's project pool now, so the cache has a home.
        try ensureProjectPool(at: poolURL)
        let imported = try HorizontalPoolCacheImporter.cachePart(item, into: poolURL)
        if case .directory = document.archive.root {
            for url in imported.writtenFiles {
                if let relativePath = archiveRelativePath(for: url) {
                    try document.archive.replaceRegularFileData(relativePath: relativePath, with: Data(contentsOf: url))
                }
            }
        }
        if !imported.writtenFiles.isEmpty {
            HorizontalPoolLibrary.invalidateCache()
            HorizontalPoolPadstacks.invalidateCaches()
        }
        guard let part = HorizontalPoolPart.loadCached(id: item.uuid, from: poolURL) else {
            throw HorizontalDispatchError.failed("“\(item.name)” could not be read from the project pool after caching.")
        }
        if let index = project.poolParts.firstIndex(where: { $0.id == part.id }) {
            project.poolParts[index] = part
        } else {
            project.poolParts.append(part)
            project.poolParts.sort { $0.mpn.localizedStandardCompare($1.mpn) == .orderedAscending }
        }
        return part
    }

    /// Creates `pool/pool.json` (Horizon's project pool manifest) when the
    /// project has none, on disk and in the open archive.
    private func ensureProjectPool(at poolURL: URL) throws {
        let manifestURL = poolURL.appendingPathComponent("pool.json")
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }
        let data = HorizontalProjectArchive.projectPoolData(HorizontalProjectDocument.projectPoolTemplate())
        try FileManager.default.createDirectory(at: poolURL, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: [.atomic])
        if case .directory = document.archive.root, let relativePath = archiveRelativePath(for: manifestURL) {
            try document.archive.replaceRegularFileData(relativePath: relativePath, with: data)
        }
        HorizontalPoolLibrary.invalidateCache()
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

    /// Tab on the schematic or the board: with both open, the keyboard goes
    /// to the other; with only this one, the other is shown in its place,
    /// beside whatever else is open, and has the keyboard. Nothing happens
    /// when the project has no board or no schematic to go to.
    private func switchCanvasPane(from pane: HorizontalPane) {
        guard let other = pane.tabCounterpart,
              other == .board ? project.board != nil : selectedSchematic != nil else {
            return
        }
        activeCanvasCommandPane = other
        let panes = pane.panesAfterTab(from: visiblePanes)
        if panes != visiblePanes {
            visiblePanes = panes
        }
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
        case .block, .blockSymbol, .sheet, .standaloneSheet:
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
        ProjectMetadataRow.rows(for: project.projectMeta)
    }

    private var selectedSchematic: SelectedSchematic? {
        if let navigatorSelection {
            switch navigatorSelection {
            case .sheet(let blockID, let sheetID):
                if let schematic = project.schematics.first(where: { $0.block.uuid == blockID }),
                   let sheet = schematic.schematic.sheets.first(where: { $0.id == sheetID }) {
                    // Through an instance, its components show its refdes.
                    if let instance = instanceView(forSchematicURL: schematic.schematic.url) {
                        let names = blockTrail.map(\.refdes).joined(separator: "/")
                        let sheets = pageNumbered(
                            schematic.schematic.sheets.map { $0.showingRefdes(instance.refdes).showingNoPopulate(instance.noPopulate) },
                            path: instance.path
                        )
                        return SelectedSchematic(
                            subtitle: "\(schematic.block.displayName) \(names) / \(sheet.name)",
                            url: schematic.schematic.url,
                            blockURL: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                            sheets: sheets,
                            sheet: sheets.first { $0.id == sheet.id }
                                ?? sheet.showingRefdes(instance.refdes).showingNoPopulate(instance.noPopulate)
                        )
                    }
                    let sheets = schematic.block.isTop ? pageNumbered(schematic.schematic.sheets, path: []) : schematic.schematic.sheets
                    return SelectedSchematic(
                        subtitle: "\(schematic.block.displayName) / \(sheet.name)",
                        url: schematic.schematic.url,
                        blockURL: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                        sheets: sheets,
                        sheet: sheets.first { $0.id == sheet.id } ?? sheet
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

/// One field of the information panel's Project Metadata editor.
struct ProjectMetadataRow: Identifiable, Equatable {
    var key: String
    var title: String
    var value: String

    var id: String { key }

    static let preferredKeys = HorizontalTextVariableItem.preferredKeys

    /// A field for every key: the usual ones always, empty or not, then any
    /// other key the project has a value for. Two keys holding the same value
    /// are still two fields — a project often starts with its name and title
    /// alike, and hiding one left it unreachable, so renaming the title left
    /// the name behind.
    static func rows(for meta: [String: String]) -> [ProjectMetadataRow] {
        let others = meta.keys
            .filter { !preferredKeys.contains($0) && !(meta[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (preferredKeys + others).map { ProjectMetadataRow(key: $0, title: title(for: $0), value: meta[$0] ?? "") }
    }

    static func title(for key: String) -> String {
        HorizontalTextVariableItem.title(for: key)
    }
}

/// The pane the sidebar showed before routing turned it to the route
/// inspector.
private struct SidebarBeforeRouting: Equatable {
    var pane: HorizontalWorkspaceRightSidebar
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
    @ObservedObject var routeInspector: HorizontalRouteInspectorModel
    /// The board is visible. Hidden, its canvas stays mounted and keeps its
    /// track tool, whose route isn't shown until the board is again.
    var showsRoute = true
    var toolSettings: HorizontalBoardToolSettings
    var safeAreaInsets: EdgeInsets
    var foregroundColor: Color
    var backgroundColor: Color
    var isReadOnly: Bool
    var onChange: (HorizontalSelectionPropertyChange, HorizontalPane) -> Void
    var onNetSegmentSelectionCommand: (HorizontalNetSegmentSelectionCommand) -> Void
    var onRouteInspectorCommand: (HorizontalRouteInspectorCommand) -> Void

    private var isRouting: Bool {
        showsRoute && routeInspector.isRouting
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                if isRouting {
                    Section(routeInspector.tune != nil ? "Track Tuning" : "Track Route") {
                        HorizontalRouteInspectorView(
                            model: routeInspector,
                            toolSettings: toolSettings,
                            isReadOnly: isReadOnly,
                            onCommand: onRouteInspectorCommand
                        )
                        .padding(.vertical, 4)
                    }
                }
                if sections.isEmpty && netSegmentSelection == nil {
                    if !isRouting {
                        Section("Selection") {
                            Label("No selection", systemImage: "scope")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
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

/// A pane-info panel that summarises only when SwiftUI asks for its body,
/// which is while its popover is open. The pane rail builds its info content
/// on every workspace update, and a board summary walks every pad, package
/// and plane fragment, so building it eagerly cost a placement click or a
/// commit hundreds of milliseconds for a panel nobody had open.
private struct DeferredPaneInformationPanel: View {
    var summary: () -> NavigatorSelectionSummary

    var body: some View {
        PaneInformationPanel(summary: summary())
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

                        ProjectMetadataField(row: row, isEditable: isEditable, onChange: onChange)
                    }
                }
            }
        }
    }
}

/// One title-block value. It is applied when editing ends — Return, or the
/// field losing focus — rather than at every keystroke, because applying one
/// reloads the project so the sheets and the board redraw with it.
private struct ProjectMetadataField: View {
    var row: ProjectMetadataRow
    var isEditable: Bool
    var onChange: (String, String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(row.title, text: $draft)
            .font(.body)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
            .focused($isFocused)
            .onSubmit(commit)
            .onAppear { draft = row.value }
            // Closing the panel mid-edit keeps what was typed.
            .onDisappear(perform: commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            // An undo, or an automation client, can change the value under
            // the field; it shows the new one unless it is being typed in.
            .onChange(of: row.value) { _, value in
                if !isFocused { draft = value }
            }
    }

    private func commit() {
        guard draft != row.value else {
            return
        }
        onChange(row.key, draft)
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

/// Standard window chrome by default; the Transparent Toolbar preference makes
/// the title bar see-through. The canvas runs underneath the toolbar in both
/// states. On macOS 26 and later the title bar draws no background of its own
/// over full-size content either way; the standard toolbar's background is the
/// scroll-edge effect of the workspace's scroll view (see `workspaceDetail`).
/// `titlebarAppearsTransparent` still governs the title-bar material on
/// earlier systems.
///
/// `.fullSizeContentView` stays on either way. It is what keeps the toolbar
/// laid out across the split columns — sidebar toggle over the navigator, title
/// at the leading edge of the detail, controls at its trailing edge. Dropping
/// it for the opaque case rearranged every item into one packed row, so the two
/// states differed in layout and not just in background.
///
/// Pool item editors keep it too. They used to drop it for a plain title bar,
/// and every one of them could then be resized but not dragged by its title
/// bar, while project windows, which keep it, moved. An editor's title bar is
/// opaque instead: never transparent, with the toolbar background visible
/// (`ProjectDocumentView.body`), and its content below it in the safe area.
///
/// This runs on every SwiftUI update, so a property is written only when it
/// differs; rewriting the style mask makes AppKit rebuild the title bar.
struct WindowChromeConfigurator: NSViewRepresentable {
    var isTransparent: Bool
    /// An opaque title bar with the title shown (pool item editors), where the
    /// canvas windows follow the Transparent Toolbar preference.
    var usesStandardTitleBar = false

    func makeNSView(context: Context) -> ConfiguringView {
        let view = ConfiguringView()
        view.isTransparent = isTransparent
        view.usesStandardTitleBar = usesStandardTitleBar
        return view
    }

    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.isTransparent = isTransparent
        nsView.usesStandardTitleBar = usesStandardTitleBar
        nsView.configureWindow()
    }

    final class ConfiguringView: NSView {
        var isTransparent = false
        var usesStandardTitleBar = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else {
                return
            }

            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            let transparent = isTransparent && !usesStandardTitleBar
            if window.titlebarAppearsTransparent != transparent {
                window.titlebarAppearsTransparent = transparent
            }
            if usesStandardTitleBar {
                if window.titleVisibility != .visible {
                    window.titleVisibility = .visible
                }
                if window.backgroundColor != .windowBackgroundColor {
                    window.backgroundColor = .windowBackgroundColor
                }
            }
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
