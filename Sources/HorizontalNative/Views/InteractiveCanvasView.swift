import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct HorizontalSelectionHUDItem: Equatable {
    var title: String
    var subtitle: String
    var details: [HorizontalSelectionHUDDetail] = []
}

struct HorizontalSelectionHUDDetail: Identifiable, Equatable {
    var label: String
    var value: String

    var id: String { "\(label):\(value)" }
}

struct HorizontalSelectionHUDState: Equatable {
    static let empty = HorizontalSelectionHUDState(hovered: nil, selected: [])

    var hovered: HorizontalSelectionHUDItem?
    var selected: [HorizontalSelectionHUDItem]

    init(hovered: HorizontalSelectionHUDItem?, selected: HorizontalSelectionHUDItem?) {
        self.hovered = hovered
        self.selected = selected.map { [$0] } ?? []
    }

    init(hovered: HorizontalSelectionHUDItem?, selected: [HorizontalSelectionHUDItem]) {
        self.hovered = hovered
        self.selected = selected
    }

    var isEmpty: Bool {
        hovered == nil && selected.isEmpty
    }
}

/// One of the board's side-and-purpose view presets.
enum HorizontalBoardLayerViewPreset: Hashable {
    case topPlacement
    case bottomPlacement
    case topSilkscreen
    case bottomSilkscreen
}

enum HorizontalCanvasCommand {
    case selectAll
    case selectNet
    case copySelection
    case pasteSelection
    case duplicateSelection
    case deleteSelection
    case highlightNet
    case moveSelection
    case moveSelectionExactly
    case rotateSelection
    case rotateSelectionAroundCenter
    case rotateSelectionArbitrary
    case twirlSelection
    case mirrorSelection
    case mirrorSelectionHorizontal
    case mirrorSelectionVertical
    case drawNetLine
    case drawTrack
    case drawGraphics(HorizontalDrawingPrimitive)
    case drawPlane
    /// Make a copper layer the working layer (number keys). Ignored by panes
    /// that have no layers, and by boards that lack the layer.
    case selectLayer(Int)
    /// Jump to a whole board view (shifted / control number keys).
    case selectBoardLayerView(HorizontalBoardLayerViewPreset)
    case definePlane
    case editPlane
    case convertPolygonToLineLoop
    case convertLineLoopToPolygon
    case addText
    /// macOS: reopen the inline text editor popover on the selected text
    /// (double-click or the per-object "Edit…" menu item). No-op on iOS.
    case editText
    case filterAirwires
    case openDatasheet
    case toggleSmash
    case smashSilkscreenGraphics
    case toggleOmitSilkscreen
    case toggleOmitOutline
    case toggleFixed
    case flipTrackPosture
    case enterTrackWidth
    case toggleVia
    case showToolSettings
    case moveNetSegmentToExistingNet
    case moveNetSegmentToNewNet
    case editSymbolPinNames
    case toggleRectanglePlacementMode
    case moveSelectionBy(HorizontalPoint)
    case commitInteraction
    case cancelInteraction
}

enum HorizontalSelectionClickAction {
    case replace
    case add
    case toggle
    case remove
}

struct HorizontalSelectionTargetItem: Identifiable, Equatable {
    enum Action: Equatable {
        case select(HorizontalSelectableRef)
        case copyText(String)
        case openURL(URL)
    }

    var id: String
    var ref: HorizontalSelectableRef?
    var title: String
    var subtitle: String
    var action: Action

    init(ref: HorizontalSelectableRef, title: String, subtitle: String) {
        self.id = Self.identifier(for: ref)
        self.ref = ref
        self.title = title
        self.subtitle = subtitle
        self.action = .select(ref)
    }

    init(id: String, title: String, subtitle: String = "", action: Action) {
        self.id = id
        self.ref = nil
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    static func identifier(for ref: HorizontalSelectableRef, suffix: String = "select") -> String {
        [
            suffix,
            ref.type.rawValue,
            ref.id,
            String(ref.vertex),
            ref.layer.map(String.init) ?? "nil",
        ].joined(separator: ":")
    }

    var menuTitle: String {
        subtitle.isEmpty ? title : "\(title) - \(subtitle)"
    }
}

/// One entry in a disambiguation candidate's action submenu. Mirrors the
/// per-object right-click menu (Select, Copy, Move ▸ …, Delete, …).
enum HorizontalTargetItemMenuEntry {
    /// Select the candidate object (the legacy click-to-select behaviour).
    case select(title: String)
    /// Run a canvas command on the candidate (the canvas selects it first).
    case command(title: String, HorizontalCanvasCommand)
    /// A nested submenu (e.g. "Move ▸ Move / Rotate / Mirror").
    indirect case submenu(title: String, [HorizontalTargetItemMenuEntry])
    /// A planned-but-unimplemented action: shown disabled (greyed) so the full
    /// Horizon menu is discoverable while clearly marked not-yet-available.
    case todo(title: String)
    case separator
}

struct HorizontalSnappedCursor {
    var point: HorizontalPoint
    var isTarget: Bool
}

private struct HorizontalSelectionDragPreview {
    var tool: HorizontalSelectionTool
    var start: CGPoint
    var current: CGPoint
    var points: [CGPoint]
}

struct HorizontalMetalInteractiveOverlayBatch {
    static let empty = HorizontalMetalInteractiveOverlayBatch()

    var worldLines = [HorizontalMetalLinePrimitive]()
    var screenLines = [HorizontalMetalScreenLinePrimitive]()
    var screenTriangles = [HorizontalMetalScreenTrianglePrimitive]()

    var isEmpty: Bool {
        worldLines.isEmpty && screenLines.isEmpty && screenTriangles.isEmpty
    }

    var key: Int {
        var hasher = Hasher()
        hasher.combine(worldLines)
        hasher.combine(screenLines)
        hasher.combine(screenTriangles)
        return hasher.finalize()
    }
}

struct CanvasViewport: Codable, Equatable {
    static let minimumZoom: CGFloat = 0.1
    static let maximumZoom: CGFloat = 128
    static let zoomBase: CGFloat = 1.5

    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    init(zoom: CGFloat = 1, pan: CGSize = .zero) {
        self.zoom = Self.clamp(zoom)
        self.pan = CGSize(
            width: pan.width.isFinite ? pan.width : 0,
            height: pan.height.isFinite ? pan.height : 0
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        let panWidth = try container.decodeIfPresent(Double.self, forKey: .panWidth) ?? 0
        let panHeight = try container.decodeIfPresent(Double.self, forKey: .panHeight) ?? 0
        self.init(
            zoom: CGFloat(zoom),
            pan: CGSize(width: CGFloat(panWidth), height: CGFloat(panHeight))
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Double(zoom), forKey: .zoom)
        try container.encode(Double(pan.width), forKey: .panWidth)
        try container.encode(Double(pan.height), forKey: .panHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case zoom
        case panWidth
        case panHeight
    }

    mutating func fit() {
        zoom = 1
        pan = .zero
    }

    mutating func zoomIn() {
        zoom = Self.clamp(zoom * 1.25)
    }

    mutating func zoomOut() {
        zoom = Self.clamp(zoom / 1.25)
    }

    mutating func applyMagnification(_ magnification: CGFloat) {
        zoom = Self.clamp(zoom * magnification)
    }

    mutating func applyMagnification(
        _ magnification: CGFloat,
        anchor: CGPoint,
        size: CGSize,
        bounds: HorizontalRect,
        fitInsets: HorizontalCanvasInsets
    ) {
        let oldZoom = zoom
        let newZoom = Self.clamp(zoom * magnification)
        zoom(to: newZoom, oldZoom: oldZoom, anchor: anchor, size: size, bounds: bounds, fitInsets: fitInsets)
    }

    mutating func applyZoomStep(
        _ step: CGFloat,
        anchor: CGPoint,
        size: CGSize,
        bounds: HorizontalRect,
        fitInsets: HorizontalCanvasInsets
    ) {
        let oldZoom = zoom
        let newZoom = Self.clamp(zoom * pow(Self.zoomBase, step))
        zoom(to: newZoom, oldZoom: oldZoom, anchor: anchor, size: size, bounds: bounds, fitInsets: fitInsets)
    }

    private mutating func zoom(
        to newZoom: CGFloat,
        oldZoom: CGFloat,
        anchor: CGPoint,
        size: CGSize,
        bounds: HorizontalRect,
        fitInsets: HorizontalCanvasInsets
    ) {
        guard newZoom != oldZoom else {
            return
        }

        let oldTransform = HorizontalCanvasTransform(bounds: bounds, size: size, fitInsets: fitInsets, zoom: oldZoom, pan: pan)
        let anchoredWorldPoint = oldTransform.worldPoint(anchor)
        let newTransform = HorizontalCanvasTransform(bounds: bounds, size: size, fitInsets: fitInsets, zoom: newZoom, pan: pan)
        let newAnchor = newTransform.point(anchoredWorldPoint)

        zoom = newZoom
        pan.width += anchor.x - newAnchor.x
        pan.height += anchor.y - newAnchor.y
    }

    mutating func pan(by delta: CGSize) {
        pan.width += delta.width
        pan.height += delta.height
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoom), maximumZoom)
    }

}

struct InteractiveCanvasView: View {
    var bounds: HorizontalRect
    @Binding var viewport: CanvasViewport
    var backgroundColor: Color
    var foregroundColor = Color.horizonPlatformLabel
    var overlayBackgroundColor = Color.horizonPlatformWindowBackground.opacity(0.78)
    var showsScaleBar = true
    var showsCoordinateReadout = true
    var grid: HorizontalGridSettings?
    var gridColor = Color.clear
    var drawsGridInMetal = false
    var gridLineWidth: CGFloat = 0.5
    var metalTriangles = [HorizontalMetalTrianglePrimitive]()
    var metalTriangleKey = 0
    var metalLines = [HorizontalMetalLinePrimitive]()
    var metalLineKey = 0
    var metalHandles = [HorizontalMetalHandlePrimitive]()
    var metalHandleKey = 0
    var metalAnchoredRects = [HorizontalMetalAnchoredRectPrimitive]()
    var metalAnchoredRectKey = 0
    var metalScreenTriangles = [HorizontalMetalScreenTrianglePrimitive]()
    var metalScreenTriangleKey = 0
    var metalScreenLines = [HorizontalMetalScreenLinePrimitive]()
    var metalScreenLineKey = 0
    var metalVisibleCompositeGroups: Set<Int>? = nil
    var metalOverlayTriangles = [HorizontalMetalTrianglePrimitive]()
    var metalOverlayTriangleKey = 0
    var metalOverlayLines = [HorizontalMetalLinePrimitive]()
    var metalOverlayLineKey = 0
    var metalOverlayHandles = [HorizontalMetalHandlePrimitive]()
    var metalOverlayHandleKey = 0
    var metalOverlayAnchoredRects = [HorizontalMetalAnchoredRectPrimitive]()
    var metalOverlayAnchoredRectKey = 0
    var metalOverlayScreenTriangles = [HorizontalMetalScreenTrianglePrimitive]()
    var metalOverlayScreenTriangleKey = 0
    var metalOverlayScreenLines = [HorizontalMetalScreenLinePrimitive]()
    var metalOverlayScreenLineKey = 0
    var metalOverlayBufferPatches = HorizontalMetalBufferPatches.empty
    var metalOverlayBufferPatchKey = 0
    var metalOverlayVisibleCompositeGroups: Set<Int>? = nil
    var metalOverlayLayerOpacityExemptGroups: Set<Int> = []
    var metalTopOverlayTriangles = [HorizontalMetalTrianglePrimitive]()
    var metalTopOverlayTriangleKey = 0
    var metalTopOverlayLines = [HorizontalMetalLinePrimitive]()
    var metalTopOverlayLineKey = 0
    var metalTopOverlayHandles = [HorizontalMetalHandlePrimitive]()
    var metalTopOverlayHandleKey = 0
    var metalTopOverlayAnchoredRects = [HorizontalMetalAnchoredRectPrimitive]()
    var metalTopOverlayAnchoredRectKey = 0
    var metalTopOverlayScreenTriangles = [HorizontalMetalScreenTrianglePrimitive]()
    var metalTopOverlayScreenTriangleKey = 0
    var metalTopOverlayScreenLines = [HorizontalMetalScreenLinePrimitive]()
    var metalTopOverlayScreenLineKey = 0
    var metalTopOverlayBufferPatches = HorizontalMetalBufferPatches.empty
    var metalTopOverlayBufferPatchKey = 0
    var metalTopOverlayVisibleCompositeGroups: Set<Int>? = nil
    var metalLoadProfileID: String? = nil
    var cursorSize: HorizontalCursorSize = .small
    var drawsCursorInMetal = true
    var snapTargets: [HorizontalPoint] = []
    var fitSafeAreaInsets: EdgeInsets? = nil
    var minimumLineWidth: CGFloat = 0
    /// Multiplier applied at composite time to per-layer texture batches. Live
    /// updates avoid invalidating any caches in BoardCanvasView's bucket build.
    var metalLayerOpacity: Double = 1
    var selectionHUD: HorizontalSelectionHUDState = .empty
    var hoverStatusText: String? = nil
    var showsHoverPopover = false
    var selectionDetails: HorizontalSelectionDetailState = .empty
    var showsSelectionDetails = true
    var unplacedObjects: [HorizontalUnplacedObject] = []
    var selectedUnplacedObjectID: String? = nil
    var placesUnplacedObjectsOnTrailingEdge = false
    var selectionToolSettings = HorizontalSelectionToolSettings()
    var selectionSelectables: [HorizontalSelectable] = []
    var handlesSelectionDeletion = false
    var undoManager: UndoManager? = nil
    var ignoresCanvasMouseEvents = false
    var onCursorWorldPointChange: (HorizontalPoint?, Double) -> Void = { _, _ in }
    var onPrimaryClick: (HorizontalPoint, Double, HorizontalSelectionClickAction, Int) -> Void = { _, _, _, _ in }
    var onAreaSelection: ([HorizontalSelectableRef], HorizontalSelectionClickAction) -> Void = { _, _ in }
    var targetMenuItems: (HorizontalPoint, Double) -> [HorizontalSelectionTargetItem] = { _, _ in [] }
    var onTargetMenuSelection: (HorizontalSelectableRef) -> Void = { _ in }
    /// Per-candidate action submenu for the disambiguation / context menu. Empty
    /// → the candidate is a plain "click to select" item (legacy behaviour).
    var targetItemMenu: (HorizontalSelectableRef) -> [HorizontalTargetItemMenuEntry] = { _ in [] }
    /// Called as the pointer moves over a candidate (or its open submenu) so the
    /// canvas can highlight the corresponding object; nil clears the highlight.
    var onTargetMenuHighlight: (HorizontalSelectableRef?) -> Void = { _ in }
    /// Run a command on a specific candidate from its action submenu (the canvas
    /// selects the ref, then dispatches the command).
    var onTargetMenuCommand: (HorizontalSelectableRef, HorizontalCanvasCommand) -> Void = { _, _ in }
    var onUnplacedObjectSelection: (HorizontalUnplacedObject) -> Void = { _ in }
    var onSelectionPropertyChange: (HorizontalSelectionPropertyChange) -> Void = { _ in }
    var onCommand: (HorizontalCanvasCommand) -> Void = { _ in }
    /// Whether a press at this world point (with this hit-test slop, world units
    /// per screen point) lands on an already-selected object. When it does, the
    /// primary drag MOVES the selection instead of starting a rubber-band
    /// selection. Mode views implement it — returning false during any active
    /// interaction (draw, paste, move) — and the default keeps drags selecting.
    var hitsSelection: (HorizontalPoint, Double) -> Bool = { _, _ in false }
    /// Reports the exact world→view transform the canvas is rendering with
    /// (built from `effectiveViewport` — what's on screen — not the `viewport`
    /// binding, which can lag behind by a gesture-settle). Hosts that overlay
    /// screen-anchored UI on world coordinates (e.g. the macOS inline text
    /// editor popover) anchor against this so the anchor lands on the object.
    /// Optional and harmless when unset (iOS never sets it).
    var onCanvasDisplayTransformChange: ((HorizontalCanvasTransform) -> Void)? = nil
    /// When this changes, the display transform is reported immediately even if
    /// the viewport/size didn't change. Lets a host force a fresh report at a
    /// moment it cares about (e.g. when it starts an overlay edit) so it isn't
    /// stuck waiting for the next gesture. Ignored when no callback is set.
    var canvasDisplayTransformReportTrigger: AnyHashable? = nil
    var allowsContextMenu = true
    var handlesInteractionKeys = false
    /// macOS: only the keyboard-focused pane's key monitor handles canvas commands
    /// (multiple panes are visible at once). Defaults true so single-pane hosts (iPad,
    /// a lone macOS pane) keep working. `onRequestKeyboardFocus` fires on interaction
    /// so clicking a pane focuses it.
    var hasKeyboardFocus = true
    var onRequestKeyboardFocus: () -> Void = {}
    var samplesCursorContinuously = false
    /// When true, the `v` key maps to `.toggleVia` (board track tool) instead of
    /// the schematic `.moveNetSegmentToExistingNet`.
    var supportsTrackVias = false

