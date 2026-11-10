#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// What a step of dragging part of a polygon costs on a real board: an edge
/// of a plane's outline or of a board polygon nudged up one step at a time,
/// as a drag's each pointer move updates the move, against the same polygon
/// nudged whole. A benchmark, not a correctness test: it runs only with
/// HORIZONTAL_REAL_BOARD_FOLDER set to a project folder, and prints.
@MainActor
final class BoardPolygonReshapePerfTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var details = HorizontalSelectionDetailState.empty
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onPlaneEdit: { _, _ in },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    private func loadBoard() throws -> HorizontalBoard {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HORIZONTAL_REAL_BOARD_FOLDER"] ?? "/nonexistent")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("set HORIZONTAL_REAL_BOARD_FOLDER to the real board's project folder to run")
        }
        var diagnostics = [HorizontalDiagnostic]()
        return try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    private struct Mounted {
        var state: State
        var window: NSWindow
        var key: (UInt16, String) throws -> Void
    }

    private func mount(_ board: HorizontalBoard) async throws -> Mounted {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let readOnly = defaults.object(forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        addTeardownBlock { defaults.set(readOnly, forKey: HorizontalOperationDefaults.readOnlyOperationKey) }
        let state = State(board)
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let up = await settle { state.actions?.visibleWorldBounds?() != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(up)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        state.undo.beginUndoGrouping()
        addTeardownBlock { @MainActor in state.undo.endUndoGrouping() }
        return Mounted(state: state, window: window, key: { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            _ = handle(event)
        })
    }

    /// `refs` alone selected: Define Plane… on a plane's outline selects the
    /// ref and opens the sidebar on it, as Edit Plane does.
    private func select(_ ref: HorizontalSelectableRef, in canvas: Mounted) async {
        canvas.state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: ref, type: ref.type, propertyID: "definePlane", value: .bool(true), applyToAll: false))
        _ = await settle { canvas.state.actions?.canMoveSelection == true }
    }

    /// Milliseconds per step of `steps` nudges up, each let through a run of
    /// the main loop (SwiftUI's update and the Metal view's draw), then Esc.
    private func stepCost(_ canvas: Mounted, steps: Int) async throws -> Double {
        // The first nudge starts the move and builds what a move keeps; the
        // steps are timed once it has.
        try canvas.key(126, "\u{f700}")
        _ = await settle { canvas.state.actions?.canCommitInteraction == true }
        try await Task.sleep(for: .milliseconds(300))
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<steps {
            try canvas.key(126, "\u{f700}")
            try await Task.sleep(for: .milliseconds(1))
        }
        // The last step's update.
        try await Task.sleep(for: .milliseconds(1))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        try canvas.key(53, "\u{1b}")
        _ = await settle { canvas.state.actions?.canCancelInteraction == false }
        return elapsed / Double(steps)
    }

    func testReshapeStepCost() async throws {
        let board = try loadBoard()
        let canvas = try await mount(board)
        let steps = 30

        // The plane with the most outline vertices, one of its edges and the
        // whole outline; and the largest polygon of the board's own.
        let plane = try XCTUnwrap(board.planes.filter { $0.fallbackPolygon != nil }
            .max { ($0.fallbackPolygon?.polygonVertices.count ?? 0) < ($1.fallbackPolygon?.polygonVertices.count ?? 0) })
        let outline = try XCTUnwrap(plane.fallbackPolygon)
        let edge = HorizontalSelectableRef(id: outline.id, type: .polygonEdge, vertex: 0, layer: outline.layer)

        await select(edge, in: canvas)
        let planeEdge = try await stepCost(canvas, steps: steps)

        let vertex = HorizontalSelectableRef(id: outline.id, type: .polygonVertex, vertex: 1, layer: outline.layer)
        await select(vertex, in: canvas)
        let planeVertex = try await stepCost(canvas, steps: steps)

        // Everything selected: a move the scene patches, after the
        // inspector has taken in the selection.
        let selectStart = CFAbsoluteTimeGetCurrent()
        canvas.state.actions?.dispatch(.selectAll)
        _ = await settle { canvas.state.details.groups.contains { $0.type == .polygonEdge } }
        let selectAll = (CFAbsoluteTimeGetCurrent() - selectStart) * 1000
        let wholeBoard = try await stepCost(canvas, steps: steps)

        print(String(format: """
            Polygon reshape step cost on %d packages, %d tracks, %d planes, %d polygons:
              plane outline edge (%d vertices): %.1f ms
              plane outline vertex: %.1f ms
              select all: %.1f ms
              whole board selected: %.1f ms
            """, board.packages.count, board.tracks.count, board.planes.count, board.polygons.count,
            outline.polygonVertices.count, planeEdge, planeVertex, selectAll, wholeBoard))
    }
}
#endif
