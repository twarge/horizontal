#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A via read with no hole diameter in its parameter set has no drill object,
/// which the loader makes only from one; giving it a hole diameter in the
/// inspector drew no hole until the board was opened again (three of
/// Board C's vias were like that). The edit now makes the drill.
@MainActor
final class BoardViaHoleEditTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
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
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testAHoleDiameterGivenToAViaWithNoHoleDrawsItsDrill() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = HorizontalGerberExportFixture.board()
        board.vias = [HorizontalMarker(
            id: "v", position: HorizontalPoint(x: 10_000_000, y: 10_000_000), size: 450_000, holeSize: nil,
            layer: nil, netID: nil, parameterSet: ["via_diameter": 450_000])]
        board.viaHoles = []

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

        let ref = HorizontalSelectableRef(id: "v", type: .via)
        state.undo.beginUndoGrouping()
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: ref, type: .via, propertyID: "holeDiameter", value: .length(200_000), applyToAll: false))
        let committed = await settle { state.committed.last != nil }
        state.undo.endUndoGrouping()
        XCTAssertTrue(committed)

        let result = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(result.vias.first?.holeSize, 200_000)
        let hole = try XCTUnwrap(result.viaHoles.first { $0.id == "v/hole" }, "the via has a drill to draw")
        XCTAssertEqual(hole.diameter, 200_000)
        XCTAssertEqual(hole.position, result.vias.first?.position)
    }
}
#endif
