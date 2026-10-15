#if os(macOS)
import AppKit
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