    /// The cursor crosshair + coordinate readout live in `CursorReadoutLayer`, fed
    /// through this holder so a pointer move re-renders only that small layer, not
    /// this ~500-line body. (@State holds the reference but does NOT observe it.)
    @State private var cursorInput = HorizontalCursorInput()
    @State private var selectionDragPreview: HorizontalSelectionDragPreview?
    /// Move-vs-select intent of the primary drag in flight, decided on the
    /// drag's first event from whether the press landed on the selection.
    /// `.moveCandidate` becomes `.moving` (and starts the move interaction)
    /// once the drag travels the activation threshold in any direction.
    private enum PrimaryDragIntent: Equatable {
        case selection
        case moveCandidate(origin: CGPoint)
        case moving
    }
    @State private var primaryDragIntent: PrimaryDragIntent?
    @State private var gridDivisor = 1
    @State private var pointerInsideSelectionPopover = false
    /// Current keyboard modifiers, published by the macOS NSEvent flags monitor so
    /// the SwiftUI select gestures can read them (SwiftUI drags carry no modifiers).
    @State private var currentInputModifiers: HorizontalCanvasInputModifiers = []
    /// Spatial index over `snapTargets`, rebuilt only when they change, so cursor
    /// snapping stays O(1)-ish per move (held in @State to persist across renders).
    @State private var snapIndexCache = HorizontalSnapIndexCache()
    #if canImport(MetalKit)
    @State private var viewportDriver = HorizontalCanvasViewportDriver()
    @State private var liveChromeViewport: CanvasViewport?
    #endif

    private var effectiveViewport: CanvasViewport {
        #if canImport(MetalKit)
        usesViewportDriver && viewportDriver.isConfigured ? (liveChromeViewport ?? viewportDriver.viewport) : viewport
        #else
        viewport
        #endif
    }

    private var interactionViewport: CanvasViewport {
        #if canImport(MetalKit)
        usesViewportDriver && viewportDriver.isConfigured ? viewportDriver.viewport : viewport
        #else
        viewport
        #endif
    }

    private var usesViewportDriver: Bool {
        #if canImport(MetalKit)
        HorizontalMetalBackdropView.isSupported
        #else
        false
        #endif
    }

    private var effectiveZoom: CGFloat {
        effectiveViewport.zoom
    }

    private var effectivePan: CGSize {
        effectiveViewport.pan
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                let fitInsets = canvasFitInsets(for: proxy)
                let overlayInsets = overlayInsets(for: proxy)
                let mouseExclusionInsets = canvasMouseExclusionInsets(for: proxy)
                let transform = HorizontalCanvasTransform(
                    bounds: bounds,
                    size: proxy.size,
                    fitInsets: fitInsets,
                    zoom: effectiveZoom,
                    pan: effectivePan,
                    minimumLineWidth: minimumLineWidth
                )
                let scaleBarScreenLines = metalScaleBarScreenLines(
                    size: proxy.size,
                    transform: transform,
                    overlayInsets: overlayInsets
                )
                // The cursor crosshair + coordinate-readout box moved to
                // CursorReadoutLayer (its own Metal overlay), so they no longer
                // contribute here and a cursor move no longer rebuilds this body.
                let selectionDragMetalBatch = metalSelectionDragBatch(transform: transform)
                let topOverlayLines = metalTopOverlayLines + selectionDragMetalBatch.worldLines
                let topOverlayScreenTriangles = metalTopOverlayScreenTriangles + selectionDragMetalBatch.screenTriangles
                let topOverlayScreenLines = metalTopOverlayScreenLines + scaleBarScreenLines
                    + selectionDragMetalBatch.screenLines
                let topOverlayLineKey = metalTopOverlayLineKey &* 31 &+ selectionDragMetalBatch.worldLines.hashValue
                let topOverlayScreenTriangleKey = metalTopOverlayScreenTriangleKey &* 31 &+ selectionDragMetalBatch.screenTriangles.hashValue
                let topOverlayScreenLineKey = (metalTopOverlayScreenLineKey &* 31 &+ scaleBarScreenLines.hashValue)
                    &+ selectionDragMetalBatch.screenLines.hashValue
                #if canImport(MetalKit)
                let usesMetalBackdrop = HorizontalMetalBackdropView.isSupported
                let usesMetalOverlay = (!metalOverlayTriangles.isEmpty || !metalOverlayLines.isEmpty || !metalOverlayHandles.isEmpty || !metalOverlayAnchoredRects.isEmpty || !metalOverlayScreenTriangles.isEmpty || !metalOverlayScreenLines.isEmpty) && HorizontalMetalBackdropView.isSupported
                let usesMetalTopOverlay = (!metalTopOverlayTriangles.isEmpty || !topOverlayLines.isEmpty || !metalTopOverlayHandles.isEmpty || !metalTopOverlayAnchoredRects.isEmpty || !topOverlayScreenTriangles.isEmpty || !topOverlayScreenLines.isEmpty) && HorizontalMetalBackdropView.isSupported
                let drawsSwiftUIChromeText = HorizontalMetalBackdropView.isSupported
                // Computed per-platform so iOS doesn't const-fold a dead ternary
                // branch (the Metal backdrop only exists on macOS).
                let canvasBackdropColor = usesMetalBackdrop ? Color.clear : backgroundColor
                #else
                let usesMetalBackdrop = false
                let usesMetalOverlay = false
                let usesMetalTopOverlay = false
                let drawsSwiftUIChromeText = false
                let canvasBackdropColor = backgroundColor
                #endif

                // Report the transform the canvas actually renders with (keyed on
                // its inputs) so world-anchored overlays land precisely. Inert
                // when no callback is set.
                if let onCanvasDisplayTransformChange {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .onAppear { onCanvasDisplayTransformChange(transform) }
                        .onChange(of: effectiveViewport) { _, _ in onCanvasDisplayTransformChange(transform) }
                        .onChange(of: proxy.size) { _, _ in onCanvasDisplayTransformChange(transform) }
                        .onChange(of: fitInsets) { _, _ in onCanvasDisplayTransformChange(transform) }
                        .onChange(of: canvasDisplayTransformReportTrigger) { _, _ in onCanvasDisplayTransformChange(transform) }
                }

                #if canImport(MetalKit)
                if usesMetalBackdrop {
                    // The base backdrop renders the grid/background; bucketed
                    // board primitives flow through the *overlay* backdrop below,
                    // which is where layerOpacity needs to apply.
                    HorizontalMetalBackdropView(
                        bounds: bounds,
                        viewport: effectiveViewport,
                        viewportDriver: usesViewportDriver ? viewportDriver : nil,
                        fitInsets: fitInsets,
                        grid: drawsGridInMetal ? grid : nil,
                        backgroundColor: backgroundColor,
                        gridColor: gridColor,
                        minimumLineWidth: minimumLineWidth,
                        gridLineWidth: gridLineWidth,
                        triangles: metalTriangles,
                        triangleKey: metalTriangleKey,
                        lines: metalLines,
                        lineKey: metalLineKey,
                        handles: metalHandles,
                        handleKey: metalHandleKey,
                        anchoredRects: metalAnchoredRects,
                        anchoredRectKey: metalAnchoredRectKey,
                        screenTriangles: metalScreenTriangles,
                        screenTriangleKey: metalScreenTriangleKey,
                        screenLines: metalScreenLines,
                        screenLineKey: metalScreenLineKey,
                        visibleCompositeGroups: metalVisibleCompositeGroups,
                        loadProfileID: metalLoadProfileID,
                        loadProfileLabel: "Metal base",
                        marksLoadProfileFirstDraw: !usesMetalOverlay
                    )
                    .allowsHitTesting(false)
                }
                #endif

                Color.clear
                    .background(canvasBackdropColor)
                    .onHover { isInside in
                        if !isInside {
                            cursorInput.location = nil
                            onCursorWorldPointChange(nil, 0)
                        }
                    }

                #if canImport(MetalKit)
                if drawsSwiftUIChromeText {
                    if let scaleOverlay = scaleBarTextOverlay(
                        size: proxy.size,
                        transform: transform,
                        overlayInsets: overlayInsets
                    ) {
                        Text(scaleOverlay.label)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(foregroundColor.opacity(0.72))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .offset(x: scaleOverlay.position.x, y: scaleOverlay.position.y)
                            .allowsHitTesting(false)
                    }
                }
                #endif

                #if canImport(MetalKit)
                if usesMetalOverlay {
                    HorizontalMetalBackdropView(
                        bounds: bounds,
                        viewport: effectiveViewport,
                        viewportDriver: usesViewportDriver ? viewportDriver : nil,
                        fitInsets: fitInsets,
                        grid: nil,
                        backgroundColor: .clear,
                        gridColor: .clear,
                        minimumLineWidth: minimumLineWidth,
                        layerOpacity: metalLayerOpacity,
                        triangles: metalOverlayTriangles,
                        triangleKey: metalOverlayTriangleKey,
                        lines: metalOverlayLines,
                        lineKey: metalOverlayLineKey,
                        handles: metalOverlayHandles,
                        handleKey: metalOverlayHandleKey,
                        anchoredRects: metalOverlayAnchoredRects,
                        anchoredRectKey: metalOverlayAnchoredRectKey,
                        screenTriangles: metalOverlayScreenTriangles,
                        screenTriangleKey: metalOverlayScreenTriangleKey,
                        screenLines: metalOverlayScreenLines,
                        screenLineKey: metalOverlayScreenLineKey,
                        bufferPatches: metalOverlayBufferPatches,
                        bufferPatchKey: metalOverlayBufferPatchKey,
                        visibleCompositeGroups: metalOverlayVisibleCompositeGroups,
                        layerOpacityExemptCompositeGroups: metalOverlayLayerOpacityExemptGroups,
                        loadProfileID: metalLoadProfileID,
                        loadProfileLabel: "Metal overlay",
                        marksLoadProfileFirstDraw: true
                    )
                    .allowsHitTesting(false)
                }

                if usesMetalTopOverlay {
                    HorizontalMetalBackdropView(
                        bounds: bounds,
                        viewport: effectiveViewport,
                        viewportDriver: usesViewportDriver ? viewportDriver : nil,
                        fitInsets: fitInsets,
                        grid: nil,
                        backgroundColor: .clear,
                        gridColor: .clear,
                        minimumLineWidth: minimumLineWidth,
                        triangles: metalTopOverlayTriangles,
                        triangleKey: metalTopOverlayTriangleKey,
                        lines: topOverlayLines,
                        lineKey: topOverlayLineKey,
                        handles: metalTopOverlayHandles,
                        handleKey: metalTopOverlayHandleKey,
                        anchoredRects: metalTopOverlayAnchoredRects,
                        anchoredRectKey: metalTopOverlayAnchoredRectKey,
                        screenTriangles: topOverlayScreenTriangles,
                        screenTriangleKey: topOverlayScreenTriangleKey,
                        screenLines: topOverlayScreenLines,
                        screenLineKey: topOverlayScreenLineKey,
                        bufferPatches: metalTopOverlayBufferPatches,
                        bufferPatchKey: metalTopOverlayBufferPatchKey,
                        visibleCompositeGroups: metalTopOverlayVisibleCompositeGroups,
                        loadProfileID: metalLoadProfileID,
                        loadProfileLabel: "Metal top overlay",
                        marksLoadProfileFirstDraw: false
                    )
                    .allowsHitTesting(false)
                }
                #endif

                // Snap-dependent crosshair + coordinate readout, isolated so a
                // pointer move re-renders only this small layer (and its own Metal
                // overlay) — not the parent body. Same z-position as the former
                // SwiftUI cursor canvas (below the input layer + selection chrome).
                // Intentional z change: the crosshair now composites ABOVE the
                // selection-drag rectangle (it was a later screen-line in the same
                // backdrop before); harmless and arguably clearer.
                CursorReadoutLayer(
                    cursorInput: cursorInput,
                    bounds: bounds,
                    effectiveViewport: effectiveViewport,
                    effectiveZoom: effectiveZoom,
                    effectivePan: effectivePan,
                    fitInsets: fitInsets,
                    minimumLineWidth: minimumLineWidth,
                    snapTargets: snapTargets,
                    grid: grid,
                    gridDivisor: gridDivisor,
                    cursorSize: cursorSize,
                    drawsCursorInMetal: drawsCursorInMetal,
                    backgroundColor: backgroundColor,
                    foregroundColor: foregroundColor,
                    overlayBackgroundColor: overlayBackgroundColor,
                    showsCoordinateReadout: showsCoordinateReadout,
                    showsHoverPopover: showsHoverPopover,
                    hoverStatusText: hoverStatusText,
                    viewportDriver: viewportDriver,
                    usesViewportDriver: usesViewportDriver
                )

                Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    #if canImport(AppKit)
                    ZStack {
                    // Pointer select/tap + pinch-zoom run through the cross-platform
                    // SwiftUI gesture view; the NSEvent monitor below it (hit-testing
                    // off) still owns scroll-wheel, right-click, and keyboard, and
                    // feeds the modifier side-channel.
                    HorizontalCanvasInputView(
                        dragMode: .selects,
                        selectionTool: selectionToolSettings.tool,
                        selectionModifierAction: selectionToolSettings.modifierAction,
                        currentModifiers: { currentInputModifiers },
                        onPrimaryClick: { location, size, clickAction, clickCount in
                            handleResolvedPrimaryClick(location: location, size: size, fitInsets: fitInsets, action: clickAction, clickCount: clickCount)
                        },
                        onPrimaryDragChanged: { start, current, points, size, _, isActive in
                            handlePrimaryDragChanged(start: start, current: current, points: points, size: size, fitInsets: fitInsets, isActive: isActive)
                        },
                        onPrimaryDragEnded: { start, current, points, size, clickAction, isActive in
                            handlePrimaryDragEnded(start: start, current: current, points: points, size: size, fitInsets: fitInsets, action: clickAction, isActive: isActive)
                        },
                        onMagnify: { magnification, anchor, size in
                            cursorInput.suppressForViewportGesture()
                            updateLiveViewport { viewport in
                                viewport.applyMagnification(
                                    magnification,
                                    anchor: anchor,
                                    size: size,
                                    bounds: bounds,
                                    fitInsets: fitInsets
                                )
                            }
                        },
                        onCursorLocationChange: { location in
                            cursorInput.location = location
                            reportCursorWorldPoint(location, size: proxy.size, fitInsets: fitInsets)
                        }
                    )

                    TrackpadCanvasMonitor(
                        onPan: { delta in
                            cursorInput.suppressForViewportGesture()
                            updateLiveViewport { viewport in
                                viewport.pan(by: delta)
                            }
                        },
                        onMagnify: { _, _, _ in },
                        onZoomStep: { step, anchor, size in
                            cursorInput.suppressForViewportGesture()
                            updateLiveViewport { viewport in
                                viewport.applyZoomStep(
                                    step,
                                    anchor: anchor,
                                    size: size,
                                    bounds: bounds,
                                    fitInsets: fitInsets
                                )
                            }
                        },
                        selectionTool: selectionToolSettings.tool,
                        selectionModifierAction: selectionToolSettings.modifierAction,
                        onPrimaryClick: { location, size, viewLocation, view, clickAction, clickCount in
                            handleResolvedPrimaryClick(location: location, size: size, fitInsets: fitInsets, action: clickAction, clickCount: clickCount)
                        },
                        onPrimaryDragChanged: { start, current, points, size, clickAction, isActive in
                            if isActive {
                                selectionDragPreview = HorizontalSelectionDragPreview(
                                    tool: selectionToolSettings.tool,
                                    start: start,
                                    current: current,
                                    points: points
                                )
                            }
                            cursorInput.location = current
                            reportCursorWorldPoint(current, size: size, fitInsets: fitInsets)
                        },
                        onPrimaryDragEnded: { start, current, points, size, clickAction, isActive in
                            defer {
                                selectionDragPreview = nil
                            }
                            guard isActive else {
                                return
                            }
                            let preview = HorizontalSelectionDragPreview(
                                tool: selectionToolSettings.tool,
                                start: start,
                                current: current,
                                points: points
                            )
                            selectDragRegion(
                                preview,
                                size: size,
                                fitInsets: fitInsets,
                                action: clickAction
                            )
                        },
                        onSecondaryClick: { canvasLocation, size, _, _ in
                            if allowsContextMenu {
                                showContextMenu(canvasLocation: canvasLocation, size: size, fitInsets: fitInsets)
                            } else {
                                onCommand(.cancelInteraction)
                            }
                        },
                        onCursorLocationChange: { location in
                            cursorInput.location = location
                            reportCursorWorldPoint(location, size: proxy.size, fitInsets: fitInsets)
                        },
                        onGridDivisorChange: { divisor in
                            gridDivisor = divisor
                        },
                        onModifiersChanged: { modifiers in
                            currentInputModifiers = modifiers
                        },
                        onMoveSelectionByGrid: { direction, fine in
                            moveSelectionByGrid(direction: direction, fine: fine)
                        },
                        handlesSelectionDeletion: handlesSelectionDeletion,
                        undoManager: undoManager,
                        onCommand: { command in
                            onCommand(command)
                        },
                        handlesInteractionKeys: handlesInteractionKeys,
                        samplesCursorContinuously: samplesCursorContinuously,
                        supportsTrackVias: supportsTrackVias,
                        hasKeyboardFocus: hasKeyboardFocus,
                        onRequestKeyboardFocus: onRequestKeyboardFocus,
                        ignoresCanvasMouseEvents: ignoresCanvasMouseEvents || pointerInsideSelectionPopover,
                        mouseExclusionInsets: mouseExclusionInsets
                    )
                    .allowsHitTesting(false)
                    }
                    #else
                    HorizontalMultitouchView(
                        onTap: { location, size, modifiers, clickCount in
                            let action = HorizontalCanvasInputCore.clickAction(
                                modifiers: modifiers,
                                modifierAction: selectionToolSettings.modifierAction
                            )
                            handleResolvedPrimaryClick(location: location, size: size, fitInsets: fitInsets, action: action, clickCount: clickCount)
                        },
                        contextMenuTargets: { location in
                            guard allowsContextMenu else {
                                return []
                            }
                            let transform = currentTransform(size: proxy.size, fitInsets: fitInsets)
                            let worldPoint = snappedCursor(at: location, transform: transform).point
                            let unitsPerPoint = worldUnitsPerScreenPoint(transform: transform, size: proxy.size)
                            return targetMenuItems(worldPoint, unitsPerPoint)
                        },
                        contextMenuEntries: { targetItemMenu($0) },
                        onContextMenuCommand: { ref, command in
                            onTargetMenuCommand(ref, command)
                        },
                        onContextMenuTargetAction: { item in
                            performTargetMenuAction(item)
                        },
                        onHover: { location in
                            cursorInput.location = location
                            reportCursorWorldPoint(location, size: proxy.size, fitInsets: fitInsets)
                        },
                        onPan: { delta in
                            updateLiveViewport { viewport in
                                viewport.pan(by: delta)
                            }
                        },
                        onPinch: { scale, anchor, panDelta, size in
                            updateLiveViewport { viewport in
                                viewport.applyMagnification(
                                    scale,
                                    anchor: anchor,
                                    size: size,
                                    bounds: bounds,
                                    fitInsets: fitInsets
                                )
                                viewport.pan(by: panDelta)
                            }
                        },
                        onGestureEnd: {
                            // Push the live viewport into the @Binding now so the
                            // selection/hover box (and other viewport-derived chrome)
                            // re-renders at the settled zoom/pan immediately, instead
                            // of staying stale until the driver's 600 ms settle fires.
                            flushLiveViewport()
                        },
                        onKeyEvent: { keyEvent in
                            // Mirrors the macOS MonitorView.handleInteractionKeyDown
                            // dispatch, decoding via the shared HorizontalCanvasInputCore.
                            if HorizontalCanvasInputCore.isEscape(keyEvent) {
                                onCommand(.cancelInteraction)
                                return true
                            }
                            if HorizontalCanvasInputCore.isReturn(keyEvent) {
                                onCommand(.commitInteraction)
                                return true
                            }
                            if let direction = HorizontalCanvasInputCore.arrowDirection(keyEvent) {
                                let modifiers = keyEvent.modifiers
                                guard modifiers.isEmpty || modifiers == .option else {
                                    return false
                                }
                                moveSelectionByGrid(direction: direction, fine: modifiers == .option)
                                return true
                            }
                            if HorizontalCanvasInputCore.isDelete(keyEvent) {
                                onCommand(.deleteSelection)
                                return true
                            }
                            if let command = HorizontalCanvasInputCore.command(keyEvent, supportsTrackVias: supportsTrackVias) {
                                onCommand(command)
                                return true
                            }
                            return false
                        },
                        selectionTool: selectionToolSettings.tool,
                        selectionModifierAction: selectionToolSettings.modifierAction,
                        onPrimaryDragChanged: { start, current, points, size, _, isActive in
                            handlePrimaryDragChanged(start: start, current: current, points: points, size: size, fitInsets: fitInsets, isActive: isActive)
                        },
                        onPrimaryDragEnded: { start, current, points, size, action, isActive in
                            handlePrimaryDragEnded(start: start, current: current, points: points, size: size, fitInsets: fitInsets, action: action, isActive: isActive)
                        }
                    )
                    #endif
                }

