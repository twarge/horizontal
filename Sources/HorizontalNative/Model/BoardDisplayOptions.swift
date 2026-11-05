import Foundation

enum HorizontalBoardSceneProjection: String, CaseIterable, Codable, Hashable, Identifiable {
    case perspective
    case orthogonal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perspective: "Perspective"
        case .orthogonal: "Orthogonal"
        }
    }
}

enum HorizontalBoardSceneCopperMode: String, CaseIterable, Codable, Hashable, Identifiable {
    case off
    case on
    case layerColor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .layerColor: "Layer Color"
        }
    }
}

enum HorizontalBoardSceneModelMode: String, CaseIterable, Codable, Hashable, Identifiable {
    case none
    case placed
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .placed: "Placed"
        case .all: "All"
        }
    }
}

/// The layer rail's Layer Mode: which of the board's stackup draws, from the
/// working layer (`BoardDisplayOptions.selectedLayer`, the one the drawing
/// tools are on). It only ever hides: a layer it keeps draws as its eye says,
/// and the working layer always does. See `BoardDisplayOptions.isLayerVisible`.
enum HorizontalBoardLayerMode: String, CaseIterable, Codable, Hashable, Identifiable {
    /// Layers draw as their eyes, the working layer and solo say.
    case asIs = "as_is"
    /// Of the copper, only the working layer draws, with the surface layers
    /// of its side.
    case currentOnly = "current_only"
    /// The working layer and the copper right above and below it in the
    /// stackup draw, with the surface layers of an outer one among them.
    case currentAndAdjacent = "current_adjacent"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asIs: "As is"
        case .currentOnly: "Current only"
        case .currentAndAdjacent: "Current and adjacent"
        }
    }
}

struct BoardDisplayOptions: Codable, Equatable, Hashable {
    var grid = true
    var topCopper = true
    var innerCopper = true
    var bottomCopper = true
    var silkscreen = true
    var solderMask = true
    var paste = true
    var boardBody = true
    var outline = true
    var panelLabels = true
    var origin = true
    var fabrication = true
    var userLayers = true
    var planeFills = true
    var dimensions = true
    var decals = true
    var trackLabels = true
    var vias = true
    var viaLabels = true
    var pads = true
    var padLabels = true
    var holes = true
    var packages = true
    var text = true
    var connectionLines = true
    var connectionLabels = true
    var keepouts = true
    var scaleBar = true
    var coordinates = true
    var orientationAxes = false
    var threeDProjection: HorizontalBoardSceneProjection = .perspective
    var threeDExplode = 0.0
    var threeDBackground = true
    var threeDSolderMaskTransparency = 0.30
    var threeDViaPlatingMicrons = 12.0
    var threeDCopperMode: HorizontalBoardSceneCopperMode = .on {
        didSet {
            threeDUseLayerColors = threeDCopperMode == .layerColor
        }
    }
    var threeDModelMode: HorizontalBoardSceneModelMode = .placed {
        didSet {
            threeDModels = threeDModelMode != .none
        }
    }
    var threeDModels = true
    var threeDUseLayerColors = false
    /// The 3D view's own surface toggles. Independent of the 2D layer eyes
    /// (`silkscreen`, `solderMask`, `paste`, `boardBody`), so hiding the
    /// silkscreen or substrate in one view leaves the other alone.
    var threeDSilkscreen = true
    var threeDSolderMask = true
    var threeDPaste = true
    var threeDBoardBody = true
    var layerOpacity = 0.6
    var highlightMode = "dim_other"
    var layerMode: HorizontalBoardLayerMode = .asIs
    var layerVisibilityOverrides: [Int: Bool] = [:]
    /// The layer selected in the layer list, forced visible by `isLayerVisible`.
    /// Derived, not a setting: the canvas is handed options with this stamped
    /// from the current selection, so any decoded value is overwritten.
    var selectedLayer: Int?
    /// The board's copper layers top to bottom (`HorizontalBoard.copperStack`),
    /// which Current and Adjacent takes the working layer's neighbours from.
    /// Derived like `selectedLayer`, stamped from the board as the canvas is
    /// handed the options; nil reads as a two-layer board.
    var copperStack: [Int]?
    /// Solo: when set, ONLY this layer is visible, whatever any eye or category
    /// says. Also derived, and deliberately a separate field rather than a pile
    /// of visibility overrides — clearing it restores exactly what the user had
    /// set before, with nothing to save or put back.
    var soloLayer: Int?
    var layerFillOverrides: [Int: Bool] = [:]
    /// The nets whose airwires the board leaves out (Design ▸ Filter
    /// Airwires…), by net uuid, lowercased. Only the view changes: check
    /// still reports every unrouted connection. A net the board no longer
    /// has is never asked about, so it is simply ignored.
    var hiddenAirwireNetIDs: Set<String> = []

