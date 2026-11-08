#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A part selected on the schematic that has no package on the board is
/// selected in the board's unplaced column, which scrolls to its row. Before,
/// the board selected nothing for it, and the column stayed where it was.
@MainActor
final class BoardUnplacedColumnSelectionTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        var state: State
        @State private var board: HorizontalBoard
        @State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    /// R1 on the board, and sixty parts, R100 to R159, with none: far more
    /// than the column shows at once in a 600 pt window.
    private func fixture() -> HorizontalBoard {
        let start = HorizontalPoint(x: 10_000_000, y: 10_000_000)
        let half = 300_000.0
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/unplaced.hprj"), uuid: "b", name: "unplaced",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: start, angle: 0, mirrored: false, label: "R1", componentID: "placed")],
            packagePads: [HorizontalPolygon(id: "pkg/pad/a", vertices: [
                .init(x: start.x - half, y: start.y - half), .init(x: start.x + half, y: start.y - half),
                .init(x: start.x + half, y: start.y + half), .init(x: start.x - half, y: start.y + half),
            ], layer: HorizontalBoardLayers.topCopper, netID: nil)],
            packageHoles: [], packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [],
            texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.placeableObjects = [HorizontalUnplacedObject(id: "placed", label: "R1", subtitle: "", componentID: "placed", gateID: nil)]
            + (0..<60).map { index in
                HorizontalUnplacedObject(id: "unplaced-\(index)", label: "R\(100 + index)", subtitle: "", componentID: "c\(index)", gateID: nil)
            }
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// The scroll view whose content is taller than it: the column's list.
    private func column(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.frame.height > scroll.contentView.bounds.height + 1 {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.column(in: $0) }.first
    }

    private func mount(_ state: State) async throws -> (NSWindow, NSView) {
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
        addTeardownBlock { @MainActor in window.close() }
        let mounted = await settle { state.actions != nil && self.column(in: hosted) != nil }
        XCTAssertTrue(mounted, "the canvas and its unplaced column are up")
        return (window, hosted)
    }

    func testAPartNotOnTheBoardIsSelectedInTheColumnAndScrolledTo() async throws {
        let state = State(fixture())
        let (_, hosted) = try await mount(state)
        let scroll = try XCTUnwrap(column(in: hosted))
        func offset() -> CGFloat { scroll.contentView.bounds.origin.y }
        // The furthest down it scrolls; a row is brought into view as little
        // as shows it, so the last row shows with the list's 5 pt inset still
        // below it, and the first with it above.
        func bottom() -> CGFloat { (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height }
        XCTAssertEqual(offset(), 0, accuracy: 0.5, "the column starts at its top")
        XCTAssertGreaterThan(bottom(), 500, "precondition: the list scrolls")

        XCTAssertEqual(state.actions?.selectComponents?(["c59"]), true, "the column's row is the board's selection")
        let scrolled = await settle { offset() >= bottom() - 6 }
        XCTAssertTrue(scrolled, "the column scrolls down to R159, at \(offset()) of \(bottom())")
        XCTAssertEqual(state.actions?.selectComponents?(["c59"]), false, "already the selection")

        // A placed part takes the selection back to its package, and the
        // column stays where it is.
        let resting = offset()
        XCTAssertEqual(state.actions?.selectComponents?(["placed"]), true)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(offset(), resting, accuracy: 0.5)

        // The first of several, as the column sorts them, is the one picked:
        // R100, under R1 at the top.
        XCTAssertEqual(state.actions?.selectComponents?(["c3", "c0"]), true)
        let back = await settle { offset() <= 6 }
        XCTAssertTrue(back, "the column scrolls back up to R100, at \(offset())")
        XCTAssertGreaterThan(offset(), 0, "as little as shows it: R1 above it is scrolled off")
    }

    /// The schematic keeps its selection from the board's packages, but what
    /// it picks that has no package is picked in the column, which scrolls to
    /// it, and goes again when the schematic picks something else. A package
    /// the board has selected itself stays selected.
    func testTheSchematicsPickOfAPartNotOnTheBoardIsPickedInTheColumn() async throws {
        let state = State(fixture())
        let (_, hosted) = try await mount(state)
        let scroll = try XCTUnwrap(column(in: hosted))
        func offset() -> CGFloat { scroll.contentView.bounds.origin.y }
        func bottom() -> CGFloat { (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height }

        XCTAssertEqual(state.actions?.selectUnplacedComponents?(["placed", "c59"]), true, "R159 has no package: the column picks it")
        let scrolled = await settle { offset() >= bottom() - 6 }
        XCTAssertTrue(scrolled, "the column scrolls down to R159, at \(offset()) of \(bottom())")
        XCTAssertEqual(state.actions?.selectUnplacedComponents?(["c59"]), false, "already picked")

        XCTAssertEqual(state.actions?.selectUnplacedComponents?(["placed"]), true, "R1 is placed: R159's pick goes")
        XCTAssertEqual(state.actions?.selectUnplacedComponents?([]), false, "nothing left to drop")

        // The board's own selection of R1's package is left alone by a
        // schematic pick with nothing unplaced in it.
        XCTAssertEqual(state.actions?.selectComponents?(["placed"]), true)
        XCTAssertEqual(state.actions?.selectUnplacedComponents?(["placed"]), false)
        XCTAssertEqual(state.actions?.selectUnplacedComponents?([]), false)
        XCTAssertEqual(state.actions?.selectComponents?(["placed"]), false, "R1's package is still the board's selection")
    }
}
#endif
