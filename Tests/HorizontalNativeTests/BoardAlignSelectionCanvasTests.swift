#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Edit ▸ Align on the board canvas: the selected packages line up, the
/// copper on their pads follows, a fixed package stays, and one undo puts it
/// all back.
@MainActor
final class BoardAlignSelectionCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
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
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let half = 300_000.0

    private func pad(_ id: String, at c: HorizontalPoint) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [
            .init(x: c.x - half, y: c.y - half), .init(x: c.x + half, y: c.y - half),
            .init(x: c.x + half, y: c.y + half), .init(x: c.x - half, y: c.y + half),
        ], layer: HorizontalBoardLayers.topCopper, netID: nil)
    }

    /// Three one-pad parts, the second fixed, and a track from the third's
    /// pad out to the right.
    private func fixture() -> HorizontalBoard {
        let a = HorizontalPoint(x: 10_000_000, y: 10_000_000)
        let b = HorizontalPoint(x: 5_000_000, y: 20_000_000)
        let c = HorizontalPoint(x: 18_000_000, y: 30_000_000)
        var board = HorizontalGerberExportFixture.board(tracks: [
            HorizontalSegment(id: "track", from: c, to: HorizontalPoint(x: 25_000_000, y: 30_000_000), width: 200_000,
                              layer: HorizontalBoardLayers.topCopper),
        ])
        board.packages = [
            HorizontalPlacement(id: "a", position: a, angle: 0, mirrored: false, label: "R1", componentID: "ca"),
            HorizontalPlacement(id: "b", position: b, angle: 0, mirrored: false, label: "R2", componentID: "cb"),
            HorizontalPlacement(id: "c", position: c, angle: 0, mirrored: false, label: "R3", componentID: "cc"),
        ]
        board.packages[1].fixed = true
        board.packagePads = [pad("a/pad/1", at: a), pad("b/pad/1", at: b), pad("c/pad/1", at: c)]
        board.packagePadPositions = ["a/1": a, "b/1": b, "c/1": c]
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func position(_ id: String, _ board: HorizontalBoard?) -> HorizontalPoint? {
        board?.packages.first { $0.id == id }?.position
    }

    func testAlignLeftLinesUpThePartsOnTheFixedOneAndUndoPutsThemBack() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let original = fixture()
        let state = State(original)
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)

        state.actions?.dispatch(.selectAll)
        let selected = await settle { (state.actions?.alignableSelectionCount ?? 0) == 3 }
        XCTAssertTrue(selected, "the three parts can be aligned")
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.alignSelection(.left))
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let aligned = try XCTUnwrap(state.committed.last)

        // The fixed part, leftmost, sets the edge and stays; the others'
        // boxes, the same size, take its left edge.
        XCTAssertEqual(position("b", aligned), position("b", original))
        XCTAssertEqual(position("a", aligned), HorizontalPoint(x: 5_000_000, y: 10_000_000))
        XCTAssertEqual(position("c", aligned), HorizontalPoint(x: 5_000_000, y: 30_000_000))
        let track = try XCTUnwrap(aligned.tracks.first { $0.id == "track" })
        XCTAssertEqual(track.from, HorizontalPoint(x: 5_000_000, y: 30_000_000), "the track on the pad follows it")
        XCTAssertEqual(track.to, HorizontalPoint(x: 25_000_000, y: 30_000_000), "and its free end stays")

        XCTAssertTrue(state.undo.canUndo)
        XCTAssertEqual(state.undo.undoActionName, "Align Left")
        state.undo.undo()
        let undone = await settle { state.committed.count == 2 }
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(state.committed.last)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(position(id, restored), position(id, original), "one undo puts \(id) back")
        }
        XCTAssertEqual(restored.tracks.first?.from, original.tracks.first?.from)
    }
}
#endif
