import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum HorizontalCanvasKind: String, CaseIterable, Identifiable {
    case board
    case schematic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: "Board"
        case .schematic: "Schematic"
        }
    }
}

enum HorizontalPaletteMode: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum HorizontalAppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum HorizontalCursorSize: String, CaseIterable, Identifiable {
    case small
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .fullScreen: "Full Screen"
        }
    }
}

enum HorizontalSelectionHandleShape: String, CaseIterable, Identifiable, Hashable {
    case diamond
    case round

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diamond: "Diamond"
        case .round: "Round"
        }
    }

    var outerRadius: CGFloat {
        switch self {
        case .diamond: 10
        case .round: 8
        }
    }

    var innerRadius: CGFloat {
        outerRadius * 0.5
    }

    var metalValue: Float {
        switch self {
        case .diamond: 0
        case .round: 1
        }
    }
}

enum HorizontalOperationDefaults {
    static let readOnlyOperationKey = "operation.readOnly"

    /// Every build starts read-only, a fresh install included, and anyone can
    /// turn it off, in Settings or with a window's lock.
    static func readOnlyOperation(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: readOnlyOperationKey) != nil else {
            return true
        }
        return defaults.bool(forKey: readOnlyOperationKey)
    }
}

/// The board's lines that Settings gives a width of their own, in pixels on
/// screen. Each is the least it is drawn at, as a canvas's minimum line width
/// is, and neither goes under that minimum.
enum HorizontalLineWidthRole: String, CaseIterable, Identifiable {
    /// Airwires and drawn connection lines.
    case connectionLine
    /// A smashed text's line to its package, drawn while either is selected
    /// (Horizon's text owner annotation).
    case smashedConnectionLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connectionLine: "Connection lines"
        case .smashedConnectionLine: "Smashed connection lines"
        }
    }

    /// Connection lines at 2 px, a smashed text's line at the board's default
    /// minimum line width, what it was drawn at before it could be set.
    var defaultWidth: Double {
        switch self {
        case .connectionLine: 2
        case .smashedConnectionLine: HorizontalAppearanceSettings.defaultMinimumLineWidth
        }
    }

    static let range = HorizontalAppearanceSettings.lineWidthRange
}

enum HorizontalColorRole: String, CaseIterable, Identifiable {
    case background
    case grid
    case textOverlay
    case junction
    case net
    case bus
    case frame
    case airwire
    case pin
    case pinAnnotation
    case hiddenPin
    case symbolBoundingBox
    case hole
    case dimension
    case error
    case origin
    case connectionLine
    case noPopulate
    case projection
    case netTie
    case diffPair
    case selectableOuter
    case selectableInner
    case selectablePrelight
    case selectableAlways

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "Background"
        case .grid: "Grid"
        case .textOverlay: "Text Overlay"
        case .junction: "Junction"
        case .net: "Net"
        case .bus: "Bus"
        case .frame: "Frame"
        case .airwire: "Airwire"
        case .pin: "Pin"
        case .pinAnnotation: "Pin Annotation"
        case .hiddenPin: "Hidden Pin"
        case .symbolBoundingBox: "Symbol Bounds"
        case .hole: "Hole"
        case .dimension: "Dimension"
        case .error: "Error"
        case .origin: "Origin"
        case .connectionLine: "Connection Line"
        case .noPopulate: "Do Not Populate"
        case .projection: "Projection"
        case .netTie: "Net Tie"
        case .diffPair: "Differential Pair"
        case .selectableOuter: "Selection Outer"
        case .selectableInner: "Selection Inner"
        case .selectablePrelight: "Selection Hover"
        case .selectableAlways: "Selection Always"
        }
    }
}

struct HorizontalCanvasPalette {
    var colors: [HorizontalColorRole: Color]
    var layerColors: [Int: Color]

    var background: Color { color(.background) }
    var grid: Color { color(.grid) }
    var textOverlay: Color { color(.textOverlay) }
    var junction: Color { color(.junction) }
    var net: Color { color(.net) }
    var bus: Color { color(.bus) }
    var frame: Color { color(.frame) }
    var airwire: Color { color(.airwire) }
    var pin: Color { color(.pin) }
    var pinAnnotation: Color { color(.pinAnnotation) }
    var hiddenPin: Color { color(.hiddenPin) }
    var symbolBoundingBox: Color { color(.symbolBoundingBox) }
    var hole: Color { color(.hole) }
    var dimension: Color { color(.dimension) }
    var error: Color { color(.error) }
    var origin: Color { color(.origin) }
    var connectionLine: Color { color(.connectionLine) }
    var noPopulate: Color { color(.noPopulate) }
    var projection: Color { color(.projection) }
    var netTie: Color { color(.netTie) }
    var diffPair: Color { color(.diffPair) }
    var selectableOuter: Color { color(.selectableOuter) }
    var selectableInner: Color { color(.selectableInner) }
    var selectablePrelight: Color { color(.selectablePrelight) }
    var selectableAlways: Color { color(.selectableAlways) }
    var overlayBackground: Color { background.opacity(0.78) }

    func color(_ role: HorizontalColorRole) -> Color {
        colors[role] ?? HorizontalCanvasPalette.darkDefault.colors[role] ?? .white
    }

    func layerColor(for layer: Int?) -> Color {
        guard let layer else {
            return textOverlay
        }

        if let color = layerColors[layer] {
            return color
        }
        if HorizontalBoardLayers.isCopper(layer), layer != HorizontalBoardLayers.topCopper, layer != HorizontalBoardLayers.bottomCopper {
            return layerColors[HorizontalBoardLayers.in1Copper] ?? Self.innerCopper(HorizontalBoardLayers.in1Copper)
        }
        if HorizontalBoardLayers.isUser(layer) {
            return layerColors[HorizontalBoardLayers.user1] ?? Color(red: 0.25, green: 1, blue: 1)
        }
        return textOverlay
    }

    static let darkDefault = HorizontalCanvasPalette(
        colors: [
            .junction: rgb(0, 1, 0),
            .textOverlay: rgb(1, 1, 1),
            .hole: rgb(1, 1, 1),
            .dimension: rgb(1, 1, 1),
            .error: rgb(1, 0, 0),
            .net: rgb(0, 1, 0),
            .bus: rgb(1, 0.4, 0),
            .frame: rgb(0, 0.5, 0),
            .airwire: rgb(0, 1, 1),
            .pin: rgb(1, 1, 1),
            .pinAnnotation: rgb(1, 1, 1),
            .hiddenPin: rgb(0.5, 0.5, 0.5),
            .symbolBoundingBox: rgb(0.5, 0.5, 0.5),
            .diffPair: rgb(0.5, 1, 0),
            .background: rgb(0, 24.0 / 255.0, 64.0 / 255.0),
            .grid: rgb(0, 78.0 / 255.0, 208.0 / 255.0),
            .origin: rgb(0, 1, 0),
            .connectionLine: rgb(0.7, 0, 0.6),
            .noPopulate: rgb(0.8, 0.4, 0.4),
            .projection: rgb(0.7, 0.8, 0.3),
            .netTie: rgb(1, 0.1, 0.5),
            .selectableOuter: rgb(1, 0, 1),
            .selectableInner: rgb(0, 0, 0),
            .selectablePrelight: rgb(0.5, 0, 0.5),
            .selectableAlways: rgb(1, 1, 0),
        ],
        layerColors: darkLayerColors
    )

