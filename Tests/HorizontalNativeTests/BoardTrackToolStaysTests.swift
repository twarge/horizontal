#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The track tool stays once a route ends, waiting for the click that starts
/// the next, as Horizon's router does; with no route under way, Escape or
/// Return leaves it. Waiting, it has no board of its own, so a pour's fills
/// reach the canvas and a board replaced under it keeps it going.
///
/// A route needs clicks, which a mounted canvas can't be sent, so the routes
/// that end on copper are `BoardTrackLoopTests`'; these drive the tool waiting.
@MainActor
final class BoardTrackToolStaysTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var delivery: HorizontalPlaneFillDelivery?
        @Published var revision = 0
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let model = HorizontalRouteInspectorModel(interval: 0)
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        init(_ board: HorizontalBoard) {
            source = board
            // Grouped by hand around the one commit that registers a step.
            undo.groupsByEvent = false
        }
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
                routeInspector: state.model,
                toolSettings: state.toolSettings,
                syncRevision: state.revision,
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

    /// A two-pad part, and an unpoured plane beside it.
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
    private func delivery(for board: HorizontalBoard, revision: Int) -> HorizontalPlaneFillDelivery {
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
                inputs: HorizontalBoardPlaneInputs.signature(of: board),
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

    /// The track tool is in use: its posture key is there only then.
    private func routing(_ state: State) -> Bool {
        state.actions?.canFlipTrackPosture == true
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

    /// Waiting for a route the tool has laid nothing, so a pour's fills are
    /// taken at once, where they used to wait until the tool was left; and
    /// Escape, with no route under way, leaves the tool with them still there.
    func testTheToolWaitingForARouteTakesNewFillsAndEscapeLeavesIt() async throws {
        let board = fixture()
        let state = State(board)
        let (window, key) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.drawTrack)
        let armed = await settle { routing(state) }
        XCTAssertTrue(armed)

        state.delivery = delivery(for: board, revision: 1)
        let taken = await settle { drawnAirwireIDs(state) == ["airwire/gnd/1"] }
        XCTAssertTrue(taken, "the scene draws the pour's airwires, so it took the fills")
        XCTAssertTrue(routing(state), "and the tool is still waiting")

        try key(53, "\u{1b}")
        let left = await settle { !routing(state) }
        XCTAssertTrue(left, "Escape with no route under way leaves the tool")
        XCTAssertEqual(state.actions?.canCancelInteraction, false)
        XCTAssertEqual(drawnAirwireIDs(state), ["airwire/gnd/1"], "leaving puts back no board from before the pour")
        XCTAssertTrue(state.committed.isEmpty, "and reports no edit")
    }

    /// A board replaced under the tool, by an undo, a schematic sync or an
    /// MCP edit, used to end it; waiting, it keeps going on the new board,
    /// and the route inspector with it. Return then leaves it, as Escape does.
    func testTheToolStaysWhenTheBoardIsReplacedUnderItAndReturnLeavesIt() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.drawTrack)
        let armed = await settle { routing(state) && state.model.isRouting && state.model.state != nil }
        XCTAssertTrue(armed)

        state.revision += 1
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(routing(state), "the tool keeps waiting for a route")
        XCTAssertTrue(state.model.isRouting, "and the inspector stays")
        XCTAssertEqual(state.model.state?.hasStarted, false)

        try key(36, "\r")
        let left = await settle { !routing(state) && !state.model.isRouting }
        XCTAssertTrue(left, "Return with no route under way leaves the tool")
        XCTAssertTrue(state.committed.isEmpty)
    }

    /// Undo, the step after a route most of all, puts a board back under the
    /// tool waiting for the next: it waits on, for a route on that board.
    func testTheToolWaitsOnThroughAnUndo() async throws {
        let board = fixture()
        let state = State(board)
        let (window, key) = try await mount(state)
        defer { window.close() }

        // A step to take back: the part moved up one grid step.
        XCTAssertEqual(state.actions?.selectComponents?(["component"]), true)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        state.undo.beginUndoGrouping()
        try key(36, "\r")
        state.undo.endUndoGrouping()
        let moved = await settle { state.committed.last?.packages.first?.position != start }
        XCTAssertTrue(moved)
        XCTAssertTrue(state.undo.canUndo)

        state.actions?.dispatch(.drawTrack)
        let armed = await settle { routing(state) && state.model.isRouting }
        XCTAssertTrue(armed)

        state.undo.undo()
        let undone = await settle { state.committed.last?.packages.first?.position == start }
        XCTAssertTrue(undone, "the part is back")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(routing(state), "and the tool still waits for a route")
        XCTAssertTrue(state.model.isRouting)
        XCTAssertEqual(state.model.state?.hasStarted, false)

        try key(53, "\u{1b}")
        let left = await settle { !routing(state) }
        XCTAssertTrue(left)
        XCTAssertEqual(state.committed.last?.packages.first?.position, start, "leaving the tool keeps the undo")
    }
}
#endif
