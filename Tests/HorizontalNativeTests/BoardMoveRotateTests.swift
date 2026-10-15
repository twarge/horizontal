#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// R during a board move turns what is being moved (105): the commit keeps
/// both the turn and the move as one undo step back to the board from before
/// the move, and Esc leaves the board as it was. Before, the turn went into a
/// board the move neither drew nor committed, so a commit after moving lost it
/// and Esc left it behind with no undo step.
///
/// The turn is made the way the move is (122): the resident scene is drawn
/// turned in place, with nothing rebuilt, and what it draws is what the
/// rebuilt scene draws after the commit, texts included.
@MainActor
final class BoardMoveRotateTests: XCTestCase {
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

    private let start = HorizontalPoint(x: 10_000_000, y: 10_000_000)

    private func fixture(artwork: Bool = false) -> HorizontalBoard {
        let half = 300_000.0
        func pad(_ id: String, _ dx: Double) -> HorizontalPolygon {
            let c = HorizontalPoint(x: start.x + dx, y: start.y)
            return HorizontalPolygon(id: id, vertices: [
                .init(x: c.x - half, y: c.y - half), .init(x: c.x + half, y: c.y - half),
                .init(x: c.x + half, y: c.y + half), .init(x: c.x - half, y: c.y + half),
            ], layer: HorizontalBoardLayers.topCopper, netID: nil)
        }
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/rotate.hprj"), uuid: "b", name: "rotate",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: start, angle: 0, mirrored: false, label: "R1", componentID: "component")],
            packagePads: [pad("pkg/pad/a", -800_000), pad("pkg/pad/b", 800_000)], packageHoles: [],
            packagePolygons: [],
            // An outline along the top of the part, and its name above it,
            // reading left to right: a quarter turn clockwise takes the name
            // to an angle the scene draws the other way round.
            packageLines: artwork ? [HorizontalSegment(
                id: "pkg/line/top",
                from: HorizontalPoint(x: start.x - 1_200_000, y: start.y + 600_000),
                to: HorizontalPoint(x: start.x + 1_200_000, y: start.y + 600_000),
                width: 150_000, layer: HorizontalBoardLayers.topSilkscreen
            )] : [],
            packageArcs: [],
            packageTexts: artwork ? [HorizontalText(
                id: "pkg/text/name", text: "R1",
                position: HorizontalPoint(x: start.x - 600_000, y: start.y + 1_100_000),
                size: 1_000_000, layer: HorizontalBoardLayers.topSilkscreen, origin: .baseline
            )] : [],
            texts: [],
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

    /// The renderer of the board's own scene, under the selection overlay.
    private func renderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.loadProfileLabel == "Metal overlay" { return renderer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    /// Mounts the canvas, selects the package and returns a key sender.
    private func mount(_ state: State) async throws -> (window: NSWindow, key: (UInt16, String) throws -> Void) {
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
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        // 104: the workspace learns whether a pushed selection changed the canvas.
        XCTAssertEqual(state.actions?.selectComponents?(["component"]), true)
        XCTAssertEqual(state.actions?.selectComponents?(["component"]), false, "already the selection")
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        return (window, key)
    }

    private typealias Strokes = [(from: SIMD2<Float>, to: SIMD2<Float>)]

    private func same(_ lhs: Strokes, _ rhs: Strokes, within tolerance: Float = 2) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            abs(a.from.x - b.from.x) < tolerance && abs(a.from.y - b.from.y) < tolerance
                && abs(a.to.x - b.to.x) < tolerance && abs(a.to.y - b.to.y) < tolerance
        }
    }

    private func package(_ board: HorizontalBoard?) -> HorizontalPlacement? {
        board?.packages.first { $0.id == "pkg" }
    }

    private func quarterTurns(_ angle: Int) -> Int {
        ((angle % 65_536) + 65_536) % 65_536 / 16_384
    }

