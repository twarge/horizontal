#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A board's bounds are its content's, and zoom and pan are measured from
/// the bounds the viewport pinned when the board was first shown. The board
/// coming back from an edit with bounds grown past what it held (a paste, a
/// part placed off the board) or shrunk again leaves the view where it was,
/// in every frame the renderer takes; another board is shown fitted, as
/// before.
@MainActor
final class BoardBoundsViewTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private func board(uuid: String = "board", bounds: HorizontalRect) -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.uuid = uuid
        board.bounds = bounds
        board.physicalBounds = bounds
        return board
    }

    private func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> HorizontalRect {
        HorizontalRect(points: [HorizontalPoint(x: minX * 1_000_000, y: minY * 1_000_000), HorizontalPoint(x: maxX * 1_000_000, y: maxY * 1_000_000)])
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func assertEqual(_ shown: HorizontalRect?, _ wanted: HorizontalRect, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let shown else { return XCTFail("The canvas reports no view", file: file, line: line) }
        for (shown, wanted) in zip([shown.minX, shown.minY, shown.maxX, shown.maxY], [wanted.minX, wanted.minY, wanted.maxX, wanted.maxY]) {
            XCTAssertEqual(shown, wanted, accuracy: 1_000, message, file: file, line: line)
        }
    }

    func testBoundsGrownByAnEditLeaveTheViewAndAnotherBoardIsFitted() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board(bounds: rect(0, 0, 40, 30)))
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle {
            state.actions?.visibleWorldBounds?() != nil
                && CanvasFrameRecording.renderer(in: hosted)?.frame.viewport.reference != nil
        }
        XCTAssertTrue(mounted)
        let view = try XCTUnwrap(state.actions?.visibleWorldBounds?())
        let renderer = try XCTUnwrap(CanvasFrameRecording.renderer(in: hosted))
        let settled = renderer.frame
        XCTAssertEqual(settled.viewport.reference, CanvasViewport.Reference(identity: "board", bounds: rect(0, 0, 40, 30)),
                       "The viewport is pinned to the bounds the board was shown with")
        let probes = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 37_000_000, y: 21_000_000)]
        renderer.recordedFrames = []

        // The same board, back from an edit that drew past what it held.
        state.board = board(bounds: rect(-60, -10, 140, 90))
        try await Task.sleep(for: .milliseconds(300))
        assertEqual(state.actions?.visibleWorldBounds?(), view, "Bounds grown by an edit moved the view")

        // And shrunk again, as an undo leaves them.
        state.board = board(bounds: rect(0, 0, 40, 30))
        try await Task.sleep(for: .milliseconds(300))
        assertEqual(state.actions?.visibleWorldBounds?(), view, "Bounds shrunk by an edit moved the view")
        CanvasFrameRecording.assertEveryFrameShows(probes, as: settled, in: renderer,
                                                   "An edit's new bounds moved the view, if only for a frame")
        XCTAssertEqual(renderer.frame.bounds, rect(0, 0, 40, 30), "The renderer measures from the pinned bounds")
        renderer.recordedFrames = nil

        // Another board is shown as it always was: fitted, at the zoom kept.
        let other = rect(500, 500, 540, 530)
        state.board = board(uuid: "other", bounds: other)
        let fitted = await settle {
            guard let shown = state.actions?.visibleWorldBounds?() else { return false }
            return abs(shown.center.x - other.center.x) < 1_000 && abs(shown.center.y - other.center.y) < 1_000
        }
        XCTAssertTrue(fitted, "Another board must be shown fitted to its own bounds")
    }
}
#endif
