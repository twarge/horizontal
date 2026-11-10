#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Lock, Unlock and Unlock All on the board canvas, from the commands the
/// menus send and the inspector's rows: each one undoable edit, and locked
/// copper left where it is by a move or a delete, as a fixed package is.
@MainActor
final class BoardCopperLockCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
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
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000
    private var project: HorizontalProject!

    /// The template project with nothing on its board but a run of two
    /// tracks, j1–j2–j3 on the top, and a via on j2, so Select All selects
    /// only copper and its junctions.
    private func fixture() throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-copper-lock-canvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let boardURL = url.appendingPathComponent("board.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        json["planes"] = [String: Any]()
        json["polygons"] = [String: Any]()
        json["junctions"] = [
            "j1": ["position": [10 * mm, 10 * mm]],
            "j2": ["position": [15 * mm, 10 * mm]],
            "j3": ["position": [20 * mm, 10 * mm]],
        ]
        json["tracks"] = [
            "t1": ["from": ["junc": "j1"], "to": ["junc": "j2"], "layer": 0, "width": 250_000, "width_from_net_class": false],
            "t2": ["from": ["junc": "j2"], "to": ["junc": "j3"], "layer": 0, "width": 250_000, "width_from_net_class": false],
        ]
        json["vias"] = ["v1": ["junction": "j2", "padstack": HorizontalProjectArchive.horizonPoolTentedCircularVia,
                               "parameter_set": ["via_diameter": 600_000, "hole_diameter": 300_000],
                               "from_rules": false, "source": "local"]]
        try JSONSerialization.data(withJSONObject: json).write(to: boardURL)
        project = try HorizontalProject.load(from: url)
        return try XCTUnwrap(project.board)
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
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

    private func commit(_ state: State, _ command: HorizontalCanvasCommand) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(command)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed, "\(command) commits one edit")
        return try XCTUnwrap(state.committed.last)
    }

    private func edit(_ state: State, _ ref: HorizontalSelectableRef, _ propertyID: String,
                      _ value: HorizontalSelectionPropertyValue) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: ref, type: ref.type, propertyID: propertyID, value: value, applyToAll: false))
        let committed = await settle { state.committed.count == commits + 1 }
        state.undo.endUndoGrouping()
        XCTAssertTrue(committed, "\(propertyID) commits one edit")
        return try XCTUnwrap(state.committed.last)
    }

    private func copper(_ board: HorizontalBoard) -> [String] {
        board.tracks.map { "\($0.id) \($0.from.x),\($0.from.y)-\($0.to.x),\($0.to.y)" }.sorted()
            + board.vias.map { "\($0.id) \($0.position.x),\($0.position.y)" }
    }

    func testLockedCopperStaysThroughAMoveAndADeleteAndUnlockAllFreesItAsOneUndoableEdit() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canLockSelection == true }
        XCTAssertTrue(selected, "Lock is there for the selected copper")
        XCTAssertEqual(state.actions?.canUnlockSelection, false, "and nothing is locked to unlock")
        XCTAssertEqual(state.actions?.canUnlockAllCopper, false)

        let locked = try await commit(state, .setCopperLocked(true))
        XCTAssertTrue(locked.tracks.allSatisfy(\.locked))
        XCTAssertTrue(locked.vias.allSatisfy(\.locked))
        XCTAssertEqual(state.undo.undoActionName, "Lock")
        let offered = await settle { state.actions?.canUnlockSelection == true }
        XCTAssertTrue(offered, "Unlock is offered now")
        XCTAssertEqual(state.actions?.canLockSelection, false)
        XCTAssertEqual(state.actions?.canUnlockAllCopper, true)

        let before = copper(locked)
        state.actions?.dispatch(.moveSelectionBy(HorizontalPoint(x: Double(mm), y: 0)))
        XCTAssertEqual(state.actions?.canCommitInteraction, false, "with all of it locked, no move starts")
        state.actions?.dispatch(.commitInteraction)
        state.actions?.dispatch(.deleteSelection)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(copper(state.committed.last ?? locked), before, "neither the move nor the delete touches locked copper")

        let freed = try await commit(state, .unlockAllCopper)
        XCTAssertFalse(BoardCopperLock.hasLocked(freed))
        XCTAssertEqual(copper(freed), before)
        XCTAssertEqual(state.undo.undoActionName, "Unlock All")

        state.undo.undo()
        let relocked = await settle { state.committed.last.map(BoardCopperLock.hasLocked) == true }
        XCTAssertTrue(relocked, "undo locks it again")
        XCTAssertTrue(state.committed.last?.tracks.allSatisfy(\.locked) == true)

        state.actions?.dispatch(.selectAll)
        _ = await settle { state.actions?.canUnlockSelection == true }
        let unlocked = try await commit(state, .setCopperLocked(false))
        XCTAssertFalse(BoardCopperLock.hasLocked(unlocked))
        XCTAssertEqual(state.undo.undoActionName, "Unlock")
        let deleted = try await commit(state, .deleteSelection)
        XCTAssertTrue(deleted.tracks.isEmpty && deleted.vias.isEmpty, "unlocked, the delete takes it")
    }

    func testATrackMovedOffALockedOneKeepsItsEndThereAndTheLockedCopperStays() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }

        let locked = try await edit(state, HorizontalSelectableRef(id: "t2", type: .track), "locked", .bool(true))
        XCTAssertEqual(locked.tracks.filter(\.locked).map(\.id), ["t2"], "the inspector's Locked locks the one track")
        XCTAssertEqual(state.undo.undoActionName, "Edit Properties")

        state.actions?.dispatch(.selectAll)
        _ = await settle { state.actions?.canUnlockSelection == true }
        state.actions?.dispatch(.moveSelectionBy(HorizontalPoint(x: 0, y: Double(mm))))
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving, "what isn't locked moves")
        let moved = try await commit(state, .commitInteraction)
        let t1 = try XCTUnwrap(moved.tracks.first { $0.id == "t1" })
        let t2 = try XCTUnwrap(moved.tracks.first { $0.id == "t2" })
        let j2 = HorizontalPoint(x: Double(15 * mm), y: Double(10 * mm))
        XCTAssertNotEqual(t1.from, HorizontalPoint(x: Double(10 * mm), y: Double(10 * mm)), "the unlocked track's free end moves")
        XCTAssertEqual(t1.to, j2, "its end on the locked track stays, as one on a pad does")
        XCTAssertEqual(t2.from, j2, "the locked track stays")
        XCTAssertEqual(t2.to, HorizontalPoint(x: Double(20 * mm), y: Double(10 * mm)))
        XCTAssertEqual(moved.vias.first?.position, j2, "and the via it ends on")
    }

    func testTheInspectorGivesAStitchingViaANetAsOneUndoableEdit() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }
        let gnd = try XCTUnwrap(project.board?.netDetails.values.first { $0.name == "GND" }?.id).lowercased()

        let after = try await edit(state, HorizontalSelectableRef(id: "v1", type: .via), "viaNet", .choice(gnd))
        XCTAssertEqual(after.vias.first?.netSetID, gnd, "pinned on the via, as Set Net… pins it")
        XCTAssertTrue(after.tracks.allSatisfy { $0.netID == gnd }, "and the tracks on it take it")
        XCTAssertEqual(state.undo.undoActionName, "Edit Properties")

        state.undo.undo()
        let undone = await settle { state.committed.last?.vias.first?.netSetID == nil }
        XCTAssertTrue(undone, "undo takes it off again")
    }
}
#endif
