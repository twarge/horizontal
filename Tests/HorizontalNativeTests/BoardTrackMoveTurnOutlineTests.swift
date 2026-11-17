#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// R during a move of a track turns the track's selection outline with it.
/// A track's turn is made in the model and the move carries on from the
/// turned board; the outline was still drawn from the board from before the
/// move, so the copper turned and its box stayed lying as it had.
@MainActor
final class BoardTrackMoveTurnOutlineTests: XCTestCase {
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

    /// One track, 10 mm long, lying along x between two junctions.
    private func board() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/track-turn.hprj"), uuid: "b", name: "track turn",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: ["j1": HorizontalPoint(x: 10 * mm, y: 20 * mm), "j2": HorizontalPoint(x: 20 * mm, y: 20 * mm)],
            junctionNetIDs: [:], netDetails: [:],
            tracks: [HorizontalSegment(
                id: "t1", from: HorizontalPoint(x: 10 * mm, y: 20 * mm), to: HorizontalPoint(x: 20 * mm, y: 20 * mm),
                width: 250_000, layer: HorizontalBoardLayers.topCopper, netID: nil, fromJunctionID: "j1", toJunctionID: "j2"
            )],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
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

    /// The top overlay layer, where the selection is drawn.
    private func overlayRenderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal top overlay") { return layer }
        return view.subviews.lazy.compactMap { self.overlayRenderer(in: $0) }.first
    }

    /// How far the selection's lines reach along x and along y.
    private func extent(_ lines: [(from: SIMD2<Float>, to: SIMD2<Float>)]) -> (width: Double, height: Double) {
        let xs = lines.flatMap { [Double($0.from.x), Double($0.to.x)] }, ys = lines.flatMap { [Double($0.from.y), Double($0.to.y)] }
        return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    func testRDuringAMoveTurnsATracksOutlineWithIt() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board())
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        // The pointer rests off the track, so the turn is about what moves.
        let rest = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 700, y: 550), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        _ = handle(rest)

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        let drawn = await settle { !(self.overlayRenderer(in: hosted)?.residentLineEndpoints(compositeGroup: 0).isEmpty ?? true) }
        XCTAssertTrue(drawn, "the selection is outlined")
        let renderer = try XCTUnwrap(overlayRenderer(in: hosted))
        let atRest = extent(renderer.residentLineEndpoints(compositeGroup: 0))
        XCTAssertGreaterThan(atRest.width, 9 * mm, "the box lies along the track")
        XCTAssertLessThan(atRest.height, 2 * mm)

        // Up one step starts the move; R turns what moves a quarter turn.
        try key(126, "\u{f700}")
        try? await Task.sleep(for: .milliseconds(200))
        try key(15, "r")
        let turned = await settle {
            let now = self.extent(renderer.residentLineEndpoints(compositeGroup: 0))
            return now.height > 9 * self.mm && now.width < 2 * self.mm
        }
        let during = extent(renderer.residentLineEndpoints(compositeGroup: 0))
        XCTAssertTrue(turned, "the outline stands with the turned track: \(during)")

        // And is where the commit then draws it.
        let moving = renderer.residentLineEndpoints(compositeGroup: 0)
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let track = try XCTUnwrap(state.committed.last?.tracks.first)
        XCTAssertEqual(track.from.x, track.to.x, accuracy: 1, "the track stands on end")
        try? await Task.sleep(for: .milliseconds(300))
        let after = renderer.residentLineEndpoints(compositeGroup: 0)
        let was = extent(moving), now = extent(after)
        XCTAssertEqual(was.width, now.width, accuracy: 100)
        XCTAssertEqual(was.height, now.height, accuracy: 100)
    }
}
#endif
