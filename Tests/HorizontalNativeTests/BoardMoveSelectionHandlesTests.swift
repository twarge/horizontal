#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The selection's handles, the marks on a selected track's ends among them,
/// stay with what they mark while a package moves with it. The package's live
/// airwires are drawn in the selection's layer and change on every step, which
/// uploads that layer's lines anew; the handles, not uploaded again, were then
/// moved by the whole move once more each step, and ran ahead of the part.
@MainActor
final class BoardMoveSelectionHandlesTests: XCTestCase {
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

    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper

    /// A part with two pads on `n`, whose airwire a move draws live, and a
    /// track between two junctions.
    private func board() -> HorizontalBoard {
        func pad(_ name: String, at center: HorizontalPoint) -> HorizontalPolygon {
            let half = 0.4 * mm
            return HorizontalPolygon(id: "pkg/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top, netID: "n")
        }
        let part = HorizontalPoint(x: 10 * mm, y: 10 * mm)
        let padA = HorizontalPoint(x: 8 * mm, y: 10 * mm)
        let padB = HorizontalPoint(x: 12 * mm, y: 10 * mm)
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/move-handles.hprj"), uuid: "b", name: "move handles",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: ["j1": HorizontalPoint(x: 10 * mm, y: 20 * mm), "j2": HorizontalPoint(x: 20 * mm, y: 20 * mm)],
            junctionNetIDs: ["j1": "m", "j2": "m"], netDetails: [:],
            tracks: [HorizontalSegment(
                id: "t1", from: HorizontalPoint(x: 10 * mm, y: 20 * mm), to: HorizontalPoint(x: 20 * mm, y: 20 * mm),
                width: 250_000, layer: top, netID: "m", fromJunctionID: "j1", toJunctionID: "j2"
            )],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: part, angle: 0, mirrored: false, label: "R1", componentID: "c1")],
            packagePads: [pad("a", at: padA), pad("b", at: padB)], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pkg/a": padA, "pkg/b": padB]
        board.regenerateAirwires()
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

    /// The top overlay layer, where the selection and a move's live airwires are drawn.
    private func overlayRenderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal top overlay") { return layer }
        return view.subviews.lazy.compactMap { self.overlayRenderer(in: $0) }.first
    }

    func testTheSelectionsHandlesStayWithAPackageAndTrackMovedTogether() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board())
        XCTAssertFalse(state.source.airwires.isEmpty, "the part's pads have an airwire between them")
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
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        let drawn = await settle { !(self.overlayRenderer(in: hosted)?.residentHandleCenters().isEmpty ?? true) }
        XCTAssertTrue(drawn, "the selection draws handles")
        let renderer = try XCTUnwrap(overlayRenderer(in: hosted))
        let atRest = renderer.residentHandleCenters()

        // Up one step.
        try key(126, "\u{f700}")
        let started = await settle { renderer.residentHandleCenters() != atRest }
        XCTAssertTrue(started, "the move set is drawn")
        let firstStep = renderer.residentHandleCenters()
        XCTAssertFalse(firstStep.isEmpty)
        // The live airwire lands off the main thread; once it shows, each
        // step uploads the layer's lines anew.
        try? await Task.sleep(for: .milliseconds(300))
        var shown = firstStep
        for _ in 0..<2 {
            let previous = shown
            try key(126, "\u{f700}")
            let stepped = await settle { renderer.residentHandleCenters() != previous }
            XCTAssertTrue(stepped)
            try? await Task.sleep(for: .milliseconds(150))
            shown = renderer.residentHandleCenters()
        }
        let shownLines = renderer.residentLineEndpoints(compositeGroup: 0)

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        let delta = try XCTUnwrap(board.junctions["j1"]) - HorizontalPoint(x: 10 * mm, y: 20 * mm)
        XCTAssertGreaterThan(delta.y, 0, "the move went up")
        XCTAssertEqual(board.packages.first { $0.id == "pkg" }?.position.y, 10 * mm + delta.y, "the part with it")
        func near(_ point: SIMD2<Float>, _ expected: HorizontalPoint) -> Bool {
            abs(Double(point.x) - expected.x) < 50 && abs(Double(point.y) - expected.y) < 50
        }
        let padA = HorizontalPoint(x: 8 * mm, y: 10 * mm) + delta
        let padB = HorizontalPoint(x: 12 * mm, y: 10 * mm) + delta
        XCTAssertTrue(shownLines.contains { (near($0.from, padA) && near($0.to, padB)) || (near($0.from, padB) && near($0.to, padA)) },
                      "the move drew the part's airwire live, in the selection's layer")
        // Three steps in all, two of them since the first was drawn.
        let twoSteps = HorizontalPoint(x: delta.x * 2 / 3, y: delta.y * 2 / 3)
        XCTAssertEqual(shown.count, firstStep.count)
        for (index, (was, now)) in zip(firstStep, shown).enumerated() {
            XCTAssertEqual(Double(now.x), Double(was.x) + twoSteps.x, accuracy: 50, "handle \(index) kept with the selection")
            XCTAssertEqual(Double(now.y), Double(was.y) + twoSteps.y, accuracy: 50, "handle \(index) kept with the selection")
        }
    }
}
#endif
