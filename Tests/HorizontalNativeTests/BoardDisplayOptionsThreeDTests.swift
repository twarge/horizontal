import Foundation
import XCTest
@testable import HorizontalNative

/// The 3D view's surface toggles are its own: hiding the silkscreen or the
/// substrate there leaves the 2D layer eyes alone, and vice versa.
final class BoardDisplayOptionsThreeDTests: XCTestCase {
    func testThreeDSurfaceTogglesAreIndependentOfTheLayerEyes() {
        var options = BoardDisplayOptions()
        options.threeDSilkscreen = false
        options.threeDBoardBody = false
        options.threeDSolderMask = false
        options.threeDPaste = false

        XCTAssertTrue(options.silkscreen)
        XCTAssertTrue(options.boardBody)
        XCTAssertTrue(options.solderMask)
        XCTAssertTrue(options.paste)
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topSilkscreen))
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topMask))
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topPaste))

        var other = BoardDisplayOptions()
        other.setLayerVisibility(HorizontalBoardLayers.topSilkscreen, isVisible: false)
        other.boardBody = false
        XCTAssertTrue(other.threeDSilkscreen)
        XCTAssertTrue(other.threeDBoardBody)
    }

    func testThreeDSurfaceTogglesPersistAndDefaultOn() throws {
        var options = BoardDisplayOptions()
        options.threeDSilkscreen = false
        options.threeDBoardBody = false
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(BoardDisplayOptions.self, from: data)
        XCTAssertFalse(decoded.threeDSilkscreen)
        XCTAssertFalse(decoded.threeDBoardBody)
        XCTAssertTrue(decoded.threeDSolderMask)
        XCTAssertTrue(decoded.threeDPaste)

        // Files written before the split have no such keys: the 3D view shows everything.
        let legacy = try JSONDecoder().decode(BoardDisplayOptions.self, from: Data(#"{"silkscreen":false,"boardBody":false}"#.utf8))
        XCTAssertFalse(legacy.silkscreen)
        XCTAssertTrue(legacy.threeDSilkscreen)
        XCTAssertTrue(legacy.threeDBoardBody)

        var reset = decoded
        reset.showAll()
        XCTAssertTrue(reset.threeDSilkscreen)
        XCTAssertTrue(reset.threeDBoardBody)
    }

    func testSceneSurfacesFollowTheThreeDTogglesNotTheLayerEyes() {
        var options = BoardDisplayOptions()
        options.boardBody = false
        options.solderMask = false
        options.paste = false
        options.silkscreen = false
        let surfaces = BoardSceneSurfaceVisibility(options)
        XCTAssertTrue(surfaces.substrate)
        XCTAssertTrue(surfaces.solderMask)
        XCTAssertTrue(surfaces.paste)
        XCTAssertTrue(surfaces.silkscreen)

        options.threeDSolderMask = false
        XCTAssertFalse(BoardSceneSurfaceVisibility(options).solderMask)
    }

    /// The package editor's 2D preset hides mask, paste and the board body;
    /// its 3D view must still show them, and the through-hole pad barrels
    /// that key on the vias flag.
    func testPackageEditorPresetLeavesTheThreeDViewComplete() {
        var options = BoardDisplayOptions()
        options.poolEditor(mode: .package)
        XCTAssertFalse(options.solderMask)
        XCTAssertFalse(options.boardBody)
        XCTAssertTrue(options.vias)
        let surfaces = BoardSceneSurfaceVisibility(options)
        XCTAssertTrue(surfaces.substrate)
        XCTAssertTrue(surfaces.solderMask)
        XCTAssertTrue(surfaces.paste)
    }
}
