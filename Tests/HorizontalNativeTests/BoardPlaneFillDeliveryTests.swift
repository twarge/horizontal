#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A pour's fills reach the board canvas without its being reset: the board
/// shown takes them in place, a tool in use keeps going and gets them once it
/// is done, and fills poured for copper that has since moved are turned down.
/// Before, a pour landed through `syncRevision`, which ended any move, route
/// or placement in progress and rebuilt the whole scene.
@MainActor
final class BoardPlaneFillDeliveryTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var delivery: HorizontalPlaneFillDelivery?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
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
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings,
                planeFillDelivery: state.delivery)
        }
    }

    private let start = HorizontalPoint(x: 10_000_000, y: 10_000_000)
    private let top = HorizontalBoardLayers.topCopper

    private func square(around center: HorizontalPoint, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y + half),
            HorizontalPoint(x: center.x - half, y: center.y + half),
        ]
    }

    /// A two-pad part to move, and an unpoured plane beside it.
    private func fixture() -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.packages = [HorizontalPlacement(id: "pkg", position: start, angle: 0, mirrored: false, label: "R1", componentID: "component")]
        board.packagePads = [
            HorizontalPolygon(id: "pkg/pad/a", vertices: square(around: HorizontalPoint(x: start.x - 800_000, y: start.y), half: 300_000), layer: top),
            HorizontalPolygon(id: "pkg/pad/b", vertices: square(around: HorizontalPoint(x: start.x + 800_000, y: start.y), half: 300_000), layer: top),
        ]
        var plane = HorizontalPlane(
            id: "plane", netID: "gnd", polygonID: "plane-outline", layer: top,
            priority: 0, fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: []
        )
        plane.fallbackPolygon = HorizontalPolygon(
            id: "plane-outline", vertices: square(around: HorizontalPoint(x: start.x, y: start.y + 5_000_000), half: 2_000_000),
            layer: top, netID: "gnd"
        )
        board.planes = [plane]
        return board
    }

    /// Fills for `board` as a pour would hand them over, with one airwire so
    /// the canvas's drawn airwires show when it took them.
    private func delivery(for board: HorizontalBoard, revision: Int, inputs: Int? = nil) -> HorizontalPlaneFillDelivery {
        let fragment = HorizontalPlaneFragment(
            paths: [square(around: HorizontalPoint(x: start.x, y: start.y + 5_000_000), half: 1_800_000)], orphan: false
        )
        let key = boardPlaneFragmentKey(planeID: "plane", fragmentIndex: 0, fragment: fragment)
        let airwire = HorizontalSegment(
            id: "airwire/gnd/1", from: HorizontalPoint(x: start.x, y: start.y + 3_000_000),
            to: HorizontalPoint(x: start.x + 4_000_000, y: start.y + 3_000_000), width: 0, layer: nil, netID: "gnd"
        )
        let result = HorizontalPlanePourResult(
            fills: HorizontalPlaneFills(
                inputs: inputs ?? HorizontalBoardPlaneInputs.signature(of: board),
                fragmentsByPlaneID: ["plane": [fragment]],
                airwires: [airwire]
            ),
            pouredPlaneIDs: ["plane"], planesFileData: nil,
            triangles: [key: boardPlaneFragmentTrianglePoints(fragment)], fragmentKeys: [key],
            isManual: false, registersUndo: false
        )
        return HorizontalPlaneFillDelivery(revision: revision, result: result)
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

    private func drawnAirwireIDs(_ state: State) -> [String]? {
        state.actions?.drawnAirwires?()?.airwires.map(\.id)
    }

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
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil && self.drawnAirwireIDs(state) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        return (window, key)
    }

    func testTheCanvasTakesNewFillsInPlace() async throws {
        let board = fixture()
        let state = State(board)
        let (window, _) = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(drawnAirwireIDs(state), [])

        state.delivery = delivery(for: board, revision: 1)
        let taken = await settle { drawnAirwireIDs(state) == ["airwire/gnd/1"] }
        XCTAssertTrue(taken, "the scene draws the pour's airwires, so it took the fills")
        XCTAssertTrue(state.committed.isEmpty, "the fills are the document's already; the canvas reports no edit")
    }

    func testAMoveInProgressKeepsGoingAndTheFillsWaitForIt() async throws {
        let board = fixture()
        let state = State(board)
        let (window, key) = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(state.actions?.selectComponents?(["component"]), true)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)

        try key(126, "\u{f700}")   // up: a keyboard move
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)

        state.delivery = delivery(for: board, revision: 1)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.actions?.canCommitInteraction, true, "a pour landing does not end the move")
        XCTAssertEqual(drawnAirwireIDs(state), [], "and its fills wait until the move is done")

        // Esc puts the board back as it was, which is the board the fills
        // were poured for, so they are taken then.
        try key(53, "\u{1b}")
        let taken = await settle { drawnAirwireIDs(state) == ["airwire/gnd/1"] }
        XCTAssertTrue(taken)
        XCTAssertEqual(state.actions?.canCommitInteraction, false)
    }

    func testFillsPouredForOtherCopperAreTurnedDown() async throws {
        let board = fixture()
        let state = State(board)
        let (window, _) = try await mount(state)
        defer { window.close() }

        let inputs = HorizontalBoardPlaneInputs.signature(of: board)
        state.delivery = delivery(for: board, revision: 1, inputs: inputs &+ 1)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawnAirwireIDs(state), [], "the board has moved on from what these fills were poured around")

        state.delivery = delivery(for: board, revision: 2)
        let taken = await settle { drawnAirwireIDs(state) == ["airwire/gnd/1"] }
        XCTAssertTrue(taken, "the next pour, for the board as it is, is taken")
    }
}
#endif
