#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Two parts joined by a track with a bend, moved together: the move's live
/// rats' nest left the bend's junction where it was, a piece of the net on its
/// own, and drew an airwire from the moving parts to that empty spot.
@MainActor
final class BoardMoveJunctionAirwireTests: XCTestCase {
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
    private let bend = HorizontalPoint(x: 10_000_000, y: 15_000_000)

    /// Parts A and B, their pads a1 and b1 on `n` joined by a track from a1 up
    /// to a bend and down to b1, and a2 and b2 on `m`, joined by nothing, whose
    /// airwire the move draws live.
    private func board() -> HorizontalBoard {
        func pad(_ package: String, _ name: String, at center: HorizontalPoint, net: String) -> HorizontalPolygon {
            let half = 0.4 * mm
            return HorizontalPolygon(id: "\(package)/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top, netID: net)
        }
        let a1 = HorizontalPoint(x: 0, y: 10 * mm), a2 = HorizontalPoint(x: 0, y: 8 * mm)
        let b1 = HorizontalPoint(x: 20 * mm, y: 10 * mm), b2 = HorizontalPoint(x: 20 * mm, y: 8 * mm)
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/move-junction-airwire.hprj"), uuid: "b", name: "move junction airwire",
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
                HorizontalPlacement(id: "pa", position: HorizontalPoint(x: 0, y: 9 * mm), angle: 0, mirrored: false, label: "A", componentID: "ca"),
                HorizontalPlacement(id: "pb", position: HorizontalPoint(x: 20 * mm, y: 9 * mm), angle: 0, mirrored: false, label: "B", componentID: "cb"),
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

    /// The top overlay layer, where the selection and a move's live airwires are drawn.
    private func overlayRenderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal top overlay") { return layer }
        return view.subviews.lazy.compactMap { self.overlayRenderer(in: $0) }.first
    }

    private typealias Key = (UInt16, String) throws -> Void

    private func mount(_ state: State) async throws -> (NSWindow, NSView, Key) {
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
        let key: Key = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        return (window, hosted, key)
    }

    /// The committed board carries the rats' nest of the board as it now is,
    /// which the canvas draws once the edit ends: the one the board had
    /// stayed until a pour remade it, and no pour comes without planes.
    private func assertRatsNestIsCurrent(_ board: HorizontalBoard, file: StaticString = #filePath, line: UInt = #line) {
        var regenerated = HorizontalBoardConnectivity.recompute(board)
        regenerated.regenerateAirwires()
        XCTAssertEqual(regenerated.airwires.map(\.netID), ["m"], "the board is routed as it was", file: file, line: line)
        func ends(_ airwires: [HorizontalSegment]) -> Set<Set<HorizontalPoint>> {
            Set(airwires.map { [$0.from, $0.to] })
        }
        XCTAssertEqual(ends(board.airwires), ends(regenerated.airwires), "the committed board's airwires", file: file, line: line)
    }

    func testMovingTwoPartsAndTheirBentTrackDrawsNoAirwireToTheBend() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(board())
        XCTAssertEqual(state.source.airwires.map(\.netID), ["m"], "n is routed; only a2 and b2 need joining")
        let (window, hosted, key) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        // The top overlay is made once the selection is drawn in it.
        let drawn = await settle { !(self.overlayRenderer(in: hosted)?.residentHandleCenters().isEmpty ?? true) }
        XCTAssertTrue(drawn, "the selection draws handles")
        let renderer = try XCTUnwrap(overlayRenderer(in: hosted))

        // Up one step, and again once the live airwires have landed, so the
        // overlay draws them for where the move has got to.
        try key(126, "\u{f700}")
        try? await Task.sleep(for: .milliseconds(300))
        try key(126, "\u{f700}")
        try? await Task.sleep(for: .milliseconds(300))
        let shownLines = renderer.residentLineEndpoints(compositeGroup: 0)

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        let movedBend = try XCTUnwrap(board.junctions["j"])
        let delta = movedBend - bend
        XCTAssertGreaterThan(delta.y, 0, "the move went up, the bend with it")
        XCTAssertEqual(board.tracks.first { $0.id == "t1" }?.to, movedBend)
        XCTAssertEqual(board.tracks.first { $0.id == "t2" }?.from, movedBend)

        func near(_ point: SIMD2<Float>, _ expected: HorizontalPoint) -> Bool {
            abs(Double(point.x) - expected.x) < 50 && abs(Double(point.y) - expected.y) < 50
        }
        let a2 = HorizontalPoint(x: 0, y: 8 * mm) + delta, b2 = HorizontalPoint(x: 20 * mm, y: 8 * mm) + delta
        XCTAssertTrue(shownLines.contains { (near($0.from, a2) && near($0.to, b2)) || (near($0.from, b2) && near($0.to, a2)) },
                      "the move drew m's airwire live, so the live rats' nest had landed")
        XCTAssertFalse(shownLines.contains { near($0.from, bend) || near($0.to, bend) },
                       "no airwire runs to where the bend was")
        assertRatsNestIsCurrent(board)
    }

    /// R at rest turns the parts and the track about them, and the committed
    /// board's airwire leaves from where the turn put the pads.
    func testTurningTwoPartsAndTheirBentTrackRemakesTheRatsNest() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(board())
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(15, "r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        XCTAssertNotEqual(board.packagePadPositions["pa/a2"], HorizontalPoint(x: 0, y: 8 * mm), "the parts turned")
        assertRatsNestIsCurrent(board)
    }
}
#endif
