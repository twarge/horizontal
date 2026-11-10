import Foundation
import HorizontalProjectIO
import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import HorizontalNative

/// Dragging a track keeps its slopes (Horizon's Drag keep slope): the track
/// moves across itself, each end sliding along its neighbour, so the
/// neighbours keep their directions and grow or shrink; a track whose end
/// can't move is refused, a drag stops before a neighbour or the track folds
/// away, and the junctions stay the ones the file names.
final class DragTrackKeepingSlopeTests: XCTestCase {
    private let mm = 1_000_000.0
    private static let net = "aaaaaaaa-0000-4000-8000-000000000001"
    private static let top = HorizontalBoardLayers.topCopper

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func board(
        junctions: [String: HorizontalPoint],
        tracks: [HorizontalSegment],
        vias: [HorizontalMarker] = [],
        padPositions: [String: HorizontalPoint] = [:]
    ) -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/drag-keep-slope.hprj"), uuid: "b", name: "drag",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias,
            viaHoles: vias.map {
                HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: $0.id), position: $0.position,
                               diameter: 300_000, plated: true, netID: $0.netID)
            },
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = padPositions
        return board
    }

    private func track(_ id: String, _ from: String, _ to: String, in junctions: [String: HorizontalPoint]) -> HorizontalSegment {
        HorizontalSegment(id: id, from: junctions[from]!, to: junctions[to]!, width: 200_000, layer: Self.top,
                          netID: Self.net, fromJunctionID: from, toJunctionID: to)
    }

    /// Four junctions a–d and the three tracks a → b, b → c, c → d.
    private func run(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> HorizontalBoard {
        let junctions = ["a": a, "b": b, "c": c, "d": d]
        return board(junctions: junctions, tracks: [
            track("t1", "a", "b", in: junctions), track("t2", "b", "c", in: junctions), track("t3", "c", "d", in: junctions),
        ])
    }

    private func drag(_ board: HorizontalBoard, _ id: String = "t2") throws -> HorizontalCopperDrag {
        try HorizontalCopperDrag.begin(selection: [HorizontalSelectableRef(id: id, type: .track)], on: board).get()
    }

    private func refusal(_ board: HorizontalBoard, _ id: String = "t2") -> HorizontalCopperDrag.Refusal? {
        if case .failure(let refusal) = HorizontalCopperDrag.begin(selection: [HorizontalSelectableRef(id: id, type: .track)], on: board) {
            return refusal
        }
        return nil
    }

    private func segment(_ id: String, in board: HorizontalBoard) throws -> HorizontalSegment {
        try XCTUnwrap(board.tracks.first { $0.id == id })
    }

    /// The unit direction of a track, to compare slopes by.
    private func direction(_ segment: HorizontalSegment) -> HorizontalPoint {
        let run = segment.to - segment.from
        return run * (1 / run.length)
    }

    private func assertSameDirection(_ lhs: HorizontalSegment, _ rhs: HorizontalSegment, file: StaticString = #filePath, line: UInt = #line) {
        let a = direction(lhs), b = direction(rhs)
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6, "\(lhs.id) kept its slope", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6, "\(lhs.id) kept its slope", file: file, line: line)
    }

    // MARK: - The geometry

    func testATrackMovesAcrossItselfAndItsNeighboursStretch() throws {
        // A U: up, across, down. Only the part of the shift across the track
        // counts.
        let original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        let moved = try drag(original).applied(to: original, shift: p(4, 3))
        let t1 = try segment("t1", in: moved), t2 = try segment("t2", in: moved), t3 = try segment("t3", in: moved)
        XCTAssertEqual(t2.from, p(0, 13))
        XCTAssertEqual(t2.to, p(10, 13))
        XCTAssertEqual(t1.from, p(0, 0), "the neighbour's far end stays")
        XCTAssertEqual(t1.to, p(0, 13))
        XCTAssertEqual(t3.from, p(10, 13))
        XCTAssertEqual(t3.to, p(10, 0))
        XCTAssertEqual(moved.junctions["b"], p(0, 13), "the junction moved with the end")
        XCTAssertEqual(moved.junctions["c"], p(10, 13))
        XCTAssertEqual(moved.junctions.count, 4)
        XCTAssertEqual(t2.fromJunctionID, "b", "the ends stay on their junctions")
        XCTAssertEqual(t1.toJunctionID, "b")
    }

    func testFortyFiveDegreeNeighboursKeepTheirSlopes() throws {
        // A trapezoid: up at 45°, across, down at 45°.
        let original = run(p(0, 0), p(5, 5), p(15, 5), p(20, 0))
        let moved = try drag(original).applied(to: original, shift: p(0, 2))
        XCTAssertEqual(try segment("t2", in: moved).from, p(7, 7))
        XCTAssertEqual(try segment("t2", in: moved).to, p(13, 7))
        for id in ["t1", "t2", "t3"] {
            assertSameDirection(try segment(id, in: moved), try segment(id, in: original))
        }
    }

    func testADiagonalTrackDragsBetweenAHorizontalAndAVerticalNeighbour() throws {
        let original = run(p(0, 0), p(10, 0), p(15, 5), p(15, 15))
        let moved = try drag(original).applied(to: original, shift: p(0, 2))
        XCTAssertEqual(try segment("t2", in: moved).from, p(8, 0), "the end slid back along the horizontal neighbour")
        XCTAssertEqual(try segment("t2", in: moved).to, p(15, 7), "and up the vertical one")
        for id in ["t1", "t2", "t3"] {
            assertSameDirection(try segment(id, in: moved), try segment(id, in: original))
        }
    }

    func testADiagonalDragStaysInWholeNanometresOnTheEightDirections() throws {
        // Across a diagonal track by a shift that isn't a whole step along it:
        // each end lands in whole nanometres on its neighbour's line.
        let original = run(p(0, 0), p(10, 0), p(15, 5), p(15, 15))
        let moved = try drag(original).applied(to: original, shift: HorizontalPoint(x: 333_333, y: 777_777))
        let t1 = try segment("t1", in: moved), t3 = try segment("t3", in: moved)
        XCTAssertEqual(t1.to.y, 0, "still horizontal")
        XCTAssertEqual(t3.from.x, 15 * mm, "still vertical")
        XCTAssertEqual(t1.to.x, t1.to.x.rounded())
        XCTAssertEqual(t3.from.y, t3.from.y.rounded())
        let run = try segment("t2", in: moved).to - (try segment("t2", in: moved).from)
        XCTAssertEqual(abs(run.x - run.y), 0, accuracy: 1, "the track itself still at 45°")
    }

    func testADragStopsBeforeTheTrackFoldsAway() throws {
        // Up the trapezoid the two diagonals meet at (10, 10): the track
        // stops a micrometre short of nothing.
        let original = run(p(0, 0), p(5, 5), p(15, 5), p(20, 0))
        let moved = try drag(original).applied(to: original, shift: p(0, 9))
        let t2 = try segment("t2", in: moved)
        XCTAssertEqual(t2.length, HorizontalCopperDrag.minimumLength, accuracy: 2)
        XCTAssertLessThan(t2.from.x, t2.to.x, "not turned over")
        for id in ["t1", "t2", "t3"] {
            assertSameDirection(try segment(id, in: moved), try segment(id, in: original))
        }
    }

    func testADragStopsBeforeANeighbourShrinksToNothingOrFlips() throws {
        // Down the trapezoid the diagonals shrink to nothing at y = 0.
        let original = run(p(0, 0), p(5, 5), p(15, 5), p(20, 0))
        let moved = try drag(original).applied(to: original, shift: p(0, -8))
        let t1 = try segment("t1", in: moved), t3 = try segment("t3", in: moved)
        XCTAssertEqual(t1.length, HorizontalCopperDrag.minimumLength, accuracy: 2)
        XCTAssertEqual(t3.length, HorizontalCopperDrag.minimumLength, accuracy: 2)
        assertSameDirection(t1, try segment("t1", in: original))
        assertSameDirection(t3, try segment("t3", in: original))

        // Only the shorter neighbour limits it where they differ.
        let lopsided = run(p(0, 3), p(2, 5), p(15, 5), p(20, 0))
        let stopped = try drag(lopsided).applied(to: lopsided, shift: p(0, -8))
        XCTAssertEqual(try segment("t1", in: stopped).length, HorizontalCopperDrag.minimumLength, accuracy: 2)
        XCTAssertEqual(try segment("t2", in: stopped).from.y, try segment("t2", in: stopped).to.y)
        assertSameDirection(try segment("t3", in: stopped), try segment("t3", in: lopsided))
    }

    func testNoShiftLeavesTheBoardAsItWas() throws {
        let original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        let drag = try drag(original)
        XCTAssertEqual(drag.applied(to: original, shift: .zero).tracks, original.tracks)
        XCTAssertEqual(drag.applied(to: original, shift: p(7, 0)).tracks, original.tracks, "a shift along the track moves nothing")
        XCTAssertEqual(drag.applied(to: original, shift: .zero).junctions, original.junctions)
    }

    // MARK: - What it refuses

    func testAnEndOnAPadIsRefused() {
        // The run starts on a pad: the first track's end on it names no junction.
        var original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        original.packagePadPositions = ["pkg/pad": p(0, 0)]
        original.tracks[0].fromJunctionID = nil
        original.junctions["a"] = nil
        XCTAssertEqual(refusal(original, "t1"), .endOnPad)
        XCTAssertNotNil(try? drag(original), "the track beyond still drags")
    }

    func testAnEndOnAViaIsRefused() {
        let original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        var withVia = original
        withVia.vias = [HorizontalMarker(id: "v", position: p(0, 10), size: 600_000, layer: nil,
                                         connectedLayers: [0, -100], netID: Self.net)]
        XCTAssertEqual(refusal(withVia), .endOnVia)
    }

    func testAJunctionOfThreeTracksOrOneIsRefused() {
        var original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        original.junctions["e"] = p(-5, 10)
        original.tracks.append(track("t4", "b", "e", in: original.junctions))
        XCTAssertEqual(refusal(original), .junctionNotTwoTracks, "three tracks on b")
        XCTAssertEqual(refusal(original, "t1"), .junctionNotTwoTracks, "a's track ends there alone")
    }

    func testArcsAndLockedCopperAreRefused() {
        var arc = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        arc.tracks[1].center = p(5, 15)
        XCTAssertEqual(refusal(arc), .arc)
        XCTAssertEqual(refusal(arc, "t1"), .junctionNotTwoTracks)

        var locked = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        locked.tracks[1].locked = true
        XCTAssertEqual(refusal(locked), .locked)

        var lockedNeighbour = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        lockedNeighbour.tracks[2].locked = true
        XCTAssertEqual(refusal(lockedNeighbour), .neighbourLocked)

        var arcNeighbour = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        arcNeighbour.tracks[0].center = p(-3, 5)
        XCTAssertEqual(refusal(arcNeighbour), .neighbourArc)
    }

    func testANeighbourRunningStraightOnIsRefused() {
        let original = run(p(0, 0), p(5, 0), p(10, 0), p(10, 5))
        XCTAssertEqual(refusal(original), .neighbourInLine)
    }

    func testOfASelectedRunTheOneTrackThatCanDragDrags() throws {
        let original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        let all = original.tracks.map { HorizontalSelectableRef(id: $0.id, type: .track) }
            + original.junctions.keys.map { HorizontalSelectableRef(id: $0, type: .junction) }
        let drag = try HorizontalCopperDrag.begin(selection: all, on: original).get()
        guard case .track(let track) = drag.kind else { return XCTFail("\(drag.kind)") }
        XCTAssertEqual(track.trackID, "t2")
        XCTAssertEqual(drag.actionName, "Drag Track")

        if case .failure(let refusal) = HorizontalCopperDrag.begin(selection: [], on: original) {
            XCTAssertEqual(refusal, .nothingToDrag)
        } else {
            XCTFail("nothing selected, nothing to drag")
        }
    }

    func testDIsTheBoardsDragKey() {
        let d = HorizontalCanvasKeyEvent(characters: "d", modifiers: [])
        guard case .dragCopper? = HorizontalCanvasInputCore.command(d, supportsTrackVias: true) else {
            return XCTFail("D drags on the board")
        }
        XCTAssertNil(HorizontalCanvasInputCore.command(d, supportsTrackVias: false), "and nowhere else")
    }

    // MARK: - The file

    /// Written to the board file and read back, the dragged track and its
    /// neighbours are where the drag left them, on the junctions they were.
    func testADraggedTrackRoundTripsThroughTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        var project = try HorizontalProject.load(from: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        var json = try JSONHelper.loadDictionary(from: try XCTUnwrap(archive.regularFileData(relativePath: "board.json")))
        func position(_ x: Double, _ y: Double) -> [String: Any] { ["position": [Int(x * mm), Int(y * mm)]] }
        json["junctions"] = ["a": position(0, 0), "b": position(5, 5), "c": position(15, 5), "d": position(20, 0)]
        func track(_ from: String, _ to: String) -> [String: Any] {
            ["from": ["junc": from, "pad": NSNull()], "to": ["junc": to, "pad": NSNull()],
             "width": 200_000, "layer": 0, "width_from_net_class": false, "locked": false]
        }
        json["tracks"] = ["t1": track("a", "b"), "t2": track("b", "c"), "t3": track("c", "d")]
        try archive.replaceRegularFileData(relativePath: "board.json", with: try JSONSerialization.data(withJSONObject: json))
        var loaded = try HorizontalProject.loadSnapshot(of: archive)
        loaded.rebaseURLs(onto: project)
        project = loaded
        let board = try XCTUnwrap(project.board)

        let moved = try drag(board).applied(to: board, shift: p(0, 2))
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: moved, in: project, to: &archive))
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(Set(reloaded.junctions.keys), ["a", "b", "c", "d"])
        XCTAssertEqual(reloaded.junctions["b"], p(7, 7))
        XCTAssertEqual(reloaded.junctions["c"], p(13, 7))
        XCTAssertEqual(reloaded.junctions["a"], p(0, 0))
        let t2 = try segment("t2", in: reloaded)
        XCTAssertEqual(t2.fromJunctionID, "b")
        XCTAssertEqual(t2.toJunctionID, "c")
        XCTAssertEqual(try segment("t1", in: reloaded).to, p(7, 7))
        XCTAssertEqual(try segment("t3", in: reloaded).from, p(13, 7))

        let written = try JSONHelper.loadDictionary(from: try XCTUnwrap(archive.regularFileData(relativePath: "board.json")))
        let tracks = try XCTUnwrap(written["tracks"] as? [String: Any])
        let t1 = try XCTUnwrap(tracks["t1"] as? [String: Any])
        XCTAssertEqual((t1["to"] as? [String: Any])?["junc"] as? String, "b", "the track still names its junction")
    }

    // MARK: - The canvas

    #if os(macOS)
    @MainActor private final class State {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        var state: State
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
                toolSettings: state.toolSettings)
        }
    }

    @MainActor private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    @MainActor private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// Mounts the canvas on the U, selects it all (of which only the middle
    /// track can drag), and starts a drag with D.
    @MainActor private func startDrag(_ state: State) async throws -> (window: NSWindow, key: (UInt16, String) throws -> Void) {
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
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        XCTAssertEqual(state.actions?.canDragCopper, true)
        try key(2, "d")
        let dragging = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(dragging, "D starts the drag")
        try key(126, "\u{f700}")   // up a grid step
        return (window, key)
    }

    @MainActor func testADragIsOneUndoableEdit() async throws {
        let original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        let state = State(original)
        let (window, _) = try await startDrag(state)
        defer { window.close() }

        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.commitInteraction)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        let t2 = try segment("t2", in: board)
        XCTAssertNotEqual(t2.from.y, 10 * mm, "the track moved a grid step")
        XCTAssertEqual(t2.from.y, t2.to.y, "across itself")
        XCTAssertEqual(t2.from.x, 0)
        XCTAssertEqual(t2.to.x, 10 * mm)
        XCTAssertEqual(try segment("t1", in: board).to, t2.from, "the neighbours stretched to it")
        XCTAssertEqual(try segment("t1", in: board).from, p(0, 0))
        XCTAssertEqual(try segment("t3", in: board).from, t2.to)
        XCTAssertEqual(board.junctions["b"], t2.from)
        XCTAssertEqual(state.undo.undoActionName, "Drag Track")

        state.undo.undo()
        let undone = await settle { state.committed.count == 2 }
        XCTAssertTrue(undone)
        XCTAssertEqual(state.committed.last?.tracks, original.tracks, "one undo puts it all back")
        XCTAssertEqual(state.committed.last?.junctions, original.junctions)
    }

    @MainActor func testCancellingADragLeavesTheBoardAlone() async throws {
        let original = run(p(0, 0), p(0, 10), p(10, 10), p(10, 0))
        let state = State(original)
        let (window, _) = try await startDrag(state)
        defer { window.close() }

        state.actions?.dispatch(.cancelInteraction)
        let ended = await settle { state.actions?.canCommitInteraction == false }
        XCTAssertTrue(ended)
        XCTAssertTrue(state.committed.isEmpty, "nothing was written")
        XCTAssertFalse(state.undo.canUndo)
        // The next commit has nothing to commit either.
        state.actions?.dispatch(.commitInteraction)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.committed.isEmpty)
    }
    #endif
}
