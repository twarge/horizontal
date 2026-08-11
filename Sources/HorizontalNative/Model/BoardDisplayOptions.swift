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
    var viaLabels = false
    var pads = true
    var padLabels = true
    var holes = true
    var packages = true
    var text = true
    var connectionLines = false
    var connectionLabels = false
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
    var layerOpacity = 0.6
    var highlightMode = "dim_other"
    var layerMode = "as_is"
    var layerVisibilityOverrides: [Int: Bool] = [:]
    /// The layer selected in the layer list, forced visible by `isLayerVisible`.
    /// Derived, not a setting: the canvas is handed options with this stamped
    /// from the current selection, so any decoded value is overwritten.
    var selectedLayer: Int?
    /// Solo: when set, ONLY this layer is visible, whatever any eye or category
    /// says. Also derived, and deliberately a separate field rather than a pile
    /// of visibility overrides — clearing it restores exactly what the user had
    /// set before, with nothing to save or put back.
    var soloLayer: Int?
    var layerFillOverrides: [Int: Bool] = [:]

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
        layerOpacity = try container.decodeIfPresent(Double.self, forKey: .layerOpacity) ?? defaults.layerOpacity
        highlightMode = try container.decodeIfPresent(String.self, forKey: .highlightMode) ?? defaults.highlightMode
        layerMode = try container.decodeIfPresent(String.self, forKey: .layerMode) ?? defaults.layerMode
        layerVisibilityOverrides = try container.decodeIfPresent([Int: Bool].self, forKey: .layerVisibilityOverrides) ?? defaults.layerVisibilityOverrides
        layerFillOverrides = try container.decodeIfPresent([Int: Bool].self, forKey: .layerFillOverrides) ?? defaults.layerFillOverrides
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
        dimensions = true
        decals = true
        trackLabels = true
        vias = true
        viaLabels = false
        pads = true
        padLabels = true
        holes = true
        packages = true
        text = true
        connectionLines = true
        connectionLabels = false
        keepouts = true
        scaleBar = true
        coordinates = true
        orientationAxes = false
        threeDModels = true
        threeDModelMode = .placed
        threeDCopperMode = .on
        threeDBackground = true
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
        dimensions = false
        decals = false
        trackLabels = false
        vias = true
        viaLabels = false
        pads = true
        padLabels = false
        holes = true
        packages = false
        text = false
        connectionLines = true
        connectionLabels = false
        keepouts = true
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
        dimensions = true
        decals = true
        trackLabels = false
        vias = false
        viaLabels = false
        pads = false
        padLabels = false
        holes = true
        packages = true
        text = true
        connectionLines = false
        connectionLabels = false
        keepouts = false
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
        dimensions = false
        decals = false
        trackLabels = true
        vias = true
        viaLabels = true
        pads = true
        padLabels = false
        holes = true
        packages = false
        text = false
        connectionLines = true
        connectionLabels = true
        keepouts = true
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
        dimensions = true
        decals = true
        trackLabels = false
        vias = false
        viaLabels = false
        pads = false
        padLabels = false
        holes = true
        packages = false
        text = true
        connectionLines = false
        connectionLabels = false
        keepouts = false
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
        dimensions = true
        decals = false
        trackLabels = false
        vias = false
        viaLabels = false
        pads = false
        padLabels = false
        holes = true
        packages = false
        text = true
        connectionLines = false
        connectionLabels = false
        keepouts = true
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
        dimensions = false
        decals = false
        trackLabels = false
        vias = false
        viaLabels = false
        pads = true
        padLabels = true
        holes = true
        packages = true
        text = true
        connectionLines = false
        connectionLabels = false
        keepouts = false
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
            ],
            mode: .silkscreen
        )
    }

    mutating func bottomSilkscreenView() {
        layerView(
            layers: [
                HorizontalBoardLayers.bottomMask,
                HorizontalBoardLayers.bottomSilkscreen,
                HorizontalBoardLayers.outline
            ],
            mode: .silkscreen
        )
    }

    mutating func topPlacementView() {
        layerView(
            layers: [
                HorizontalBoardLayers.topCopper,
                HorizontalBoardLayers.topCourtyard
            ],
            mode: .placement
        )
    }

    mutating func bottomPlacementView() {
        layerView(
            layers: [
                HorizontalBoardLayers.bottomCopper,
                HorizontalBoardLayers.bottomCourtyard
            ],
            mode: .placement
        )
    }

    mutating func apply(_ preset: HorizontalBoardLayerViewPreset) {
        switch preset {
        case .topPlacement: topPlacementView()
        case .bottomPlacement: bottomPlacementView()
        case .topSilkscreen: topSilkscreenView()
        case .bottomSilkscreen: bottomSilkscreenView()
        }
    }

    mutating func topRoutingView() {
        layerView(layers: [HorizontalBoardLayers.topCopper], mode: .routing)
    }

    mutating func bottomRoutingView() {
        layerView(layers: [HorizontalBoardLayers.bottomCopper], mode: .routing)
    }

    mutating func cleanView() {
        showAll()
        grid = false
        origin = false
        connectionLines = false
        connectionLabels = false
        scaleBar = false
        coordinates = false
        orientationAxes = false
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

        return layerFillOverrides[layer] ?? planeFills
    }

    mutating func setLayerFilled(_ layer: Int, isFilled: Bool) {
        if isFilled == planeFills {
            layerFillOverrides.removeValue(forKey: layer)
        } else {
            layerFillOverrides[layer] = isFilled
        }
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

    private enum LayerPresetMode {
        case silkscreen
        case placement
        case routing
    }

    private mutating func layerView(layers: Set<Int>, mode: LayerPresetMode) {
        grid = true
        boardBody = false
        panelLabels = false
        origin = false
        dimensions = false
        decals = true
        // Presets intentionally leave via visibility (`vias`), all label
        // visibility (`viaLabels`, `padLabels`, `trackLabels`) and `planes`
        // untouched. Planes follow their copper layer; the others are controlled
        // independently of the Silk/Placement/Routing presets.
        connectionLines = false
        connectionLabels = false
        keepouts = false
        scaleBar = true
        coordinates = true
        orientationAxes = false

        switch mode {
        case .silkscreen:
            pads = false
            holes = false
            packages = true
            text = true
        case .placement:
            pads = true
            holes = true
            packages = true
            text = true
        case .routing:
            pads = true
            holes = true
            packages = false
            text = false
        }

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
