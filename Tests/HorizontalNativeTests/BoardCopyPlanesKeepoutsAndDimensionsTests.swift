#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Copy, Paste and Duplicate of the board's planes, keepouts, dimensions and
/// decals. A plane's and a keepout's outline is kept in it, not among the
/// board's polygons, so Copy found no polygon under a selected outline and
/// took nothing; the other two it never looked for.
@MainActor
final class BoardCopyPlanesKeepoutsAndDimensionsTests: XCTestCase {
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
    private let decalID = "9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    /// The template board, which has a GND plane on each side, with a
    /// keepout, a dimension and a decal added.
    private func fixture() throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-copy-planes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        let edited = try HorizontalCanvasProjectEdit.archive(applying: [
            ["op": "place_keepout", "layer": 0,
             "vertices": [["x_mm": 5, "y_mm": 5], ["x_mm": 9, "y_mm": 5], ["x_mm": 9, "y_mm": 8], ["x_mm": 5, "y_mm": 8]]],
            ["op": "place_dimension", "from": ["x_mm": 5, "y_mm": -5], "to": ["x_mm": 15, "y_mm": -5]],
        ], to: archive, in: project)
        archive = edited.archive
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        var board = try XCTUnwrap(project.board)
        XCTAssertEqual(board.planes.count, 2)
        XCTAssertEqual(board.keepouts.count, 1)
        XCTAssertEqual(board.dimensions.count, 1)
        let square: [HorizontalPoint] = [(19, 4), (21, 4), (21, 6), (19, 6)].map {
            HorizontalPoint(x: Double($0.0 * mm), y: Double($0.1 * mm))
        }
        board.decals = [HorizontalBoardDecal(
            id: "decal-1", decalID: decalID, name: "Logo",
            polygons: [HorizontalPolygon(id: "decal-1/polygon/p", vertices: square, layer: HorizontalBoardLayers.topSilkscreen)],
            lines: [], arcs: [], texts: [],
            position: HorizontalPoint(x: Double(20 * mm), y: Double(5 * mm))
        )]
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

    private func commit(_ state: State, _ command: HorizontalCanvasCommand) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(command)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
        return try XCTUnwrap(state.committed.last)
    }

    /// Duplicate of everything selected makes a second plane of each plane,
    /// with an outline of its own and the same net, a second keepout, a
    /// second dimension and a second decal, each moved by the same step; and
    /// all of them are written and load again.
    func testDuplicateCopiesPlanesKeepoutsDimensionsAndDecals() async throws {
        let before = try fixture()
        let state = State(before)
        let (window, _) = try await mount(state)
        defer { window.close() }

        await selectAll(state, including: [.polygonEdge, .dimension, .boardDecal])
        let after = try await commit(state, .duplicateSelection)
        XCTAssertEqual(after.planes.count, 4)
        XCTAssertEqual(after.keepouts.count, 2)
        XCTAssertEqual(after.dimensions.count, 2)
        XCTAssertEqual(after.decals.count, 2)

        let original = try XCTUnwrap(before.planes.first)
        let outline = try XCTUnwrap(original.fallbackPolygon)
        let copies = after.planes.filter { plane in !before.planes.contains { $0.id == plane.id } }
        XCTAssertEqual(copies.count, 2)
        for copy in copies {
            let own = try XCTUnwrap(copy.fallbackPolygon)
            XCTAssertEqual(copy.polygonID, own.id)
            XCTAssertFalse(before.planes.contains { $0.polygonID == copy.polygonID }, "an outline of its own")
            XCTAssertEqual(copy.netID, original.netID)
            XCTAssertEqual(own.vertices.count, outline.vertices.count)
            XCTAssertTrue(copy.fragments.isEmpty, "poured by the next pour")
        }
        let top = try XCTUnwrap(copies.first { $0.layer == original.layer }?.fallbackPolygon)
        let step = top.vertices[0] - outline.vertices[0]
        XCTAssertNotEqual(step, .zero, "the copy lands beside the original")

        let keepout = try XCTUnwrap(after.keepouts.first { $0.id != before.keepouts[0].id })
        XCTAssertEqual(keepout.polygonID, keepout.polygon.id)
        XCTAssertNotEqual(keepout.polygonID, before.keepouts[0].polygonID)
        XCTAssertEqual(keepout.polygon.vertices[0] - before.keepouts[0].polygon.vertices[0], step)
        XCTAssertEqual(keepout.allCopperLayers, before.keepouts[0].allCopperLayers)

        let dimension = try XCTUnwrap(after.dimensions.first { $0.id != before.dimensions[0].id })
        XCTAssertEqual(dimension.p0 - before.dimensions[0].p0, step)
        XCTAssertEqual(dimension.length, before.dimensions[0].length, accuracy: 1)

        let decal = try XCTUnwrap(after.decals.first { $0.id != "decal-1" })
        XCTAssertEqual(decal.decalID, decalID)
        XCTAssertEqual(try XCTUnwrap(decal.position) - HorizontalPoint(x: Double(20 * mm), y: Double(5 * mm)), step)
        XCTAssertEqual(decal.polygons.first?.id, "\(decal.id)/polygon/p")

        // Written as the board writes its own, and read back.
        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(Set(reloaded.planes.map(\.id)), Set(after.planes.map(\.id)))
        XCTAssertEqual(Set(reloaded.keepouts.map(\.id)), Set(after.keepouts.map(\.id)))
        XCTAssertEqual(Set(reloaded.dimensions.map(\.id)), Set(after.dimensions.map(\.id)))
        let written = try XCTUnwrap(reloaded.planes.first { $0.id == copies[0].id })
        XCTAssertEqual(written.netID, original.netID)
        XCTAssertEqual(written.fallbackPolygon?.vertices.count ?? written.points.count, outline.vertices.count)
    }

    /// Copy then Paste: the copies follow the pointer until Return puts
    /// them down, and nothing is added before that.
    func testCopyThenPastePutsDownAPlaneAndAKeepout() async throws {
        let before = try fixture()
        let state = State(before)
        let (window, _) = try await mount(state)
        defer { window.close() }

        await selectAll(state, including: [.polygonEdge])
        state.actions?.dispatch(.copySelection)
        state.actions?.dispatch(.pasteSelection)
        let pasting = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(pasting, "the paste is in hand")
        XCTAssertTrue(state.committed.isEmpty)
        let after = try await commit(state, .commitInteraction)
        XCTAssertEqual(after.planes.count, 4)
        XCTAssertEqual(after.keepouts.count, 2)
        XCTAssertEqual(after.dimensions.count, 2)
    }
}
#endif
