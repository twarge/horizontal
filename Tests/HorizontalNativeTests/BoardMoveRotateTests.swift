#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// R during a board move turns what is being moved (105): the commit keeps
/// both the turn and the move as one undo step back to the board from before
/// the move, and Esc leaves the board as it was. Before, the turn went into a
/// board the move neither drew nor committed, so a commit after moving lost it
/// and Esc left it behind with no undo step.
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

    private func fixture() -> HorizontalBoard {
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
