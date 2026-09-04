import SwiftUI

private struct HorizontalVisiblePanesKey: FocusedValueKey {
    typealias Value = Binding<Set<HorizontalPane>>
}

private struct HorizontalHighlightNetActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct HorizontalFindActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct HorizontalDistractionFreeModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct HorizontalWindowToolbarHiddenKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct HorizontalToggleRightSidebarActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct HorizontalUpdateAllPlanesActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct HorizontalClearAllPlanesActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct HorizontalBoardRulesActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Capabilities of the currently-focused canvas (board or schematic) for menu
/// items that mirror the canvas's keyboard shortcuts. Each closure is a no-op
/// when not applicable to the focused canvas.
struct HorizontalCanvasCommandActions {
    var canDeleteSelection: Bool
    var canMoveSelection: Bool
    var canRotateSelection: Bool
    var canMirrorSelection: Bool
    var canDrawNetLine: Bool
    var canDrawTrack: Bool = false
    var canDrawGraphics: Bool = false
    var canDrawPlane: Bool = false
    var canAddText: Bool = false
    var canFilterAirwires: Bool = false
    var canFlipTrackPosture: Bool = false
    var canEnterTrackWidth: Bool = false
    var canToggleVia: Bool = false
    var canShowToolSettings: Bool = false
    var canMoveNetSegmentToExistingNet: Bool
    var canMoveNetSegmentToNewNet: Bool
    var canEditSymbolPinNames: Bool
    var canHighlightNet: Bool
    var canSelectAll: Bool
    var canSelectNet: Bool = false
    var canCopySelection: Bool = false
    var canPasteSelection: Bool = false
    var canDuplicateSelection: Bool = false
    var canCommitInteraction: Bool
    var canCancelInteraction: Bool
    var canPlacePad: Bool = false
    var canPlaceShape: Bool = false
    var canPlaceHole: Bool = false
    var canPlacePin: Bool = false
    var canPlaceRefdesAndValue: Bool = false
    var canPlaceDot: Bool = false
    var hasPlacementInteraction: Bool = false
    var dispatch: (HorizontalCanvasCommand) -> Void
}

private struct HorizontalCanvasCommandActionsKey: FocusedValueKey {
    typealias Value = HorizontalCanvasCommandActions
}

private struct HorizontalBoardDisplayOptionsKey: FocusedValueKey {
    typealias Value = Binding<BoardDisplayOptions>
}

private struct HorizontalBoardAvailableKey: FocusedValueKey {
    typealias Value = Bool
}

private struct HorizontalReadOnlyOperationKey: FocusedValueKey {
    typealias Value = Bool
}

private struct HorizontalSchematicDisplayOptionsKey: FocusedValueKey {
    typealias Value = Binding<SchematicDisplayOptions>
}

private struct HorizontalSchematicAvailableKey: FocusedValueKey {
    typealias Value = Bool
}

private struct HorizontalDocumentViewActionsKey: FocusedValueKey {
    typealias Value = HorizontalDocumentViewActions
}

struct HorizontalDocumentViewActions {
    var canShowTopSchematic: Bool
    var canShowBoard: Bool
    var canShowDiagnostics: Bool
    var showPackage: () -> Void
    var showTopSchematic: () -> Void
    var showBoard: () -> Void
    var showDiagnostics: () -> Void
    var revealPackageInFinder: () -> Void
    var openProjectFile: () -> Void
    var copyPackagePath: () -> Void
    var copyProjectFilePath: () -> Void
}

extension FocusedValues {
    var horizonVisiblePanes: Binding<Set<HorizontalPane>>? {
        get { self[HorizontalVisiblePanesKey.self] }
        set { self[HorizontalVisiblePanesKey.self] = newValue }
    }

    var horizonHighlightNetAction: (() -> Void)? {
        get { self[HorizontalHighlightNetActionKey.self] }
        set { self[HorizontalHighlightNetActionKey.self] = newValue }
    }

    var horizonFindAction: (() -> Void)? {
        get { self[HorizontalFindActionKey.self] }
        set { self[HorizontalFindActionKey.self] = newValue }
    }

    var horizonDistractionFreeMode: Binding<Bool>? {
        get { self[HorizontalDistractionFreeModeKey.self] }
        set { self[HorizontalDistractionFreeModeKey.self] = newValue }
    }

