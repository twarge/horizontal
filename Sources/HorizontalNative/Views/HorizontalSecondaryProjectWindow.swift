#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// What the windows of one project share: the project as the last window to
/// change it left it, and the selection and Spotlight, so a part picked on
/// one monitor is boxed on the other and a spotlight dims every window. Each
/// window keeps its own panes, view, tools and canvas selection. The project
/// window owns it; File ▸ New Window for Project (⌥⌘N) opens more windows on
/// it, purely to spread a project over several monitors.
@MainActor
final class HorizontalSharedProject: ObservableObject {
    @Published var selectedNetIDs = Set<String>()
    @Published var highlightedNetIDs = Set<String>()
    @Published var selectedComponentIDs = Set<String>()
    @Published var highlightedComponentIDs = Set<String>()

    /// The project as the window that last changed it has it, and which
    /// window that was. Not published: a window follows it through
    /// `projectChanges`, not by being redrawn.
    private(set) var project: HorizontalProject?
    private(set) var writer: UUID?
    /// Once a turn at most, after a window changed the project: the windows
    /// that didn't take its copy.
    let projectChanges = PassthroughSubject<Void, Never>()
    /// A window's Spotlight, for the others to bring it into their views.
    let spotlights = PassthroughSubject<UUID, Never>()
    private var isNotifying = false
    private var windowCount = 1

    /// `project` is what the window `window` now has. Several changes in one
    /// turn, as one edit can make, reach the other windows as one.
    func publish(_ project: HorizontalProject, from window: UUID) {
        self.project = project
        writer = window
        guard !isNotifying else {
            return
        }
        isNotifying = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            isNotifying = false
            projectChanges.send()
        }
    }

    /// The number the next window takes in its title: 2, 3, …
    func nextWindowNumber() -> Int {
        windowCount += 1
        return windowCount
    }
}

/// A project window's other windows: the document's own, so its undo stack,
/// Save, Revert and closing are the project's, without the file's proxy icon,
/// and titled with their number. The project window closes the document, and
/// these with it; closing one of these closes only it.
final class HorizontalSecondaryWindowController: NSWindowController {
    override func synchronizeWindowTitleWithDocumentName() {
        // The title is the workspace's, bridged from SwiftUI; the document
        // would name the file and put its icon in the title bar.
        window?.representedURL = nil
        window?.standardWindowButton(.documentIconButton)?.isHidden = true
    }
}

@MainActor
enum HorizontalSecondaryProjectWindow {
    /// Opens another window on the project `source` shows, on another screen
    /// when there is one, else beside it. Nothing happens for a window that
    /// isn't a project's.
    static func open(
        shared: HorizontalSharedProject,
        document: Binding<HorizontalProjectDocument>,
        visiblePanes: Set<HorizontalPane>,
        appearanceSettings: HorizontalAppearanceSettings,
        from source: NSWindow?
    ) {
        guard let source, let nsDocument = source.windowController?.document as? NSDocument,
              shared.project != nil else {
            NSSound.beep()
            return
        }
        // The project window takes the document with it when it closes, as
        // a document's main window does: the others close then, where they
        // would have kept the document open on their own.
        for controller in nsDocument.windowControllers where !(controller is HorizontalSecondaryWindowController) {
            controller.shouldCloseDocument = true
        }
        let root = HorizontalSecondaryProjectView(
            shared: shared,
            document: document,
            undoManager: nsDocument.undoManager,
            number: shared.nextWindowNumber(),
            initialPanes: visiblePanes
        )
        .environmentObject(appearanceSettings)
        .preferredColorScheme(appearanceSettings.preferredColorScheme)
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isRestorable = false
        window.setFrame(frame(beside: source), display: false)
        let controller = HorizontalSecondaryWindowController(window: window)
        nsDocument.addWindowController(controller)
        controller.synchronizeWindowTitleWithDocumentName()
        controller.showWindow(nil)
    }

    /// The source window's size on the first other screen, centred there, or
    /// offset from it on the one screen there is.
    static func frame(beside source: NSWindow) -> NSRect {
        let size = source.frame.size
        if let other = NSScreen.screens.first(where: { $0 != source.screen }) {
            let visible = other.visibleFrame
            let width = min(size.width, visible.width), height = min(size.height, visible.height)
            return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        }
        var frame = source.frame.offsetBy(dx: 40, dy: -40)
        if let visible = source.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.maxX - frame.width, visible.minX))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.maxY - frame.height, visible.minY))
        }
        return frame
    }
}

/// Another window on a project: the workspace, sidebar, panes and toolbar as
/// the project window has them, on the shared project and selection, with
/// panes, view and tools of its own.
struct HorizontalSecondaryProjectView: View {
    @ObservedObject var shared: HorizontalSharedProject
    let document: Binding<HorizontalProjectDocument>
    /// The document's, which SwiftUI doesn't hand a window it didn't make.
    let undoManager: UndoManager?
    let number: Int
    @State private var visiblePanes: Set<HorizontalPane>
    @State private var spotlightRequest = 0
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(
        shared: HorizontalSharedProject,
        document: Binding<HorizontalProjectDocument>,
        undoManager: UndoManager?,
        number: Int,
        initialPanes: Set<HorizontalPane>
    ) {
        self.shared = shared
        self.document = document
        self.undoManager = undoManager
        self.number = number
        _visiblePanes = State(initialValue: initialPanes)
    }

    var body: some View {
        Group {
            if let project = shared.project {
                ProjectWorkspaceView(
                    project: project,
                    projectURL: project.url,
                    document: document,
                    visiblePanes: $visiblePanes,
                    selectedNetIDs: $shared.selectedNetIDs,
                    highlightedNetIDs: $shared.highlightedNetIDs,
                    selectedComponentIDs: $shared.selectedComponentIDs,
                    highlightedComponentIDs: $shared.highlightedComponentIDs,
                    spotlightRequest: $spotlightRequest,
                    sharedProject: shared,
                    isSecondaryWindow: true,
                    undoManagerOverride: undoManager
                )
                .navigationTitle("\(project.displayTitle) — \(number)")
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(WindowChromeConfigurator(isTransparent: appearanceSettings.isToolbarTransparent))
        .containerBackground(appearanceSettings.palette(for: .board, colorScheme: colorScheme).background, for: .window)
        .toolbarBackgroundVisibility(appearanceSettings.isToolbarTransparent ? .hidden : .visible, for: .windowToolbar)
        .focusedSceneValue(\.horizonVisiblePanes, $visiblePanes)
        .focusedSceneValue(\.horizonHighlightNetAction, spotlightSelection)
        .focusedSceneValue(\.horizonNewProjectWindowAction, openAnotherWindow)
    }

    /// The View menu's Spotlight, as the project window's does it.
    private func spotlightSelection() {
        shared.highlightedNetIDs = shared.selectedNetIDs
        shared.highlightedComponentIDs = shared.selectedComponentIDs
        spotlightRequest += 1
    }

    private func openAnotherWindow() {
        HorizontalSecondaryProjectWindow.open(
            shared: shared, document: document, visiblePanes: visiblePanes,
            appearanceSettings: appearanceSettings, from: NSApp.keyWindow
        )
    }
}
#endif