    init() { }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        grid = try container.decodeIfPresent(Bool.self, forKey: .grid) ?? defaults.grid
        topCopper = try container.decodeIfPresent(Bool.self, forKey: .topCopper) ?? defaults.topCopper
        innerCopper = try container.decodeIfPresent(Bool.self, forKey: .innerCopper) ?? defaults.innerCopper
        bottomCopper = try container.decodeIfPresent(Bool.self, forKey: .bottomCopper) ?? defaults.bottomCopper
        silkscreen = try container.decodeIfPresent(Bool.self, forKey: .silkscreen) ?? defaults.silkscreen
        solderMask = try container.decodeIfPresent(Bool.self, forKey: .solderMask) ?? defaults.solderMask
        paste = try container.decodeIfPresent(Bool.self, forKey: .paste) ?? defaults.paste
        boardBody = try container.decodeIfPresent(Bool.self, forKey: .boardBody) ?? defaults.boardBody
        outline = try container.decodeIfPresent(Bool.self, forKey: .outline) ?? defaults.outline
        panelLabels = try container.decodeIfPresent(Bool.self, forKey: .panelLabels) ?? defaults.panelLabels
        origin = try container.decodeIfPresent(Bool.self, forKey: .origin) ?? defaults.origin
        fabrication = try container.decodeIfPresent(Bool.self, forKey: .fabrication) ?? defaults.fabrication
        userLayers = try container.decodeIfPresent(Bool.self, forKey: .userLayers) ?? defaults.userLayers
        planeFills = try container.decodeIfPresent(Bool.self, forKey: .planeFills) ?? defaults.planeFills
        dimensions = try container.decodeIfPresent(Bool.self, forKey: .dimensions) ?? defaults.dimensions
        decals = try container.decodeIfPresent(Bool.self, forKey: .decals) ?? defaults.decals
        trackLabels = try container.decodeIfPresent(Bool.self, forKey: .trackLabels) ?? defaults.trackLabels
        vias = try container.decodeIfPresent(Bool.self, forKey: .vias) ?? defaults.vias
        viaLabels = try container.decodeIfPresent(Bool.self, forKey: .viaLabels) ?? defaults.viaLabels
        pads = try container.decodeIfPresent(Bool.self, forKey: .pads) ?? defaults.pads
        padLabels = try container.decodeIfPresent(Bool.self, forKey: .padLabels) ?? defaults.padLabels
        holes = try container.decodeIfPresent(Bool.self, forKey: .holes) ?? defaults.holes
        packages = try container.decodeIfPresent(Bool.self, forKey: .packages) ?? defaults.packages
        text = try container.decodeIfPresent(Bool.self, forKey: .text) ?? defaults.text
        connectionLines = try container.decodeIfPresent(Bool.self, forKey: .connectionLines) ?? defaults.connectionLines
        connectionLabels = try container.decodeIfPresent(Bool.self, forKey: .connectionLabels) ?? defaults.connectionLabels
        keepouts = try container.decodeIfPresent(Bool.self, forKey: .keepouts) ?? defaults.keepouts
        scaleBar = try container.decodeIfPresent(Bool.self, forKey: .scaleBar) ?? defaults.scaleBar
        coordinates = try container.decodeIfPresent(Bool.self, forKey: .coordinates) ?? defaults.coordinates
        orientationAxes = try container.decodeIfPresent(Bool.self, forKey: .orientationAxes) ?? defaults.orientationAxes
        if let projectionRawValue = try container.decodeIfPresent(String.self, forKey: .threeDProjection) {
            threeDProjection = HorizontalBoardSceneProjection(rawValue: projectionRawValue)
                ?? (projectionRawValue == "orthographic" ? .orthogonal : defaults.threeDProjection)
        } else {
            threeDProjection = defaults.threeDProjection
        }
        threeDExplode = try container.decodeIfPresent(Double.self, forKey: .threeDExplode) ?? defaults.threeDExplode
        threeDBackground = try container.decodeIfPresent(Bool.self, forKey: .threeDBackground) ?? defaults.threeDBackground
        threeDSolderMaskTransparency = try container.decodeIfPresent(Double.self, forKey: .threeDSolderMaskTransparency) ?? defaults.threeDSolderMaskTransparency
        threeDViaPlatingMicrons = try container.decodeIfPresent(Double.self, forKey: .threeDViaPlatingMicrons) ?? defaults.threeDViaPlatingMicrons
        let legacyUsesLayerColors = try container.decodeIfPresent(Bool.self, forKey: .threeDUseLayerColors) ?? defaults.threeDUseLayerColors
        if let copperModeRawValue = try container.decodeIfPresent(String.self, forKey: .threeDCopperMode) {
            threeDCopperMode = HorizontalBoardSceneCopperMode(rawValue: copperModeRawValue)
                ?? (legacyUsesLayerColors ? .layerColor : defaults.threeDCopperMode)
        } else {
            threeDCopperMode = legacyUsesLayerColors ? .layerColor : defaults.threeDCopperMode
        }

