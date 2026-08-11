import XCTest
@testable import HorizontalNative

/// Tests the pure layer-style resolution extracted from BoardCanvasView's metal
/// batcher: per-layer composite groups and a via's spanned copper layers.
final class BoardLayerStyleTests: XCTestCase {
    func testCompositeGroupIsLayerPlusOffset() {
        XCTAssertEqual(BoardLayerStyle.compositeGroup(for: 0), 1_000_000)
        XCTAssertEqual(BoardLayerStyle.compositeGroup(for: -1), 999_999)
        XCTAssertEqual(BoardLayerStyle.compositeGroup(for: HorizontalBoardLayers.bottomCopper), 1_000_000 + HorizontalBoardLayers.bottomCopper)
        // Always > 0 (group 0 is the non-composited main pass) for real layers.
        XCTAssertGreaterThan(BoardLayerStyle.compositeGroup(for: HorizontalBoardLayers.bottomCopper), 0)
    }

    func testViaLayersFallBackToOwnLayerWhenNoConnectedLayers() {
        let via = HorizontalMarker(id: "v", position: .zero, size: 200, layer: HorizontalBoardLayers.topCopper)
        XCTAssertEqual(BoardLayerStyle.renderedViaLayers(for: via), [HorizontalBoardLayers.topCopper])
    }

    func testViaLayersUseConnectedLayersCopperOnlySorted() {
        let via = HorizontalMarker(
            id: "v", position: .zero, size: 200, layer: HorizontalBoardLayers.topCopper,
            connectedLayers: [HorizontalBoardLayers.topCopper, 10 /* mask, non-copper */, HorizontalBoardLayers.bottomCopper, -1])
        // Mask layer filtered out; copper layers sorted ascending.
        XCTAssertEqual(
            BoardLayerStyle.renderedViaLayers(for: via),
            [HorizontalBoardLayers.bottomCopper, -1, HorizontalBoardLayers.topCopper])
    }

    func testViaLayersEmptyWhenOnlyNonCopper() {
        let via = HorizontalMarker(id: "v", position: .zero, size: 200, layer: 0, connectedLayers: [10, 20, 30])
        XCTAssertTrue(BoardLayerStyle.renderedViaLayers(for: via).isEmpty)
    }
}
