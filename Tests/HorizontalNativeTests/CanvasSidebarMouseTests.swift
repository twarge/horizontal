#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The leading pane's canvas runs under the sidebar, and its event monitor sees
/// every click in its bounds before the window does (120). A click over the
/// sidebar is the sidebar's: a right-click there opens a row's context menu
/// rather than the canvas's, and no click there takes the keyboard. Before, the
/// monitor left only the strip under the toolbar alone, so it took a sheet
/// row's right-click and nothing opened.
@MainActor
final class CanvasSidebarMouseTests: XCTestCase {
    @MainActor private final class State {
        var actions: HorizontalCanvasCommandActions?
        var focusRequests = 0
        let toolSettings = HorizontalBoardToolSettings()
    }

    private static let sidebarWidth: CGFloat = 200

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: CanvasSidebarMouseTests.board(), viewport: $viewport, displayOptions: BoardDisplayOptions(),
                fitSafeAreaInsets: EdgeInsets(top: 0, leading: CanvasSidebarMouseTests.sidebarWidth, bottom: 0, trailing: 0),
                onCanvasCommandActionsChange: { state.actions = $0 },
                onRequestKeyboardFocus: { state.focusRequests += 1 },
                toolSettings: state.toolSettings)
        }
    }

    private static func board() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/sidebar.hprj"), uuid: "b", name: "sidebar",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
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

    func testAClickOverTheSidebarIsTheSidebarsAndOneOverTheCanvasIsTheCanvass() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State()
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
        let monitorView = try XCTUnwrap(monitor(in: hosted))
        let handle = monitorView.makeEventHandler()
        let ready = await settle { monitorView.mouseExclusionInsets.leading == Self.sidebarWidth }
        XCTAssertTrue(ready, "the canvas leaves the sidebar's strip alone")

        func click(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent? {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return handle(event)
        }

        XCTAssertNotNil(try click(.rightMouseDown, x: Self.sidebarWidth / 2), "a right-click over the sidebar reaches its row")
        XCTAssertNotNil(try click(.leftMouseDown, x: Self.sidebarWidth / 2))
        XCTAssertEqual(state.focusRequests, 0, "a click over the sidebar does not give the canvas the keyboard")

        XCTAssertNil(try click(.rightMouseDown, x: Self.sidebarWidth + 300), "the canvas takes its own right-click")
        XCTAssertEqual(state.focusRequests, 1)
    }
}
#endif
