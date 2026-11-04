#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A committed board move is drawn where it went. The commit used to keep the
/// scene from before the move, which the move's resident patches had drawn
/// moved; once the patches ended the renderer put that scene back, so a moved
/// board outline (or track) was drawn at its old place until a pour or Q
/// rebuilt the scene.
///
/// And a polygon with all of it selected moves, turns and mirrors whole and
/// once, as the move's preview draws it. Select All moved a board outline once
/// for each of its edges and again for each vertex. (An edge selected alone
/// moves only its two vertices: `BoardPolygonPartsTests`.)
@MainActor
final class BoardOutlineMoveCommitTests: XCTestCase {
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
        @State private var board: HorizontalBoard
        @State private var viewport = CanvasViewport()
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

    private typealias Strokes = [(from: SIMD2<Float>, to: SIMD2<Float>)]

    private static let rectangle = [
        HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 20_000_000, y: 0),
        HorizontalPoint(x: 20_000_000, y: 10_000_000), HorizontalPoint(x: 0, y: 10_000_000),
    ]
    /// Three edges: an odd count, so a turn or mirror made once per edge and
    /// again per vertex does not come out right by chance, as it can on four.
    private static let triangle = [
        HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 20_000_000, y: 0), HorizontalPoint(x: 0, y: 10_000_000),
    ]

    private func board(
        outline: [HorizontalPoint]? = nil,
        tracks: [HorizontalSegment] = [],
        junctions: [String: HorizontalPoint] = [:],
        lines: [HorizontalSegment] = [],
        dimensions: [HorizontalDimension] = []
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/outline.hprj"), uuid: "b", name: "outline",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: lines, arcs: [], connectionLines: [], airwires: [],
            polygons: outline.map { [HorizontalPolygon(id: "outline", vertices: $0, layer: HorizontalBoardLayers.outline, netID: nil)] } ?? [],
            planes: [], keepouts: [], dimensions: dimensions, decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
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

    /// The layer of the board's own scene, under the selection overlay.
    private func renderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    /// Mounts the canvas, selects everything and returns its renderer and a
    /// key sender.
    private func mount(_ state: State) async throws -> (
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

    private func same(_ lhs: Strokes, _ rhs: Strokes, within tolerance: Float = 2) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            abs(a.from.x - b.from.x) < tolerance && abs(a.from.y - b.from.y) < tolerance
                && abs(a.to.x - b.to.x) < tolerance && abs(a.to.y - b.to.y) < tolerance
        }
    }

    private func closedStrokes(_ points: [HorizontalPoint]) -> Strokes {
        zip(points, points.dropFirst() + points.prefix(1)).map {
            (SIMD2(Float($0.0.x), Float($0.0.y)), SIMD2(Float($0.1.x), Float($0.1.y)))
        }
    }

    /// Moves everything up one key press and commits: what the preview drew,
    /// what the commit drew, and the board committed.
    private func moveUpAndCommit(
        _ state: State, renderer: HorizontalMetalCanvasLayer, group: Int, key: (UInt16, String) throws -> Void
    ) async throws -> (preview: Strokes, drawn: () -> Strokes, board: HorizontalBoard) {
        let before = renderer.residentLineEndpoints(compositeGroup: group)
        XCTAssertFalse(before.isEmpty)
        try key(126, "\u{f700}")   // up: a keyboard move, patched in Metal
        let previewed = await settle {
            let moved = renderer.residentLineEndpoints(compositeGroup: group)
            return moved.count == before.count && moved[0].from.y > before[0].from.y + 1
        }
        XCTAssertTrue(previewed, "the move is previewed")
        let preview = renderer.residentLineEndpoints(compositeGroup: group)
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        return (preview, { renderer.residentLineEndpoints(compositeGroup: group) }, try XCTUnwrap(state.committed.last))
    }

    func testACommittedOutlineMoveIsDrawnWhereItWentAndMovesItOnce() async throws {
        let state = State(board(outline: Self.rectangle))
        let (window, renderer, key) = try await mount(state)
        defer { window.close() }

        let outlineGroup = 1   // BoardCanvasView.boardBodyMetalCompositeGroup
        let (preview, drawn, board) = try await moveUpAndCommit(state, renderer: renderer, group: outlineGroup, key: key)
        let outline = try XCTUnwrap(board.polygons.first).vertices
        XCTAssertTrue(same(closedStrokes(outline), preview),
                      "the outline moved once, as the preview drew it, not once per edge and vertex: \(outline)")
        let shown = await settle { self.same(drawn(), preview) }
        XCTAssertTrue(shown, "the committed outline is drawn where it went, not at its old place: \(drawn())")
    }

    func testACommittedTrackMoveIsDrawnWhereItWent() async throws {
        let track = HorizontalSegment(
            id: "t", from: HorizontalPoint(x: 2_000_000, y: 2_000_000), to: HorizontalPoint(x: 8_000_000, y: 2_000_000),
            width: 250_000, layer: HorizontalBoardLayers.topCopper
        )
        let state = State(board(tracks: [track]))
        let (window, renderer, key) = try await mount(state)
        defer { window.close() }

        let copper = BoardLayerStyle.compositeGroup(for: HorizontalBoardLayers.topCopper)
        let (preview, drawn, board) = try await moveUpAndCommit(state, renderer: renderer, group: copper, key: key)
        let moved = try XCTUnwrap(board.tracks.first)
        XCTAssertTrue(same([(SIMD2(Float(moved.from.x), Float(moved.from.y)), SIMD2(Float(moved.to.x), Float(moved.to.y)))], preview))
        let shown = await settle { self.same(drawn(), preview) }
        XCTAssertTrue(shown, "the committed track is drawn where it went: \(drawn())")
    }

    /// Moves the selection up one key press and commits; the board committed.
    private func keyMoveUp(_ state: State, key: (UInt16, String) throws -> Void) async throws -> HorizontalBoard {
        try key(126, "\u{f700}")
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        return try XCTUnwrap(state.committed.last)
    }

    func testADimensionWithAllItsPartsSelectedMovesWholeAndOnce() async throws {
        // Its two points and its label are three selectables, as in Horizon;
        // all three moving shift it once and leave its label's distance.
        let dimension = HorizontalDimension(
            id: "d", p0: HorizontalPoint(x: 0, y: 0), p1: HorizontalPoint(x: 10_000_000, y: 0),
            labelDistance: 1_000_000, labelSize: 1_500_000, mode: .distance
        )
        let state = State(board(dimensions: [dimension]))
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        let board = try await keyMoveUp(state, key: key)
        let moved = try XCTUnwrap(board.dimensions.first)
        let delta = moved.p0 - dimension.p0
        XCTAssertGreaterThan(delta.y, 0, "it moved up")
        XCTAssertEqual(delta.x, 0)
        XCTAssertEqual(moved.p1 - dimension.p1, delta, "both points by the one step")
        XCTAssertEqual(moved.labelDistance, dimension.labelDistance, "the label goes with them")
    }

    func testALineAndTheJunctionsItEndsOnMoveOnce() async throws {
        // A selected junction carries the end of a line that ends on it, as
        // Horizon's does, but not of one the selection moves whole.
        let silk = HorizontalBoardLayers.topSilkscreen
        let line = HorizontalSegment(
            id: "l", from: HorizontalPoint(x: 0, y: 0), to: HorizontalPoint(x: 5_000_000, y: 0), width: 150_000, layer: silk
        )
        let state = State(board(junctions: ["a": line.from, "b": line.to], lines: [line]))
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        let board = try await keyMoveUp(state, key: key)
        let moved = try XCTUnwrap(board.lines.first)
        let delta = moved.from - line.from
        XCTAssertGreaterThan(delta.y, 0, "it moved up")
        XCTAssertEqual(moved.to - line.to, delta)
        XCTAssertEqual(board.junctions["a"], moved.from, "the junction went with the line's end, once")
        XCTAssertEqual(board.junctions["b"], moved.to)
    }

    func testROnASelectedOutlineTurnsItAQuarterOnce() async throws {
        let state = State(board(outline: Self.triangle))
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        try key(15, "r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let turned = HorizontalRect(points: try XCTUnwrap(state.committed.last?.polygons.first).vertices)
        XCTAssertEqual(turned.width, 10_000_000, accuracy: 1, "a quarter turn stands the triangle on its end")
        XCTAssertEqual(turned.height, 20_000_000, accuracy: 1)
    }

    func testEOnASelectedOutlineMirrorsItOnce() async throws {
        let state = State(board(outline: Self.triangle))
        let (window, _, key) = try await mount(state)
        defer { window.close() }

        try key(14, "e")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let mirrored = try XCTUnwrap(state.committed.last?.polygons.first).vertices
        let bounds = HorizontalRect(points: mirrored)
        XCTAssertEqual(bounds.width, 20_000_000, accuracy: 1)
        let apex = try XCTUnwrap(mirrored.max { $0.y < $1.y })
        XCTAssertEqual(apex.x, bounds.maxX, accuracy: 1, "the apex, on the left, is mirrored to the right: \(mirrored)")
    }
}
#endif