    static let boardLightDefault = HorizontalCanvasPalette(
        colors: darkDefault.colors.merging([
            .background: rgb(1, 1, 1),
            .grid: rgb(225.0 / 255.0, 225.0 / 255.0, 225.0 / 255.0),
            .textOverlay: rgb(0, 0, 0),
            .hole: rgb(146.0 / 255.0, 146.0 / 255.0, 146.0 / 255.0),
            .dimension: rgb(0, 0, 0),
            .pin: rgb(146.0 / 255.0, 146.0 / 255.0, 146.0 / 255.0),
            // The dark theme's cyan all but vanishes on white, more so at
            // the airwires' 72 % opacity, so a deep teal.
            .airwire: rgb(0, 0.42, 0.55),
        ]) { _, new in new },
        layerColors: lightLayerColors
    )

    static let schematicLightDefault = HorizontalCanvasPalette(
        colors: boardLightDefault.colors.merging([
            .background: rgb(1, 1, 1),
            .grid: rgb(224.0 / 255.0, 224.0 / 255.0, 224.0 / 255.0),
            .textOverlay: rgb(0, 0, 0),
            .junction: rgb(0, 132.0 / 255.0, 33.0 / 255.0),
            .net: rgb(0, 133.0 / 255.0, 0),
            .frame: rgb(0, 0, 0),
            .hole: rgb(0, 0, 0),
            .dimension: rgb(0, 0, 0),
            .noPopulate: rgb(252.0 / 255.0, 130.0 / 255.0, 0),
            // Black so pin lines + the symbol outline (both use `.pin`) and the
            // pin annotation read on a white schematic background.
            .pin: rgb(0, 0, 0),
            .pinAnnotation: rgb(0, 0, 0),
            .diffPair: rgb(0.4583333433, 0.7333333492, 0.1833333373),
            .netTie: rgb(58.0 / 255.0, 73.0 / 255.0, 147.0 / 255.0),
        ]) { _, new in new },
        layerColors: lightLayerColors
    )

    static let schematicDarkDefault = HorizontalCanvasPalette(
        colors: darkDefault.colors.merging([
            .junction: rgb(0, 1, 0),
            .frame: rgb(1, 1, 0),
            .pin: rgb(1, 1, 0),
            .netTie: rgb(140.0 / 255.0, 157.0 / 255.0, 234.0 / 255.0),
        ]) { _, new in new },
        layerColors: darkDefault.layerColors
    )

    /// The layer colours a palette of this mode starts with: board layers are
    /// the same whichever canvas draws them.
    static func defaultLayerColors(mode: HorizontalPaletteMode) -> [Int: Color] {
        switch mode {
        case .light: lightLayerColors
        case .dark: darkLayerColors
        }
    }

    static func defaultPalette(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) -> HorizontalCanvasPalette {
        switch (kind, mode) {
        case (.board, .light):
            boardLightDefault
        case (.schematic, .light):
            schematicLightDefault
        case (.board, .dark):
            darkDefault
        case (.schematic, .dark):
            schematicDarkDefault
        }
    }

    private static let darkLayerColors: [Int: Color] = [
        HorizontalBoardLayers.topNotes: rgb(1, 1, 1),
        HorizontalBoardLayers.outlineNotes: rgb(0.6, 0.6, 0),
        HorizontalBoardLayers.outline: rgb(0.6, 0.6, 0),
        HorizontalBoardLayers.topCourtyard: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topAssembly: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topPackage: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topPaste: rgb(0.8, 0.8, 0.8),
        HorizontalBoardLayers.topSilkscreen: rgb(0.9, 0.9, 0.9),
        // The mask layers are a mid grey, which no copper layer uses and
        // which reads on both backgrounds. Horizon's (1, .5, .5) is exactly
        // what red copper at the 60% default layer opacity becomes over a
        // white background, so in the light theme a mask opening inside a
        // copper ring drew in the copper's own colour; Horizon's bottom mask
        // was a green on green.
        HorizontalBoardLayers.topMask: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topCopper: rgb(1, 0, 0),
        HorizontalBoardLayers.in1Copper: innerCopper(HorizontalBoardLayers.in1Copper),
        HorizontalBoardLayers.in2Copper: innerCopper(HorizontalBoardLayers.in2Copper),
        HorizontalBoardLayers.in3Copper: innerCopper(HorizontalBoardLayers.in3Copper),
        HorizontalBoardLayers.in4Copper: innerCopper(HorizontalBoardLayers.in4Copper),
        HorizontalBoardLayers.in5Copper: innerCopper(HorizontalBoardLayers.in5Copper),
        HorizontalBoardLayers.in6Copper: innerCopper(HorizontalBoardLayers.in6Copper),
        HorizontalBoardLayers.in7Copper: innerCopper(HorizontalBoardLayers.in7Copper),
        HorizontalBoardLayers.in8Copper: innerCopper(HorizontalBoardLayers.in8Copper),
        HorizontalBoardLayers.bottomCopper: rgb(0, 0.5, 0),
        HorizontalBoardLayers.bottomMask: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.bottomSilkscreen: rgb(0.9, 0.9, 0.9),
        HorizontalBoardLayers.bottomPaste: rgb(0.8, 0.8, 0.8),
        HorizontalBoardLayers.bottomPackage: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.bottomAssembly: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.bottomCourtyard: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.bottomNotes: rgb(1, 1, 1),
        HorizontalBoardLayers.user1: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user2: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user3: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user4: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user5: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user6: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user7: rgb(0.25, 1, 1),
        HorizontalBoardLayers.user8: rgb(0.25, 1, 1),
        HorizontalBoardLayers.dimensions: rgb(1, 1, 1),
    ]

    /// The dark set's near-whites all but vanish on a white canvas, the more
    /// so at the 60 % layer opacity, so the light theme has its own: the
    /// neutral silkscreen, notes and dimensions mirror to near-black, as does
    /// Outline Notes, text drawn in the outline's olive; paste goes to a mid
    /// grey that still lets the copper show through, the user layers' pale
    /// cyan becomes a deep teal and the outline's olive darkens.
    /// Copper, the grey masks and the 0.5 grey package layers read on either
    /// background and stay as they are.
    private static let lightLayerColors: [Int: Color] = darkLayerColors.merging([
        HorizontalBoardLayers.topNotes: rgb(0, 0, 0),
        HorizontalBoardLayers.outlineNotes: rgb(0.1, 0.1, 0),
        HorizontalBoardLayers.outline: rgb(0.45, 0.45, 0),
        HorizontalBoardLayers.topPaste: rgb(0.45, 0.45, 0.45),
        HorizontalBoardLayers.topSilkscreen: rgb(0.1, 0.1, 0.1),
        HorizontalBoardLayers.bottomSilkscreen: rgb(0.1, 0.1, 0.1),
        HorizontalBoardLayers.bottomPaste: rgb(0.45, 0.45, 0.45),
        HorizontalBoardLayers.bottomNotes: rgb(0, 0, 0),
        HorizontalBoardLayers.user1: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user2: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user3: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user4: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user5: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user6: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user7: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.user8: rgb(0, 0.5, 0.55),
        HorizontalBoardLayers.dimensions: rgb(0, 0, 0),
    ]) { _, light in light }

    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    private static func innerCopper(_ layer: Int) -> Color {
        let color = HorizontalDefaultTheme.innerCopperRGB(for: layer)
        return rgb(color.red, color.green, color.blue)
    }
}