        let legacyShowsModels = try container.decodeIfPresent(Bool.self, forKey: .threeDModels) ?? defaults.threeDModels
        if let modelModeRawValue = try container.decodeIfPresent(String.self, forKey: .threeDModelMode) {
            threeDModelMode = HorizontalBoardSceneModelMode(rawValue: modelModeRawValue)
                ?? (legacyShowsModels ? defaults.threeDModelMode : .none)
        } else {
            threeDModelMode = legacyShowsModels ? defaults.threeDModelMode : .none
        }
        threeDModels = threeDModelMode != .none
        threeDUseLayerColors = threeDCopperMode == .layerColor
        threeDSilkscreen = try container.decodeIfPresent(Bool.self, forKey: .threeDSilkscreen) ?? defaults.threeDSilkscreen
        threeDSolderMask = try container.decodeIfPresent(Bool.self, forKey: .threeDSolderMask) ?? defaults.threeDSolderMask
        threeDPaste = try container.decodeIfPresent(Bool.self, forKey: .threeDPaste) ?? defaults.threeDPaste
        threeDBoardBody = try container.decodeIfPresent(Bool.self, forKey: .threeDBoardBody) ?? defaults.threeDBoardBody
        layerOpacity = try container.decodeIfPresent(Double.self, forKey: .layerOpacity) ?? defaults.layerOpacity
        highlightMode = try container.decodeIfPresent(String.self, forKey: .highlightMode) ?? defaults.highlightMode
        layerMode = try container.decodeIfPresent(String.self, forKey: .layerMode)
            .flatMap(HorizontalBoardLayerMode.init(rawValue:)) ?? defaults.layerMode
        layerVisibilityOverrides = try container.decodeIfPresent([Int: Bool].self, forKey: .layerVisibilityOverrides) ?? defaults.layerVisibilityOverrides
        layerFillOverrides = try container.decodeIfPresent([Int: Bool].self, forKey: .layerFillOverrides) ?? defaults.layerFillOverrides
        hiddenAirwireNetIDs = Set((try container.decodeIfPresent([String].self, forKey: .hiddenAirwireNetIDs) ?? []).map { $0.lowercased() })
    }

    mutating func showAll() {
        grid = true
        topCopper = true
        innerCopper = true
        bottomCopper = true
        silkscreen = true
        solderMask = true
        paste = true
        boardBody = true
        outline = true
        panelLabels = true
        origin = true
        fabrication = true
        userLayers = true
        scaleBar = true
        coordinates = true
        orientationAxes = false
        threeDModels = true
        threeDModelMode = .placed
        threeDCopperMode = .on
        threeDBackground = true
        threeDSilkscreen = true
        threeDSolderMask = true
        threeDPaste = true
        threeDBoardBody = true
        layerVisibilityOverrides.removeAll()
    }

    mutating func copperOnly() {
        grid = true
        topCopper = true
        innerCopper = true
        bottomCopper = true
        silkscreen = false
        solderMask = false
        paste = false
        boardBody = false
        outline = false
        panelLabels = false
        origin = false
        fabrication = false
        userLayers = false
        scaleBar = true
        coordinates = true
        orientationAxes = false
        layerVisibilityOverrides.removeAll()
    }

    mutating func assemblyOnly() {
        grid = false
        topCopper = false
        innerCopper = false
        bottomCopper = false
        silkscreen = true
        solderMask = false
        paste = false
        boardBody = true
        outline = true
        panelLabels = true
        origin = false
        fabrication = true
        userLayers = false
        scaleBar = true
        coordinates = true
        orientationAxes = false
        layerVisibilityOverrides.removeAll()
    }

    mutating func routingOnly() {
        grid = true
        topCopper = true
        innerCopper = true
        bottomCopper = true
        silkscreen = false
        solderMask = false
        paste = false
        boardBody = false
        outline = true
        panelLabels = false
        origin = true
        fabrication = false
        userLayers = false
        scaleBar = true
        coordinates = true
        orientationAxes = false
        layerVisibilityOverrides.removeAll()
    }

    mutating func fabricationOnly() {
        grid = false
        topCopper = false
        innerCopper = false
        bottomCopper = false
        silkscreen = true
        solderMask = true
        paste = true
        boardBody = true
        outline = true
        panelLabels = true
        origin = true
        fabrication = true
        userLayers = true
        scaleBar = true
        coordinates = true
        orientationAxes = false
        layerVisibilityOverrides.removeAll()
    }

    mutating func mechanicalOnly() {
        grid = true
        topCopper = false
        innerCopper = false
        bottomCopper = false
        silkscreen = false
        solderMask = false
        paste = false
        boardBody = true
        outline = true
        panelLabels = true
        origin = true
        fabrication = true
        userLayers = true
        scaleBar = true
        coordinates = true
        orientationAxes = false
        layerVisibilityOverrides.removeAll()
    }

    mutating func footprintsOnly() {
        grid = true
        topCopper = false
        innerCopper = false
        bottomCopper = false
        silkscreen = true
        solderMask = false
        paste = true
        boardBody = true
        outline = true
        panelLabels = true
        origin = false
        fabrication = false
        userLayers = false
        scaleBar = true
        coordinates = true
        orientationAxes = false
        layerVisibilityOverrides.removeAll()
    }

    mutating func topSilkscreenView() {
        layerView(
            layers: [
                HorizontalBoardLayers.topMask,
                HorizontalBoardLayers.topSilkscreen,
                HorizontalBoardLayers.outline
            ]
        )
    }

    mutating func bottomSilkscreenView() {
        layerView(
            layers: [
                HorizontalBoardLayers.bottomMask,
                HorizontalBoardLayers.bottomSilkscreen,
                HorizontalBoardLayers.outline
            ]
        )
    }

    mutating func topPlacementView() {
        layerView(
            layers: [
                HorizontalBoardLayers.topCopper,
                HorizontalBoardLayers.topAssembly,
                HorizontalBoardLayers.topCourtyard,
                HorizontalBoardLayers.outline
            ]
        )
    }

    mutating func bottomPlacementView() {
        layerView(
            layers: [
                HorizontalBoardLayers.bottomCopper,
                HorizontalBoardLayers.bottomAssembly,
                HorizontalBoardLayers.bottomCourtyard,
                HorizontalBoardLayers.outline
            ]
        )
    }

    mutating func topRoutingView() {
        layerView(layers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.outline])
    }

    mutating func bottomRoutingView() {
        layerView(layers: [HorizontalBoardLayers.bottomCopper, HorizontalBoardLayers.outline])
    }

    /// The view a board opens on: `saved` (the file's remembered view, or the
    /// defaults when it has none) showing the top placement layers. The
    /// object switches, fills and 3D settings it holds stay as they were.
    static func opening(_ saved: BoardDisplayOptions?) -> BoardDisplayOptions {
        var options = saved ?? BoardDisplayOptions()
        options.topPlacementView()
        return options
    }

    mutating func cleanView() {
        showAll()
        grid = false
        origin = false
        scaleBar = false
        coordinates = false
        orientationAxes = false
    }

    /// Whether the board outline is drawn as the Outline layer: its eye, the
    /// working layer and solo, as for any layer, rather than the Outline
    /// category alone. A layer preset that leaves the outline out clears the
    /// category, and the eye turned back on then marks the layer seen with an
    /// override, which the outline's stroke didn't follow.
    var showsOutlineLayer: Bool {
        isLayerVisible(HorizontalBoardLayers.outline)
    }

    /// Whether the airwire filter lets a net's airwires draw. The Connections
    /// switch is asked separately: with it off none draw, whatever this says.
    func showsAirwires(ofNet netID: String?) -> Bool {
        guard let netID, !hiddenAirwireNetIDs.isEmpty else {
            return true
        }
        return !hiddenAirwireNetIDs.contains(netID.lowercased())
    }

    mutating func setAirwiresShown<Nets: Sequence<String>>(_ isShown: Bool, forNets netIDs: Nets) {
        for netID in netIDs {
            if isShown {
                hiddenAirwireNetIDs.remove(netID.lowercased())
            } else {
                hiddenAirwireNetIDs.insert(netID.lowercased())
            }
        }
    }

    /// Whether any of a via's copper shows. The canvas draws a via's ring on
    /// its copper layers that show, and its net name only with a ring: a view
    /// with none of them, a silkscreen view say, leaves the label out too.
    func showsCopper(of via: HorizontalMarker) -> Bool {
        via.copperLayers.contains { isLayerVisible($0) }
    }

    func isLayerVisible(_ layer: Int?) -> Bool {
        guard let layer else {
            return true
        }

        // Solo wins over everything: it is the most recent and most explicit
        // instruction about what to look at.
        if let soloLayer {
            return layer == soloLayer
        }

        // The working layer is always shown, whatever its eye says. Drawing into
        // a layer you cannot see is how work gets lost, and selecting a layer is
        // a clearer statement of intent than a visibility toggle set earlier.
        // Not persisted: `selectedLayer` is set from the current selection each
        // time the options are handed to the canvas.
        if let selectedLayer, layer == selectedLayer {
            return true
        }

        // The layer mode hides the stackup away from the working layer, and
        // shows nothing an eye hides: within what it keeps, the eyes decide.
        if !layerModeKeeps(layer) {
            return false
        }

        if let override = layerVisibilityOverrides[layer] {
            return override
        }

        return isLayerCategoryVisible(layer)
    }

    mutating func setLayerVisibility(_ layer: Int, isVisible: Bool) {
        if isVisible == isLayerCategoryVisible(layer) {
            layerVisibilityOverrides.removeValue(forKey: layer)
        } else {
            layerVisibilityOverrides[layer] = isVisible
        }
    }

    func isLayerFilled(_ layer: Int?) -> Bool {
        guard let layer else {
            return planeFills
        }

        return layerFillOverrides[layer] ?? isLayerFilledByDefault(layer)
    }

    mutating func setLayerFilled(_ layer: Int, isFilled: Bool) {
        if isFilled == isLayerFilledByDefault(layer) {
            layerFillOverrides.removeValue(forKey: layer)
        } else {
            layerFillOverrides[layer] = isFilled
        }
    }

    /// The fill a layer has until its own switch is set. The solder masks
    /// start as outlines: a mask opening drawn filled covers the pad it opens.
    private func isLayerFilledByDefault(_ layer: Int) -> Bool {
        planeFills && HorizontalBoardLayers.category(for: layer) != .solderMask
    }

    private func isLayerCategoryVisible(_ layer: Int) -> Bool {
        switch HorizontalBoardLayers.category(for: layer) {
        case .topCopper:
            return topCopper
        case .innerCopper:
            return innerCopper
        case .bottomCopper:
            return bottomCopper
        case .silkscreen:
            return silkscreen
        case .solderMask:
            return solderMask
        case .paste:
            return paste
        case .outline:
            return outline
        case .user:
            return userLayers
        case .fabrication, .other:
            return fabrication
        }
    }

    /// A sided view: only `layers` and the view furniture — the grid, the
    /// origin mark, the scale bar and the coordinates, as the schematic shows
    /// them. The objects (pads, holes, packages, text, labels, connections
    /// and the rest) are the user's own switches, which no view preset
    /// touches; what of them shows follows the layers they are on.
    private mutating func layerView(layers: Set<Int>) {
        grid = true
        boardBody = false
        panelLabels = false
        origin = true
        scaleBar = true
        coordinates = true
        orientationAxes = false

        showOnlyLayers(layers)
    }

    private mutating func showOnlyLayers(_ layers: Set<Int>) {
        topCopper = layers.contains(HorizontalBoardLayers.topCopper)
        innerCopper = layers.contains { HorizontalBoardLayers.category(for: $0) == .innerCopper }
        bottomCopper = layers.contains(HorizontalBoardLayers.bottomCopper)
        silkscreen = layers.contains { HorizontalBoardLayers.category(for: $0) == .silkscreen }
        solderMask = layers.contains { HorizontalBoardLayers.category(for: $0) == .solderMask }
        paste = layers.contains { HorizontalBoardLayers.category(for: $0) == .paste }
        outline = layers.contains { HorizontalBoardLayers.category(for: $0) == .outline }
        fabrication = layers.contains { HorizontalBoardLayers.category(for: $0) == .fabrication }
        userLayers = layers.contains { HorizontalBoardLayers.category(for: $0) == .user }

        layerVisibilityOverrides.removeAll()
        for layer in HorizontalBoardLayers.all {
            let shouldShow = layers.contains(layer)
            if shouldShow != isLayerCategoryVisible(layer) {
                layerVisibilityOverrides[layer] = shouldShow
            }
        }
    }
}

