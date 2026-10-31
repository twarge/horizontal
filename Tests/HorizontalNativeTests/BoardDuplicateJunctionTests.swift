#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Duplicate on the board canvas puts the copies' ends on junctions
/// (`BoardTrackRouting.attachJunctions`), which the writer needs to write
/// them at all: before, a duplicated track or via in the open was dropped on
/// save. `BoardPasteJunctionTests` covers the rule and the file.
@MainActor
final class BoardDuplicateJunctionTests: XCTestCase {
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

    private let top = HorizontalBoardLayers.topCopper

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testADuplicatedTrackAndViaGoOnJunctionsOfTheirOwn() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = HorizontalGerberExportFixture.board()
        board.tracks = []
        board.vias = []
        board.viaHoles = []
        board.junctions = [:]
        let from = HorizontalPoint(x: 10_000_000, y: 10_000_000), to = HorizontalPoint(x: 15_000_000, y: 10_000_000)
        let head = BoardTrackRouteHead(
            anchor: from, anchorJunctionID: nil, anchorOnPad: false, netID: nil, width: 200_000, layer: top, placesVia: false)
        BoardTrackRouting.lay(
            [BoardTrackSegmentSpec(from: from, to: to)], to: to, endsOnPad: false, via: nil, from: head, on: &board)
        BoardTrackRouting.dropVia(
            HorizontalBoardViaTemplate(padstackID: "via", diameter: 600_000, holeDiameter: 300_000, fromRules: false, parameterSet: [:]),
            at: HorizontalPoint(x: 20_000_000, y: 10_000_000), netID: nil, preferredJunctionID: nil, on: &board)
        let originals = (tracks: Set(board.tracks.map(\.id)), vias: Set(board.vias.map(\.id)))

        let state = State(board)
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
        let selected = await settle { state.actions?.canDuplicateSelection == true }
        XCTAssertTrue(selected)
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.duplicateSelection)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.last?.tracks.count == 2 }
        XCTAssertTrue(committed)
        let result = try XCTUnwrap(state.committed.last)

        let copy = try XCTUnwrap(result.tracks.first { !originals.tracks.contains($0.id) })
        for (end, id) in [(copy.from, copy.fromJunctionID), (copy.to, copy.toJunctionID)] {
            let junction = try XCTUnwrap(id, "each end of the copy names a junction")
            XCTAssertEqual(result.junctions[junction], end, "at the copy's end")
        }
        let viaCopy = try XCTUnwrap(result.vias.first { !originals.vias.contains($0.id) })
        XCTAssertTrue(result.junctions.values.contains(viaCopy.position), "the copied via stands on a junction")
    }
}
#endif
