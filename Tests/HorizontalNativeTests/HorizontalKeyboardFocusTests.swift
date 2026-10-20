#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The keyboard goes to a text field or to a canvas, never both: a click on the
/// canvas takes it from a pane's search field, and while a field has it the
/// canvas's keyboard-focus badge stands down (Billo, 2026-10-13). A list with
/// the keyboard, such as the Pools pane's table, is treated the same (128).
@MainActor
final class HorizontalKeyboardFocusTests: XCTestCase {
    private func window(with views: [NSView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        views.forEach(container.addSubview)
        window.contentView = container
        return window
    }

    private func click(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testClickOnTheCanvasTakesTheKeyboardFromATextField() throws {
        _ = NSApplication.shared
        let canvas = TrackpadCanvasMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let field = NSTextField(frame: NSRect(x: 220, y: 130, width: 160, height: 24))
        let window = window(with: [canvas, field])
        defer { window.close() }
        var focusRequests = 0
        canvas.onRequestKeyboardFocus = { focusRequests += 1 }
        let handle = canvas.makeEventHandler()

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder is NSTextView, "the field editor has the keyboard")
        _ = handle(try click(at: NSPoint(x: 100, y: 150), in: window))
        XCTAssertTrue(window.firstResponder === canvas)
        XCTAssertEqual(focusRequests, 1)

        // A text view drawn over the canvas keeps the keyboard when clicked.
        let overlay = NSTextView(frame: NSRect(x: 20, y: 20, width: 80, height: 40))
        canvas.addSubview(overlay)
        XCTAssertTrue(window.makeFirstResponder(overlay))
        _ = handle(try click(at: NSPoint(x: 40, y: 40), in: window))
        XCTAssertTrue(window.firstResponder === overlay)
    }

    private func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func downArrow(in window: NSWindow) throws -> NSEvent {
        try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, in: window)
    }

    /// A table in a scroll view, as SwiftUI's `Table` puts one in a pane.
    private func table(rows: Int, frame: NSRect) -> (NSScrollView, NSTableView) {
        final class Rows: NSObject, NSTableViewDataSource {
            let count: Int
            init(_ count: Int) { self.count = count }
            func numberOfRows(in tableView: NSTableView) -> Int { count }
            func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Row \(row)" }
        }
        let table = NSTableView(frame: NSRect(origin: .zero, size: frame.size))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        let source = Rows(rows)
        table.dataSource = source
        objc_setAssociatedObject(table, "rows", source, .OBJC_ASSOCIATION_RETAIN)
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = table
        table.reloadData()
        return (scroll, table)
    }

    /// 128: a list elsewhere with the keyboard, such as the Pools pane's
    /// table, takes its arrows, letters and Delete, even while a canvas pane
    /// holds the keyboard focus. Before, the canvas's monitor took them first:
    /// Down nudged the canvas's selection and the table never moved.
    func testAListWithTheKeyboardTakesItsOwnKeysFromAFocusedCanvas() throws {
        _ = NSApplication.shared
        let canvas = TrackpadCanvasMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let (scroll, table) = table(rows: 5, frame: NSRect(x: 220, y: 20, width: 160, height: 260))
        let window = window(with: [canvas, scroll])
        defer { window.close() }
        var nudges = 0
        var commands = [HorizontalCanvasCommand]()
        canvas.hasKeyboardFocus = true
        canvas.onMoveSelectionByGrid = { _, _ in nudges += 1 }
        canvas.onCommand = { commands.append($0) }
        let handle = canvas.makeEventHandler()

        // With nothing else holding the keyboard, the canvas takes Down.
        XCTAssertNil(handle(try downArrow(in: window)))
        XCTAssertEqual(nudges, 1)

        XCTAssertTrue(window.makeFirstResponder(table))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let down = try downArrow(in: window)
        XCTAssertNotNil(handle(down), "the table's Down is the table's")
        XCTAssertNotNil(handle(try key("r", keyCode: 15, in: window)), "and so are its letters")
        XCTAssertNotNil(handle(try key(String(UnicodeScalar(NSDeleteCharacter)!), keyCode: 51, in: window)), "and Delete")
        XCTAssertEqual(nudges, 1)
        XCTAssertTrue(commands.isEmpty)
        window.sendEvent(down)
        XCTAssertEqual(table.selectedRow, 1, "the arrow moved the table's selection")

        // An interaction in progress still takes its own keys.
        canvas.handlesInteractionKeys = true
        XCTAssertNil(handle(try key("\u{1b}", keyCode: 53, in: window)))
        XCTAssertEqual(commands.count, 1)
        guard case .cancelInteraction? = commands.first else {
            return XCTFail("Escape cancels the interaction: \(commands)")
        }
    }