/// The layer views a request can ask for by name — the presets the board rail
/// offers, plus all layers, copper only and the clean view — so a spoken "show
/// the top layer" and an agent's `show_layers` mean the same thing. The bare
/// side ("the top layer") is the placement view: copper, assembly and
/// courtyard, which is what one looks at when working on that side.
enum HorizontalBoardSide: String {
    case top
    case bottom

    var other: HorizontalBoardSide { self == .top ? .bottom : .top }

    /// The copper the drawing tools should be on when this side is up.
    var copperLayer: Int { self == .top ? HorizontalBoardLayers.topCopper : HorizontalBoardLayers.bottomCopper }

    var silkscreenLayer: Int { self == .top ? HorizontalBoardLayers.topSilkscreen : HorizontalBoardLayers.bottomSilkscreen }
}

enum HorizontalBoardLayerPreset: String, CaseIterable {
    case topPlacement = "top_placement"
    case topSilkscreen = "top_silkscreen"
    case topRouting = "top_routing"
    case bottomPlacement = "bottom_placement"
    case bottomSilkscreen = "bottom_silkscreen"
    case bottomRouting = "bottom_routing"
    /// The placement view of a side, seen from that side: the bottom view
    /// mirrors the board, the way turning it over does.
    case topView = "top_view"
    case bottomView = "bottom_view"
    /// The other side's view from whichever is up.
    case flipView = "flip_view"
    /// A mode with the side left to context: the side that is up now.
    case placement
    case silkscreen
    case routing
    case all
    case copperOnly = "copper_only"
    case clean