                if showsSelectionDetails, selectionDetails.hasSelection {
                    HorizontalSelectionPopoverView(
                        state: selectionDetails,
                        foregroundColor: foregroundColor,
                        backgroundColor: overlayBackgroundColor,
                        onChange: onSelectionPropertyChange
                    )
                        .onHover { inside in
                            pointerInsideSelectionPopover = inside
                        }
                        .padding(.top, overlayInsets.top)
                        .padding(.leading, overlayInsets.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if showsHoverPopover, let hovered = selectionHUD.hovered {
                    HorizontalHoverPopoverView(
                        item: hovered,
                        foregroundColor: foregroundColor,
                        backgroundColor: overlayBackgroundColor
                    )
                        .padding(.top, overlayInsets.top)
                        .padding(.leading, overlayInsets.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }

                if !unplacedObjects.isEmpty {
                    HorizontalUnplacedObjectColumn(
                        objects: unplacedObjects,
                        selectedID: selectedUnplacedObjectID,
                        foregroundColor: foregroundColor,
                        backgroundColor: overlayBackgroundColor,
                        labelSide: placesUnplacedObjectsOnTrailingEdge ? .leading : .trailing,
                        onSelect: onUnplacedObjectSelection
                    )
                    .padding(.top, overlayInsets.top + 42)
                    .padding(unplacedObjectColumnHorizontalEdge, unplacedObjectColumnHorizontalPadding(overlayInsets))
                    .padding(.bottom, overlayInsets.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: unplacedObjectColumnAlignment)
                }

            }

        }
        .onAppear {
            configureViewportDriver()
        }
        .onChange(of: viewport) { _, newValue in
            synchronizeLiveViewportFromBinding(newValue)
        }
        .onDisappear {
            flushLiveViewport()
        }
    }

    private func canvasFitInsets(for proxy: GeometryProxy) -> HorizontalCanvasInsets {
        let safeAreaInsets = fitSafeAreaInsets ?? proxy.safeAreaInsets

        return HorizontalCanvasInsets(
            top: max(
                HorizontalCanvasInsets.fullBleedMinimumFit.top,
                HorizontalCanvasInsets.defaultFit.top + safeAreaInsets.top
            ),
            leading: max(
                HorizontalCanvasInsets.fullBleedMinimumFit.leading,
                HorizontalCanvasInsets.defaultFit.leading + safeAreaInsets.leading
            ),
            bottom: HorizontalCanvasInsets.defaultFit.bottom,
            trailing: HorizontalCanvasInsets.defaultFit.trailing
        )
    }

    private func overlayInsets(for proxy: GeometryProxy) -> EdgeInsets {
        let safeAreaInsets = fitSafeAreaInsets ?? proxy.safeAreaInsets
        return EdgeInsets(
            top: safeAreaInsets.top + 12,
            leading: safeAreaInsets.leading + 12,
            bottom: safeAreaInsets.bottom + 18,
            trailing: safeAreaInsets.trailing + 12
        )
    }

    private var unplacedObjectColumnAlignment: Alignment {
        placesUnplacedObjectsOnTrailingEdge ? .topTrailing : .topLeading
    }

    private var unplacedObjectColumnHorizontalEdge: Edge.Set {
        placesUnplacedObjectsOnTrailingEdge ? .trailing : .leading
    }

    private func unplacedObjectColumnHorizontalPadding(_ insets: EdgeInsets) -> CGFloat {
        (placesUnplacedObjectsOnTrailingEdge ? insets.trailing : insets.leading) + 8
    }

    private func canvasMouseExclusionInsets(for proxy: GeometryProxy) -> EdgeInsets {
        let safeAreaInsets = fitSafeAreaInsets ?? proxy.safeAreaInsets
        return EdgeInsets(top: safeAreaInsets.top, leading: 0, bottom: 0, trailing: 0)
    }

    private func updateLiveViewport(_ update: (inout CanvasViewport) -> Void) {
        #if canImport(MetalKit)
        if usesViewportDriver {
            viewportDriver.update(update)
        } else {
            update(&viewport)
        }
        #else
        update(&viewport)
        #endif
    }

    private func configureViewportDriver() {
        #if canImport(MetalKit)
        guard usesViewportDriver else {
            return
        }
        liveChromeViewport = viewport
        viewportDriver.configure(viewport: viewport) { settledViewport in
            guard viewport != settledViewport else {
                return
            }
            viewport = settledViewport
        } onLiveViewportChange: { liveViewport in
            guard liveChromeViewport != liveViewport else {
                return
            }
            liveChromeViewport = liveViewport
        }
        #endif
    }

    private func synchronizeLiveViewportFromBinding(_ newValue: CanvasViewport) {
        #if canImport(MetalKit)
        guard usesViewportDriver else {
            return
        }
        if liveChromeViewport != newValue {
            liveChromeViewport = newValue
        }
        viewportDriver.configure(viewport: newValue)
        #endif
    }

    private func flushLiveViewport() {
        #if canImport(MetalKit)
        guard usesViewportDriver else {
            return
        }
        liveChromeViewport = viewportDriver.viewport
        viewportDriver.flush()
        #endif
    }

    private func metalSelectionDragBatch(transform: HorizontalCanvasTransform) -> HorizontalMetalInteractiveOverlayBatch {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported,
              let preview = selectionDragPreview else {
            return .empty
        }

        var batch = HorizontalMetalInteractiveOverlayBatch()
        let lineColor = HorizontalMetalRGBA(foregroundColor.opacity(0.72))
        let matchColor = HorizontalMetalRGBA(foregroundColor.opacity(0.78))

        func appendScreenLine(
            from: CGPoint,
            to: CGPoint,
            color: HorizontalMetalRGBA,
            width: Float,
            dash: (Float, Float)? = nil
        ) {
            guard from != to else {
                return
            }
            batch.screenLines.append(
                HorizontalMetalScreenLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    width: width,
                    dashLength: dash?.0 ?? 0,
                    dashGap: dash?.1 ?? 0
                )
            )
        }

        func appendClosedScreenPolyline(
            _ points: [CGPoint],
            color: HorizontalMetalRGBA,
            width: Float,
            dash: (Float, Float)? = nil
        ) {
            guard let first = points.first, points.count >= 2 else {
                return
            }
            let closedPoints = points + [first]
            for pair in zip(closedPoints, closedPoints.dropFirst()) {
                appendScreenLine(from: pair.0, to: pair.1, color: color, width: width, dash: dash)
            }
        }

        func appendScreenFan(_ points: [CGPoint], color: HorizontalMetalRGBA) {
            guard points.count >= 3 else {
                return
            }
            let anchor = points[0]
            for index in 1..<(points.count - 1) {
                batch.screenTriangles.append(
                    HorizontalMetalScreenTrianglePrimitive(
                        a: anchor,
                        b: points[index],
                        c: points[index + 1],
                        color: color
                    )
                )
            }
        }

        switch preview.tool {
        case .box:
            let rect = CGRect(
                x: min(preview.start.x, preview.current.x),
                y: min(preview.start.y, preview.current.y),
                width: abs(preview.current.x - preview.start.x),
                height: abs(preview.current.y - preview.start.y)
            )
            if rect.width > 0, rect.height > 0 {
                let points = [
                    CGPoint(x: rect.minX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.maxY)
                ]
                appendScreenFan(points, color: HorizontalMetalRGBA(foregroundColor.opacity(0.08)))
                appendClosedScreenPolyline(points, color: lineColor, width: 1, dash: (5, 3))
            }
        case .lasso:
            guard preview.points.count >= 2 else {
                return .empty
            }
            appendScreenFan(preview.points, color: HorizontalMetalRGBA(foregroundColor.opacity(0.06)))
            appendClosedScreenPolyline(preview.points, color: lineColor, width: 1.2, dash: (5, 3))
        case .paint:
            guard preview.points.count >= 2 else {
                return .empty
            }
            for pair in zip(preview.points, preview.points.dropFirst()) {
                appendScreenLine(from: pair.0, to: pair.1, color: lineColor, width: 7)
            }
            let centerColor = HorizontalMetalRGBA(backgroundColor.opacity(0.88))
            for pair in zip(preview.points, preview.points.dropFirst()) {
                appendScreenLine(from: pair.0, to: pair.1, color: centerColor, width: 3)
            }
        }

        appendSelectionDragMatches(preview, to: &batch, transform: transform, color: matchColor)
        return batch
        #else
        return .empty
        #endif
    }

    private func appendSelectionDragMatches(
        _ preview: HorizontalSelectionDragPreview,
        to batch: inout HorizontalMetalInteractiveOverlayBatch,
        transform: HorizontalCanvasTransform,
        color: HorizontalMetalRGBA
    ) {
        let refs = Set(selectionRefs(for: preview, transform: transform))
        guard !refs.isEmpty else {
            return
        }

        func appendWorldLine(from: HorizontalPoint, to: HorizontalPoint) {
            guard pointKey(from) != pointKey(to) else {
                return
            }
            batch.worldLines.append(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    minimumWidth: 1.1,
                    dashLength: 3,
                    dashGap: 3
                )
            )
        }

        func appendScreenLine(from: CGPoint, to: CGPoint) {
            guard from != to else {
                return
            }
            batch.screenLines.append(
                HorizontalMetalScreenLinePrimitive(
                    from: from,
                    to: to,
                    color: HorizontalMetalRGBA(foregroundColor.opacity(0.84)),
                    width: 1.2
                )
            )
        }

