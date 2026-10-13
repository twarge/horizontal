#if os(macOS)
import AppKit
import XCTest
@testable import HorizontalNative

/// The keyboard goes to a text field or to a canvas, never both: a click on the
/// canvas takes it from a pane's search field, and while a field has it the
/// canvas's keyboard-focus badge stands down (Billo, 2026-10-13).
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

    func testWorkspaceReportsWhenATextFieldHasTheKeyboard() throws {
        _ = NSApplication.shared
        let monitor = WorkspaceKeyCommandMonitor.KeyCommandMonitorView(frame: .zero)
        let field = NSTextField(frame: NSRect(x: 20, y: 130, width: 160, height: 24))
        var reports: [Bool] = []
        monitor.onTextInputFocusChange = { reports.append($0) }
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
    }
}
#endif