    /// The preset as a message names it: "showing the top layer".
    var spokenTitle: String {
        switch self {
        case .topPlacement: "the top layer"
        case .topSilkscreen: "the top silkscreen"
        case .topRouting: "top routing"
        case .bottomPlacement: "the bottom layer"
        case .bottomSilkscreen: "the bottom silkscreen"
        case .bottomRouting: "bottom routing"
        case .topView: "the top of the board"
        case .bottomView: "the bottom of the board"
        case .flipView: "the other side"
        case .placement: "placement"
        case .silkscreen: "the silkscreen"
        case .routing: "routing"
        case .all: "all layers"
        case .copperOnly: "copper only"
        case .clean: "the clean view"
        }
    }

    /// The side this preset is about, or nil when it is about neither.
    var side: HorizontalBoardSide? {
        switch self {
        case .topPlacement, .topSilkscreen, .topRouting, .topView: .top
        case .bottomPlacement, .bottomSilkscreen, .bottomRouting, .bottomView: .bottom
        default: nil
        }
    }

    /// The layer the drawing tools go on with this preset: the side's
    /// silkscreen for a silkscreen view, its copper for the rest, nil for a
    /// preset about neither side.
    var drawingLayer: Int? {
        switch self {
        case .topSilkscreen, .bottomSilkscreen: side?.silkscreenLayer
        default: side?.copperLayer
        }
    }

