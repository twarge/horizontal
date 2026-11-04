#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Board decals and new board holes reaching the file. The writer had no
/// patcher for decals at all, so a decal moved or deleted on the canvas came
/// back with the next load; and it only updated holes the file had already,
/// so a hole Paste or Duplicate made was never written.
@MainActor
final class BoardDecalAndHoleWritingTests: XCTestCase {
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
    private let padstackID = "4c2a8f0e-5d3b-4f6a-9e1c-7b8d2a3f4e5c"
    private let decalID = "9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    private func boardJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entries(_ key: String) throws -> [String: [String: Any]] {
        (try boardJSON()[key] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    /// The template project with a hole on a padstack and a board decal
    /// written into its board file, as Horizon writes them. The hole loads;
    /// the decal's pool item is not in the project, so the decal is given to
    /// the board here as the loader would make it.
    private func fixture() throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-decal-hole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        var json = try boardJSON()
        json["holes"] = ["hole-1": ["padstack": padstackID,
                                    "placement": ["shift": [5 * mm, 5 * mm], "angle": 0, "mirror": false],
                                    "parameter_set": ["hole_diameter": 3 * mm]]]
        json["decals"] = ["decal-1": ["decal": decalID,
                                      "placement": ["shift": [20 * mm, 5 * mm], "angle": 900, "mirror": false],
                                      "flip": false, "scale": 2.0]]
        try archive.replaceRegularFileData(relativePath: "board.json", with: try JSONSerialization.data(withJSONObject: json))
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        var board = try XCTUnwrap(project.board)
        XCTAssertEqual(board.holes.map(\.id), ["hole-1"])
        XCTAssertEqual(board.holes.first?.padstackID, padstackID)

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

    func testAMovedDecalIsWrittenWhereItWent() async throws {
        let state = State(try fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        await selectAll(state, including: [.boardDecal])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        let after = try await commit(state, .commitInteraction)
        let moved = try XCTUnwrap(after.decals.first?.position)
        XCTAssertEqual(moved.x, Double(20 * mm))
        XCTAssertNotEqual(moved.y, Double(5 * mm), "the decal moved")

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        let decal = try XCTUnwrap(try entries("decals")["decal-1"])
        let placement = try XCTUnwrap(decal["placement"] as? [String: Any])
        XCTAssertEqual((placement["shift"] as? [NSNumber])?.map(\.doubleValue), [moved.x, moved.y], "written where it went")
        XCTAssertEqual(placement["angle"] as? Int, 900, "its angle as the file had it")
        XCTAssertEqual(placement["mirror"] as? Bool, false)
        XCTAssertEqual(decal["scale"] as? Double, 2.0, "and its scale")
        XCTAssertEqual(decal["decal"] as? String, decalID)
    }

    func testADeletedDecalLeavesTheFile() async throws {
        let state = State(try fixture())
        let (window, _) = try await mount(state)
        defer { window.close() }

        await selectAll(state, including: [.boardDecal])
        let after = try await commit(state, .deleteSelection)
        XCTAssertTrue(after.decals.isEmpty)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertNil(try entries("decals")["decal-1"], "the decal is gone from the file")
    }

    func testADuplicatedHoleIsWritten() async throws {
        let state = State(try fixture())
        let (window, _) = try await mount(state)
        defer { window.close() }

        await selectAll(state, including: [.boardHole])
        let after = try await commit(state, .duplicateSelection)
        XCTAssertEqual(after.holes.count, 2)
        let copy = try XCTUnwrap(after.holes.first { $0.id != "hole-1" })

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        let holes = try entries("holes")
        XCTAssertEqual(holes.count, 2, "the copy is written beside the original")
        let entry = try XCTUnwrap(holes[copy.id])
        XCTAssertEqual(entry["padstack"] as? String, padstackID)
        let placement = try XCTUnwrap(entry["placement"] as? [String: Any])
        XCTAssertEqual((placement["shift"] as? [NSNumber])?.map(\.intValue), [Int(copy.position.x), Int(copy.position.y)])
        XCTAssertNotEqual(copy.position, after.holes.first { $0.id == "hole-1" }?.position)
        XCTAssertEqual(placement["angle"] as? Int, 0)
        XCTAssertEqual(placement["mirror"] as? Bool, false, "a placement as Horizon reads one")
        XCTAssertEqual((entry["parameter_set"] as? [String: Any])?["hole_diameter"] as? Int, 3 * mm)
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(Set(reloaded.holes.map(\.id)), Set(["hole-1", copy.id]), "and both load")
    }
}
#endif
