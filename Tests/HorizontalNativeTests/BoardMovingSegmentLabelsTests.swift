#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
#endif
import XCTest
@testable import HorizontalNative

/// The net label of a track a move stretches or turns is drawn where the move
/// takes the track (`BoardMovingSegmentLabels`), or hidden when the moved
/// track would not carry it; the scene moved only such a track's ends, so its
/// label stayed at the old middle until the commit.
final class BoardMovingSegmentLabelsTests: XCTestCase {
    private let style = HorizontalMetalLinePrimitive(
        from: .zero, to: .zero,
        color: HorizontalMetalRGBA(red: 0.9, green: 0.8, blue: 0.7, alpha: 1),
        minimumWidth: 0.75,
        compositeGroup: 2_000_000,
        compositeOpacity: 0.9
    )

    private func ref(_ id: String, type: HorizontalObjectType = .track) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: type, layer: 0)
    }

    private func track(_ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 1_000_000, layer: 0, netID: "n")
    }

    private func label(_ text: String = "GND", at position: HorizontalPoint, size: Double = 600_000, angle: Int = 0) -> HorizontalText {
        HorizontalText(id: "t/track-net-label", text: text, position: position, size: size, layer: nil,
                       angle: angle, origin: .center, centered: true)
    }

    /// The scene's strokes for `label`, from line 3 of its lines, and the span
    /// that says where they are.
    private func drawn(_ label: HorizontalText) -> (lines: [HorizontalMetalLinePrimitive], span: BoardMetalTextSpan) {
        let strokes = HorizontalOutlineTextRenderer.outlineSegments(for: label)
        var lines = Array(repeating: style, count: 3)
        lines += strokes.map { stroke in
            var line = style
            line.from = stroke.0
            line.to = stroke.1
            return line
        }
        return (lines, BoardMetalTextSpan(textID: label.id, compositeGroup: style.compositeGroup, start: 40,
                                          count: strokes.count, lineIndex: 3))
    }

    private func spans(_ id: String) -> [BoardMetalTextSpan] {
        [BoardMetalTextSpan(textID: "\(id)/track-net-label", compositeGroup: 2_000_000, start: 0, count: 1, lineIndex: 0)]
    }

    func testOnlyTheLabelsTheShiftDoesNotCarryAreRedrawn() {
        let a = HorizontalPoint(x: 0, y: 0), b = HorizontalPoint(x: 10_000_000, y: 0)
        let segments = ["stretched": track("stretched", a, b), "carried": track("carried", a, b),
                        "unlabelled": track("unlabelled", a, b)]
        var plan = BoardResidentMovePlan()
        plan.segmentMoves[ref("stretched")] = BoardResidentSegmentMove(movesTo: true)
        plan.segmentMoves[ref("carried")] = BoardResidentSegmentMove(movesFrom: true, movesTo: true)
        plan.segmentMoves[ref("unlabelled")] = BoardResidentSegmentMove(movesTo: true)
        let textSpans = [ref("stretched"): spans("stretched"), ref("carried"): spans("carried")]
        let shift = HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: 1_000_000), angle: 0, mirrored: false)

        let shifted = BoardMovingSegmentLabels.reshaped(plan: plan, placement: shift, segments: segments, textSpans: textSpans)
        XCTAssertEqual(shifted.map(\.ref), [ref("stretched")], "a track the move carries whole takes its label along")
        XCTAssertEqual(shifted.first?.moved.from, a, "the end that stays")
        XCTAssertEqual(shifted.first?.moved.to, b + HorizontalPoint(x: 0, y: 1_000_000), "the end that moves")

        let turn = HorizontalPlacementTransform(shift: .zero, angle: 16_384, mirrored: false)
        let turned = BoardMovingSegmentLabels.reshaped(plan: plan, placement: turn, segments: segments, textSpans: textSpans)
        XCTAssertEqual(Set(turned.map(\.ref)), [ref("stretched"), ref("carried")],
                       "a turn would carry a label round, where the scene draws it level")
    }

    func testAStretchedTracksLabelIsDrawnFromTheMovedTrack() throws {
        let (lines, span) = drawn(label(at: HorizontalPoint(x: 5_000_000, y: 0)))
        let moved = label(at: HorizontalPoint(x: 5_000_000, y: 500_000), size: 550_000, angle: 1_000)
        let patch = try XCTUnwrap(BoardMovingSegmentLabels.patch(for: span, label: moved, lines: lines, minimumLabelSize: 0))

        XCTAssertEqual(patch.compositeGroup, span.compositeGroup)
        XCTAssertEqual(patch.start, span.start, "written over the old strokes")
        let strokes = HorizontalOutlineTextRenderer.outlineSegments(for: moved)
        XCTAssertEqual(patch.primitives.map(\.from), strokes.map(\.0))
        XCTAssertEqual(patch.primitives.map(\.to), strokes.map(\.1))
        XCTAssertTrue(patch.primitives.allSatisfy { $0.color == style.color && $0.compositeOpacity == style.compositeOpacity },
                      "in the scene's style")
    }

    func testALabelTheMovedTrackWouldNotShowIsHidden() throws {
        let original = label(at: HorizontalPoint(x: 5_000_000, y: 0))
        let (lines, span) = drawn(original)
        let hidden: (HorizontalMetalLineBufferPatch?) -> Bool = { patch in
            guard let patch else { return false }
            return patch.start == span.start && patch.primitives.count == span.count
                && patch.primitives.allSatisfy { $0.color.alpha == 0 }
        }

        XCTAssertTrue(hidden(BoardMovingSegmentLabels.patch(for: span, label: nil, lines: lines, minimumLabelSize: 0)),
                      "the track is now too short for it")
        XCTAssertTrue(hidden(BoardMovingSegmentLabels.patch(for: span, label: original, lines: lines, minimumLabelSize: 700_000)),
                      "too small to show at this zoom")
        XCTAssertTrue(hidden(BoardMovingSegmentLabels.patch(for: span, label: label("GNDX", at: original.position), lines: lines, minimumLabelSize: 0)),
                      "other strokes than the span holds")

        var stray = span
        stray.lineIndex = lines.count - 1
        XCTAssertNil(BoardMovingSegmentLabels.patch(for: stray, label: original, lines: lines, minimumLabelSize: 0),
                     "a span not where it says is left alone")
    }
}

