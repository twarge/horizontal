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

    /// Release builds — including anything archived for distribution — are
    /// read-only unconditionally: the preference is neither offered nor
    /// consulted. Debug builds keep the toggle so the editing paths can still
    /// be developed and tested.
    ///
    /// Keyed off DEBUG rather than a bespoke flag because that is exactly the
    /// distinction wanted: `make build` for development keeps editing, while
    /// `make release`, `make archive` and the App Store workflow all compile
    /// Release and are therefore locked.
    static var isReadOnlyOperationForced: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static func readOnlyOperation(defaults: UserDefaults = .standard) -> Bool {
        if isReadOnlyOperationForced {
            return true
        }
        guard defaults.object(forKey: readOnlyOperationKey) != nil else {
            return true
        }
        return defaults.bool(forKey: readOnlyOperationKey)
    }
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
        case .diffPair: "Diff Pair"
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
            return layerColors[HorizontalBoardLayers.in1Copper] ?? Color(red: 1, green: 1, blue: 0)
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
        layerColors: defaultLayerColors
    )

    static let boardLightDefault = HorizontalCanvasPalette(
        colors: darkDefault.colors.merging([
            .background: rgb(1, 1, 1),
            .grid: rgb(225.0 / 255.0, 225.0 / 255.0, 225.0 / 255.0),
            .textOverlay: rgb(0, 0, 0),
            .hole: rgb(146.0 / 255.0, 146.0 / 255.0, 146.0 / 255.0),
            .dimension: rgb(0, 0, 0),
            .pin: rgb(146.0 / 255.0, 146.0 / 255.0, 146.0 / 255.0),
        ]) { _, new in new },
        layerColors: darkDefault.layerColors
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
        ]) { _, new in new },
        layerColors: darkDefault.layerColors
    )

    static let schematicDarkDefault = HorizontalCanvasPalette(
        colors: darkDefault.colors.merging([
            .junction: rgb(0, 1, 0),
            .frame: rgb(1, 1, 0),
            .pin: rgb(1, 1, 0),
        ]) { _, new in new },
        layerColors: darkDefault.layerColors
    )

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

    private static let defaultLayerColors: [Int: Color] = [
        HorizontalBoardLayers.topNotes: rgb(1, 1, 1),
        HorizontalBoardLayers.outlineNotes: rgb(0.6, 0.6, 0),
        HorizontalBoardLayers.outline: rgb(0.6, 0.6, 0),
        HorizontalBoardLayers.topCourtyard: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topAssembly: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topPackage: rgb(0.5, 0.5, 0.5),
        HorizontalBoardLayers.topPaste: rgb(0.8, 0.8, 0.8),
        HorizontalBoardLayers.topSilkscreen: rgb(0.9, 0.9, 0.9),
        HorizontalBoardLayers.topMask: rgb(1, 0.5, 0.5),
        HorizontalBoardLayers.topCopper: rgb(1, 0, 0),
        HorizontalBoardLayers.in1Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in2Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in3Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in4Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in5Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in6Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in7Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.in8Copper: rgb(1, 1, 0),
        HorizontalBoardLayers.bottomCopper: rgb(0, 0.5, 0),
        HorizontalBoardLayers.bottomMask: rgb(0.25, 0.5, 0.25),
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

    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}

private struct HorizontalPaletteKey: Hashable {
    var kind: HorizontalCanvasKind
    var mode: HorizontalPaletteMode
}

@MainActor
final class HorizontalAppearanceSettings: ObservableObject {
    static let defaultMinimumLineWidth: Double = 1.5
    static let defaultGridLineWidth: Double = 0.5

