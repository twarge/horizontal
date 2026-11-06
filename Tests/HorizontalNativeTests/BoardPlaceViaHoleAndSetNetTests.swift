#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Horizon's Place via, Place hole and Set via net on the board canvas.
///
/// Place Via… asks for a net and then puts down a via on it each click,
/// shaped by the via rule that takes the net and pinned on it, as Horizon's
/// tool does. Place Board Hole… asks for a hole padstack from the pools and
/// puts down a board hole on it each click, its padstack cached into the
/// project pool when it came from another. Set Net… gives the selected
/// netless copper a net, pinned on its vias. Each is written as Horizon
/// writes it and reads back.
@MainActor
final class BoardPlaceViaHoleAndSetNetTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        let poolURL: URL
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard, poolURL: URL) {
            source = board
            self.poolURL = poolURL
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
                toolSettings: state.toolSettings,
                poolURL: state.poolURL)
        }
    }

    private let mm = 1_000_000
    /// Not horizon-pool's own Circular Hole's uuid, so a pool registered on
    /// the machine running the tests can't stand in for the fixture's.
    private let holePadstackID = "7a3e9c41-2b6d-4f80-9e15-c4d2a8b7f603"
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!
    private var projectPoolURL: URL!
    private var holePadstackData = Data()

    /// horizon-pool's Circular Hole: a plated round hole whose diameter and
    /// annular ring are parameters it requires.
    private func holePadstackJSON() -> [String: Any] {
        [
            "type": "padstack",
            "padstack_type": "hole",
            "uuid": holePadstackID,
            "name": "Test Circular Hole",
            "holes": [
                "h": ["diameter": 400_000, "length": 500_000, "parameter_class": "hole", "plated": true, "shape": "round",
                      "placement": ["angle": 0, "mirror": false, "shift": [0, 0]]],
            ],
            "parameter_set": ["hole_annular_ring": 200_000, "hole_diameter": 400_000, "hole_solder_mask_expansion": 100_000],
            "parameters_required": ["hole_diameter", "hole_annular_ring"],
            "parameter_program": "get-parameter [ hole_diameter ]\ndup dup\nset-hole [ hole round ]\n",
            "polygons": [String: Any](),
            "shapes": [String: Any](),
        ]
    }

    /// The template project — GND, and the via rule Horizon gives a new
    /// board — with `edit` made to its board file, and beside it a pool
    /// named horizon-pool holding the hole padstack, which the project draws
    /// from as from a checkout of horizon-pool beside the projects.
    ///
    /// The template's GND via, and its junction, go first: it stands in the
    /// board's middle, which is where a placement starts when the pointer
    /// hasn't moved, and it is copper Set Net… could take.
    private func fixture(_ edit: (inout [String: Any]) throws -> Void = { _ in }) throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-place-via-hole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let boardURL = url.appendingPathComponent("board.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        let starterVias = (json["vias"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        var junctions = json["junctions"] as? [String: Any] ?? [:]
        for case let junction as String in starterVias.map({ $0["junction"] }) {
            junctions.removeValue(forKey: junction)
        }
        json["junctions"] = junctions
        json["vias"] = [String: Any]()
        try edit(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: boardURL)
        project = try HorizontalProject.load(from: url)
        projectPoolURL = project.baseURL.appendingPathComponent(project.poolDirectory ?? "pool", isDirectory: true)

        let basePool = root.appendingPathComponent("horizon-pool", isDirectory: true)
        let padstacks = basePool.appendingPathComponent("padstacks", isDirectory: true)
        try FileManager.default.createDirectory(at: padstacks, withIntermediateDirectories: true)
        let poolJSON: [String: Any] = ["type": "pool", "uuid": "1e2d3c4b-5a69-4788-9a0b-c1d2e3f4a5b6", "name": "Test Pool",
                                       "default_via": HorizontalProjectArchive.nullUUID, "pools_included": [String]()]
        try JSONSerialization.data(withJSONObject: poolJSON).write(to: basePool.appendingPathComponent("pool.json"))
        holePadstackData = try JSONSerialization.data(withJSONObject: holePadstackJSON(), options: [.sortedKeys])
        try holePadstackData.write(to: padstacks.appendingPathComponent("hole-round.json"))
        archive = try HorizontalProjectArchive.completeProject(from: url)
        return try XCTUnwrap(project.board)
    }

    private var gndNetID: String {
        get throws {
            try XCTUnwrap(project.board?.netDetails.values.first { $0.name == "GND" }?.id).lowercased()
        }
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

    private func commit(_ state: State, _ command: HorizontalCanvasCommand) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(command)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
        return try XCTUnwrap(state.committed.last)
    }

    private func boardEntries(_ key: String) throws -> [String: [String: Any]] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json[key] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    // MARK: - Place Via

    func testPlaceViaAsksForANetAndPutsDownTheRulesViaPinnedOnItEachClick() async throws {
        let board = try fixture()
        let gnd = try gndNetID
        let rule = try XCTUnwrap(board.routeVia(netID: gnd), "the template's via rule takes every net")
        let state = State(board, poolURL: projectPoolURL)
        let (window, _) = try await mount(state)
        defer { window.close() }

        XCTAssertEqual(state.actions?.canPlaceVia, true)
        state.actions?.dispatch(.placeVia)
        let asked = await settle { state.actions?.netChoices != nil }
        XCTAssertTrue(asked, "the net chooser comes up first, as Horizon's tool asks")
        XCTAssertEqual(state.actions?.netChoices?.map(\.title), ["GND"])
        state.actions?.chooseNet?(gnd)
        let placing = await settle { state.actions?.canCommitInteraction == true && state.actions?.netChoices == nil }
        XCTAssertTrue(placing, "the chooser goes and the via follows the cursor")
        XCTAssertEqual(state.actions?.canPlaceVia, false, "one tool at a time")

        let after = try await commit(state, .commitInteraction)
        XCTAssertEqual(state.actions?.canCommitInteraction, true, "the tool stays for the next via, as Horizon's does")
        XCTAssertEqual(after.vias.count, 1)
        let via = try XCTUnwrap(after.vias.first)
        XCTAssertEqual(via.netSetID, gnd, "pinned on the net chosen")
        XCTAssertEqual(via.netID, gnd)
        XCTAssertEqual(via.padstackID, rule.padstackID)
        XCTAssertEqual(via.size, rule.diameter)
        XCTAssertEqual(via.holeSize, rule.holeDiameter)
        XCTAssertTrue(via.fromRules, "and goes on taking its shape from the rules")
        XCTAssertEqual(after.viaHoles.map(\.id), ["\(via.id)/hole"])
        XCTAssertTrue(after.junctions.values.contains(via.position), "it stands on a junction, as Horizon's via does")

        let second = try await commit(state, .commitInteraction)
        XCTAssertEqual(second.vias.count, 2, "a click is a via")
        state.actions?.dispatch(.cancelInteraction)
        let ended = await settle { state.actions?.canCommitInteraction == false }
        XCTAssertTrue(ended, "Esc ends the tool")
        XCTAssertEqual(state.committed.count, 2, "and puts nothing down")

        try HorizontalProjectJSONApplicator.apply(board: second, in: project, to: &archive)
        let entry = try XCTUnwrap(try boardEntries("vias")[via.id], "written under its id")
        XCTAssertEqual(entry["net_set"] as? String, gnd)
        XCTAssertEqual((entry["padstack"] as? String)?.lowercased(), rule.padstackID.lowercased())
        XCTAssertEqual(entry["from_rules"] as? Bool, true)
        let junction = try XCTUnwrap(entry["junction"] as? String)
        XCTAssertNotNil(try boardEntries("junctions")[junction], "on a junction the file has")

        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        let read = try XCTUnwrap(reloaded.vias.first { $0.id == via.id })
        XCTAssertEqual(read.netSetID, gnd)
        XCTAssertEqual(read.position, via.position)
    }

    // MARK: - Place Board Hole

    func testPlaceBoardHoleTakesAHolePadstackFromThePoolsTurnsWithRAndIsWrittenCachedAndReadBack() async throws {
        let state = State(try fixture(), poolURL: projectPoolURL)
        let (window, key) = try await mount(state)
        defer { window.close() }

        XCTAssertEqual(state.actions?.canPlaceBoardHole, true)
        state.actions?.dispatch(.placeBoardHole)
        let listed = await settle { state.actions?.holePadstackChoices?.contains { $0.id == self.holePadstackID } == true }
        XCTAssertTrue(listed, "the chooser lists the pool's hole padstack: \(state.actions?.holePadstackChoices?.map(\.name) ?? [])")
        XCTAssertTrue(state.actions?.holePadstackChoices?.allSatisfy { ["hole", "mechanical"].contains($0.type) } == true,
                      "and only hole and mechanical padstacks, as Horizon's chooser")
        state.actions?.chooseHolePadstack?(holePadstackID)
        let placing = await settle { state.actions?.canCommitInteraction == true && state.actions?.holePadstackChoices == nil }
        XCTAssertTrue(placing, "the chooser goes and the hole follows the cursor")

        try key(15, "r")
        let after = try await commit(state, .commitInteraction)
        XCTAssertEqual(state.actions?.canCommitInteraction, true, "the tool stays for the next hole")
        XCTAssertEqual(after.holes.count, 1)
        let hole = try XCTUnwrap(after.holes.first)
        XCTAssertEqual(hole.padstackID, holePadstackID)
        XCTAssertEqual(hole.diameter, 400_000, "the padstack's own hole diameter")
        XCTAssertTrue(hole.plated)
        XCTAssertNil(hole.netID)
        XCTAssertEqual(hole.angle, 49_152, "turned a quarter clockwise by R, as R turns what the board places")
        XCTAssertEqual(hole.parameterSet, ["hole_diameter": 400_000, "hole_annular_ring": 200_000],
                       "the parameters it requires, at the padstack's values, as Horizon's tool gives them")
        state.actions?.dispatch(.cancelInteraction)

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        let entry = try XCTUnwrap(try boardEntries("holes")[hole.id], "written under its id")
        XCTAssertEqual(entry["padstack"] as? String, holePadstackID)
        let placement = try XCTUnwrap(entry["placement"] as? [String: Any])
        XCTAssertEqual((placement["shift"] as? [NSNumber])?.map(\.doubleValue), [hole.position.x, hole.position.y])
        XCTAssertEqual(placement["angle"] as? Int, 49_152)
        XCTAssertEqual(placement["mirror"] as? Bool, false)
        let parameters = try XCTUnwrap(entry["parameter_set"] as? [String: Any])
        XCTAssertEqual((parameters["hole_diameter"] as? NSNumber)?.intValue, 400_000)
        XCTAssertEqual((parameters["hole_annular_ring"] as? NSNumber)?.intValue, 200_000)
        XCTAssertNil(entry["net"], "a hole on no net")
        let cachedPath = "\(project.poolDirectory ?? "pool")/\(HorizontalProjectArchive.cachedPadstackPath(holePadstackID))"
        XCTAssertEqual(archive.regularFileData(relativePath: cachedPath), holePadstackData,
                       "the padstack cached into the project pool as the pool has it")

        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        let read = try XCTUnwrap(reloaded.holes.first { $0.id == hole.id }, "it reads back: \(reloaded.holes.map(\.id))")
        XCTAssertEqual(read.position, hole.position)
        XCTAssertEqual(read.diameter, 400_000)
        XCTAssertEqual(read.angle, 49_152)
        XCTAssertEqual(read.padstackID, holePadstackID)
    }

    // MARK: - Set Net

    func testSetNetGivesNetlessCopperTheNetPinnedOnItsViaAndUndoTakesItBack() async throws {
        let mm = self.mm
        let board = try fixture { json in
            var junctions = json["junctions"] as? [String: Any] ?? [:]
            junctions["j1"] = ["position": [10 * mm, 10 * mm]]
            junctions["j2"] = ["position": [15 * mm, 10 * mm]]
            json["junctions"] = junctions
            json["tracks"] = ["t1": ["from": ["junc": "j1"], "to": ["junc": "j2"], "layer": 0, "width": 250_000,
                                     "width_from_net_class": false, "locked": false]]
            json["vias"] = ["v1": ["junction": "j2", "padstack": HorizontalProjectArchive.horizonPoolTentedCircularVia,
                                   "parameter_set": ["via_diameter": 600_000, "hole_diameter": 300_000],
                                   "from_rules": false, "source": "local", "locked": false]]
        }
        let gnd = try gndNetID
        XCTAssertNil(board.tracks.first?.netID, "copper on no net")
        XCTAssertNil(board.vias.first?.netID)
        let state = State(board, poolURL: projectPoolURL)
        let (window, _) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        state.actions?.dispatch(.setNet)
        let asked = await settle { state.actions?.netChoices != nil }
        XCTAssertTrue(asked, "the net chooser comes up for the copper that can take a net")
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        state.actions?.chooseNet?(gnd)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
        let after = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(after.vias.first?.netSetID, gnd, "pinned on the via")
        XCTAssertEqual(after.tracks.first?.netID, gnd, "and the track it ends on has it from there")
        XCTAssertEqual(state.undo.undoActionName, "Set Net")

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertEqual(try boardEntries("vias")["v1"]?["net_set"] as? String, gnd)
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(reloaded.vias.first?.netSetID, gnd)
        XCTAssertEqual(reloaded.tracks.first?.netID, gnd, "the track reads back on the net")

        state.undo.undo()
        let undone = await settle { state.committed.last?.vias.first?.netSetID == nil }
        XCTAssertTrue(undone, "undo takes the net off again")
    }

    func testSetNetOnCopperThatCantTakeOneAsksNothing() async throws {
        let mm = self.mm
        let board = try fixture { json in
            var junctions = json["junctions"] as? [String: Any] ?? [:]
            junctions["j1"] = ["position": [10 * mm, 10 * mm]]
            junctions["j2"] = ["position": [15 * mm, 10 * mm]]
            json["junctions"] = junctions
            json["tracks"] = ["t1": ["from": ["junc": "j1"], "to": ["junc": "j2"], "layer": 0, "width": 250_000,
                                     "width_from_net_class": false, "locked": false]]
        }
        let state = State(board, poolURL: projectPoolURL)
        let (window, _) = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        state.actions?.dispatch(.setNet)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(state.actions?.netChoices, "a track that reaches no via has nothing to hold a net")
        XCTAssertTrue(state.committed.isEmpty)
    }
}
#endif