    var horizonWindowToolbarHidden: Binding<Bool>? {
        get { self[HorizontalWindowToolbarHiddenKey.self] }
        set { self[HorizontalWindowToolbarHiddenKey.self] = newValue }
    }

    var horizonToggleRightSidebarAction: (() -> Void)? {
        get { self[HorizontalToggleRightSidebarActionKey.self] }
        set { self[HorizontalToggleRightSidebarActionKey.self] = newValue }
    }

    var horizonUpdateAllPlanesAction: (() -> Void)? {
        get { self[HorizontalUpdateAllPlanesActionKey.self] }
        set { self[HorizontalUpdateAllPlanesActionKey.self] = newValue }
    }

    var horizonClearAllPlanesAction: (() -> Void)? {
        get { self[HorizontalClearAllPlanesActionKey.self] }
        set { self[HorizontalClearAllPlanesActionKey.self] = newValue }
    }

    var horizonBoardRulesAction: (() -> Void)? {
        get { self[HorizontalBoardRulesActionKey.self] }
        set { self[HorizontalBoardRulesActionKey.self] = newValue }
    }

    var horizonCanvasCommandActions: HorizontalCanvasCommandActions? {
        get { self[HorizontalCanvasCommandActionsKey.self] }
        set { self[HorizontalCanvasCommandActionsKey.self] = newValue }
    }

    var horizonBoardDisplayOptions: Binding<BoardDisplayOptions>? {
        get { self[HorizontalBoardDisplayOptionsKey.self] }
        set { self[HorizontalBoardDisplayOptionsKey.self] = newValue }
    }

    var horizonBoardAvailable: Bool? {
        get { self[HorizontalBoardAvailableKey.self] }
        set { self[HorizontalBoardAvailableKey.self] = newValue }
    }

    var horizonReadOnlyOperation: Bool? {
        get { self[HorizontalReadOnlyOperationKey.self] }
        set { self[HorizontalReadOnlyOperationKey.self] = newValue }
    }

    var horizonSchematicDisplayOptions: Binding<SchematicDisplayOptions>? {
        get { self[HorizontalSchematicDisplayOptionsKey.self] }
        set { self[HorizontalSchematicDisplayOptionsKey.self] = newValue }
    }

    var horizonSchematicAvailable: Bool? {
        get { self[HorizontalSchematicAvailableKey.self] }
        set { self[HorizontalSchematicAvailableKey.self] = newValue }
    }

    var horizonDocumentViewActions: HorizontalDocumentViewActions? {
        get { self[HorizontalDocumentViewActionsKey.self] }
        set { self[HorizontalDocumentViewActionsKey.self] = newValue }
    }
}

