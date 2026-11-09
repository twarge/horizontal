#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Delete on a polygon's edge takes its two vertices and selects the edge
/// that now joins the vertices either side of the gap, so the next Delete
/// goes on along the outline; on the board, a keepout's polygon too, and in
/// the schematic's drawings by the same rule.
@MainActor
final class BoardPolygonEdgeDeleteTests: XCTestCase {
    // MARK: - The edge across the gap

    func testTheEdgeAcrossTheGapIsTheOneBeforeIt() {
        // A hexagon: deleting edge 2 (v2–v3) leaves v0 v1 v4 v5, where edge 1
        // is v1–v4, across the gap.
        XCTAssertEqual(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 2, vertexCount: 6), 1)
        // The last edge, v5–v0, leaves v1 v2 v3 v4, and v4–v1 is edge 3.
        XCTAssertEqual(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 5, vertexCount: 6), 3)
        // The first, v0–v1, leaves v2 v3 v4 v5, and v5–v2 is edge 3.
        XCTAssertEqual(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 0, vertexCount: 6), 3)
        XCTAssertEqual(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 1, vertexCount: 5), 0, "a pentagon left a triangle")
    }

    func testAPolygonThatGoesLeavesNothingToSelect() {
        XCTAssertNil(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 0, vertexCount: 4), "two vertices are no board polygon")
        XCTAssertEqual(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 0, vertexCount: 4, minimumVertices: 2), 1,
                       "though a drawing keeps two")
        XCTAssertNil(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 0, vertexCount: 3, minimumVertices: 2))
        XCTAssertNil(HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: 6, vertexCount: 6), "not one of its edges")
    }

    // MARK: - On the board

    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var details = HorizontalSelectionDetailState.empty
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
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
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private var center: HorizontalPoint { HorizontalPoint(x: 15 * mm, y: 15 * mm) }

    /// A hexagon on the top copper, its vertex k at 60k degrees.
    private func hexagon() -> [HorizontalPoint] {
        (0..<6).map { k in
            let angle = Double(k) * .pi / 3
            return HorizontalPoint(x: center.x + 10 * mm * cos(angle), y: center.y + 10 * mm * sin(angle))
        }
    }

    /// The hexagon as a polygon of the board's, or as a keepout's, which
    /// holds its polygon as the board loads one.
    private func board(keepout: Bool = false) -> HorizontalBoard {
        let hexagon = HorizontalPolygon(id: "hexagon", vertices: hexagon(), layer: HorizontalBoardLayers.topCopper)
        var board = HorizontalGerberExportFixture.board(polygons: keepout ? [] : [hexagon])
        if keepout {
            board.keepouts = [HorizontalKeepout(
                id: "ko", polygonID: "hexagon", polygon: hexagon, keepoutClass: "", allCopperLayers: false,
                exposedCopperOnly: false, copperPatchTypes: ["track"])]
        }
        let extent = HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 30 * mm, y: 30 * mm)])
        board.bounds = extent
        board.physicalBounds = extent
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

    private func selectedEdges(_ state: State) -> [HorizontalSelectableRef] {
        state.details.groups.filter { $0.type == .polygonEdge }.flatMap { $0.items.map(\.ref) }
    }

    func testDeletingAnEdgeSelectsTheEdgeAcrossTheGapAndTheNextDeleteGoesOn() async throws {
        try await deleteEdgesInTurn(keepout: false)
    }

    /// A keepout's polygon is reshaped as any polygon is, the keepout kept
    /// until its polygon goes.
    func testAKeepoutsPolygonLosesAnEdgeAsAPolygonDoes() async throws {
        try await deleteEdgesInTurn(keepout: true)
    }

    private func deleteEdgesInTurn(keepout: Bool) async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board(keepout: keepout))
        /// The hexagon's vertices as the edit left them, wherever it is kept.
        func vertexCount(_ board: HorizontalBoard?) -> Int? {
            keepout ? board?.keepouts.first?.polygon.polygonVertices.count : board?.polygons.first?.polygonVertices.count
        }
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let up = await settle { state.actions?.visibleWorldBounds?() != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(up)
        let monitor = try XCTUnwrap(monitor(in: hosted))
        let visible = try XCTUnwrap(state.actions?.visibleWorldBounds?())

        // A click on the middle of edge 2, v2–v3, where the canvas draws it.
        let corners = hexagon()
        let middle = HorizontalPoint(x: (corners[2].x + corners[3].x) / 2, y: (corners[2].y + corners[3].y) / 2)
        let size = monitor.bounds.size
        let point = CGPoint(
            x: (middle.x - visible.minX) / visible.width * size.width,
            y: (visible.maxY - middle.y) / visible.height * size.height
        )
        monitor.onPrimaryClick?(point, size, CGPoint(x: point.x, y: size.height - point.y), monitor, .replace, 1)
        let picked = await settle { self.selectedEdges(state).map(\.vertex) == [2] }
        XCTAssertTrue(picked, "edge 2 selected: \(selectedEdges(state))")

        state.actions?.dispatch(.deleteSelection)
        let deleted = await settle { vertexCount(state.committed.last) == 4 }
        XCTAssertTrue(deleted, "its two vertices gone")
        if keepout {
            XCTAssertTrue(state.committed.last?.polygons.isEmpty ?? false, "the keepout keeps its polygon")
            XCTAssertEqual(state.committed.last?.keepouts.map(\.id), ["ko"])
        }
        let next = await settle { self.selectedEdges(state).map(\.vertex) == [1] }
        XCTAssertTrue(next, "edge 1, v1–v4, across the gap, selected: \(selectedEdges(state))")
        XCTAssertEqual(selectedEdges(state).first?.id, "hexagon")

        state.actions?.dispatch(.deleteSelection)
        let gone = await settle { state.committed.count == 2 && vertexCount(state.committed.last) == nil }
        XCTAssertTrue(gone, "the next Delete takes v1 and v4, and two vertices are no polygon")
        if keepout {
            XCTAssertTrue(state.committed.last?.keepouts.isEmpty ?? false, "and no keepout")
            XCTAssertEqual(state.committed.last?.removedKeepoutIDs, ["ko"])
        }
        let cleared = await settle { self.selectedEdges(state).isEmpty }
        XCTAssertTrue(cleared, "with nothing left to select: \(selectedEdges(state))")
    }
}
#endif
