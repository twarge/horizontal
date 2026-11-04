#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Moving a plane on the board canvas: by its polygon, which is what a click
/// on a plane picks, and by the plane itself, which Edit Plane selects. The
/// board keeps a plane's polygon in the plane, as it loads it, and the move
/// changed only the board's own polygons, so a plane's outline stayed where
/// it was and the next pour put the fill back there; a moved plane moved only
/// its outline and fills in memory, and the polygon the file stores stayed put.
@MainActor
final class BoardPlanePolygonMoveTests: XCTestCase {
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

    private let mm = 1_000_000.0
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    private func square(_ cx: Double, _ cy: Double, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: cx - half, y: cy - half), HorizontalPoint(x: cx + half, y: cy - half),
            HorizontalPoint(x: cx + half, y: cy + half), HorizontalPoint(x: cx - half, y: cy + half),
        ]
    }

    /// The template project's board with a poured GND plane on a top-copper
    /// polygon, written to its file, its polygon kept in the plane as the
    /// board loads one.
    private func fixture() throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-plane-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        var board = try XCTUnwrap(project.board)
        board.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND")
        let polygon = HorizontalPolygon(id: "pour", vertices: square(10 * mm, 10 * mm, half: 10 * mm),
                                        layer: HorizontalBoardLayers.topCopper)
        var plane = HorizontalPlane(polygon: polygon, draft: HorizontalPlaneEditorDraft(netID: "gnd"))
        plane.fragments = [HorizontalPlaneFragment(paths: [square(10 * mm, 10 * mm, half: 9 * mm)], orphan: false)]
        board.planes.append(plane)
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try writtenPolygonVertices(), polygon.vertices, "the writer writes a plane's outline")
        return board
    }

    private func writtenPolygonVertices() throws -> [HorizontalPoint] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let polygon = try XCTUnwrap((json["polygons"] as? [String: Any])?["pour"] as? [String: Any])
        let vertices = try XCTUnwrap(polygon["vertices"] as? [[String: Any]])
        return try vertices.map { vertex in
            let position = try XCTUnwrap(vertex["position"] as? [NSNumber])
            return HorizontalPoint(x: position[0].doubleValue, y: position[1].doubleValue)
        }
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

    /// Moves the selection up a step with the keyboard and commits the move.
    private func moveUp(_ state: State, key: (UInt16, String) throws -> Void) async throws -> HorizontalBoard {
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
        return try XCTUnwrap(state.committed.last)
    }

    /// The plane's outline and its fills moved by one step, and the outline is
    /// still the plane's alone.
    private func assertMovedTogether(_ before: HorizontalBoard, _ after: HorizontalBoard,
                                     file: StaticString = #filePath, line: UInt = #line) throws -> HorizontalPoint {
        let old = try XCTUnwrap(before.planes.first?.fallbackPolygon)
        let plane = try XCTUnwrap(after.planes.first)
        let new = try XCTUnwrap(plane.fallbackPolygon)
        let delta = new.vertices[0] - old.vertices[0]
        XCTAssertNotEqual(delta, .zero, "the outline moved", file: file, line: line)
        XCTAssertEqual(new.vertices, old.vertices.map { $0 + delta }, "whole, by one step", file: file, line: line)
        XCTAssertEqual(plane.layer, new.layer, file: file, line: line)
        XCTAssertFalse(after.polygons.contains { $0.id == "pour" },
                       "no polygon of the board's own, which an export would write as copper", file: file, line: line)
        let oldFill = try XCTUnwrap(before.planes.first?.fragments.first?.paths.first)
        XCTAssertEqual(plane.fragments.first?.paths.first, oldFill.map { $0 + delta },
                       "its fills move along, once", file: file, line: line)
        return delta
    }

    func testMovingAPlanesPolygonMovesThePlane() async throws {
        let board = try fixture()
        let state = State(board)
        let (window, key) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.details.groups.contains { $0.type == .polygonEdge } }
        XCTAssertTrue(selected)
        XCTAssertFalse(state.details.groups.contains { $0.type == .plane }, "a plane is picked by its polygon")
        let after = try await moveUp(state, key: key)
        let delta = try assertMovedTogether(board, after)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertEqual(try writtenPolygonVertices(), board.planes.first?.fallbackPolygon?.vertices.map { $0 + delta })
    }

    func testMovingThePlaneMovesItsPolygon() async throws {
        let board = try fixture()
        let state = State(board)
        let (window, key) = try await mount(state)
        defer { window.close() }

        // Edit Plane on the polygon selects the plane; its editor closed again.
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.details.groups.contains { $0.type == .polygonEdge } }
        XCTAssertTrue(selected)
        state.actions?.dispatch(.editPlane)
        state.actions?.cancelPlaneEditor?()
        let plane = await settle { state.details.groups.map(\.type) == [.plane] }
        XCTAssertTrue(plane)
        let after = try await moveUp(state, key: key)
        let delta = try assertMovedTogether(board, after)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertEqual(try writtenPolygonVertices(), board.planes.first?.fallbackPolygon?.vertices.map { $0 + delta },
                       "the file has the polygon where the plane went")
    }
}
#endif
