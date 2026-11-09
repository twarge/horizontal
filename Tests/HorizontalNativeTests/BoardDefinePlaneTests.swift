#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Define Plane on a polygon, in a board canvas that has a board of its own
/// already, as it has after any edit and after every pour it takes in place.
/// The plane editor handed the document a board with the plane and kept
/// drawing its own without it: the pour for the plane was turned down as
/// poured for other copper, and the next edit wrote the plane away again.
/// On the way, the polygon's parts are named as the which-object menu and
/// the selection name them: by layer, and once a plane, by the plane's net,
/// never by an id.
@MainActor
final class BoardDefinePlaneTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var delivery: HorizontalPlaneFillDelivery?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var planeEdits: [(board: HorizontalBoard, actionName: String)] = []
        var actions: HorizontalCanvasCommandActions?
        var details: HorizontalSelectionDetailState = .empty
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    /// The host's part: the board it is handed is the one it gives back.
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
                onPlaneEdit: { state.planeEdits.append(($0, $1)); board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
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

    /// A two-pad part to move, and a top-copper polygon that is no plane yet.
    private func fixture() -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.netDetails = ["gnd": HorizontalNetDetails(id: "gnd", name: "GND")]
        board.packages = [HorizontalPlacement(id: "pkg", position: start, angle: 0, mirrored: false, label: "R1", componentID: "component")]
        board.packagePads = [
            HorizontalPolygon(id: "pkg/pad/a", vertices: square(around: HorizontalPoint(x: start.x - 800_000, y: start.y), half: 300_000), layer: top),
            HorizontalPolygon(id: "pkg/pad/b", vertices: square(around: HorizontalPoint(x: start.x + 800_000, y: start.y), half: 300_000), layer: top),
        ]
        board.polygons = [HorizontalPolygon(
            id: "pour", vertices: square(around: HorizontalPoint(x: start.x, y: start.y + 5_000_000), half: 2_000_000), layer: top
        )]
        return board
    }

    /// Fills for `board`'s plane as a pour would hand them over, with one
    /// airwire so the canvas's drawn airwires show when it took them.
    private func delivery(for board: HorizontalBoard, planeID: String, revision: Int) -> HorizontalPlaneFillDelivery {
        let fragment = HorizontalPlaneFragment(
            paths: [square(around: HorizontalPoint(x: start.x, y: start.y + 5_000_000), half: 1_800_000)], orphan: false
        )
        let key = boardPlaneFragmentKey(planeID: planeID, fragmentIndex: 0, fragment: fragment)
        let airwire = HorizontalSegment(
            id: "airwire/gnd/1", from: HorizontalPoint(x: start.x, y: start.y + 3_000_000),
            to: HorizontalPoint(x: start.x + 4_000_000, y: start.y + 3_000_000), width: 0, layer: nil, netID: "gnd"
        )
        let result = HorizontalPlanePourResult(
            fills: HorizontalPlaneFills(
                inputs: HorizontalBoardPlaneInputs.signature(of: board),
                fragmentsByPlaneID: [planeID: [fragment]],
                airwires: [airwire]
            ),
            pouredPlaneIDs: [planeID], planesFileData: nil,
            triangles: [key: boardPlaneFragmentTrianglePoints(fragment)], fragmentKeys: [key],
            isManual: true, registersUndo: false
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

    private var topName: String { HorizontalBoardLayers.name(for: top) }

    private func subtitles(_ state: State, _ type: HorizontalObjectType) -> Set<String> {
        Set(state.details.groups.filter { $0.type == type }.flatMap(\.items).map(\.subtitle))
    }

    /// No selected object is named by an id's first eight digits.
    private func assertNoIDs(_ state: State, file: StaticString = #filePath, line: UInt = #line) {
        let named = state.details.groups.flatMap(\.items).flatMap { [$0.title, $0.subtitle] }
        let ids = named.filter { $0.range(of: "[0-9a-f]{8}", options: .regularExpression) != nil }
        XCTAssertEqual(ids, [], file: file, line: line)
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

    /// Moves R1 up a step with the keyboard and commits the move.
    private func moveThePart(_ state: State, key: (UInt16, String) throws -> Void) async throws {
        let commits = state.committed.count
        state.actions?.dispatch(.cancelInteraction)   // Esc: nothing selected
        let cleared = await settle { state.details.groups.isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertEqual(state.actions?.selectComponents?(["component"]), true)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(126, "\u{f700}")   // up: a keyboard move
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.commitInteraction)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
    }

    func testAPlaneDefinedAfterAnEditIsDrawnPouredAndKept() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        // An edit first, after which the canvas draws from a board of its own.
        try await moveThePart(state, key: key)

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.details.groups.contains { $0.type == .polygonEdge } }
        XCTAssertTrue(selected)
        XCTAssertEqual(subtitles(state, .polygonEdge), [topName], "a polygon's edge is told apart by its layer")
        XCTAssertEqual(subtitles(state, .polygonVertex), [topName])
        assertNoIDs(state)
        state.actions?.dispatch(.definePlane)
        // The editor's Define Plane button, with GND chosen.
        try? await Task.sleep(for: .milliseconds(100))
        state.undo.beginUndoGrouping()
        state.actions?.confirmPlaneEditor?(HorizontalPlaneEditorDraft(netID: "gnd"))
        state.undo.endUndoGrouping()
        let defined = await settle { state.planeEdits.count == 1 }
        XCTAssertTrue(defined)
        let edit = try XCTUnwrap(state.planeEdits.first)
        XCTAssertEqual(edit.actionName, "Define Plane")
        let plane = try XCTUnwrap(edit.board.planes.first)
        XCTAssertEqual(edit.board.planes.count, 1)
        XCTAssertEqual(plane.polygonID, "pour")
        XCTAssertEqual(plane.netID, "gnd")
        XCTAssertEqual(plane.fallbackPolygon?.id, "pour")
        XCTAssertFalse(edit.board.polygons.contains { $0.id == "pour" },
                       "the polygon is kept in the plane, as the board loads it, not among the board's own, which an export writes as copper")
        let planeShown = await settle { subtitles(state, .polygonEdge) == ["Plane GND - \(topName)"] }
        XCTAssertTrue(planeShown, "the polygon stays selected, a plane's now, which the canvas can only show with the plane in its board")
        let edge = try XCTUnwrap(state.details.groups.first { $0.type == .polygonEdge }?.items.first)
        XCTAssertTrue(edge.properties.contains { $0.id == "plane.net" && $0.section == "Plane" }, "its Plane section in the sidebar")

        // The document pours the board it was handed, with the plane.
        state.delivery = delivery(for: edit.board, planeID: plane.id, revision: 1)
        let taken = await settle { drawnAirwireIDs(state) == ["airwire/gnd/1"] }
        XCTAssertTrue(taken, "the pour for the new plane is the canvas's board's pour, so it takes it")

        state.actions?.dispatch(.selectAll)
        let reselected = await settle { state.details.groups.contains { $0.type == .polygonEdge } }
        XCTAssertTrue(reselected)
        XCTAssertEqual(subtitles(state, .polygonEdge), ["Plane GND - \(topName)"], "a plane's polygon gives the plane's net")
        assertNoIDs(state)

        // The next edit starts from the board with the plane.
        try await moveThePart(state, key: key)
        let after = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(after.planes.map(\.id), [plane.id], "an edit after Define Plane keeps the plane")
        XCTAssertEqual(after.planes.first?.netID, "gnd")
        XCTAssertFalse(after.planes.first?.fragments.isEmpty ?? true, "with the fills it was poured")
    }
}
#endif
