#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A trackpad scroll over the board pans it unless the pointer is over the
/// unplaced column, whose list it scrolls; which it is comes from where the
/// column is drawn. It came from the column's hover, which a column that went
/// away or came back under the pointer, as placing a part and Clear All
/// Planes (⇧Q) halfway through do, could leave set: the canvas then passed
/// every scroll on, and the trackpad panned nothing while a pinch still zoomed.
@MainActor
final class BoardCanvasOverlayScrollTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        var poolURL: URL
        var actions: HorizontalCanvasCommandActions?
        @Published var syncRevision = 0
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard, poolURL: URL) { source = board; self.poolURL = poolURL }
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
                onBoardChange: { board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings,
                syncRevision: state.syncRevision,
                poolURL: state.poolURL)
        }
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

    private func renderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer { return renderer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    /// A canvas mounted on the fixture's board with R1 and R2 placed and R3,
    /// the one part left, in the unplaced column; its event handler, and a
    /// trackpad scroll at a point in canvas coordinates (top left, points)
    /// handed to it, returning whether the canvas took it.
    @MainActor private struct Mounted {
        var window: NSWindow
        var hosted: NSView
        var monitor: TrackpadCanvasMonitor.MonitorView
        var renderer: HorizontalMetalBackdropView.Renderer
        var scroll: (CGPoint) throws -> Bool
        var r3: HorizontalUnplacedObject
        /// What the canvas draws the board at, which a pan moves at once.
        var drawnPan: CGSize { renderer.frame.viewport.pan }
    }

    private func mount(_ state: inout State?) async throws -> Mounted {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        // AppKit makes no scroll event at a place in a window, so the event is
        // given its window (field 51) and its place there as the window
        // server gives them.
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"),
              let windowField = CGEventField(rawValue: 51) else {
            throw XCTSkip("no way to place a scroll event in a window")
        }
        let setWindowLocation = unsafeBitCast(symbol, to: SetWindowLocation.self)

        let fixture = try BlockLayoutFixture(instances: 1, placeParts: false)
        let instance = try XCTUnwrap(fixture.instances.first)
        try fixture.apply([
            ["op": "place_component", "component": fixture.flat(instance, "R1"), "x_mm": 0, "y_mm": 0],
            ["op": "place_component", "component": fixture.flat(instance, "R2"), "x_mm": 5, "y_mm": 0],
        ])
        let board = try fixture.board
        let r3 = try XCTUnwrap(board.unplacedObjects.first)
        XCTAssertEqual(board.unplacedObjects.map(\.label), ["R3"], "precondition: R3 alone is unplaced")
        let poolURL = try XCTUnwrap(fixture.project.poolDirectory.map { fixture.project.baseURL.appendingPathComponent($0) })
        let made = State(board, poolURL: poolURL)
        state = made

        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: made)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let mounted = await settle {
            made.actions != nil && self.monitor(in: hosted)?.overlayFrames.isEmpty == false && self.renderer(in: hosted) != nil
        }
        XCTAssertTrue(mounted, "the canvas, with the unplaced column on it")
        let monitor = try XCTUnwrap(monitor(in: hosted))
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let handle = monitor.makeEventHandler()
        let scroll: (CGPoint) throws -> Bool = { canvasPoint in
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 20, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(windowField, value: Int64(window.windowNumber))
            let inWindow = monitor.convert(NSPoint(x: canvasPoint.x, y: monitor.bounds.height - canvasPoint.y), to: nil)
            setWindowLocation(event, CGPoint(x: inWindow.x, y: window.frame.height - inWindow.y))
            let scroll = try XCTUnwrap(NSEvent(cgEvent: event))
            XCTAssertTrue(scroll.hasPreciseScrollingDeltas, "a trackpad's scroll")
            return handle(scroll) == nil
        }
        return Mounted(window: window, hosted: hosted, monitor: monitor, renderer: renderer, scroll: scroll, r3: r3)
    }

    private func middle(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Over the column, a scroll is the column's; anywhere else on the board
    /// it pans, at once.
    func testAScrollOverTheUnplacedColumnIsTheColumnsAndOneElsewherePans() async throws {
        var state: State?
        let canvas = try await mount(&state)
        let column = try XCTUnwrap(canvas.monitor.overlayFrames.first)
        XCTAssertGreaterThan(column.width, 100, "the column is the panel, not the canvas: \(column)")
        XCTAssertLessThan(column.width, canvas.monitor.bounds.width / 2)
        let board = CGPoint(x: canvas.monitor.bounds.width * 0.75, y: canvas.monitor.bounds.height / 2)
        XCTAssertFalse(column.contains(board))

        let atRest = canvas.drawnPan
        XCTAssertTrue(try canvas.scroll(board), "the board takes a scroll over it")
        XCTAssertNotEqual(canvas.drawnPan, atRest, "and pans")

        let panned = canvas.drawnPan
        XCTAssertFalse(try canvas.scroll(middle(of: column)), "a scroll over the column is left to it")
        XCTAssertEqual(canvas.drawnPan, panned, "and the board stays put")
    }

    /// The report: placing a part, and Clear All Planes halfway through,
    /// which replaces the board under the canvas and drops the placement.
    /// Placing the last part takes the column away, so the trackpad pans
    /// where it was; the part comes back with the board, and the column with
    /// it, and the trackpad still pans the board anywhere but over the
    /// column.
    func testPlacingTheLastPartThenClearingThePlanesLeavesTheTrackpadPanning() async throws {
        var state: State?
        let canvas = try await mount(&state)
        let host = try XCTUnwrap(state)
        let column = try XCTUnwrap(canvas.monitor.overlayFrames.first)
        let board = CGPoint(x: canvas.monitor.bounds.width * 0.75, y: canvas.monitor.bounds.height / 2)

        host.actions?.pickUnplacedObject?(canvas.r3.id)
        let placing = await settle { host.actions?.canCancelInteraction == true && canvas.monitor.overlayFrames.isEmpty }
        XCTAssertTrue(placing, "placing R3, the column gone with the last part")

        var before = canvas.drawnPan
        XCTAssertTrue(try canvas.scroll(board), "the board takes a scroll while a part is placed")
        XCTAssertNotEqual(canvas.drawnPan, before)
        before = canvas.drawnPan
        XCTAssertTrue(try canvas.scroll(middle(of: column)), "and one where the column was")
        XCTAssertNotEqual(canvas.drawnPan, before)

        // What Clear All Planes does to the canvas: the board replaced.
        host.syncRevision += 1
        let dropped = await settle {
            host.actions?.canCancelInteraction == false && canvas.monitor.overlayFrames.count == 1
        }
        XCTAssertTrue(dropped, "the placement goes, and R3 comes back to the column")

        for point in [board, CGPoint(x: board.x, y: column.maxY + 40)] {
            before = canvas.drawnPan
            XCTAssertTrue(try canvas.scroll(point), "the board takes a scroll at \(point) again")
            XCTAssertNotEqual(canvas.drawnPan, before, "and pans")
        }
        before = canvas.drawnPan
        XCTAssertFalse(try canvas.scroll(middle(of: try XCTUnwrap(canvas.monitor.overlayFrames.first))), "the column's is its own again")
        XCTAssertEqual(canvas.drawnPan, before)
    }
}
#endif
