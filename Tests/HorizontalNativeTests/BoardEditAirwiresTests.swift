#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Every edit of the board canvas leaves the rats' nest of the board it makes.
/// Only a placement, a move and R, E and T made it; a drawn track, a delete
/// or a paste left the airwires the edit began with until a pour remade them,
/// and a board with no planes never pours: Board C drew 33 airwires where
/// the board has 8, some running to where parts had been.
@MainActor
final class BoardEditAirwiresTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        var state: State
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

    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private var a1: HorizontalPoint { HorizontalPoint(x: 0, y: 10 * mm) }
    private var a2: HorizontalPoint { HorizontalPoint(x: 0, y: 8 * mm) }
    private var b1: HorizontalPoint { HorizontalPoint(x: 20 * mm, y: 10 * mm) }
    private var b2: HorizontalPoint { HorizontalPoint(x: 20 * mm, y: 8 * mm) }

    /// Fixed parts A and B, which a delete leaves where they are; their pads
    /// a1 and b1 on `n` joined by a track from a1 up to a bend and down to
    /// b1, and a2 and b2 on `m`, joined by nothing. No planes.
    private func board() -> HorizontalBoard {
        func pad(_ package: String, _ name: String, at center: HorizontalPoint, net: String) -> HorizontalPolygon {
            let half = 0.4 * mm
            return HorizontalPolygon(id: "\(package)/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top, netID: net)
        }
        let bend = HorizontalPoint(x: 10 * mm, y: 15 * mm)
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/edit-airwires.hprj"), uuid: "b", name: "edit airwires",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: ["j": bend], junctionNetIDs: ["j": "n"], netDetails: [:],
            tracks: [
                HorizontalSegment(id: "t1", from: a1, to: bend, width: 250_000, layer: top, netID: "n", toJunctionID: "j"),
                HorizontalSegment(id: "t2", from: bend, to: b1, width: 250_000, layer: top, netID: "n", fromJunctionID: "j"),
            ],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [
                HorizontalPlacement(id: "pa", position: HorizontalPoint(x: 0, y: 9 * mm), angle: 0, mirrored: false, label: "A",
                                    componentID: "ca", fixed: true),
                HorizontalPlacement(id: "pb", position: HorizontalPoint(x: 20 * mm, y: 9 * mm), angle: 0, mirrored: false, label: "B",
                                    componentID: "cb", fixed: true),
            ],
            packagePads: [pad("pa", "a1", at: a1, net: "n"), pad("pa", "a2", at: a2, net: "m"),
                          pad("pb", "b1", at: b1, net: "n"), pad("pb", "b2", at: b2, net: "m")],
            packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pa/a1": a1, "pa/a2": a2, "pb/b1": b1, "pb/b2": b2]
        board.regenerateAirwires()
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

    private func layer(_ label: String, in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: label) { return layer }
        return view.subviews.lazy.compactMap { self.layer(label, in: $0) }.first
    }

    /// Whether `lines` hold one from `a` to `b`, either way round.
    private func draws(_ lines: [(from: SIMD2<Float>, to: SIMD2<Float>)], _ a: HorizontalPoint, _ b: HorizontalPoint) -> Bool {
        func near(_ point: SIMD2<Float>, _ expected: HorizontalPoint) -> Bool {
            abs(Double(point.x) - expected.x) < 50 && abs(Double(point.y) - expected.y) < 50
        }
        return lines.contains { (near($0.from, a) && near($0.to, b)) || (near($0.from, b) && near($0.to, a)) }
    }

    private func mount(_ state: State) async -> (NSWindow, NSView) {
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
        return (window, hosted)
    }

    /// Deleting the track that joined a1 and b1 leaves `n` an airwire between
    /// them, on the committed board, in what the canvas reports it draws and
    /// in its scene, beside `m`'s. Before, the board kept `m`'s alone.
    func testADeleteOnABoardWithNoPlanesRemakesTheRatsNest() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(board())
        XCTAssertEqual(state.source.airwires.map(\.netID), ["m"], "n is routed; only a2 and b2 need joining")
        let (window, hosted) = await mount(state)
        defer { window.close() }
        func sceneLines() -> [(from: SIMD2<Float>, to: SIMD2<Float>)] {
            layer("Metal overlay", in: hosted)?.residentLineEndpoints(compositeGroup: 0) ?? []
        }
        let drawn = await settle { self.draws(sceneLines(), self.a2, self.b2) }
        XCTAssertTrue(drawn, "m's airwire is drawn")
        XCTAssertFalse(draws(sceneLines(), a1, b1), "n is routed")

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        state.actions?.dispatch(.deleteSelection)
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(board.tracks, [], "the tracks went")
        XCTAssertEqual(board.packages.count, 2, "the fixed parts stayed")

        func ends(_ airwires: [HorizontalSegment]) -> Set<Set<HorizontalPoint>> {
            Set(airwires.map { [$0.from, $0.to] })
        }
        XCTAssertEqual(ends(board.airwires), [[a1, b1], [a2, b2]], "the committed board's airwires")
        var regenerated = HorizontalBoardConnectivity.recompute(board)
        regenerated.regenerateAirwires()
        XCTAssertEqual(ends(board.airwires), ends(regenerated.airwires), "as a regeneration makes them")

        let reported = await settle { (state.actions?.drawnAirwires?()?.airwires.count ?? 0) == 2 }
        XCTAssertTrue(reported, "the canvas says it draws both")
        let redrawn = await settle { self.draws(sceneLines(), self.a1, self.b1) }
        XCTAssertTrue(redrawn, "the scene draws n's airwire")
        XCTAssertTrue(draws(sceneLines(), a2, b2), "and m's still")
    }
}
#endif