    @Published private var appTheme: HorizontalAppTheme
    @Published private var cursorSize: HorizontalCursorSize
    @Published private var selectionHandleShape: HorizontalSelectionHandleShape
    @Published private var showsHoverPopover: Bool
    @Published private var fillsNetLabelBackground: Bool
    @Published private var swapsViewControlsAndUnplacedReferences: Bool
    @Published private var transparentToolbar: Bool
    @Published private var readOnlyOperation: Bool
    @Published private var boardSceneBackgroundColor: Color
    @Published private var boardSceneSubstrateColor: Color
    @Published private var boardSceneSolderMaskColor: Color
    @Published private var boardSceneSilkscreenColor: Color
    @Published private var boardSceneCopperColor: Color
    @Published private var palettes = [HorizontalPaletteKey: HorizontalCanvasPalette]()
    @Published private var sharedLayerColors = [Int: Color]()
    @Published private var minimumLineWidths = [HorizontalCanvasKind: Double]()
    @Published private var gridLineWidth: Double

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appTheme = Self.loadAppTheme(defaults: defaults)
        cursorSize = Self.loadCursorSize(defaults: defaults)
        selectionHandleShape = Self.loadSelectionHandleShape(defaults: defaults)
        showsHoverPopover = Self.loadShowsHoverPopover(defaults: defaults)
        fillsNetLabelBackground = Self.loadFillsNetLabelBackground(defaults: defaults)
        swapsViewControlsAndUnplacedReferences = Self.loadSwapsViewControlsAndUnplacedReferences(defaults: defaults)
        transparentToolbar = Self.loadTransparentToolbar(defaults: defaults)
        readOnlyOperation = HorizontalOperationDefaults.readOnlyOperation(defaults: defaults)
        boardSceneBackgroundColor = Self.loadBoardSceneBackgroundColor(defaults: defaults)
        boardSceneSubstrateColor = Self.loadBoardSceneSubstrateColor(defaults: defaults)
        boardSceneSolderMaskColor = Self.loadBoardSceneSolderMaskColor(defaults: defaults)
        boardSceneSilkscreenColor = Self.loadBoardSceneSilkscreenColor(defaults: defaults)
        boardSceneCopperColor = Self.loadBoardSceneCopperColor(defaults: defaults)
        sharedLayerColors = Self.loadSharedLayerColors(defaults: defaults)
        gridLineWidth = Self.loadGridLineWidth(defaults: defaults)
        for kind in HorizontalCanvasKind.allCases {
            minimumLineWidths[kind] = loadMinimumLineWidth(kind: kind)
            for mode in HorizontalPaletteMode.allCases {
                palettes[HorizontalPaletteKey(kind: kind, mode: mode)] = loadPalette(kind: kind, mode: mode)
            }
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
        HorizontalOperationDefaults.isReadOnlyOperationForced || readOnlyOperation
    }

    var boardSceneBackground: Color {
        boardSceneBackgroundColor
    }

    var boardSceneLayerColors: [Int: HorizontalRGBColor] {
        editableLayers.reduce(into: [Int: HorizontalRGBColor]()) { result, layer in
            let components = Self.colorComponents(from: sharedLayerColor(for: layer))
            result[layer] = HorizontalRGBColor(
                red: Double(components.red),
                green: Double(components.green),
                blue: Double(components.blue)
            )
        }
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
        palette.layerColors = sharedLayerColors
        return palette
    }

    func colorBinding(for role: HorizontalColorRole, kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) -> Binding<Color> {
        Binding {
            self.palette(for: kind, mode: mode).color(role)
        } set: { color in
            self.setColor(color, for: role, kind: kind, mode: mode)
        }
    }

    func layerColorBinding(for layer: Int) -> Binding<Color> {
        Binding {
            self.sharedLayerColor(for: layer)
        } set: { color in
            self.setLayerColor(color, for: layer)
        }
    }

    func layerColorBinding(for layer: Int, kind: HorizontalCanvasKind, mode: HorizontalPaletteMode) -> Binding<Color> {
        layerColorBinding(for: layer)
    }

