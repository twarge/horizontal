import Foundation

/// What the board canvas is editing: a project board, or one of the pool
/// item kinds Horizon edits with its layered "imp" — a package, a padstack, a
/// decal. Each pool mode fixes which layers exist, which tools apply and what
/// the canvas shows by default, mirroring `imp_package`, `imp_padstack` and
/// `imp_decal`.
enum HorizontalBoardEditorMode: Hashable {
    case board
    case package
    case padstack
    case decal
}

struct HorizontalBoardModeProfile: Hashable {
    var mode: HorizontalBoardEditorMode
    /// The layers the layer panel and the inspector pickers offer, top to
    /// bottom. Empty means "whatever the board has" (board mode).
    var layers: [Int]
    /// The copper layers the number keys may select (the synthetic board's
    /// stackup, so the board's own layer gate keeps working).
    var stackupLayers: [Int]
    /// Whether nets exist: a board propagates nets from pads on every commit;
    /// a pool item has no nets at all.
    var usesConnectivity: Bool
    var placesPads: Bool
    var placesShapes: Bool
    var placesHoles: Bool
    var allowsGraphics: Bool
    var allowsPolygons: Bool
    var allowsText: Bool
    var defaultDrawingLayer: Int

    var isPoolMode: Bool {
        mode != .board
    }

    /// Whether `layer` is one this mode can draw on or pick.
    func allows(layer: Int) -> Bool {
        layers.isEmpty || layers.contains(layer)
    }

    static let board = HorizontalBoardModeProfile(
        mode: .board,
        layers: [],
        stackupLayers: [],
        usesConnectivity: true,
        placesPads: false,
        placesShapes: false,
        placesHoles: false,
        allowsGraphics: true,
        allowsPolygons: true,
        allowsText: true,
        defaultDrawingLayer: HorizontalBoardLayers.topCopper
    )

    /// `Package::get_layers`: outline, the top stack, one inner copper, the
    /// bottom stack.
    static let package = HorizontalBoardModeProfile(
        mode: .package,
        layers: [
            HorizontalBoardLayers.outline,
            HorizontalBoardLayers.topCourtyard,
            HorizontalBoardLayers.topAssembly,
            HorizontalBoardLayers.topPackage,
            HorizontalBoardLayers.topPaste,
            HorizontalBoardLayers.topSilkscreen,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper,
            HorizontalBoardLayers.in1Copper,
            HorizontalBoardLayers.bottomCopper,
            HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.bottomSilkscreen,
            HorizontalBoardLayers.bottomPaste,
            HorizontalBoardLayers.bottomPackage,
            HorizontalBoardLayers.bottomAssembly,
            HorizontalBoardLayers.bottomCourtyard,
        ],
        stackupLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.bottomCopper],
        usesConnectivity: false,
        placesPads: true,
        placesShapes: false,
        placesHoles: false,
        allowsGraphics: true,
        allowsPolygons: true,
        allowsText: true,
        defaultDrawingLayer: HorizontalBoardLayers.topSilkscreen
    )

    /// `Padstack::get_layers`: paste, mask, copper on both sides plus "inner".
    static let padstack = HorizontalBoardModeProfile(
        mode: .padstack,
        layers: [
            HorizontalBoardLayers.topPaste,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper,
            HorizontalBoardLayers.in1Copper,
            HorizontalBoardLayers.bottomCopper,
            HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.bottomPaste,
        ],
        stackupLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.in1Copper, HorizontalBoardLayers.bottomCopper],
        usesConnectivity: false,
        placesPads: false,
        placesShapes: true,
        placesHoles: true,
        allowsGraphics: false,
        allowsPolygons: true,
        allowsText: false,
        defaultDrawingLayer: HorizontalBoardLayers.topCopper
    )

    /// `Decal::get_layers`: top assembly, silkscreen, mask and copper.
    static let decal = HorizontalBoardModeProfile(
        mode: .decal,
        layers: [
            HorizontalBoardLayers.topAssembly,
            HorizontalBoardLayers.topSilkscreen,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper,
        ],
        stackupLayers: [HorizontalBoardLayers.topCopper],
        usesConnectivity: false,
        placesPads: false,
        placesShapes: false,
        placesHoles: false,
        allowsGraphics: true,
        allowsPolygons: true,
        allowsText: true,
        defaultDrawingLayer: HorizontalBoardLayers.topSilkscreen
    )

    static func profile(for mode: HorizontalBoardEditorMode) -> HorizontalBoardModeProfile {
        switch mode {
        case .board: .board
        case .package: .package
        case .padstack: .padstack
        case .decal: .decal
        }
    }
}

extension BoardDisplayOptions {
    /// What a pool item editor shows by default: every layer of the item's
    /// kind, pads and holes with their labels, no board-only objects. A
    /// padstack shows mask and paste because they are what it defines; a
    /// package hides them the way the library preview does, so the copper
    /// footprint reads clearly.
    mutating func poolEditor(mode: HorizontalBoardEditorMode) {
        showAll()
        // A package has no vias to hide in 2D, and the 3D view keys its
        // through-hole pad barrels on this flag: off, only SMD and
        // non-round pads would show.
        vias = true
        viaLabels = false
        connectionLines = false
        connectionLabels = false
        decals = false
        trackLabels = false
        panelLabels = false
        boardBody = false
        planeFills = false
        fabrication = false
        userLayers = false
        pads = true
        holes = true
        packages = true
        text = true
        keepouts = mode == .package
        dimensions = mode == .package
        padLabels = mode == .package
        solderMask = mode == .padstack
        paste = mode == .padstack
        layerVisibilityOverrides.removeAll()
        layerFillOverrides.removeAll()
    }
}
