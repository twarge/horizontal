#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Place Decal…, Horizon's place-decal tool: a decal chosen from the pools a
/// project draws from follows the cursor, R turns it a quarter turn
/// clockwise, E flips it to the other side, and a click puts it down. It is
/// written to the board file as Horizon's BoardDecal::serialize writes one,
/// its pool item cached into the project pool, which is where the loader
/// draws a decal from, and it reads back as it was placed.
@MainActor
final class BoardPlaceDecalTests: XCTestCase {
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
        /// The Pools pane's Place on a decal, as a project window passes it.
        @Published var placeDecalRequest: HorizontalBoardDecalPlacementRequest?
        /// Whether the board's pane has the keyboard, as the window tracks it.
        @Published var hasKeyboard = true
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
                hasKeyboardFocus: state.hasKeyboard,
                onRequestKeyboardFocus: { state.hasKeyboard = true },
                placeDecalRequest: state.placeDecalRequest,
                toolSettings: state.toolSettings,
                poolURL: state.poolURL)
        }
    }

    private let mm = 1_000_000.0
    private let decalID = "5e0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!
    private var projectPoolURL: URL!
    private var decalData = Data()

    /// The decal: an L of top silkscreen, a 2 mm line along x from its origin
    /// and a 1 mm one up y, and a square of it a millimetre across.
    private func decalJSON() -> [String: Any] {
        let mm = Int(self.mm)
        return [
            "type": "decal",
            "uuid": decalID,
            "name": "Test Logo",
            "junctions": [
                "a": ["position": [0, 0]],
                "b": ["position": [2 * mm, 0]],
                "c": ["position": [0, mm]],
            ],
            "lines": [
                "x": ["from": "a", "to": "b", "layer": HorizontalBoardLayers.topSilkscreen, "width": 100_000],
                "y": ["from": "a", "to": "c", "layer": HorizontalBoardLayers.topSilkscreen, "width": 100_000],
            ],
            "polygons": [
                "p": ["layer": HorizontalBoardLayers.topSilkscreen, "vertices": [
                    ["type": "line", "position": [mm, mm]],
                    ["type": "line", "position": [2 * mm, mm]],
                    ["type": "line", "position": [2 * mm, 2 * mm]],
                    ["type": "line", "position": [mm, 2 * mm]],
                ]],
            ],
            "arcs": [String: Any](),
            "texts": [String: Any](),
        ]
    }

    /// The template project, and beside it a pool named horizon-pool holding
    /// the decal, which the project draws from as from a checkout of
    /// horizon-pool beside the projects. With `inProjectPool`, the project's
    /// own pool has the decal instead.
    private func fixture(inProjectPool: Bool = false) throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-place-decal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        project = try HorizontalProject.load(from: url)
        projectPoolURL = project.baseURL.appendingPathComponent(project.poolDirectory ?? "pool", isDirectory: true)

        decalData = try JSONSerialization.data(withJSONObject: decalJSON(), options: [.sortedKeys])
        let decals: URL
        if inProjectPool {
            decals = projectPoolURL.appendingPathComponent("decals", isDirectory: true)
        } else {
            let basePool = root.appendingPathComponent("horizon-pool", isDirectory: true)
            try FileManager.default.createDirectory(at: basePool, withIntermediateDirectories: true)
            let poolJSON: [String: Any] = ["type": "pool", "uuid": "0d7c6b5a-4f3e-4d2c-9b1a-8f7e6d5c4b3a", "name": "Test Pool",
                                           "default_via": HorizontalProjectArchive.nullUUID, "pools_included": [String]()]
            try JSONSerialization.data(withJSONObject: poolJSON).write(to: basePool.appendingPathComponent("pool.json"))
            decals = basePool.appendingPathComponent("decals", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: decals, withIntermediateDirectories: true)
        try decalData.write(to: decals.appendingPathComponent("test-logo.json"))
        archive = try HorizontalProjectArchive.completeProject(from: url)
        return try XCTUnwrap(project.board)
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

    /// Place Decal… from the menu, and the test decal chosen in its chooser.
    private func chooseTestDecal(_ state: State) async throws {
        XCTAssertEqual(state.actions?.canPlaceDecal, true)
        state.actions?.dispatch(.placeDecal)
        let listed = await settle { state.actions?.decalChoices?.contains { $0.uuid == self.decalID } == true }
        XCTAssertTrue(listed, "the chooser lists the pool's decal: \(state.actions?.decalChoices?.map(\.name) ?? [])")
        let item = try XCTUnwrap(state.actions?.decalChoices?.first { $0.uuid == decalID })
        state.actions?.chooseDecal?(item)
        let placing = await settle { state.actions?.canCommitInteraction == true && state.actions?.decalChoices == nil }
        XCTAssertTrue(placing, "the chooser goes and the decal follows the cursor")
        XCTAssertEqual(state.actions?.canPlaceDecal, false, "one tool at a time")
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

    private func line(_ name: String, of decal: HorizontalBoardDecal) throws -> HorizontalSegment {
        try XCTUnwrap(decal.lines.first { $0.id.hasSuffix("/line/\(name)") }, "line \(name) of \(decal.lines.map(\.id))")
    }

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func decalEntries() throws -> [String: [String: Any]] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json["decals"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    private var cachedDecalPath: String {
        "\(project.poolDirectory ?? "pool")/decals/cache/\(decalID).json"
    }

    /// Geometry read back from the file matches what the canvas put down:
    /// every line's ends and layer, and every polygon's corners and layer.
    private func assertSameGeometry(_ reloaded: HorizontalBoardDecal, _ placed: HorizontalBoardDecal,
                                    file: StaticString = #filePath, line: UInt = #line) {
        func lines(_ decal: HorizontalBoardDecal) -> [String] {
            decal.lines.map { "\($0.id) \($0.from.x),\($0.from.y) \($0.to.x),\($0.to.y) \($0.layer ?? 0) \($0.width)" }.sorted()
        }
        func polygons(_ decal: HorizontalBoardDecal) -> [String] {
            decal.polygons.map { "\($0.id) \($0.vertices.map { "\($0.x),\($0.y)" }) \($0.layer ?? 0)" }.sorted()
        }
        XCTAssertEqual(lines(reloaded), lines(placed), file: file, line: line)
        XCTAssertEqual(polygons(reloaded), polygons(placed), file: file, line: line)
    }

    func testAChosenDecalTurnsWithRAndIsWrittenCachedAndReadBackAsPlaced() async throws {
        let state = State(try fixture(), poolURL: projectPoolURL)
        let (window, key) = try await mount(state)
        defer { window.close() }

        try await chooseTestDecal(state)
        try key(15, "r")
        let after = try await commit(state, .commitInteraction)
        XCTAssertEqual(state.actions?.canCommitInteraction, false, "the tool ends with the one decal, as Horizon's does")

        XCTAssertEqual(after.decals.count, 1)
        let placed = try XCTUnwrap(after.decals.first)
        let origin = try XCTUnwrap(placed.position)
        XCTAssertEqual(placed.decalID, decalID)
        XCTAssertEqual(placed.name, "Test Logo")
        XCTAssertEqual(placed.angle, 49_152, "a quarter turn clockwise, Horizon's inc_angle_deg(-90)")
        XCTAssertFalse(placed.flip)
        XCTAssertEqual(placed.cacheSource?.uuid, decalID, "taken from a pool the project pool lacks")
        // The L turned clockwise: x now runs down from where it went, y right.
        let x = try line("x", of: placed)
        XCTAssertEqual(x.from, origin)
        XCTAssertEqual(x.to, origin + point(0, -2))
        XCTAssertEqual(x.layer, HorizontalBoardLayers.topSilkscreen)
        XCTAssertEqual(try line("y", of: placed).to, origin + point(1, 0))

        let changed = try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertTrue(changed)
        let entry = try XCTUnwrap(try decalEntries()[placed.id], "written under its id")
        XCTAssertEqual(entry["decal"] as? String, decalID)
        let placement = try XCTUnwrap(entry["placement"] as? [String: Any])
        XCTAssertEqual((placement["shift"] as? [NSNumber])?.map(\.doubleValue), [origin.x, origin.y])
        XCTAssertEqual(placement["angle"] as? Int, 49_152)
        XCTAssertEqual(placement["mirror"] as? Bool, false)
        XCTAssertEqual(entry["flip"] as? Bool, false)
        XCTAssertEqual((entry["scale"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(archive.regularFileData(relativePath: cachedDecalPath), decalData,
                       "the decal cached into the project pool as the pool has it")
        XCTAssertFalse(try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive),
                       "and cached once: the next save writes nothing")

        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(reloaded.decals.map(\.id), [placed.id], "it reads back")
        let read = try XCTUnwrap(reloaded.decals.first)
        XCTAssertEqual(read.position, origin)
        XCTAssertEqual(read.angle, 49_152)
        XCTAssertNil(read.cacheSource, "read from the project pool")
        assertSameGeometry(read, placed)
    }

    func testEFlipsTheDecalToTheBottomAndEscPutsNothingDown() async throws {
        let state = State(try fixture(), poolURL: projectPoolURL)
        let (window, key) = try await mount(state)
        defer { window.close() }

        try await chooseTestDecal(state)
        try key(14, "e")
        let after = try await commit(state, .commitInteraction)
        let placed = try XCTUnwrap(after.decals.first)
        let origin = try XCTUnwrap(placed.position)
        XCTAssertTrue(placed.flip)
        XCTAssertEqual(placed.angle, 0)
        // Seen from the top, x runs the other way, on the bottom silkscreen.
        let x = try line("x", of: placed)
        XCTAssertEqual(x.to, origin + point(-2, 0))
        XCTAssertEqual(x.layer, HorizontalBoardLayers.bottomSilkscreen)
        XCTAssertEqual(try line("y", of: placed).to, origin + point(0, 1))

        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        let entry = try XCTUnwrap(try decalEntries()[placed.id])
        XCTAssertEqual(entry["flip"] as? Bool, true)
        XCTAssertEqual((entry["placement"] as? [String: Any])?["mirror"] as? Bool, true, "the flip is the placement's mirror")
        let read = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board?.decals.first)
        assertSameGeometry(read, placed)

        // A second one taken up and let go puts nothing down.
        try await chooseTestDecal(state)
        let commits = state.committed.count
        state.actions?.dispatch(.cancelInteraction)
        let cancelled = await settle { state.actions?.canCommitInteraction == false }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(state.committed.count, commits)
        XCTAssertEqual(state.actions?.canPlaceDecal, true, "and the tool can be taken up again")
    }

    func testADecalTurnedFlippedAndScaledReadsBackAsPlaced() throws {
        _ = try fixture()
        var board = try XCTUnwrap(project.board)
        let item = try XCTUnwrap(HorizontalBoardDecalPlacement.choices(projectPoolURL: projectPoolURL)
            .items(in: .decal).first { $0.uuid == decalID })
        var placement = try XCTUnwrap(HorizontalBoardDecalPlacement(item: item))
        placement.rotate()
        placement.toggleFlip()
        placement.scale = 2.5
        XCTAssertEqual(placement.angle, 16_384, "the flip inverts the angle, as Horizon's MIRROR does")
        let at = point(10, 20)
        let placed = try XCTUnwrap(placement.decal(id: "d1", at: at, nInnerLayers: 0, projectPoolURL: projectPoolURL))
        XCTAssertEqual(try line("x", of: placed).to, at + point(0, 5), "2 mm at 2.5 times, turned and seen from below")
        XCTAssertEqual(try line("x", of: placed).width, 250_000, "its width scaled too")
        board.decals.append(placed)

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let entry = try XCTUnwrap(try decalEntries()["d1"])
        XCTAssertEqual((entry["scale"] as? NSNumber)?.doubleValue, 2.5)
        XCTAssertEqual((entry["placement"] as? [String: Any])?["angle"] as? Int, 16_384)
        let read = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board?.decals.first)
        XCTAssertEqual(read.scale, 2.5)
        XCTAssertTrue(read.flip)
        assertSameGeometry(read, placed)
    }

    func testADecalTheProjectPoolHasIsNotCachedAgain() throws {
        var board = try fixture(inProjectPool: true)
        let item = try XCTUnwrap(HorizontalBoardDecalPlacement.choices(projectPoolURL: projectPoolURL)
            .items(in: .decal).first { $0.uuid == decalID })
        let placement = try XCTUnwrap(HorizontalBoardDecalPlacement(item: item))
        let placed = try XCTUnwrap(placement.decal(id: "d1", at: point(5, 5), nInnerLayers: 0, projectPoolURL: projectPoolURL))
        XCTAssertNil(placed.cacheSource, "the project pool's own")
        board.decals.append(placed)

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertNil(archive.regularFileData(relativePath: cachedDecalPath), "nothing cached beside it")
        let read = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board?.decals.first)
        assertSameGeometry(read, placed)
    }

    /// The Pools pane's Place on a decal, Return in its list or a
    /// double-click: the board takes it up as the chooser hands one over,
    /// takes the keyboard from the pane so R, E, S and Esc reach the tool,
    /// and Return puts the decal down.
    func testTheRequestFromThePoolsPaneArmsThePlacementAndReturnPutsTheDecalDown() async throws {
        let state = State(try fixture(), poolURL: projectPoolURL)
        state.hasKeyboard = false
        let (window, key) = try await mount(state)
        defer { window.close() }
        let item = try XCTUnwrap(HorizontalBoardDecalPlacement.choices(projectPoolURL: projectPoolURL)
            .items(in: .decal).first { $0.uuid == decalID })

        state.placeDecalRequest = HorizontalBoardDecalPlacementRequest(item: item)
        let placing = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(placing, "the decal follows the cursor")
        XCTAssertEqual(state.actions?.canPlaceDecal, false, "one tool at a time")
        let tookKeyboard = await settle { state.hasKeyboard }
        XCTAssertTrue(tookKeyboard, "the board asks for the keyboard the Pools pane had")

        try key(15, "r")
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        try key(36, "\r")
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed, "Return puts it down")
        XCTAssertEqual(state.actions?.canCommitInteraction, false, "and the tool ends with the one decal")
        let placed = try XCTUnwrap(state.committed.last?.decals.first)
        XCTAssertEqual(placed.decalID, decalID)
        XCTAssertEqual(placed.angle, 49_152, "turned by R on the way")
        XCTAssertEqual(placed.cacheSource?.uuid, decalID, "cached from the pool the pane showed it in")
    }

    /// A request the board can't take now, with another tool under way,
    /// is dropped rather than starting once that tool is done.
    func testARequestWhileAnotherToolIsInUseIsDropped() async throws {
        let state = State(try fixture(), poolURL: projectPoolURL)
        let (window, _) = try await mount(state)
        defer { window.close() }
        let item = try XCTUnwrap(HorizontalBoardDecalPlacement.choices(projectPoolURL: projectPoolURL)
            .items(in: .decal).first { $0.uuid == decalID })
        state.actions?.dispatch(.drawDimension)
        let drawing = await settle { state.actions?.canCancelInteraction == true }
        XCTAssertTrue(drawing)

        state.placeDecalRequest = HorizontalBoardDecalPlacementRequest(item: item)
        try await Task.sleep(for: .milliseconds(100))
        state.actions?.dispatch(.cancelInteraction)
        let idle = await settle { state.actions?.canPlaceDecal == true }
        XCTAssertTrue(idle, "the dimension tool let go, and nothing else taken up")
        XCTAssertEqual(state.actions?.canCommitInteraction, false)
    }

    func testPlaceDecalIsOffWhileAnotherToolIsInUse() async throws {
        let state = State(try fixture(), poolURL: projectPoolURL)
        let (window, _) = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(state.actions?.canPlaceDecal, true)
        state.actions?.dispatch(.drawDimension)
        let drawing = await settle { state.actions?.canCancelInteraction == true }
        XCTAssertTrue(drawing)
        XCTAssertEqual(state.actions?.canPlaceDecal, false, "not while another tool is in use")
    }
}
#endif
