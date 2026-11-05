import XCTest
@testable import HorizontalNative

/// Horizon's Select More (+) and Select More (stop at vias) (=), which a
/// double-click on a track runs: the run of track a selection is part of,
/// along its junctions, through its vias or stopping at them, and out to its
/// pads, where it ends (`BoardSelectMore`, the keys that ask for it, and a
/// mounted board canvas taking them).
final class BoardSelectMoreTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// Pad P1 (0, 0) → j1 → j2 → the via at (20, 10), a branch off j2 to j9,
    /// then on the bottom from the via to j3 and pad P2 (30, 0); past P2 a run
    /// of its own to pad P3. Apart from those, a top track and a bottom one
    /// that end at (50, 30) on junctions of their own, with no via there.
    /// t2's first end names no junction: the one at its point on its layer is
    /// its.
    private func board() -> HorizontalBoard {
        let junctions: [String: HorizontalPoint] = [
            "j1": point(10, 0), "j2": point(10, 10), "jv": point(20, 10), "j3": point(20, 20),
            "j4": point(40, 0), "j9": point(5, 10),
            "j5": point(50, 30), "j6": point(60, 30), "j7": point(50, 30), "j8": point(50, 40),
        ]
        func track(_ id: String, _ from: HorizontalPoint, _ fromJunction: String?, _ to: HorizontalPoint, _ toJunction: String?,
                   layer: Int? = nil) -> HorizontalSegment {
            HorizontalSegment(id: id, from: from, to: to, width: 250_000, layer: layer ?? top, netID: "n",
                              fromJunctionID: fromJunction, toJunctionID: toJunction)
        }
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/select-more.hprj"), uuid: "b", name: "select more",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: top, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: bottom, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: [
                track("t1", point(0, 0), nil, point(10, 0), "j1"),
                track("t2", point(10, 0), nil, point(10, 10), "j2"),
                track("t3", point(10, 10), "j2", point(20, 10), "jv"),
                track("t10", point(10, 10), "j2", point(5, 10), "j9"),
                track("t4", point(20, 10), "jv", point(20, 20), "j3", layer: bottom),
                track("t5", point(20, 20), "j3", point(30, 0), nil, layer: bottom),
                track("t6", point(30, 0), nil, point(40, 0), "j4"),
                track("t7", point(40, 0), "j4", point(60, 0), nil),
                track("t8", point(50, 30), "j5", point(60, 30), "j6"),
                track("t9", point(50, 30), "j7", point(50, 40), "j8", layer: bottom),
            ],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [HorizontalMarker(id: "v1", position: point(20, 10), size: 600_000, layer: top, connectedLayers: [top, bottom])],
            viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: point(30, 0), angle: 0, mirrored: false, label: "R1", componentID: "c1")],
            packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pkg/p1": point(0, 0), "pkg/p2": point(30, 0), "pkg/p3": point(60, 0)]
        return board
    }

    private func track(_ id: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .track, layer: top)
    }

    private func selected(
        _ seeds: [HorizontalSelectableRef],
        stopsAtVias: Bool = false,
        in board: HorizontalBoard? = nil
    ) -> (tracks: Set<String>, junctions: Set<String>) {
        let refs = BoardSelectMore.selection(from: seeds, in: board ?? self.board(), stopsAtVias: stopsAtVias)
        XCTAssertEqual(Set(refs.map(\.type)).subtracting([.track, .junction]), [], "only tracks and junctions")
        return (Set(refs.filter { $0.type == .track }.map(\.id)), Set(refs.filter { $0.type == .junction }.map(\.id)))
    }

    // MARK: - The run

    func testSelectMoreFollowsTheJunctionsThroughTheViaOutToThePads() {
        let run = selected([track("t1")])
        XCTAssertEqual(run.tracks, ["t1", "t2", "t3", "t10", "t4", "t5"], "the branch and the via's bottom side, not past pad P2")
        XCTAssertEqual(run.junctions, ["j1", "j2", "j9", "jv", "j3"])
    }

    func testStopAtViasEndsTheRunAtTheVia() {
        let run = selected([track("t1")], stopsAtVias: true)
        XCTAssertEqual(run.tracks, ["t1", "t2", "t3", "t10"])
        XCTAssertEqual(run.junctions, ["j1", "j2", "j9"], "the via's junction is left out")
    }

    func testAViaInTheSelectionStandsForItsJunctionEvenStoppingAtVias() {
        let via = HorizontalSelectableRef(id: "v1", type: .via, layer: top)
        for stopsAtVias in [false, true] {
            let run = selected([via], stopsAtVias: stopsAtVias)
            XCTAssertEqual(run.tracks, ["t1", "t2", "t3", "t10", "t4", "t5"], "stopsAtVias \(stopsAtVias)")
            XCTAssertEqual(run.junctions, ["j1", "j2", "j9", "jv", "j3"], "stopsAtVias \(stopsAtVias)")
        }
    }

    func testASelectedJunctionStartsTheRunAndStaysSelected() {
        let run = selected([HorizontalSelectableRef(id: "J9", type: .junction)], stopsAtVias: true)
        XCTAssertEqual(run.tracks, ["t1", "t2", "t3", "t10"])
        XCTAssertEqual(run.junctions, ["j1", "j2", "j9"])
    }

    func testTheRunPastAPadIsARunOfItsOwn() {
        let run = selected([track("t7")])
        XCTAssertEqual(run.tracks, ["t6", "t7"])
        XCTAssertEqual(run.junctions, ["j4"])
    }

    func testTracksOnTwoLayersEndingAtOnePointWithNoViaStayApart() {
        let run = selected([track("t8")])
        XCTAssertEqual(run.tracks, ["t8"])
        XCTAssertEqual(run.junctions, ["j5", "j6"])
    }

    /// Horizon's via has one junction; here a point may hold one a layer,
    /// which the via joins.
    func testAViaJoinsTheJunctionsOfEachLayerAtItsPoint() throws {
        var board = board()
        board.junctions["jb"] = point(20, 10)
        let index = try XCTUnwrap(board.tracks.firstIndex { $0.id == "t4" })
        board.tracks[index].fromJunctionID = "jb"
        let through = selected([track("t3")], in: board)
        XCTAssertTrue(through.tracks.isSuperset(of: ["t4", "t5"]), "\(through.tracks)")
        XCTAssertTrue(through.junctions.isSuperset(of: ["jv", "jb"]))
        let stopped = selected([track("t3")], stopsAtVias: true, in: board)
        XCTAssertTrue(stopped.tracks.isDisjoint(with: ["t4", "t5"]), "\(stopped.tracks)")
        XCTAssertTrue(stopped.junctions.isDisjoint(with: ["jv", "jb"]))
    }

    func testTheRefsAreTheBoardsSelectablesInTheBoardsOrder() {
        let refs = BoardSelectMore.selection(from: [track("t5")], in: board(), stopsAtVias: false)
        XCTAssertEqual(refs.filter { $0.type == .track }.map(\.id), ["t1", "t2", "t3", "t10", "t4", "t5"])
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "t4", type: .track, layer: bottom)), "a track's ref has its layer")
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "jv", type: .junction)), "a junction's has none")
    }

    func testOnlyATrackJunctionOrViaHasARun() {
        let package = HorizontalSelectableRef(id: "pkg", type: .boardPackage)
        XCTAssertFalse(BoardSelectMore.canSelectMore(from: [package]))
        XCTAssertEqual(BoardSelectMore.selection(from: [package], in: board(), stopsAtVias: false), [])
        XCTAssertEqual(BoardSelectMore.selection(from: [track("gone")], in: board(), stopsAtVias: false), [])
        XCTAssertTrue(BoardSelectMore.canSelectMore(from: [package, track("t1")]))
        // Horizon's selection is the run alone.
        XCTAssertEqual(selected([package, track("t8")]).tracks, ["t8"])
    }

    // MARK: - Keys

    private func command(_ characters: String, typed: String? = nil, _ modifiers: HorizontalCanvasInputModifiers = [],
                         board: Bool = true) -> Bool? {
        let event = HorizontalCanvasKeyEvent(characters: characters, typedCharacters: typed, modifiers: modifiers)
        guard case .selectMore(let stopsAtVias)? = HorizontalCanvasInputCore.command(event, supportsTrackVias: board) else {
            return nil
        }
        return stopsAtVias
    }

    func testPlusSelectsMoreAndEqualsStopsAtVias() {
        // US: + is Shift-=.
        XCTAssertEqual(command("+", typed: "+", .shift), false)
        XCTAssertEqual(command("=", typed: "=", []), true)
        // German: + is a key of its own, = is Shift-0.
        XCTAssertEqual(command("+", typed: "+", []), false)
        XCTAssertEqual(command("=", typed: "=", .shift), true)
        // UIKit leaves Shift out of charactersIgnoringModifiers.
        XCTAssertEqual(command("=", typed: "+", .shift), false)
        // No typed characters: the characters decide.
        XCTAssertEqual(command("+"), false)
        XCTAssertEqual(command("="), true)
    }

    func testPlusWithCommandOrOffTheBoardIsNotSelectMore() {
        XCTAssertNil(command("+", typed: "+", [.command, .shift]))
        XCTAssertNil(command("=", typed: "=", .command), "⌘= stays the menu's")
        XCTAssertNil(command("=", typed: "≠", .option))
        XCTAssertNil(command("+", typed: "+", .shift, board: false))
        XCTAssertNil(command("=", typed: "=", [], board: false))
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// + and = on a mounted board canvas: the selection becomes the run, as the
/// Edit menu's items, which the selection enables, make it.
@MainActor
final class BoardSelectMoreCanvasTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
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
                onBoardChange: { board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0

    /// Two tracks from pad to via to pad, the second on the bottom, and the
    /// part whose pads they end on.
    private func board() -> HorizontalBoard {
        let top = HorizontalBoardLayers.topCopper
        let bottom = HorizontalBoardLayers.bottomCopper
        let padA = HorizontalPoint(x: 0, y: 0)
        let via = HorizontalPoint(x: 10 * mm, y: 0)
        let padB = HorizontalPoint(x: 20 * mm, y: 0)
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/select-more-canvas.hprj"), uuid: "b", name: "select more canvas",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: top, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: bottom, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: ["jv": via], junctionNetIDs: [:], netDetails: [:],
            tracks: [
                HorizontalSegment(id: "t1", from: padA, to: via, width: 250_000, layer: top, netID: "n", toJunctionID: "jv"),
                HorizontalSegment(id: "t2", from: via, to: padB, width: 250_000, layer: bottom, netID: "n", fromJunctionID: "jv"),
            ],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [HorizontalMarker(id: "v1", position: via, size: 600_000, layer: top, connectedLayers: [top, bottom], netID: "n")],
            viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: HorizontalPoint(x: 10 * mm, y: 10 * mm), angle: 0, mirrored: false,
                                           label: "R1", componentID: "c1")],
            packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pkg/a": padA, "pkg/b": padB]
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

    func testPlusAndEqualsMakeTheSelectionTheRun() async throws {
        _ = NSApplication.shared
        let state = State(board())
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        XCTAssertEqual(state.actions?.canSelectMore, false, "nothing selected, nothing to start from")
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event), "the canvas takes \(characters)")
        }
        func types() -> Set<HorizontalObjectType> { Set(state.details.groups.map(\.type)) }
        func count(_ type: HorizontalObjectType) -> Int? { state.details.groups.first { $0.type == type }?.items.count }

        // US layout: + is Shift-= (key code 24).
        for (characters, flags) in [("+", NSEvent.ModifierFlags.shift), ("=", [])] {
            state.actions?.dispatch(.selectAll)
            let all = await settle { types().isSuperset(of: [.boardPackage, .via, .track]) }
            XCTAssertTrue(all, "\(types())")
            XCTAssertEqual(state.actions?.canSelectMore, true)

            try key(24, characters, flags)
            let run = await settle { types() == [.track, .junction] }
            XCTAssertTrue(run, "\(characters): \(types())")
            // From both tracks, through the via or stopping at it, the run is
            // both; the via's junction comes with them, but not the via or
            // the part.
            XCTAssertEqual(count(.track), 2)
            XCTAssertEqual(count(.junction), 1)
        }
    }
}
#endif
