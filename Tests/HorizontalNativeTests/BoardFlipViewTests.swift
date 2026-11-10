import XCTest
@testable import HorizontalNative

/// View ▸ Flip Board View and F on the board canvas (`HorizontalBoardViewState`):
/// the board turns over to the other side's placement view, seen from that
/// side, with the tools on its copper, and back again.
final class BoardFlipViewTests: XCTestCase {
    private func topView() -> HorizontalBoardViewState {
        var options = BoardDisplayOptions()
        options.applyLayerPreset(.topPlacement)
        return HorizontalBoardViewState(displayOptions: options, mirrored: false, drawingLayer: HorizontalBoardLayers.topCopper)
    }

    func testFlipTurnsTheTopViewOverToTheMirroredBottom() {
        var view = topView()
        view.flip()
        XCTAssertTrue(view.mirrored, "the bottom is seen from below")
        XCTAssertEqual(view.drawingLayer, HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(view.displayOptions.visibleSide, .bottom)
        XCTAssertEqual(view.sideUp, .bottom)
    }

    func testFlipTwiceComesBackToTheTop() {
        var view = topView()
        view.flip()
        view.flip()
        XCTAssertFalse(view.mirrored)
        XCTAssertEqual(view.drawingLayer, HorizontalBoardLayers.topCopper)
        XCTAssertEqual(view.displayOptions.visibleSide, .top)
    }

    func testWithBothSidesShowingTheFlipGoesByTheMirror() {
        var options = BoardDisplayOptions()
        options.showAll()
        var view = HorizontalBoardViewState(displayOptions: options, mirrored: true, drawingLayer: HorizontalBoardLayers.bottomCopper)
        XCTAssertNil(options.visibleSide)
        view.flip()
        XCTAssertFalse(view.mirrored, "seen from below with every layer on, the flip goes to the top")
        XCTAssertEqual(view.displayOptions.visibleSide, .top)
    }

    func testTheSideViewKeysLeaveTheMirrorAlone() {
        var view = topView()
        view.apply(HorizontalBoardLayerViewPreset.bottomRouting.layerPreset)
        XCTAssertFalse(view.mirrored, "⌘2 shows the bottom's routing without turning the board over")
        XCTAssertEqual(view.drawingLayer, HorizontalBoardLayers.bottomCopper)
    }

    func testFOnTheBoardCanvasFlipsTheViewAndElsewhereDoesNothing() {
        let f = HorizontalCanvasKeyEvent(characters: "f", modifiers: [])
        guard case .selectBoardLayerView(let preset)? = HorizontalCanvasInputCore.command(f, supportsTrackVias: true) else {
            return XCTFail("F on the board is the flip")
        }
        XCTAssertEqual(preset, .flip)
        XCTAssertEqual(preset.layerPreset, .flipView)
        XCTAssertNil(HorizontalCanvasInputCore.command(f, supportsTrackVias: false), "the schematic has no board to turn")
        XCTAssertNil(HorizontalCanvasInputCore.command(HorizontalCanvasKeyEvent(characters: "f", modifiers: .command), supportsTrackVias: true),
                     "⌘F stays Find's")
    }
}
