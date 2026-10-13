import AppKit
import XCTest
@testable import HorizontalNative

/// What `WindowChromeConfigurator` does to a document window's title bar.
@MainActor
final class HorizontalWindowChromeTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    func testAPoolItemWindowKeepsFullSizeContentWithAnOpaqueTitleBar() {
        // Pool item editors used to drop .fullSizeContentView, and could then
        // be resized but not dragged by their title bar.
        let window = window()
        window.titlebarAppearsTransparent = true
        let view = WindowChromeConfigurator.ConfiguringView()
        view.isTransparent = true
        view.usesStandardTitleBar = true
        window.contentView?.addSubview(view)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.titlebarAppearsTransparent, "an editor's title bar ignores the Transparent Toolbar preference")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    func testACanvasWindowFollowsTheTransparentToolbarPreference() {
        let window = window()
        let view = WindowChromeConfigurator.ConfiguringView()
        view.isTransparent = true
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.titlebarAppearsTransparent)

        view.isTransparent = false
        view.configureWindow()
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    }
}
