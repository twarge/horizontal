#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Delete or Backspace on a via's junction: the junction goes, and the via
/// standing on it with it, as Horizon's delete takes a junction's via, along
/// with the tracks that end there. A via that could not have been selected
/// itself stays and keeps its junction: a locked one, and one the selection
/// filter keeps out. The junction used to stay under its via whatever the
/// via, so the key did nothing to a bare via's junction, and took only the
/// tracks off one on a run.
@MainActor
final class BoardViaJunctionDeleteTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        /// The selection filter: junctions alone to begin with, so Select
        /// All selects them and leaves the vias and tracks unselected.
        @Published var selection: HorizontalSelectionToolSettings = {
            var selection = HorizontalSelectionToolSettings()
            selection.boardFilter.only(.junctions)
            return selection
        }()
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
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(),
                undoManager: state.undo, selectionToolSettings: state.selection,
                onBoardChange: { state.committed.append($0); board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    /// The template project with nothing on its board but these junctions,
    /// tracks and vias, written as Horizon writes them.
    private func fixture(junctions: [String: [Int]], tracks: [String: [String]] = [:],
                         vias: [String: (junction: String, locked: Bool)]) throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-via-junction-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let boardURL = url.appendingPathComponent("board.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        json["planes"] = [String: Any]()
        json["polygons"] = [String: Any]()
        json["junctions"] = junctions.mapValues { ["position": [$0[0] * mm, $0[1] * mm]] }
        json["tracks"] = tracks.mapValues { ends -> [String: Any] in
            ["from": ["junc": ends[0]], "to": ["junc": ends[1]], "layer": 0, "width": 250_000, "width_from_net_class": false]
        }
        json["vias"] = vias.mapValues { via -> [String: Any] in
            ["junction": via.junction, "padstack": HorizontalProjectArchive.horizonPoolTentedCircularVia,
             "parameter_set": ["via_diameter": 600_000, "hole_diameter": 300_000],
             "from_rules": false, "source": "local", "locked": via.locked]
        }
        try JSONSerialization.data(withJSONObject: json).write(to: boardURL)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        return try XCTUnwrap(project.board)
    }

    private func writtenKeys(_ key: String) throws -> Set<String> {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set((json[key] as? [String: Any] ?? [:]).keys.map { $0.lowercased() })
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// The canvas in a window, and a way to press a key in it.
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
            XCTAssertNil(handle(event), "the canvas takes the key")
        }
        return (window, key)
    }

    /// Selects the board's junctions, and nothing else, then lets the
    /// selection filter pick everything again unless `keepingFilter`.
    private func selectJunctions(_ state: State, _ ids: Set<String>, keepingFilter: Bool = false) async {
        state.actions?.dispatch(.selectAll)
        let selected = await settle {
            state.details.groups.map(\.type) == [.junction]
                && Set(state.details.groups.flatMap(\.items).map { $0.ref.id.lowercased() }) == ids
        }
        XCTAssertTrue(selected, "selected \(state.details.groups.map { ($0.type, $0.items.map(\.ref.id)) })")
        if !keepingFilter {
            state.selection = HorizontalSelectionToolSettings()
            // The canvas takes the new filter with its next pass.
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func press(_ state: State, _ key: (UInt16, String) throws -> Void, code: UInt16, _ characters: String) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        try key(code, characters)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed, "the key deletes something")
        return try XCTUnwrap(state.committed.last)
    }

    func testBackspaceOnABareViasJunctionDeletesTheJunctionAndItsViaFromTheFile() async throws {
        let state = State(try fixture(junctions: ["bare": [5, 5]], vias: ["v-bare": ("bare", false)]))
        XCTAssertEqual(state.source.vias.map(\.id), ["v-bare"])
        let (window, key) = try await mount(state)
        defer { window.close() }

        await selectJunctions(state, ["bare"])
        let after = try await press(state, key, code: 51, "\u{7f}")
        XCTAssertTrue(after.junctions.isEmpty, "the junction is gone")
        XCTAssertTrue(after.vias.isEmpty, "and the via that stood on it")
        XCTAssertTrue(after.viaHoles.isEmpty)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertTrue(try writtenKeys("vias").isEmpty, "the via leaves the file")
        XCTAssertTrue(try writtenKeys("junctions").isEmpty, "and so does its junction")
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertTrue(reloaded.vias.isEmpty && reloaded.junctions.isEmpty, "and neither comes back")

        // One undo step puts both back.
        state.undo.undo()
        let undone = await settle { state.committed.last?.vias.map(\.id) == ["v-bare"] }
        XCTAssertTrue(undone)
        XCTAssertEqual(state.committed.last?.junctions.keys.map { $0.lowercased() }, ["bare"])
    }

    func testDeleteOnJunctionsTakesAViaOnARunWithItsTracksAndLeavesALockedViaOnItsJunction() async throws {
        let state = State(try fixture(
            junctions: ["j1": [10, 10], "j2": [15, 10], "j3": [20, 10], "held": [30, 10]],
            tracks: ["t1": ["j1", "j2"], "t2": ["j2", "j3"]],
            vias: ["v-run": ("j2", false), "v-held": ("held", true)]))
        let (window, key) = try await mount(state)
        defer { window.close() }

        await selectJunctions(state, ["j1", "j2", "j3", "held"])
        let after = try await press(state, key, code: 117, "\u{f728}")
        XCTAssertTrue(after.tracks.isEmpty, "the tracks that ended on them")
        XCTAssertEqual(after.vias.map(\.id), ["v-held"], "the via on the run goes with its junction; the locked one stays")
        XCTAssertEqual(after.junctions.keys.map { $0.lowercased() }, ["held"], "and keeps its junction")
    }

    func testAViaTheSelectionFilterKeepsOutStaysOnItsJunction() async throws {
        let state = State(try fixture(
            junctions: ["j1": [10, 10], "j2": [15, 10], "j3": [20, 10]],
            tracks: ["t1": ["j1", "j2"], "t2": ["j2", "j3"]],
            vias: ["v-run": ("j2", false)]))
        let (window, key) = try await mount(state)
        defer { window.close() }

        await selectJunctions(state, ["j1", "j2", "j3"], keepingFilter: true)
        let after = try await press(state, key, code: 51, "\u{7f}")
        XCTAssertTrue(after.tracks.isEmpty, "the tracks went with the junctions they ended on")
        XCTAssertEqual(after.vias.map(\.id), ["v-run"], "a via no pick could take is not deleted")
        XCTAssertEqual(after.junctions.keys.map { $0.lowercased() }, ["j2"], "and keeps its junction")
    }
}
#endif