        for selectable in selectionSelectables where refs.contains(selectable.ref) {
            guard selectable.corners.count >= 2 else {
                let center = transform.point(selectable.center)
                let radius: CGFloat = 5
                let points = (0..<18).map { index in
                    let angle = Double(index) / 18 * Double.pi * 2
                    return CGPoint(
                        x: center.x + CGFloat(cos(angle)) * radius,
                        y: center.y + CGFloat(sin(angle)) * radius
                    )
                }
                for pair in zip(points, Array(points.dropFirst()) + [points[0]]) {
                    appendScreenLine(from: pair.0, to: pair.1)
                }
                continue
            }

            let points = selectable.corners
            for pair in zip(points, Array(points.dropFirst()) + [points[0]]) {
                appendWorldLine(from: pair.0, to: pair.1)
            }
        }
    }

    private func currentTransform(size: CGSize, fitInsets: HorizontalCanvasInsets) -> HorizontalCanvasTransform {
        let viewport = interactionViewport
        return HorizontalCanvasTransform(
            bounds: bounds,
            size: size,
            fitInsets: fitInsets,
            zoom: viewport.zoom,
            pan: viewport.pan
        )
    }

    private func reportCursorWorldPoint(_ location: CGPoint?, size: CGSize, fitInsets: HorizontalCanvasInsets) {
        guard let location else {
            onCursorWorldPointChange(nil, 0)
            return
        }

        let transform = currentTransform(size: size, fitInsets: fitInsets)
        onCursorWorldPointChange(
            snappedCursor(at: location, transform: transform).point,
            worldUnitsPerScreenPoint(transform: transform, size: size)
        )
    }

    #if canImport(AppKit)
    private func showContextMenu(
        canvasLocation: CGPoint,
        size: CGSize,
        fitInsets: HorizontalCanvasInsets
    ) {
        let transform = currentTransform(size: size, fitInsets: fitInsets)
        let worldPoint = snappedCursor(at: canvasLocation, transform: transform).point
        let unitsPerPoint = worldUnitsPerScreenPoint(transform: transform, size: size)
        let targets = targetMenuItems(worldPoint, unitsPerPoint)
        // The permanent Fit View / Copy Visible Bounds / Copy Coordinates items
        // were removed, so the context menu is purely the objects under the
        // cursor — nothing there means no menu.
        guard !targets.isEmpty else {
            return
        }
        let menu = NSMenu()
        var refForItem = [ObjectIdentifier: HorizontalSelectableRef]()

        if targets.count == 1,
           let target = targets.first,
           let ref = target.ref,
           !targetItemMenu(ref).isEmpty {
            // Exactly one object under the cursor → show its action menu directly,
            // without the extra "ItemName ▸" nesting. Every top-level item maps to
            // the object so hovering keeps it highlighted.
            for entry in targetItemMenu(ref) {
                let item = makeTargetMenuEntryItem(entry, ref: ref, target: target)
                if !item.isSeparatorItem {
                    refForItem[ObjectIdentifier(item)] = ref
                }
                menu.addItem(item)
            }
        } else {
            appendTargetMenuItems(targets, to: menu, refForItem: &refForItem)
        }

        let highlightDelegate = CanvasMenuHighlightDelegate(refForItem: refForItem, onHighlight: onTargetMenuHighlight)
        menu.delegate = highlightDelegate
        // No NSView is handed to the SwiftUI pointer path, so pop up in screen
        // coordinates at the cursor (NSEvent.mouseLocation is the click point).
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        // popUp is synchronous; menuDidClose already cleared the highlight, but
        // clear again defensively for the no-hover dismiss path.
        onTargetMenuHighlight(nil)
        _ = highlightDelegate // keep the (weakly-referenced) delegate alive across popUp
    }

    private func showSelectionTargetMenu(targets: [HorizontalSelectionTargetItem]) {
        let menu = NSMenu()
        var refForItem = [ObjectIdentifier: HorizontalSelectableRef]()
        appendTargetMenuItems(targets, to: menu, refForItem: &refForItem)

        let highlightDelegate = CanvasMenuHighlightDelegate(refForItem: refForItem, onHighlight: onTargetMenuHighlight)
        menu.delegate = highlightDelegate
        // This fires from inside the SwiftUI select gesture's callback, and popUp
        // spins a nested modal runloop — defer it one tick so the gesture (and its
        // `defer { dragState = nil }`) fully unwinds first, avoiding re-entrancy
        // into the in-flight gesture. Capture the cursor now (screen coordinates —
        // no NSView on this path) so the menu still anchors at the click even if
        // the pointer drifts before the next tick.
        let anchor = NSEvent.mouseLocation
        let clearHighlight = onTargetMenuHighlight
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: anchor, in: nil)
            clearHighlight(nil)
            _ = highlightDelegate
        }
    }

    /// Appends one menu item per disambiguation candidate. A candidate with a
    /// non-empty `targetItemMenu` becomes a parent item carrying an action
    /// submenu (Select / Copy / Move ▸ … / Delete); otherwise it stays a plain
    /// click-to-select item. `refForItem` maps each parent item to its object so
    /// the highlight delegate can light it up on hover.
    private func appendTargetMenuItems(
        _ targets: [HorizontalSelectionTargetItem],
        to menu: NSMenu,
        refForItem: inout [ObjectIdentifier: HorizontalSelectableRef]
    ) {
        for target in targets {
            guard let ref = target.ref else {
                // Non-ref entries (copy-text / open-URL) stay direct actions.
                menu.addItem(makeTargetActionItem(target))
                continue
            }
            let entries = targetItemMenu(ref)
            let parent: NSMenuItem
            if entries.isEmpty {
                parent = makeTargetActionItem(target)
            } else {
                parent = NSMenuItem(title: target.menuTitle, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for entry in entries {
                    submenu.addItem(makeTargetMenuEntryItem(entry, ref: ref, target: target))
                }
                parent.submenu = submenu
            }
            refForItem[ObjectIdentifier(parent)] = ref
            menu.addItem(parent)
        }
    }

    /// A plain item whose click performs the candidate's default action
    /// (`performTargetMenuAction`).
    private func makeTargetActionItem(_ target: HorizontalSelectionTargetItem) -> NSMenuItem {
        let item = NSMenuItem(title: target.menuTitle, action: #selector(CanvasMenuAction.invoke(_:)), keyEquivalent: "")
        let action = CanvasMenuAction {
            performTargetMenuAction(target)
        }
        item.target = action
        item.representedObject = action
        return item
    }

    /// Recursively builds a submenu entry. `target` is forwarded so a `.select`
    /// entry runs the same default action as a legacy click-to-select item.
    private func makeTargetMenuEntryItem(
        _ entry: HorizontalTargetItemMenuEntry,
        ref: HorizontalSelectableRef,
        target: HorizontalSelectionTargetItem
    ) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .todo(let title):
            // No target/action → AppKit auto-disables (greyed). Discoverable but
            // clearly not yet wired up.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = "Not yet implemented"
            return item
        case .select(let title):
            let item = NSMenuItem(title: title, action: #selector(CanvasMenuAction.invoke(_:)), keyEquivalent: "")
            let action = CanvasMenuAction {
                performTargetMenuAction(target)
            }
            item.target = action
            item.representedObject = action
            return item
        case .command(let title, let command):
            let item = NSMenuItem(title: title, action: #selector(CanvasMenuAction.invoke(_:)), keyEquivalent: "")
            let action = CanvasMenuAction {
                onTargetMenuCommand(ref, command)
            }
            item.target = action
            item.representedObject = action
            return item
        case .submenu(let title, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for child in entries {
                submenu.addItem(makeTargetMenuEntryItem(child, ref: ref, target: target))
            }
            item.submenu = submenu
            return item
        }
    }

    #endif

    private func performTargetMenuAction(_ item: HorizontalSelectionTargetItem) {
        switch item.action {
        case .select(let ref):
            onTargetMenuSelection(ref)
        case .copyText(let text):
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #elseif canImport(UIKit)
            UIPasteboard.general.string = text
            #endif
        case .openURL(let url):
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            UIApplication.shared.open(url)
            #endif
        }
    }

    private func worldUnitsPerScreenPoint(transform: HorizontalCanvasTransform, size: CGSize) -> Double {
        transform.visibleBounds.width / max(Double(size.width), 1)
    }

    /// Shared primary-drag handler (macOS SwiftUI gesture, iOS pointer drag).
    /// Decides move-vs-select on the drag's first event: a press on the
    /// selection drags it (via the existing move interaction), anywhere else
    /// rubber-bands.
    private func handlePrimaryDragChanged(
        start: CGPoint,
        current: CGPoint,
        points: [CGPoint],
        size: CGSize,
        fitInsets: HorizontalCanvasInsets,
        isActive: Bool
    ) {
        if primaryDragIntent == nil {
            let transform = currentTransform(size: size, fitInsets: fitInsets)
            let unitsPerPoint = worldUnitsPerScreenPoint(transform: transform, size: size)
            primaryDragIntent = hitsSelection(transform.worldPoint(start), unitsPerPoint)
                ? .moveCandidate(origin: start)
                : .selection
        }

        switch primaryDragIntent {
        case .moveCandidate(let origin):
            let traveled = max(abs(current.x - origin.x), abs(current.y - origin.y))
            if traveled > HorizontalPrimaryDragState.activationThreshold {
                // Anchor the move at the press point, then start it — the move
                // interaction anchors at the last reported cursor position.
                reportCursorWorldPoint(origin, size: size, fitInsets: fitInsets)
                onCommand(.moveSelection)
                primaryDragIntent = .moving
            }
        case .moving, .selection, nil:
            break
        }

        if case .selection = primaryDragIntent, isActive {
            selectionDragPreview = HorizontalSelectionDragPreview(
                tool: selectionToolSettings.tool,
                start: start,
                current: current,
                points: points
            )
        }
        cursorInput.location = current
        reportCursorWorldPoint(current, size: size, fitInsets: fitInsets)
    }

    private func handlePrimaryDragEnded(
        start: CGPoint,
        current: CGPoint,
        points: [CGPoint],
        size: CGSize,
        fitInsets: HorizontalCanvasInsets,
        action: HorizontalSelectionClickAction,
        isActive: Bool
    ) {
        defer {
            selectionDragPreview = nil
            primaryDragIntent = nil
        }
        switch primaryDragIntent {
        case .moving:
            reportCursorWorldPoint(current, size: size, fitInsets: fitInsets)
            onCommand(.commitInteraction)
        case .moveCandidate:
            // Never traveled far enough to start the move; the drag machine
            // resolves these as clicks, which arrive via the click path.
            break
        case .selection, nil:
            guard isActive else {
                return
            }
            let preview = HorizontalSelectionDragPreview(
                tool: selectionToolSettings.tool,
                start: start,
                current: current,
                points: points
            )
            selectDragRegion(preview, size: size, fitInsets: fitInsets, action: action)
        }
    }

    /// Shared resolved-click handler (macOS input view + trackpad monitor, iOS
    /// tap and pointer-drag click fallback). A click that ends a move-intent
    /// drag commits the move instead of selecting; the box drag machine's
    /// activation needs both axes, so a straight-line drag-move resolves as a
    /// "click" here.
    private func handleResolvedPrimaryClick(
        location: CGPoint,
        size: CGSize,
        fitInsets: HorizontalCanvasInsets,
        action: HorizontalSelectionClickAction,
        clickCount: Int
    ) {
        if let intent = primaryDragIntent {
            primaryDragIntent = nil
            if intent == .moving {
                onCommand(.commitInteraction)
                return
            }
        }
        let transform = currentTransform(size: size, fitInsets: fitInsets)
        let worldPoint = snappedCursor(at: location, transform: transform).point
        let unitsPerPoint = worldUnitsPerScreenPoint(transform: transform, size: size)
        // The click-time disambiguation popup is macOS-only (NSMenu); on iOS
        // overlapping candidates are disambiguated by the long-press menu.
        #if canImport(AppKit)
        if allowsContextMenu, action == .replace, clickCount == 1 {
            let selectableTargets = targetMenuItems(worldPoint, unitsPerPoint).filter { $0.ref != nil }
            if selectableTargets.count > 1 {
                showSelectionTargetMenu(targets: selectableTargets)
                return
            }
        }
        #endif
        onPrimaryClick(worldPoint, unitsPerPoint, action, clickCount)
    }

    private func selectDragRegion(
        _ preview: HorizontalSelectionDragPreview,
        size: CGSize,
        fitInsets: HorizontalCanvasInsets,
        action clickAction: HorizontalSelectionClickAction
    ) {
        guard !selectionSelectables.isEmpty else {
            onAreaSelection([], effectiveAreaSelectionAction(from: clickAction))
            return
        }

        let transform = currentTransform(size: size, fitInsets: fitInsets)
        let refs: [HorizontalSelectableRef]
        switch preview.tool {
        case .box:
            refs = HorizontalSelectableHitTest.selectables(
                inBoxFrom: transform.worldPoint(preview.start),
                to: transform.worldPoint(preview.current),
                selectables: selectionSelectables,
                qualifier: selectionToolSettings.qualifier
            )
        case .lasso:
            refs = HorizontalSelectableHitTest.selectables(
                inLasso: preview.points.map(transform.worldPoint),
                selectables: selectionSelectables,
                qualifier: selectionToolSettings.qualifier
            )
        case .paint:
            refs = HorizontalSelectableHitTest.selectables(
                touchedBy: preview.points.map(transform.worldPoint),
                selectables: selectionSelectables
            )
        }
        onAreaSelection(refs, effectiveAreaSelectionAction(from: clickAction))
    }

    private func effectiveAreaSelectionAction(from clickAction: HorizontalSelectionClickAction) -> HorizontalSelectionClickAction {
        guard clickAction == .replace, selectionToolSettings.stickySelection else {
            return clickAction
        }
        return selectionToolSettings.modifierAction.clickAction
    }

    private func drawSelectionDragPreview(
        _ preview: HorizontalSelectionDragPreview,
        context: inout GraphicsContext,
        size: CGSize,
        transform: HorizontalCanvasTransform
    ) {
        let color = foregroundColor.opacity(0.72)
        switch preview.tool {
        case .box:
            let rect = CGRect(
                x: min(preview.start.x, preview.current.x),
                y: min(preview.start.y, preview.current.y),
                width: abs(preview.current.x - preview.start.x),
                height: abs(preview.current.y - preview.start.y)
            )
            guard rect.width > 0, rect.height > 0 else {
                return
            }
            let path = Path(rect)
            context.fill(path, with: .color(foregroundColor.opacity(0.08)))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1, dash: [5, 3])
            )
        case .lasso:
            guard preview.points.count >= 2 else {
                return
            }
            var path = Path()
            path.move(to: preview.points[0])
            for point in preview.points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            context.fill(path, with: .color(foregroundColor.opacity(0.06)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round, dash: [5, 3]))
        case .paint:
            guard preview.points.count >= 2 else {
                return
            }
            var path = Path()
            path.move(to: preview.points[0])
            for point in preview.points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(backgroundColor.opacity(0.88)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }

        drawSelectionDragMatches(preview, context: &context, transform: transform)
    }

    private func drawSelectionDragMatches(
        _ preview: HorizontalSelectionDragPreview,
        context: inout GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let refs = Set(selectionRefs(for: preview, transform: transform))
        guard !refs.isEmpty else {
            return
        }

        for selectable in selectionSelectables where refs.contains(selectable.ref) {
            let corners = selectable.corners.map(transform.point)
            guard corners.count >= 2 else {
                let point = transform.point(selectable.center)
                let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                context.stroke(Path(ellipseIn: rect), with: .color(foregroundColor.opacity(0.84)), lineWidth: 1.2)
                continue
            }

            var path = Path()
            path.move(to: corners[0])
            for corner in corners.dropFirst() {
                path.addLine(to: corner)
            }
            path.closeSubpath()
            context.stroke(path, with: .color(foregroundColor.opacity(0.78)), style: StrokeStyle(lineWidth: 1.1, dash: [3, 3]))
        }
    }

    private func selectionRefs(
        for preview: HorizontalSelectionDragPreview,
        transform: HorizontalCanvasTransform
    ) -> [HorizontalSelectableRef] {
        switch preview.tool {
        case .box:
            return HorizontalSelectableHitTest.selectables(
                inBoxFrom: transform.worldPoint(preview.start),
                to: transform.worldPoint(preview.current),
                selectables: selectionSelectables,
                qualifier: selectionToolSettings.qualifier
            )
        case .lasso:
            return HorizontalSelectableHitTest.selectables(
                inLasso: preview.points.map(transform.worldPoint),
                selectables: selectionSelectables,
                qualifier: selectionToolSettings.qualifier
            )
        case .paint:
            return HorizontalSelectableHitTest.selectables(
                touchedBy: preview.points.map(transform.worldPoint),
                selectables: selectionSelectables
            )
        }
    }

    private func drawScaleBar(
        context: inout GraphicsContext,
        size: CGSize,
        transform: HorizontalCanvasTransform,
        overlayInsets: EdgeInsets,
        drawsLinesInMetal: Bool
    ) {
        let visible = transform.visibleBounds
        guard !visible.isEmpty, size.width > 0 else {
            return
        }

        let targetScreenLength = min(max(size.width * 0.12, 72), 120)
        let worldUnitsPerPoint = visible.width / Double(size.width)
        let worldLength = niceScaleLength(worldUnitsPerPoint * Double(targetScreenLength))
        let screenLength = transform.length(worldLength)
        guard screenLength >= 24 else {
            return
        }

        let origin = CGPoint(
            x: overlayInsets.leading,
            y: max(overlayInsets.top + 18, size.height - overlayInsets.bottom)
        )
        var path = Path()
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + screenLength, y: origin.y))
        path.move(to: CGPoint(x: origin.x, y: origin.y - 4))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + 4))
        path.move(to: CGPoint(x: origin.x + screenLength, y: origin.y - 4))
        path.addLine(to: CGPoint(x: origin.x + screenLength, y: origin.y + 4))

        if !drawsLinesInMetal {
            context.stroke(
                path,
                with: .color(foregroundColor.opacity(0.52)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
        context.draw(
            Text(scaleLabel(for: worldLength))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(foregroundColor.opacity(0.72)),
            at: CGPoint(x: origin.x, y: origin.y - 6),
            anchor: .bottomLeading
        )
    }

    private func scaleBarTextOverlay(
        size: CGSize,
        transform: HorizontalCanvasTransform,
        overlayInsets: EdgeInsets
    ) -> (label: String, position: CGPoint)? {
        guard showsScaleBar else {
            return nil
        }
        let visible = transform.visibleBounds
        guard !visible.isEmpty, size.width > 0 else {
            return nil
        }

        let targetScreenLength = min(max(size.width * 0.12, 72), 120)
        let worldUnitsPerPoint = visible.width / Double(size.width)
        let worldLength = niceScaleLength(worldUnitsPerPoint * Double(targetScreenLength))
        let screenLength = transform.length(worldLength)
        guard screenLength >= 24 else {
            return nil
        }

        let origin = CGPoint(
            x: overlayInsets.leading,
            y: max(overlayInsets.top + 18, size.height - overlayInsets.bottom)
        )
        return (
            scaleLabel(for: worldLength),
            CGPoint(x: origin.x, y: origin.y - 20)
        )
    }

    private func niceScaleLength(_ rawLength: Double) -> Double {
        guard rawLength > 0 else {
            return 1_000_000
        }

        let magnitude = pow(10, floor(log10(rawLength)))
        let normalized = rawLength / magnitude
        let nice: Double
        if normalized < 2 {
            nice = 1
        } else if normalized < 5 {
            nice = 2
        } else {
            nice = 5
        }
        return nice * magnitude
    }

    private func metalScaleBarScreenLines(
        size: CGSize,
        transform: HorizontalCanvasTransform,
        overlayInsets: EdgeInsets
    ) -> [HorizontalMetalScreenLinePrimitive] {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported,
              showsScaleBar else {
            return []
        }

        let visible = transform.visibleBounds
        guard !visible.isEmpty, size.width > 0 else {
            return []
        }

        let targetScreenLength = min(max(size.width * 0.12, 72), 120)
        let worldUnitsPerPoint = visible.width / Double(size.width)
        let screenLength = transform.length(niceScaleLength(worldUnitsPerPoint * Double(targetScreenLength)))
        guard screenLength >= 24 else {
            return []
        }

        let origin = CGPoint(
            x: overlayInsets.leading,
            y: max(overlayInsets.top + 18, size.height - overlayInsets.bottom)
        )
        let color = HorizontalMetalRGBA(foregroundColor.opacity(0.52))
        return [
            HorizontalMetalScreenLinePrimitive(
                from: origin,
                to: CGPoint(x: origin.x + screenLength, y: origin.y),
                color: color,
                width: 1
            ),
            HorizontalMetalScreenLinePrimitive(
                from: CGPoint(x: origin.x, y: origin.y - 4),
                to: CGPoint(x: origin.x, y: origin.y + 4),
                color: color,
                width: 1
            ),
            HorizontalMetalScreenLinePrimitive(
                from: CGPoint(x: origin.x + screenLength, y: origin.y - 4),
                to: CGPoint(x: origin.x + screenLength, y: origin.y + 4),
                color: color,
                width: 1
            )
        ]
        #else
        return []
        #endif
    }

    private func scaleLabel(for worldLength: Double) -> String {
        let millimeters = worldLength / 1_000_000
        if millimeters >= 10 {
            return "\(millimeters.formatted(.number.precision(.fractionLength(0)))) mm"
        }
        if millimeters >= 1 {
            return "\(millimeters.formatted(.number.precision(.fractionLength(1)))) mm"
        }
        return "\((millimeters * 1_000).formatted(.number.precision(.fractionLength(0)))) um"
    }

    private func snappedCursor(at location: CGPoint, transform: HorizontalCanvasTransform) -> HorizontalSnappedCursor {
        let worldPoint = transform.worldPoint(location)
        let gridPoint = grid.map {
            snapToGrid(worldPoint, grid: $0, divisor: gridDivisor)
        } ?? worldPoint

        // Index is (re)built only when snapTargets changes, so cursor moves over a
        // stable board are O(1)-ish instead of two O(n) scans per call.
        let index = snapIndexCache.index(for: snapTargets)

        if let exactTarget = index.exactMatch(gridPoint) {
            return HorizontalSnappedCursor(point: exactTarget, isTarget: true)
        }

        if let nearestTarget = nearestSnapTarget(index: index, to: location, transform: transform) {
            return HorizontalSnappedCursor(point: nearestTarget, isTarget: true)
        }

        return HorizontalSnappedCursor(point: gridPoint, isTarget: false)
    }

    private func nearestSnapTarget(index: HorizontalSnapIndex, to location: CGPoint, transform: HorizontalCanvasTransform) -> HorizontalPoint? {
        // 30 screen points in world units (uniform canvas scale → just divide by it,
        // derived robustly from the transform itself).
        let snapRadius: CGFloat = 30
        let world = transform.worldPoint(location)
        let edge = transform.worldPoint(CGPoint(x: location.x + snapRadius, y: location.y))
        let worldRadius = hypot(edge.x - world.x, edge.y - world.y)
        return index.nearest(to: world, within: worldRadius)
    }

    private func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }

    private func snapToGrid(_ point: HorizontalPoint, grid: HorizontalGridSettings, divisor: Int) -> HorizontalPoint {
        HorizontalCanvasInputCore.snapToGrid(point, grid: grid, divisor: divisor)
    }

    private func moveSelectionByGrid(direction: HorizontalPoint, fine: Bool) {
        guard let grid else {
            return
        }

        let divisor = fine ? 10.0 : 1.0
        let delta = HorizontalPoint(
            x: direction.x * grid.spacing.x / divisor,
            y: direction.y * grid.spacing.y / divisor
        )
        onCommand(.moveSelectionBy(delta))
    }
}

