#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Deleting a plane, with Delete Plane Definition in its polygon's Plane
/// section and in a selected plane's details, through the writer the
/// document saves with. The canvas
/// took the plane out of its board, but the writer keeps every plane entry the
/// model lacks (a parser that dropped one must not read as a user deleting
/// it), so the plane stayed in board.json and came back with the next load.
/// The polygon under it stays, a polygon again: the board keeps a plane's
/// polygon in the plane, as it loads it, so it has to be given back.
@MainActor
final class BoardDeletePlaneTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
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
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    /// The template project's board with a top-copper polygon that is a GND
    /// plane, written to its file as a save writes it, the polygon kept in the
    /// plane as the board loads one.
    private func fixture() throws -> (board: HorizontalBoard, planeID: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-delete-plane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        var board = try XCTUnwrap(project.board)
        board.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND")
        let polygon = HorizontalPolygon(id: "pour", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 20 * mm, y: 0),
            HorizontalPoint(x: 20 * mm, y: 20 * mm), HorizontalPoint(x: 0, y: 20 * mm),
        ], layer: HorizontalBoardLayers.topCopper)
        let plane = HorizontalPlane(polygon: polygon, draft: HorizontalPlaneEditorDraft(netID: "gnd"))
        board.planes.append(plane)
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try writtenKeys("planes"), [plane.id])
        XCTAssertTrue(try writtenKeys("polygons").contains("pour"))
        return (board, plane.id)
    }

    /// The ids of the board file's `planes` or `polygons` map.
    private func writtenKeys(_ key: String) throws -> Set<String> {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set((json[key] as? [String: Any] ?? [:]).keys.map { $0.lowercased() })
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func mount(_ state: State) async throws -> NSWindow {
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
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        return window
    }

    /// The sidebar's Delete Plane Definition, on `ref`.
    private func deleteThePlane(_ state: State, on ref: HorizontalSelectableRef) async throws -> HorizontalBoard {
        state.undo.beginUndoGrouping()
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: ref, type: ref.type, propertyID: "deletePlaneDefinition", value: .bool(true), applyToAll: false))
        let deleted = await settle { state.planeEdits.count == 1 }
        state.undo.endUndoGrouping()
        XCTAssertTrue(deleted)
        let edit = try XCTUnwrap(state.planeEdits.first)
        XCTAssertEqual(edit.actionName, "Delete Plane")
        XCTAssertTrue(edit.board.planes.isEmpty)
        XCTAssertEqual(edit.board.polygons.map(\.id), ["pour"], "the polygon stays, a polygon again")
        return edit.board
    }

    func testDeletePlaneDefinitionOnItsPolygonTakesThePlaneOutOfTheFile() async throws {
        let (board, planeID) = try fixture()
        let state = State(board)
        let window = try await mount(state)
        defer { window.close() }

        let after = try await deleteThePlane(state, on: HorizontalSelectableRef(
            id: "pour", type: .polygonEdge, vertex: 1, layer: HorizontalBoardLayers.topCopper))
        let selected = await settle {
            state.details.groups.map(\.type) == [.polygonEdge] && state.details.groups.first?.items.first?.ref.vertex == 1
        }
        XCTAssertTrue(selected, "the polygon's edge stays selected: \(state.details.groups.map(\.type))")
        let usage = state.details.groups.first?.items.first?.properties.first { $0.id == "usage" }
        XCTAssertEqual(usage?.value, .readOnly("Polygon"))

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertFalse(try writtenKeys("planes").contains(planeID), "the plane is gone from the file")
        XCTAssertTrue(try writtenKeys("polygons").contains("pour"), "and its polygon is not")
    }

    func testDeletePlaneDefinitionOnThePlaneTakesItOutOfTheFile() async throws {
        let (board, planeID) = try fixture()
        let state = State(board)
        let window = try await mount(state)
        defer { window.close() }

        let after = try await deleteThePlane(state, on: HorizontalSelectableRef(
            id: planeID, type: .plane, layer: HorizontalBoardLayers.topCopper))
        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertFalse(try writtenKeys("planes").contains(planeID))
        XCTAssertTrue(try writtenKeys("polygons").contains("pour"))
    }
}
#endif
