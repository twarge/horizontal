#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A junction can be picked only where its copper shows: one whose tracks are
/// all on hidden layers is left out with them, as Horizon leaves it out.
@MainActor
final class BoardJunctionVisibilityTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        var options: BoardDisplayOptions
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        init(_ board: HorizontalBoard, options: BoardDisplayOptions) {
            source = board
            self.options = options
        }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.source, viewport: $viewport, displayOptions: state.options, undoManager: state.undo,
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// A track on the top and one on the bottom, each between junctions of
    /// its own, and a junction nothing joins.
    private func board() -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board(tracks: [
            HorizontalSegment(id: "top-track", from: point(5, 5), to: point(10, 5), width: 250_000,
                              layer: HorizontalBoardLayers.topCopper, fromJunctionID: "jt1", toJunctionID: "jt2"),
            HorizontalSegment(id: "bottom-track", from: point(5, 10), to: point(10, 10), width: 250_000,
                              layer: HorizontalBoardLayers.bottomCopper, fromJunctionID: "jb1", toJunctionID: "jb2"),
        ])
        board.junctions = ["jt1": point(5, 5), "jt2": point(10, 5), "jb1": point(5, 10), "jb2": point(10, 10), "jo": point(20, 20)]
        let extent = HorizontalRect(points: [point(0, 0), point(30, 30)])
        board.bounds = extent
        board.physicalBounds = extent
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// What Select All picks with `options`: the ids by type.
    private func selectAll(_ options: BoardDisplayOptions) async throws -> [HorizontalObjectType: Set<String>] {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board(), options: options)
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.details.hasSelection }
        XCTAssertTrue(selected)
        return state.details.groups.reduce(into: [:]) { picked, group in
            picked[group.type, default: []].formUnion(group.items.map(\.ref.id))
        }
    }

    func testAJunctionOnAHiddenLayerIsNotPicked() async throws {
        var options = BoardDisplayOptions()
        options.soloLayer = HorizontalBoardLayers.topCopper
        let picked = try await selectAll(options)
        XCTAssertEqual(picked[.junction], ["jt1", "jt2", "jo"], "the top track's junctions, and the one on no copper")
        XCTAssertEqual(picked[.track], ["top-track"])
    }

    func testEveryJunctionIsPickedWithEveryLayerShowing() async throws {
        let picked = try await selectAll(BoardDisplayOptions())
        XCTAssertEqual(picked[.junction], ["jt1", "jt2", "jb1", "jb2", "jo"])
        XCTAssertEqual(picked[.track], ["top-track", "bottom-track"])
    }
}
#endif
