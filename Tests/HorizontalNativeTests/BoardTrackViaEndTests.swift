#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// V, then a double-click, ends a route at the via the first click drops and
/// leaves the board on the layer the route was on, for a via down to a plane
/// on another layer: the next route starts where this one did. A single click
/// still carries the route on on the far layer.
@MainActor
final class BoardTrackViaEndTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var drawingLayer = HorizontalBoardLayers.topCopper
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
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
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings,
                drawingLayer: state.drawingLayer,
                onSelectDrawingLayer: { state.drawingLayer = $0 })
        }
    }

    /// A two-layer board with a via a route drops on V.
    private func board() -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.viaTemplate = HorizontalBoardViaTemplate(padstackID: "via-padstack", diameter: 500_000, holeDiameter: 250_000)
        // 50 mm across, for the canvas to fit and a click to land somewhere.
        let extent = HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 50_000_000, y: 50_000_000)])
        board.bounds = extent
        board.physicalBounds = extent
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

    private struct Mounted {
        var window: NSWindow
        var monitor: TrackpadCanvasMonitor.MonitorView
        /// A click resolved at a point in the canvas (top left), as the
        /// canvas's own gesture resolves one, with its click count.
        var click: (CGPoint, HorizontalSelectionClickAction, Int) -> Void
        var key: (UInt16, String) throws -> Void
    }

    private func mount(_ state: State) async throws -> Mounted {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let monitor = try XCTUnwrap(monitor(in: hosted))
        let handle = monitor.makeEventHandler()
        return Mounted(
            window: window,
            monitor: monitor,
            click: { point, action, count in
                monitor.onPrimaryClick?(point, monitor.bounds.size, CGPoint(x: point.x, y: monitor.bounds.height - point.y), monitor, action, count)
            },
            key: { code, characters in
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                XCTAssertNil(handle(event), "the canvas takes \(characters)")
            }
        )
    }

    /// The tool's route lays a track to a point with a via armed (V): the
    /// via goes there and the board turns to the far layer.
    private func routeToAVia(_ canvas: Mounted, _ state: State) async throws -> CGPoint {
        state.actions?.dispatch(.drawTrack)
        let armed = await settle { state.actions?.canFlipTrackPosture == true }
        XCTAssertTrue(armed, "the track tool")
        let size = canvas.monitor.bounds.size
        // ⌘-click: a route starts anywhere, not only on copper.
        canvas.click(CGPoint(x: size.width * 0.4, y: size.height * 0.5), .toggle, 1)
        try canvas.key(9, "v")
        let end = CGPoint(x: size.width * 0.6, y: size.height * 0.5)
        canvas.click(end, .replace, 1)
        let turned = await settle { state.drawingLayer == HorizontalBoardLayers.bottomCopper }
        XCTAssertTrue(turned, "the via took the route, and the board, to the bottom")
        return end
    }

    func testADoubleClickOnTheViaEndsTheRouteThereOnTheLayerItWasOn() async throws {
        let state = State(board())
        XCTAssertNotNil(state.source.routeVia(netID: nil), "precondition: the board has a via to drop")
        let canvas = try await mount(state)
        let end = try await routeToAVia(canvas, state)

        canvas.click(end, .replace, 2)
        let ended = await settle { !state.committed.isEmpty }

        XCTAssertTrue(ended, "the double-click ends the route")
        let board = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(board.vias.count - state.source.vias.count, 1, "with the via at its end")
        XCTAssertEqual(board.tracks.count - state.source.tracks.count, 1, "and the one track to it")
        let back = await settle { state.drawingLayer == HorizontalBoardLayers.topCopper }
        XCTAssertTrue(back, "back on the top, the layer the route was on")
        XCTAssertEqual(state.actions?.canFlipTrackPosture, true, "the tool waits for the next route")
    }

    func testAClickAfterTheViaCarriesTheRouteOnOnTheFarLayer() async throws {
        let state = State(board())
        let canvas = try await mount(state)
        let end = try await routeToAVia(canvas, state)

        let size = canvas.monitor.bounds.size
        let further = CGPoint(x: end.x, y: size.height * 0.3)
        canvas.click(further, .replace, 1)
        canvas.click(further, .replace, 2)
        let ended = await settle { !state.committed.isEmpty }
        XCTAssertTrue(ended)
        let board = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(board.tracks.count - state.source.tracks.count, 2, "a track on each side of the via")
        XCTAssertTrue(board.tracks.contains { $0.layer == HorizontalBoardLayers.bottomCopper }, "the second on the bottom")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.drawingLayer, HorizontalBoardLayers.bottomCopper, "a route that went on past the via stays on its layer")
    }

    /// A double-click is AppKit's, counted from when the clicks happened:
    /// the via click turns the board to another layer, which can keep the
    /// main thread busy past the double-click interval, and the second click,
    /// timed when it was handled, came in as a single and carried the route
    /// on instead of ending it. The canvas takes the mouse event's count.
    /// (A test process's canvas takes no mouse events, so the count is
    /// checked on its own.)
    func testTheMouseEventsCountIsTheCanvassClickCount() throws {
        func mouse(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)
        }
        XCTAssertEqual(HorizontalCanvasInputView.clickCount(of: mouse(.leftMouseUp, 1)), 1)
        XCTAssertEqual(HorizontalCanvasInputView.clickCount(of: mouse(.leftMouseUp, 2)), 2)
        XCTAssertEqual(HorizontalCanvasInputView.clickCount(of: mouse(.leftMouseUp, 3)), 1, "a third click is a single, as the canvas counted it")
        XCTAssertEqual(HorizontalCanvasInputView.clickCount(of: mouse(.leftMouseDown, 4)), 2)
        XCTAssertNil(HorizontalCanvasInputView.clickCount(of: mouse(.mouseMoved, 0)), "not a click: the timing decides")
        XCTAssertNil(HorizontalCanvasInputView.clickCount(of: mouse(.rightMouseUp, 1)))
        XCTAssertNil(HorizontalCanvasInputView.clickCount(of: nil))
    }
}
#endif