private struct HorizontalPaletteKey: Hashable {
    var kind: HorizontalCanvasKind
    var mode: HorizontalPaletteMode
}

@MainActor
final class HorizontalAppearanceSettings: ObservableObject {
    nonisolated static let defaultMinimumLineWidth: Double = 1.5
    static let defaultGridLineWidth: Double = 0.5
    /// Every line width Settings sets, the grid's marks, each canvas's
    /// minimum and the connection lines, in pixels: one range and one step,
    /// so their sliders run alike and carry the same ticks.
    nonisolated static let lineWidthRange: ClosedRange<Double> = 0.5...5
    nonisolated static let lineWidthStep: Double = 0.1

    /// `width` brought into `lineWidthRange`.
    nonisolated static func clampedLineWidth(_ width: Double) -> Double {
        min(max(width, lineWidthRange.lowerBound), lineWidthRange.upperBound)
    }

    @Published private var appTheme: HorizontalAppTheme
    @Published private var cursorSize: HorizontalCursorSize
    @Published private var selectionHandleShape: HorizontalSelectionHandleShape
    @Published private var showsHoverPopover: Bool
    @Published private var fillsNetLabelBackground: Bool
    @Published private var drawsWireHops: Bool
    @Published private var displaysCanvasWarnings: Bool
    @Published private var fillsClosedSymbolBackground: Bool
    @Published private var swapsViewControlsAndUnplacedReferences: Bool
    @Published private var transparentToolbar: Bool
    @Published private var readOnlyOperation: Bool
    @Published private var liveServerEnabled: Bool
    @Published private var boardSceneBackgroundColor: Color
    @Published private var boardSceneSubstrateColor: Color
    @Published private var boardSceneSolderMaskColor: Color
    @Published private var boardSceneSilkscreenColor: Color
    @Published private var boardSceneCopperColor: Color
    @Published private var palettes = [HorizontalPaletteKey: HorizontalCanvasPalette]()
    @Published private var layerColorSets = [HorizontalPaletteMode: [Int: Color]]()
    @Published private var minimumLineWidths = [HorizontalCanvasKind: Double]()
    @Published private var gridLineWidth: Double
    @Published private var roleLineWidths = [HorizontalLineWidthRole: Double]()
    @Published private var clipsSilkscreenToSolderMask: Bool
    @Published private var silkscreenMaskClearanceMM: Double

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appTheme = Self.loadAppTheme(defaults: defaults)
        cursorSize = Self.loadCursorSize(defaults: defaults)
        selectionHandleShape = Self.loadSelectionHandleShape(defaults: defaults)
        showsHoverPopover = Self.loadShowsHoverPopover(defaults: defaults)
        fillsNetLabelBackground = Self.loadFillsNetLabelBackground(defaults: defaults)
        drawsWireHops = defaults.object(forKey: Self.wireHopsDefaultsKey) as? Bool ?? true
        displaysCanvasWarnings = defaults.object(forKey: Self.canvasWarningsDefaultsKey) as? Bool ?? true
        fillsClosedSymbolBackground = defaults.bool(forKey: Self.closedSymbolBackgroundDefaultsKey)
        swapsViewControlsAndUnplacedReferences = Self.loadSwapsViewControlsAndUnplacedReferences(defaults: defaults)
        transparentToolbar = Self.loadTransparentToolbar(defaults: defaults)
        readOnlyOperation = HorizontalOperationDefaults.readOnlyOperation(defaults: defaults)
        liveServerEnabled = HorizontalLiveServer.isEnabled(defaults: defaults)
        boardSceneBackgroundColor = Self.loadBoardSceneBackgroundColor(defaults: defaults)
        boardSceneSubstrateColor = Self.loadBoardSceneSubstrateColor(defaults: defaults)
        boardSceneSolderMaskColor = Self.loadBoardSceneSolderMaskColor(defaults: defaults)
        boardSceneSilkscreenColor = Self.loadBoardSceneSilkscreenColor(defaults: defaults)
        boardSceneCopperColor = Self.loadBoardSceneCopperColor(defaults: defaults)
        Self.seedLightLayerColors(defaults: defaults)
        layerColorSets = Dictionary(uniqueKeysWithValues: HorizontalPaletteMode.allCases.map { mode in
            (mode, Self.loadLayerColors(mode: mode, defaults: defaults))
        })
        gridLineWidth = Self.loadGridLineWidth(defaults: defaults)
        clipsSilkscreenToSolderMask = Self.loadClipsSilkscreenToSolderMask(defaults: defaults)
        silkscreenMaskClearanceMM = Self.loadSilkscreenMaskClearanceMM(defaults: defaults)
        for kind in HorizontalCanvasKind.allCases {
            minimumLineWidths[kind] = loadMinimumLineWidth(kind: kind)
            for mode in HorizontalPaletteMode.allCases {
                palettes[HorizontalPaletteKey(kind: kind, mode: mode)] = loadPalette(kind: kind, mode: mode)
            }
        }
        for role in HorizontalLineWidthRole.allCases {
            roleLineWidths[role] = Self.loadLineWidth(role: role, defaults: defaults)
        }
        // Lives as long as the app does, so the observer is never removed.
        _ = NotificationCenter.default.addObserver(
            forName: SettingsSync.didPullNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSyncedDefaults() }
        }
    }

    /// The keys of `UserDefaults` that iCloud carries between the user's
    /// devices (`SettingsSync`): the colours, the line widths, the canvas
    /// and toolbar options and the silkscreen clipping. The theme and the
    /// cursor's size suit one display and stay with it, as do the read-only
    /// lock and the live server, which are one device's to decide.
    static var syncedDefaultsKeys: [String] {
        var keys = [
            selectionHandleShapeDefaultsKey,
            hoverPopoverDefaultsKey,
            netLabelBackgroundDefaultsKey,
            wireHopsDefaultsKey,
            canvasWarningsDefaultsKey,
            closedSymbolBackgroundDefaultsKey,
            swapViewControlsAndUnplacedReferencesDefaultsKey,
            transparentToolbarDefaultsKey,
            boardSceneBackgroundColorDefaultsKey,
            boardSceneSubstrateColorDefaultsKey,
            boardSceneSolderMaskColorDefaultsKey,
            boardSceneSilkscreenColorDefaultsKey,
            boardSceneCopperColorDefaultsKey,
            gridLineWidthDefaultsKey,
            clipSilkscreenDefaultsKey,
            silkscreenMaskClearanceDefaultsKey,
        ]
        keys += HorizontalLineWidthRole.allCases.map { lineWidthDefaultsKey(role: $0) }
        for kind in HorizontalCanvasKind.allCases {
            keys.append(minimumLineWidthDefaultsKey(kind: kind))
            for mode in HorizontalPaletteMode.allCases {
                keys += HorizontalColorRole.allCases.map { colorDefaultsKey(kind: kind, mode: mode, role: $0) }
            }
        }
        for mode in HorizontalPaletteMode.allCases {
            keys += editableLayers.map { layerDefaultsKey(mode: mode, layer: $0) }
        }
        return keys
    }

    /// Copies a colour chosen for the one shared layer set into the light
    /// set, as the first launch that knows the light set does. `SettingsSync`
    /// asks for it before it pulls: colours arriving from another device are
    /// that device's dark set and must not seed this one's light set.
    static func seedDefaultsBeforeSync(defaults: UserDefaults = .standard) {
        seedLightLayerColors(defaults: defaults)
    }

    /// Reads again what `syncedDefaultsKeys` names, after `SettingsSync`
    /// wrote another device's choices into `UserDefaults`.
    private func reloadSyncedDefaults() {
        selectionHandleShape = Self.loadSelectionHandleShape(defaults: defaults)
        showsHoverPopover = Self.loadShowsHoverPopover(defaults: defaults)
        fillsNetLabelBackground = Self.loadFillsNetLabelBackground(defaults: defaults)
        drawsWireHops = defaults.object(forKey: Self.wireHopsDefaultsKey) as? Bool ?? true
        displaysCanvasWarnings = defaults.object(forKey: Self.canvasWarningsDefaultsKey) as? Bool ?? true
        fillsClosedSymbolBackground = defaults.bool(forKey: Self.closedSymbolBackgroundDefaultsKey)
        swapsViewControlsAndUnplacedReferences = Self.loadSwapsViewControlsAndUnplacedReferences(defaults: defaults)
        transparentToolbar = Self.loadTransparentToolbar(defaults: defaults)
        boardSceneBackgroundColor = Self.loadBoardSceneBackgroundColor(defaults: defaults)
        boardSceneSubstrateColor = Self.loadBoardSceneSubstrateColor(defaults: defaults)
        boardSceneSolderMaskColor = Self.loadBoardSceneSolderMaskColor(defaults: defaults)
        boardSceneSilkscreenColor = Self.loadBoardSceneSilkscreenColor(defaults: defaults)
        boardSceneCopperColor = Self.loadBoardSceneCopperColor(defaults: defaults)
        for mode in HorizontalPaletteMode.allCases {
            layerColorSets[mode] = Self.loadLayerColors(mode: mode, defaults: defaults)
        }
        gridLineWidth = Self.loadGridLineWidth(defaults: defaults)
        clipsSilkscreenToSolderMask = Self.loadClipsSilkscreenToSolderMask(defaults: defaults)
        silkscreenMaskClearanceMM = Self.loadSilkscreenMaskClearanceMM(defaults: defaults)
        for kind in HorizontalCanvasKind.allCases {
            minimumLineWidths[kind] = loadMinimumLineWidth(kind: kind)
            for mode in HorizontalPaletteMode.allCases {
                palettes[HorizontalPaletteKey(kind: kind, mode: mode)] = loadPalette(kind: kind, mode: mode)
            }
        }
        for role in HorizontalLineWidthRole.allCases {
            roleLineWidths[role] = Self.loadLineWidth(role: role, defaults: defaults)
        }
    }

    var preferredColorScheme: ColorScheme? {
        appTheme.preferredColorScheme
    }

    var canvasCursorSize: HorizontalCursorSize {
        cursorSize
    }

    var canvasSelectionHandleShape: HorizontalSelectionHandleShape {
        selectionHandleShape
    }

    var shouldShowHoverPopover: Bool {
        showsHoverPopover
    }

    var shouldFillNetLabelBackground: Bool {
        fillsNetLabelBackground
    }

    /// Wires of different nets that cross draw a hop on the schematic.
    var shouldDrawWireHops: Bool {
        drawsWireHops
    }

    /// Display warnings on canvas, the rules window's and the rules results
    /// sidebar's: the canvases' warning markers, the schematic's own and the
    /// rules checks', and the count on the rules results button. Off, the
    /// checks run only when asked (`HorizontalRulesCheckDefaults`), and their
    /// results sidebar still lists what they find.
    var shouldDisplayCanvasWarnings: Bool {
        displaysCanvasWarnings
    }

    var shouldFillClosedSymbolBackground: Bool {
        fillsClosedSymbolBackground
    }

    var shouldSwapViewControlsAndUnplacedReferences: Bool {
        swapsViewControlsAndUnplacedReferences
    }

    var isToolbarTransparent: Bool {
        transparentToolbar
    }

    /// Belt-and-braces: a Release build reports read-only regardless of what is
    /// stored in defaults, so a value written by an earlier Debug run (or by
    /// `defaults write`) can't unlock a shipped build.
    var isReadOnlyOperationEnabled: Bool {
        readOnlyOperation
    }

    /// Whether the app serves its open documents to the MCP server and the
    /// Python package over the loopback channel.
    var isLiveServerEnabled: Bool {
        liveServerEnabled
    }

    var boardSceneBackground: Color {
        boardSceneBackgroundColor
    }

    /// The 3D view's background is a colour of its own, not the theme's, so
    /// its layer colours are the set made for a background like it.
    var boardSceneLayerColors: [Int: HorizontalRGBColor] {
        let mode = boardSceneLayerColorMode
        return editableLayers.reduce(into: [Int: HorizontalRGBColor]()) { result, layer in
            let components = Self.colorComponents(from: layerColor(for: layer, mode: mode))
            result[layer] = HorizontalRGBColor(
                red: Double(components.red),
                green: Double(components.green),
                blue: Double(components.blue)
            )
        }
    }

    var boardSceneLayerColorMode: HorizontalPaletteMode {
        let components = Self.colorComponents(from: boardSceneBackgroundColor)
        let luminance = 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
        return luminance > 0.5 ? .light : .dark
    }

    var boardSceneMaterialColors: HorizontalBoardColors {
        HorizontalBoardColors(
            silkscreen: Self.rgbColor(from: boardSceneSilkscreenColor),
            solderMask: Self.rgbColor(from: boardSceneSolderMaskColor),
            substrate: Self.rgbColor(from: boardSceneSubstrateColor)
        )
    }

    func palette(for kind: HorizontalCanvasKind, colorScheme: ColorScheme) -> HorizontalCanvasPalette {
        palette(for: kind, mode: colorScheme == .dark ? .dark : .light)
    }

    func palette(for kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) -> HorizontalCanvasPalette {
        var palette = palettes[HorizontalPaletteKey(kind: kind, mode: mode)] ?? HorizontalCanvasPalette.defaultPalette(kind: kind, mode: mode)
        palette.layerColors = layerColorSets[mode] ?? HorizontalCanvasPalette.defaultLayerColors(mode: mode)
        return palette
    }

    func colorBinding(for role: HorizontalColorRole, kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) -> Binding<Color> {
        Binding {
            self.palette(for: kind, mode: mode).color(role)
        } set: { color in
            self.setColor(color, for: role, kind: kind, mode: mode)
        }
    }

    /// A layer's colour in the light or the dark theme; every canvas that
    /// draws board layers shares it.
    func layerColorBinding(for layer: Int, mode: HorizontalPaletteMode) -> Binding<Color> {
        Binding {
            self.layerColor(for: layer, mode: mode)
        } set: { color in
            self.setLayerColor(color, for: layer, mode: mode)
        }
    }

    func layerColorBinding(for layer: Int, colorScheme: ColorScheme) -> Binding<Color> {
        layerColorBinding(for: layer, mode: colorScheme == .dark ? .dark : .light)
    }

    func appThemeBinding() -> Binding<HorizontalAppTheme> {
        Binding {
            self.appTheme
        } set: { theme in
            // The segmented picker can deliver a new theme from within a view
            // update, and the theme recolours every window, Settings'
            // included; publishing it there is undefined, so it goes out on
            // the next turn of the main queue.
            guard theme != self.appTheme else { return }
            DispatchQueue.main.async { self.setAppTheme(theme) }
        }
    }

    func cursorSizeBinding() -> Binding<HorizontalCursorSize> {
        Binding {
            self.cursorSize
        } set: { cursorSize in
            self.setCursorSize(cursorSize)
        }
    }

    func selectionHandleShapeBinding() -> Binding<HorizontalSelectionHandleShape> {
        Binding {
            self.selectionHandleShape
        } set: { shape in
            self.setSelectionHandleShape(shape)
        }
    }

    func hoverPopoverBinding() -> Binding<Bool> {
        Binding {
            self.showsHoverPopover
        } set: { showsHoverPopover in
            self.setShowsHoverPopover(showsHoverPopover)
        }
    }

    func netLabelBackgroundBinding() -> Binding<Bool> {
        Binding {
            self.fillsNetLabelBackground
        } set: { fills in
            self.setFillsNetLabelBackground(fills)
        }
    }

    func wireHopsBinding() -> Binding<Bool> {
        Binding {
            self.drawsWireHops
        } set: { draws in
            self.objectWillChange.send()
            self.drawsWireHops = draws
            self.defaults.set(draws, forKey: Self.wireHopsDefaultsKey)
        }
    }

    func canvasWarningsBinding() -> Binding<Bool> {
        Binding {
            self.displaysCanvasWarnings
        } set: { displays in
            self.displaysCanvasWarnings = displays
            self.defaults.set(displays, forKey: Self.canvasWarningsDefaultsKey)
        }
    }

    func closedSymbolBackgroundBinding() -> Binding<Bool> {
        Binding {
            self.fillsClosedSymbolBackground
        } set: { fills in
            self.fillsClosedSymbolBackground = fills
            self.defaults.set(fills, forKey: Self.closedSymbolBackgroundDefaultsKey)
        }
    }

    func swapViewControlsAndUnplacedReferencesBinding() -> Binding<Bool> {
        Binding {
            self.swapsViewControlsAndUnplacedReferences
        } set: { swaps in
            self.setSwapsViewControlsAndUnplacedReferences(swaps)
        }
    }

    func transparentToolbarBinding() -> Binding<Bool> {
        Binding {
            self.transparentToolbar
        } set: { isTransparent in
            self.setTransparentToolbar(isTransparent)
        }
    }

    func readOnlyOperationBinding() -> Binding<Bool> {
        Binding {
            self.readOnlyOperation
        } set: { isReadOnly in
            self.setReadOnlyOperation(isReadOnly)
        }
    }

    func liveServerEnabledBinding() -> Binding<Bool> {
        Binding {
            self.liveServerEnabled
        } set: { isEnabled in
            self.setLiveServerEnabled(isEnabled)
        }
    }

    func boardSceneBackgroundColorBinding() -> Binding<Color> {
        Binding {
            self.boardSceneBackgroundColor
        } set: { color in
            self.setBoardSceneBackgroundColor(color)
        }
    }

    func boardSceneSubstrateColorBinding() -> Binding<Color> {
        Binding {
            self.boardSceneSubstrateColor
        } set: { color in
            self.setBoardSceneSubstrateColor(color)
        }
    }

    func boardSceneSolderMaskColorBinding() -> Binding<Color> {
        Binding {
            self.boardSceneSolderMaskColor
        } set: { color in
            self.setBoardSceneSolderMaskColor(color)
        }
    }

    func boardSceneSilkscreenColorBinding() -> Binding<Color> {
        Binding {
            self.boardSceneSilkscreenColor
        } set: { color in
            self.setBoardSceneSilkscreenColor(color)
        }
    }

    func boardSceneCopperColorBinding() -> Binding<Color> {
        Binding {
            self.boardSceneCopperColor
        } set: { color in
            self.setBoardSceneCopperColor(color)
        }
    }

    var boardSceneCopper: Color {
        boardSceneCopperColor
    }

    func minimumLineWidth(for kind: HorizontalCanvasKind) -> CGFloat {
        CGFloat(minimumLineWidths[kind] ?? Self.defaultMinimumLineWidth)
    }

    var gridMarkLineWidth: CGFloat {
        CGFloat(gridLineWidth)
    }

    func minimumLineWidthBinding(for kind: HorizontalCanvasKind) -> Binding<Double> {
        Binding {
            self.minimumLineWidths[kind] ?? Self.defaultMinimumLineWidth
        } set: { width in
            self.setMinimumLineWidth(width, for: kind)
        }
    }

    func gridLineWidthBinding() -> Binding<Double> {
        Binding {
            self.gridLineWidth
        } set: { width in
            self.setGridLineWidth(width)
        }
    }

    func lineWidth(for role: HorizontalLineWidthRole) -> CGFloat {
        CGFloat(roleLineWidths[role] ?? role.defaultWidth)
    }

    func lineWidthBinding(for role: HorizontalLineWidthRole) -> Binding<Double> {
        Binding {
            self.roleLineWidths[role] ?? role.defaultWidth
        } set: { width in
            self.setLineWidth(width, for: role)
        }
    }

    /// The clip-silkscreen-to-solder-mask mode, nil while it is off. The
    /// board view, the 3D view and the fabrication exports all apply it.
    var silkscreenClipping: HorizontalSilkscreenClipping? {
        guard clipsSilkscreenToSolderMask else {
            return nil
        }
        return HorizontalSilkscreenClipping(clearance: silkscreenMaskClearanceMM * 1_000_000)
    }

    var silkscreenMaskClearanceMillimetres: Double {
        silkscreenMaskClearanceMM
    }

    func clipSilkscreenToSolderMaskBinding() -> Binding<Bool> {
        Binding {
            self.clipsSilkscreenToSolderMask
        } set: { clips in
            self.setClipsSilkscreenToSolderMask(clips)
        }
    }

    func silkscreenMaskClearanceBinding() -> Binding<Double> {
        Binding {
            self.silkscreenMaskClearanceMM
        } set: { clearance in
            self.setSilkscreenMaskClearanceMM(clearance)
        }
    }

    func resetSilkscreenClipping() {
        objectWillChange.send()
        clipsSilkscreenToSolderMask = false
        silkscreenMaskClearanceMM = HorizontalSilkscreenClipping.defaultClearanceMM
        defaults.removeObject(forKey: Self.clipSilkscreenDefaultsKey)
        defaults.removeObject(forKey: Self.silkscreenMaskClearanceDefaultsKey)
    }

    func resetMinimumLineWidth(kind: HorizontalCanvasKind) {
        objectWillChange.send()
        minimumLineWidths[kind] = Self.defaultMinimumLineWidth
        defaults.removeObject(forKey: minimumLineWidthDefaultsKey(kind: kind))
    }

    func resetGridLineWidth() {
        objectWillChange.send()
        gridLineWidth = Self.defaultGridLineWidth
        defaults.removeObject(forKey: Self.gridLineWidthDefaultsKey)
    }

    func resetLineWidth(role: HorizontalLineWidthRole) {
        objectWillChange.send()
        roleLineWidths[role] = role.defaultWidth
        defaults.removeObject(forKey: Self.lineWidthDefaultsKey(role: role))
    }

    func resetBoardSceneBackgroundColor() {
        objectWillChange.send()
        boardSceneBackgroundColor = Self.defaultBoardSceneBackgroundColor
        defaults.removeObject(forKey: Self.boardSceneBackgroundColorDefaultsKey)
    }

    func resetBoardSceneColors() {
        objectWillChange.send()
        boardSceneBackgroundColor = Self.defaultBoardSceneBackgroundColor
        boardSceneSubstrateColor = Self.defaultBoardSceneSubstrateColor
        boardSceneSolderMaskColor = Self.defaultBoardSceneSolderMaskColor
        boardSceneSilkscreenColor = Self.defaultBoardSceneSilkscreenColor
        boardSceneCopperColor = Self.defaultBoardSceneCopperColor
        defaults.removeObject(forKey: Self.boardSceneBackgroundColorDefaultsKey)
        defaults.removeObject(forKey: Self.boardSceneSubstrateColorDefaultsKey)
        defaults.removeObject(forKey: Self.boardSceneSolderMaskColorDefaultsKey)
        defaults.removeObject(forKey: Self.boardSceneSilkscreenColorDefaultsKey)
        defaults.removeObject(forKey: Self.boardSceneCopperColorDefaultsKey)
    }

    func reset(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) {
        let key = HorizontalPaletteKey(kind: kind, mode: mode)
        objectWillChange.send()
        palettes[key] = HorizontalCanvasPalette.defaultPalette(kind: kind, mode: mode)

        for role in HorizontalColorRole.allCases {
            defaults.removeObject(forKey: colorDefaultsKey(kind: kind, mode: mode, role: role))
        }
    }

    /// Both themes' layer colours go back to their defaults.
    func resetLayerColors() {
        objectWillChange.send()
        for mode in HorizontalPaletteMode.allCases {
            layerColorSets[mode] = Self.defaultLayerColorSet(mode: mode)
            for layer in editableLayers {
                defaults.removeObject(forKey: Self.layerDefaultsKey(mode: mode, layer: layer))
            }
        }
    }

    private func setColor(_ color: Color, for role: HorizontalColorRole, kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) {
        let key = HorizontalPaletteKey(kind: kind, mode: mode)
        objectWillChange.send()
        var palette = palette(for: kind, mode: mode)
        palette.colors[role] = color
        palettes[key] = palette
        defaults.set(Self.hexString(from: color), forKey: colorDefaultsKey(kind: kind, mode: mode, role: role))
    }

    private func layerColor(for layer: Int, mode: HorizontalPaletteMode) -> Color {
        layerColorSets[mode]?[layer]
            ?? HorizontalCanvasPalette.defaultPalette(kind: .board, mode: mode).layerColor(for: layer)
    }

    private func setLayerColor(_ color: Color, for layer: Int, mode: HorizontalPaletteMode) {
        objectWillChange.send()
        layerColorSets[mode, default: Self.defaultLayerColorSet(mode: mode)][layer] = color
        defaults.set(Self.hexString(from: color), forKey: Self.layerDefaultsKey(mode: mode, layer: layer))
    }

    // A segmented Picker on macOS writes its selection back through its
    // binding while it updates the control: publishing for a value that
    // hasn't changed would then publish from within a view update.
    private func setAppTheme(_ theme: HorizontalAppTheme) {
        guard theme != appTheme else { return }
        objectWillChange.send()
        appTheme = theme
        defaults.set(theme.rawValue, forKey: appThemeDefaultsKey)
    }

    private func setCursorSize(_ newCursorSize: HorizontalCursorSize) {
        guard newCursorSize != cursorSize else { return }
        objectWillChange.send()
        cursorSize = newCursorSize
        defaults.set(newCursorSize.rawValue, forKey: cursorSizeDefaultsKey)
    }

    private func setSelectionHandleShape(_ newShape: HorizontalSelectionHandleShape) {
        guard newShape != selectionHandleShape else { return }
        objectWillChange.send()
        selectionHandleShape = newShape
        defaults.set(newShape.rawValue, forKey: Self.selectionHandleShapeDefaultsKey)
    }

    private func setShowsHoverPopover(_ newValue: Bool) {
        objectWillChange.send()
        showsHoverPopover = newValue
        defaults.set(newValue, forKey: Self.hoverPopoverDefaultsKey)
    }

    private func setFillsNetLabelBackground(_ newValue: Bool) {
        objectWillChange.send()
        fillsNetLabelBackground = newValue
        defaults.set(newValue, forKey: Self.netLabelBackgroundDefaultsKey)
    }

    private func setSwapsViewControlsAndUnplacedReferences(_ newValue: Bool) {
        objectWillChange.send()
        swapsViewControlsAndUnplacedReferences = newValue
        defaults.set(newValue, forKey: Self.swapViewControlsAndUnplacedReferencesDefaultsKey)
    }

    private func setTransparentToolbar(_ newValue: Bool) {
        objectWillChange.send()
        transparentToolbar = newValue
        defaults.set(newValue, forKey: Self.transparentToolbarDefaultsKey)
    }

    private func setReadOnlyOperation(_ newValue: Bool) {
        objectWillChange.send()
        readOnlyOperation = newValue
        defaults.set(newValue, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
    }

    private func setLiveServerEnabled(_ newValue: Bool) {
        objectWillChange.send()
        liveServerEnabled = newValue
        defaults.set(newValue, forKey: HorizontalLiveServer.enabledDefaultsKey)
        // Start or stop the listener now rather than at the next document
        // open or close, so the switch matches what the app is doing.
        HorizontalLiveServer.enabledDidChange()
    }

    private func setBoardSceneBackgroundColor(_ color: Color) {
        objectWillChange.send()
        boardSceneBackgroundColor = color
        defaults.set(Self.hexString(from: color), forKey: Self.boardSceneBackgroundColorDefaultsKey)
    }

    private func setBoardSceneSubstrateColor(_ color: Color) {
        objectWillChange.send()
        boardSceneSubstrateColor = color
        defaults.set(Self.hexString(from: color), forKey: Self.boardSceneSubstrateColorDefaultsKey)
    }

    private func setBoardSceneSolderMaskColor(_ color: Color) {
        objectWillChange.send()
        boardSceneSolderMaskColor = color
        defaults.set(Self.hexString(from: color), forKey: Self.boardSceneSolderMaskColorDefaultsKey)
    }

    private func setBoardSceneSilkscreenColor(_ color: Color) {
        objectWillChange.send()
        boardSceneSilkscreenColor = color
        defaults.set(Self.hexString(from: color), forKey: Self.boardSceneSilkscreenColorDefaultsKey)
    }

    private func setBoardSceneCopperColor(_ color: Color) {
        objectWillChange.send()
        boardSceneCopperColor = color
        defaults.set(Self.hexString(from: color), forKey: Self.boardSceneCopperColorDefaultsKey)
    }

    private func setMinimumLineWidth(_ width: Double, for kind: HorizontalCanvasKind) {
        let clampedWidth = Self.clampedLineWidth(width)
        objectWillChange.send()
        minimumLineWidths[kind] = clampedWidth
        defaults.set(clampedWidth, forKey: minimumLineWidthDefaultsKey(kind: kind))
    }

    private func setClipsSilkscreenToSolderMask(_ clips: Bool) {
        objectWillChange.send()
        clipsSilkscreenToSolderMask = clips
        defaults.set(clips, forKey: Self.clipSilkscreenDefaultsKey)
    }

    private func setSilkscreenMaskClearanceMM(_ clearance: Double) {
        let clamped = min(max(clearance, 0), HorizontalSilkscreenClipping.maximumClearanceMM)
        objectWillChange.send()
        silkscreenMaskClearanceMM = clamped
        defaults.set(clamped, forKey: Self.silkscreenMaskClearanceDefaultsKey)
    }

    private func setGridLineWidth(_ width: Double) {
        let clampedWidth = Self.clampedLineWidth(width)
        objectWillChange.send()
        gridLineWidth = clampedWidth
        defaults.set(clampedWidth, forKey: Self.gridLineWidthDefaultsKey)
    }

    private func setLineWidth(_ width: Double, for role: HorizontalLineWidthRole) {
        let clampedWidth = Self.clampedLineWidth(width)
        objectWillChange.send()
        roleLineWidths[role] = clampedWidth
        defaults.set(clampedWidth, forKey: Self.lineWidthDefaultsKey(role: role))
    }

    private func loadPalette(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) -> HorizontalCanvasPalette {
        var palette = HorizontalCanvasPalette.defaultPalette(kind: kind, mode: mode)
        for role in HorizontalColorRole.allCases {
            if let color = defaults.string(forKey: colorDefaultsKey(kind: kind, mode: mode, role: role)).flatMap(Self.color(from:)) {
                palette.colors[role] = color
            }
        }
        return palette
    }

    private func loadMinimumLineWidth(kind: HorizontalCanvasKind) -> Double {
        let key = minimumLineWidthDefaultsKey(kind: kind)
        guard defaults.object(forKey: key) != nil else {
            return Self.defaultMinimumLineWidth
        }
        return Self.clampedLineWidth(defaults.double(forKey: key))
    }

    private static func loadClipsSilkscreenToSolderMask(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: clipSilkscreenDefaultsKey)
    }

    private static func loadSilkscreenMaskClearanceMM(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: silkscreenMaskClearanceDefaultsKey) != nil else {
            return HorizontalSilkscreenClipping.defaultClearanceMM
        }
        return min(max(defaults.double(forKey: silkscreenMaskClearanceDefaultsKey), 0), HorizontalSilkscreenClipping.maximumClearanceMM)
    }

    private static func loadGridLineWidth(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: gridLineWidthDefaultsKey) != nil else {
            return defaultGridLineWidth
        }
        return clampedLineWidth(defaults.double(forKey: gridLineWidthDefaultsKey))
    }

    private static func loadLineWidth(role: HorizontalLineWidthRole, defaults: UserDefaults) -> Double {
        let key = lineWidthDefaultsKey(role: role)
        guard defaults.object(forKey: key) != nil else {
            return role.defaultWidth
        }
        return clampedLineWidth(defaults.double(forKey: key))
    }

    private static func loadAppTheme(defaults: UserDefaults) -> HorizontalAppTheme {
        guard let rawValue = defaults.string(forKey: appThemeDefaultsKey) else {
            return .system
        }
        return HorizontalAppTheme(rawValue: rawValue) ?? .system
    }

    private static func loadCursorSize(defaults: UserDefaults) -> HorizontalCursorSize {
        guard let rawValue = defaults.string(forKey: cursorSizeDefaultsKey) else {
            return .small
        }
        return HorizontalCursorSize(rawValue: rawValue) ?? .small
    }

    private static func loadSelectionHandleShape(defaults: UserDefaults) -> HorizontalSelectionHandleShape {
        guard let rawValue = defaults.string(forKey: selectionHandleShapeDefaultsKey) else {
            return .diamond
        }
        return HorizontalSelectionHandleShape(rawValue: rawValue) ?? .diamond
    }

    private static func loadShowsHoverPopover(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: hoverPopoverDefaultsKey) != nil else {
            return false
        }
        return defaults.bool(forKey: hoverPopoverDefaultsKey)
    }

    private static func loadTransparentToolbar(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: transparentToolbarDefaultsKey) != nil else {
            return false
        }
        return defaults.bool(forKey: transparentToolbarDefaultsKey)
    }

    private static func loadFillsNetLabelBackground(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: netLabelBackgroundDefaultsKey) != nil else {
            return false
        }
        return defaults.bool(forKey: netLabelBackgroundDefaultsKey)
    }

    private static func loadSwapsViewControlsAndUnplacedReferences(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: swapViewControlsAndUnplacedReferencesDefaultsKey) != nil else {
            return false
        }
        return defaults.bool(forKey: swapViewControlsAndUnplacedReferencesDefaultsKey)
    }

    private static func loadBoardSceneBackgroundColor(defaults: UserDefaults) -> Color {
        defaults.string(forKey: boardSceneBackgroundColorDefaultsKey).flatMap(color(from:))
            ?? defaultBoardSceneBackgroundColor
    }

    private static func loadBoardSceneSubstrateColor(defaults: UserDefaults) -> Color {
        defaults.string(forKey: boardSceneSubstrateColorDefaultsKey).flatMap(color(from:))
            ?? defaultBoardSceneSubstrateColor
    }

    private static func loadBoardSceneSolderMaskColor(defaults: UserDefaults) -> Color {
        defaults.string(forKey: boardSceneSolderMaskColorDefaultsKey).flatMap(color(from:))
            ?? defaultBoardSceneSolderMaskColor
    }

    private static func loadBoardSceneSilkscreenColor(defaults: UserDefaults) -> Color {
        defaults.string(forKey: boardSceneSilkscreenColorDefaultsKey).flatMap(color(from:))
            ?? defaultBoardSceneSilkscreenColor
    }

    private static func loadBoardSceneCopperColor(defaults: UserDefaults) -> Color {
        defaults.string(forKey: boardSceneCopperColorDefaultsKey).flatMap(color(from:))
            ?? defaultBoardSceneCopperColor
    }

    private static func loadLayerColors(mode: HorizontalPaletteMode, defaults: UserDefaults) -> [Int: Color] {
        var colors = defaultLayerColorSet(mode: mode)
        for layer in editableLayers {
            if let color = storedLayerColor(mode: mode, layer: layer, defaults: defaults) {
                colors[layer] = color
            }
        }
        return colors
    }

    private static func storedLayerColor(mode: HorizontalPaletteMode, layer: Int, defaults: UserDefaults) -> Color? {
        if let color = defaults.string(forKey: layerDefaultsKey(mode: mode, layer: layer)).flatMap(color(from:)) {
            return color
        }
        // Before one set served both themes, each canvas kept its own; the
        // board's dark one became that set.
        guard mode == .dark else { return nil }
        return defaults.string(forKey: legacyLayerDefaultsKey(kind: .board, mode: .dark, layer: layer)).flatMap(color(from:))
    }

    /// Until the light theme had layer colours of its own, one set served
    /// both, so a colour someone chose then was a choice for the light canvas
    /// too: the first launch that knows the light set copies each such
    /// colour into it, once, and the sets go their own ways from there.
    private static func seedLightLayerColors(defaults: UserDefaults) {
        guard !defaults.bool(forKey: lightLayerColorsSeededDefaultsKey) else { return }
        for layer in editableLayers where defaults.string(forKey: layerDefaultsKey(mode: .light, layer: layer)) == nil {
            if let color = storedLayerColor(mode: .dark, layer: layer, defaults: defaults) {
                defaults.set(hexString(from: color), forKey: layerDefaultsKey(mode: .light, layer: layer))
            }
        }
        defaults.set(true, forKey: lightLayerColorsSeededDefaultsKey)
    }

    private static func defaultLayerColorSet(mode: HorizontalPaletteMode) -> [Int: Color] {
        var colors = [Int: Color]()
        let palette = HorizontalCanvasPalette.defaultPalette(kind: .board, mode: mode)
        for layer in editableLayers {
            colors[layer] = palette.layerColor(for: layer)
        }
        return colors
    }

    private static let appThemeDefaultsKey = "appearance.appTheme"
    private static let lightLayerColorsSeededDefaultsKey = "appearance.board.shared.light.seeded"
    private static let cursorSizeDefaultsKey = "appearance.cursorSize"
    private static let selectionHandleShapeDefaultsKey = "appearance.selectionHandleShape"
    private static let hoverPopoverDefaultsKey = "appearance.showsHoverPopover"
    private static let netLabelBackgroundDefaultsKey = "appearance.fillNetLabelBackground"
    private static let wireHopsDefaultsKey = "appearance.schematicWireHops"
    private static let canvasWarningsDefaultsKey = "appearance.displaysCanvasWarnings"
    private static let closedSymbolBackgroundDefaultsKey = "appearance.fillClosedSymbolBackground"
    private static let swapViewControlsAndUnplacedReferencesDefaultsKey = "appearance.swapViewControlsAndUnplacedReferences"
    private static let transparentToolbarDefaultsKey = "appearance.transparentToolbar"
    private static let boardSceneBackgroundColorDefaultsKey = "appearance.boardScene.backgroundColor"
    private static let boardSceneSubstrateColorDefaultsKey = "appearance.boardScene.substrateColor"
    private static let boardSceneSolderMaskColorDefaultsKey = "appearance.boardScene.solderMaskColor"
    private static let boardSceneSilkscreenColorDefaultsKey = "appearance.boardScene.silkscreenColor"
    private static let boardSceneCopperColorDefaultsKey = "appearance.boardScene.copperColor"
    private static let gridLineWidthDefaultsKey = "appearance.grid.lineWidth"
    private static let clipSilkscreenDefaultsKey = "fabrication.clipSilkscreenToSolderMask"
    private static let silkscreenMaskClearanceDefaultsKey = "fabrication.silkscreenMaskClearanceMM"
    private static let defaultBoardSceneBackgroundColor = HorizontalDefaultTheme.background
    // #BCC486. Only a colour someone picks is stored, so this reaches everyone
    // who never chose one.
    private static let defaultBoardSceneSubstrateColor = Color(red: 188 / 255, green: 196 / 255, blue: 134 / 255)
    private static let defaultBoardSceneSolderMaskColor = Color(red: 0.05, green: 0.33, blue: 0.12)
    private static let defaultBoardSceneSilkscreenColor = Color(red: 0.92, green: 0.92, blue: 0.88)
    private static let defaultBoardSceneCopperColor = Color(red: 0.72, green: 0.45, blue: 0.2)

    private var appThemeDefaultsKey: String {
        Self.appThemeDefaultsKey
    }

    private var cursorSizeDefaultsKey: String {
        Self.cursorSizeDefaultsKey
    }

    private func colorDefaultsKey(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode, role: HorizontalColorRole) -> String {
        Self.colorDefaultsKey(kind: kind, mode: mode, role: role)
    }

    private static func colorDefaultsKey(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode, role: HorizontalColorRole) -> String {
        "appearance.\(kind.rawValue).\(mode.rawValue).color.\(role.rawValue)"
    }

    /// The dark theme keeps the key the one shared set had, so the colours
    /// chosen then stay where they were.
    private static func layerDefaultsKey(mode: HorizontalPaletteMode, layer: Int) -> String {
        switch mode {
        case .dark: "appearance.board.shared.layer.\(layer)"
        case .light: "appearance.board.shared.light.layer.\(layer)"
        }
    }

    private static func legacyLayerDefaultsKey(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode, layer: Int) -> String {
        "appearance.\(kind.rawValue).\(mode.rawValue).layer.\(layer)"
    }

    private func minimumLineWidthDefaultsKey(kind: HorizontalCanvasKind) -> String {
        Self.minimumLineWidthDefaultsKey(kind: kind)
    }

    private static func minimumLineWidthDefaultsKey(kind: HorizontalCanvasKind) -> String {
        "appearance.\(kind.rawValue).minimumLineWidth"
    }

    private static func lineWidthDefaultsKey(role: HorizontalLineWidthRole) -> String {
        "appearance.board.\(role.rawValue).lineWidth"
    }

    static func color(from hex: String) -> Color? {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let integer = Int(value, radix: 16) else {
            return nil
        }
        return Color(
            red: Double((integer >> 16) & 0xff) / 255.0,
            green: Double((integer >> 8) & 0xff) / 255.0,
            blue: Double(integer & 0xff) / 255.0
        )
    }

    static func hexString(from color: Color) -> String {
        let components = colorComponents(from: color)
        let red = Int((components.red * 255).rounded())
        let green = Int((components.green * 255).rounded())
        let blue = Int((components.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func colorComponents(from color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        #if canImport(AppKit)
        let platformColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return (platformColor.redComponent, platformColor.greenComponent, platformColor.blueComponent)
        #else
        let platformColor = UIColor(color)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
        #endif
    }

    private static func rgbColor(from color: Color) -> HorizontalRGBColor {
        let components = colorComponents(from: color)
        return HorizontalRGBColor(
            red: Double(components.red),
            green: Double(components.green),
            blue: Double(components.blue)
        )
    }
}

let editableLayers: [Int] = HorizontalBoardLayers.all + [HorizontalBoardLayers.dimensions]