struct HorizontalViewCommands: Commands {
    @FocusedBinding(\.horizonVisiblePanes) private var visiblePanes
    @FocusedBinding(\.horizonBoardDisplayOptions) private var boardDisplayOptions
    @FocusedBinding(\.horizonSchematicDisplayOptions) private var schematicDisplayOptions
    @FocusedBinding(\.horizonDistractionFreeMode) private var distractionFreeMode
    @FocusedBinding(\.horizonWindowToolbarHidden) private var windowToolbarHidden
    @FocusedValue(\.horizonHighlightNetAction) private var highlightNetAction
    @FocusedValue(\.horizonFindAction) private var findAction
    @FocusedValue(\.horizonToggleRightSidebarAction) private var toggleRightSidebarAction
    @FocusedValue(\.horizonUpdateAllPlanesAction) private var updateAllPlanesAction
    @FocusedValue(\.horizonClearAllPlanesAction) private var clearAllPlanesAction
    @FocusedValue(\.horizonBoardRulesAction) private var boardRulesAction
    @FocusedValue(\.horizonCanvasCommandActions) private var canvasCommandActions
    @FocusedValue(\.horizonBoardAvailable) private var boardAvailable
    @FocusedValue(\.horizonReadOnlyOperation) private var readOnlyOperation
    @FocusedValue(\.horizonSchematicAvailable) private var schematicAvailable
    @FocusedValue(\.horizonDocumentViewActions) private var documentViewActions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Reveal Package in Finder") {
                documentViewActions?.revealPackageInFinder()
            }
            .disabled(documentViewActions == nil)
            Button("Open Project File") {
                documentViewActions?.openProjectFile()
            }
            .disabled(documentViewActions == nil)

            Divider()
            Button("Copy Package Path") {
                documentViewActions?.copyPackagePath()
            }
            .disabled(documentViewActions == nil)
            Button("Copy Project File Path") {
                documentViewActions?.copyProjectFilePath()
            }
            .disabled(documentViewActions == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") {
                findAction?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(findAction == nil)

            Divider()
            // Canvas-level commands. The Horizon-style single-key shortcuts are
            // handled by InteractiveCanvasView so text fields can opt out cleanly;
            // these menu items remain as clickable command affordances.
            Button("Select All") {
                canvasCommandActions?.dispatch(.selectAll)
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(canvasCommandActions?.canSelectAll != true)

            Button("Select Net") {
                canvasCommandActions?.dispatch(.selectNet)
            }
            .keyboardShortcut("l", modifiers: .shift)
            .disabled(canvasCommandActions?.canSelectNet != true)

            Divider()
            // ⌘C/⌘V/⌘D are handled by the canvas key monitor (so they beat the
            // system Edit-menu Copy/Paste on the canvas while text fields keep
            // theirs); these stay as clickable, shortcut-free affordances.
            Button("Copy") {
                canvasCommandActions?.dispatch(.copySelection)
            }
            .disabled(canvasCommandActions?.canCopySelection != true)

            Button("Paste") {
                canvasCommandActions?.dispatch(.pasteSelection)
            }
            .disabled(canvasCommandActions?.canPasteSelection != true)

            Button("Duplicate") {
                canvasCommandActions?.dispatch(.duplicateSelection)
            }
            .disabled(canvasCommandActions?.canDuplicateSelection != true)

            Button("Delete") {
                canvasCommandActions?.dispatch(.deleteSelection)
            }
            .disabled(canvasCommandActions?.canDeleteSelection != true)

            Divider()
            Button("Move") {
                canvasCommandActions?.dispatch(.moveSelection)
            }
            .disabled(canvasCommandActions?.canMoveSelection != true)

            Button("Rotate") {
                canvasCommandActions?.dispatch(.rotateSelection)
            }
            .disabled(canvasCommandActions?.canRotateSelection != true)

            Button("Mirror / Flip") {
                canvasCommandActions?.dispatch(.mirrorSelection)
            }
            .disabled(canvasCommandActions?.canMirrorSelection != true)

            Divider()
            Button("Move Net Segment to Existing Net") {
                canvasCommandActions?.dispatch(.moveNetSegmentToExistingNet)
            }
            .disabled(canvasCommandActions?.canMoveNetSegmentToExistingNet != true)

            Button("Move Net Segment to New Net") {
                canvasCommandActions?.dispatch(.moveNetSegmentToNewNet)
            }
            .disabled(canvasCommandActions?.canMoveNetSegmentToNewNet != true)

            Button("Edit Symbol Pin Names") {
                canvasCommandActions?.dispatch(.editSymbolPinNames)
            }
            .disabled(canvasCommandActions?.canEditSymbolPinNames != true)

            Divider()
            Button("Commit Interaction") {
                canvasCommandActions?.dispatch(.commitInteraction)
            }
            .disabled(canvasCommandActions?.canCommitInteraction != true)

            Button("Cancel Interaction") {
                canvasCommandActions?.dispatch(.cancelInteraction)
            }
            .disabled(canvasCommandActions?.canCancelInteraction != true)
        }

        CommandMenu("Design") {
            Button("Draw Track") {
                canvasCommandActions?.dispatch(.drawTrack)
            }
            .disabled(canvasCommandActions?.canDrawTrack != true)

            Button("Draw Net Line") {
                canvasCommandActions?.dispatch(.drawNetLine)
            }
            .disabled(canvasCommandActions?.canDrawNetLine != true)

            Divider()
            Button("Add Text…") {
                canvasCommandActions?.dispatch(.addText)
            }
            .disabled(canvasCommandActions?.canAddText != true)

            ForEach(HorizontalDrawingPrimitive.allCases) { primitive in
                Button(primitive.title) {
                    canvasCommandActions?.dispatch(.drawGraphics(primitive))
                }
                .disabled(canvasCommandActions?.canDrawGraphics != true)
            }

            Button("Draw Plane") {
                canvasCommandActions?.dispatch(.drawPlane)
            }
            .disabled(canvasCommandActions?.canDrawPlane != true)

            Divider()
            Button("Place Pad…") {
                canvasCommandActions?.dispatch(.placePad)
            }
            .disabled(canvasCommandActions?.canPlacePad != true)
            Menu("Place Shape") {
                ForEach(HorizontalPadstackShapeForm.allCases, id: \.self) { form in
                    Button(form.displayName) {
                        canvasCommandActions?.dispatch(.placeShape(form))
                    }
                }
            }
            .disabled(canvasCommandActions?.canPlaceShape != true)
            Menu("Place Hole") {
                Button("Round") {
                    canvasCommandActions?.dispatch(.placeHole(.round))
                }
                Button("Slot") {
                    canvasCommandActions?.dispatch(.placeHole(.slot))
                }
            }
            .disabled(canvasCommandActions?.canPlaceHole != true)
            Button("Place Pin") {
                canvasCommandActions?.dispatch(.placePin)
            }
            .disabled(canvasCommandActions?.canPlacePin != true)
            Button("Place Reference and Value") {
                canvasCommandActions?.dispatch(.placeRefdesAndValue)
            }
            .disabled(canvasCommandActions?.canPlaceRefdesAndValue != true)
            Button("Place Dot") {
                canvasCommandActions?.dispatch(.placeDot)
            }
            .disabled(canvasCommandActions?.canPlaceDot != true)

            Divider()
            Button("Flip Track Posture") {
                canvasCommandActions?.dispatch(.flipTrackPosture)
            }
            .disabled(canvasCommandActions?.canFlipTrackPosture != true)

            Button("Set Track Width…") {
                canvasCommandActions?.dispatch(.enterTrackWidth)
            }
            .disabled(canvasCommandActions?.canEnterTrackWidth != true)

            Button("Toggle Via") {
                canvasCommandActions?.dispatch(.toggleVia)
            }
            .disabled(canvasCommandActions?.canToggleVia != true)

            Button("Track Settings…") {
                canvasCommandActions?.dispatch(.showToolSettings)
            }
            .disabled(canvasCommandActions?.canShowToolSettings != true)

            Divider()
            Button("Filter Airwires…") {
                canvasCommandActions?.dispatch(.filterAirwires)
            }
            .disabled(canvasCommandActions?.canFilterAirwires != true)
        }

        CommandGroup(replacing: .toolbar) {
            Button(windowToolbarToggleTitle) {
                windowToolbarHidden = !(windowToolbarHidden ?? false)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(windowToolbarHidden == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") {
                toggleRightSidebarAction?()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(toggleRightSidebarAction == nil)

            Toggle("Distraction-Free Mode", isOn: distractionFreeModeBinding)
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(distractionFreeMode == nil)

            Divider()

            Button("Highlight Net") {
                highlightNetAction?()
            }
            .disabled(highlightNetAction == nil)

            Button("Update All Planes") {
                updateAllPlanesAction?()
            }
            .keyboardShortcut("q", modifiers: [])
            .disabled(updateAllPlanesAction == nil || boardAvailable != true || readOnlyOperation == true)

            // Empties every plane's renderFragments so the board draws without
            // plane fills; Q recomputes them. This is the plane-fill control —
            // there is deliberately no separate plane VISIBILITY toggle, since a
            // plane is shown whenever its copper layer is. Intentionally NOT
            // gated by readOnlyOperation: it changes only in-memory rendering.
            Button("Clear All Planes") {
                clearAllPlanesAction?()
            }
            .keyboardShortcut("q", modifiers: [.shift])
            .disabled(clearAllPlanesAction == nil || boardAvailable != true)

            Button("Board Rules…") {
                boardRulesAction?()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(boardRulesAction == nil || boardAvailable != true)

            Divider()
            Menu("Default View") {
                Button("Show Package") {
                    documentViewActions?.showPackage()
                }
                Button("Show Top Schematic") {
                    documentViewActions?.showTopSchematic()
                }
                .disabled(documentViewActions?.canShowTopSchematic != true)
                Button("Show Board") {
                    documentViewActions?.showBoard()
                }
                .disabled(documentViewActions?.canShowBoard != true)

                Divider()
                Button("Show Diagnostics") {
                    documentViewActions?.showDiagnostics()
                }
                .disabled(documentViewActions?.canShowDiagnostics != true)
            }
            .disabled(documentViewActions == nil)

            Divider()
            Toggle("Parts Pane", isOn: paneBinding(.parts))
                .keyboardShortcut(HorizontalPane.parts.keyboardShortcut, modifiers: .command)
            Toggle("Schematic Pane", isOn: paneBinding(.schematic))
                .keyboardShortcut(HorizontalPane.schematic.keyboardShortcut, modifiers: .command)
            Toggle("Board Pane", isOn: paneBinding(.board))
                .keyboardShortcut(HorizontalPane.board.keyboardShortcut, modifiers: .command)
            Toggle("3D Board Pane", isOn: paneBinding(.threeD))
                .keyboardShortcut(HorizontalPane.threeD.keyboardShortcut, modifiers: .command)

            Divider()
            Menu("Schematic Visibility") {
                Button("Show All") {
                    updateSchematicDisplayOptions { $0.showAll() }
                }
                Button("Connectivity") {
                    updateSchematicDisplayOptions { $0.logicalOnly() }
                }
                Button("Artwork") {
                    updateSchematicDisplayOptions { $0.artworkOnly() }
                }
                Button("Labels") {
                    updateSchematicDisplayOptions { $0.labelsOnly() }
                }
                Button("Clean View") {
                    updateSchematicDisplayOptions { $0.cleanView() }
                }

                Divider()
                Toggle("Grid", isOn: schematicOptionBinding(\.grid))
                Toggle("Origin", isOn: schematicOptionBinding(\.origin))
                Toggle("Frame", isOn: schematicOptionBinding(\.frame))
                Toggle("Drawing", isOn: schematicOptionBinding(\.drawing))
                Toggle("Symbols", isOn: schematicOptionBinding(\.symbols))
                Toggle("Block Symbols", isOn: schematicOptionBinding(\.blockSymbols))
                Toggle("Nets", isOn: schematicOptionBinding(\.nets))
                Toggle("Net Labels", isOn: schematicOptionBinding(\.netLabels))
                Toggle("Junctions", isOn: schematicOptionBinding(\.junctions))
                Toggle("Net Ties", isOn: schematicOptionBinding(\.netTies))
                Toggle("Buses", isOn: schematicOptionBinding(\.buses))
                Toggle("Power", isOn: schematicOptionBinding(\.power))
                Toggle("Text", isOn: schematicOptionBinding(\.text))

                Divider()
                Toggle("Coordinates", isOn: schematicOptionBinding(\.coordinates))
            }
            .disabled(schematicDisplayOptions == nil || schematicAvailable != true)

            Menu("Board Visibility") {
                Button("Show All") {
                    updateBoardDisplayOptions { $0.showAll() }
                }
                Button("Copper") {
                    updateBoardDisplayOptions { $0.copperOnly() }
                }
                Button("Routing") {
                    updateBoardDisplayOptions { $0.routingOnly() }
                }
                Button("Assembly") {
                    updateBoardDisplayOptions { $0.assemblyOnly() }
                }
                Button("Fabrication") {
                    updateBoardDisplayOptions { $0.fabricationOnly() }
                }
                Button("Mechanical") {
                    updateBoardDisplayOptions { $0.mechanicalOnly() }
                }
                Button("Footprints") {
                    updateBoardDisplayOptions { $0.footprintsOnly() }
                }
                Button("Clean View") {
                    updateBoardDisplayOptions { $0.cleanView() }
                }

                Divider()
                Toggle("Grid", isOn: boardOptionBinding(\.grid))
                Toggle("Top Copper", isOn: boardOptionBinding(\.topCopper))
                Toggle("Inner Copper", isOn: boardOptionBinding(\.innerCopper))
                Toggle("Bottom Copper", isOn: boardOptionBinding(\.bottomCopper))
                Toggle("Silkscreen", isOn: boardOptionBinding(\.silkscreen))
                Toggle("Solder Mask", isOn: boardOptionBinding(\.solderMask))
                Toggle("Paste", isOn: boardOptionBinding(\.paste))
                Toggle("Board Body", isOn: boardOptionBinding(\.boardBody))
                Toggle("Outline", isOn: boardOptionBinding(\.outline))
                Toggle("Panel Labels", isOn: boardOptionBinding(\.panelLabels))
                Toggle("Origin", isOn: boardOptionBinding(\.origin))
                Toggle("Fabrication", isOn: boardOptionBinding(\.fabrication))
                Toggle("User Layers", isOn: boardOptionBinding(\.userLayers))
                Toggle("Keepouts", isOn: boardOptionBinding(\.keepouts))
                Toggle("Dimensions", isOn: boardOptionBinding(\.dimensions))
                Toggle("Decals", isOn: boardOptionBinding(\.decals))
                Toggle("Track Labels", isOn: boardOptionBinding(\.trackLabels))
                Toggle("Vias", isOn: boardOptionBinding(\.vias))
                Toggle("Via Labels", isOn: boardOptionBinding(\.viaLabels))
                Toggle("Pads", isOn: boardOptionBinding(\.pads))
                Toggle("Pad Labels", isOn: boardOptionBinding(\.padLabels))
                Toggle("Holes", isOn: boardOptionBinding(\.holes))
                Toggle("Packages", isOn: boardOptionBinding(\.packages))
                Toggle("3D Models", isOn: boardThreeDModelsBinding)
                Toggle("Text", isOn: boardOptionBinding(\.text))
                Toggle("Connections", isOn: boardOptionBinding(\.connectionLines))
                Toggle("Connection Labels", isOn: boardOptionBinding(\.connectionLabels))

                Divider()
                Toggle("Scale Bar", isOn: boardOptionBinding(\.scaleBar))
                Toggle("Coordinates", isOn: boardOptionBinding(\.coordinates))
                Toggle("3D Layer Colors", isOn: boardThreeDLayerColorsBinding)
            }
            .disabled(boardDisplayOptions == nil || boardAvailable != true)
        }
    }

    private func paneBinding(_ pane: HorizontalPane) -> Binding<Bool> {
        Binding {
            visiblePanes?.contains(pane) ?? false
        } set: { isVisible in
            guard var panes = visiblePanes else {
                return
            }
            if isVisible {
                panes.insert(pane)
            } else if panes.count > 1 {
                panes.remove(pane)
            }
            visiblePanes = panes
        }
    }

    private var distractionFreeModeBinding: Binding<Bool> {
        Binding {
            distractionFreeMode ?? false
        } set: { isEnabled in
            distractionFreeMode = isEnabled
        }
    }

    private var windowToolbarToggleTitle: String {
        windowToolbarHidden == true ? "Show Toolbar" : "Hide Toolbar"
    }

    private func schematicOptionBinding(_ keyPath: WritableKeyPath<SchematicDisplayOptions, Bool>) -> Binding<Bool> {
        Binding {
            schematicDisplayOptions?[keyPath: keyPath] ?? false
        } set: { isOn in
            guard var options = schematicDisplayOptions else {
                return
            }
            options[keyPath: keyPath] = isOn
            schematicDisplayOptions = options
        }
    }

    private func updateSchematicDisplayOptions(_ update: (inout SchematicDisplayOptions) -> Void) {
        guard var options = schematicDisplayOptions else {
            return
        }
        update(&options)
        schematicDisplayOptions = options
    }

    private func boardOptionBinding(_ keyPath: WritableKeyPath<BoardDisplayOptions, Bool>) -> Binding<Bool> {
        Binding {
            boardDisplayOptions?[keyPath: keyPath] ?? false
        } set: { isOn in
            guard var options = boardDisplayOptions else {
                return
            }
            options[keyPath: keyPath] = isOn
            boardDisplayOptions = options
        }
    }

    private var boardThreeDModelsBinding: Binding<Bool> {
        Binding {
            guard let options = boardDisplayOptions else {
                return false
            }
            return options.threeDModelMode != .none
        } set: { isOn in
            updateBoardDisplayOptions { options in
                if isOn {
                    if options.threeDModelMode == .none {
                        options.threeDModelMode = .placed
                    }
                } else {
                    options.threeDModelMode = .none
                }
                options.threeDModels = options.threeDModelMode != .none
            }
        }
    }

    private var boardThreeDLayerColorsBinding: Binding<Bool> {
        Binding {
            boardDisplayOptions?.threeDCopperMode == .layerColor
        } set: { usesLayerColors in
            updateBoardDisplayOptions { options in
                if usesLayerColors {
                    options.threeDCopperMode = .layerColor
                } else if options.threeDCopperMode == .layerColor {
                    options.threeDCopperMode = .on
                }
                options.threeDUseLayerColors = options.threeDCopperMode == .layerColor
            }
        }
    }

    private func updateBoardDisplayOptions(_ update: (inout BoardDisplayOptions) -> Void) {
        guard var options = boardDisplayOptions else {
            return
        }
        update(&options)
        boardDisplayOptions = options
    }
}