#if os(macOS)
/// On a mounted canvas: an arrow-key move, patched in Metal, draws the label
/// of a track it stretches where the committed board's scene draws it.
@MainActor
final class BoardMovingSegmentLabelCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        var displayOptions: BoardDisplayOptions
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: displayOptions, undoManager: state.undo,
                onBoardChange: { state.committed.append($0); state.board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    /// `BoardCanvasView.textOverlayMetalCompositeGroup`, where track labels
    /// are drawn.
    private static let labelsGroup = 2_000_000

    private let start = HorizontalPoint(x: 2_000_000, y: 2_000_000)
    private let bend = HorizontalPoint(x: 22_000_000, y: 2_000_000)
    private let end = HorizontalPoint(x: 22_000_000, y: 22_000_000)

    private func segment(_ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 1_000_000, layer: HorizontalBoardLayers.topCopper, netID: "n")
    }

    /// t1 from junction j1 to a via, on a named net. The via's net is pinned
    /// (Horizon's net_set), so it is the net's source: copper that reaches
    /// no pad or pinned via loses its net, and its label, at the commit.
    private func board() -> HorizontalBoard {
        var via = HorizontalMarker(id: "V", position: bend, size: 600_000, holeSize: 300_000, layer: nil,
                                   connectedLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper],
                                   netID: "n")
        via.netSetID = "n"
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/moving-labels.hprj"), uuid: "b", name: "moving labels",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: ["j1": start], junctionNetIDs: ["j1": "n"],
            netDetails: ["n": HorizontalNetDetails(id: "n", name: "GND")],
            tracks: [segment("t1", start, bend)],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [via],
            viaHoles: [HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: "V"), position: bend, diameter: 300_000,
                                      plated: true, netID: "n")],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
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

    private func renderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    private typealias Strokes = [(from: SIMD2<Float>, to: SIMD2<Float>)]

    /// The same strokes, in any order, to within 100 nm.
    private func same(_ lhs: Strokes, _ rhs: Strokes) -> Bool {
        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { abs(a.x - b.x) < 100 && abs(a.y - b.y) < 100 }
        return lhs.count == rhs.count && lhs.allSatisfy { stroke in
            rhs.contains { near($0.from, stroke.from) && near($0.to, stroke.to) }
        }
    }

    /// Everything selected, then t2 drawn on from the via to junction j3 and
    /// left out of the selection, as a track beyond a selected via is: the
    /// move carries t1 whole and stretches t2 from its via end.
    func testAKeyMoveDrawsTheLabelOfATrackItStretchesWhereTheCommitPutsIt() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board())
        var options = BoardDisplayOptions()
        options.viaLabels = false
        XCTAssertTrue(options.trackLabels)
        let hosted = NSHostingView(rootView: Canvas(state: state, displayOptions: options)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle {
            state.actions != nil && self.monitor(in: hosted) != nil && self.renderer(in: hosted)?.presentedContentKey != nil
        }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        let oneLabel = await settle { !renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup).isEmpty }
        XCTAssertTrue(oneLabel, "t1 is labelled")
        let t1Strokes = renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup).count
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)

        state.board.junctions["j3"] = end
        state.board.junctionNetIDs["j3"] = "n"
        state.board.tracks.append(segment("t2", bend, end))
        let twoLabels = await settle {
            renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup).count == 2 * t1Strokes
        }
        XCTAssertTrue(twoLabels, "t2 is labelled too")
        XCTAssertEqual(state.actions?.canMoveSelection, true, "the selection outlived the new track")
        let before = renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup)

        // Up, twice: a keyboard move, patched in Metal. The first press builds
        // the resident scene the move patches; the second only patches it.
        try key(126, "\u{f700}")
        let started = await settle {
            !self.same(renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup), before)
        }
        XCTAssertTrue(started, "the move redrew the labels")
        try await Task.sleep(for: .milliseconds(300))
        let firstStep = renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup)
        let uploads = renderer.residentSceneUploads
        try key(126, "\u{f700}")
        let previewed = await settle {
            !self.same(renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup), firstStep)
        }
        XCTAssertTrue(previewed, "the next step redrew them again")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(renderer.residentSceneUploads, uploads, "a patched preview, not a rebuilt scene")
        let preview = renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup)

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        let t1 = try XCTUnwrap(board.tracks.first { $0.id == "t1" })
        let t2 = try XCTUnwrap(board.tracks.first { $0.id == "t2" })
        let delta = t1.from - start
        XCTAssertGreaterThan(delta.y, 0, "the move went up")
        XCTAssertEqual(t1.to, bend + delta, "t1 moved whole, with the via")
        XCTAssertEqual(t2.from, bend + delta, "t2's via end went with the via")
        XCTAssertEqual(t2.to, end, "and its junction end stayed")
        let rebuilt = await settle {
            renderer.residentSceneUploads > uploads
                && self.same(renderer.residentLineEndpoints(compositeGroup: Self.labelsGroup), preview)
        }
        XCTAssertTrue(rebuilt, "the preview drew the labels where the committed board's scene draws them")
    }
}
#endif
