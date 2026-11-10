#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
#endif
import XCTest
@testable import HorizontalNative

/// The layer rail's Layer Mode: As is draws what the eyes say, Current only
/// the working copper and the surface layers of its side, Current and
/// adjacent the copper next to it in the stackup as well. A mode only hides,
/// solo outranks it, and with no working layer it reads as As is.
final class BoardLayerModeTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let in1 = HorizontalBoardLayers.in1Copper
    private let in2 = HorizontalBoardLayers.in2Copper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let fourLayers = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.in1Copper,
                              HorizontalBoardLayers.in2Copper, HorizontalBoardLayers.bottomCopper]
    private let topSurfaces = [HorizontalBoardLayers.topMask, HorizontalBoardLayers.topSilkscreen,
                               HorizontalBoardLayers.topPaste, HorizontalBoardLayers.topPackage,
                               HorizontalBoardLayers.topAssembly, HorizontalBoardLayers.topCourtyard,
                               HorizontalBoardLayers.topNotes]
    private let bottomSurfaces = [HorizontalBoardLayers.bottomMask, HorizontalBoardLayers.bottomSilkscreen,
                                  HorizontalBoardLayers.bottomPaste, HorizontalBoardLayers.bottomPackage,
                                  HorizontalBoardLayers.bottomAssembly, HorizontalBoardLayers.bottomCourtyard,
                                  HorizontalBoardLayers.bottomNotes]
    /// The layers no side owns, which every mode leaves to their eyes.
    private let unsided = [HorizontalBoardLayers.outline, HorizontalBoardLayers.outlineNotes,
                           HorizontalBoardLayers.user1, HorizontalBoardLayers.dimensions]

    private func options(_ mode: HorizontalBoardLayerMode, working: Int?, stack: [Int]? = nil) -> BoardDisplayOptions {
        var options = BoardDisplayOptions()
        options.showAll()
        options.layerMode = mode
        options.selectedLayer = working
        options.copperStack = stack
        return options
    }

    private func visibleCopper(_ options: BoardDisplayOptions, in stack: [Int]) -> [Int] {
        stack.filter { options.isLayerVisible($0) }
    }

    private func assertShown(_ layers: [Int], _ shown: Bool, _ options: BoardDisplayOptions, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for layer in layers {
            XCTAssertEqual(options.isLayerVisible(layer), shown,
                           "\(message): \(HorizontalBoardLayers.name(for: layer))", file: file, line: line)
        }
    }

    // MARK: - Visible layer sets

    func testAsIsDrawsWhatTheEyesSay() {
        var options = options(.asIs, working: in1, stack: fourLayers)
        XCTAssertEqual(visibleCopper(options, in: fourLayers), fourLayers)
        assertShown(topSurfaces + bottomSurfaces + unsided, true, options, "as is")

        options.setLayerVisibility(in2, isVisible: false)
        XCTAssertEqual(visibleCopper(options, in: fourLayers), [top, in1, bottom])
    }

    func testCurrentOnlyOnAnInnerLayerDrawsItAlone() {
        let options = options(.currentOnly, working: in1, stack: fourLayers)
        XCTAssertEqual(visibleCopper(options, in: fourLayers), [in1])
        assertShown(topSurfaces + bottomSurfaces, false, options, "an inner layer has no surfaces")
        assertShown(unsided, true, options, "the outline and the layers of neither side stay")
    }

    func testCurrentOnlyOnAnOuterLayerKeepsItsSidesSurfaces() {
        let topWorking = options(.currentOnly, working: top, stack: fourLayers)
        XCTAssertEqual(visibleCopper(topWorking, in: fourLayers), [top])
        assertShown(topSurfaces, true, topWorking, "the top's surfaces go with the top copper")
        assertShown(bottomSurfaces, false, topWorking, "the bottom's don't")
        assertShown(unsided, true, topWorking, "every mode keeps")

        let bottomWorking = options(.currentOnly, working: bottom, stack: fourLayers)
        XCTAssertEqual(visibleCopper(bottomWorking, in: fourLayers), [bottom])
        assertShown(bottomSurfaces, true, bottomWorking, "the bottom's surfaces go with the bottom copper")
        assertShown(topSurfaces, false, bottomWorking, "the top's don't")
    }

    func testCurrentAndAdjacentOnAFourLayerBoardsInnerLayers() {
        let first = options(.currentAndAdjacent, working: in1, stack: fourLayers)
        XCTAssertEqual(visibleCopper(first, in: fourLayers), [top, in1, in2])
        assertShown(topSurfaces, true, first, "the top copper is a neighbour, and its surfaces with it")
        assertShown(bottomSurfaces, false, first, "the bottom copper isn't")

        let second = options(.currentAndAdjacent, working: in2, stack: fourLayers)
        XCTAssertEqual(visibleCopper(second, in: fourLayers), [in1, in2, bottom])
        assertShown(bottomSurfaces, true, second, "the bottom copper is a neighbour")
        assertShown(topSurfaces, false, second, "the top copper isn't")
        assertShown(unsided, true, second, "every mode keeps")
    }

    func testCurrentAndAdjacentOnAnOuterLayer() {
        let options = options(.currentAndAdjacent, working: top, stack: fourLayers)
        XCTAssertEqual(visibleCopper(options, in: fourLayers), [top, in1])
        assertShown(topSurfaces, true, options, "the working side")
        assertShown(bottomSurfaces, false, options, "the far side")
    }

    /// The neighbours come from the stackup stamped in: on a two-layer board,
    /// or one with none stamped, top and bottom are next to each other.
    func testCurrentAndAdjacentOnATwoLayerBoard() {
        for stack in [[top, bottom], nil] {
            let options = options(.currentAndAdjacent, working: top, stack: stack)
            XCTAssertEqual(visibleCopper(options, in: [top, bottom]), [top, bottom])
            assertShown(topSurfaces + bottomSurfaces, true, options, "both sides' copper draws")
        }
    }

    func testCurrentAndAdjacentOnASixLayerBoard() {
        let six = [top, in1, in2, HorizontalBoardLayers.in3Copper, HorizontalBoardLayers.in4Copper, bottom]
        let options = options(.currentAndAdjacent, working: HorizontalBoardLayers.in3Copper, stack: six)
        XCTAssertEqual(visibleCopper(options, in: six), [in2, HorizontalBoardLayers.in3Copper, HorizontalBoardLayers.in4Copper])
        assertShown(topSurfaces + bottomSurfaces, false, options, "neither outer copper is a neighbour")
    }

    /// The silkscreen view puts the tools on the side's silkscreen: Current
    /// only draws no copper, Current and adjacent the copper it lies on.
    func testASurfaceWorkingLayer() {
        let only = options(.currentOnly, working: HorizontalBoardLayers.topSilkscreen, stack: fourLayers)
        XCTAssertEqual(visibleCopper(only, in: fourLayers), [])
        assertShown(topSurfaces, true, only, "the working layer's side")
        assertShown(bottomSurfaces, false, only, "the other side")

        let adjacent = options(.currentAndAdjacent, working: HorizontalBoardLayers.bottomSilkscreen, stack: fourLayers)
        XCTAssertEqual(visibleCopper(adjacent, in: fourLayers), [bottom])
        assertShown(bottomSurfaces, true, adjacent, "the working layer's side")
        assertShown(topSurfaces, false, adjacent, "the other side")
    }

    // MARK: - With the eyes, solo and the working layer

    /// A mode never shows what an eye hides, but the working layer always shows.
    func testAModeOnlyHides() {
        var options = options(.currentAndAdjacent, working: in1, stack: fourLayers)
        options.setLayerVisibility(in2, isVisible: false)
        options.setLayerVisibility(in1, isVisible: false)
        options.setLayerVisibility(HorizontalBoardLayers.topSilkscreen, isVisible: false)
        XCTAssertEqual(visibleCopper(options, in: fourLayers), [top, in1])
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.topSilkscreen))
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topMask))

        options.layerMode = .asIs
        XCTAssertEqual(visibleCopper(options, in: fourLayers), [top, in1, bottom], "as is, the eyes decide")
    }

    func testSoloOutranksTheMode() {
        var options = options(.currentOnly, working: top, stack: fourLayers)
        options.soloLayer = bottom
        XCTAssertEqual(visibleCopper(options, in: fourLayers), [bottom])
        assertShown(topSurfaces + unsided, false, options, "solo shows its layer alone")
    }

    /// Options with no working layer stamped — the layer rail's own eyes, the
    /// 3D view — draw as is whatever the mode, so the eyes keep showing the
    /// eyes and the 3D board stays whole.
    func testNoWorkingLayerReadsAsIs() {
        for mode in HorizontalBoardLayerMode.allCases {
            let options = options(mode, working: nil, stack: fourLayers)
            XCTAssertEqual(visibleCopper(options, in: fourLayers), fourLayers, "\(mode)")
            assertShown(topSurfaces + bottomSurfaces + unsided, true, options, "\(mode)")
        }
    }

    /// The working layer moves the mode's layers with it.
    func testChangingTheWorkingLayerMovesTheModesLayers() {
        var options = options(.currentOnly, working: top, stack: fourLayers)
        var seen = [[Int]]()
        for layer in fourLayers {
            options.selectedLayer = layer
            seen.append(visibleCopper(options, in: fourLayers))
        }
        XCTAssertEqual(seen, [[top], [in1], [in2], [bottom]])
    }

    // MARK: - Pads and vias

    /// A via draws on the copper it spans that draws, so one through the
    /// working layer still does, and a blind one away from it doesn't. A
    /// through-hole pad has a shape on every copper layer, the working one
    /// among them, and draws there the same way.
    func testViasSpanningTheWorkingLayerStillDraw() {
        let through = HorizontalMarker(id: "through", position: .zero, size: 600_000, layer: nil, connectedLayers: fourLayers)
        let blind = HorizontalMarker(id: "blind", position: .zero, size: 600_000, layer: nil, connectedLayers: [top, in1])
        let options = options(.currentOnly, working: in2, stack: fourLayers)
        XCTAssertTrue(options.showsCopper(of: through))
        XCTAssertFalse(options.showsCopper(of: blind))
        XCTAssertEqual(through.copperLayers.filter { options.isLayerVisible($0) }, [in2], "its ring draws on the working layer alone")
    }

    // MARK: - Saving and the stackup

    func testTheModeIsSavedAsThePickersTag() throws {
        var options = BoardDisplayOptions()
        options.layerMode = .currentAndAdjacent
        let data = try JSONEncoder().encode(options)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["layerMode"] as? String, "current_adjacent")
        XCTAssertEqual(try JSONDecoder().decode(BoardDisplayOptions.self, from: data).layerMode, .currentAndAdjacent)

        for (saved, mode) in [("as_is", HorizontalBoardLayerMode.asIs), ("current_only", .currentOnly),
                              ("current_adjacent", .currentAndAdjacent), ("tinted", .asIs)] {
            let decoded = try JSONDecoder().decode(BoardDisplayOptions.self, from: Data(#"{"layerMode": "\#(saved)"}"#.utf8))
            XCTAssertEqual(decoded.layerMode, mode, saved)
        }
        XCTAssertEqual(try JSONDecoder().decode(BoardDisplayOptions.self, from: Data("{}".utf8)).layerMode, .asIs)
    }

    /// The picker is the board's 2D rail's alone: the pool editors' rails and
    /// both 3D panes' leave it out.
    func testOnlyTheBoardsTwoDRailOffersTheLayerMode() {
        func controls(threeD: Bool, layers: [Int]?) -> BoardLayerControls {
            BoardLayerControls(board: nil, displayOptions: .constant(BoardDisplayOptions()), selectedLayer: .constant(top),
                               includesThreeDControls: threeD, layers: layers, showsBoardObjectToggles: layers == nil)
        }
        XCTAssertTrue(controls(threeD: false, layers: nil).showsLayerMode, "the board")
        XCTAssertFalse(controls(threeD: true, layers: nil).showsLayerMode, "the board's 3D pane")
        for profile in [HorizontalBoardModeProfile.package, .padstack, .decal] {
            XCTAssertFalse(controls(threeD: false, layers: profile.layers).showsLayerMode, "\(profile.mode)")
            XCTAssertFalse(controls(threeD: true, layers: profile.layers).showsLayerMode, "\(profile.mode) in 3D")
        }
    }

    func testTheCopperStackComesFromTheStackup() {
        XCTAssertEqual(layerModeBoard(stackup: [bottom, in2, top, in1]).copperStack, fourLayers)
        XCTAssertEqual(layerModeBoard(stackup: []).copperStack, [top, bottom], "no stackup reads as two layers")
    }
}

