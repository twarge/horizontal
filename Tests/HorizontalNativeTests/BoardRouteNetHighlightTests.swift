import XCTest
@testable import HorizontalNative

/// A route under way highlights the net it connects, on top of the window's
/// highlight, and only while it lasts.
@MainActor
final class BoardRouteNetHighlightTests: XCTestCase {
    func testTheRouteAddsItsNetToTheWindowsHighlight() {
        let shown = BoardCanvasView.shownHighlightNetIDs(window: ["gnd"], routeNetID: "VCC")
        XCTAssertEqual(shown, ["gnd", "vcc"], "the route's net is matched as the window's are, lowercased")
    }

    func testARouteOnNoNetHighlightsNothingOfItsOwn() {
        XCTAssertEqual(BoardCanvasView.shownHighlightNetIDs(window: [], routeNetID: nil), [])
        XCTAssertEqual(BoardCanvasView.shownHighlightNetIDs(window: ["gnd"], routeNetID: nil), ["gnd"])
    }

    func testARouteOnTheHighlightedNetLeavesTheHighlightAsItIs() {
        XCTAssertEqual(BoardCanvasView.shownHighlightNetIDs(window: ["gnd"], routeNetID: "GND"), ["gnd"])
    }
}
