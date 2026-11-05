#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A board kept mounted while hidden, as the split keeps it while the
/// schematic shows, keeps its pad labels: at no width its transform fits the
/// board into a point, and the zoom cull read from that dropped every label,
/// which came back only after the cull's quiet period once the board was shown
/// again by Tab.
@MainActor
final class BoardHiddenPaneLabelsTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var shown = true
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Pane: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
                // As ResizablePaneSplitView keeps a pane it hides: mounted, at no width.
                .frame(width: state.shown ? 800 : 0)
                .clipped()
                .opacity(state.shown ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private let mm = 1_000_000.0

    /// A part with two 2 mm pads, each labelled with its name.
    private func board() -> HorizontalBoard {
        let top = HorizontalBoardLayers.topCopper
        func pad(_ name: String, at center: HorizontalPoint) -> HorizontalPolygon {
            let half = 1 * mm
            return HorizontalPolygon(id: "pkg/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top)
        }
        let padA = HorizontalPoint(x: 12 * mm, y: 15 * mm)
        let padB = HorizontalPoint(x: 18 * mm, y: 15 * mm)
        let bounds = HorizontalRect(points: [.zero, HorizontalPoint(x: 30 * mm, y: 30 * mm)])
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/hidden-labels.hprj"), uuid: "b", name: "hidden labels",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: HorizontalPoint(x: 15 * mm, y: 15 * mm), angle: 0, mirrored: false, label: "R1", componentID: "c1")],
            packagePads: [pad("a", at: padA), pad("b", at: padB)], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: bounds, bounds: bounds
        )
        board.packagePadPositions = ["pkg/a": padA, "pkg/b": padB]
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// The layer the board's scene is drawn in.
    private func boardLayer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.boardLayer(in: $0) }.first
    }

    /// The strokes of the generated labels the board's layer holds, in their own
    /// composite group (BoardCanvasView's textOverlayMetalCompositeGroup).
    private func labelStrokes(in view: NSView) -> Int {
        boardLayer(in: view)?.residentLineEndpoints(compositeGroup: 2_000_000).count ?? 0
    }

    func testAHiddenBoardKeepsItsLabelsForWhenItIsShownAgain() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board())
        let hosted = NSHostingView(rootView: Pane(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        func visibleWidth() -> Double? { state.actions?.visibleWorldBounds?().map(\.width) }

        let labelled = await settle { self.labelStrokes(in: hosted) > 0 }
        XCTAssertTrue(labelled, "the pads are labelled")
        // Past the cull's quiet period, so the threshold for this view is in.
        try await Task.sleep(for: .milliseconds(400))
        let shownStrokes = labelStrokes(in: hosted)
        XCTAssertGreaterThan(shownStrokes, 0)

        state.shown = false
        let hidden = await settle { visibleWidth() == 0 }
        XCTAssertTrue(hidden, "the board is hidden at no width")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(labelStrokes(in: hosted), shownStrokes, "the hidden board culled its labels")

        state.shown = true
        let shownAgain = await settle { (visibleWidth() ?? 0) > 0 }
        XCTAssertTrue(shownAgain)
        XCTAssertEqual(labelStrokes(in: hosted), shownStrokes, "the labels are there as the board is shown")
    }
}
#endif