/// A 30 mm board with `stackup` and a track on each layer of `tracks`.
private func layerModeBoard(stackup: [Int], tracks: [Int] = []) -> HorizontalBoard {
    let mm = 1_000_000.0
    let bounds = HorizontalRect(points: [.zero, HorizontalPoint(x: 30 * mm, y: 30 * mm)])
    return HorizontalBoard(
        url: URL(fileURLWithPath: "/tmp/layer-mode.hprj"), uuid: "layer-mode", name: "layer mode",
        grid: .boardDefault,
        colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
        stackupLayers: stackup.map {
            HorizontalBoardStackupLayer(layer: $0, copperThickness: 35_000, substrateThickness: 400_000)
        },
        userLayers: [],
        junctions: [:], junctionNetIDs: [:], netDetails: [:],
        tracks: tracks.enumerated().map { index, layer in
            let y = Double(5 + 5 * index) * mm
            return HorizontalSegment(id: "track\(index)", from: HorizontalPoint(x: 5 * mm, y: y),
                                     to: HorizontalPoint(x: 25 * mm, y: y), width: 0.5 * mm, layer: layer, netID: nil)
        },
        netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
        polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
        vias: [], viaHoles: [],
        packages: [], packagePads: [], packageHoles: [],
        packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
        boardPanels: [], physicalBounds: bounds, bounds: bounds
    )
}