#if canImport(AppKit)
private final class CanvasMenuAction: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) {
        action()
    }
}

/// Lights up the board object under a disambiguation/context-menu candidate as
/// the pointer moves over it. The parent menu's highlighted item stays selected
/// while its submenu is open, so the highlight persists while the user browses
/// that candidate's actions; moving to a sibling (or off all candidates) updates
/// or clears it. Submenus carry no delegate, so they don't disturb the parent's
/// highlight.
private final class CanvasMenuHighlightDelegate: NSObject, NSMenuDelegate {
    private let refForItem: [ObjectIdentifier: HorizontalSelectableRef]
    private let onHighlight: (HorizontalSelectableRef?) -> Void

    init(
        refForItem: [ObjectIdentifier: HorizontalSelectableRef],
        onHighlight: @escaping (HorizontalSelectableRef?) -> Void
    ) {
        self.refForItem = refForItem
        self.onHighlight = onHighlight
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let item, let ref = refForItem[ObjectIdentifier(item)] {
            onHighlight(ref)
        } else {
            onHighlight(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        onHighlight(nil)
    }
}
#endif

private struct HorizontalHoverPopoverView: View {
    var item: HorizontalSelectionHUDItem
    var foregroundColor: Color
    var backgroundColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Hover")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(foregroundColor.opacity(0.54))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(foregroundColor.opacity(0.66))
                        .lineLimit(1)
                }
            }

            if !item.details.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.details.prefix(8)) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(detail.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(foregroundColor.opacity(0.52))
                            Text(detail.value)
                                .font(.caption2)
                                .foregroundStyle(foregroundColor.opacity(0.78))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(foregroundColor.opacity(0.16), lineWidth: 0.7)
        }
        .foregroundStyle(foregroundColor)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

private struct HorizontalUnplacedObjectColumn: View {
    var objects: [HorizontalUnplacedObject]
    var selectedID: String?
    var foregroundColor: Color
    var backgroundColor: Color
    var labelSide = HorizontalRailHelpLabelSide.trailing
    var onSelect: (HorizontalUnplacedObject) -> Void

    @State private var isRailHovered = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(objects) { object in
                    HorizontalRailHelpLabel(title: helpText(for: object), labelOffset: 54) {
                        Button {
                            onSelect(object)
                        } label: {
                            Text(object.label)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                                .foregroundStyle(foregroundColor.opacity(selectedID == object.id ? 0.96 : 0.78))
                                .frame(width: 44, height: 28)
                                .background {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(backgroundColor.opacity(selectedID == object.id ? 0.96 : 0.74))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(
                                            foregroundColor.opacity(selectedID == object.id ? 0.42 : 0.18),
                                            lineWidth: selectedID == object.id ? 1.1 : 0.7
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(helpText(for: object))
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 5)
        }
        .frame(
            width: isRailHovered ? 240 : 54,
            alignment: labelSide == .trailing ? .leading : .trailing
        )
        .frame(maxHeight: 320)
        .environment(\.horizonRailHelpLabelsVisible, isRailHovered)
        .environment(\.horizonRailHelpLabelSide, labelSide)
        .contentShape(Rectangle())
        .onHover { isRailHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: isRailHovered)
    }

    private func helpText(for object: HorizontalUnplacedObject) -> String {
        let subtitle = object.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return subtitle.isEmpty ? object.label : "\(object.label) \(subtitle)"
    }
}

/// Cross-platform SwiftUI canvas input (the unified pointer layer). A drag either
/// PANS (`.pans`, iOS navigation) or runs the shared select state machine
/// (`.selects`, macOS mouse / iOS tool-armed). Taps are modifier-aware (modifiers
/// arrive via `currentModifiers` — on macOS from the NSEvent flags side-channel)
/// and pinch zooms anchored on the centroid. Double-click is detected by timing
/// since SwiftUI drags carry no click count.
struct HorizontalCanvasInputView: View {
    enum DragMode { case pans, selects, tapsOnly }

    var dragMode: DragMode
    var selectionTool: HorizontalSelectionTool = .box
    var selectionModifierAction: HorizontalSelectionModifierAction = .toggle
    /// Current keyboard modifiers (macOS NSEvent flags side-channel; `[]` on touch).
    var currentModifiers: () -> HorizontalCanvasInputModifiers = { [] }

    var onPan: (CGSize) -> Void = { _ in }
    /// Resolved click: world-less local point, size, modifier action, click count.
    var onPrimaryClick: (CGPoint, CGSize, HorizontalSelectionClickAction, Int) -> Void
    var onPrimaryDragChanged: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void = { _, _, _, _, _, _ in }
    var onPrimaryDragEnded: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void = { _, _, _, _, _, _ in }
    /// Per-frame relative magnification ratio, the pinch anchor (in points), size.
    /// Used by the macOS `MagnifyGesture`; on iOS pinch comes from the UIKit
    /// `HorizontalMultitouchView`, so this defaults to a no-op there.
    var onMagnify: (CGFloat, CGPoint, CGSize) -> Void = { _, _, _ in }
    var onCursorLocationChange: (CGPoint?) -> Void

    @State private var lastDragTranslation = CGSize.zero
    @State private var lastMagnification: CGFloat = 1
    @State private var dragState: HorizontalPrimaryDragState?
    @State private var lastTapTime = Date.distantPast
    @State private var lastTapLocation = CGPoint.zero

    var body: some View {
        GeometryReader { proxy in
            canvas(size: proxy.size)
        }
    }

    // The pinch gesture is macOS-only: on iOS the UIKit `HorizontalMultitouchView`
    // owns two-finger pan+zoom (and trackpad scroll), so a SwiftUI `MagnifyGesture`
    // here would double-handle the pinch.
    @ViewBuilder
    private func canvas(size: CGSize) -> some View {
        #if os(macOS)
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(magnifyGesture(size: size))
            .onContinuousHover(coordinateSpace: .local) { phase in
                reportHover(phase)
            }
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            // Apple Pencil hover (and trackpad pointer) feed a continuous cursor so
            // the interactive router can preview without a touch down.
            .onContinuousHover(coordinateSpace: .local) { phase in
                reportHover(phase)
            }
        #endif
    }

    private func reportHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            onCursorLocationChange(location)
        case .ended:
            onCursorLocationChange(nil)
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                onCursorLocationChange(value.location)
                switch dragMode {
                case .pans:
                    let delta = CGSize(
                        width: value.translation.width - lastDragTranslation.width,
                        height: value.translation.height - lastDragTranslation.height
                    )
                    lastDragTranslation = value.translation
                    if abs(value.translation.width) > 4 || abs(value.translation.height) > 4 {
                        onPan(delta)
                    }
                case .selects:
                    if dragState == nil {
                        dragState = HorizontalPrimaryDragState(
                            start: value.startLocation,
                            current: value.startLocation,
                            points: [value.startLocation],
                            action: HorizontalCanvasInputCore.clickAction(modifiers: currentModifiers(), modifierAction: selectionModifierAction),
                            clickCount: 1
                        )
                    }
                    dragState?.extend(to: value.location, tool: selectionTool)
                    if let state = dragState {
                        onPrimaryDragChanged(state.start, state.current, state.points, size, state.action, state.isActive)
                    }
                case .tapsOnly:
                    // Single-finger drag is reserved (navigation is two-finger on
                    // iOS); only the tap on lift is meaningful.
                    break
                }
            }
            .onEnded { value in
                defer {
                    lastDragTranslation = .zero
                    dragState = nil
                }
                let wasTap = abs(value.translation.width) <= 4 && abs(value.translation.height) <= 4
                switch dragMode {
                case .pans:
                    if wasTap {
                        fireTap(at: value.location, size: size, action: .replace)
                    }
                case .selects:
                    if var state = dragState {
                        switch state.resolve(at: value.location) {
                        case let .drag(start, current, points, action):
                            onPrimaryDragEnded(start, current, points, size, action, true)
                        case let .click(point, _, action):
                            fireTap(at: point, size: size, action: action)
                        }
                    } else if wasTap {
                        fireTap(at: value.location, size: size, action: HorizontalCanvasInputCore.clickAction(modifiers: currentModifiers(), modifierAction: selectionModifierAction))
                    }
                case .tapsOnly:
                    if wasTap {
                        fireTap(at: value.location, size: size, action: HorizontalCanvasInputCore.clickAction(modifiers: currentModifiers(), modifierAction: selectionModifierAction))
                    }
                }
            }
    }

    /// Single/double-click detection (SwiftUI drags carry no click count).
    private func fireTap(at location: CGPoint, size: CGSize, action: HorizontalSelectionClickAction) {
        let now = Date()
        let isDouble = now.timeIntervalSince(lastTapTime) < 0.35
            && abs(location.x - lastTapLocation.x) < 16
            && abs(location.y - lastTapLocation.y) < 16
        let clickCount = isDouble ? 2 : 1
        lastTapTime = isDouble ? .distantPast : now
        lastTapLocation = location
        onPrimaryClick(location, size, action, clickCount)
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard value.magnification > 0 else {
                    return
                }
                let relative = value.magnification / lastMagnification
                lastMagnification = value.magnification
                let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                onMagnify(relative, anchor, size)
            }
            .onEnded { _ in
                lastMagnification = 1
            }
    }
}