    /// Whether the preset leaves the view mirrored — the bottom view — or
    /// not, or says nothing about it (nil).
    var mirrorsView: Bool? {
        switch self {
        case .bottomView: true
        case .topView: false
        default: nil
        }
    }

    /// The preset with its side decided: a side-less one takes `side`, the
    /// flip takes the other side, and the rest are what they were.
    func resolved(for side: HorizontalBoardSide) -> HorizontalBoardLayerPreset {
        switch self {
        case .placement: side == .top ? .topPlacement : .bottomPlacement
        case .silkscreen: side == .top ? .topSilkscreen : .bottomSilkscreen
        case .routing: side == .top ? .topRouting : .bottomRouting
        case .flipView: side == .top ? .bottomView : .topView
        default: self
        }
    }
}

extension BoardDisplayOptions {
    /// Side-less presets have to be `resolved` first; unresolved, they are
    /// read as the top side.
    mutating func applyLayerPreset(_ preset: HorizontalBoardLayerPreset) {
        switch preset.resolved(for: .top) {
        case .topPlacement, .topView: topPlacementView()
        case .topSilkscreen: topSilkscreenView()
        case .topRouting: topRoutingView()
        case .bottomPlacement, .bottomView: bottomPlacementView()
        case .bottomSilkscreen: bottomSilkscreenView()
        case .bottomRouting: bottomRoutingView()
        case .all: showAll()
        case .copperOnly: copperOnly()
        case .clean: cleanView()
        case .placement, .silkscreen, .routing, .flipView: break
        }
    }

