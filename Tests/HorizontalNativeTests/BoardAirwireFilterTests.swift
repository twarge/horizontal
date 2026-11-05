import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The airwire filter (the board rail's filter button, Design ▸ Filter
/// Airwires…): which nets it lists, which airwires it lets draw, that it is
/// saved with the board's view, and that the live channel says what it hides
/// while still holding every airwire up against check's.
final class BoardAirwireFilterTests: XCTestCase {
    private let mm = 1_000_000.0

    private func airwire(_ id: String, net: String?, from: Double, to: Double) -> HorizontalSegment {
        HorizontalSegment(id: id, from: HorizontalPoint(x: from * mm, y: 0), to: HorizontalPoint(x: to * mm, y: 0),
                          width: 0, layer: nil, netID: net)
    }

    private func board(airwires: [HorizontalSegment], nets: [HorizontalNetDetails]) -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/airwire-filter.hprj"), uuid: "b", name: "airwire filter",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [],
            junctions: [:], junctionNetIDs: [:],
            netDetails: Dictionary(uniqueKeysWithValues: nets.map { ($0.id, $0) }),
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.airwires = airwires
        return board
    }

    private var nets: [HorizontalNetDetails] {
        [
            HorizontalNetDetails(id: "n-gnd", name: "GND", netClassID: "power", netClassName: "Power"),
            HorizontalNetDetails(id: "n-sda", name: "SDA", netClassID: "default", netClassName: "Default"),
            HorizontalNetDetails(id: "n-scl", name: "SCL", netClassID: "default", netClassName: "Default"),
            HorizontalNetDetails(id: "n-routed", name: "VBUS", netClassID: "power", netClassName: "Power"),
        ]
    }

    func testListsTheNetsWithAirwiresAndTheHiddenOnesTheBoardStillHas() {
        let board = board(airwires: [
            airwire("a1", net: "n-gnd", from: 0, to: 1),
            airwire("a2", net: "n-gnd", from: 1, to: 2),
            airwire("a3", net: "N-SDA", from: 2, to: 3),
            airwire("a4", net: "n-scl", from: 3, to: 4),
        ], nets: nets)
        var options = BoardDisplayOptions()
        // VBUS is routed and hidden, so it stays listed to be shown again; a
        // net the board lost is ignored.
        options.setAirwiresShown(false, forNets: ["N-ROUTED", "n-gone", "n-sda"])

        let rows = BoardAirwireFilter.rows(board: board, options: options)
        XCTAssertEqual(rows.map(\.name), ["GND", "SCL", "SDA", "VBUS"])
        XCTAssertEqual(rows.map(\.airwireCount), [2, 1, 1, 0])
        XCTAssertEqual(rows.map(\.isShown), [true, true, false, false])
        XCTAssertEqual(rows.map(\.id), ["n-gnd", "n-scl", "n-sda", "n-routed"], "by uuid, lowercased")
        XCTAssertEqual(BoardAirwireFilter.netClasses(in: rows).map(\.name), ["Default", "Power"])

        XCTAssertEqual(BoardAirwireFilter.matching(rows, search: "s", netClassID: nil).map(\.name), ["SCL", "SDA", "VBUS"])
        XCTAssertEqual(BoardAirwireFilter.matching(rows, search: " sd ", netClassID: nil).map(\.name), ["SDA"])
        XCTAssertEqual(BoardAirwireFilter.matching(rows, search: "", netClassID: "power").map(\.name), ["GND", "VBUS"])
        XCTAssertEqual(BoardAirwireFilter.matching(rows, search: "s", netClassID: "power").map(\.name), ["VBUS"])

        // Show All and Hide All take what is listed.
        let listed = BoardAirwireFilter.matching(rows, search: "", netClassID: "default").map(\.id)
        options.setAirwiresShown(true, forNets: listed)
        XCTAssertEqual(options.hiddenAirwireNetIDs, ["n-routed", "n-gone"])
        options.setAirwiresShown(false, forNets: listed)
        XCTAssertEqual(options.hiddenAirwireNetIDs, ["n-routed", "n-gone", "n-scl", "n-sda"])
    }

    func testAnUnnamedNetIsListedByItsUUID() {
        let unnamed = HorizontalNetDetails(id: "0123456789abcdef", name: "")
        let rows = BoardAirwireFilter.rows(
            board: board(airwires: [airwire("a1", net: unnamed.id, from: 0, to: 1)], nets: [unnamed]),
            options: BoardDisplayOptions()
        )
        XCTAssertEqual(rows.map(\.name), ["Unnamed net 01234567"])
    }

    func testOnlyTheHiddenNetsAirwiresAreLeftOut() {
        let airwires = [
            airwire("a1", net: "n-gnd", from: 0, to: 1),
            airwire("a2", net: "n-sda", from: 1, to: 2),
            airwire("a3", net: nil, from: 2, to: 3),
        ]
        var options = BoardDisplayOptions()
        XCTAssertEqual(BoardAirwireFilter.shown(airwires, options: options).map(\.id), ["a1", "a2", "a3"])
        options.setAirwiresShown(false, forNets: ["N-GND"])
        XCTAssertFalse(options.showsAirwires(ofNet: "n-gnd"))
        XCTAssertFalse(options.showsAirwires(ofNet: "N-Gnd"), "net uuids are compared lowercased")
        XCTAssertTrue(options.showsAirwires(ofNet: nil))
        XCTAssertEqual(BoardAirwireFilter.shown(airwires, options: options).map(\.id), ["a2", "a3"])

        let drawn = HorizontalDrawnAirwires(airwires: airwires, shown: true, hiddenNetIDs: options.hiddenAirwireNetIDs)
        XCTAssertEqual(drawn.visibleAirwires.map(\.id), ["a2", "a3"])
    }

    /// The scene's connection lines lose a hidden net's airwires at concat
    /// time; the net's own drawn connection lines and the other nets' stay.
    func testTheSceneBatchDropsOnlyTheHiddenNetsAirwires() {
        var batch = BoardMetalElementBatch()
        let color = HorizontalMetalRGBA(red: 0, green: 0, blue: 1, alpha: 1)
        func line(_ x: Double) -> HorizontalMetalLinePrimitive {
            HorizontalMetalLinePrimitive(from: HorizontalPoint(x: x, y: 0), to: HorizontalPoint(x: x, y: 1), color: color)
        }
        batch.appendLine(line(1), owner: HorizontalSelectableRef(id: "cl1", type: .connectionLine))
        batch.appendLine(line(2), owner: HorizontalSelectableRef(id: "airwire/n-gnd", type: .connectionLine))
        batch.appendLine(line(3), owner: HorizontalSelectableRef(id: "airwire/n-sda", type: .connectionLine))
        batch.appendLine(line(4), owner: HorizontalSelectableRef(id: "airwire/n-gnd", type: .connectionLine))

        XCTAssertEqual(batch.filtered(hidingAirwiresOf: []).lines.map(\.from.x), [1, 2, 3, 4])
        XCTAssertEqual(batch.filtered(hidingAirwiresOf: ["n-other"]).lines.map(\.from.x), [1, 2, 3, 4])
        let filtered = batch.filtered(hidingAirwiresOf: ["n-gnd"])
        XCTAssertEqual(filtered.lines.map(\.from.x), [1, 3])
        XCTAssertEqual(filtered.lineOwners.map { $0?.id }, ["cl1", "airwire/n-sda"])
        XCTAssertEqual(filtered.lineLabelSizes.count, 2)
    }

    func testHiddenNetsAreSavedWithTheBoardsView() throws {
        var options = BoardDisplayOptions()
        options.setAirwiresShown(false, forNets: ["n-gnd", "n-sda"])
        var state = HorizontalFileViewState.default
        state.boardDisplayOptions = options
        let decoded = try JSONDecoder().decode(HorizontalFileViewState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.boardDisplayOptions.hiddenAirwireNetIDs, ["n-gnd", "n-sda"])
        XCTAssertEqual(decoded.boardDisplayOptions, options)
        XCTAssertEqual(BoardDisplayOptions.opening(decoded.boardDisplayOptions).hiddenAirwireNetIDs, ["n-gnd", "n-sda"],
                       "a board opens with its filter, as with its other object switches")

        // A view saved before the filter has none; one written by hand in
        // another case is read lowercased.
        let old = try JSONDecoder().decode(BoardDisplayOptions.self, from: Data(#"{"connectionLines": false}"#.utf8))
        XCTAssertTrue(old.hiddenAirwireNetIDs.isEmpty)
        XCTAssertFalse(old.connectionLines)
        let mixed = try JSONDecoder().decode(BoardDisplayOptions.self, from: Data(#"{"hiddenAirwireNetIDs": ["N-GND"]}"#.utf8))
        XCTAssertEqual(mixed.hiddenAirwireNetIDs, ["n-gnd"])
    }

    /// The live channel's comparison keeps every airwire, so a filtered scene
    /// still matches check, and says what the filter leaves out.
    func testTheLiveChannelSaysWhatTheFilterHidesAndStillMatchesCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-airwire-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        let index = HorizontalDesignIndex(project: try HorizontalProject.load(from: packageURL))

        let airwires = [
            airwire("a1", net: "n-gnd", from: 0, to: 1),
            airwire("a2", net: "n-gnd", from: 1, to: 2),
            airwire("a3", net: "n-sda", from: 2, to: 3),
        ]
        let unfiltered = HorizontalDispatchMethods.canvasAirwiresJSON(
            HorizontalDrawnAirwires(airwires: airwires, shown: true), reported: airwires, index: index)
        XCTAssertNil(unfiltered["filtered"])
        XCTAssertNil(unfiltered["hidden_nets"])

        let drawn = HorizontalDrawnAirwires(airwires: airwires, shown: true, hiddenNetIDs: ["n-gnd", "n-gone"])
        let json = HorizontalDispatchMethods.canvasAirwiresJSON(drawn, reported: airwires, index: index)
        XCTAssertEqual(json["matches_check"] as? Bool, true, "\(json)")
        XCTAssertEqual(json.int("count"), 3, "the scene's airwires, the hidden ones too")
        XCTAssertEqual(json.int("filtered"), 2)
        let hidden = try XCTUnwrap(json["hidden_nets"] as? [JSONDictionary])
        XCTAssertEqual(hidden.map { $0.string("net_id") }, ["n-gnd"], "a net the scene has no airwires on is left out")
        XCTAssertEqual(hidden.first?.int("airwires"), 2)
    }
}

#if os(macOS)
import AppKit
import MetalKit
import SwiftUI

/// The filter on a mounted board: the scene drops a hidden net's airwires the
/// moment the filter changes, a move's live airwires leave them out too, and
/// the menu item reaches the host.
@MainActor
final class BoardAirwireFilterCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var options = BoardDisplayOptions()
        var actions: HorizontalCanvasCommandActions?
        var filterRequests = 0
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Pane: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: state.options, undoManager: state.undo,
                onBoardChange: { state.board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings,
                onFilterAirwires: { state.filterRequests += 1 })
        }
    }

    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let padA = HorizontalPoint(x: 8_000_000, y: 10_000_000)
    private let padB = HorizontalPoint(x: 12_000_000, y: 10_000_000)
    private let padC = HorizontalPoint(x: 8_000_000, y: 14_000_000)
    private let padD = HorizontalPoint(x: 12_000_000, y: 14_000_000)

    /// One part with pads a and b on net "n" and c and d on net "h", so each
    /// net has one airwire across the part.
    private func board() -> HorizontalBoard {
        func pad(_ name: String, at center: HorizontalPoint, net: String) -> HorizontalPolygon {
            let half = 0.4 * mm
            return HorizontalPolygon(id: "pkg/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top, netID: net)
        }
        let bounds = HorizontalRect(points: [.zero, HorizontalPoint(x: 20 * mm, y: 24 * mm)])
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/airwire-filter-canvas.hprj"), uuid: "b", name: "airwire filter",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:],
            netDetails: ["n": HorizontalNetDetails(id: "n", name: "N"), "h": HorizontalNetDetails(id: "h", name: "H")],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: HorizontalPoint(x: 10 * mm, y: 12 * mm), angle: 0,
                                           mirrored: false, label: "R1", componentID: "c1")],
            packagePads: [pad("a", at: padA, net: "n"), pad("b", at: padB, net: "n"),
                          pad("c", at: padC, net: "h"), pad("d", at: padD, net: "h")],
            packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: bounds, bounds: bounds
        )
        board.packagePadPositions = ["pkg/a": padA, "pkg/b": padB, "pkg/c": padC, "pkg/d": padD]
        board.regenerateAirwires()
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func layer(_ label: String, in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: label) { return layer }
        return view.subviews.lazy.compactMap { self.layer(label, in: $0) }.first
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// Whether `lines` hold one from `a` to `b`, either way round, moved by `delta`.
    private func draws(_ lines: [(from: SIMD2<Float>, to: SIMD2<Float>)], _ a: HorizontalPoint, _ b: HorizontalPoint,
                       moved delta: HorizontalPoint = .zero) -> Bool {
        func near(_ point: SIMD2<Float>, _ expected: HorizontalPoint) -> Bool {
            abs(Double(point.x) - expected.x) < 50 && abs(Double(point.y) - expected.y) < 50
        }
        let a = a + delta, b = b + delta
        return lines.contains { (near($0.from, a) && near($0.to, b)) || (near($0.from, b) && near($0.to, a)) }
    }

    private func mount(_ state: State) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Pane(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return (window, hosted)
    }

    func testTheSceneLeavesOutAHiddenNetsAirwiresAtOnce() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(board())
        XCTAssertEqual(Set(state.board.airwires.compactMap(\.netID)), ["n", "h"], "each net has an airwire")
        let (window, hosted) = mount(state)
        defer { window.close() }
        func sceneLines() -> [(from: SIMD2<Float>, to: SIMD2<Float>)] {
            layer("Metal overlay", in: hosted)?.residentLineEndpoints(compositeGroup: 0) ?? []
        }

        let drawn = await settle { self.draws(sceneLines(), self.padA, self.padB) && self.draws(sceneLines(), self.padC, self.padD) }
        XCTAssertTrue(drawn, "both nets' airwires are drawn")
        XCTAssertEqual(state.actions?.canFilterAirwires, true, "the menu item is on for the board")
        state.actions?.dispatch(.filterAirwires)
        XCTAssertEqual(state.filterRequests, 1, "the menu item opens the host's filter")

        state.options.setAirwiresShown(false, forNets: ["H"])
        let filtered = await settle { !self.draws(sceneLines(), self.padC, self.padD) }
        XCTAssertTrue(filtered, "h's airwire is gone")
        XCTAssertTrue(draws(sceneLines(), padA, padB), "n's stays")
        let reported = try XCTUnwrap(state.actions?.drawnAirwires?())
        XCTAssertEqual(reported.airwires.count, 2, "the live channel keeps every airwire to compare with check")
        XCTAssertEqual(reported.visibleAirwires.compactMap(\.netID), ["n"])
        XCTAssertEqual(reported.hiddenNetIDs, ["h"])

        state.options.setAirwiresShown(true, forNets: ["h"])
        let back = await settle { self.draws(sceneLines(), self.padC, self.padD) }
        XCTAssertTrue(back, "shown again, h's airwire is back")
    }

    func testAMovesLiveAirwiresLeaveOutAHiddenNet() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(board())
        state.options.setAirwiresShown(false, forNets: ["h"])
        let (window, hosted) = mount(state)
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        func liveLines() -> [(from: SIMD2<Float>, to: SIMD2<Float>)] {
            layer("Metal top overlay", in: hosted)?.residentLineEndpoints(compositeGroup: 0) ?? []
        }

        /// Whether `lines` hold one from `a` to `b`, either way round, moved up
        /// together by however far the move has gone.
        func drawsMovedUp(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Bool {
            liveLines().contains { line in
                for (from, to) in [(a, b), (b, a)] {
                    let shiftFrom = (x: Double(line.from.x) - from.x, y: Double(line.from.y) - from.y)
                    let shiftTo = (x: Double(line.to.x) - to.x, y: Double(line.to.y) - to.y)
                    if abs(shiftFrom.x) < 50, abs(shiftTo.x) < 50, abs(shiftFrom.y - shiftTo.y) < 50, shiftFrom.y > 50 {
                        return true
                    }
                }
                return false
            }
        }

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        // Up one step, then again once the live airwires, made off the main
        // thread, have landed and draw from the next body pass.
        try key(126, "\u{f700}")
        try? await Task.sleep(for: .milliseconds(300))
        try key(126, "\u{f700}")
        let live = await settle { drawsMovedUp(self.padA, self.padB) }
        XCTAssertTrue(live, "the move draws n's airwire live")
        XCTAssertFalse(drawsMovedUp(padC, padD), "and not hidden h's")
        XCTAssertFalse(draws(liveLines(), padC, padD), "nor h's where it was")
    }
}
#endif
