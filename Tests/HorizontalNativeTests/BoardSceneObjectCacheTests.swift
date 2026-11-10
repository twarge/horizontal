#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The board scene's per-object cache: a rebuild replays what each section and
/// object drew last time for what is unchanged and draws the rest, and the
/// result is what a full build draws. The scene verifier builds every scene a
/// second time without the caches and compares the two; these edits on a
/// mounted canvas must leave it nothing to report, and must replay.
@MainActor
final class BoardSceneObjectCacheTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var details = HorizontalSelectionDetailState.empty
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper

    private func square(_ cx: Double, _ cy: Double, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: cx - half, y: cy - half), HorizontalPoint(x: cx + half, y: cy - half),
            HorizontalPoint(x: cx + half, y: cy + half), HorizontalPoint(x: cx - half, y: cy + half),
        ]
    }

    /// Something of most of what the scene draws: tracks with a net (and so
    /// labels), a via on the net, copper and outline polygons, a keepout, an
    /// unpoured plane, a board text, a hole.
    private func board() -> HorizontalBoard {
        let net = "gnd"
        let polygon = HorizontalPolygon(id: "copper", vertices: square(20 * mm, 20 * mm, half: 4 * mm), layer: top)
        let outline = HorizontalPolygon(id: "outline", vertices: square(25 * mm, 25 * mm, half: 25 * mm), layer: HorizontalBoardLayers.outline)
        let pour = HorizontalPolygon(id: "pour", vertices: square(35 * mm, 35 * mm, half: 5 * mm), layer: HorizontalBoardLayers.bottomCopper)
        let keepoutPolygon = HorizontalPolygon(id: "ko-poly", vertices: square(10 * mm, 40 * mm, half: 3 * mm), layer: top)
        var board = HorizontalGerberExportFixture.board(
            tracks: [
                HorizontalSegment(id: "t1", from: HorizontalPoint(x: 5 * mm, y: 5 * mm), to: HorizontalPoint(x: 15 * mm, y: 5 * mm),
                                  width: 300_000, layer: top, netID: net),
                HorizontalSegment(id: "t2", from: HorizontalPoint(x: 15 * mm, y: 5 * mm), to: HorizontalPoint(x: 15 * mm, y: 12 * mm),
                                  width: 300_000, layer: top, netID: net),
            ],
            keepouts: [HorizontalKeepout(id: "ko", polygonID: "ko-poly", polygon: keepoutPolygon, keepoutClass: "",
                                         allCopperLayers: false, exposedCopperOnly: false, copperPatchTypes: ["track"])],
            vias: [HorizontalMarker(id: "v1", position: HorizontalPoint(x: 15 * mm, y: 12 * mm), size: 600_000, holeSize: 300_000,
                                    layer: nil, netID: net)],
            polygons: [polygon, outline],
            planes: [HorizontalPlane(polygon: pour, draft: HorizontalPlaneEditorDraft(netID: net))],
            texts: [HorizontalText(id: "label", text: "SCENE", position: HorizontalPoint(x: 30 * mm, y: 10 * mm),
                                   size: 1_000_000, layer: HorizontalBoardLayers.topSilkscreen)]
        )
        board.netDetails[net] = HorizontalNetDetails(id: net, name: "GND")
        let extent = HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 50 * mm, y: 50 * mm)])
        board.bounds = extent
        board.physicalBounds = extent
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    func testEditsRebuildTheSceneAsAFullBuildWouldAndReplayTheRest() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let wasEnabled = BoardSceneVerifier.isEnabled
        BoardSceneVerifier.isEnabled = true
        BoardSceneVerifier.mismatches = []
        BoardSceneVerifier.comparisons = 0
        defer { BoardSceneVerifier.isEnabled = wasEnabled }

        let state = State(board())
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let up = await settle { state.actions?.visibleWorldBounds?() != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(up)
        let monitor = try XCTUnwrap(monitor(in: hosted))
        let visible = try XCTUnwrap(state.actions?.visibleWorldBounds?())
        let size = monitor.bounds.size
        let handle = monitor.makeEventHandler()
        func click(_ world: HorizontalPoint) {
            let point = CGPoint(x: (world.x - visible.minX) / visible.width * size.width,
                                y: (visible.maxY - world.y) / visible.height * size.height)
            monitor.onPrimaryClick?(point, size, CGPoint(x: point.x, y: size.height - point.y), monitor, .replace, 1)
        }
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            _ = handle(event)
        }
        state.undo.beginUndoGrouping()
        defer { state.undo.endUndoGrouping() }

        // Each edit: a commit, and the rebuild after it checked.
        func committed(_ count: Int, _ message: String) async {
            let done = await settle { state.committed.count >= count }
            XCTAssertTrue(done, message)
            let checked = await settle { BoardSceneVerifier.comparisons > 0 }
            XCTAssertTrue(checked, "the verifier compared the rebuilt scene")
        }

        // Reshape: an edge of the copper polygon nudged up on its own.
        click(HorizontalPoint(x: 20 * mm, y: 16 * mm))
        let picked = await settle { state.details.groups.contains { $0.type == .polygonEdge } }
        XCTAssertTrue(picked, "an edge selected: \(state.details.groups.map(\.type))")
        try key(126, "\u{f700}")
        _ = await settle { state.actions?.canCommitInteraction == true }
        state.actions?.dispatch(.commitInteraction)
        await committed(1, "the reshape commits")

        // A track's width, an inspector edit of one object.
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: HorizontalSelectableRef(id: "t1", type: .track, layer: top), type: .track,
            propertyID: "width", value: .length(500_000), applyToAll: false))
        await committed(2, "the width edit commits")

        // Everything moved at once, then deleted.
        state.actions?.dispatch(.selectAll)
        _ = await settle { state.details.groups.count > 3 }
        try key(126, "\u{f700}")
        _ = await settle { state.actions?.canCommitInteraction == true }
        state.actions?.dispatch(.commitInteraction)
        await committed(3, "the move commits")
        state.actions?.dispatch(.deleteSelection)
        await committed(4, "the delete commits")

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(BoardSceneVerifier.mismatches, [], "every rebuilt scene is what a full build draws")
        XCTAssertGreaterThan(BoardSceneVerifier.comparisons, 3)
    }

    func testARebuildReplaysWhatDidNotChange() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let cache = BoardSceneObjectCache()
        let buckets = BoardMetalElementBuckets()
        func line(_ y: Double, group: Int) -> HorizontalMetalLinePrimitive {
            HorizontalMetalLinePrimitive(from: HorizontalPoint(x: 0, y: y), to: HorizontalPoint(x: 1, y: y),
                                         color: HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1),
                                         width: 0, minimumWidth: 1, compositeGroup: group)
        }
        func build(_ objects: [(String, Double)], drawn: inout [String]) -> BoardMetalElementBuckets {
            let buckets = BoardMetalElementBuckets()
            let scene = BoardSceneBuild(cache: cache, buckets: buckets)
            cache.beginBuild(styleKey: 1)
            scene.section(.init("things", layer: 1), writes: [\.alwaysOnLayered], source: objects.map(\.1), objects: Double.self) { draw in
                for (id, y) in objects {
                    draw(id, y) {
                        drawn.append(id)
                        buckets.alwaysOnLayered.appendLine(line(y, group: 7), owner: HorizontalSelectableRef(id: id, type: .track))
                    }
                }
            }
            scene.finish()
            return buckets
        }
        _ = buckets
        var drawn = [String]()
        let first = build([("a", 1), ("b", 2), ("c", 3)], drawn: &drawn)
        XCTAssertEqual(drawn, ["a", "b", "c"])
        let firstStamp = try XCTUnwrap(first.groupStamps?[\BoardMetalElementBuckets.alwaysOnLayered]?[7])

        drawn = []
        let same = build([("a", 1), ("b", 2), ("c", 3)], drawn: &drawn)
        XCTAssertEqual(drawn, [], "an unchanged section is replayed whole")
        XCTAssertEqual(same.alwaysOnLayered, first.alwaysOnLayered)
        XCTAssertEqual(same.groupStamps?[\BoardMetalElementBuckets.alwaysOnLayered]?[7], firstStamp, "and keeps its stamp")

        drawn = []
        let changed = build([("a", 1), ("b", 5), ("c", 3)], drawn: &drawn)
        XCTAssertEqual(drawn, ["b"], "only the changed object is drawn again")
        XCTAssertEqual(changed.alwaysOnLayered.lines.map(\.from.y), [1, 5, 3], "in its place")
        XCTAssertNotEqual(changed.groupStamps?[\BoardMetalElementBuckets.alwaysOnLayered]?[7], firstStamp)
        XCTAssertEqual(cache.counters.objectsReplayed, 2)
        XCTAssertEqual(cache.counters.objectsBuilt, 1)
    }
}
#endif
