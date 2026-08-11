import XCTest
@testable import HorizontalNative

/// Number-key layer selection, and the rule that the selected layer renders
/// whatever its eye says.
final class BoardLayerSelectionTests: XCTestCase {
    private func keyEvent(_ characters: String,
                          modifiers: HorizontalCanvasInputModifiers = []) -> HorizontalCanvasKeyEvent {
        HorizontalCanvasKeyEvent(characters: characters, modifiers: modifiers)
    }

    // MARK: - Digit mapping

    func testDigitsMapTopBottomThenInnerLayersInOrder() {
        XCTAssertEqual(HorizontalCanvasInputCore.copperLayer(forDigit: 1), HorizontalBoardLayers.topCopper)
        XCTAssertEqual(HorizontalCanvasInputCore.copperLayer(forDigit: 2), HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(HorizontalCanvasInputCore.copperLayer(forDigit: 3), HorizontalBoardLayers.in1Copper)
        XCTAssertEqual(HorizontalCanvasInputCore.copperLayer(forDigit: 4), HorizontalBoardLayers.in2Copper)
        XCTAssertEqual(HorizontalCanvasInputCore.copperLayer(forDigit: 5), HorizontalBoardLayers.in3Copper)
    }

    func testNonDigitsAndZeroAreNotLayers() {
        XCTAssertNil(HorizontalCanvasInputCore.copperLayer(forDigit: 0))
        XCTAssertNil(HorizontalCanvasInputCore.digit(keyEvent("x")))
        XCTAssertNil(HorizontalCanvasInputCore.digit(keyEvent("/")))
    }

    /// macOS reports Shift+1 as "!" via charactersIgnoringModifiers, so the
    /// shifted number row has to decode back to its digit — otherwise the whole
    /// Shift/Control layer of these bindings silently does nothing.
    func testShiftedNumberRowStillDecodesToItsDigit() {
        XCTAssertEqual(HorizontalCanvasInputCore.digit(keyEvent("!", modifiers: .shift)), 1)
        XCTAssertEqual(HorizontalCanvasInputCore.digit(keyEvent("@", modifiers: .shift)), 2)
    }

    /// A layout that reports something else entirely still works, because the
    /// hardware key code is layout-independent.
    func testKeyCodeDecodesTheDigitWhenCharactersDoNot() {
        let event = HorizontalCanvasKeyEvent(characters: "±", keyCode: 18, modifiers: .shift)
        XCTAssertEqual(HorizontalCanvasInputCore.digit(event), 1)
    }

    // MARK: - View presets

    func testShiftedSideDigitsSelectPlacementViews() {
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: .shift), .topPlacement)
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 2, modifiers: .shift), .bottomPlacement)
    }

    func testControlSideDigitsSelectSilkscreenViews() {
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: .control), .topSilkscreen)
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 2, modifiers: .control), .bottomSilkscreen)
    }

    /// Only the two side digits carry a preset — there is no inner placement
    /// view — and an unmodified digit is a plain layer selection.
    func testOtherDigitsAndModifiersCarryNoPreset() {
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 3, modifiers: .shift))
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: []))
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: .command))
    }

    func testShiftedDigitDecodesToAPresetCommand() {
        let command = HorizontalCanvasInputCore.command(
            keyEvent("!", modifiers: .shift), supportsTrackVias: true)
        guard case .selectBoardLayerView(let preset)? = command else {
            return XCTFail("expected .selectBoardLayerView, got \(String(describing: command))")
        }
        XCTAssertEqual(preset, .topPlacement)
    }

    // MARK: - Solo

    /// Solo shows one layer and nothing else, whatever the eyes say.
    func testSoloHidesEveryOtherLayer() {
        var options = BoardDisplayOptions()
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.bottomCopper))

        options.soloLayer = HorizontalBoardLayers.topCopper
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topCopper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.bottomCopper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.topSilkscreen))
    }

    /// Clearing solo restores exactly what was visible before, including an eye
    /// the user had turned off — nothing was overwritten to achieve the solo.
    func testClearingSoloRestoresThePreviousVisibility() {
        var options = BoardDisplayOptions()
        options.setLayerVisibility(HorizontalBoardLayers.bottomCopper, isVisible: false)
        options.soloLayer = HorizontalBoardLayers.topCopper
        options.soloLayer = nil

        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topCopper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.bottomCopper), "the eye setting survived")
    }

    /// Solo beats the selected-layer rule, or soloing an inner layer would still
    /// leave the working layer drawn on top of it.
    func testSoloOutranksTheSelectedLayer() {
        var options = BoardDisplayOptions()
        options.selectedLayer = HorizontalBoardLayers.topCopper
        options.soloLayer = HorizontalBoardLayers.in1Copper

        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.in1Copper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.topCopper))
    }

    /// The presets differ from each other; a preset must actually change the
    /// view rather than being wired to the same thing twice.
    func testPresetsProduceDistinctViews() {
        var placement = BoardDisplayOptions()
        placement.apply(.topPlacement)
        var silkscreen = BoardDisplayOptions()
        silkscreen.apply(.topSilkscreen)
        var bottomPlacement = BoardDisplayOptions()
        bottomPlacement.apply(.bottomPlacement)

        XCTAssertNotEqual(placement, silkscreen)
        XCTAssertNotEqual(placement, bottomPlacement)
        XCTAssertTrue(placement.pads, "placement shows pads")
        XCTAssertFalse(silkscreen.pads, "silkscreen does not")
    }

    func testPlainDigitDecodesToSelectLayer() {
        let command = HorizontalCanvasInputCore.command(keyEvent("2"), supportsTrackVias: true)
        guard case .selectLayer(let layer)? = command else {
            return XCTFail("expected .selectLayer, got \(String(describing: command))")
        }
        XCTAssertEqual(layer, HorizontalBoardLayers.bottomCopper)
    }

    /// A modified digit belongs to the system (⌘1 switches tabs/windows), so the
    /// canvas must not claim it.
    func testModifiedDigitsAreNotLayerSelection() {
        for modifiers in [HorizontalCanvasInputModifiers.command, .shift, .option] {
            let command = HorizontalCanvasInputCore.command(
                keyEvent("1", modifiers: modifiers), supportsTrackVias: true)
            if case .selectLayer = command {
                XCTFail("\(modifiers) + 1 must not select a layer")
            }
        }
    }

    // MARK: - Selected layer visibility

    /// The point of the feature: selecting a layer shows it even though its eye
    /// is explicitly off.
    func testSelectedLayerIsVisibleDespiteEyeOff() {
        var options = BoardDisplayOptions()
        options.setLayerVisibility(HorizontalBoardLayers.in1Copper, isVisible: false)
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.in1Copper))

        options.selectedLayer = HorizontalBoardLayers.in1Copper
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.in1Copper))
    }

    /// Only the selected layer is forced — selecting one layer must not reveal
    /// every other hidden layer.
    func testSelectionDoesNotRevealOtherHiddenLayers() {
        var options = BoardDisplayOptions()
        options.setLayerVisibility(HorizontalBoardLayers.in1Copper, isVisible: false)
        options.setLayerVisibility(HorizontalBoardLayers.in2Copper, isVisible: false)
        options.selectedLayer = HorizontalBoardLayers.in1Copper

        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.in1Copper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.in2Copper))
    }

    /// Deselecting restores whatever the eye said, rather than leaving the layer
    /// stuck visible.
    func testClearingSelectionRestoresTheEyeSetting() {
        var options = BoardDisplayOptions()
        options.setLayerVisibility(HorizontalBoardLayers.topCopper, isVisible: false)
        options.selectedLayer = HorizontalBoardLayers.topCopper
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topCopper))

        options.selectedLayer = nil
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.topCopper))
    }
}
