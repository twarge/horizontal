#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Add Vertex (K) on a board polygon's edge, as Horizon's: each click puts a
/// vertex where it is and the next follows the cursor, and Return, Esc or a
/// double-click ends it, keeping what was placed, as one undo step.
@MainActor
final class BoardPolygonAddVertexTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var details = HorizontalSelectionDetailState.empty
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
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private var center: HorizontalPoint { HorizontalPoint(x: 15 * mm, y: 15 * mm) }

    private func hexagon() -> [HorizontalPoint] {
        (0..<6).map { k in
            let angle = Double(k) * .pi / 3
            return HorizontalPoint(x: center.x + 10 * mm * cos(angle), y: center.y + 10 * mm * sin(angle))
        }
    }

    private func board() -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board(polygons: [
            HorizontalPolygon(id: "hexagon", vertices: hexagon(), layer: HorizontalBoardLayers.topCopper),
        ])
        let extent = HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 30 * mm, y: 30 * mm)])
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
        var state: State
        /// A world point where the canvas draws it (top left).
        var at: (HorizontalPoint) -> CGPoint
        var click: (HorizontalPoint, Int) -> Void
        var move: (HorizontalPoint) throws -> Void
        var key: (UInt16, String) throws -> Void
    }

    /// The hexagon's edge 2, v2–v3, selected and K pressed on it.
    private func addingVertices() async throws -> Mounted {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board())
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let up = await settle { state.actions?.visibleWorldBounds?() != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(up)
        let monitor = try XCTUnwrap(monitor(in: hosted))
        let visible = try XCTUnwrap(state.actions?.visibleWorldBounds?())
        let size = monitor.bounds.size
        let handle = monitor.makeEventHandler()
        let at: (HorizontalPoint) -> CGPoint = { world in
            CGPoint(x: (world.x - visible.minX) / visible.width * size.width,
                    y: (visible.maxY - world.y) / visible.height * size.height)
        }
        let mounted = Mounted(
            state: state,
            at: at,
            click: { world, count in
                let point = at(world)
                monitor.onPrimaryClick?(point, size, CGPoint(x: point.x, y: size.height - point.y), monitor, .replace, count)
            },
            move: { world in
                let point = at(world)
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .mouseMoved, location: monitor.convert(NSPoint(x: point.x, y: size.height - point.y), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0
                ))
                _ = handle(event)
            },
            key: { code, characters in
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                XCTAssertNil(handle(event), "the canvas takes \(characters)")
            }
        )
        let corners = hexagon()
        mounted.click(HorizontalPoint(x: (corners[2].x + corners[3].x) / 2, y: (corners[2].y + corners[3].y) / 2), 1)
        let picked = await settle {
            state.details.groups.filter { $0.type == .polygonEdge }.flatMap(\.items).map(\.ref.vertex) == [2]
        }
        XCTAssertTrue(picked, "edge 2 selected")
        try mounted.key(40, "k")
        let adding = await settle { state.actions?.canCancelInteraction == true }
        XCTAssertTrue(adding, "K starts Add Vertex")
        return mounted
    }

    private func vertices(_ board: HorizontalBoard?) -> [HorizontalPoint] {
        board?.polygons.first?.polygonVertices.map(\.position) ?? []
    }

    private func assertNear(_ point: HorizontalPoint?, _ expected: HorizontalPoint, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let point else {
            return XCTFail("no vertex: \(message)", file: file, line: line)
        }
        XCTAssertEqual(point.x, expected.x, accuracy: 0.6 * mm, message, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 0.6 * mm, message, file: file, line: line)
    }

    func testClicksAddVerticesIntoTheEdgeAndReturnKeepsThem() async throws {
        let canvas = try await addingVertices()
        let corners = hexagon()
        let first = HorizontalPoint(x: 6 * mm, y: 25 * mm)
        let second = HorizontalPoint(x: 3 * mm, y: 20 * mm)
        try canvas.move(first)
        canvas.click(first, 1)
        try canvas.move(HorizontalPoint(x: 4 * mm, y: 22 * mm))
        canvas.click(second, 1)
        XCTAssertTrue(canvas.state.committed.isEmpty, "nothing is edited until the tool ends")
        try canvas.key(36, "\r")

        let ended = await settle { !canvas.state.committed.isEmpty }
        XCTAssertTrue(ended, "Return ends it")
        let placed = vertices(canvas.state.committed.last)
        XCTAssertEqual(placed.count, 8, "two vertices into the edge, none at the cursor")
        assertNear(placed[safe: 2], corners[2], "v2 as it was")
        assertNear(placed[safe: 3], first, "the first click's vertex after v2")
        assertNear(placed[safe: 4], second, "and the second's after it")
        assertNear(placed[safe: 5], corners[3], "then v3")
        XCTAssertEqual(canvas.state.committed.count, 1, "one edit")
        XCTAssertEqual(canvas.state.undo.undoActionName, "Add Vertices")
        let selected = await settle {
            canvas.state.details.groups.filter { $0.type == .polygonVertex }.flatMap(\.items).map(\.ref.vertex) == [4]
        }
        XCTAssertTrue(selected, "the last vertex added is selected")
        XCTAssertEqual(canvas.state.actions?.canCancelInteraction, false, "and the tool is done")
    }

    func testADoubleClickPlacesItsVertexAndEnds() async throws {
        let canvas = try await addingVertices()
        let point = HorizontalPoint(x: 6 * mm, y: 25 * mm)
        try canvas.move(point)
        canvas.click(point, 1)
        canvas.click(point, 2)
        let ended = await settle { !canvas.state.committed.isEmpty }
        XCTAssertTrue(ended, "the double-click ends it")
        let placed = vertices(canvas.state.committed.last)
        XCTAssertEqual(placed.count, 7, "one vertex: the second click adds none")
        assertNear(placed[safe: 3], point, "where it was clicked")
        XCTAssertEqual(canvas.state.undo.undoActionName, "Add Vertex")
    }

    func testEscapeEndsItKeepingWhatWasPlacedAndNothingWhenNothingWas() async throws {
        let canvas = try await addingVertices()
        try canvas.move(HorizontalPoint(x: 6 * mm, y: 25 * mm))
        try canvas.key(53, "\u{1b}")
        let done = await settle { canvas.state.actions?.canCancelInteraction == false }
        XCTAssertTrue(done, "Esc ends the tool")
        XCTAssertTrue(canvas.state.committed.isEmpty, "with no click, the polygon is as it was")

        try canvas.key(40, "k")
        let again = await settle { canvas.state.actions?.canCancelInteraction == true }
        XCTAssertTrue(again, "K again, the edge still selected")
        let point = HorizontalPoint(x: 6 * mm, y: 25 * mm)
        try canvas.move(point)
        canvas.click(point, 1)
        try canvas.key(53, "\u{1b}")
        let ended = await settle { !canvas.state.committed.isEmpty }
        XCTAssertTrue(ended, "Esc keeps the vertex placed, as Return does")
        XCTAssertEqual(vertices(canvas.state.committed.last).count, 7)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
