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
    /// shifted number row has to decode back to its digit — otherwise ⌘⇧1 and
    /// ⌘⇧2 silently do nothing.
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

    func testCommandSideDigitsSelectRoutingViews() {
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: .command), .topRouting)
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 2, modifiers: .command), .bottomRouting)
    }

    func testCommandOptionSideDigitsSelectPlacementViews() {
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: [.command, .option]), .topPlacement)
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 2, modifiers: [.command, .option]), .bottomPlacement)
    }

    func testCommandShiftSideDigitsSelectSilkscreenViews() {
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: [.command, .shift]), .topSilkscreen)
        XCTAssertEqual(
            HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 2, modifiers: [.command, .shift]), .bottomSilkscreen)
    }

    /// Only the two side digits carry a preset — there is no inner placement
    /// view — an unmodified digit is a plain layer selection, and the old
    /// ⇧ and ⌃ bindings are gone.
    func testOtherDigitsAndModifiersCarryNoPreset() {
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 3, modifiers: .command))
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: []))
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: .shift))
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: .control))
        XCTAssertNil(HorizontalCanvasInputCore.boardLayerViewPreset(forDigit: 1, modifiers: [.command, .control]))
    }

    func testShiftedDigitDecodesToAPresetCommand() {
        let command = HorizontalCanvasInputCore.command(
            keyEvent("!", modifiers: [.command, .shift]), supportsTrackVias: true)
        guard case .selectBoardLayerView(let preset)? = command else {
            return XCTFail("expected .selectBoardLayerView, got \(String(describing: command))")
        }
        XCTAssertEqual(preset, .topSilkscreen)
    }

    /// ⌘⌥1 arrives as "¡" on a US layout; the key code still names the 1.
    func testCommandOptionDigitDecodesByKeyCode() {
        let event = HorizontalCanvasKeyEvent(characters: "¡", keyCode: 18, modifiers: [.command, .option])
        guard case .selectBoardLayerView(let preset)? = HorizontalCanvasInputCore.command(event, supportsTrackVias: true) else {
            return XCTFail("expected .selectBoardLayerView")
        }
        XCTAssertEqual(preset, .topPlacement)
    }

    /// Off the board canvas ⌘1 and ⌘2 are not the canvas's: the View menu
    /// shows and hides the Parts and Schematic panes with them.
    func testOnlyTheBoardCanvasTakesTheViewKeys() {
        XCTAssertNil(HorizontalCanvasInputCore.command(keyEvent("1", modifiers: .command), supportsTrackVias: false))
        XCTAssertNil(HorizontalCanvasInputCore.command(keyEvent("@", modifiers: [.command, .shift]), supportsTrackVias: false))
    }

    /// A view key puts the tools where the rail's preset button would: the
    /// side's silkscreen for a silkscreen view, its copper otherwise.
    func testViewKeyPresetsNameTheirDrawingLayers() {
        let expected: [(HorizontalBoardLayerViewPreset, Int)] = [
            (.topRouting, HorizontalBoardLayers.topCopper),
            (.bottomRouting, HorizontalBoardLayers.bottomCopper),
            (.topPlacement, HorizontalBoardLayers.topCopper),
            (.bottomPlacement, HorizontalBoardLayers.bottomCopper),
            (.topSilkscreen, HorizontalBoardLayers.topSilkscreen),
            (.bottomSilkscreen, HorizontalBoardLayers.bottomSilkscreen),
        ]
        for (preset, layer) in expected {
            XCTAssertEqual(preset.layerPreset.drawingLayer, layer, "\(preset)")
        }
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
        placement.applyLayerPreset(.topPlacement)
        var silkscreen = BoardDisplayOptions()
        silkscreen.applyLayerPreset(.topSilkscreen)
        var bottomPlacement = BoardDisplayOptions()
        bottomPlacement.applyLayerPreset(.bottomPlacement)

        XCTAssertNotEqual(placement, silkscreen)
        XCTAssertNotEqual(placement, bottomPlacement)
        XCTAssertTrue(placement.isLayerVisible(HorizontalBoardLayers.topCopper), "placement shows top copper")
        XCTAssertFalse(silkscreen.isLayerVisible(HorizontalBoardLayers.topCopper), "silkscreen does not")
    }

    /// A placement view is its side's copper, assembly drawing and courtyard,
    /// the outline, and none of the other side's.
    func testPlacementViewsShowTheirSidesAssembly() {
        let top = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.topAssembly, HorizontalBoardLayers.topCourtyard]
        let bottom = [HorizontalBoardLayers.bottomCopper, HorizontalBoardLayers.bottomAssembly, HorizontalBoardLayers.bottomCourtyard]
        for (name, apply, shown, hidden) in [
            ("top", { (options: inout BoardDisplayOptions) in options.topPlacementView() }, top, bottom),
            ("bottom", { (options: inout BoardDisplayOptions) in options.bottomPlacementView() }, bottom, top),
        ] {
            var options = BoardDisplayOptions()
            apply(&options)
            for layer in shown + [HorizontalBoardLayers.outline] {
                XCTAssertTrue(options.isLayerVisible(layer), "\(name) placement shows \(HorizontalBoardLayers.name(for: layer))")
            }
            for layer in hidden + [HorizontalBoardLayers.topPackage, HorizontalBoardLayers.bottomPackage] {
                XCTAssertFalse(options.isLayerVisible(layer), "\(name) placement hides \(HorizontalBoardLayers.name(for: layer))")
            }
        }
    }

    /// The solder masks start as outlines and every other layer filled; a
    /// switch set back to its layer's default leaves no override behind.
    func testSolderMasksDefaultToOutlines() {
        var options = BoardDisplayOptions()
        XCTAssertFalse(options.isLayerFilled(HorizontalBoardLayers.topMask))
        XCTAssertFalse(options.isLayerFilled(HorizontalBoardLayers.bottomMask))
        XCTAssertTrue(options.isLayerFilled(HorizontalBoardLayers.topCopper))
        XCTAssertTrue(options.isLayerFilled(HorizontalBoardLayers.topPaste))

        options.setLayerFilled(HorizontalBoardLayers.topMask, isFilled: true)
        XCTAssertTrue(options.isLayerFilled(HorizontalBoardLayers.topMask))
        XCTAssertFalse(options.isLayerFilled(HorizontalBoardLayers.bottomMask), "the other mask keeps its default")
        options.setLayerFilled(HorizontalBoardLayers.topMask, isFilled: false)
        options.setLayerFilled(HorizontalBoardLayers.topCopper, isFilled: true)
        XCTAssertTrue(options.layerFillOverrides.isEmpty)
    }

    /// The Objects switches start on, and no view preset sets them: a
    /// view is its layers, and what the user switched off stays off.
    func testPresetsLeaveObjectSwitchesAlone() {
        let objects: [WritableKeyPath<BoardDisplayOptions, Bool>] = [
            \.trackLabels, \.vias, \.viaLabels, \.pads, \.padLabels, \.holes, \.packages,
            \.text, \.keepouts, \.dimensions, \.connectionLines, \.connectionLabels, \.decals
        ]
        let defaults = BoardDisplayOptions()
        for object in objects {
            XCTAssertTrue(defaults[keyPath: object], "\(object) defaults on")
        }

        var mixed = BoardDisplayOptions()
        for (index, object) in objects.enumerated() {
            mixed[keyPath: object] = index.isMultiple(of: 2)
        }
        let presets: [(String, (inout BoardDisplayOptions) -> Void)] = [
            ("top silkscreen", { $0.topSilkscreenView() }),
            ("bottom silkscreen", { $0.bottomSilkscreenView() }),
            ("top placement", { $0.topPlacementView() }),
            ("bottom placement", { $0.bottomPlacementView() }),
            ("top routing", { $0.topRoutingView() }),
            ("bottom routing", { $0.bottomRoutingView() }),
            ("all", { $0.showAll() }),
            ("clean", { $0.cleanView() }),
            ("copper only", { $0.copperOnly() }),
            ("routing only", { $0.routingOnly() }),
            ("assembly", { $0.assemblyOnly() }),
            ("fabrication", { $0.fabricationOnly() }),
            ("mechanical", { $0.mechanicalOnly() }),
            ("footprints", { $0.footprintsOnly() })
        ]
        for (name, apply) in presets {
            var options = mixed
            apply(&options)
            for object in objects {
                XCTAssertEqual(options[keyPath: object], mixed[keyPath: object], "\(name) changed \(object)")
            }
        }
    }

    /// Turning the board over keeps the view's mode, read from its layers
    /// now that the views no longer differ in their objects.
    func testVisibleViewModeComesFromTheLayers() {
        var options = BoardDisplayOptions()
        options.topSilkscreenView()
        XCTAssertEqual(options.visibleViewMode(on: .top), .silkscreen)
        options.topPlacementView()
        XCTAssertEqual(options.visibleViewMode(on: .top), .placement)
        options.topRoutingView()
        XCTAssertEqual(options.visibleViewMode(on: .top), .routing)
        options.bottomSilkscreenView()
        XCTAssertEqual(options.visibleViewMode(on: .bottom), .silkscreen)
        options.bottomRoutingView()
        XCTAssertEqual(options.visibleViewMode(on: .bottom), .routing)
        options.bottomPlacementView()
        XCTAssertEqual(options.visibleViewMode(on: .bottom), .placement)
    }

    /// A silkscreen view puts the tools on that side's silkscreen; the other
    /// sided views on its copper, and the side-less ones nowhere in particular.
    func testPresetDrawingLayers() {
        XCTAssertEqual(HorizontalBoardLayerPreset.topSilkscreen.drawingLayer, HorizontalBoardLayers.topSilkscreen)
        XCTAssertEqual(HorizontalBoardLayerPreset.bottomSilkscreen.drawingLayer, HorizontalBoardLayers.bottomSilkscreen)
        XCTAssertEqual(HorizontalBoardLayerPreset.topPlacement.drawingLayer, HorizontalBoardLayers.topCopper)
        XCTAssertEqual(HorizontalBoardLayerPreset.bottomRouting.drawingLayer, HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(HorizontalBoardLayerPreset.bottomView.drawingLayer, HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(
            HorizontalBoardLayerPreset.silkscreen.resolved(for: .bottom).drawingLayer,
            HorizontalBoardLayers.bottomSilkscreen
        )
        XCTAssertNil(HorizontalBoardLayerPreset.all.drawingLayer)
    }

    /// A via's net name is drawn only with its copper: a silkscreen view
    /// shows none of a through via's copper, so it shows no label either.
    func testViaCopperShowsOnlyOnItsVisibleLayers() {
        let through = HorizontalMarker(
            id: "via", position: HorizontalPoint(x: 0, y: 0), size: 600_000, layer: nil,
            connectedLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
        )
        let buried = HorizontalMarker(
            id: "buried", position: HorizontalPoint(x: 0, y: 0), size: 600_000, layer: nil,
            connectedLayers: [HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.in2Copper]
        )
        var options = BoardDisplayOptions()
        XCTAssertTrue(options.showsCopper(of: through))

        options.topSilkscreenView()
        XCTAssertFalse(options.showsCopper(of: through), "the top silkscreen view hides the via's copper")
        options.bottomSilkscreenView()
        XCTAssertFalse(options.showsCopper(of: through), "and so does the bottom one")

        options.selectedLayer = HorizontalBoardLayers.bottomCopper
        XCTAssertTrue(options.showsCopper(of: through), "the working layer shows whatever its eye says")
        options.selectedLayer = nil

        options.bottomPlacementView()
        XCTAssertTrue(options.showsCopper(of: through), "the bottom copper shows, and the via's ring on it")
        XCTAssertFalse(options.showsCopper(of: buried), "a buried via has no copper on the bottom")
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

    /// Every sided view — placement, routing and silkscreen, top and bottom —
    /// shows the board outline, with nothing the working layer adds.
    func testEverySidedViewShowsTheOutline() {
        for preset in [HorizontalBoardLayerViewPreset.topPlacement, .bottomPlacement, .topRouting,
                       .bottomRouting, .topSilkscreen, .bottomSilkscreen] {
            var options = BoardDisplayOptions()
            options.applyLayerPreset(preset.layerPreset)
            options.selectedLayer = nil
            XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.outline), "\(preset)")
            XCTAssertTrue(options.showsOutlineLayer, "\(preset)")
        }
    }

    /// A routing view is its side's copper and the outline, nothing else.
    func testRoutingViewsShowTheirCopperAndTheOutline() {
        var options = BoardDisplayOptions()
        options.bottomRoutingView()
        let shown = HorizontalBoardLayers.all.filter { options.isLayerVisible($0) }
        XCTAssertEqual(Set(shown), [HorizontalBoardLayers.bottomCopper, HorizontalBoardLayers.outline])
    }

    /// A board opens on the top placement view, whatever view the file saved,
    /// and keeps the rest of what it saved.
    func testABoardOpensOnTheTopPlacementView() {
        var saved = BoardDisplayOptions()
        saved.bottomSilkscreenView()
        saved.pads = false
        let opened = BoardDisplayOptions.opening(saved)
        var expected = saved
        expected.topPlacementView()
        XCTAssertEqual(opened, expected)
        XCTAssertFalse(opened.pads, "the object switches stay as saved")
        XCTAssertTrue(opened.isLayerVisible(HorizontalBoardLayers.topCourtyard))
        XCTAssertFalse(opened.isLayerVisible(HorizontalBoardLayers.bottomSilkscreen))

        var fresh = BoardDisplayOptions()
        fresh.topPlacementView()
        XCTAssertEqual(BoardDisplayOptions.opening(nil), fresh)
    }

    /// The board outline's stroke follows the Outline layer as it is seen:
    /// its eye, the working layer and solo. A preset that leaves the outline
    /// out clears the Outline category, and turning the layer's eye back on
    /// sets an override the stroke didn't follow, so it stayed at the faint
    /// opacity it has with the layer off.
    func testTheBoardOutlineFollowsTheOutlineLayersEye() {
        var options = BoardDisplayOptions()
        XCTAssertTrue(options.showsOutlineLayer)

        options.copperOnly()
        XCTAssertFalse(options.outline, "the preset leaves the outline out")
        XCTAssertFalse(options.showsOutlineLayer)
        options.setLayerVisibility(HorizontalBoardLayers.outline, isVisible: true)
        XCTAssertFalse(options.outline, "the eye sets an override, not the category")
        XCTAssertTrue(options.showsOutlineLayer)

        options = BoardDisplayOptions()
        options.setLayerVisibility(HorizontalBoardLayers.outline, isVisible: false)
        XCTAssertTrue(options.outline)
        XCTAssertFalse(options.showsOutlineLayer)
        options.selectedLayer = HorizontalBoardLayers.outline
        XCTAssertTrue(options.showsOutlineLayer, "the working layer is always shown")

        options = BoardDisplayOptions()
        options.soloLayer = HorizontalBoardLayers.topCopper
        XCTAssertFalse(options.showsOutlineLayer)
    }
}