    func testRDuringAMoveTurnsWhatMovesAndTheCommitKeepsTheTurnAndTheMove() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        try key(126, "\u{f700}")   // up: a keyboard move
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        try key(15, "r")
        XCTAssertEqual(state.committed.count, 0, "R while moving commits nothing")
        XCTAssertEqual(state.actions?.canCommitInteraction, true, "and the move carries on")
        try key(126, "\u{f700}")   // and on from the turned package
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)

        let placed = try XCTUnwrap(package(state.committed.last))
        XCTAssertEqual(quarterTurns(placed.angle), 3, "turned a quarter, as R turns")
        XCTAssertEqual(placed.position.x, start.x, accuracy: 1)
        XCTAssertGreaterThan(placed.position.y, start.y, "moved up by both key presses")

        XCTAssertTrue(state.undo.canUndo)
        state.undo.undo()
        let undone = await settle { state.committed.count == 2 }
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(package(state.committed.last))
        XCTAssertEqual(restored.angle, 0, "one undo step back to before the move")
        XCTAssertEqual(restored.position, start)
        XCTAssertFalse(state.undo.canUndo)
    }

    func testRDuringAMoveTurnsTheResidentSceneInPlaceAndDrawsWhatTheCommitDraws() async throws {
        let state = State(fixture(artwork: true))
        let (window, key) = try await mount(state)
        defer { window.close() }
        let hosted = try XCTUnwrap(window.contentView)
        let mounted = await settle { self.renderer(in: hosted)?.presentedContentKey != nil }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let silkscreen = BoardLayerStyle.compositeGroup(for: HorizontalBoardLayers.topSilkscreen)
        let before = renderer.residentLineEndpoints(compositeGroup: silkscreen)
        // The outline, then the name's strokes.
        XCTAssertGreaterThan(before.count, 2)
        func outlineIsUpright(_ strokes: Strokes) -> Bool {
            guard let outline = strokes.first else { return false }
            return abs(outline.from.x - outline.to.x) < 2 && abs(outline.from.y - outline.to.y) > 2_000_000
        }
        XCTAssertFalse(outlineIsUpright(before))

        try key(126, "\u{f700}")   // up: a keyboard move, patched in Metal
        let previewed = await settle {
            let moved = renderer.residentLineEndpoints(compositeGroup: silkscreen)
            return moved.count == before.count && moved[0].from.y > before[0].from.y + 1
        }
        XCTAssertTrue(previewed)
        try await Task.sleep(for: .milliseconds(300))
        let uploads = renderer.residentSceneUploads

        try key(15, "r")
        let turned = await settle { outlineIsUpright(renderer.residentLineEndpoints(compositeGroup: silkscreen)) }
        XCTAssertTrue(turned, "the preview turns")
        let turnedOutline = try XCTUnwrap(renderer.residentLineEndpoints(compositeGroup: silkscreen).first)
        try key(126, "\u{f700}")   // and the turned part moves on
        let movedOn = await settle {
            guard let outline = renderer.residentLineEndpoints(compositeGroup: silkscreen).first else { return false }
            return outline.from.y > turnedOutline.from.y + 1 && abs(outline.from.x - turnedOutline.from.x) < 2
        }
        XCTAssertTrue(movedOn)
        try await Task.sleep(for: .milliseconds(300))
        let preview = renderer.residentLineEndpoints(compositeGroup: silkscreen)
        XCTAssertTrue(outlineIsUpright(preview))
        XCTAssertEqual(renderer.residentSceneUploads, uploads,
                       "R turned the resident scene in place: nothing was built or uploaded again")
        XCTAssertTrue(state.committed.isEmpty)

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(quarterTurns(try XCTUnwrap(package(board)).angle), 3)
        // Turned clockwise, the name sits at an angle the scene draws the other
        // way round, so the preview could not just turn its strokes: it drew
        // them as the committed text draws.
        let name = try XCTUnwrap(board.packageTexts.first)
        XCTAssertEqual(name.angle, 49_152)
        let nameStrokes: Strokes = HorizontalOutlineTextRenderer.outlineSegments(for: name).map {
            (SIMD2(Float($0.0.x), Float($0.0.y)), SIMD2(Float($0.1.x), Float($0.1.y)))
        }
        XCTAssertTrue(same(Array(preview.dropFirst()), nameStrokes), "the preview draws the name as the board has it")
        // The commit rebuilds the scene, as every package move's does, and
        // draws what the preview drew.
        let rebuilt = await settle { renderer.residentSceneUploads > uploads }
        XCTAssertTrue(rebuilt)
        let drawn = await settle { self.same(renderer.residentLineEndpoints(compositeGroup: silkscreen), preview) }
        XCTAssertTrue(drawn, "the preview is what the committed board draws")
    }

    func testRThenEnterWithoutMovingAgainStillTurns() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        try key(126, "\u{f700}")
        try key(15, "r")
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed, "a turn with no move after it still lands")
        XCTAssertEqual(quarterTurns(try XCTUnwrap(package(state.committed.last)).angle), 3)
    }

    func testEscAfterRDuringAMoveLeavesTheBoardAsItWas() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        try key(126, "\u{f700}")
        try key(15, "r")
        try key(53, "\u{1b}")
        let stopped = await settle { state.actions?.canCommitInteraction != true }
        XCTAssertTrue(stopped)
        XCTAssertTrue(state.committed.isEmpty)
        XCTAssertFalse(state.undo.canUndo)

        // Nothing of the cancelled turn is left in the canvas: the next move
        // starts from the package as it was.
        let reselected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(reselected)
        try key(126, "\u{f700}")
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        XCTAssertEqual(try XCTUnwrap(package(state.committed.last)).angle, 0)
    }
}
#endif
