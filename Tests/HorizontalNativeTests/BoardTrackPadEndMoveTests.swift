#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
#endif
import XCTest
@testable import HorizontalNative

/// Moving a track moves its two ends, and an end on a pad stays on it
/// (`BoardTrackPadEnds`): a track from a pad to a junction swings about the
/// pad, and one from pad to pad stays put. A package the selection moves
/// still carries the ends on its pads.
final class BoardTrackPadEndMoveTests: XCTestCase {
    private let pad = HorizontalPoint(x: 0, y: 0)
    private let otherPad = HorizontalPoint(x: 0, y: 2_000_000)
    private let corner = HorizontalPoint(x: 1_000_000, y: 0)
    private var padPositions: [String: HorizontalPoint] {
        ["pkg1/pad1": pad, "pkg2/pad1": otherPad]
    }

    private func track(_ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint, center: HorizontalPoint? = nil) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 200_000, layer: 0, center: center, netID: "n")
    }

    private func ref(_ id: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .track, layer: 0)
    }

    private func plan(
        _ refs: [HorizontalSelectableRef],
        tracks: [HorizontalSegment],
        junctions: [String: HorizontalPoint] = [:],
        packageHoles: [HorizontalHole] = []
    ) -> BoardResidentMovePlan {
        BoardMovePlanner.residentMovePlan(
            for: refs, tracks: tracks, netTies: [],
            junctions: junctions, junctionNetIDs: junctions.mapValues { _ in "n" },
            vias: [], packagePads: [], packageHoles: packageHoles, padPositions: padPositions)
    }

    func testPadEndsAreThePadCentres() {
        var ends = BoardTrackPadEnds(padPositions: padPositions)
        XCTAssertTrue(ends.isOnPad(pad))
        XCTAssertTrue(ends.isOnPad(otherPad))
        XCTAssertFalse(ends.isOnPad(corner))
        var none = BoardTrackPadEnds(padPositions: [:])
        XCTAssertFalse(none.isOnPad(pad))
    }

    /// A track with no junction ends used to shift whole, both ends off
    /// their pads.
    func testTrackFromPadToPadStaysPut() {
        let result = plan([ref("t1")], tracks: [track("t1", pad, otherPad)])
        XCTAssertNil(result.segmentMoves[ref("t1")])
        XCTAssertFalse(result.translatedRefs.contains(ref("t1")))
    }

    func testTrackFromPadToFreeEndMovesOnlyTheFreeEnd() {
        let result = plan([ref("t1")], tracks: [track("t1", pad, corner)])
        XCTAssertEqual(result.segmentMoves[ref("t1")], BoardResidentSegmentMove(movesFrom: false, movesTo: true))
    }

    /// The track's own junction end carries the copper there, as before; the
    /// pad end is left.
    func testTrackFromPadToJunctionMovesTheJunctionEnd() {
        let next = track("t2", corner, HorizontalPoint(x: 1_000_000, y: 1_000_000))
        let result = plan([ref("t1")], tracks: [track("t1", pad, corner), next], junctions: ["j1": corner])
        XCTAssertEqual(result.segmentMoves[ref("t1")], BoardResidentSegmentMove(movesFrom: false, movesTo: true))
        XCTAssertEqual(result.segmentMoves[ref("t2")], BoardResidentSegmentMove(movesFrom: true, movesTo: false))
    }

    /// A junction at a pad's centre is on the pad too, so it stays, and so do
    /// the other tracks on it.
    func testJunctionOnAPadStaysWithIt() {
        let next = track("t2", pad, otherPad)
        let result = plan([ref("t1")], tracks: [track("t1", pad, corner), next], junctions: ["j1": pad])
        XCTAssertEqual(result.segmentMoves[ref("t1")], BoardResidentSegmentMove(movesFrom: false, movesTo: true))
        XCTAssertNil(result.segmentMoves[ref("t2")])
    }

    /// An arc's centre moves with both ends only: with one left on its pad,
    /// the arc is reshaped by its moving end, as moving its junction would.
    func testArcCentreStaysWhenAnEndIsOnAPad() {
        let arc = track("t1", pad, corner, center: HorizontalPoint(x: 500_000, y: 0))
        let result = plan([ref("t1")], tracks: [arc])
        XCTAssertEqual(result.segmentMoves[ref("t1")], BoardResidentSegmentMove(movesFrom: false, movesTo: true, movesCenter: false))

        let free = track("t2", corner, HorizontalPoint(x: 2_000_000, y: 0), center: HorizontalPoint(x: 1_500_000, y: 0))
        XCTAssertEqual(plan([ref("t2")], tracks: [free]).segmentMoves[ref("t2")],
                       BoardResidentSegmentMove(movesFrom: true, movesTo: true, movesCenter: true))
    }

    /// A selected package still carries the track ends on its pads.
    func testSelectedPackageCarriesTheEndOnItsPad() {
        let hole = HorizontalHole(id: "pkg1/hole/h1", position: pad, diameter: 300_000, plated: true, netID: "n")
        let package = HorizontalSelectableRef(id: "pkg1", type: .boardPackage)
        let result = plan([package, ref("t1")], tracks: [track("t1", pad, corner)], packageHoles: [hole])
        XCTAssertTrue(result.translatedRefs.contains(package))
        XCTAssertEqual(result.segmentMoves[ref("t1")]?.movesFrom, true)
    }

    /// A move takes a selected track's junctions along, but not one on a pad.
    func testExpandedSelectionLeavesOutJunctionsOnPads() {
        let expanded = BoardMovePlanner.expandedSelection(
            [ref("t1")], tracks: [track("t1", pad, corner)], netTies: [],
            junctions: ["j-pad": pad, "j-corner": corner], junctionNetIDs: ["j-pad": "n", "j-corner": "n"],
            vias: [], padPositions: padPositions)
        XCTAssertEqual(Set(expanded), [ref("t1"), HorizontalSelectableRef(id: "j-corner", type: .junction)])
    }
}