    func appThemeBinding() -> Binding<HorizontalAppTheme> {
        Binding {
            self.appTheme
        } set: { theme in
            self.setAppTheme(theme)
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

    func resetLayerColors() {
        objectWillChange.send()
        sharedLayerColors = Self.defaultSharedLayerColors()
        for layer in editableLayers {
            defaults.removeObject(forKey: sharedLayerDefaultsKey(layer: layer))
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

    private func sharedLayerColor(for layer: Int) -> Color {
        sharedLayerColors[layer]
            ?? HorizontalCanvasPalette.defaultPalette(kind: .board, mode: .dark).layerColor(for: layer)
    }

    private func setLayerColor(_ color: Color, for layer: Int) {
        objectWillChange.send()
        sharedLayerColors[layer] = color
        defaults.set(Self.hexString(from: color), forKey: sharedLayerDefaultsKey(layer: layer))
    }

    private func setAppTheme(_ theme: HorizontalAppTheme) {
        objectWillChange.send()
        appTheme = theme
        defaults.set(theme.rawValue, forKey: appThemeDefaultsKey)
    }

    private func setCursorSize(_ newCursorSize: HorizontalCursorSize) {
        objectWillChange.send()
        cursorSize = newCursorSize
        defaults.set(newCursorSize.rawValue, forKey: cursorSizeDefaultsKey)
    }

    private func setSelectionHandleShape(_ newShape: HorizontalSelectionHandleShape) {
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
        let clampedWidth = min(max(width, 0.5), 4.0)
        objectWillChange.send()
        minimumLineWidths[kind] = clampedWidth
        defaults.set(clampedWidth, forKey: minimumLineWidthDefaultsKey(kind: kind))
    }

    private func setGridLineWidth(_ width: Double) {
        let clampedWidth = min(max(width, 0.5), 4.0)
        objectWillChange.send()
        gridLineWidth = clampedWidth
        defaults.set(clampedWidth, forKey: Self.gridLineWidthDefaultsKey)
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
        return min(max(defaults.double(forKey: key), 0.5), 4.0)
    }

    private static func loadGridLineWidth(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: gridLineWidthDefaultsKey) != nil else {
            return defaultGridLineWidth
        }
        return min(max(defaults.double(forKey: gridLineWidthDefaultsKey), 0.5), 4.0)
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

    private static func loadSharedLayerColors(defaults: UserDefaults) -> [Int: Color] {
        var colors = defaultSharedLayerColors()
        for layer in editableLayers {
            if let color = defaults.string(forKey: sharedLayerDefaultsKey(layer: layer)).flatMap(color(from:)) {
                colors[layer] = color
            } else if let color = defaults.string(forKey: legacyLayerDefaultsKey(kind: .board, mode: .dark, layer: layer)).flatMap(color(from:)) {
                colors[layer] = color
            }
        }
        return colors
    }

    private static func defaultSharedLayerColors() -> [Int: Color] {
        var colors = [Int: Color]()
        let darkPalette = HorizontalCanvasPalette.defaultPalette(kind: .board, mode: .dark)
        for layer in editableLayers {
            colors[layer] = darkPalette.layerColor(for: layer)
        }
        return colors
    }

    private static let appThemeDefaultsKey = "appearance.appTheme"
    private static let cursorSizeDefaultsKey = "appearance.cursorSize"
    private static let selectionHandleShapeDefaultsKey = "appearance.selectionHandleShape"
    private static let hoverPopoverDefaultsKey = "appearance.showsHoverPopover"
    private static let netLabelBackgroundDefaultsKey = "appearance.fillNetLabelBackground"
    private static let swapViewControlsAndUnplacedReferencesDefaultsKey = "appearance.swapViewControlsAndUnplacedReferences"
    private static let transparentToolbarDefaultsKey = "appearance.transparentToolbar"
    private static let boardSceneBackgroundColorDefaultsKey = "appearance.boardScene.backgroundColor"
    private static let boardSceneSubstrateColorDefaultsKey = "appearance.boardScene.substrateColor"
    private static let boardSceneSolderMaskColorDefaultsKey = "appearance.boardScene.solderMaskColor"
    private static let boardSceneSilkscreenColorDefaultsKey = "appearance.boardScene.silkscreenColor"
    private static let boardSceneCopperColorDefaultsKey = "appearance.boardScene.copperColor"
    private static let gridLineWidthDefaultsKey = "appearance.grid.lineWidth"
    private static let defaultBoardSceneBackgroundColor = HorizontalDefaultTheme.background
    private static let defaultBoardSceneSubstrateColor = Color(red: 0.18, green: 0.34, blue: 0.18)
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
        "appearance.\(kind.rawValue).\(mode.rawValue).color.\(role.rawValue)"
    }

    private static func sharedLayerDefaultsKey(layer: Int) -> String {
        "appearance.board.shared.layer.\(layer)"
    }

    private static func legacyLayerDefaultsKey(kind: HorizontalCanvasKind, mode: HorizontalPaletteMode, layer: Int) -> String {
        "appearance.\(kind.rawValue).\(mode.rawValue).layer.\(layer)"
    }

    private func sharedLayerDefaultsKey(layer: Int) -> String {
        Self.sharedLayerDefaultsKey(layer: layer)
    }

    private func minimumLineWidthDefaultsKey(kind: HorizontalCanvasKind) -> String {
        "appearance.\(kind.rawValue).minimumLineWidth"
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