#if canImport(UIKit)
import UIKit

/// Finds the current first responder via the standard `sendAction(to: nil)` walk,
/// so the canvas can tell whether a text field is being edited before reclaiming
/// key focus. (Extensions can't add stored properties, so the capture slot lives
/// here.)
private enum HorizontalFirstResponderProbe {
    // Touched only on the main thread (UIKit responder chain + main-queue callers).
    nonisolated(unsafe) static weak var captured: UIResponder?

    static func currentResponderIsTextInput() -> Bool {
        captured = nil
        // This probe only ever runs on the main thread (main-queue callers walking the
        // responder chain), but it's a synchronous nonisolated function so the compiler
        // can't prove it. Assert the isolation so the main-actor `UIApplication` call is
        // allowed without forcing the caller to become async.
        MainActor.assumeIsolated {
            // Discard the Bool result so the closure (and assumeIsolated) returns Void.
            _ = UIApplication.shared.sendAction(
                #selector(UIResponder.horizonCaptureFirstResponder(_:)),
                to: nil,
                from: nil,
                for: nil
            )
        }
        let responder = captured
        return responder is UITextField || responder is UITextView
    }
}

extension UIResponder {
    @objc fileprivate func horizonCaptureFirstResponder(_ sender: Any) {
        HorizontalFirstResponderProbe.captured = self
    }
}

/// The complete iOS canvas input view (UIKit gesture recognizers). The two-finger
/// pan+zoom is ported from dexef's `MetalCanvas`: a 2-touch `UIPanGestureRecognizer`
/// (with `allowedScrollTypesMask` so an iPad trackpad's indirect two-finger scroll
/// also pans) plus a simultaneous `UIPinchGestureRecognizer` give combined pan AND
/// zoom — the pinch centroid drives pan, the pinch scale drives zoom — and losing
/// one finger mid-pinch keeps panning (no zoom) without a positional jump. Tap /
/// double-tap round out selection and draw-commit; a `UIContextMenuInteraction`
/// provides the long-press context menu (a real native `UIMenu` with nested
/// submenus, system styling and 44pt rows); hover drives the Pencil cursor. Every
/// recognizer lives on one `UIView` so there is no SwiftUI-gesture vs
/// UIKit-recognizer touch arbitration (a layered approach would let whichever view
/// is on top swallow the other's touches).
struct HorizontalMultitouchView: UIViewRepresentable {
    /// Tap: location (points), view size, active keyboard modifiers (iPad hardware
    /// keyboard), and click count (2 = double-tap).
    var onTap: (CGPoint, CGSize, HorizontalCanvasInputModifiers, Int) -> Void
    /// Candidate objects under a long-press point (view-local points) for the
    /// native context menu. Empty ⇒ no menu.
    var contextMenuTargets: (CGPoint) -> [HorizontalSelectionTargetItem]
    /// The per-object action entries (Select / Copy / Move ▸ … / Delete).
    var contextMenuEntries: (HorizontalSelectableRef) -> [HorizontalTargetItemMenuEntry]
    var onContextMenuCommand: (HorizontalSelectableRef, HorizontalCanvasCommand) -> Void
    var onContextMenuTargetAction: (HorizontalSelectionTargetItem) -> Void
    /// Apple Pencil / trackpad-pointer hover → cursor (nil when it leaves).
    var onHover: (CGPoint?) -> Void
    /// One/two-finger + trackpad pan: incremental translation delta (points).
    var onPan: (CGSize) -> Void
    /// Combined zoom+pan: incremental scale ratio, the pinch-centroid anchor
    /// (points), the centroid pan delta (points), and the view size.
    var onPinch: (CGFloat, CGPoint, CGSize, CGSize) -> Void
    /// Fired when a pan/pinch recognizer ends or cancels. Lets the parent flush the
    /// viewport driver so the settled viewport reaches the @Binding immediately
    /// (instead of after the 600 ms debounce), forcing a re-render that repositions
    /// viewport-derived chrome (the selection/hover box) right after the gesture.
    /// Unlike macOS — which keeps re-sampling via mouseMoved after a magnify — a
    /// touch gesture ends with no follow-up events, so without this the chrome would
    /// stay at its pre-gesture screen position until the debounce fired.
    var onGestureEnd: () -> Void = {}
    /// Hardware-keyboard key (iPad). Returns true if the canvas consumed it; false
    /// lets the press propagate up the responder chain.
    var onKeyEvent: (HorizontalCanvasKeyEvent) -> Bool = { _ in false }
    /// Trackpad/mouse pointer click-drag, in `HorizontalCanvasInputView`'s
    /// primary-drag shape: (start, current, points, size, action, isActive).
    var selectionTool: HorizontalSelectionTool = .box
    var selectionModifierAction: HorizontalSelectionModifierAction = .toggle
    var onPrimaryDragChanged: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void = { _, _, _, _, _, _ in }
    var onPrimaryDragEnded: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void = { _, _, _, _, _, _ in }