    /// The side the view is about, read from what is visible: one side's
    /// copper or silkscreen showing and not the other's. Nil when both or
    /// neither show — the all-layers view, say — which no side owns.
    var visibleSide: HorizontalBoardSide? {
        let top = isLayerVisible(HorizontalBoardLayers.topCopper) || isLayerVisible(HorizontalBoardLayers.topSilkscreen)
        let bottom = isLayerVisible(HorizontalBoardLayers.bottomCopper) || isLayerVisible(HorizontalBoardLayers.bottomSilkscreen)
        switch (top, bottom) {
        case (true, false): return .top
        case (false, true): return .bottom
        default: return nil
        }
    }

    /// Which of the side's views is showing, read from its layers as
    /// `visibleSide` is, since the views differ only in those: the side's
    /// silkscreen without its copper is the silkscreen view, its copper
    /// without its courtyard the routing view, and anything else placement.
    func visibleViewMode(on side: HorizontalBoardSide) -> HorizontalBoardLayerPreset {
        let courtyard = side == .top ? HorizontalBoardLayers.topCourtyard : HorizontalBoardLayers.bottomCourtyard
        let copper = isLayerVisible(side.copperLayer)
        if isLayerVisible(side.silkscreenLayer), !copper {
            return .silkscreen
        }
        return copper && !isLayerVisible(courtyard) ? .routing : .placement
    }
}

