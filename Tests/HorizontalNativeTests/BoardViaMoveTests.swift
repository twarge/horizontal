import XCTest
#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
#endif
@testable import HorizontalNative

/// A via moves with its drill, and once. The drill is its own hole object,
/// "<via id>/hole", which the move, turn and mirror looked for by the via's
/// own id and never found, and which the scene drew under its own id, so a
/// keyboard move's preview left it behind. And a via whose junction was in the
/// selection too (a selected track brings its junctions) moved twice on
/// commit: the junction's move found the via where the via's own had put it.
final class BoardViaMoveTests: XCTestCase {
    private static let net = "n"
    private static let top = HorizontalBoardLayers.topCopper

    private func board(
        junctions: [String: HorizontalPoint],
        tracks: [HorizontalSegment],
        vias: [HorizontalMarker] = [],
        lines: [HorizontalSegment] = []
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/via-move.hprj"), uuid: "b", name: "via move",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: lines, arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias,
            viaHoles: vias.map {
                HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: $0.id), position: $0.position,
                               diameter: $0.holeSize ?? 300_000, plated: true, netID: $0.netID)
            },
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func track(_ id: String, _ from: String, _ to: String, in junctions: [String: HorizontalPoint], netID: String? = net) -> HorizontalSegment {
        HorizontalSegment(
            id: id, from: junctions[from]!, to: junctions[to]!, width: 250_000, layer: Self.top,
            netID: netID, fromJunctionID: from, toJunctionID: to
        )
    }

    private func via(at point: HorizontalPoint) -> HorizontalMarker {
        HorizontalMarker(id: "V", position: point, size: 600_000, holeSize: 300_000, layer: nil,
                         connectedLayers: [Self.top, HorizontalBoardLayers.bottomCopper], netID: Self.net)
    }

    /// The via at a, a track a → b and one b → c, as in the user's recording:
    /// a via, the diagonal track off it and the straight one beyond.
    private func viaBoard() -> HorizontalBoard {
        let junctions = [
            "a": HorizontalPoint(x: 2_000_000, y: 2_000_000),
            "b": HorizontalPoint(x: 4_000_000, y: 4_000_000),
            "c": HorizontalPoint(x: 10_000_000, y: 4_000_000),
        ]
        return board(
            junctions: junctions,
            tracks: [track("t1", "a", "b", in: junctions), track("t2", "b", "c", in: junctions)],
            vias: [via(at: junctions["a"]!)]
        )
    }

    // MARK: - The points a change carries

    func testAViaHoleNamesItsVia() {
        XCTAssertEqual(HorizontalBoard.viaHoleID(ofVia: "V"), "V/hole")
        XCTAssertEqual(HorizontalBoard.viaID(ofViaHole: "V/hole"), "V")
        XCTAssertNil(HorizontalBoard.viaID(ofViaHole: "V"))
    }

    func testAViaAndItsJunctionMoveOnceAndTakeTheDrill() {
        let original = viaBoard()
        let a = original.junctions["a"]!, b = original.junctions["b"]!
        let delta = HorizontalPoint(x: 1_270_000, y: 0)
        var points = BoardMovingPoints()
        points.add(a, to: a + delta, netID: Self.net)                 // the via
        points.add(a, to: a + delta, netID: nil, carriesGraphics: true) // its junction
        points.add(b, to: b + delta, netID: nil, carriesGraphics: true)
        var moved = original
        points.apply(from: original, to: &moved)

        XCTAssertEqual(moved.vias[0].position, a + delta, "the via moved once")
        XCTAssertEqual(moved.viaHoles[0].position, a + delta, "its drill went with it")
        XCTAssertEqual(moved.junctions["a"], a + delta)
        XCTAssertEqual(moved.junctions["b"], b + delta)
        XCTAssertEqual(moved.tracks[0].from, a + delta)
        XCTAssertEqual(moved.tracks[0].to, b + delta)
        XCTAssertEqual(moved.tracks[1].from, b + delta, "the track beyond stretches to the moved bend")
        XCTAssertEqual(moved.tracks[1].to, original.tracks[1].to)
    }

    func testATrackOneStepLongKeepsItsLengthAndBothJunctions() {
        // A nudge as long as the track along it put the first end where the
        // second was, and the second's move took the first along again.
        let step = 1_270_000.0
        let junctions = ["a": HorizontalPoint(x: 0, y: 0), "b": HorizontalPoint(x: step, y: 0)]
        let original = board(junctions: junctions, tracks: [track("t", "a", "b", in: junctions)])
        let delta = HorizontalPoint(x: step, y: 0)
        var points = BoardMovingPoints()
        points.add(junctions["a"]!, to: junctions["a"]! + delta, netID: nil)
        points.add(junctions["b"]!, to: junctions["b"]! + delta, netID: nil)
        var moved = original
        points.apply(from: original, to: &moved)

        XCTAssertEqual(moved.tracks[0].from, HorizontalPoint(x: step, y: 0))
        XCTAssertEqual(moved.tracks[0].to, HorizontalPoint(x: 2 * step, y: 0))
        XCTAssertEqual(moved.junctions.count, 2, "two junctions one step apart are not folded into one")
    }

    func testWhatTheChangeHasMovedAlreadyStaysWhereItWent() {
        let original = viaBoard()
        let a = original.junctions["a"]!
        var moved = original
        let elsewhere = HorizontalPoint(x: 0, y: 9_000_000)
        moved.tracks[0].from = elsewhere
        var points = BoardMovingPoints()
        points.add(a, to: a + HorizontalPoint(x: 1_000_000, y: 0), netID: Self.net)
        points.apply(from: original, to: &moved)
        XCTAssertEqual(moved.tracks[0].from, elsewhere)
        XCTAssertEqual(moved.vias[0].position, a + HorizontalPoint(x: 1_000_000, y: 0))
    }

    func testOnlyCopperOfThePointsNetGoes() {
        let junctions = ["a": HorizontalPoint(x: 0, y: 0), "b": HorizontalPoint(x: 5_000_000, y: 0), "z": HorizontalPoint(x: 0, y: 5_000_000)]
        let original = board(junctions: junctions, tracks: [
            track("mine", "a", "b", in: junctions),
            HorizontalSegment(id: "other", from: junctions["a"]!, to: junctions["z"]!, width: 250_000, layer: Self.top, netID: "m"),
        ])
        let delta = HorizontalPoint(x: 1_000_000, y: 0)
        var points = BoardMovingPoints()
        points.add(junctions["a"]!, to: junctions["a"]! + delta, netID: Self.net)
        var moved = original
        points.apply(from: original, to: &moved)
        XCTAssertEqual(moved.tracks[0].from, junctions["a"]! + delta)
        XCTAssertEqual(moved.tracks[1].from, junctions["a"]!, "another net's track there stays")
    }

    func testAJunctionCarriesTheEndsOfLinesButNotOfOnesMovedWhole() {
        let silk = HorizontalBoardLayers.topSilkscreen
        let point = HorizontalPoint(x: 1_000_000, y: 1_000_000)
        let original = board(junctions: ["a": point], tracks: [], lines: [
            HorizontalSegment(id: "follows", from: point, to: HorizontalPoint(x: 6_000_000, y: 1_000_000), width: 150_000, layer: silk),
            HorizontalSegment(id: "whole", from: point, to: HorizontalPoint(x: 1_000_000, y: 6_000_000), width: 150_000, layer: silk),
        ])
        let delta = HorizontalPoint(x: 0, y: 1_000_000)
        var points = BoardMovingPoints()
        points.add(point, to: point + delta, netID: nil, carriesGraphics: true)
        var moved = original
        points.apply(from: original, to: &moved, graphicsMovedWhole: ["whole"])
        XCTAssertEqual(moved.lines[0].from, point + delta)
        XCTAssertEqual(moved.lines[1].from, point, "the selection moves that line itself")
    }

    // MARK: - The canvas

    #if os(macOS)
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

    /// `BoardCanvasView.holesMetalCompositeGroup`, where drills are drawn.
    private static let holesGroup = 1_900_000

    @MainActor private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    @MainActor private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    @MainActor private func renderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    /// Mounts the canvas and selects everything: the via, its tracks and
    /// their junctions.
    @MainActor private func mount(_ state: State) async throws -> (
        window: NSWindow, renderer: HorizontalMetalCanvasLayer, key: (UInt16, String) throws -> Void
    ) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle {
            state.actions != nil && self.monitor(in: hosted) != nil && self.renderer(in: hosted)?.presentedContentKey != nil
        }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        return (window, renderer, key)
    }

    private func center(of strokes: [(from: SIMD2<Float>, to: SIMD2<Float>)]) -> HorizontalPoint {
        let sum = strokes.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2(Double($1.from.x), Double($1.from.y)) }
        return HorizontalPoint(x: sum.x / Double(strokes.count), y: sum.y / Double(strokes.count))
    }

    private func distance(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    @MainActor func testAKeyboardMoveCarriesTheDrillAndTheCommitMovesTheViaOnce() async throws {
        let original = viaBoard()
        let state = State(original)
        let (window, renderer, key) = try await mount(state)
        defer { window.close() }

        let drill = renderer.residentLineEndpoints(compositeGroup: Self.holesGroup)
        XCTAssertFalse(drill.isEmpty, "the drill is drawn")
        XCTAssertLessThan(distance(center(of: drill), original.vias[0].position), 1_000)

        try key(124, "\u{f703}")   // right: a keyboard move, patched in Metal
        let previewed = await settle {
            let moved = renderer.residentLineEndpoints(compositeGroup: Self.holesGroup)
            return moved.count == drill.count && self.center(of: moved).x > self.center(of: drill).x + 1
        }
        XCTAssertTrue(previewed, "the preview takes the drill along with the via")
        let previewDrill = center(of: renderer.residentLineEndpoints(compositeGroup: Self.holesGroup))

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)

        let delta = board.vias[0].position - original.vias[0].position
        XCTAssertGreaterThan(delta.x, 0, "it moved right")
        XCTAssertEqual(delta.y, 0)
        XCTAssertEqual(board.viaHoles[0].position, board.vias[0].position, "the drill is in the via")
        XCTAssertLessThan(distance(previewDrill, board.vias[0].position), 1_000, "where the preview drew it")
        for before in original.tracks {
            let moved = try XCTUnwrap(board.tracks.first { $0.id == before.id })
            XCTAssertEqual(moved.from - before.from, delta, "\(moved.id) moved once, as the via did")
            XCTAssertEqual(moved.to - before.to, delta, "\(moved.id) moved once, as the via did")
        }
        XCTAssertEqual(try track("t1", in: board).from, board.vias[0].position, "the track still ends on the via")
    }

    private func track(_ id: String, in board: HorizontalBoard) throws -> HorizontalSegment {
        try XCTUnwrap(board.tracks.first { $0.id == id })
    }

    @MainActor func testRTurnsTheViaOnceWithItsDrill() async throws {
        let original = viaBoard()
        let state = State(original)
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        try key(15, "r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)

        let via = board.vias[0].position
        XCTAssertNotEqual(via, original.vias[0].position, "the via turned with the rest")
        XCTAssertEqual(board.viaHoles[0].position, via, "the drill is in the via")
        let turned = try track("t1", in: board), before = try track("t1", in: original)
        XCTAssertEqual(turned.from, via, "the track still ends on the via")
        let run = turned.to - turned.from, wasRun = before.to - before.from
        XCTAssertEqual(hypot(run.x, run.y), hypot(wasRun.x, wasRun.y), accuracy: 1, "the track kept its length")
        XCTAssertEqual(run.x * wasRun.x + run.y * wasRun.y, 0, accuracy: 1, "a quarter turn, made once")
        XCTAssertEqual(try track("t2", in: board).from, turned.to, "the next track still meets it")
    }

    @MainActor func testEMirrorsTheViaWithItsDrill() async throws {
        let original = viaBoard()
        let state = State(original)
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        try key(14, "e")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)

        let via = board.vias[0].position
        XCTAssertNotEqual(via, original.vias[0].position, "the via mirrored with the rest")
        XCTAssertEqual(via.y, original.vias[0].position.y)
        XCTAssertEqual(board.viaHoles[0].position, via, "the drill is in the via")
        XCTAssertEqual(try track("t1", in: board).from, via, "the track still ends on the via")
    }
    #endif
}