    /// The same for a SwiftUI `Table`, which is what the Pools pane shows: it
    /// is an `NSTableView` underneath, so the canvas leaves it its keys.
    func testASwiftUITableIsAListThatTakesItsOwnKeys() async throws {
        _ = NSApplication.shared
        struct Rows: View {
            struct Row: Identifiable { var id: Int }
            @State var selection: Int? = 0
            var body: some View {
                Table((0..<5).map(Row.init), selection: $selection) {
                    TableColumn("Row") { Text("Row \($0.id)") }
                }
            }
        }
        let hosted = NSHostingView(rootView: Rows())
        hosted.frame = NSRect(x: 220, y: 20, width: 160, height: 260)
        let canvas = TrackpadCanvasMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let window = window(with: [canvas, hosted])
        defer { window.close() }
        window.orderFront(nil)
        func find(_ view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap(find).first
        }
        var swiftUITable: NSTableView?
        let deadline = Date().addingTimeInterval(3)
        while swiftUITable?.numberOfRows != 5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            swiftUITable = find(hosted)
        }
        let table = try XCTUnwrap(swiftUITable)
        XCTAssertTrue(table.isKeyboardList)
        var nudges = 0
        canvas.onMoveSelectionByGrid = { _, _ in nudges += 1 }
        XCTAssertTrue(window.makeFirstResponder(table))
        let down = try downArrow(in: window)
        XCTAssertNotNil(canvas.makeEventHandler()(down))
        XCTAssertEqual(nudges, 0)
        window.sendEvent(down)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 1, "the SwiftUI table's selection moved")
    }

    /// A click on the canvas takes the keyboard back from a list, as it does
    /// from a field, so the canvas's keys work again; a click on the list
    /// leaves it there. An interaction started from the list, as Place's
    /// double-click starts one, takes the keyboard as it does from a field.
    func testTheCanvasTakesTheKeyboardBackFromAList() async throws {
        _ = NSApplication.shared
        let canvas = TrackpadCanvasMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let (scroll, table) = table(rows: 5, frame: NSRect(x: 220, y: 20, width: 160, height: 260))
        let window = window(with: [canvas, scroll])
        defer { window.close() }
        let handle = canvas.makeEventHandler()

        XCTAssertTrue(window.makeFirstResponder(table))
        _ = handle(try click(at: NSPoint(x: 300, y: 150), in: window))
        XCTAssertTrue(window.firstResponder === table, "a click on the list is the list's")
        _ = handle(try click(at: NSPoint(x: 100, y: 150), in: window))
        XCTAssertTrue(window.firstResponder === canvas)

        XCTAssertTrue(window.makeFirstResponder(table))
        canvas.handlesInteractionKeys = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(window.firstResponder === canvas, "the interaction has the keyboard")
    }

    private final class DocumentState: ObservableObject {
        @Published var document = HorizontalProjectDocument()
    }

    private struct Workspace: View {
        @ObservedObject var state: DocumentState
        var project: HorizontalProject
        @State var panes: Set<HorizontalPane> = [.board, .schematic]
        @State var nets = Set<String>()
        @State var highlightedNets = Set<String>()
        @State var components = Set<String>()
        @State var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $state.document, visiblePanes: $panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents)
        }
    }

    /// 128 gives a focused list its keys, which would leave the canvases
    /// without theirs if a window opened with its navigator focused. It
    /// doesn't: the window's first responder is SwiftUI's hosting view, which
    /// keeps it when the window becomes key rather than passing it to the
    /// navigator's outline, and the outline is in the key view loop only with
    /// Keyboard Navigation on. Without it the loop holds just the canvases.
    func testAProjectWindowOpensWithNoListHoldingTheKeyboard() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvases") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("initial-focus-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = DocumentState()
        state.document.archive = try HorizontalProjectArchive.snapshot(from: root)
        let project = try HorizontalProject.load(from: root)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "initial-focus-\(UUID().uuidString)"))
        let hosted = NSHostingView(rootView: Workspace(state: state, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func lists(_ view: NSView) -> [NSTableView] { ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(lists) }
        let deadline = Date().addingTimeInterval(10)
        while lists(hosted).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let navigator = try XCTUnwrap(lists(hosted).first, "the navigator's outline")
        // The canvases come up after the navigator, once their sheet and board
        // load; a slow machine probes the key-view loop before they are there,
        // and finds it empty.
        func canvases(_ view: NSView) -> [TrackpadCanvasMonitor.MonitorView] {
            ((view as? TrackpadCanvasMonitor.MonitorView).map { [$0] } ?? []) + view.subviews.flatMap(canvases)
        }
        while !canvases(hosted).contains(where: { !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(canvases(hosted).isEmpty, "the canvases are up")

        // What the window does when it first becomes key: its initial first
        // responder takes the keyboard, and SwiftUI hears the window is key.
        let initial = try XCTUnwrap(window.initialFirstResponder)
        XCTAssertTrue(initial === hosted)
        XCTAssertTrue(window.makeFirstResponder(initial))
        window.becomeKey()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(window.firstResponder?.isKeyboardList ?? false,
                       "the window opens with \(String(describing: window.firstResponder)) holding the keyboard")
        XCTAssertFalse(window.firstResponder === navigator)

        if !NSApp.isFullKeyboardAccessEnabled {
            XCTAssertFalse(navigator.canBecomeKeyView, "without Keyboard Navigation the outline takes the keyboard only from a click")
            XCTAssertTrue(window.makeFirstResponder(nil))
            window.selectNextKeyView(nil)
            // What the loop holds, so a failure on a machine this passes
            // elsewhere on says what came first instead.
            var chain = [String]()
            var view = window.firstResponder as? NSView
            for _ in 0..<6 {
                chain.append(view.map { NSStringFromClass(type(of: $0)) } ?? "nil")
                view = view?.nextValidKeyView
            }
            XCTAssertTrue(window.firstResponder is TrackpadCanvasMonitor.MonitorView,
                          "the first key view is a canvas, not \(String(describing: window.firstResponder)); loop \(chain), sheet \(String(describing: window.attachedSheet))")
        }
    }

    func testWorkspaceReportsWhenATextFieldHasTheKeyboard() throws {
        _ = NSApplication.shared
        let monitor = WorkspaceKeyCommandMonitor.KeyCommandMonitorView(frame: .zero)
        let field = NSTextField(frame: NSRect(x: 20, y: 130, width: 160, height: 24))
        var reports: [Bool] = []
        monitor.onControlKeyboardFocusChange = { reports.append($0) }
        let window = window(with: [monitor, field])
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        settle()
        XCTAssertEqual(reports, [false])
        XCTAssertTrue(window.makeFirstResponder(field))
        settle()
        XCTAssertEqual(reports, [false, true])
        XCTAssertTrue(window.makeFirstResponder(nil))
        settle()
        XCTAssertEqual(reports, [false, true, false])

        // A list with the keyboard stands the canvas's badge down too (128).
        let (scroll, table) = table(rows: 3, frame: NSRect(x: 200, y: 20, width: 160, height: 100))
        window.contentView?.addSubview(scroll)
        XCTAssertTrue(window.makeFirstResponder(table))
        settle()
        XCTAssertEqual(reports, [false, true, false, true])
    }
}
#endif
