#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A grid changed in the pane, on a board canvas that has a board of its own
/// already, as it has after any edit. The pane's grid settings change the
/// board it holds; the canvas went on stepping the arrow keys (and snapping)
/// by its own board's old grid, and its next commit put the old grid back.
@MainActor
final class BoardGridChangeTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    /// The pane's part: it hands the canvas the board it holds, and takes the
    /// canvas's commits back into it.
    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); state.board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let start = HorizontalPoint(x: 10_000_000, y: 10_000_000)

    private func grid(_ spacing: Double) -> HorizontalGridSettings {
        HorizontalGridSettings(name: "", mode: "square", spacing: HorizontalPoint(x: spacing, y: spacing), origin: .zero)
    }

    private func fixture() -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.grid = grid(125_000)
        board.packages = [HorizontalPlacement(id: "pkg", position: start, angle: 0, mirrored: false, label: "R1", componentID: "component")]
        board.packagePads = [HorizontalPolygon(id: "pkg/pad/a", vertices: [
            HorizontalPoint(x: start.x - 300_000, y: start.y - 300_000), HorizontalPoint(x: start.x + 300_000, y: start.y - 300_000),
            HorizontalPoint(x: start.x + 300_000, y: start.y + 300_000), HorizontalPoint(x: start.x - 300_000, y: start.y + 300_000),
        ], layer: HorizontalBoardLayers.topCopper)]
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    private func mount(_ state: State) async throws -> (window: NSWindow, key: (UInt16, String) throws -> Void) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        return (window, key)
    }

    /// Moves R1 up a step with the keyboard, commits, and gives how far it went.
    private func moveThePartUp(_ state: State, key: (UInt16, String) throws -> Void) async throws -> Double {
        let before = try XCTUnwrap(state.board.packages.first?.position)
        let commits = state.committed.count
        _ = state.actions?.selectComponents?(["component"])   // false once it is the selection already
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.commitInteraction)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
        let after = try XCTUnwrap(state.committed.last?.packages.first?.position)
        XCTAssertEqual(after.x, before.x)
        return abs(after.y - before.y)
    }

    func testAGridChangedAfterAnEditStepsTheArrowKeysAndStays() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        // An edit first, after which the canvas draws from a board of its own.
        let first = try await moveThePartUp(state, key: key)
        XCTAssertEqual(first, 125_000, accuracy: 1)

        // The pane's grid settings change the board it holds.
        state.board.grid = grid(250_000)
        try? await Task.sleep(for: .milliseconds(100))
        let second = try await moveThePartUp(state, key: key)
        XCTAssertEqual(second, 250_000, accuracy: 1, "the arrow keys step by the new grid")
        XCTAssertEqual(state.committed.last?.grid.spacing.x, 250_000, "and the edit keeps it")
    }
}
#endif
