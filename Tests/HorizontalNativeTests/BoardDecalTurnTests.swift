#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// R and E on a board decal, at rest and while it is being moved: it turns
/// a quarter about the pivot and flips to the other side across it, drawn
/// again from its pool item as the file will have it. Before, a decal moved
/// but took no turn and no flip.
@MainActor
final class BoardDecalTurnTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        let poolURL: URL
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
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

    private let mm = 1_000_000.0
    private let quarterTurn = 16_384
    private let decalID = "5e0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5c"
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!
    private var projectPoolURL: URL!

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// The template project with a decal in its pool, an L of top
    /// silkscreen: 2 mm along x from its origin and 1 mm up y.
    private func fixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-decal-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        project = try HorizontalProject.load(from: url)
        projectPoolURL = project.baseURL.appendingPathComponent(project.poolDirectory ?? "pool", isDirectory: true)
        let decals = projectPoolURL.appendingPathComponent("decals", isDirectory: true)
        try FileManager.default.createDirectory(at: decals, withIntermediateDirectories: true)
        let millimetre = Int(mm)
        let json: [String: Any] = [
            "type": "decal", "uuid": decalID, "name": "Test Logo",
            "junctions": ["a": ["position": [0, 0]], "b": ["position": [2 * millimetre, 0]], "c": ["position": [0, millimetre]]],
            "lines": [
                "x": ["from": "a", "to": "b", "layer": HorizontalBoardLayers.topSilkscreen, "width": 100_000],
                "y": ["from": "a", "to": "c", "layer": HorizontalBoardLayers.topSilkscreen, "width": 100_000],
            ],
            "polygons": [String: Any](), "arcs": [String: Any](), "texts": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: decals.appendingPathComponent("test-logo.json"))
        archive = try HorizontalProjectArchive.completeProject(from: url)
    }

    /// The board with the decal at 10, 20 as `d1`, as Place Decal… puts it.
    private func boardWithTheDecal() throws -> HorizontalBoard {
        try fixture()
        let item = try XCTUnwrap(HorizontalBoardDecalPlacement.choices(projectPoolURL: projectPoolURL)
            .items(in: .decal).first { $0.uuid == decalID })
        let placement = try XCTUnwrap(HorizontalBoardDecalPlacement(item: item))
        var board = try XCTUnwrap(project.board)
        board.decals.append(try XCTUnwrap(placement.decal(id: "d1", at: point(10, 20), nInnerLayers: 0, projectPoolURL: projectPoolURL)))
        return board
    }

    private func line(_ name: String, of decal: HorizontalBoardDecal) throws -> HorizontalSegment {
        try XCTUnwrap(decal.lines.first { $0.id.hasSuffix("/line/\(name)") }, "line \(name) of \(decal.lines.map(\.id))")
    }

    private func assertNear(_ a: HorizontalPoint, _ b: HorizontalPoint, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1, message, file: file, line: line)
    }

    private func turned(_ decal: HorizontalBoardDecal, about pivot: HorizontalPoint, by angle: Int) throws -> HorizontalBoardDecal {
        try XCTUnwrap(BoardDecalPlacementEdit.turned(decal, about: pivot, by: angle, nInnerLayers: 0, poolURL: projectPoolURL))
    }

    private func mirrored(_ decal: HorizontalBoardDecal, about pivot: HorizontalPoint) throws -> HorizontalBoardDecal {
        try XCTUnwrap(BoardDecalPlacementEdit.mirrored(decal, about: pivot, nInnerLayers: 0, poolURL: projectPoolURL))
    }

    // MARK: - The edit

    /// A turn is the rigid turn of everything the decal draws: each point
    /// where turning it about the pivot puts it, flipped or not.
    func testATurnCarriesTheDecalRoundThePivotAndTurnsItByAsMuch() throws {
        let decal = try XCTUnwrap(try boardWithTheDecal().decals.first)
        let pivot = point(12, 20)
        for flipped in [false, true] {
            let start = flipped ? try mirrored(decal, about: point(10, 20)) : decal
            XCTAssertEqual(start.flip, flipped)
            for angle in [quarterTurn, -quarterTurn, 2 * quarterTurn, 8_192] {
                let result = try turned(start, about: pivot, by: angle)
                XCTAssertEqual(result.angle, HorizontalCanvasModeSupport.wrappedAngle(start.angle + angle))
                XCTAssertEqual(result.flip, flipped, "a turn keeps the side")
                assertNear(try XCTUnwrap(result.position),
                           HorizontalCanvasModeSupport.rotated(try XCTUnwrap(start.position), around: pivot, by: angle))
                for name in ["x", "y"] {
                    let was = try line(name, of: start), now = try line(name, of: result)
                    assertNear(now.from, HorizontalCanvasModeSupport.rotated(was.from, around: pivot, by: angle), "\(name) from, \(angle)")
                    assertNear(now.to, HorizontalCanvasModeSupport.rotated(was.to, around: pivot, by: angle), "\(name) to, \(angle)")
                    XCTAssertEqual(now.layer, was.layer)
                }
            }
        }
        // R's own quarter turn, clockwise, about the decal's origin.
        let clockwise = try turned(decal, about: point(10, 20), by: -quarterTurn)
        XCTAssertEqual(clockwise.position, point(10, 20))
        XCTAssertEqual(try line("x", of: clockwise).to, point(10, 18), "on whole nanometres")
    }

    /// A flip is the mirror image across the vertical line through the
    /// pivot, on the other side of the board, whatever angle it lay at.
    func testAFlipMirrorsTheDecalAcrossThePivotOntoTheOtherSide() throws {
        let upright = try XCTUnwrap(try boardWithTheDecal().decals.first)
        let pivot = point(12, 20)
        for start in [upright, try turned(upright, about: point(10, 20), by: quarterTurn), try turned(upright, about: pivot, by: 8_192)] {
            let result = try mirrored(start, about: pivot)
            XCTAssertTrue(result.flip)
            func image(_ p: HorizontalPoint) -> HorizontalPoint { HorizontalPoint(x: 2 * pivot.x - p.x, y: p.y) }
            assertNear(try XCTUnwrap(result.position), image(try XCTUnwrap(start.position)))
            for name in ["x", "y"] {
                let was = try line(name, of: start), now = try line(name, of: result)
                assertNear(now.from, image(was.from), "\(name) from, at \(start.angle)")
                assertNear(now.to, image(was.to), "\(name) to, at \(start.angle)")
                XCTAssertEqual(now.layer, HorizontalBoardLayers.bottomSilkscreen)
            }
            let back = try mirrored(result, about: pivot)
            XCTAssertFalse(back.flip)
            XCTAssertEqual(back.angle, start.angle, "and back again")
            assertNear(try line("x", of: back).to, try line("x", of: start).to)
        }
    }

    func testATurnedAndFlippedDecalIsWrittenAndReadBackAsItLay() throws {
        var board = try boardWithTheDecal()
        let decal = try mirrored(try turned(board.decals[0], about: point(12, 20), by: -quarterTurn), about: point(12, 20))
        board.decals[0] = decal
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        var read = try HorizontalProject.loadSnapshot(of: archive)
        read.rebaseURLs(onto: project)
        let back = try XCTUnwrap(read.board?.decals.first)
        XCTAssertEqual(back.angle, decal.angle)
        XCTAssertEqual(back.flip, decal.flip)
        XCTAssertEqual(back.position, decal.position)
        XCTAssertEqual(try line("x", of: back).to, try line("x", of: decal).to)
        XCTAssertEqual(try line("y", of: back).to, try line("y", of: decal).to)
    }

    func testADecalWhosePoolItemCantBeReadTakesNoTurn() throws {
        let decal = try XCTUnwrap(try boardWithTheDecal().decals.first)
        try FileManager.default.removeItem(at: projectPoolURL.appendingPathComponent("decals/test-logo.json"))
        XCTAssertNil(BoardDecalPlacementEdit.turned(decal, about: point(10, 20), by: quarterTurn, nInnerLayers: 0, poolURL: projectPoolURL))
        XCTAssertNil(BoardDecalPlacementEdit.mirrored(decal, about: point(10, 20), nInnerLayers: 0, poolURL: projectPoolURL))
    }

    // MARK: - On the canvas

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// Mounts the canvas, selects the decal, rests the pointer away from it
    /// and returns a key sender.
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
        let monitorView = try XCTUnwrap(monitor(in: hosted))
        let handle = monitorView.makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        let rest = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 400, y: 300), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        _ = handle(rest)
        return (window, key)
    }

    func testRAtRestTurnsTheDecalAndEFlipsIt() async throws {
        let state = State(try boardWithTheDecal(), poolURL: projectPoolURL)
        let (window, key) = try await mount(state)
        defer { window.close() }

        try key(15, "r")
        let turnedOnce = await settle { state.committed.count == 1 }
        XCTAssertTrue(turnedOnce, "R on a decal is an edit")
        let turned = try XCTUnwrap(state.committed.last?.decals.first)
        XCTAssertEqual(turned.angle, 3 * quarterTurn, "a quarter clockwise, as R turns a part")
        XCTAssertFalse(turned.flip)

        try key(14, "e")
        let flippedOnce = await settle { state.committed.count == 2 }
        XCTAssertTrue(flippedOnce, "E on a decal is an edit")
        let flipped = try XCTUnwrap(state.committed.last?.decals.first)
        XCTAssertTrue(flipped.flip)
        XCTAssertEqual(try line("x", of: flipped).layer, HorizontalBoardLayers.bottomSilkscreen)
    }

    func testRDuringAMoveTurnsTheDecalAndTheCommitKeepsTheTurnAndTheMove() async throws {
        let state = State(try boardWithTheDecal(), poolURL: projectPoolURL)
        let (window, key) = try await mount(state)
        defer { window.close() }
        let start = point(10, 20)

        try key(126, "\u{f700}")   // up: a keyboard move
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        try key(15, "r")
        XCTAssertEqual(state.committed.count, 0, "R while moving commits nothing")
        XCTAssertEqual(state.actions?.canCommitInteraction, true, "and the move carries on")
        try key(126, "\u{f700}")   // and on from the turned decal
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)

        let decal = try XCTUnwrap(state.committed.last?.decals.first)
        XCTAssertEqual(decal.angle, 3 * quarterTurn, "turned a quarter, as R turns")
        let position = try XCTUnwrap(decal.position)
        // The turn is about the selection's pivot, which carries the origin
        // round it, so where it lands is the move and the turn together.
        XCTAssertNotEqual(position, start)
        let x = try line("x", of: decal)
        assertNear(x.from, position, "its geometry went with it")
        assertNear(x.to, position + point(0, -2), "and is drawn turned")

        state.undo.undo()
        let undone = await settle { state.committed.count == 2 }
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(state.committed.last?.decals.first)
        XCTAssertEqual(restored.angle, 0, "one undo step back to before the move")
        XCTAssertEqual(restored.position, start)
    }
}
#endif