    /// Everything except the Pencil. The pan/pinch recognizers take these so a
    /// finger (or trackpad) still moves the board while the Pencil is reserved
    /// for pointing — the standard iPad split, and what lets a Pencil drag
    /// track the cursor instead of dragging the canvas out from under it.
    private static let nonPencilTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.indirect.rawValue),
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
    ]

    func makeUIView(context: Context) -> KeyableTouchView {
        let view = KeyableTouchView()
        view.onKeyEvent = onKeyEvent
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)

        // Native iOS context menu (real nested UIMenu submenus, system styling,
        // 44pt rows, scrolling) on long-press — replaces the old custom overlay.
        view.addInteraction(UIContextMenuInteraction(delegate: coordinator))

        let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleHover(_:)))
        hover.delegate = coordinator
        view.addGestureRecognizer(hover)

        // Apple Pencil behaves like a pointer. Hover alone isn't enough: it ENDS
        // the moment the tip contacts the glass, and Pencils/iPads without hover
        // support never report it at all — so while the tip is down, the view's
        // own touch handling feeds the same cursor, keeping the router preview
        // under the tip. Done on the VIEW rather than with a gesture recognizer
        // deliberately: a recognizer would join the failure graph and could
        // starve the tap or the long-press context menu, whereas plain touch
        // delivery runs alongside both.
        view.onPencilTouch = { [weak coordinator] location in
            coordinator?.reportPencilCursor(location)
        }
        view.onPencilTouchEnded = { [weak coordinator] in
            coordinator?.endPencilTouch()
        }
        // Ported from DeXeF's pinch re-grab jump fix (MetalCanvas
        // TouchTrackingMetalView + ViewportController.isMultiTouchSequenceActive).
        view.onMultiTouchSequenceChange = { [weak coordinator] active in
            coordinator?.setMultiTouchSequenceActive(active)
        }

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        // One finger pans too; two fingers pan (and the pinch recognizer layers
        // zoom on top, with handlePan ceding to it while pinching).
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        // Indirect two-finger scroll from a trackpad / Magic Mouse drives the same
        // recognizer (it bypasses the touch-count gate), giving trackpad panning.
        pan.allowedScrollTypesMask = .all
        // ...but NOT the Pencil: with one-finger panning enabled a Pencil drag
        // would pan the board, which is the opposite of pointing at it.
        pan.allowedTouchTypes = Self.nonPencilTouchTypes
        pan.delegate = coordinator
        view.addGestureRecognizer(pan)
        // The delegate refuses this recognizer pointer TOUCHES (a trackpad
        // click-drag rubber-bands via the recognizer below); two-finger scroll
        // arrives as UIScrollEvents through allowedScrollTypesMask, which the
        // touch refusal doesn't affect, so trackpad panning survives.
        coordinator.canvasPanRecognizer = pan

        let pointerDrag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePointerDrag(_:)))
        pointerDrag.minimumNumberOfTouches = 1
        pointerDrag.maximumNumberOfTouches = 1
        pointerDrag.allowedScrollTypesMask = []
        pointerDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerDrag.delegate = coordinator
        view.addGestureRecognizer(pointerDrag)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = coordinator
        view.addGestureRecognizer(pinch)

        return view
    }

    func updateUIView(_ uiView: KeyableTouchView, context: Context) {
        uiView.onKeyEvent = onKeyEvent
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.contextMenuTargets = contextMenuTargets
        coordinator.contextMenuEntries = contextMenuEntries
        coordinator.onContextMenuCommand = onContextMenuCommand
        coordinator.onContextMenuTargetAction = onContextMenuTargetAction
        coordinator.onHover = onHover
        coordinator.onPan = onPan
        coordinator.onPinch = onPinch
        coordinator.onGestureEnd = onGestureEnd
        coordinator.selectionTool = selectionTool
        coordinator.selectionModifierAction = selectionModifierAction
        coordinator.onPrimaryDragChanged = onPrimaryDragChanged
        coordinator.onPrimaryDragEnded = onPrimaryDragEnded
    }

    /// A first-responder UIView that turns hardware-keyboard presses into canvas
    /// key events. A focused text field becomes first responder and steals keys
    /// back automatically; tapping the canvas re-focuses it (see `handleTap`).
    final class KeyableTouchView: UIView {
        var onKeyEvent: ((HorizontalCanvasKeyEvent) -> Bool)?
        /// Apple Pencil tip position while it's touching, reported as the cursor.
        /// Handled as raw touches rather than through a gesture recognizer so it
        /// stays out of the recognizer failure graph — the tap that commits and
        /// the long-press that opens the context menu are untouched by it.
        var onPencilTouch: ((CGPoint) -> Void)?
        /// Tip lifted (or the touch was cancelled). Lets the coordinator resume
        /// honouring hover-ended, which it suppresses while the tip is down.
        var onPencilTouchEnded: (() -> Void)?
        /// True from the moment a second finger lands until the last one lifts.
        ///
        /// This is reported from `touchesBegan`, which runs BEFORE any gesture
        /// recognizer callback — that ordering is the whole point. The pan
        /// recognizer accepts one or two touches, so a second finger does not
        /// end it; instead its `translation` silently re-bases onto the
        /// two-finger centroid, and `handlePan` applies that leap as a delta,
        /// jumping the board. Suppressing the pan before the recognizer can fire
        /// is the only way to catch it, since the pinch's `.began` (and thus
        /// `isPinching`) arrives too late.
        ///
        /// It stays set until EVERY finger lifts, deliberately: dropping back to
        /// one finger re-bases the translation a second time, so releasing the
        /// suppression there would just reintroduce the jump in the other
        /// direction. While it's set the pinch handler owns panning (it pans by
        /// centroid delta, including its one-touch case).
        var onMultiTouchSequenceChange: ((Bool) -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        /// Fingers still on the canvas, excluding any ending in this event.
        /// Only `.direct` touches count: the Pencil is excluded from the pan and
        /// pinch recognizers, so it can't cause the centroid re-base this guards.
        private func activeFingerCount(for event: UIEvent?) -> Int {
            guard let touches = event?.touches(for: self) else { return 0 }
            return touches.filter {
                $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
            }.count
        }

        private func reportPencil(_ touches: Set<UITouch>) {
            guard let onPencilTouch,
                  let pencil = touches.first(where: { $0.type == .pencil }) else {
                return
            }
            onPencilTouch(pencil.location(in: self))
        }

        private func reportPencilEnded(_ touches: Set<UITouch>) {
            guard touches.contains(where: { $0.type == .pencil }) else { return }
            onPencilTouchEnded?()
        }

        private func reportTouchesLifted(_ event: UIEvent?) {
            if activeFingerCount(for: event) == 0 {
                onMultiTouchSequenceChange?(false)
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            if activeFingerCount(for: event) >= 2 {
                onMultiTouchSequenceChange?(true)
            }
            reportPencil(touches)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            reportPencil(touches)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            reportPencilEnded(touches)
            reportTouchesLifted(event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            reportPencilEnded(touches)
            reportTouchesLifted(event)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if window != nil {
                becomeFirstResponder()
                // Reclaim key focus when a rail/inspector text field (grid, track
                // width, …) finishes editing, so shortcuts resume without a tap.
                for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(textInputEndedEditing),
                        name: name,
                        object: nil
                    )
                }
            }
        }

        @objc private func textInputEndedEditing() {
            // Deferred so a field-to-field move (e.g. tabbing across grid fields)
            // can claim first responder first — only re-focus if NO text input did.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                guard !HorizontalFirstResponderProbe.currentResponderIsTextInput() else { return }
                self.becomeFirstResponder()
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            for press in presses {
                if let key = press.key, onKeyEvent?(Self.keyEvent(from: key)) == true {
                    continue
                }
                unhandled.insert(press)
            }
            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        private static func keyEvent(from key: UIKey) -> HorizontalCanvasKeyEvent {
            HorizontalCanvasKeyEvent(
                characters: key.charactersIgnoringModifiers,
                key: keyEquivalent(for: key.keyCode),
                modifiers: HorizontalCanvasInputModifiers(
                    command: key.modifierFlags.contains(.command),
                    option: key.modifierFlags.contains(.alternate),
                    control: key.modifierFlags.contains(.control),
                    shift: key.modifierFlags.contains(.shift)
                )
            )
        }

        private static func keyEquivalent(for keyCode: UIKeyboardHIDUsage) -> KeyEquivalent? {
            switch keyCode {
            case .keyboardLeftArrow: return .leftArrow
            case .keyboardRightArrow: return .rightArrow
            case .keyboardUpArrow: return .upArrow
            case .keyboardDownArrow: return .downArrow
            case .keyboardEscape: return .escape
            case .keyboardReturnOrEnter, .keypadEnter: return .return
            case .keyboardDeleteOrBackspace: return .delete
            case .keyboardDeleteForward: return .deleteForward
            default: return nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTap: onTap,
            contextMenuTargets: contextMenuTargets,
            contextMenuEntries: contextMenuEntries,
            onContextMenuCommand: onContextMenuCommand,
            onContextMenuTargetAction: onContextMenuTargetAction,
            onHover: onHover,
            onPan: onPan,
            onPinch: onPinch,
            onGestureEnd: onGestureEnd
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        var onTap: (CGPoint, CGSize, HorizontalCanvasInputModifiers, Int) -> Void
        var contextMenuTargets: (CGPoint) -> [HorizontalSelectionTargetItem]
        var contextMenuEntries: (HorizontalSelectableRef) -> [HorizontalTargetItemMenuEntry]
        var onContextMenuCommand: (HorizontalSelectableRef, HorizontalCanvasCommand) -> Void
        var onContextMenuTargetAction: (HorizontalSelectionTargetItem) -> Void
        var onHover: (CGPoint?) -> Void
        var onPan: (CGSize) -> Void
        var onPinch: (CGFloat, CGPoint, CGSize, CGSize) -> Void
        var onGestureEnd: () -> Void
        // Pointer (trackpad/mouse) click-drag: the shared primary-drag shape.
        var selectionTool: HorizontalSelectionTool = .box
        var selectionModifierAction: HorizontalSelectionModifierAction = .toggle
        var onPrimaryDragChanged: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void = { _, _, _, _, _, _ in }
        var onPrimaryDragEnded: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void = { _, _, _, _, _, _ in }
        /// The canvas pan recognizer, so the delegate can refuse it pointer
        /// touches (which the pointer-drag recognizer owns instead).
        weak var canvasPanRecognizer: UIPanGestureRecognizer?
        private var pointerDragState: HorizontalPrimaryDragState?

        private var isPinching = false
        private var isPanning = false
        /// True between Pencil touch-down and lift. Hover reports `.ended` as
        /// soon as the tip lands, so this distinguishes "tip is on the glass"
        /// from "Pencil moved away" — only the latter should clear the cursor.
        private var isPencilDown = false
        /// Two or more fingers are down. See
        /// `KeyableTouchView.onMultiTouchSequenceChange` for why this exists and
        /// why it outlives the second finger.
        private var isMultiTouchSequenceActive = false
        private var lastPanTranslation = CGPoint.zero
        private var lastScale: CGFloat = 1
        private var lastCentroid = CGPoint.zero
        private var lastTouchCount = 0
        private var hasReference = false
        private var lastTapTime = Date.distantPast
        private var lastTapLocation = CGPoint.zero
        private var menuPreviewLocation = CGPoint.zero
        private var previewPlaceholder: UIView?
        private var contextMenuVisible = false

        init(
            onTap: @escaping (CGPoint, CGSize, HorizontalCanvasInputModifiers, Int) -> Void,
            contextMenuTargets: @escaping (CGPoint) -> [HorizontalSelectionTargetItem],
            contextMenuEntries: @escaping (HorizontalSelectableRef) -> [HorizontalTargetItemMenuEntry],
            onContextMenuCommand: @escaping (HorizontalSelectableRef, HorizontalCanvasCommand) -> Void,
            onContextMenuTargetAction: @escaping (HorizontalSelectionTargetItem) -> Void,
            onHover: @escaping (CGPoint?) -> Void,
            onPan: @escaping (CGSize) -> Void,
            onPinch: @escaping (CGFloat, CGPoint, CGSize, CGSize) -> Void,
            onGestureEnd: @escaping () -> Void
        ) {
            self.onTap = onTap
            self.contextMenuTargets = contextMenuTargets
            self.contextMenuEntries = contextMenuEntries
            self.onContextMenuCommand = onContextMenuCommand
            self.onContextMenuTargetAction = onContextMenuTargetAction
            self.onHover = onHover
            self.onPan = onPan
            self.onPinch = onPinch
            self.onGestureEnd = onGestureEnd
        }

        // Single tap (1 touch); double-tap detected by timing so a single tap fires
        // immediately instead of waiting for a double-tap recognizer to fail.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            // Don't let a tap select beneath an opening/visible context menu (the
            // tap and the menu's long-press are otherwise only timing-separated).
            guard let view = recognizer.view, recognizer.state == .ended, !contextMenuVisible else { return }
            // Re-acquire key focus (a focused text field may have stolen it).
            view.becomeFirstResponder()
            let location = recognizer.location(in: view)
            let now = Date()
            let isDouble = now.timeIntervalSince(lastTapTime) < 0.35
                && abs(location.x - lastTapLocation.x) < 16
                && abs(location.y - lastTapLocation.y) < 16
            lastTapTime = isDouble ? .distantPast : now
            lastTapLocation = location
            onTap(location, view.bounds.size, modifiers(from: recognizer.modifierFlags), isDouble ? 2 : 1)
        }

        // MARK: - Native context menu (UIContextMenuInteractionDelegate)

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let targets = contextMenuTargets(location)
            guard !targets.isEmpty else { return nil }
            menuPreviewLocation = location
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildMenu(for: targets)
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            contextMenuVisible = true
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            if let animator {
                animator.addCompletion { [weak self] in self?.contextMenuVisible = false }
            } else {
                contextMenuVisible = false
            }
        }

        // Suppress the default "lift" preview (the gesture host is a full-screen
        // clear view; a snapshot of it on a platter would look odd) by targeting a
        // tiny clear placeholder at the press point — just the menu, no preview.
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            clearPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            clearPreview(for: interaction)
        }

        private func clearPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            let placeholder = previewPlaceholder ?? {
                let placeholder = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                placeholder.backgroundColor = .clear
                previewPlaceholder = placeholder
                return placeholder
            }()
            if placeholder.superview !== view {
                view.addSubview(placeholder)
            }
            placeholder.center = menuPreviewLocation
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            return UITargetedPreview(view: placeholder, parameters: parameters)
        }

        private func buildMenu(for targets: [HorizontalSelectionTargetItem]) -> UIMenu {
            // Exactly one object with its own action list → show those actions
            // directly (no "ItemName ▸" nesting), mirroring the macOS NSMenu.
            if targets.count == 1, let target = targets.first, let ref = target.ref {
                let entries = contextMenuEntries(ref)
                if !entries.isEmpty {
                    return UIMenu(title: target.menuTitle, children: menuElements(for: entries, ref: ref, target: target))
                }
            }
            // Otherwise one entry per candidate; candidates with actions nest into a
            // submenu, the rest are direct select actions.
            let children: [UIMenuElement] = targets.map { target in
                guard let ref = target.ref else {
                    return targetAction(target)
                }
                let entries = contextMenuEntries(ref)
                guard !entries.isEmpty else {
                    return targetAction(target)
                }
                return UIMenu(title: target.menuTitle, children: menuElements(for: entries, ref: ref, target: target))
            }
            return UIMenu(title: "", children: children)
        }

        /// A plain action running the candidate's default action (select/copy/open).
        private func targetAction(_ target: HorizontalSelectionTargetItem) -> UIAction {
            UIAction(title: target.menuTitle) { [weak self] _ in
                self?.onContextMenuTargetAction(target)
            }
        }

        /// Translates entries to `UIMenuElement`s. `UIMenu` has no standalone
        /// separator, so separator-delimited runs become inline `UIMenu` sections.
        private func menuElements(
            for entries: [HorizontalTargetItemMenuEntry],
            ref: HorizontalSelectableRef,
            target: HorizontalSelectionTargetItem
        ) -> [UIMenuElement] {
            var sections = [[UIMenuElement]]()
            var current = [UIMenuElement]()
            for entry in entries {
                switch entry {
                case .separator:
                    if !current.isEmpty {
                        sections.append(current)
                        current = []
                    }
                case .todo(let title):
                    let action = UIAction(title: title) { _ in }
                    action.attributes = [.disabled]
                    current.append(action)
                case .select(let title):
                    current.append(UIAction(title: title) { [weak self] _ in self?.onContextMenuTargetAction(target) })
                case .command(let title, let command):
                    current.append(UIAction(title: title) { [weak self] _ in self?.onContextMenuCommand(ref, command) })
                case .submenu(let title, let children):
                    current.append(UIMenu(title: title, children: menuElements(for: children, ref: ref, target: target)))
                }
            }
            if !current.isEmpty {
                sections.append(current)
            }
            if sections.count <= 1 {
                return sections.first ?? []
            }
            return sections.map { UIMenu(title: "", options: .displayInline, children: $0) }
        }

        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            // While panning/zooming, suppress the hover cursor: a non-nil cursor
            // makes the canvas re-run the snap-target search and rebuild the cursor +
            // coordinate-readout overlays on EVERY gesture frame. Direct touch has no
            // hover, which is exactly why finger pan/zoom stays smooth while the
            // trackpad (whose pointer keeps the cursor alive) stalled.
            guard !isPanning, !isPinching, let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                onHover(recognizer.location(in: view))
            default:
                // Hover ENDS the moment the Pencil tip touches down, so clearing
                // here would drop the cursor — and with it the route preview —
                // at the exact instant of a tap. While the tip is down it is
                // still pointing at something, and `reportPencilCursor` owns the
                // cursor; only a genuine hover-away clears it.
                if !isPencilDown {
                    onHover(nil)
                }
            }
        }

        /// Apple Pencil contact → the same cursor hover drives, so the router
        /// preview follows the tip while it's down (hover stops at contact, and
        /// hardware without Pencil hover never reports it at all).
        ///
        /// The cursor is deliberately never cleared on lift: that matches a
        /// macOS pointer, which stays put after a click, and keeps the
        /// in-progress route preview on screen between taps. A hover-capable
        /// Pencil resumes updating it immediately; a finger pan clears it via
        /// `handlePan`.
        func reportPencilCursor(_ location: CGPoint) {
            isPencilDown = true
            guard !isPanning, !isPinching else { return }
            onHover(location)
        }

        func endPencilTouch() {
            isPencilDown = false
        }

        func setMultiTouchSequenceActive(_ active: Bool) {
            isMultiTouchSequenceActive = active
        }

        // One/two-finger + trackpad pan. While a pinch owns the gesture the pinch
        // handler already pans via its centroid, so this cedes to it (avoiding
        // double-pan) but keeps its reference aligned to the current translation so
        // a one-finger pan can resume afterwards without a positional jump.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            // Tracked before the pinch guard so it always clears at gesture end.
            isPanning = recognizer.state == .began || recognizer.state == .changed
            // Settle the viewport at gesture end BEFORE the suppression guard
            // below. A pan that ended while `isMultiTouchSequenceActive` was
            // still set (the view holds it until the LAST finger lifts, and the
            // recognizer's .ended arrives before the view's touchesEnded) used
            // to skip `onGestureEnd`, leaving viewport-derived chrome —
            // highlights, selection boxes — offset from the settled canvas
            // until the 600 ms debounce caught up.
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                lastPanTranslation = .zero
                // Mirror handlePinch: settle the viewport into the @Binding at
                // gesture end so viewport-derived chrome repositions immediately
                // rather than after the 600 ms debounce.
                onGestureEnd()
                return
            }
            // `isMultiTouchSequenceActive` catches the window `isPinching` can't:
            // a second finger re-bases this recognizer's translation onto the
            // two-finger centroid immediately, whereas the pinch's `.began` (and
            // so `isPinching`) only arrives afterwards. Both keep the reference
            // aligned to the current translation while suppressed, so whatever
            // resumes panning does so without a jump.
            guard !isPinching, !isMultiTouchSequenceActive else {
                lastPanTranslation = recognizer.translation(in: view)
                return
            }
            switch recognizer.state {
            case .began:
                lastPanTranslation = .zero
                onHover(nil) // hide the cursor for the duration of the pan
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = CGSize(
                    width: translation.x - lastPanTranslation.x,
                    height: translation.y - lastPanTranslation.y
                )
                lastPanTranslation = translation
                onPan(delta)
            default:
                lastPanTranslation = .zero
            }
        }

        /// Trackpad/mouse pointer click-drag: drives the shared primary-drag
        /// state machine (rubber-band selection, or drag-to-move when the press
        /// lands on the selection) instead of panning the canvas. Two-finger
        /// trackpad scroll still pans — it reaches the canvas pan recognizer as
        /// UIScrollEvents, which the pointer-touch refusal below doesn't block.
        @objc func handlePointerDrag(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let size = view.bounds.size
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                // The recognizer begins only after its movement hysteresis;
                // reconstruct the press point so the drag (and any drag-to-move
                // anchor) starts where the button actually went down.
                let translation = recognizer.translation(in: view)
                let origin = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                var state = HorizontalPrimaryDragState(
                    start: origin,
                    current: origin,
                    points: [origin],
                    action: HorizontalCanvasInputCore.clickAction(
                        modifiers: modifiers(from: recognizer.modifierFlags),
                        modifierAction: selectionModifierAction
                    ),
                    clickCount: 1
                )
                state.extend(to: location, tool: selectionTool)
                pointerDragState = state
                onPrimaryDragChanged(state.start, state.current, state.points, size, state.action, state.isActive)
            case .changed:
                guard pointerDragState != nil else { return }
                pointerDragState?.extend(to: location, tool: selectionTool)
                if let state = pointerDragState {
                    onPrimaryDragChanged(state.start, state.current, state.points, size, state.action, state.isActive)
                }
            case .ended:
                guard var state = pointerDragState else { return }
                pointerDragState = nil
                switch state.resolve(at: location) {
                case let .drag(start, current, points, action):
                    onPrimaryDragEnded(start, current, points, size, action, true)
                case let .click(point, clickCount, _):
                    onTap(point, size, modifiers(from: recognizer.modifierFlags), clickCount)
                }
            case .cancelled, .failed:
                if let state = pointerDragState {
                    onPrimaryDragEnded(state.start, state.current, state.points, size, state.action, false)
                }
                pointerDragState = nil
            default:
                break
            }
        }

        // Combined pan+zoom with graceful finger-loss.
        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                isPinching = true
                lastScale = recognizer.scale
                lastCentroid = recognizer.location(in: view)
                lastTouchCount = recognizer.numberOfTouches
                hasReference = true
                onHover(nil) // hide the cursor for the duration of the zoom
            case .changed:
                let centroid = recognizer.location(in: view)
                let touchCount = recognizer.numberOfTouches
                // A finger was added or lifted → the centroid jumps. Re-anchor with
                // no pan/zoom this frame so the transition is seamless.
                if !hasReference || touchCount != lastTouchCount {
                    lastCentroid = centroid
                    lastScale = recognizer.scale
                    lastTouchCount = touchCount
                    hasReference = true
                    return
                }
                // One direct touch = the user lifted a finger mid-pinch → pan only.
                // Zero touches = an indirect trackpad pinch → zoom (centroid steady).
                let incrementalScale = touchCount == 1 ? 1 : recognizer.scale / lastScale
                let panDelta = CGSize(
                    width: centroid.x - lastCentroid.x,
                    height: centroid.y - lastCentroid.y
                )
                onPinch(incrementalScale, centroid, panDelta, view.bounds.size)
                lastScale = recognizer.scale
                lastCentroid = centroid
            default:
                isPinching = false
                hasReference = false
                lastScale = 1
                lastTouchCount = 0
                // Settle the viewport into the @Binding now (vs. after the 600 ms
                // debounce) so viewport-derived chrome repositions immediately. Pan
                // may still be in flight (a finger lifted mid-pinch); handlePan's own
                // end fires its flush, and a redundant flush is cheap + idempotent.
                if recognizer.state == .ended || recognizer.state == .cancelled {
                    onGestureEnd()
                }
            }
        }

        private func modifiers(from flags: UIKeyModifierFlags) -> HorizontalCanvasInputModifiers {
            HorizontalCanvasInputModifiers(
                command: flags.contains(.command),
                option: flags.contains(.alternate),
                control: flags.contains(.control),
                shift: flags.contains(.shift)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // A trackpad/mouse pointer click-drag rubber-bands (its own recognizer)
        // instead of panning. Refusing the pointer TOUCH here leaves two-finger
        // trackpad scrolling intact: scroll arrives as UIScrollEvents through
        // `allowedScrollTypesMask`, not through this touch path.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer === canvasPanRecognizer, touch.type == .indirectPointer {
                return false
            }
            return true
        }
    }
}
#endif