extension BoardDisplayOptions {
    /// Whether the layer mode leaves `layer` to its eye, read from the working
    /// layer. Only the stackup is the mode's: the copper, and each side's
    /// surface layers (`surfaceSide(of:)`), which go with that side's outer
    /// copper, or with the working layer when it is one of them. The outline,
    /// the user layers and the dimensions are left to their eyes in every
    /// mode. With no working layer stamped — the rail's own eyes, the 3D
    /// view — every mode reads as As is.
    private func layerModeKeeps(_ layer: Int) -> Bool {
        guard layerMode != .asIs, let selectedLayer else {
            return true
        }
        if HorizontalBoardLayers.isCopper(layer) {
            return layerModeDraws(copper: layer, workingLayer: selectedLayer)
        }
        guard let side = Self.surfaceSide(of: layer) else {
            return true
        }
        return Self.surfaceSide(of: selectedLayer) == side
            || layerModeDraws(copper: side.copperLayer, workingLayer: selectedLayer)
    }

    /// Whether the layer mode draws a copper layer: the working layer, and in
    /// Current and Adjacent the copper next to it in `copperStack`. A surface
    /// layer working has no copper of its own, so Current Only draws none and
    /// Current and Adjacent the outer copper of its side, which it lies on.
    private func layerModeDraws(copper: Int, workingLayer: Int) -> Bool {
        switch layerMode {
        case .asIs:
            return true
        case .currentOnly:
            return copper == workingLayer
        case .currentAndAdjacent:
            guard HorizontalBoardLayers.isCopper(workingLayer) else {
                return Self.surfaceSide(of: workingLayer)?.copperLayer == copper
            }
            if copper == workingLayer {
                return true
            }
            let stack = copperStack ?? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
            guard let working = stack.firstIndex(of: workingLayer), let other = stack.firstIndex(of: copper) else {
                return false
            }
            return abs(working - other) == 1
        }
    }

    /// The side a surface layer is on: its mask, silkscreen, paste, package,
    /// assembly, courtyard and notes. Nil for copper and for the layers of
    /// neither side.
    static func surfaceSide(of layer: Int) -> HorizontalBoardSide? {
        switch layer {
        case HorizontalBoardLayers.topMask...HorizontalBoardLayers.topCourtyard, HorizontalBoardLayers.topNotes:
            return .top
        case HorizontalBoardLayers.bottomNotes...HorizontalBoardLayers.bottomMask:
            return .bottom
        default:
            return nil
        }
    }
}

extension HorizontalBoard {
    /// The board's copper layers top to bottom, as its stackup has them, for
    /// the layer mode's neighbours. Top and bottom are always there, so a
    /// stackup that lists no copper reads as a two-layer board.
    var copperStack: [Int] {
        let stackup = stackupLayers.map(\.layer).filter(HorizontalBoardLayers.isCopper)
        return Set(stackup + [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]).sorted(by: >)
    }
}
