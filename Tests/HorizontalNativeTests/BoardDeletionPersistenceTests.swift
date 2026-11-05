#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// What the board canvas deletes, and how it moves a keepout, reaching the
/// file. The writer keeps every polygon, hole and keepout entry the model
/// lacks (a parser that dropped one must not read as a user deleting it), so a
/// deletion has to be flagged, and only vias, dimensions and planes were: a
/// deleted polygon, hole or keepout stayed in board.json and came back with
/// the next load. A keepout's outline, and a plane's, live in the keepout and
/// the plane, as the board loads them, and the writer wrote neither, so a
/// moved keepout went back too.
@MainActor
final class BoardDeletionPersistenceTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
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
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    private func vertices(_ cx: Int, _ cy: Int, half: Int) -> [[String: Any]] {
        [(cx - half, cy - half), (cx + half, cy - half), (cx + half, cy + half), (cx - half, cy + half)].map {
            ["type": "line", "position": [$0.0, $0.1], "arc_center": [0, 0], "arc_reverse": false]
        }
    }

    private func newProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-board-deletes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
    }

    private func boardJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writtenKeys(_ key: String) throws -> Set<String> {
        Set((try boardJSON()[key] as? [String: Any] ?? [:]).keys.map { $0.lowercased() })
    }

    private func writtenPolygonY(_ id: String) throws -> Int {
        let polygon = try XCTUnwrap((try boardJSON()["polygons"] as? [String: Any])?[id] as? [String: Any])
        let vertex = try XCTUnwrap((polygon["vertices"] as? [[String: Any]])?.first)
        return try XCTUnwrap((vertex["position"] as? [NSNumber])?[1].intValue)
    }

    /// The template project with a plain top-copper polygon, a hole and a
    /// top-copper keepout written into its board file, as Horizon writes
    /// them, and the board the loader makes of it.
    private func loadedFixture() throws -> HorizontalBoard {
        try newProject()
        var json = try boardJSON()
        var polygons = json["polygons"] as? [String: Any] ?? [:]
        polygons["loose"] = ["layer": HorizontalBoardLayers.topCopper, "parameter_class": "", "vertices": vertices(5 * mm, 5 * mm, half: 2 * mm)]
        polygons["ko-poly"] = ["layer": HorizontalBoardLayers.topCopper, "parameter_class": "", "vertices": vertices(15 * mm, 5 * mm, half: 2 * mm)]
        json["polygons"] = polygons
        json["keepouts"] = ["ko": ["polygon": "ko-poly", "keepout_class": "", "all_cu_layers": false,
                                   "exposed_cu_only": false, "patch_types_cu": [] as [String]]]
        json["holes"] = ["hole-1": ["placement": ["shift": [25 * mm, 5 * mm], "angle": 0, "mirror": false],
                                    "parameter_set": ["hole_diameter": mm]]]
        try archive.replaceRegularFileData(relativePath: "board.json", with: try JSONSerialization.data(withJSONObject: json))
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        let board = try XCTUnwrap(project.board)
        XCTAssertEqual(board.polygons.map(\.id), ["loose"], "a keepout's polygon is the keepout's, not the board's")
        XCTAssertEqual(board.keepouts.map(\.id), ["ko"])
        XCTAssertEqual(board.holes.map(\.id), ["hole-1"])
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
        return (window, key)
    }

    private func selectAll(_ state: State, including types: Set<HorizontalObjectType>) async {
        state.actions?.dispatch(.selectAll)
        let selected = await settle { types.isSubset(of: Set(state.details.groups.map(\.type))) }
        XCTAssertTrue(selected, "selected \(state.details.groups.map(\.type))")
    }

    private func deleteSelection(_ state: State) async throws -> HorizontalBoard {
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.deleteSelection)
        state.undo.endUndoGrouping()
        let deleted = await settle { state.committed.count == 1 }
        XCTAssertTrue(deleted)
        return try XCTUnwrap(state.committed.last)
    }

    func testDeletedPolygonsHolesAndKeepoutsLeaveTheFile() async throws {
        let state = State(try loadedFixture())
        let (window, _) = try await mount(state)
        defer { window.close() }

        await selectAll(state, including: [.polygonEdge, .keepout, .boardHole])
        let after = try await deleteSelection(state)
        XCTAssertTrue(after.polygons.isEmpty)
        XCTAssertTrue(after.keepouts.isEmpty)
        XCTAssertTrue(after.holes.isEmpty)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertFalse(try writtenKeys("polygons").contains("loose"), "the polygon is gone from the file")
        XCTAssertFalse(try writtenKeys("holes").contains("hole-1"), "the hole too")
        XCTAssertFalse(try writtenKeys("keepouts").contains("ko"), "the keepout too")
        XCTAssertFalse(try writtenKeys("polygons").contains("ko-poly"), "with its outline, as Horizon's keepout goes with its polygon")
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertTrue(reloaded.polygons.isEmpty && reloaded.keepouts.isEmpty && reloaded.holes.isEmpty, "and none comes back")
    }

    func testAMovedKeepoutIsWrittenWhereItWent() async throws {
        let state = State(try loadedFixture())
        let (window, key) = try await mount(state)
        defer { window.close() }
        let before = try writtenPolygonY("ko-poly")

        await selectAll(state, including: [.keepout])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.commitInteraction)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let after = try XCTUnwrap(state.committed.last)
        let moved = try XCTUnwrap(after.keepouts.first?.polygon.vertices.first?.y)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertNotEqual(Int(moved), before, "the keepout moved")
        XCTAssertEqual(try writtenPolygonY("ko-poly"), Int(moved), "and its outline is written where it went")
    }

    /// Deleting a plane's outline takes the plane with it, as Horizon's
    /// Board::delete_dependants takes a plane whose polygon is gone.
    func testDeletingAPlanesOutlineTakesThePlane() async throws {
        try newProject()
        var board = try XCTUnwrap(project.board)
        board.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND")
        let outline = HorizontalPolygon(id: "pour", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: Double(20 * mm), y: 0),
            HorizontalPoint(x: Double(20 * mm), y: Double(20 * mm)), HorizontalPoint(x: 0, y: Double(20 * mm)),
        ], layer: HorizontalBoardLayers.topCopper)
        let plane = HorizontalPlane(polygon: outline, draft: HorizontalPlaneEditorDraft(netID: "gnd"))
        board.planes.append(plane)
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertTrue(try writtenKeys("polygons").contains("pour"))

        let state = State(board)
        let (window, _) = try await mount(state)
        defer { window.close() }
        await selectAll(state, including: [.polygonEdge])
        let after = try await deleteSelection(state)
        XCTAssertTrue(after.planes.isEmpty, "the plane went with its outline")
        XCTAssertTrue(after.polygons.isEmpty)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertFalse(try writtenKeys("planes").contains(plane.id))
        XCTAssertFalse(try writtenKeys("polygons").contains("pour"))
    }
}
#endif
