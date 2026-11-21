#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A board decal in the sidebar inspector, as Horizon's property panel has
/// one: Position X and Y, Angle, Flipped and Scale. A move shifts it; the
/// rest draw it again from its pool item as the loader will from the file,
/// which is written with them and reads back as the board had it. A decal
/// nobody changed keeps its entry as the file wrote it.
@MainActor
final class BoardDecalInspectorTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var source: HorizontalBoard
        let poolURL: URL
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        var details: HorizontalSelectionDetailState = .empty
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
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings,
                poolURL: state.poolURL)
        }
    }

    private let mm = 1_000_000.0
    private let quarterTurn = 16_384
    private let decalID = "5e0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!
    private var projectPoolURL: URL!
    private var basePoolDecalURL: URL?

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

    /// The template project with the decal in its own pool; with
    /// `inProjectPool` false, in a pool named horizon-pool beside it, which
    /// the project draws from.
    private func fixture(inProjectPool: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-decal-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        project = try HorizontalProject.load(from: url)
        projectPoolURL = project.baseURL.appendingPathComponent(project.poolDirectory ?? "pool", isDirectory: true)

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
            basePoolDecalURL = decals.appendingPathComponent("test-logo.json")
        }
        try FileManager.default.createDirectory(at: decals, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: decalJSON(), options: [.sortedKeys])
            .write(to: decals.appendingPathComponent("test-logo.json"))
        archive = try HorizontalProjectArchive.completeProject(from: url)
    }

    /// The decal as Place Decal… puts it down at `at`.
    private func placed(id: String = "d1", at: HorizontalPoint) throws -> HorizontalBoardDecal {
        let item = try XCTUnwrap(HorizontalBoardDecalPlacement.choices(projectPoolURL: projectPoolURL)
            .items(in: .decal).first { $0.uuid == decalID })
        let placement = try XCTUnwrap(HorizontalBoardDecalPlacement(item: item))
        return try XCTUnwrap(placement.decal(id: id, at: at, nInnerLayers: 0, projectPoolURL: projectPoolURL))
    }

    /// The board read from a file that has the decal at 10, 20 as `d1`.
    private func boardWithTheDecalInItsFile() throws -> HorizontalBoard {
        try fixture()
        var board = try XCTUnwrap(project.board)
        board.decals.append(try placed(at: point(10, 20)))
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        return try reloaded()
    }

    /// The board as the file has it now, its URLs the project's again: a
    /// snapshot reads from a temporary copy.
    private func reloaded() throws -> HorizontalBoard {
        var read = try HorizontalProject.loadSnapshot(of: archive)
        read.rebaseURLs(onto: project)
        return try XCTUnwrap(read.board)
    }

    private func boardJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decalEntries() throws -> [String: [String: Any]] {
        (try boardJSON()["decals"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func line(_ name: String, of decal: HorizontalBoardDecal) throws -> HorizontalSegment {
        try XCTUnwrap(decal.lines.first { $0.id.hasSuffix("/line/\(name)") }, "line \(name) of \(decal.lines.map(\.id))")
    }

    private func assertNear(_ a: HorizontalPoint, _ b: HorizontalPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.5, file: file, line: line)
    }

    /// Geometry read back from the file matches what the board had.
    private func assertSameGeometry(_ read: HorizontalBoardDecal, _ had: HorizontalBoardDecal,
                                    file: StaticString = #filePath, line: UInt = #line) {
        func lines(_ decal: HorizontalBoardDecal) -> [String] {
            decal.lines.map { "\($0.id) \($0.from.x),\($0.from.y) \($0.to.x),\($0.to.y) \($0.layer ?? 0) \($0.width)" }.sorted()
        }
        func polygons(_ decal: HorizontalBoardDecal) -> [String] {
            decal.polygons.map { "\($0.id) \($0.vertices.map { "\($0.x),\($0.y)" }) \($0.layer ?? 0)" }.sorted()
        }
        XCTAssertEqual(lines(read), lines(had), file: file, line: line)
        XCTAssertEqual(polygons(read), polygons(had), file: file, line: line)
    }

    private let ref = HorizontalSelectableRef(id: "d1", type: .boardDecal)

    private func set(_ propertyID: String, _ value: HorizontalSelectionPropertyValue, on board: inout HorizontalBoard) -> Bool {
        BoardDecalPlacementEdit.apply(value, propertyID: propertyID, to: ref, board: &board, poolURL: projectPoolURL)
    }

    // MARK: - What the inspector lists

    func testADecalListsItsPositionAngleFlipAndScale() throws {
        try fixture()
        var decal = try placed(at: point(10, 20))
        decal = try XCTUnwrap(decal.redrawn(angle: quarterTurn, flip: true, scale: 2.5, nInnerLayers: 0, projectPoolURL: projectPoolURL))
        let properties = BoardDecalPlacementEdit.properties(of: decal)
        XCTAssertEqual(properties.map(\.id), ["name", "positionX", "positionY", "angle", "flipped", "scale"])
        XCTAssertEqual(properties.map(\.label), ["Name", "Position X", "Position Y", "Angle", "Flipped", "Scale"])
        XCTAssertEqual(properties.map(\.value), [
            .readOnly("Test Logo"), .length(10 * mm), .length(20 * mm), .angle(quarterTurn), .bool(true), .scale(2.5),
        ])
        XCTAssertEqual(properties.map(\.editor), [.readOnly, .length, .length, .angle, .bool, .scale])
    }

    /// A panel's copy of another board's decal is that board's file's.
    func testAPanelsCopyOfADecalHasItsNameAlone() throws {
        try fixture()
        var copy = try placed(at: point(10, 20))
        copy.id = "panel-1/d1"
        XCTAssertEqual(BoardDecalPlacementEdit.properties(of: copy).map(\.id), ["name"])

        var board = try XCTUnwrap(project.board)
        board.decals = [copy]
        let before = board.decals
        XCTAssertTrue(BoardDecalPlacementEdit.apply(.scale(2), propertyID: "scale", to: HorizontalSelectableRef(id: copy.id, type: .boardDecal),
                                                    board: &board, poolURL: projectPoolURL))
        XCTAssertEqual(board.decals, before, "and nothing changes it")
    }

    // MARK: - Each property, on the board and in the file

    func testPositionMovesTheDecalAndIsWritten() throws {
        var board = try boardWithTheDecalInItsFile()
        XCTAssertTrue(set("positionX", .length(15 * mm), on: &board))
        XCTAssertTrue(set("positionY", .length(-5 * mm), on: &board))
        let decal = try XCTUnwrap(board.decals.first)
        XCTAssertEqual(decal.position, point(15, -5))
        XCTAssertEqual(try line("x", of: decal).from, point(15, -5))
        XCTAssertEqual(try line("x", of: decal).to, point(17, -5), "its geometry with it")

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let placement = try XCTUnwrap(try decalEntries()["d1"]?["placement"] as? [String: Any])
        XCTAssertEqual((placement["shift"] as? [NSNumber])?.map(\.doubleValue), [15 * mm, -5 * mm])
        assertSameGeometry(try XCTUnwrap(try reloaded().decals.first), decal)
    }

    func testAngleTurnsTheDecalAboutItsOriginAndIsWritten() throws {
        var board = try boardWithTheDecalInItsFile()
        let origin = point(10, 20)
        XCTAssertTrue(set("angle", .angle(quarterTurn), on: &board))
        let decal = try XCTUnwrap(board.decals.first)
        XCTAssertEqual(decal.angle, quarterTurn)
        XCTAssertEqual(decal.position, origin, "where it was")
        XCTAssertEqual(try line("x", of: decal).to, origin + point(0, 2), "a quarter turn anticlockwise")
        XCTAssertEqual(try line("y", of: decal).to, origin + point(-1, 0))

        // An angle past a full turn is the angle it comes round to.
        XCTAssertTrue(set("angle", .angle(65_536 + 8_192), on: &board))
        XCTAssertEqual(board.decals.first?.angle, 8_192)
        let eighth = try XCTUnwrap(board.decals.first)
        assertNear(try line("x", of: eighth).to, origin + point(2.0.squareRoot(), 2.0.squareRoot()))

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let entry = try XCTUnwrap(try decalEntries()["d1"])
        XCTAssertEqual((entry["placement"] as? [String: Any])?["angle"] as? Int, 8_192)
        XCTAssertEqual(entry["flip"] as? Bool, false, "the rest as it was")
        XCTAssertEqual((entry["scale"] as? NSNumber)?.doubleValue, 1)
        let read = try XCTUnwrap(try reloaded().decals.first)
        XCTAssertEqual(read.angle, 8_192)
        assertSameGeometry(read, eighth)
    }

    /// Horizon's set_flip: the other side of the board, the file's angle
    /// kept, which Horizon inverts before it draws a flipped decal
    /// (`Canvas::render(const BoardDecal &)`): turned the other way, then
    /// mirrored.
    func testFlippedPutsTheDecalOnTheOtherSideAndIsWritten() throws {
        var board = try boardWithTheDecalInItsFile()
        let origin = point(10, 20)
        XCTAssertTrue(set("angle", .angle(quarterTurn), on: &board))
        XCTAssertTrue(set("flipped", .bool(true), on: &board))
        let decal = try XCTUnwrap(board.decals.first)
        XCTAssertTrue(decal.flip)
        XCTAssertEqual(decal.angle, quarterTurn, "the angle the file has")
        // The quarter turn is now clockwise, so the line that ran up y runs
        // down it; the mirror then leaves the one along -x where it is.
        XCTAssertEqual(try line("x", of: decal).to, origin + point(0, -2))
        XCTAssertEqual(try line("y", of: decal).to, origin + point(-1, 0))
        XCTAssertEqual(try line("x", of: decal).layer, HorizontalBoardLayers.bottomSilkscreen)
        XCTAssertEqual(decal.polygons.first?.layer, HorizontalBoardLayers.bottomSilkscreen)

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let entry = try XCTUnwrap(try decalEntries()["d1"])
        XCTAssertEqual(entry["flip"] as? Bool, true)
        let placement = try XCTUnwrap(entry["placement"] as? [String: Any])
        XCTAssertEqual(placement["mirror"] as? Bool, true, "the flip is the placement's mirror")
        XCTAssertEqual(placement["angle"] as? Int, quarterTurn)
        let read = try XCTUnwrap(try reloaded().decals.first)
        XCTAssertTrue(read.flip)
        assertSameGeometry(read, decal)

        // And back to the top.
        XCTAssertTrue(set("flipped", .bool(false), on: &board))
        XCTAssertEqual(try line("x", of: try XCTUnwrap(board.decals.first)).layer, HorizontalBoardLayers.topSilkscreen)
        XCTAssertEqual(try line("y", of: try XCTUnwrap(board.decals.first)).to, origin + point(-1, 0))
    }

    func testScaleSizesTheDecalAboutItsOriginAndIsWritten() throws {
        var board = try boardWithTheDecalInItsFile()
        let origin = point(10, 20)
        XCTAssertTrue(set("scale", .scale(2.5), on: &board))
        let decal = try XCTUnwrap(board.decals.first)
        XCTAssertEqual(decal.scale, 2.5)
        XCTAssertEqual(decal.position, origin)
        XCTAssertEqual(try line("x", of: decal).to, origin + point(5, 0), "2 mm at 2.5 times")
        XCTAssertEqual(try line("x", of: decal).width, 250_000, "its line widths too")
        XCTAssertEqual(decal.polygons.first?.vertices.first, origin + point(2.5, 2.5))

        // No scale at all, or one below nothing, is not a scale.
        for scale in [0, -1, Double.nan, .infinity] {
            XCTAssertTrue(set("scale", .scale(scale), on: &board))
            XCTAssertEqual(board.decals.first, decal, "\(scale) leaves it be")
        }

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual((try decalEntries()["d1"]?["scale"] as? NSNumber)?.doubleValue, 2.5)
        let read = try XCTUnwrap(try reloaded().decals.first)
        XCTAssertEqual(read.scale, 2.5)
        assertSameGeometry(read, decal)
    }

    // MARK: - What stays

    /// What the board reads as the file has it is left as the file wrote it:
    /// an angle a turn round, and a key the app doesn't know.
    func testADecalNobodyChangedKeepsItsEntryAsTheFileWroteIt() throws {
        try fixture()
        var json = try boardJSON()
        json["decals"] = [
            "d1": ["decal": decalID,
                   "placement": ["shift": [10 * Int(mm), 20 * Int(mm)], "angle": 65_536 + quarterTurn, "mirror": false],
                   "flip": false, "scale": 1.5, "from_a_later_horizon": "kept"],
            "d2": ["decal": decalID,
                   "placement": ["shift": [30 * Int(mm), 20 * Int(mm)], "angle": 0, "mirror": false],
                   "flip": false, "scale": 1.0],
        ]
        try archive.replaceRegularFileData(relativePath: "board.json", with: try JSONSerialization.data(withJSONObject: json))
        var board = try reloaded()
        XCTAssertEqual(board.decals.first { $0.id == "d1" }?.angle, quarterTurn, "read as the angle it comes round to")

        // The other decal scaled; this one untouched.
        XCTAssertTrue(BoardDecalPlacementEdit.apply(.scale(3), propertyID: "scale", to: HorizontalSelectableRef(id: "d2", type: .boardDecal),
                                                    board: &board, poolURL: projectPoolURL))
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let entries = try decalEntries()
        let untouched = try XCTUnwrap(entries["d1"])
        XCTAssertEqual((untouched["placement"] as? [String: Any])?["angle"] as? Int, 65_536 + quarterTurn)
        XCTAssertEqual((untouched["scale"] as? NSNumber)?.doubleValue, 1.5)
        XCTAssertEqual(untouched["from_a_later_horizon"] as? String, "kept")
        XCTAssertEqual((entries["d2"]?["scale"] as? NSNumber)?.doubleValue, 3)
    }

    /// A decal placed from a pool the project pool lacks, not yet saved: it
    /// is drawn again from the pool it came from, and is still cached from
    /// there with the save.
    func testADecalNotYetCachedIsDrawnAgainFromThePoolItCameFrom() throws {
        try fixture(inProjectPool: false)
        var board = try XCTUnwrap(project.board)
        let fresh = try placed(at: point(10, 20))
        XCTAssertEqual(fresh.cacheSource?.uuid, decalID)
        board.decals.append(fresh)

        XCTAssertTrue(set("scale", .scale(2), on: &board))
        let decal = try XCTUnwrap(board.decals.first)
        XCTAssertEqual(try line("x", of: decal).to, point(14, 20))
        XCTAssertEqual(decal.cacheSource?.uuid, decalID, "still to be cached")

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual((try decalEntries()["d1"]?["scale"] as? NSNumber)?.doubleValue, 2)
        XCTAssertNotNil(archive.regularFileData(relativePath: "\(project.poolDirectory ?? "pool")/decals/cache/\(decalID).json"))
    }

    /// With its pool item gone, the decal can't be drawn again: it is left
    /// as it was and the canvas is told so. It still moves.
    func testADecalWhosePoolItemCantBeReadStaysAsItIsButMoves() throws {
        try fixture(inProjectPool: false)
        var board = try XCTUnwrap(project.board)
        board.decals.append(try placed(at: point(10, 20)))
        try FileManager.default.removeItem(at: try XCTUnwrap(basePoolDecalURL))
        let before = board.decals

        XCTAssertFalse(set("scale", .scale(2), on: &board))
        XCTAssertFalse(set("angle", .angle(quarterTurn), on: &board))
        XCTAssertFalse(set("flipped", .bool(true), on: &board))
        XCTAssertEqual(board.decals, before)
        XCTAssertTrue(set("flipped", .bool(false), on: &board), "the side it has already asks nothing of the pool")

        XCTAssertTrue(set("positionX", .length(12 * mm), on: &board))
        XCTAssertEqual(board.decals.first?.position, point(12, 20))
    }

    // MARK: - Through the sidebar

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
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
        // Every edit in one undo group, as an event would open one.
        state.undo.beginUndoGrouping()
        addTeardownBlock { @MainActor in state.undo.endUndoGrouping() }
        return window
    }

    private func decalItem(_ state: State, _ id: String = "d1") -> HorizontalSelectionDetailItem? {
        state.details.groups.first { $0.type == .boardDecal }?.items.first { $0.ref.id.lowercased() == id }
    }

    private func send(_ state: State, _ item: HorizontalSelectionDetailItem, _ propertyID: String,
                      _ value: HorizontalSelectionPropertyValue, applyToAll: Bool = false) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: item.ref, type: .boardDecal, propertyID: propertyID, value: value, applyToAll: applyToAll))
        let committed = await settle { state.committed.count > commits }
        XCTAssertTrue(committed, "\(propertyID) is an edit")
        return try XCTUnwrap(state.committed.last)
    }

    func testTheSidebarsFieldsChangeTheSelectedDecalAndUndoPutsItBack() async throws {
        let state = State(try boardWithTheDecalInItsFile(), poolURL: projectPoolURL)
        let window = try await mount(state)
        defer { window.close() }
        let origin = point(10, 20)

        state.actions?.dispatch(.selectAll)
        let listed = await settle { self.decalItem(state) != nil }
        XCTAssertTrue(listed, "selected \(state.details.groups.map(\.type))")
        let item = try XCTUnwrap(decalItem(state))
        XCTAssertEqual(item.properties.map(\.id), ["name", "positionX", "positionY", "angle", "flipped", "scale"])
        XCTAssertEqual(item.properties.first { $0.id == "scale" }?.value, .scale(1))

        var board = try await send(state, item, "scale", .scale(2))
        XCTAssertEqual(try line("x", of: try XCTUnwrap(board.decals.first)).to, origin + point(4, 0))
        let shown = await settle { self.decalItem(state)?.properties.first { $0.id == "scale" }?.value == .scale(2) }
        XCTAssertTrue(shown, "the field shows the scale it has now")

        board = try await send(state, item, "angle", .angle(quarterTurn))
        XCTAssertEqual(try line("x", of: try XCTUnwrap(board.decals.first)).to, origin + point(0, 4))
        board = try await send(state, item, "flipped", .bool(true))
        XCTAssertEqual(try line("x", of: try XCTUnwrap(board.decals.first)).layer, HorizontalBoardLayers.bottomSilkscreen)
        board = try await send(state, item, "positionX", .length(30 * mm))
        let decal = try XCTUnwrap(board.decals.first)
        XCTAssertEqual(decal.position, point(30, 20))
        XCTAssertEqual(try line("x", of: decal).to, point(30, 16), "flipped, its quarter turn is clockwise")

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        assertSameGeometry(try XCTUnwrap(try reloaded().decals.first), decal)

        // One undo group here, so one undo takes all four back.
        state.undo.endUndoGrouping()
        let commits = state.committed.count
        state.undo.undo()
        state.undo.beginUndoGrouping()
        let undone = await settle { state.committed.count > commits }
        XCTAssertTrue(undone)
        let back = try XCTUnwrap(state.committed.last?.decals.first)
        XCTAssertEqual(back.scale, 1)
        XCTAssertEqual(back.position, origin)
        XCTAssertEqual(try line("x", of: back).to, origin + point(2, 0))
    }

    /// The row's All: every selected decal takes the value.
    func testAllSetsEverySelectedDecal() async throws {
        try fixture()
        var source = try XCTUnwrap(project.board)
        source.decals += [try placed(id: "d1", at: point(10, 20)), try placed(id: "d2", at: point(30, 20))]
        let state = State(source, poolURL: projectPoolURL)
        let window = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.selectAll)
        let listed = await settle { state.details.groups.first { $0.type == .boardDecal }?.items.count == 2 }
        XCTAssertTrue(listed)
        let board = try await send(state, try XCTUnwrap(decalItem(state)), "scale", .scale(0.5), applyToAll: true)
        XCTAssertEqual(board.decals.map(\.scale), [0.5, 0.5])
        XCTAssertEqual(try line("x", of: try XCTUnwrap(board.decals.first { $0.id == "d2" })).to, point(31, 20))
    }
}
#endif