#if canImport(AppKit)
private struct TrackpadCanvasMonitor: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint, CGSize) -> Void
    var onZoomStep: (CGFloat, CGPoint, CGSize) -> Void
    var selectionTool: HorizontalSelectionTool
    var selectionModifierAction: HorizontalSelectionModifierAction
    var onPrimaryClick: (CGPoint, CGSize, CGPoint, NSView, HorizontalSelectionClickAction, Int) -> Void
    var onPrimaryDragChanged: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void
    var onPrimaryDragEnded: (CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void
    var onSecondaryClick: (CGPoint, CGSize, CGPoint, NSView) -> Void
    var onCursorLocationChange: (CGPoint?) -> Void
    var onGridDivisorChange: (Int) -> Void
    var onModifiersChanged: (HorizontalCanvasInputModifiers) -> Void
    var onMoveSelectionByGrid: (HorizontalPoint, Bool) -> Void
    var handlesSelectionDeletion: Bool
    var undoManager: UndoManager?
    var onCommand: (HorizontalCanvasCommand) -> Void
    var handlesInteractionKeys: Bool
    var samplesCursorContinuously: Bool
    var supportsTrackVias: Bool
    var hasKeyboardFocus: Bool
    var onRequestKeyboardFocus: () -> Void
    var ignoresCanvasMouseEvents: Bool
    var mouseExclusionInsets: EdgeInsets

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.onZoomStep = onZoomStep
        view.selectionTool = selectionTool
        view.selectionModifierAction = selectionModifierAction
        view.onPrimaryClick = onPrimaryClick
        view.onPrimaryDragChanged = onPrimaryDragChanged
        view.onPrimaryDragEnded = onPrimaryDragEnded
        view.onSecondaryClick = onSecondaryClick
        view.onCursorLocationChange = onCursorLocationChange
        view.onGridDivisorChange = onGridDivisorChange
        view.onModifiersChanged = onModifiersChanged
        view.onMoveSelectionByGrid = onMoveSelectionByGrid
        view.handlesSelectionDeletion = handlesSelectionDeletion
        view.canvasUndoManager = undoManager
        view.onCommand = onCommand
        view.handlesInteractionKeys = handlesInteractionKeys
        view.samplesCursorContinuously = samplesCursorContinuously
        view.supportsTrackVias = supportsTrackVias
        view.hasKeyboardFocus = hasKeyboardFocus
        view.onRequestKeyboardFocus = onRequestKeyboardFocus
        view.ignoresCanvasMouseEvents = ignoresCanvasMouseEvents
        view.mouseExclusionInsets = mouseExclusionInsets
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
        nsView.onZoomStep = onZoomStep
        nsView.selectionTool = selectionTool
        nsView.selectionModifierAction = selectionModifierAction
        nsView.onPrimaryClick = onPrimaryClick
        nsView.onPrimaryDragChanged = onPrimaryDragChanged
        nsView.onPrimaryDragEnded = onPrimaryDragEnded
        nsView.onSecondaryClick = onSecondaryClick
        nsView.onCursorLocationChange = onCursorLocationChange
        nsView.onGridDivisorChange = onGridDivisorChange
        nsView.onModifiersChanged = onModifiersChanged
        nsView.onMoveSelectionByGrid = onMoveSelectionByGrid
        nsView.handlesSelectionDeletion = handlesSelectionDeletion
        nsView.canvasUndoManager = undoManager
        nsView.onCommand = onCommand
        nsView.handlesInteractionKeys = handlesInteractionKeys
        nsView.samplesCursorContinuously = samplesCursorContinuously
        nsView.supportsTrackVias = supportsTrackVias
        nsView.hasKeyboardFocus = hasKeyboardFocus
        nsView.onRequestKeyboardFocus = onRequestKeyboardFocus
        nsView.ignoresCanvasMouseEvents = ignoresCanvasMouseEvents
        nsView.mouseExclusionInsets = mouseExclusionInsets
    }

    final class MonitorView: NSView {
        var onPan: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat, CGPoint, CGSize) -> Void)?
        var onZoomStep: ((CGFloat, CGPoint, CGSize) -> Void)?
        var selectionTool = HorizontalSelectionTool.box
        var selectionModifierAction = HorizontalSelectionModifierAction.toggle
        var onPrimaryClick: ((CGPoint, CGSize, CGPoint, NSView, HorizontalSelectionClickAction, Int) -> Void)?
        var onPrimaryDragChanged: ((CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void)?
        var onPrimaryDragEnded: ((CGPoint, CGPoint, [CGPoint], CGSize, HorizontalSelectionClickAction, Bool) -> Void)?
        var onSecondaryClick: ((CGPoint, CGSize, CGPoint, NSView) -> Void)?
        var onCursorLocationChange: ((CGPoint?) -> Void)?
        var onGridDivisorChange: ((Int) -> Void)?
        var onModifiersChanged: ((HorizontalCanvasInputModifiers) -> Void)?
        var onMoveSelectionByGrid: ((HorizontalPoint, Bool) -> Void)?
        var handlesSelectionDeletion = false
        var canvasUndoManager: UndoManager?
        var onCommand: ((HorizontalCanvasCommand) -> Void)?
        var handlesInteractionKeys = false
        var supportsTrackVias = false
        var hasKeyboardFocus = true
        var onRequestKeyboardFocus: (() -> Void)?
        var samplesCursorContinuously = false {
            didSet {
                configureCursorSampler()
            }
        }
        var ignoresCanvasMouseEvents = false
        var mouseExclusionInsets = EdgeInsets()
        private var monitor: Any?
        private var cursorSampler: Timer?
        private var lastSampledCanvasLocation: CGPoint?
        private var pointerInside = false
        private var primaryDragState: HorizontalPrimaryDragState?

        override var acceptsFirstResponder: Bool {
            true
        }

        override var undoManager: UndoManager? {
            canvasUndoManager ?? super.undoManager
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureMonitor()
            configureCursorSampler()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                removeMonitor()
                removeCursorSampler()
            }
        }

        private func configureMonitor() {
            removeMonitor()
            guard let window else {
                return
            }

            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .flagsChanged, .keyDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func configureCursorSampler() {
            guard samplesCursorContinuously, window != nil else {
                removeCursorSampler()
                return
            }
            guard cursorSampler == nil else {
                return
            }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else {
                    return
                }
                MainActor.assumeIsolated {
                    self.sampleCursorLocation()
                }
            }
            cursorSampler = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func removeCursorSampler() {
            cursorSampler?.invalidate()
            cursorSampler = nil
            lastSampledCanvasLocation = nil
        }

        /// True while the window's edge is being dragged.
        ///
        /// Cursor tracking stands down for the duration, and that is the whole
        /// fix for sluggish resizing. The canvas bounds change every frame of a
        /// resize, so a perfectly stationary pointer maps to a NEW canvas
        /// coordinate on every tick of the 60 Hz sampler — which re-runs
        /// snapping and hit-testing and writes SwiftUI state on top of the
        /// layout pass AppKit is already doing, sixty times a second, for a
        /// pointer that is on the window frame and not pointing at the board at
        /// all.
        ///
        /// This is the macOS counterpart of the `isPanning` / `isPinching`
        /// guards the iOS path already had; resizing simply had no equivalent.
        private var isLiveResizing: Bool {
            inLiveResize || (window?.inLiveResize ?? false)
        }

        private func sampleCursorLocation() {
            guard samplesCursorContinuously,
                  let window,
                  !ignoresCanvasMouseEvents,
                  !isLiveResizing else {
                return
            }

            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard bounds.contains(location), !isExcludedMouseLocation(location) else {
                if pointerInside || lastSampledCanvasLocation != nil {
                    pointerInside = false
                    lastSampledCanvasLocation = nil
                    onCursorLocationChange?(nil)
                }
                return
            }

            pointerInside = true
            let canvasLocation = CGPoint(x: location.x, y: bounds.height - location.y)
            guard lastSampledCanvasLocation != canvasLocation else {
                return
            }
            lastSampledCanvasLocation = canvasLocation
            let divisor = NSEvent.modifierFlags.contains(.option) ? 10 : 1
            onGridDivisorChange?(divisor)
            onCursorLocationChange?(canvasLocation)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else {
                return event
            }

            if event.type == .keyDown {
                // Multiple panes are visible at once on macOS, each with its own key
                // monitor. Route canvas keyboard commands ONLY to the keyboard-focused
                // pane (set by clicking a pane) so e.g. ⌘A doesn't select in every
                // pane. An in-progress interaction still handles its own keys, and the
                // first-responder check covers the brief window after a right-click
                // before the focus state round-trips back.
                guard hasKeyboardFocus
                    || window.firstResponder === self
                    || (handlesInteractionKeys && isInteractionKey(event)) else {
                    return event
                }
                return handleKeyDown(event)
            }

            // Same reasoning as `isLiveResizing`: a drag on the window's edge is
            // not a gesture on the canvas, and reporting it costs a hit-test and
            // a state write per event while AppKit is already laying out.
            if isLiveResizing, event.type != .keyDown {
                return event
            }

            let location = convert(event.locationInWindow, from: nil)
            let canvasLocation = CGPoint(x: location.x, y: bounds.height - location.y)
            let isPrimaryDragEvent = event.type == .leftMouseDragged || event.type == .leftMouseUp
            guard bounds.contains(location) || (primaryDragState != nil && isPrimaryDragEvent) else {
                pointerInside = false
                if event.type == .mouseMoved || event.type == .leftMouseDragged {
                    onCursorLocationChange?(nil)
                }
                return event
            }

            guard !isExcludedMouseLocation(location) else {
                pointerInside = false
                if event.type == .mouseMoved || event.type == .leftMouseDragged {
                    onCursorLocationChange?(nil)
                }
                return event
            }

            pointerInside = bounds.contains(location)
            updateGridDivisor(from: event)
            // Feed the modifier side-channel so the SwiftUI select gestures know
            // which click action (add/toggle/remove) to apply.
            onModifiersChanged?(inputModifiers(from: event.modifierFlags))
            if ignoresCanvasMouseEvents {
                return event
            }
            // Mouse selection (tap + drag-select) is handled by the SwiftUI
            // HorizontalCanvasInputView; report the cursor and pass the event through.
            if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
                // A click within this pane gives it keyboard focus (after the
                // ignoresCanvasMouseEvents guard above, so sidebar clicks don't steal it).
                if event.type == .leftMouseDown {
                    onRequestKeyboardFocus?()
                }
                lastSampledCanvasLocation = canvasLocation
                onCursorLocationChange?(canvasLocation)
                return event
            }
            if event.type == .rightMouseDown {
                onRequestKeyboardFocus?()
                window.makeFirstResponder(self)
                onSecondaryClick?(canvasLocation, bounds.size, location, self)
                return nil
            }

            if event.type == .mouseMoved || event.type == .leftMouseDragged || event.type == .flagsChanged {
                lastSampledCanvasLocation = canvasLocation
                onCursorLocationChange?(canvasLocation)
                return event
            }

            // Pinch zoom is handled by the SwiftUI MagnifyGesture.
            if event.type == .magnify {
                return event
            }

            if event.hasPreciseScrollingDeltas {
                let delta = CGSize(
                    width: event.scrollingDeltaX,
                    height: event.scrollingDeltaY
                )
                guard delta != .zero else {
                    return nil
                }

                onPan?(delta)
            } else {
                let step = event.scrollingDeltaY
                guard step != 0 else {
                    return nil
                }

                onZoomStep?(step, canvasLocation, bounds.size)
            }

            return nil
        }

        private func isExcludedMouseLocation(_ location: CGPoint) -> Bool {
            guard primaryDragState == nil else {
                return false
            }
            if mouseExclusionInsets.top > 0,
               location.y >= bounds.height - mouseExclusionInsets.top {
                return true
            }
            if mouseExclusionInsets.leading > 0,
               location.x <= mouseExclusionInsets.leading {
                return true
            }
            if mouseExclusionInsets.trailing > 0,
               location.x >= bounds.width - mouseExclusionInsets.trailing {
                return true
            }
            if mouseExclusionInsets.bottom > 0,
               location.y <= mouseExclusionInsets.bottom {
                return true
            }
            return false
        }

        private func updatePrimaryDrag(to canvasLocation: CGPoint) {
            guard var state = primaryDragState else {
                return
            }
            state.extend(to: canvasLocation, tool: selectionTool)
            primaryDragState = state
            onPrimaryDragChanged?(state.start, state.current, state.points, bounds.size, state.action, state.isActive)
        }

        private func finishPrimaryDrag(at canvasLocation: CGPoint) {
            guard var state = primaryDragState else {
                return
            }
            let resolution = state.resolve(at: canvasLocation)
            primaryDragState = nil

            switch resolution {
            case let .drag(start, current, points, action):
                onPrimaryDragEnded?(start, current, points, bounds.size, action, true)
            case let .click(point, clickCount, action):
                onPrimaryClick?(point, bounds.size, CGPoint(x: point.x, y: bounds.height - point.y), self, action, clickCount)
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            // While a text field is focused, let it keep the standard editing
            // shortcuts (⌘A/⌘C/⌘V/⌘X/⌘D) instead of the canvas commands.
            if isTextInputActive, isSelectAllCommand(event) || isClipboardCommand(event) {
                return event
            }

            if handlesInteractionKeys && isInteractionKey(event) {
                return handleInteractionKeyDown(event)
            }

            guard !isTextInputActive else {
                return event
            }

            let result = handleInteractionKeyDown(event)
            if result != nil {
                logCandidateBeep("canvas keyDown fell through", event: event)
            }
            return result
        }

        private func handleInteractionKeyDown(_ event: NSEvent) -> NSEvent? {
            if isEscapeKey(event) {
                onCommand?(.cancelInteraction)
                return nil
            }

            if isReturnKey(event) {
                onCommand?(.commitInteraction)
                return nil
            }

            if let arrowDirection = arrowDirection(from: event) {
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard modifiers.isEmpty || modifiers == .option else {
                    return event
                }
                onMoveSelectionByGrid?(arrowDirection, modifiers == .option)
                return nil
            }

            if isDeleteKey(event) {
                onCommand?(.deleteSelection)
                return nil
            }

            if let command = canvasCommand(from: event) {
                onCommand?(command)
                return nil
            }

            return event
        }

        private func isInteractionKey(_ event: NSEvent) -> Bool {
            isEscapeKey(event) || isReturnKey(event) || isDeleteKey(event)
                || arrowDirection(from: event) != nil
                || canvasCommand(from: event) != nil
        }

        private func logCandidateBeep(_ reason: String, event: NSEvent) {
            guard isCanvasCommandKey(event) else {
                return
            }

            let characters = event.charactersIgnoringModifiers ?? ""
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let firstResponderDescription = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            print(
                "Horizontal candidate beep: \(reason); key=\(characters.debugDescription) keyCode=\(event.keyCode) modifiers=\(modifiers.rawValue) pointerInside=\(pointerInside) handlesInteractionKeys=\(handlesInteractionKeys) firstResponder=\(firstResponderDescription)"
            )
        }

        private func isCanvasCommandKey(_ event: NSEvent) -> Bool {
            canvasCommand(from: event) != nil
        }

        // Adapters: build the platform-neutral key/modifier types from an NSEvent
        // so the shared `HorizontalCanvasInputCore` decoders do the actual work.
        private func inputModifiers(from flags: NSEvent.ModifierFlags) -> HorizontalCanvasInputModifiers {
            HorizontalCanvasInputModifiers(
                command: flags.contains(.command),
                option: flags.contains(.option),
                control: flags.contains(.control),
                shift: flags.contains(.shift)
            )
        }

        private func keyEvent(from event: NSEvent) -> HorizontalCanvasKeyEvent {
            HorizontalCanvasKeyEvent(
                characters: event.charactersIgnoringModifiers,
                keyCode: event.keyCode,
                key: arrowKeyEquivalent(for: event.specialKey),
                modifiers: inputModifiers(from: event.modifierFlags)
            )
        }

        // Preserve the former `event.specialKey` arrow fallback (keyCode 123–126
        // covers the common case) by mapping it to a neutral KeyEquivalent.
        private func arrowKeyEquivalent(for specialKey: NSEvent.SpecialKey?) -> KeyEquivalent? {
            switch specialKey {
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            default: return nil
            }
        }

        private func isCanvasCommandKeyAllowedWithoutCanvasFocus(_ event: NSEvent) -> Bool {
            guard let command = canvasCommand(from: event) else {
                return false
            }
            return HorizontalCanvasInputCore.allowedWithoutCanvasFocus(command)
        }

        private func canvasCommand(from event: NSEvent) -> HorizontalCanvasCommand? {
            HorizontalCanvasInputCore.command(keyEvent(from: event), supportsTrackVias: supportsTrackVias)
        }

        private func isSelectAllCommand(_ event: NSEvent) -> Bool {
            HorizontalCanvasInputCore.isSelectAllCommand(keyEvent(from: event))
        }

        private func isClipboardCommand(_ event: NSEvent) -> Bool {
            HorizontalCanvasInputCore.isClipboardCommand(keyEvent(from: event))
        }

        private func isEscapeKey(_ event: NSEvent) -> Bool {
            HorizontalCanvasInputCore.isEscape(keyEvent(from: event))
        }

        private func isReturnKey(_ event: NSEvent) -> Bool {
            HorizontalCanvasInputCore.isReturn(keyEvent(from: event))
        }

        private func isDeleteKey(_ event: NSEvent) -> Bool {
            HorizontalCanvasInputCore.isDelete(keyEvent(from: event))
        }

        private func arrowDirection(from event: NSEvent) -> HorizontalPoint? {
            HorizontalCanvasInputCore.arrowDirection(keyEvent(from: event))
        }

        private var isTextInputActive: Bool {
            guard let firstResponder = window?.firstResponder else {
                return false
            }
            return firstResponder is NSTextView || firstResponder is NSTextField
        }

        private func updateGridDivisor(from event: NSEvent) {
            // Matches default Appearance::GridFineModifier::ALT.
            onGridDivisorChange?(HorizontalCanvasInputCore.gridDivisor(modifiers: inputModifiers(from: event.modifierFlags)))
        }

        private func selectionClickAction(from event: NSEvent) -> HorizontalSelectionClickAction {
            HorizontalCanvasInputCore.clickAction(
                modifiers: inputModifiers(from: event.modifierFlags),
                modifierAction: selectionModifierAction
            )
        }
    }
}
#endif