#if os(macOS)
/// The board canvas's own moves and turns, through its keys: what the move
/// commits, and R at rest.
@MainActor
final class BoardTrackPadEndCanvasTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
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
                onBoardChange: { state.committed.append($0); board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let pad = HorizontalPoint(x: 2_000_000, y: 2_000_000)
    private let otherPad = HorizontalPoint(x: 2_000_000, y: 8_000_000)
    private let corner = HorizontalPoint(x: 6_000_000, y: 2_000_000)
    private let far = HorizontalPoint(x: 6_000_000, y: 6_000_000)

    private func track(_ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 250_000, layer: HorizontalBoardLayers.topCopper, netID: "n")
    }

    /// `t1` from a pad to a junction, `t2` on from there to another, and
    /// `t3` from pad to pad. No package: a pad end is told by its position.
    private func board() -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/pad-ends.hprj"), uuid: "b", name: "pad ends",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: ["j1": corner, "j2": far], junctionNetIDs: ["j1": "n", "j2": "n"], netDetails: [:],
            tracks: [track("t1", pad, corner), track("t2", corner, far), track("t3", pad, otherPad)],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pkg1/pad1": pad, "pkg2/pad1": otherPad]
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

    /// The renderer of the top overlay, where the selection is drawn.
    private func overlayRenderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.loadProfileLabel == "Metal top overlay" { return renderer }
        return view.subviews.lazy.compactMap { self.overlayRenderer(in: $0) }.first
    }

    /// Mounts the canvas, selects everything and returns a key sender.
    private func mount(_ state: State) async throws -> (window: NSWindow, key: (UInt16, String) throws -> Void) {
        let (window, _, key) = try await mountWithOverlay(state)
        return (window, key)
    }

    /// `mount`, with a finder of the selection overlay's renderer, which the
    /// canvas makes once there is something to draw in it.
    private func mountWithOverlay(_ state: State) async throws -> (
        window: NSWindow, overlay: () -> HorizontalMetalBackdropView.Renderer?, key: (UInt16, String) throws -> Void
    ) {
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
        return (window, { self.overlayRenderer(in: hosted) }, key)
    }

    private func tracks(_ board: HorizontalBoard) -> [String: HorizontalSegment] {
        Dictionary(uniqueKeysWithValues: board.tracks.map { ($0.id, $0) })
    }

    func testAKeyMoveLeavesTrackEndsOnTheirPads() async throws {
        let state = State(board())
        let (window, key) = try await mount(state)
        defer { window.close() }

        try key(126, "\u{f700}")   // up
        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        let moved = tracks(board)
        let delta = try XCTUnwrap(board.junctions["j1"]) - corner
        XCTAssertGreaterThan(delta.y, 0, "the junctions moved up")
        XCTAssertEqual(moved["t1"]?.from, pad, "t1 keeps to its pad")
        XCTAssertEqual(moved["t1"]?.to, corner + delta, "and its junction end moved")
        XCTAssertEqual(moved["t2"]?.from, corner + delta)
        XCTAssertEqual(moved["t2"]?.to, far + delta)
        XCTAssertEqual(moved["t3"]?.from, pad, "a track from pad to pad stays put")
        XCTAssertEqual(moved["t3"]?.to, otherPad)
    }

    /// The box `BoardTrackSelectionOutline` outlines a straight track by.
    private func outlineCorners(_ segment: HorizontalSegment) throws -> [HorizontalPoint] {
        try XCTUnwrap(
            HorizontalCanvasModeSupport.segmentSelectables([segment], type: .track).first { !$0.isPoint }
        ).corners
    }

    /// Whether `strokes` start a line at every corner of `corners`.
    private func outlines(
        _ corners: [HorizontalPoint],
        in strokes: [(from: SIMD2<Float>, to: SIMD2<Float>)]
    ) -> Bool {
        corners.allSatisfy { corner in
            strokes.contains { abs(Double($0.from.x) - corner.x) < 50 && abs(Double($0.from.y) - corner.y) < 50 }
        }
    }

    /// The selection outline keeps to the copper while the move is under
    /// way: a track's box swings about its pad end with the track, and a
    /// track from pad to pad keeps its box where it is. The selection used to
    /// shift whole, boxes and all, off the tracks it outlined.
    func testAKeyMoveOutlinesTheTracksWhereTheyAre() async throws {
        let original = board()
        let state = State(original)
        let (window, overlay, key) = try await mountWithOverlay(state)
        defer { window.close() }
        let found = await settle { overlay()?.presentedContentKey != nil }
        XCTAssertTrue(found, "the selection is drawn")
        let renderer = try XCTUnwrap(overlay())
        let before = original.tracks
        let shown = await settle {
            let strokes = renderer.residentLineEndpoints(compositeGroup: 0)
            return before.allSatisfy { (try? self.outlines(self.outlineCorners($0), in: strokes)) == true }
        }
        XCTAssertTrue(shown, "each track is outlined")

        try key(126, "\u{f700}")   // up: a keyboard move, patched in Metal
        let t1 = try XCTUnwrap(before.first { $0.id == "t1" })
        let previewed = await settle {
            let strokes = renderer.residentLineEndpoints(compositeGroup: 0)
            return (try? self.outlines(self.outlineCorners(t1), in: strokes)) == false
        }
        XCTAssertTrue(previewed, "the move redrew t1's outline")
        let strokes = renderer.residentLineEndpoints(compositeGroup: 0)

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let moved = tracks(try XCTUnwrap(state.committed.last))
        let delta = try XCTUnwrap(moved["t2"]).from - corner
        XCTAssertGreaterThan(delta.y, 0, "the move went up")
        for id in ["t1", "t2", "t3"] {
            let track = try XCTUnwrap(moved[id])
            XCTAssertTrue(try outlines(outlineCorners(track), in: strokes), "\(id) was outlined where the move took it")
        }
        var shiftedPadToPad = try XCTUnwrap(before.first { $0.id == "t3" })
        shiftedPadToPad.from = shiftedPadToPad.from + delta
        shiftedPadToPad.to = shiftedPadToPad.to + delta
        XCTAssertFalse(try outlines(outlineCorners(shiftedPadToPad), in: strokes), "t3's outline stayed with t3")
        var shiftedPadEnd = t1
        shiftedPadEnd.from = shiftedPadEnd.from + delta
        shiftedPadEnd.to = shiftedPadEnd.to + delta
        XCTAssertFalse(try outlines(outlineCorners(shiftedPadEnd), in: strokes), "t1's outline kept to its pad")
    }

    func testRLeavesTrackEndsOnTheirPads() async throws {
        let state = State(board())
        let (window, key) = try await mount(state)
        defer { window.close() }

        try key(15, "r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        let turned = tracks(board)
        XCTAssertNotEqual(board.junctions["j1"], corner, "the junctions turned")
        XCTAssertEqual(turned["t1"]?.from, pad, "t1 keeps to its pad")
        XCTAssertEqual(turned["t1"]?.to, board.junctions["j1"], "and its other end went with its junction")
        XCTAssertEqual(turned["t3"]?.from, pad, "a track from pad to pad stays put")
        XCTAssertEqual(turned["t3"]?.to, otherPad)
    }
}
#endif