#if os(macOS)
/// The mounted board draws what the mode keeps the moment the mode or the
/// working layer changes: the copper layer groups its Metal layer composites
/// follow at once, and the composites are drawn again rather than reused.
@MainActor
final class BoardLayerModeRedrawTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var options: BoardDisplayOptions
        let board: HorizontalBoard
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(board: HorizontalBoard, options: BoardDisplayOptions) {
            self.board = board
            self.options = options
        }
    }

    private struct Pane: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: state.options, undoManager: state.undo,
                toolSettings: state.toolSettings,
                drawingLayer: state.options.selectedLayer ?? HorizontalBoardLayers.topCopper)
                .frame(width: 800, height: 600)
        }
    }

    private let fourLayers = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.in1Copper,
                              HorizontalBoardLayers.in2Copper, HorizontalBoardLayers.bottomCopper]

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// The layer the board's scene is drawn in.
    private func boardLayer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.boardLayer(in: $0) }.first
    }

    /// The view the board's scene is drawn into.
    private func boardView(in view: NSView) -> MTKView? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.layer(labeled: "Metal overlay") != nil { return metal }
        return view.subviews.lazy.compactMap { self.boardView(in: $0) }.first
    }

    /// Waits for a frame that draws the composites again. The view draws on
    /// needs-display, and a draw that finds no drawable is skipped and waits
    /// for the next one, which a window nobody is looking at (a CI runner's)
    /// may never be given: so a draw is asked for outright while waiting. A
    /// draw with nothing new reuses the textures and doesn't count, so this
    /// still fails if the change left them as they were.
    private func compositesRedrawn(in view: NSView, since renders: Int) async -> Bool {
        await settle {
            if (self.boardLayer(in: view)?.compositeTextureRenders ?? 0) > renders { return true }
            self.boardView(in: view)?.draw()
            return (self.boardLayer(in: view)?.compositeTextureRenders ?? 0) > renders
        }
    }

    /// The copper layers whose groups the next frame composites, top first.
    private func compositedCopper(in view: NSView) -> [Int] {
        let groups = Set(boardLayer(in: view)?.compositedGroups ?? [])
        return fourLayers.filter { groups.contains(BoardLayerStyle.compositeGroup(for: $0)) }
    }

    func testTheMountedBoardDrawsWhatTheModeKeepsAsItChanges() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let board = layerModeBoard(stackup: fourLayers, tracks: fourLayers)
        var options = BoardDisplayOptions()
        options.showAll()
        options.selectedLayer = HorizontalBoardLayers.topCopper
        options.copperStack = board.copperStack
        let state = State(board: board, options: options)
        let hosted = NSHostingView(rootView: Pane(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        let drawn = await settle { self.compositedCopper(in: hosted) == self.fourLayers }
        XCTAssertTrue(drawn, "as is, every copper layer draws: \(compositedCopper(in: hosted))")

        let steps: [(String, (inout BoardDisplayOptions) -> Void, [Int])] = [
            ("current only on top", { $0.layerMode = .currentOnly }, [HorizontalBoardLayers.topCopper]),
            ("current only on inner 1", { $0.selectedLayer = HorizontalBoardLayers.in1Copper }, [HorizontalBoardLayers.in1Copper]),
            ("inner 1 and its neighbours", { $0.layerMode = .currentAndAdjacent },
             [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.in2Copper]),
            ("inner 2 and its neighbours", { $0.selectedLayer = HorizontalBoardLayers.in2Copper },
             [HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.in2Copper, HorizontalBoardLayers.bottomCopper]),
            ("as is again", { $0.layerMode = .asIs }, fourLayers),
        ]
        for (name, change, expected) in steps {
            let renders = boardLayer(in: hosted)?.compositeTextureRenders ?? 0
            change(&state.options)
            let followed = await settle { self.compositedCopper(in: hosted) == expected }
            XCTAssertTrue(followed, "\(name): composites \(compositedCopper(in: hosted)), expected \(expected)")
            let redrawn = await compositesRedrawn(in: hosted, since: renders)
            XCTAssertTrue(redrawn, "\(name): the composites are drawn again, not reused")
        }
    }
}
#endif
