import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// A harvested board object held in the in-app copy buffer. Carries the full
/// object so Paste/Duplicate can append a fresh-id, translated clone. Scoped to
/// standalone copper/graphics — packages, planes (rule-generated) and
/// package-owned geometry are intentionally excluded.
private enum BoardClipboardItem {
    case track(HorizontalSegment)
    case netTie(HorizontalSegment)
    case line(HorizontalSegment)
    case arc(HorizontalArc)
    case via(HorizontalMarker, [HorizontalHole])
    case text(HorizontalText)
    case hole(HorizontalHole)
    case polygon(HorizontalPolygon)
}

/// Live paste-placement interaction: the harvested clipboard objects are shown
/// as a ghost following the cursor (`cursor − anchor` offset) until the user
/// clicks / presses Return to commit, or Esc to cancel. The ghost is render-only
/// (nothing is appended to the board until commit), so cancel is a no-op.
private struct PastePlacementState {
    var items: [BoardClipboardItem]
    /// The grab point — the cursor position at copy time. Paste offset is
    /// `cursor − anchor`, so the geometry keeps its offset relative to the cursor.
    var anchor: HorizontalPoint
    /// Current cursor position (updated as the pointer moves).
    var cursor: HorizontalPoint
}

struct BoardCanvasView: View {
    // The in-canvas selection popover stays off on both platforms: macOS uses its
    // right inspector sidebar and iOS uses the right-side slide-over inspector
    // (HorizontalInspectorSidebar) instead.
    static let showsInCanvasSelectionInspector = false
    private static let quarterTurnAngle = -16_384
    private static let noNetClassChoiceID = "none"
    private static let boardBodyMetalCompositeGroup = 1
    private static let boardLayerMetalCompositeGroupOffset = 1_000_000
    // Generated overlay-name labels (pad names, track/net-tie net names) render as
    // stroked simplex-font polylines. Baking their alpha into the vertex color
    // makes overlapping stroke segments (letter joints, crossings) compound alpha
    // and show darker seams. Instead they go into this one dedicated composite
    // group, drawn OPAQUE (overlap = opaque-over-opaque, no compounding) and
    // composited at `textOverlayMetalCompositeOpacity` (1.0). Via
    // `metalOverlayLayerOpacityExemptGroups` the group is also exempt from the
    // copper layer-opacity slider, so the labels stay fully readable no matter how
    // dim copper gets — matching the always-on TEXT_OVERLAY layer. The group
    // is distinct from group 0 (main pass), the board-body group, and every
    // `boardLayerMetalCompositeGroupOffset + layer` group (layers max out near
    // 10_000, so `1_000_000 + layer` never reaches 2_000_000).
    private static let textOverlayMetalCompositeGroup = 2_000_000
    private static let textOverlayMetalCompositeOpacity: Float = 1.0
    // Drill-hole fills/outlines. Previously these had no composite group (→ group
    // 0), so they drew in the MAIN pass AFTER every composite texture — including
    // the overlay-label group — and their opaque background-punch fill cut through
    // pad/via/track net-name labels. Giving them their own composite group that
    // sorts BETWEEN copper (`boardLayerMetalCompositeGroupOffset + layer`, layers
    // max near 10_000 so always < 1_900_000) and the label group (2_000_000) keeps
    // them drawn above copper (holes still punch copper) but below the labels
    // (names no longer cut). The group is layer-opacity EXEMPT (see
    // metalOverlayLayerOpacityExemptGroups) so the punch stays full-opacity exactly
    // as the old group-0 main-pass draw did, no matter how dim the copper slider
    // makes the layers.
    private static let holesMetalCompositeGroup = 1_900_000
    private static let emitsGeneratedBoardLabelsInMetal = true
    // Zoom-out cull for the GENERATED overlay labels (pad names, via net names,
    // track/net-tie net names): once a label's glyphs shrink below this many
    // points of cap height they are illegible clutter, so they are dropped
    // entirely. `HorizontalText.size` IS the world-space line height (the simplex
    // renderer strokes at `size / 21` against a 21-unit em), so
    // `transform.length(text.size)` is the on-screen glyph height in points.
    //
    // Horizon does the same thing per-primitive on the GPU: `set_lod_size()`
    // (render.cpp — `min(pad_width, pad_height)` for pads, track `width` for
    // tracks, via `size` for vias) feeds `triangle-glyph-geometry.glsl`, which
    // hides a glyph below 5px of FEATURE size and ramps its alpha up to 15px.
    // We key on the glyph rather than the feature (it states legibility
    // directly, and works the same for one- and two-row labels), and we cull
    // hard instead of fading: these labels are stroked polylines drawn opaque in
    // `textOverlayMetalCompositeGroup` precisely so overlapping strokes don't
    // compound alpha into dark seams, so a per-label fade would reintroduce
    // that. 4pt sits inside fade band (its hide point lands near
    // 2-4px of glyph, full opacity near 5-11px).
    //
    // Real board text (`board.texts`) and package text are NOT culled — they are
    // board content, not generated overlays, and Horizon likewise never calls
    // set_lod_size for them.
    private static let minimumLegibleLabelPointSize: Double = 4
    /// Steps per octave used to quantize the cull threshold. Live zoom then
    /// re-concatenates only when it crosses a step (~19% of scale) instead of
    /// on every frame.
    private static let labelLODStepsPerOctave: Double = 4

    private struct MoveState {
        var startPoint: HorizontalPoint
        var lastPoint: HorizontalPoint
        var originalBoard: HorizontalBoard
        var tracksCursor: Bool
        var snapTargets: [HorizontalPoint]?
        var residentMovePlan: BoardResidentMovePlan
        /// Set when this move is the place-the-text-then-edit flow (macOS "Add
        /// Text"). On commit, the canvas opens the inline text editor for this
        /// ref instead of registering a "Move" undo — the placement is one
        /// undoable step ("Add Text"), finalized only when real content is typed.
        var editTextRefOnCommit: String? = nil
    }

    #if os(macOS)
    /// In-flight inline text edit (macOS "Add Text"): a placeholder `HorizontalText`
    /// has been placed and anchored, and a popover lets the user type its content
    /// with a LIVE canvas re-render on each keystroke. `preBoard` is the board
    /// snapshot from *before* the text was added, so a cancelled placement (empty
    /// or untouched `"Text"`) reverts to a true no-op and the single "Add Text"
    /// undo entry is registered only when real content commits.
    private struct EditTextState {
        let ref: String
        let worldPosition: HorizontalPoint
        var content: String
        let preBoard: HorizontalBoard
        /// False while the placeholder hovers (popover hidden); flipped true by
        /// beginEditingPlacedText after the anchoring click, so the popover only
        /// appears — pointing at the placed text — once the user has clicked.
        var isEditing: Bool = false
        /// True for the "Add Text" flow (placeholder placed by placeText), false
        /// when re-editing an already-placed text. Drives the finalize/undo name
        /// ("Add Text" vs "Edit Text") and whether a no-op cancel clears the
        /// selection (a fresh placement does; an existing edit keeps it).
        var isNewPlacement: Bool = true
        /// The content the popover opened with. A finalize whose content equals
        /// this is a no-op — covers "left the placeholder as Text" (new) and "no
        /// change" (existing) with one comparison.
        var originalContent: String
    }
    #endif

    private struct DrawGraphicsState {
        var primitive: HorizontalDrawingPrimitive
        var originalBoard: HorizontalBoard
        var points: [HorizontalPoint] = []
        var cursor: HorizontalPoint?
        var rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner
        var layer: Int
        /// When true this is a "Draw Plane": the closed outline becomes a polygon
        /// AND a net-bound `HorizontalPlane` (tool_draw_plane = draw-polygon
        /// + create plane). Reuses every polygon-draw interaction hook so no new
        /// state-machine plumbing is needed; only `commitDrawGraphics` branches.
        var createsPlane: Bool = false
    }

    /// Corner posture for an orthogonal track segment: `.xy` runs horizontally
    /// first then vertically, `.yx` the reverse. Mirrors the schematic net tool.
    enum BoardTrackBendMode {
        case xy
        case yx

        mutating func toggle() {
            self = self == .xy ? .yx : .xy
        }
    }

    private struct DrawTrackState {
        var originalBoard: HorizontalBoard
        var anchor: HorizontalPoint?
        var anchorJunctionID: String?
        /// The anchor sits on a pad center; no junction is created there and
        /// the applicator serializes the endpoint as a direct pad connection.
        var anchorOnPad = false
        var netID: String?
        var width: Double
        var layer: Int
        var cursor: HorizontalPoint?
        var bendMode: BoardTrackBendMode = .xy
        var cornerStyle: BoardTrackCornerStyle = .ninety
        var segmentCount = 0
        var viaCount = 0

        /// Whether the route has committed anything to the draft board yet
        /// (segments or vias) — gates finishing so an empty route is discarded.
        var hasDrawn: Bool { segmentCount > 0 || viaCount > 0 }
    }

    /// One undoable step of an in-progress route (the state before a click's
    /// segments or a via were added), so Backspace can walk the route back a
    /// click at a time without cancelling the whole thing.
    private struct BoardTrackRouteStep {
        var board: HorizontalBoard?
        var anchor: HorizontalPoint?
        var anchorJunctionID: String?
        var anchorOnPad: Bool
        var netID: String?
        var width: Double
        var layer: Int
        var segmentCount: Int
        var viaCount: Int
    }

    private typealias DrawGraphicsResult = HorizontalCanvasDrawGraphicsResult

    private struct MovingConnectionPoint {
        var point: HorizontalPoint
        var netID: String?
    }

    private struct PadLabelGroup {
        var id: String
        var vertices: [HorizontalPoint]
        var netID: String?
        var metadata: [String: String]
        /// Best intrinsic pad frame contributed by any polygon in the group.
        /// Populated from `HorizontalPolygon.padLabelFrame` and merged with the
        /// largest-area-wins rule so the copper polygon's frame beats smaller
        /// mask apertures. Nil means we'll fall back to the polygon-edge
        /// scoring heuristic in `padLabelFrame(for:padText:netText:)`.
        var labelFrame: PadLabelFrameDescriptor?
    }

    private var sourceBoard: HorizontalBoard
    private var netClasses: [HorizontalNetClass]
    @Binding private var viewport: CanvasViewport
    var displayOptions: BoardDisplayOptions
    var fitSafeAreaInsets: EdgeInsets? = nil
    var highlightedNetIDs = Set<String>()
    var highlightedComponentIDs = Set<String>()
    var undoManager: UndoManager? = nil
    var selectionToolSettings = HorizontalSelectionToolSettings()
    var isReadOnly = false
    var ignoresCanvasMouseEvents = false
    var onSelectedNetChange: (Set<String>) -> Void = { _ in }
    var onSelectedComponentChange: (Set<String>) -> Void = { _ in }
    var onHighlightNetCommand: (Set<String>) -> Void = { _ in }
    var onHighlightComponentCommand: (Set<String>) -> Void = { _ in }
    var onBoardChange: (HorizontalBoard) -> Void = { _ in }
    /// A plane create/edit that requires a re-pour. The host runs
    /// `HorizontalBoardPlaneUpdater.updateAllPlanes` on the supplied board, applies
    /// it (writing the plane fragment cache), and registers the named undo —
    /// mirroring the manual "Update All Planes" path. Distinct from
    /// `onBoardChange` because pouring is heavy and owned by the document.
    var onPlaneEdit: (HorizontalBoard, String) -> Void = { _, _ in }
    var onNetClassChange: (String, String?) -> Void = { _, _ in }
    var onComponentRefdesChange: (String, String) -> Void = { _, _ in }
    var onSelectionDetailsChange: (HorizontalSelectionDetailState) -> Void = { _ in }
    var onCanvasCommandActionsChange: (HorizontalCanvasCommandActions?) -> Void = { _ in }
    var hasKeyboardFocus = true
    var onRequestKeyboardFocus: () -> Void = {}
    var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    var drawingToolCommand: HorizontalDrawingToolCommand?
    var drawTrackCommand: HorizontalDrawTrackCommand?
    var onShowToolSettings: () -> Void = {}
    var drawingLayer: Int = HorizontalBoardLayers.topCopper
    /// Bumped by the pane when the board changes underneath the canvas — a plane
    /// pour, a schematic sync. The canvas adopts the new board in place rather
    /// than being rebuilt, so the view never blanks for work it did not ask for.
    var syncRevision: Int = 0
    /// Number keys pick the working copper layer; the pane owns the selection,
    /// so the canvas reports the request rather than applying it.
    var onSelectDrawingLayer: (Int) -> Void = { _ in }
    /// Shifted / control number keys jump to a board view preset.
    var onSelectBoardLayerView: (HorizontalBoardLayerViewPreset) -> Void = { _ in }
    /// Pool directory URL, for re-deriving a package's silk on Unsmash.
    var poolURL: URL?
    @ObservedObject var toolSettings: HorizontalBoardToolSettings

    @State private var hoveredObject: HorizontalSelectableRef?
    @State private var selectedObjects: [HorizontalSelectableRef] = []
    @State private var selectedUnplacedObjectID: String?
    @State private var editedBoard: HorizontalBoard?
    @State private var moveState: MoveState?
    @State private var drawGraphicsState: DrawGraphicsState?
    @State private var drawTrackState: DrawTrackState?
    /// Obstacle world for the active drawing gesture, built once when it starts.
    /// See `docs/push-shove-router.md`.
    @State private var trackRouterSession: HorizontalBoardTrackRouterSession?
    /// Live PNS head, as preview specs, while the autorouter is active (empty in
    /// manual mode). A universal type so the preview renderers stay
    /// platform-agnostic; the session that produces it is macOS-only.
    @State private var pushShovePreviewSpecs: [BoardTrackSegmentSpec] = []
    /// Existing tracks (by id) the previewing route will remove (track repair /
    /// shove) — hidden from the board render until commit.
    @State private var pushShoveRemovedSegmentIDs: Set<String> = []
    #if canImport(HorizontalPushShoveRouter)
    @State private var pushShoveSession: BoardPushShoveSession?
    #endif
    /// In-app copy buffer for board objects (Copy → Paste/Duplicate). Holds the
    /// harvested objects + their bounding-box min so Paste can land at the cursor.
    @State private var boardClipboard: [BoardClipboardItem] = []
    @State private var boardClipboardAnchor: HorizontalPoint?
    /// Active while Paste is placing the clipboard ghost: the harvested objects
    /// follow the cursor (`cursor − anchor` offset) until a click / Return
    /// commits them, or Esc cancels. Nothing is added to the board until commit.
    @State private var pastePlacementState: PastePlacementState?
    /// Step-back history for the in-progress route (Backspace pops one).
    @State private var trackRouteHistory: [BoardTrackRouteStep] = []
    @State private var lastCursorWorldPoint: HorizontalPoint?
    @State private var selectableCacheRevision = 0
    @State private var metalSceneRevision = 0
    #if os(macOS)
    @State private var editingTextState: EditTextState?
    /// Debounces the heavy live re-render (board mutation + connectivity recompute
    /// + Metal rebuild) while typing into the inline text editor, so keystrokes
    /// stay instant and the canvas catches up ~0.1s behind.
    @State private var textRenderDebounce: Task<Void, Never>?
    /// The transform the canvas is actually rendering with (reported by
    /// InteractiveCanvasView from its on-screen viewport). The inline editor
    /// popover anchors against this so it lands on the text at any zoom/pan.
    @State private var canvasDisplayTransform: HorizontalCanvasTransform?
    #endif
    /// Quantized world-space cull threshold for generated labels at the current
    /// zoom (0 = show everything). Unlike `canvasDisplayTransform` this IS
    /// maintained during live pan/zoom, but only written when the quantized step
    /// changes, so it costs a @State write a handful of times across a whole
    /// zoom sweep rather than one per frame.
    @State private var minimumLabelSize: Double = 0
    /// Holds `minimumLabelSize` back until the canvas transform stops moving, so
    /// a pinch doesn't re-run this body (and re-concatenate the buckets) at every
    /// quantization step it sweeps through.
    @StateObject private var labelLODDebouncer = BoardLabelLODDebouncer()
    @StateObject private var undoTarget = HorizontalUndoTarget<HorizontalBoard>()
    @StateObject private var selectableCache = BoardSelectableCache()
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(
        board: HorizontalBoard,
        netClasses: [HorizontalNetClass] = [],
        viewport: Binding<CanvasViewport>,
        displayOptions: BoardDisplayOptions,
        fitSafeAreaInsets: EdgeInsets? = nil,
        highlightedNetIDs: Set<String> = [],
        highlightedComponentIDs: Set<String> = [],
        undoManager: UndoManager? = nil,
        selectionToolSettings: HorizontalSelectionToolSettings = HorizontalSelectionToolSettings(),
        isReadOnly: Bool = false,
        ignoresCanvasMouseEvents: Bool = false,
        onSelectedNetChange: @escaping (Set<String>) -> Void = { _ in },
        onSelectedComponentChange: @escaping (Set<String>) -> Void = { _ in },
        onHighlightNetCommand: @escaping (Set<String>) -> Void = { _ in },
        onHighlightComponentCommand: @escaping (Set<String>) -> Void = { _ in },
        onBoardChange: @escaping (HorizontalBoard) -> Void = { _ in },
        onPlaneEdit: @escaping (HorizontalBoard, String) -> Void = { _, _ in },
        onNetClassChange: @escaping (String, String?) -> Void = { _, _ in },
        onComponentRefdesChange: @escaping (String, String) -> Void = { _, _ in },
        onSelectionDetailsChange: @escaping (HorizontalSelectionDetailState) -> Void = { _ in },
        onCanvasCommandActionsChange: @escaping (HorizontalCanvasCommandActions?) -> Void = { _ in },
        hasKeyboardFocus: Bool = true,
        onRequestKeyboardFocus: @escaping () -> Void = {},
        selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand? = nil,
        drawingToolCommand: HorizontalDrawingToolCommand? = nil,
        drawTrackCommand: HorizontalDrawTrackCommand? = nil,
        onShowToolSettings: @escaping () -> Void = {},
        toolSettings: HorizontalBoardToolSettings,
        drawingLayer: Int = HorizontalBoardLayers.topCopper,
        syncRevision: Int = 0,
        onSelectDrawingLayer: @escaping (Int) -> Void = { _ in },
        onSelectBoardLayerView: @escaping (HorizontalBoardLayerViewPreset) -> Void = { _ in },
        poolURL: URL? = nil
    ) {
        self.sourceBoard = board
        self.netClasses = netClasses
        self._viewport = viewport
        self.displayOptions = displayOptions
        self.fitSafeAreaInsets = fitSafeAreaInsets
        self.highlightedNetIDs = highlightedNetIDs
        self.highlightedComponentIDs = highlightedComponentIDs
        self.undoManager = undoManager
        self.selectionToolSettings = selectionToolSettings
        self.isReadOnly = isReadOnly
        self.ignoresCanvasMouseEvents = ignoresCanvasMouseEvents
        self.onSelectedNetChange = onSelectedNetChange
        self.onSelectedComponentChange = onSelectedComponentChange
        self.onHighlightNetCommand = onHighlightNetCommand
        self.onHighlightComponentCommand = onHighlightComponentCommand
        self.onBoardChange = onBoardChange
        self.onPlaneEdit = onPlaneEdit
        self.onNetClassChange = onNetClassChange
        self.onComponentRefdesChange = onComponentRefdesChange
        self.onSelectionDetailsChange = onSelectionDetailsChange
        self.onCanvasCommandActionsChange = onCanvasCommandActionsChange
        self.hasKeyboardFocus = hasKeyboardFocus
        self.onRequestKeyboardFocus = onRequestKeyboardFocus
        self.selectionPropertyChangeCommand = selectionPropertyChangeCommand
        self.drawingToolCommand = drawingToolCommand
        self.drawTrackCommand = drawTrackCommand
        self.onShowToolSettings = onShowToolSettings
        self.toolSettings = toolSettings
        self.drawingLayer = drawingLayer
        self.syncRevision = syncRevision
        self.onSelectDrawingLayer = onSelectDrawingLayer
        self.onSelectBoardLayerView = onSelectBoardLayerView
        self.poolURL = poolURL
    }

    private var board: HorizontalBoard {
        if let moveState {
            if canPatchBoardMoveInMetal {
                return moveState.originalBoard
            }
            return boardMovePreviewBoard(for: moveState)
        }
        let base = editedBoard ?? sourceBoard
        if let pastePlacementState {
            // Render-only ghost of the clipboard following the cursor. Uses
            // deterministic preview ids so the metal buckets stay stable across
            // body passes; selection/hit-testing is suspended during placement.
            var preview = base
            _ = appendClipboardClones(
                pastePlacementState.items,
                offset: pastePlacementState.cursor - pastePlacementState.anchor,
                into: &preview,
                idPrefix: "paste-preview"
            )
            return preview
        }
        return base
    }

    private var pastePreviewSignature: BoardPastePreviewSignature? {
        guard let pastePlacementState else { return nil }
        let offset = pastePlacementState.cursor - pastePlacementState.anchor
        return BoardPastePreviewSignature(
            itemCount: pastePlacementState.items.count,
            offsetX: Int64(offset.x.rounded()),
            offsetY: Int64(offset.y.rounded())
        )
    }

    private var boardMovePreviewSignature: BoardMovePreviewSignature? {
        guard let moveState else {
            return nil
        }
        return BoardMovePreviewSignature(
            selectedRefs: selectedObjects,
            startPoint: moveState.startPoint,
            lastPoint: moveState.lastPoint
        )
    }

    private var boardForMetalBuckets: HorizontalBoard {
        if canPatchBoardMoveInMetal,
           let moveState {
            return moveState.originalBoard
        }
        var result = board
        // Hide tracks the in-progress autoroute will remove, so the removal
        // (track repair / shove) is previewed before commit. Render-only — `board`
        // (selection, hit-testing) is unchanged.
        if !pushShoveRemovedSegmentIDs.isEmpty {
            result.tracks.removeAll { pushShoveRemovedSegmentIDs.contains(normalizedID($0.id)) }
        }
        return result
    }

    private var theme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    private var hasActiveHighlight: Bool {
        !highlightedNetIDs.isEmpty || !highlightedComponentIDs.isEmpty
    }

    private var drawsGridInMetal: Bool {
        #if canImport(MetalKit)
        displayOptions.grid && HorizontalMetalBackdropView.isSupported
        #else
        false
        #endif
    }

    private var drawsBoardLinesInMetal: Bool {
        #if canImport(MetalKit)
        HorizontalMetalBackdropView.isSupported
            && (displayOptions.boardBody
                || displayOptions.packages
                || displayOptions.outline
                || displayOptions.origin
                || displayOptions.keepouts
                || displayOptions.holes
                || displayOptions.dimensions
                || displayOptions.connectionLines
                || displayOptions.pads
                || displayOptions.vias
                || displayOptions.decals
                || displayOptions.text
                || (Self.emitsGeneratedBoardLabelsInMetal
                    && (displayOptions.trackLabels || displayOptions.padLabels || displayOptions.viaLabels))
                || HorizontalBoardLayers.all.contains { displayOptions.isLayerVisible($0) })
        #else
        false
        #endif
    }

    private var canPatchBoardMoveInMetal: Bool {
        guard let moveState,
              !selectedObjects.isEmpty,
              drawsBoardLinesInMetal else {
            return false
        }
        return moveState.residentMovePlan.isPatchable
            && selectedObjects.allSatisfy(isBoardMetalMovePatchable)
    }

    private func isBoardMetalMovePatchable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .boardPackage,
             .track,
             .boardNetTie,
             .boardLine,
             .boardArc,
             .via,
             .boardHole,
             .connectionLine,
             .keepout,
             .dimension,
             .boardDecal,
             .polygonEdge,
             .plane,
             .junction:
            return true
        case .text:
            // Standalone board text owns an individually-patchable resident span.
            // A smashed package's `fromSmash` text renders as package geometry
            // (no per-text span), so its move must rebuild the scene to re-render
            // the glyphs — fall off the fast in-place patch path.
            return packageID(forGeometryID: ref.id) == nil
        case .pad:
            // A pad has no resident span of its own — its geometry lives in its
            // package's spans. When the package is also selected (e.g. Select All
            // → nudge), the pad moves rigidly with the package via span
            // translation, so the whole move stays on the fast in-place patch path
            // instead of triggering a full board copy + bucket rebuild every
            // press. A lone pad move (package not selected) must still fall back
            // so its preview is correct.
            guard let packageID = packageID(forGeometryID: ref.id) else {
                return false
            }
            return selectedObjects.contains(HorizontalSelectableRef(id: packageID, type: .boardPackage))
        case .polygonArcCenter, .polygonVertex:
            // Polygon control points share the polygon's resident span (tagged by
            // .polygonEdge). If the whole polygon (its edge) is also selected the
            // polygon translates rigidly; a lone vertex/arc move reshapes the
            // polygon (non-rigid) and must fall back to a rebuild.
            return selectedObjects.contains(HorizontalSelectableRef(id: ref.id, type: .polygonEdge, layer: ref.layer))
        case .blockSymbolPort, .boardPanel, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return false
        }
    }

    /// iOS modal prompt (text / number / option-picker) for draw tools that need input
    /// — AddText, track-width, plane-net. macOS uses the synchronous NSAlert prompts, so
    /// this stays nil there.
    @State private var promptRequest: HorizontalCanvasPromptRequest?

    var body: some View {
        let _ = BoardLoadTimer.beginBoard2DLoad(id: board2DProfileID, summary: board2DProfileSummary)
        let board2DBodyStart = BoardLoadTimer.tickBodyStart()
        defer { BoardLoadTimer.tickBodyEnd(board2DBodyStart) }
        let _ = BoardLoadTimer.tickBody()
        let _ = HorizontalMoveRateDiagnostics.mark(.bodyPass, active: moveState != nil)
        let profilesPostCommitBody = HorizontalMoveCommitDiagnostics.hasPendingPostCommitBody
        var postCommitBodyTimings = [(String, UInt64)]()
        func measureBody<T>(_ label: String, _ body: () -> T) -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = body()
            let elapsed = elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)
            BoardLoadTimer.recordBoard2DStep(label, nanoseconds: elapsed, id: board2DProfileID)
            if profilesPostCommitBody {
                postCommitBodyTimings.append((label, elapsed))
            }
            return value
        }

        let visibleLayers = measureBody("visible layers") { visibleRenderLayers() }
        let metalRenderLayers = measureBody("metal render layers") { boardMetalRenderLayers() }
        let metalLineBatch = measureBody("metal line batch") {
            measuredBoardMetalLineBatch(renderLayers: metalRenderLayers)
        }
        let metalBufferPatches = measureBody("move patches") {
            measuredBoardMetalMovePatches(metadata: metalLineBatch.metadata)
        }
        let metalHighlightBatch = measureBody("highlight batch") { boardMetalHighlightBatch() }
        let metalDimBatch = measureBody("dim batch") {
            boardMetalDimBatch(
            hasMetalHighlight: !metalHighlightBatch.lines.isEmpty || !metalHighlightBatch.triangles.isEmpty
            )
        }
        let metalSelectionBatch = measureBody("selection batch") { measuredBoardMetalSelectionBatch() }
        let metalPreviewBatch = measureBody("preview batch") { boardMetalPreviewBatch() }
        let metalTopOverlayTriangles = measureBody("overlay triangles") {
            metalDimBatch.triangles + metalHighlightBatch.triangles + metalSelectionBatch.triangles + metalPreviewBatch.triangles
        }
        let metalTopOverlayLines = measureBody("overlay lines") {
            metalHighlightBatch.lines + metalSelectionBatch.lines + metalPreviewBatch.lines
        }
        let metalTopOverlayHandles = measureBody("overlay handles") {
            metalHighlightBatch.handles + metalSelectionBatch.handles + metalPreviewBatch.handles
        }
        let metalTopOverlayKey = measureBody("overlay key") {
            ((metalDimBatch.triangleKey &* 31 &+ metalHighlightBatch.lineKey) &* 31 &+ metalSelectionBatch.lineKey) &* 31 &+ metalPreviewBatch.lineKey
        }
        let metalTopOverlayHandleKey = measureBody("handle key") {
            (metalHighlightBatch.handleKey &* 31 &+ metalSelectionBatch.handleKey) &* 31 &+ metalPreviewBatch.handleKey
        }
        let metalTopOverlayBufferPatches = measureBody("selection move patches") {
            measuredBoardMetalSelectionMovePatches(
                baseSelectionBatch: metalSelectionBatch,
                lineStart: metalHighlightBatch.lines.count,
                handleStart: metalHighlightBatch.handles.count
            )
        }
        let _ = HorizontalMoveCommitDiagnostics.reportPostCommitBody(timings: postCommitBodyTimings)

        return InteractiveCanvasView(
            bounds: board.bounds,
            viewport: $viewport,
            backgroundColor: theme.background,
            foregroundColor: theme.textOverlay,
            overlayBackgroundColor: theme.overlayBackground,
            showsScaleBar: displayOptions.scaleBar,
            showsCoordinateReadout: displayOptions.coordinates,
            grid: board.grid,
            gridColor: theme.grid,
            drawsGridInMetal: drawsGridInMetal,
            gridLineWidth: appearanceSettings.gridMarkLineWidth,
            metalOverlayTriangles: metalLineBatch.triangles,
            metalOverlayTriangleKey: metalLineBatch.triangleKey,
            metalOverlayLines: metalLineBatch.lines,
            metalOverlayLineKey: metalLineBatch.lineKey,
            metalOverlayAnchoredRects: metalLineBatch.anchoredRects,
            metalOverlayAnchoredRectKey: metalLineBatch.anchoredRectKey,
            metalOverlayBufferPatches: metalBufferPatches,
            metalOverlayBufferPatchKey: metalBufferPatches.hashValue,
            metalOverlayVisibleCompositeGroups: visibleMetalCompositeGroups(for: visibleLayers),
            metalOverlayLayerOpacityExemptGroups: [Self.textOverlayMetalCompositeGroup, Self.holesMetalCompositeGroup],
            metalTopOverlayTriangles: metalTopOverlayTriangles,
            metalTopOverlayTriangleKey: metalTopOverlayKey,
            metalTopOverlayLines: metalTopOverlayLines,
            metalTopOverlayLineKey: metalTopOverlayKey,
            metalTopOverlayHandles: metalTopOverlayHandles,
            metalTopOverlayHandleKey: metalTopOverlayHandleKey,
            metalTopOverlayBufferPatches: metalTopOverlayBufferPatches,
            metalTopOverlayBufferPatchKey: metalTopOverlayBufferPatches.hashValue,
            metalLoadProfileID: board2DProfileID,
            cursorSize: appearanceSettings.canvasCursorSize,
            snapTargets: boardSnapTargets(),
            fitSafeAreaInsets: fitSafeAreaInsets,
            minimumLineWidth: appearanceSettings.minimumLineWidth(for: .board),
            metalLayerOpacity: layerOpacity,
            selectionHUD: selectionHUD,
            hoverStatusText: interactionStatusText ?? hoverStatusText,
            showsHoverPopover: appearanceSettings.shouldShowHoverPopover,
            selectionDetails: selectionDetails,
            showsSelectionDetails: Self.showsInCanvasSelectionInspector,
            unplacedObjects: currentUnplacedObjects,
            selectedUnplacedObjectID: selectedUnplacedObjectID,
            placesUnplacedObjectsOnTrailingEdge: appearanceSettings.shouldSwapViewControlsAndUnplacedReferences,
            selectionToolSettings: selectionToolSettings,
            selectionSelectables: boardSelectables(),
            handlesSelectionDeletion: canDeleteSelection,
            undoManager: undoManager,
            ignoresCanvasMouseEvents: ignoresCanvasMouseEvents,
            onCursorWorldPointChange: { point, worldUnitsPerPoint in
                updateCursor(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
            },
            onPrimaryClick: { point, worldUnitsPerPoint, clickAction, clickCount in
                if pastePlacementState != nil {
                    commitPastePlacement(at: point)
                    return
                }
                if let moveState {
                    if moveState.tracksCursor {
                        updateMove(to: point)
                    }
                    commitMove()
                    return
                }
                if drawGraphicsState != nil {
                    addDrawGraphicsPoint(point)
                    // Double-click ends the shape — including a multi-segment
                    // line. The duplicate end-vertex the second click adds is a
                    // zero-length segment that commitDrawGraphics filters out,
                    // and commitDrawGraphicsAtCursor keeps the tool active if
                    // there's nothing valid yet, so an early double-click is safe.
                    if clickCount >= 2 {
                        commitDrawGraphicsAtCursor()
                    }
                    return
                }
                if drawTrackState != nil {
                    addDrawTrackPoint(point)
                    // Guard on segmentCount: commitDrawTrack tears down the
                    // tool state before checking it, so an accidental
                    // double-click on the start point would silently exit the
                    // tool having drawn nothing.
                    if clickCount >= 2, drawTrackState?.hasDrawn == true {
                        commitDrawTrack()
                    }
                    return
                }

                let hitRef = hitSelectable(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
                #if os(macOS)
                // Double-click a text → reopen the inline editor instead of just
                // selecting it.
                if clickCount >= 2, let hitRef, hitRef.type == .text {
                    beginEditingExistingText(hitRef)
                    return
                }
                #endif
                updateSelection(with: hitRef, action: clickAction)
            },
            onAreaSelection: { refs, action in
                guard moveState == nil,
                      drawGraphicsState == nil,
                      drawTrackState == nil,
                      pastePlacementState == nil else {
                    return
                }
                updateSelection(with: refs, action: action)
            },
            targetMenuItems: { point, worldUnitsPerPoint in
                targetMenuItems(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
            },
            onTargetMenuSelection: { ref in
                setSelectedObject(ref)
            },
            targetItemMenu: { ref in
                targetItemMenuEntries(for: ref)
            },
            onTargetMenuHighlight: { ref in
                if hoveredObject != ref {
                    hoveredObject = ref
                }
            },
            onTargetMenuCommand: { ref, command in
                setSelectedObject(ref)
                dispatchCanvasCommand(command)
            },
            onUnplacedObjectSelection: { object in
                selectUnplacedObject(object)
            },
            onSelectionPropertyChange: applySelectionPropertyChange,
            onCommand: dispatchCanvasCommand,
            onCanvasDisplayTransformChange: { transform in
                #if os(macOS)
                // Only store while editing (the user isn't gesturing then, so it
                // stays stable); when not editing the overlay is inert anyway and
                // this avoids per-frame @State churn during pan/zoom. The report
                // trigger below guarantees a fresh value the instant editing
                // begins (when viewport/size haven't changed).
                if editingTextState != nil {
                    canvasDisplayTransform = transform
                }
                #endif
                // Label LOD is sampled from the live transform but APPLIED only
                // once zooming stops. Sampling is just arithmetic; applying
                // writes @State, which re-runs this body and re-concatenates the
                // buckets, so doing it per frame made pinch-zoom lag.
                labelLODDebouncer.schedule(Self.minimumLegibleLabelSize(for: transform)) { settled in
                    if settled != minimumLabelSize {
                        minimumLabelSize = settled
                    }
                }
            },
            canvasDisplayTransformReportTrigger: inlineTextEditorReportTrigger,
            allowsContextMenu: moveState == nil && drawGraphicsState == nil && drawTrackState == nil && pastePlacementState == nil,
            handlesInteractionKeys: moveState != nil || drawGraphicsState != nil || drawTrackState != nil || pastePlacementState != nil,
            hasKeyboardFocus: hasKeyboardFocus,
            onRequestKeyboardFocus: onRequestKeyboardFocus,
            samplesCursorContinuously: drawTrackState != nil
                || drawGraphicsState != nil
                || pastePlacementState != nil
                || moveState?.tracksCursor == true,
            supportsTrackVias: true
        )
        .onChange(of: syncRevision) { _, _ in
            adoptExternallyUpdatedBoard()
        }
        .onChange(of: sourceBoard.uuid) { _, _ in
            undoTarget.removeAllActions(from: undoManager)
            editedBoard = nil
            invalidateSelectableCache()
            selectedObjects = []
            selectedUnplacedObjectID = nil
            hoveredObject = nil
            moveState = nil
            drawGraphicsState = nil
            drawTrackState = nil
            trackRouterSession = nil
            pastePlacementState = nil
            trackRouteHistory = []
            lastCursorWorldPoint = nil
            configureUndoTarget()
            publishSelectionContext()
        }
        .onAppear {
            configureUndoTarget()
            onSelectionDetailsChange(selectionDetails)
            publishCanvasCommandActions()
        }
        .onDisappear {
            onSelectionDetailsChange(.empty)
            onCanvasCommandActionsChange(nil)
        }
        .horizonCanvasPrompt($promptRequest)
        .overlay { inlineTextEditorOverlay }
        .onChange(of: canvasCommandActionsSignature) { _, _ in
            publishCanvasCommandActions()
        }
        .onChange(of: selectionDetails) { _, details in
            onSelectionDetailsChange(details)
        }
        .onChange(of: selectionPropertyChangeCommand?.id) { _, _ in
            if !isReadOnly, let selectionPropertyChangeCommand {
                applySelectionPropertyChange(selectionPropertyChangeCommand.change)
            }
        }
        .onChange(of: drawingToolCommand?.id) { _, _ in
            if !isReadOnly, let drawingToolCommand {
                beginDrawGraphics(drawingToolCommand.primitive)
            }
        }
        .onChange(of: drawTrackCommand?.id) { _, _ in
            if !isReadOnly, drawTrackCommand != nil {
                beginDrawTrack()
            }
        }
        .onChange(of: isReadOnly) { _, readOnly in
            if readOnly {
                cancelDrawGraphics()
                cancelDrawTrack()
                cancelMove()
            }
        }
    }

    /// macOS inline text-placement editor: a transparent 1pt anchor positioned at
    /// the placed text's screen point, hosting a popover (arrow pointing down at
    /// the text) with a focused, select-all TextField that updates the canvas live.
    /// iOS keeps its prompt-sheet flow, so this is empty there.
    @ViewBuilder
    private var inlineTextEditorOverlay: some View {
        #if os(macOS)
        GeometryReader { proxy in
            if let edit = editingTextState {
                // Anchor against the transform the canvas actually renders with
                // (reported via onCanvasDisplayTransformChange — built from the
                // on-screen viewport, not the binding which can lag). Fall back to
                // a local reconstruction only if no report has arrived yet.
                let transform = canvasDisplayTransform ?? HorizontalCanvasTransform(
                    bounds: board.bounds,
                    size: proxy.size,
                    fitInsets: boardCanvasFitInsets(safeArea: proxy.safeAreaInsets),
                    zoom: viewport.zoom,
                    pan: viewport.pan
                )
                let anchor = transform.point(edit.worldPosition)
                // Attach the popover to the 1pt anchor BEFORE `.position`: a popover
                // anchors to the view it's attached to, and `.position` returns a
                // PARENT-FILLING view — so attaching after `.position` anchored the
                // popover to the whole canvas (top-center) rather than the point.
                Color.clear
                    .frame(width: 1, height: 1)
                    .popover(isPresented: inlineTextEditorPresented, arrowEdge: .top) {
                        inlineTextEditor
                    }
                    .position(anchor)
            }
        }
        .allowsHitTesting(false)
        #else
        EmptyView()
        #endif
    }

    /// Trigger that forces the canvas to re-report its display transform the
    /// instant an inline edit begins (so the anchor is fresh even when the
    /// viewport hasn't changed since the last report). nil on iOS.
    private var inlineTextEditorReportTrigger: AnyHashable? {
        #if os(macOS)
        return editingTextState.map { AnyHashable($0.ref) }
        #else
        return nil
        #endif
    }

    #if os(macOS)
    /// Mirrors InteractiveCanvasView.canvasFitInsets(for:) so the popover anchor
    /// lands exactly where the canvas draws the text (same fit math, same insets).
    private func boardCanvasFitInsets(safeArea proxySafeArea: EdgeInsets) -> HorizontalCanvasInsets {
        let safeAreaInsets = fitSafeAreaInsets ?? proxySafeArea
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

    /// `isPresented` for the editor popover. Setting it false (click-away / Esc)
    /// finalizes the placement.
    private var inlineTextEditorPresented: Binding<Bool> {
        Binding(
            get: { editingTextState?.isEditing == true },
            set: { presented in
                if !presented {
                    finalizeTextEdit()
                }
            }
        )
    }

    private var inlineTextEditorBinding: Binding<String> {
        Binding(
            get: { editingTextState?.content ?? "" },
            set: { updateEditingTextContent($0) }
        )
    }

    @ViewBuilder
    private var inlineTextEditor: some View {
        BoardInlineTextEditorField(
            text: inlineTextEditorBinding,
            onSubmit: { finalizeTextEdit() }
        )
    }
    #endif

    private var canvasCommandActionsSignature: Int {
        var hasher = Hasher()
        hasher.combine(isReadOnly)
        hasher.combine(selectedObjects)
        hasher.combine(selectedUnplacedObjectID)
        hasher.combine(moveState != nil)
        hasher.combine(drawGraphicsState?.primitive.rawValue)
        hasher.combine(drawGraphicsState?.points.count ?? 0)
        hasher.combine(drawGraphicsState?.rectanglePlacementMode == .center)
        hasher.combine(drawTrackState != nil)
        hasher.combine(drawTrackState?.segmentCount ?? 0)
        hasher.combine(drawTrackState?.cornerStyle.rawValue)
        hasher.combine(boardClipboard.isEmpty)
        hasher.combine(pastePlacementState != nil)
        return hasher.finalize()
    }

    private func publishCanvasCommandActions() {
        onCanvasCommandActionsChange(canvasCommandActions())
    }

    private var hasMetalHighlightCandidates: Bool {
        guard hasActiveHighlight else {
            return false
        }

        func matches(_ netID: String?) -> Bool {
            guard let netID else {
                return false
            }
            return highlightedNetIDs.contains(normalizedID(netID))
        }

        if board.planes.contains(where: {
            displayOptions.isLayerVisible($0.layer) && matches($0.netID) && !$0.renderFragments.isEmpty
        }) {
            return true
        }
        if board.polygons.contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if board.lines.contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if board.arcs.contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if board.tracks.contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if board.netTies.contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if displayOptions.connectionLines,
           board.connectionLines.contains(where: { matches($0.netID) })
            || board.airwires.contains(where: { matches($0.netID) }) {
            return true
        }
        if displayOptions.pads,
           board.packagePads.contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if displayOptions.vias,
           board.vias.contains(where: { !visibleViaLayers(for: $0).isEmpty && matches($0.netID) }) {
            return true
        }
        if displayOptions.holes,
           (board.packageHoles + board.viaHoles + board.holes).contains(where: { matches($0.netID) }) {
            return true
        }
        if displayOptions.text,
           (board.texts + board.packageTexts).contains(where: { displayOptions.isLayerVisible($0.layer) && matches($0.netID) }) {
            return true
        }
        if displayOptions.packages,
           board.packages.contains(where: { matchesHighlightedComponent($0.componentID) }) {
            return true
        }
        return false
    }

    private var selectionHUD: HorizontalSelectionHUDState {
        HorizontalSelectionHUDState(
            hovered: hudItem(for: hoveredObject),
            selected: []
        )
    }

    private var hoverStatusText: String? {
        guard let hoveredObject,
              let item = hudItem(for: hoveredObject) else {
            return nil
        }
        return hoverStatusText(for: hoveredObject, item: item)
    }

    private var interactionStatusText: String? {
        if let state = drawGraphicsState {
            return HorizontalCanvasModeSupport.drawingToolStatusText(
                for: state.primitive,
                rectanglePlacementMode: state.rectanglePlacementMode
            )
        }
        if let state = drawTrackState {
            let layerName = HorizontalBoardLayers.name(for: state.layer)
            let widthMM = String(format: "%g", state.width / 1_000_000)
            if isRouterMode {
                let kind = toolSettings.routerShove ? "shove" : "walkaround"
                if state.anchor == nil {
                    return "Autoroute \(kind) (\(layerName), \(widthMM) mm): click to start   W width   Esc cancels"
                }
                let viaHint = canToggleVia ? "   V via" : ""
                return "Autoroute \(kind) (\(layerName), \(widthMM) mm): click to route   / posture\(viaHint)   ⌫ back   Return/double-click finishes   Esc cancels"
            }
            if state.anchor == nil {
                return "Track (\(layerName), \(widthMM) mm): click to start   W width   Esc cancels"
            }
            let viaHint = canToggleVia ? "   V via" : ""
            let undoHint = trackRouteHistory.isEmpty ? "" : "   ⌫ back"
            return "Track (\(layerName), \(widthMM) mm, \(state.cornerStyle.label)): click to route   / posture   C corner (90/45/arc)   W width\(viaHint)\(undoHint)   Return/double-click finishes   Esc cancels"
        }
        if moveState != nil {
            return "Move: click or Return commits   Esc cancels"
        }
        return nil
    }

    private var selectionDetails: HorizontalSelectionDetailState {
        let stableBoard = editedBoard ?? sourceBoard
        return selectableCache.selectionDetails(
            key: BoardSelectionDetailsCacheKey(
                boardID: stableBoard.uuid,
                revision: selectableCacheRevision,
                counts: boardGeometryCounts(for: stableBoard),
                selectedRefs: selectedObjects,
                selectedUnplacedObjectID: selectedUnplacedObjectID.map(normalizedID)
            )
        ) {
            buildSelectionDetails()
        }
    }

    private func buildSelectionDetails() -> HorizontalSelectionDetailState {
        if let selectedUnplacedObject {
            return HorizontalSelectionDetailState(
                hovered: nil,
                groups: [
                    HorizontalSelectionDetailGroup(
                        type: .boardPackage,
                        title: "Unplaced package",
                        pluralTitle: "Unplaced packages",
                        items: [selectionDetailItem(for: selectedUnplacedObject)]
                    )
                ]
            )
        }

        let items = selectedObjects.compactMap(selectionDetailItem)
        let groups = Dictionary(grouping: items, by: { $0.ref.type })
            .map { type, items in
                HorizontalSelectionDetailGroup(
                    type: type,
                    title: displayName(for: type),
                    pluralTitle: pluralDisplayName(for: type),
                    items: items
                )
            }
            .sorted { $0.title < $1.title }
        return HorizontalSelectionDetailState(hovered: nil, groups: groups)
    }

    private var selectedNetID: String? {
        selectedNetIDs.first
    }

    private var selectedNetIDs: Set<String> {
        Set(selectedObjects.compactMap { netID(for: $0).map(normalizedID) })
    }

    private var selectedComponentIDs: Set<String> {
        var ids = Set(selectedObjects.compactMap { componentID(for: $0).map(normalizedID) })
        if let selectedUnplacedObject,
           let componentID = selectedUnplacedObject.componentID.map(normalizedID) {
            ids.insert(componentID)
        }
        return ids
    }

    private func publishSelectionContext() {
        onSelectedNetChange(selectedNetIDs)
        onSelectedComponentChange(selectedComponentIDs)
    }

    private var selectedUnplacedObject: HorizontalUnplacedObject? {
        guard let selectedUnplacedObjectID else {
            return nil
        }
        return currentUnplacedObjects.first { normalizedID($0.id) == normalizedID(selectedUnplacedObjectID) }
    }

    private var currentUnplacedObjects: [HorizontalUnplacedObject] {
        let placeableObjects = board.placeableObjects.isEmpty ? board.unplacedObjects : board.placeableObjects
        let placedComponentIDs = Set(board.packages.compactMap { $0.componentID.map(normalizedID) })
        return placeableObjects
            .filter { object in
                guard let componentID = object.componentID.map(normalizedID) else {
                    return true
                }
                return !placedComponentIDs.contains(componentID)
            }
            .sorted { lhs, rhs in
                lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }

    private var canDeleteSelection: Bool {
        !isReadOnly && moveState == nil && drawGraphicsState == nil && !selectedObjects.isEmpty
    }

    private func selectionDetailItem(for ref: HorizontalSelectableRef) -> HorizontalSelectionDetailItem? {
        guard let item = hudItem(for: ref) else {
            return nil
        }

        return HorizontalSelectionDetailItem(
            ref: ref,
            title: item.title,
            subtitle: item.subtitle,
            details: item.details,
            properties: selectionProperties(for: ref)
        )
    }

    private func selectionDetailItem(for object: HorizontalUnplacedObject) -> HorizontalSelectionDetailItem {
        HorizontalSelectionDetailItem(
            ref: HorizontalSelectableRef(id: object.id, type: .boardPackage),
            title: object.label,
            subtitle: object.subtitle,
            details: componentDetailRows(object.details)
                + [detailRow("Component", object.componentID.map(shortID))].compactMap { $0 },
            properties: [
                readOnlyProperty("state", "State", "Unplaced"),
                readOnlyProperty("kind", "Kind", object.subtitle),
                readOnlyProperty("component", "Component", object.componentID.map(shortID)),
            ].compactMap { $0 }
        )
    }

    private func hudItem(for ref: HorizontalSelectableRef?) -> HorizontalSelectionHUDItem? {
        guard let ref else {
            return nil
        }

        switch ref.type {
        case .boardPackage:
            guard let package = board.packages.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            let side = package.mirrored ? "bottom" : "top"
            return HorizontalSelectionHUDItem(
                title: nonEmpty(package.label) ?? shortID(package.id),
                subtitle: "Board package \(shortID(package.id)) on \(side)",
                details: componentDetailRows(package.componentDetails)
                    + [
                        detailRow("Side", side),
                    ].compactMap { $0 }
            )
        case .track:
            return segmentHUDItem(for: ref, in: board.tracks, title: "Track")
        case .boardNetTie:
            return segmentHUDItem(for: ref, in: board.netTies, title: "Board net tie")
        case .boardLine:
            return segmentHUDItem(for: ref, in: board.lines, title: "Board line")
        case .boardArc:
            return arcHUDItem(for: ref, in: board.arcs, title: "Board arc")
        case .connectionLine:
            return segmentHUDItem(for: ref, in: board.connectionLines, title: "Connection line")
        case .pad:
            guard let pad = board.packagePads.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Pad \(padLabel(for: pad))",
                subtitle: netDisplayName(pad.netID).map { "\($0) - \(shortID(pad.id))" } ?? shortID(pad.id),
                details: netDetailRows(pad.netID) + [
                    detailRow("Layer", layerName(for: pad.layer)),
                ].compactMap { $0 } + metadataRows(pad.metadata)
            )
        case .via:
            guard let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Via",
                subtitle: netDisplayName(via.netID).map { "\($0) - \(diameterString(via.size))" }
                    ?? "\(diameterString(via.size)) - \(shortID(via.id))",
                details: netDetailRows(via.netID) + [
                    detailRow("Diameter", diameterString(via.size)),
                ].compactMap { $0 }
            )
        case .boardHole:
            guard let hole = hole(for: ref.id) else {
                return genericHUDItem(for: ref)
            }
            let plating = hole.plated ? "plated" : "non-plated"
            return HorizontalSelectionHUDItem(
                title: "Board hole",
                subtitle: netDisplayName(hole.netID).map { "\($0) - \(holeLabel(for: hole)) \(plating)" }
                    ?? "\(holeLabel(for: hole)) \(plating)",
                details: netDetailRows(hole.netID) + [
                    detailRow("Shape", hole.shape.rawValue.capitalized),
                    detailRow("Diameter", diameterString(hole.diameter)),
                    hole.shape == .slot ? detailRow("Length", diameterString(hole.effectiveLength)) : nil,
                    detailRow("Plating", plating),
                ].compactMap { $0 }
            )
        case .polygonArcCenter:
            return polygonHUDItem(for: ref, title: "Polygon arc center")
        case .polygonEdge:
            return polygonHUDItem(for: ref, title: "Polygon edge")
        case .polygonVertex:
            return polygonHUDItem(for: ref, title: "Polygon vertex")
        case .plane:
            guard let plane = board.planes.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Plane",
                subtitle: netDisplayName(plane.netID) ?? shortID(plane.id),
                details: netDetailRows(plane.netID) + [
                    detailRow("Layer", layerName(for: plane.layer)),
                    detailRow("Priority", String(plane.priority)),
                    detailRow("Fill", plane.fillStyle),
                ].compactMap { $0 }
            )
        case .keepout:
            guard let keepout = board.keepouts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Keepout",
                subtitle: nonEmpty(keepout.keepoutClass) ?? shortID(keepout.id),
                details: [
                    detailRow("Layer", keepout.allCopperLayers ? "All copper" : layerName(for: keepout.polygon.layer)),
                    detailRow("Class", keepout.keepoutClass),
                    detailRow("Exposed", keepout.exposedCopperOnly ? "yes" : nil),
                ].compactMap { $0 }
            )
        case .dimension:
            guard let dimension = board.dimensions.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Dimension",
                subtitle: dimension.label,
                details: [
                    detailRow("Mode", dimension.mode.rawValue),
                    detailRow("Length", lengthString(dimension.length)),
                ].compactMap { $0 }
            )
        case .boardDecal:
            guard let decal = board.decals.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(title: nonEmpty(decal.name) ?? "Board decal", subtitle: shortID(decal.id))
        case .boardPanel:
            guard let panel = board.boardPanels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(title: nonEmpty(panel.boardName) ?? "Board panel", subtitle: shortID(panel.id))
        case .text:
            guard let text = (board.texts + board.packageTexts).first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: nonEmpty(text.text) ?? "Text",
                subtitle: netDisplayName(text.netID).map { "\($0) - \(shortID(text.id))" } ?? shortID(text.id),
                details: netDetailRows(text.netID) + [
                    detailRow("Layer", layerName(for: text.layer)),
                    detailRow("Size", lengthString(text.size)),
                ].compactMap { $0 }
            )
        case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return genericHUDItem(for: ref)
        }
    }

    private func segmentHUDItem(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        title: String
    ) -> HorizontalSelectionHUDItem {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return genericHUDItem(for: ref)
        }

        var details = netDetailRows(segment.netID) + [
            detailRow("Layer", layerName(for: segment.layer)),
            detailRow("Length", lengthString(segment.length)),
            detailRow("Width", segment.width > 0 ? lengthString(segment.width) : nil),
        ].compactMap { $0 }
        if let radius = segment.arc?.radius {
            details.append(HorizontalSelectionHUDDetail(label: "Radius", value: lengthString(radius)))
        }

        return HorizontalSelectionHUDItem(
            title: title,
            subtitle: netDisplayName(segment.netID).map { "\($0) - \(lengthString(segment.length))" }
                ?? "\(lengthString(segment.length)) - \(shortID(segment.id))",
            details: details
        )
    }

    private func arcHUDItem(
        for ref: HorizontalSelectableRef,
        in arcs: [HorizontalArc],
        title: String
    ) -> HorizontalSelectionHUDItem {
        guard let arc = arcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return genericHUDItem(for: ref)
        }

        return HorizontalSelectionHUDItem(
            title: title,
            subtitle: netDisplayName(arc.netID).map { "\($0) - \(lengthString(arc.length))" }
                ?? "\(lengthString(arc.length)) - \(shortID(arc.id))",
            details: netDetailRows(arc.netID) + [
                detailRow("Layer", layerName(for: arc.layer)),
                detailRow("Radius", lengthString(arc.radius)),
                detailRow("Length", lengthString(arc.length)),
                detailRow("Width", arc.width > 0 ? lengthString(arc.width) : nil),
            ].compactMap { $0 }
        )
    }

    private func polygonHUDItem(for ref: HorizontalSelectableRef, title: String) -> HorizontalSelectionHUDItem {
        guard let polygon = boardPolygon(for: ref.id, in: board) else {
            return genericHUDItem(for: ref)
        }

        return HorizontalSelectionHUDItem(
            title: title,
            subtitle: netDisplayName(polygon.netID).map { "\($0) - vertex \(ref.vertex)" }
                ?? "\(shortID(ref.id)) - vertex \(ref.vertex)",
            details: netDetailRows(polygon.netID) + [
                detailRow("Layer", layerName(for: polygon.layer)),
                detailRow("Area", areaString(polygon.area)),
            ].compactMap { $0 }
        )
    }

    private func boardPolygon(for id: String, in board: HorizontalBoard) -> HorizontalPolygon? {
        let normalizedPolygonID = normalizedID(id)
        return board.polygons.first { normalizedID($0.id) == normalizedPolygonID }
            ?? board.planes.compactMap(\.fallbackPolygon).first { normalizedID($0.id) == normalizedPolygonID }
    }

    private func genericHUDItem(for ref: HorizontalSelectableRef) -> HorizontalSelectionHUDItem {
        HorizontalSelectionHUDItem(title: displayName(for: ref.type), subtitle: shortID(ref.id))
    }

    private func hoverStatusText(for ref: HorizontalSelectableRef, item: HorizontalSelectionHUDItem) -> String {
        let typeName = statusTypeName(for: ref.type)
        let displayType = displayName(for: ref.type)
        let name = statusName(for: item, displayType: displayType)
        guard let name else {
            return typeName
        }
        return "\(typeName): \(name)"
    }

    private func statusName(for item: HorizontalSelectionHUDItem, displayType: String) -> String? {
        if let title = nonEmpty(item.title),
           title.caseInsensitiveCompare(displayType) != .orderedSame {
            return title
        }
        if let netValue = item.details.first(where: { $0.label == "Net" })?.value,
           let netName = nonEmpty(netValue) {
            return netName
        }
        return nonEmpty(item.subtitle)
    }

    private func statusTypeName(for type: HorizontalObjectType) -> String {
        displayName(for: type)
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }

    private func componentDetailRows(_ component: HorizontalComponentDetails?) -> [HorizontalSelectionHUDDetail] {
        guard let component else {
            return []
        }

        return [
            detailRow("Refdes", component.refdes),
            detailRow("Value", component.value),
            component.noPopulate ? detailRow("DNP", "Yes") : nil,
            detailRow("MPN", component.mpn),
            detailRow("Manufacturer", component.manufacturer),
            detailRow("Package", component.packageName),
            detailRow("Description", component.description),
            detailRow("Datasheet", component.datasheet),
        ].compactMap { $0 }
    }

    private func netDetailRows(_ netID: String?) -> [HorizontalSelectionHUDDetail] {
        guard let netID else {
            return []
        }

        let net = board.netDetails[normalizedID(netID)]
        return [
            detailRow("Net", net?.name ?? shortID(netID)),
            detailRow("Class", net?.netClassName),
            detailRow("Type", netTypeString(net)),
        ].compactMap { $0 }
    }

    private func netTypeString(_ net: HorizontalNetDetails?) -> String? {
        guard let net else {
            return nil
        }

        var values = [String]()
        if net.isPower {
            values.append("power")
        }
        if net.isPort {
            values.append("port \(net.portDirection ?? "bidirectional")")
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private func metadataRows(_ metadata: [String: String]) -> [HorizontalSelectionHUDDetail] {
        metadata.keys.sorted().compactMap { key in
            detailRow(key, metadataValue(metadata[key], for: key))
        }
    }

    private func metadataValue(_ value: String?, for key: String) -> String? {
        guard let value else {
            return nil
        }

        let lowerKey = key.lowercased()
        if lowerKey.contains("width") || lowerKey.contains("height") || lowerKey.contains("diameter"),
           let numeric = Double(value) {
            return lengthString(numeric)
        }
        return value
    }

    private func detailRow(_ label: String, _ value: String?) -> HorizontalSelectionHUDDetail? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        return HorizontalSelectionHUDDetail(label: label, value: value)
    }

    private func selectionProperties(for ref: HorizontalSelectableRef) -> [HorizontalSelectionProperty] {
        switch ref.type {
        case .track:
            return segmentProperties(for: ref, segments: board.tracks, copperOnly: true, includesNetClass: true)
        case .boardNetTie:
            return segmentProperties(for: ref, segments: board.netTies, copperOnly: true, includesNetClass: true)
        case .boardLine:
            return segmentProperties(for: ref, segments: board.lines, copperOnly: false, includesNetClass: false)
        case .boardArc:
            return arcProperties(for: ref, arcs: board.arcs, copperOnly: false, includesNetClass: false)
        case .connectionLine:
            return segmentProperties(for: ref, segments: board.connectionLines, copperOnly: false, includesNetClass: true, editable: false)
        case .via:
            guard let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("name", "Net", netDisplayName(via.netID)),
                editableNetClassProperty(for: via.netID),
                readOnlyProperty("span", "Span", viaSpanName(via)),
                editableLengthProperty("diameter", "Diameter", via.size),
                editableLengthProperty("positionX", "Position X", via.position.x),
                editableLengthProperty("positionY", "Position Y", via.position.y),
            ].compactMap { $0 }
        case .boardHole:
            guard let hole = hole(for: ref.id) else {
                return []
            }
            return [
                readOnlyProperty("name", "Net", netDisplayName(hole.netID)),
                editableNetClassProperty(for: hole.netID),
                readOnlyProperty("shape", "Shape", hole.shape.rawValue.capitalized),
                editableLengthProperty("diameter", "Diameter", hole.diameter),
                hole.shape == .slot ? editableLengthProperty("length", "Length", hole.effectiveLength) : nil,
                editableBoolProperty("plated", "Plated", hole.plated),
                editableLengthProperty("positionX", "Position X", hole.position.x),
                editableLengthProperty("positionY", "Position Y", hole.position.y),
            ].compactMap { $0 }
        case .plane:
            guard let plane = board.planes.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            let netOptions = sortedPlaneNetOptions()
            let netValue = plane.netID.map(normalizedID)
            return [
                netOptions.isEmpty || netValue == nil
                    ? readOnlyProperty("name", "Net", netDisplayName(plane.netID))
                    : editableChoiceProperty("net", "Net", value: netValue!, options: netOptions),
                editableNetClassProperty(for: plane.netID),
                editableLayerProperty("layer", "Layer", plane.layer, copperOnly: true),
                editableChoiceProperty(
                    "priority",
                    "Fill order",
                    value: String(plane.priority),
                    options: (0...20).map { HorizontalSelectionPropertyOption(id: String($0), title: String($0)) }
                ),
                editableBoolProperty("fromRules", "From rules", plane.fromRules),
                editableChoiceProperty(
                    "fill",
                    "Fill",
                    value: planeFillStyleID(plane.settings.fillStyle),
                    options: [
                        HorizontalSelectionPropertyOption(id: "solid", title: "Solid"),
                        HorizontalSelectionPropertyOption(id: "hatch", title: "Hatch"),
                    ]
                ),
                editableLengthProperty("minWidth", "Min width", Double(plane.settings.minWidth)),
                editableBoolProperty("keepOrphans", "Keep orphans", plane.settings.keepOrphans),
            ].compactMap { $0 }
        case .keepout:
            guard let keepout = board.keepouts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableTextProperty("keepoutClass", "Keepout class", keepout.keepoutClass),
                readOnlyProperty("layer", "Layer", keepout.allCopperLayers ? "All copper" : layerName(for: keepout.polygon.layer)),
            ].compactMap { $0 }
        case .dimension:
            guard let dimension = board.dimensions.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableLengthProperty("size", "Size", dimension.labelSize),
                editableChoiceProperty(
                    "mode",
                    "Mode",
                    value: dimension.mode.rawValue,
                    options: HorizontalDimensionMode.allCases.map {
                        HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.title)
                    }
                ),
            ].compactMap { $0 }
        case .text:
            guard let text = (board.texts + board.packageTexts).first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return textProperties(text) + [editableNetClassProperty(for: text.netID)].compactMap { $0 }
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            guard let polygon = boardPolygon(for: ref.id, in: board) else {
                return []
            }
            return [
                readOnlyProperty("net", "Net", netDisplayName(polygon.netID)),
                editableNetClassProperty(for: polygon.netID),
                editableLayerProperty("layer", "Layer", polygon.layer, copperOnly: false),
                readOnlyProperty("usage", "Usage", "Polygon"),
                readOnlyProperty("area", "Area", areaString(polygon.area)),
            ].compactMap { $0 }
        case .pad:
            guard let pad = board.packagePads.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("name", "Name", padLabel(for: pad)),
                readOnlyProperty("value", "Padstack", pad.metadata["Padstack"]),
                readOnlyProperty("padType", "Pad type", pad.metadata["Pad type"]),
                readOnlyProperty("net", "Net", netDisplayName(pad.netID)),
                editableNetClassProperty(for: pad.netID),
                editableLayerProperty("layer", "Layer", pad.layer, copperOnly: true),
            ].compactMap { $0 }
        case .boardPackage:
            guard let package = board.packages.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableComponentRefdesProperty(for: package),
                editableLengthProperty("positionX", "Position X", package.position.x),
                editableLengthProperty("positionY", "Position Y", package.position.y),
                editableAngleProperty("angle", "Angle", package.angle),
                editableBoolProperty("flipped", "Flipped", package.mirrored),
                editableBoolProperty("omitSilkscreen", "Omit silkscreen", package.omitSilkscreen),
                editableBoolProperty("omitOutline", "Omit outline", package.omitOutline),
                editableBoolProperty("fixed", "Fix package", package.fixed),
            ].compactMap { $0 }
        case .boardPanel:
            guard let panel = board.boardPanels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("name", "Board", panel.boardName),
                readOnlyProperty("omitOutline", "Omit outline", panel.omitOutline ? "Yes" : "No"),
            ].compactMap { $0 }
        case .boardDecal:
            guard let decal = board.decals.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("name", "Name", decal.name),
            ].compactMap { $0 }
        case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return []
        }
    }

    private func segmentProperties(
        for ref: HorizontalSelectableRef,
        segments: [HorizontalSegment],
        copperOnly: Bool,
        includesNetClass: Bool,
        editable: Bool = true
    ) -> [HorizontalSelectionProperty] {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }

        let net = segment.netID.flatMap { board.netDetails[normalizedID($0)] }
        let widthProperty = editable
            ? editableLengthProperty("width", "Width", segment.width)
            : readOnlyProperty("width", "Width", segment.width > 0 ? lengthString(segment.width) : nil)
        let layerProperty = editable
            ? editableLayerProperty("layer", "Layer", segment.layer, copperOnly: copperOnly)
            : readOnlyProperty("layer", "Layer", layerName(for: segment.layer))

        var properties = [
            readOnlyProperty("name", "Net", net?.name ?? netDisplayName(segment.netID)),
            layerProperty,
            widthProperty,
            includesNetClass ? editableNetClassProperty(for: segment.netID) : nil,
        ].compactMap { $0 }
        if let radius = segment.arc?.radius,
           let radiusProperty = readOnlyProperty("radius", "Radius", lengthString(radius)) {
            properties.append(radiusProperty)
        }
        if let length = readOnlyProperty("length", "Length", lengthString(segment.length)) {
            properties.append(length)
        }
        return properties
    }

    private func arcProperties(
        for ref: HorizontalSelectableRef,
        arcs: [HorizontalArc],
        copperOnly: Bool,
        includesNetClass: Bool,
        editable: Bool = true
    ) -> [HorizontalSelectionProperty] {
        guard let arc = arcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }

        let net = arc.netID.flatMap { board.netDetails[normalizedID($0)] }
        let widthProperty = editable
            ? editableLengthProperty("width", "Width", arc.width)
            : readOnlyProperty("width", "Width", arc.width > 0 ? lengthString(arc.width) : nil)
        let layerProperty = editable
            ? editableLayerProperty("layer", "Layer", arc.layer, copperOnly: copperOnly)
            : readOnlyProperty("layer", "Layer", layerName(for: arc.layer))

        return [
            readOnlyProperty("name", "Net", net?.name ?? netDisplayName(arc.netID)),
            layerProperty,
            widthProperty,
            includesNetClass ? editableNetClassProperty(for: arc.netID) : nil,
            readOnlyProperty("radius", "Radius", lengthString(arc.radius)),
            readOnlyProperty("length", "Length", lengthString(arc.length)),
        ].compactMap { $0 }
    }

    private func textProperties(_ text: HorizontalText) -> [HorizontalSelectionProperty] {
        [
            editableTextProperty("text", "Text", text.text, multiline: true),
            editableLengthProperty("size", "Size", text.size),
            editableLengthProperty("width", "Width", text.width),
            editableLayerProperty("layer", "Layer", text.layer, copperOnly: false),
            editableLengthProperty("positionX", "Position X", text.position.x),
            editableLengthProperty("positionY", "Position Y", text.position.y),
            editableAngleProperty("angle", "Angle", displayAngle(for: text)),
            editableBoolProperty("mirror", "Mirror", text.mirrored),
            editableBoolProperty("allowUpsideDown", "Allow upside-down", text.allowUpsideDown),
        ].compactMap { $0 }
    }

    private func readOnlyProperty(_ id: String, _ label: String, _ value: String?) -> HorizontalSelectionProperty? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        return HorizontalSelectionProperty(id: id, label: label, editor: .readOnly, value: .readOnly(value))
    }

    private func editableTextProperty(
        _ id: String,
        _ label: String,
        _ value: String,
        multiline: Bool = false
    ) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(
            id: id,
            label: label,
            editor: multiline ? .multilineText : .text,
            value: .text(value)
        )
    }

    private func editableBoolProperty(_ id: String, _ label: String, _ value: Bool) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(id: id, label: label, editor: .bool, value: .bool(value))
    }

    private func editableLengthProperty(_ id: String, _ label: String, _ value: Double) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(id: id, label: label, editor: .length, value: .length(value))
    }

    private func editableAngleProperty(_ id: String, _ label: String, _ value: Int) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(id: id, label: label, editor: .angle, value: .angle(value))
    }

    private func editableComponentRefdesProperty(for placement: HorizontalPlacement) -> HorizontalSelectionProperty? {
        guard let refdes = placement.componentDetails?.refdes else {
            return nil
        }
        return editableTextProperty("refdes", "Refdes", refdes)
    }

    private func editableLayerProperty(
        _ id: String,
        _ label: String,
        _ value: Int?,
        copperOnly: Bool
    ) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(
            id: id,
            label: label,
            editor: .layer(layerOptions(copperOnly: copperOnly, currentLayer: value)),
            value: .layer(value)
        )
    }

    private func editableChoiceProperty(
        _ id: String,
        _ label: String,
        value: String,
        options: [HorizontalSelectionPropertyOption]
    ) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(id: id, label: label, editor: .choice(options), value: .choice(value))
    }

    private func editableNetClassProperty(for netID: String?) -> HorizontalSelectionProperty? {
        guard let netID else {
            return nil
        }

        let normalizedNetID = normalizedID(netID)
        guard let net = board.netDetails[normalizedNetID] else {
            return nil
        }

        let options = netClassOptions()
        guard !options.isEmpty else {
            return readOnlyProperty("netClass", "Net class", net.netClassName)
        }

        let selectedID = net.netClassID.map(normalizedID) ?? Self.noNetClassChoiceID
        let optionIDs = Set(options.map(\.id))
        let value = optionIDs.contains(selectedID) ? selectedID : options[0].id
        return editableChoiceProperty("netClass", "Net class", value: value, options: options)
    }

    /// Copper span of a via, e.g. "Top Copper – Bottom Copper" (a blind or
    /// buried via spans fewer layers). The parse resolves the span into the
    /// ordered copper layers it touches; an empty list means it recorded no
    /// explicit span, which Horizon treats as through — all copper.
    private func viaSpanName(_ via: HorizontalMarker) -> String? {
        guard let first = via.connectedLayers.first, let last = via.connectedLayers.last else {
            return "All copper"
        }
        if first == last {
            return layerName(for: first)
        }
        return [layerName(for: first), layerName(for: last)]
            .compactMap { $0 }
            .joined(separator: " – ")
    }

    private func netClassOptions() -> [HorizontalSelectionPropertyOption] {
        netClasses.map { netClass in
            HorizontalSelectionPropertyOption(
                id: normalizedID(netClass.id),
                title: nonEmpty(netClass.name) ?? shortID(netClass.id)
            )
        }
    }

    /// Layers offered by an inspector layer picker: only copper layers the
    /// board's stackup actually has (a 2-layer board must not offer "Inner 5")
    /// and only user layers the board defines, by their user-given names. The
    /// current value is always listed even when it fails those filters, so the
    /// picker never shows an empty selection; "None" appears only when the
    /// object's layer is unset (it is a parse artifact, not a settable choice).
    private func layerOptions(copperOnly: Bool, currentLayer: Int?) -> [HorizontalSelectionPropertyOption] {
        let stackupCopper = Set(board.stackupLayers.map(\.layer).filter(HorizontalBoardLayers.isCopper))
        let definedUserLayers = Set(board.userLayers.map(\.id))
        let layers = HorizontalBoardLayers.all.filter { layer in
            if layer == currentLayer {
                return true
            }
            if copperOnly && !HorizontalBoardLayers.isCopper(layer) {
                return false
            }
            if HorizontalBoardLayers.isCopper(layer), !stackupCopper.isEmpty, !stackupCopper.contains(layer) {
                return false
            }
            if HorizontalBoardLayers.isUser(layer), !definedUserLayers.contains(layer) {
                return false
            }
            return true
        }
        let options = layers.map { layer in
            HorizontalSelectionPropertyOption(
                id: String(layer),
                title: layerName(for: layer) ?? "Layer \(layer)"
            )
        }
        guard currentLayer != nil else {
            return [HorizontalSelectionPropertyOption(id: "none", title: "None")] + options
        }
        return options
    }

    private func dispatchCanvasCommand(_ command: HorizontalCanvasCommand) {
        canvasCommandHandlers().dispatch(command)
    }

    private func canvasCommandActions() -> HorizontalCanvasCommandActions {
        canvasCommandHandlers().actions()
    }

    private func canvasCommandHandlers() -> HorizontalCanvasCommandHandlerSet {
        HorizontalCanvasCommandHandlerSet(
            isReadOnly: isReadOnly,
            hasInteraction: drawGraphicsState != nil || drawTrackState != nil || moveState != nil || pastePlacementState != nil,
            selectAll: selectAllObjects,
            selectNet: selectNetOfSelection,
            copySelection: { copySelectionToClipboard() },
            pasteSelection: { pasteClipboard() },
            duplicateSelection: { duplicateSelection() },
            deleteSelection: deleteSelection,
            highlightSelection: {
                onHighlightNetCommand(selectedNetIDs)
                onHighlightComponentCommand(selectedComponentIDs)
            },
            beginMove: { beginMove() },
            moveSelectionExactly: moveSelectionExactly,
            rotateSelection: rotateSelection,
            rotateSelectionAroundCenter: rotateSelectionAroundCenter,
            rotateSelectionArbitrary: rotateSelectionArbitrary,
            twirlSelection: twirlSelection,
            mirrorSelection: mirrorSelection,
            mirrorSelectionHorizontal: mirrorSelectionHorizontal,
            mirrorSelectionVertical: mirrorSelectionVertical,
            drawNetLine: nil,
            drawTrack: { beginDrawTrack() },
            drawGraphics: { beginDrawGraphics($0) },
            drawPlane: { beginDrawPlane() },
            selectLayer: { selectDrawingLayer($0) },
            selectBoardLayerView: { onSelectBoardLayerView($0) },
            definePlane: { definePlaneForSelection() },
            editPlane: { editPlaneForSelection() },
            convertPolygonToLineLoop: { convertPolygonToLineLoopForSelection() },
            convertLineLoopToPolygon: { convertLineLoopToPolygonForSelection() },
            addText: { addText() },
            editText: { editSelectedText() },
            openDatasheet: { openSelectedDatasheet() },
            toggleSmash: { toggleSmashSelection() },
            smashSilkscreenGraphics: { smashSilkscreenGraphicsSelection() },
            toggleOmitSilkscreen: { togglePackageFlag(\.omitSilkscreen, actionName: "Omit Silkscreen") },
            toggleOmitOutline: { togglePackageFlag(\.omitOutline, actionName: "Omit Outline") },
            toggleFixed: { togglePackageFlag(\.fixed, actionName: "Fix Package") },
            flipTrackPosture: drawTrackState != nil ? { flipTrackPosture() } : nil,
            enterTrackWidth: drawTrackState != nil ? { enterTrackWidth() } : nil,
            toggleVia: canToggleVia ? { toggleVia() } : nil,
            showToolSettings: { onShowToolSettings() },
            editSymbolPinNames: nil,
            toggleRectanglePlacementMode: toggleRectanglePlacementMode,
            moveSelectionBy: moveSelectionByGrid,
            commitInteraction: {
                if pastePlacementState != nil {
                    commitPastePlacement(at: lastCursorWorldPoint)
                } else if drawGraphicsState != nil {
                    commitDrawGraphicsAtCursor()
                } else if drawTrackState != nil {
                    commitDrawTrack()
                } else {
                    commitMove()
                }
            },
            cancelInteraction: {
                if pastePlacementState != nil {
                    cancelPastePlacement()
                } else if drawGraphicsState != nil {
                    endDrawGraphicsInteraction()
                } else if drawTrackState != nil {
                    cancelDrawTrack()
                } else {
                    cancelMove()
                }
            }
        )
    }

    private func updateCursor(at point: HorizontalPoint?, worldUnitsPerPoint: Double) {
        // Guard each @State write with an equality check. SwiftUI doesn't
        // dedupe @State assignments for Equatable types — every write triggers
        // a body re-render. During pan/zoom the cursor fires events at the
        // gesture rate, and unconditional writes cause body to be recomputed
        // on every tick, stalling the Metal draw loop.
        if lastCursorWorldPoint != point {
            lastCursorWorldPoint = point
        }

        if moveState != nil {
            HorizontalMoveRateDiagnostics.mark(point == nil ? .cursorNil : .cursorEvent)
        }

        guard let point else {
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if var state = pastePlacementState {
            if state.cursor != point {
                state.cursor = point
                pastePlacementState = state
            }
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if let moveState {
            if moveState.tracksCursor {
                updateMove(to: point)
            }
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if var state = drawGraphicsState {
            state.cursor = point
            drawGraphicsState = state
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if var state = drawTrackState {
            state.cursor = point
            drawTrackState = state
            #if canImport(HorizontalPushShoveRouter)
            if isRouterMode, state.anchor != nil {
                routerRefreshPreview(at: point)
            }
            #endif
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        let newHover = hitSelectable(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
        if hoveredObject != newHover {
            hoveredObject = newHover
        }
    }

    private func hitSelectable(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> HorizontalSelectableRef? {
        boardSelectableScene().hitSelectable(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
    }

    private func targetMenuItems(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> [HorizontalSelectionTargetItem] {
        HorizontalCanvasModeSupport.targetMenuItems(
            scene: boardSelectableScene(),
            at: point,
            worldUnitsPerPoint: worldUnitsPerPoint,
            itemForRef: { hudItem(for: $0) }
        )
    }

    /// Action submenu for one disambiguation candidate — per-object
    /// right-click menu. Implemented actions are wired; the rest are shown as
    /// disabled `.todo` items so the full menu is discoverable (Horizon parity).
    /// "Select" is first so picking one of several overlapping objects stays a
    /// quick two-click. Ordering follows menu.
    private func targetItemMenuEntries(for ref: HorizontalSelectableRef) -> [HorizontalTargetItemMenuEntry] {
        let writable = !isReadOnly
        let isPackage = ref.type == .boardPackage
        let harvestable = isClipboardHarvestable(ref)
        let hasNet = refHasNet(ref)

        var entries: [HorizontalTargetItemMenuEntry] = [.select(title: "Select"), .separator]

        #if os(macOS)
        // Edit text inline (reopens the placement popover on the existing text).
        if writable, ref.type == .text {
            entries.append(.command(title: "Edit…", .editText))
        }
        #endif

        // Clipboard
        if writable, harvestable { entries.append(.command(title: "Duplicate", .duplicateSelection)) }
        if writable, !boardClipboard.isEmpty { entries.append(.command(title: "Paste relative", .pasteSelection)) }
        if harvestable { entries.append(.command(title: "Copy", .copySelection)) } // copy is safe read-only

        // Move ▸ (transforms). "Move" covers everything movable; rotate/mirror are
        // only offered for types those passes actually transform (dimensions and
        // decals can move but not yet rotate/mirror).
        if writable, isTransformable(ref) {
            let rotatable = isRotatableOrMirrorable(ref)
            var move: [HorizontalTargetItemMenuEntry] = [.command(title: "Move", .moveSelection)]
            if rotatable {
                move.append(contentsOf: [
                    .command(title: "Rotate", .rotateSelectionAroundCenter),
                    .command(title: "Mirror X", .mirrorSelectionHorizontal),
                    .command(title: "Mirror Y", .mirrorSelectionVertical),
                ])
            }
            move.append(.separator)
            move.append(.command(title: "Move exactly", .moveSelectionExactly))
            if rotatable { move.append(.command(title: "Rotate arbitrary", .rotateSelectionArbitrary)) }
            move.append(contentsOf: [
                .todo(title: "Move by keyboard"),
                .todo(title: "Scale"),
            ])
            if rotatable {
                move.append(.separator)
                move.append(contentsOf: [
                    .command(title: "Rotate around cursor", .rotateSelection),
                    .command(title: "Mirror around cursor", .mirrorSelection),
                ])
            }
            entries.append(.submenu(title: "Move", move))
        }

        // Package operations (smash / omit / fix). "Add text" / "Filter
        // airwires" are canvas-level and live in the menu bar.
        if writable, isPackage {
            var packageEntries: [HorizontalTargetItemMenuEntry] = [
                .command(title: packageIsSmashed(ref) ? "Unsmash Text" : "Smash Text", .toggleSmash),
            ]
            // Horizon gates "smash silkscreen graphics" on omit_silkscreen == false.
            if !packageFlag(ref, \.omitSilkscreen) {
                packageEntries.append(.command(title: "Smash Silkscreen Graphics", .smashSilkscreenGraphics))
            }
            packageEntries.append(contentsOf: [
                .separator,
                .command(title: packageFlag(ref, \.omitSilkscreen) ? "Show Silkscreen" : "Omit Silkscreen", .toggleOmitSilkscreen),
                .command(title: packageFlag(ref, \.omitOutline) ? "Show Outline" : "Omit Outline", .toggleOmitOutline),
                .separator,
                .command(title: packageFlag(ref, \.fixed) ? "Unfix Package" : "Fix Package", .toggleFixed),
            ])
            entries.append(.submenu(title: "Package", packageEntries))
        }

        // Polygon → plane (polygon `usage`). Bare polygon: offer to make
        // it a copper plane. Already a plane outline: jump to editing that plane.
        if writable, isPolygonRef(ref) {
            if planeBackedByPolygon(ref.id, in: board) != nil {
                entries.append(.command(title: "Edit Plane", .editPlane))
            } else {
                entries.append(.command(title: "Define Plane", .definePlane))
            }
        }

        // Polygon ↔ line loop (reciprocal tools).
        if writable, isConvertiblePolygon(ref) {
            entries.append(.command(title: "Convert to Line Loop", .convertPolygonToLineLoop))
        }
        if writable, ref.type == .boardLine || ref.type == .boardArc || ref.type == .junction {
            entries.append(.command(title: "Convert to Polygon", .convertLineLoopToPolygon))
        }

        // Destructive
        entries.append(.separator)
        if writable, isDeletable(ref) { entries.append(.command(title: "Delete", .deleteSelection)) }
        if writable, hasNet { entries.append(.todo(title: "Disconnect")) }

        // Net
        if hasNet {
            entries.append(.separator)
            entries.append(.command(title: "Highlight Net", .highlightNet))
            entries.append(.command(title: "Select Net", .selectNet))
        }

        // Pool / datasheet (packages)
        if isPackage {
            entries.append(.separator)
            entries.append(.todo(title: "Show in pool manager"))
            entries.append(.todo(title: "Show in project pool manager"))
            if packageDatasheetURL(for: ref) != nil {
                entries.append(.command(title: "Open Datasheet", .openDatasheet))
            } else {
                entries.append(.todo(title: "Open datasheet"))
            }
        }

        return entries
    }

    /// Standalone copper / graphics the clipboard can clone. Resolves the ref
    /// against the exact pools `harvestClipboard` reads, so Copy/Duplicate is
    /// only offered when it would actually clone something — package-owned text /
    /// holes (which also surface as `.text` / `.boardHole` candidates but live in
    /// `packageTexts` / `packageHoles`) are correctly excluded.
    private func isClipboardHarvestable(_ ref: HorizontalSelectableRef) -> Bool {
        let id = normalizedID(ref.id)
        func has<T: Identifiable>(_ array: [T]) -> Bool where T.ID == String {
            array.contains { normalizedID($0.id) == id }
        }
        switch ref.type {
        case .track: return has(board.tracks)
        case .boardNetTie: return has(board.netTies)
        case .boardLine: return has(board.lines)
        case .boardArc: return has(board.arcs)
        case .via: return has(board.vias)
        case .text: return has(board.texts)
        case .boardHole: return has(board.holes)
        case .polygonVertex, .polygonEdge, .polygonArcCenter: return has(board.polygons)
        default: return false
        }
    }

    /// Objects the Move transform operates on (the broadest set — includes
    /// dimensions and decals, which can be moved).
    private func isTransformable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .track, .boardNetTie, .boardLine, .boardArc, .via, .text, .boardHole,
             .polygonVertex, .polygonEdge, .polygonArcCenter, .boardPackage, .dimension, .boardDecal:
            return true
        default:
            return false
        }
    }

    /// Objects the rotate/mirror passes actually transform — `isTransformable`
    /// minus dimensions and decals (which `rotateSelectedObjects` /
    /// `mirrorSelectedObjects` treat as no-ops), so we don't offer dead actions.
    private func isRotatableOrMirrorable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .track, .boardNetTie, .boardLine, .boardArc, .via, .text, .boardHole,
             .polygonVertex, .polygonEdge, .polygonArcCenter, .boardPackage:
            return true
        default:
            return false
        }
    }

    /// Whether `deleteSelectedObjects` can actually remove this ref's type (pads
    /// and connected junctions are no-ops there, so we don't offer Delete).
    private func isDeletable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .pad, .junction,
             .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine,
             .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie,
             .schematicSymbol, .symbolPin:
            return false
        default:
            return true
        }
    }

    private func refHasNet(_ ref: HorizontalSelectableRef) -> Bool {
        netID(for: ref) != nil
    }

    /// Resolves a board package ref to its part's datasheet URL (already loaded
    /// into `componentDetails` from the pool), or nil when there's no usable URL.
    private func packageDatasheetURL(for ref: HorizontalSelectableRef) -> URL? {
        guard ref.type == .boardPackage,
              let package = board.packages.first(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              let datasheet = package.componentDetails?.datasheet else {
            return nil
        }
        return Self.datasheetURL(datasheet)
    }

    /// Turns a datasheet attribute string into an openable URL: an explicit
    /// scheme is used as-is; a bare "host/path" is assumed https. nil when blank
    /// or not URL-shaped.
    private static func datasheetURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.contains("."), !trimmed.contains(" "), let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return nil
    }

    /// Opens the datasheet of the selected package(s) — the user explicitly
    /// invokes this from the package's menu, so it's a deliberate open of their
    /// own part's datasheet link.
    private func openSelectedDatasheet() {
        guard let url = uniqueRefs(selectedObjects).lazy.compactMap({ packageDatasheetURL(for: $0) }).first else {
            return
        }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    private func packageIsSmashed(_ ref: HorizontalSelectableRef) -> Bool {
        board.packages.first { normalizedID($0.id) == normalizedID(ref.id) }?.smashed ?? false
    }

    /// Smash / Unsmash the selected package(s) (tool_smash). Smash
    /// extracts the package's own silk text into independently editable
    /// `fromSmash` board text and hides the package silk; Unsmash removes the
    /// copies and re-derives the package silk from the pool.
    private func toggleSmashSelection() {
        guard !isReadOnly else { return }
        let packageRefs = uniqueRefs(selectedObjects).filter { $0.type == .boardPackage }
        guard !packageRefs.isEmpty else { return }

        let previous = editedBoard ?? sourceBoard
        var draft = previous
        var changed = false
        var smashedAny = false
        var smashedPackageIDs = Set<String>()
        for ref in packageRefs {
            let result = toggleSmash(ref, in: &draft)
            changed = result.changed || changed
            if result.smashed {
                smashedAny = true
                smashedPackageIDs.insert(normalizedID(ref.id))
            }
        }
        guard changed else { return }

        registerUndoSnapshot(previous, actionName: smashedAny ? "Smash" : "Unsmash")
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        // After smashing, select the new editable from-smash texts so they can be
        // immediately repositioned / edited.
        if smashedAny {
            selectedObjects = draft.packageTexts.compactMap { text in
                guard text.fromSmash,
                      let pkg = packageID(forGeometryID: text.id).map(normalizedID),
                      smashedPackageIDs.contains(pkg) else {
                    return nil
                }
                return HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer)
            }
        }
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// Toggles one package. Returns whether anything changed and whether the net
    /// effect was a smash (true) or unsmash (false), for the undo action name.
    private func toggleSmash(_ ref: HorizontalSelectableRef, in board: inout HorizontalBoard) -> (changed: Bool, smashed: Bool) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return (false, false)
        }
        let pkgID = normalizedID(board.packages[index].id)
        func belongs(_ text: HorizontalText) -> Bool {
            packageID(forGeometryID: text.id).map(normalizedID) == pkgID
        }
        // Smash operates on silkscreen text only (tool_smash); assembly
        // and other package text stays package-owned.
        func isSilk(_ text: HorizontalText) -> Bool {
            text.layer.map(HorizontalBoardLayers.isSilkscreen) == true
        }

        if board.packages[index].smashed {
            // UNSMASH: drop the editable copies and re-derive the package silk
            // (silkscreen only — non-silk package text was never smashed).
            board.packageTexts.removeAll { $0.fromSmash && belongs($0) }
            board.packages[index].smashed = false
            if let poolURL {
                let silk = HorizontalBoard.packageSilkTexts(
                    for: board.packages[index],
                    poolURL: poolURL,
                    copperLayerCount: board.copperLayerCount
                ).filter(isSilk)
                let present = Set(board.packageTexts.map { normalizedID($0.id) })
                board.packageTexts.append(contentsOf: silk.filter { !present.contains(normalizedID($0.id)) })
            }
            return (true, false)
        }

        // SMASH: copy the package's own SILKSCREEN text into editable `fromSmash`
        // board text and remove the pool silk (now represented by the copies).
        let poolSilk = board.packageTexts.filter { !$0.fromSmash && belongs($0) && isSilk($0) }
        guard !poolSilk.isEmpty else {
            return (false, false)
        }
        board.packageTexts.removeAll { !$0.fromSmash && belongs($0) && isSilk($0) }
        let prefix = board.packages[index].id
        for var text in poolSilk {
            text.id = "\(prefix)/text/\(UUID().uuidString.lowercased())"
            text.fromSmash = true
            board.packageTexts.append(text)
        }
        board.packages[index].smashed = true
        return (true, true)
    }

    // MARK: - Package flags (omit silkscreen / omit outline / fixed) + smash graphics

    private func package(for ref: HorizontalSelectableRef) -> HorizontalPlacement? {
        board.packages.first { normalizedID($0.id) == normalizedID(ref.id) }
    }

    private func packageFlag(_ ref: HorizontalSelectableRef, _ keyPath: KeyPath<HorizontalPlacement, Bool>) -> Bool {
        package(for: ref)?[keyPath: keyPath] ?? false
    }

    /// True when `ref` names a package marked `fixed` in `board`. Fixed packages
    /// are excluded from move/delete (`fixed` flag).
    private func isFixedPackage(_ ref: HorizontalSelectableRef, in board: HorizontalBoard) -> Bool {
        guard ref.type == .boardPackage else { return false }
        return board.packages.first { normalizedID($0.id) == normalizedID(ref.id) }?.fixed == true
    }

    /// Toggles a per-package boolean flag (omit_silkscreen / omit_outline / fixed)
    /// on every selected package. Geometry is untouched — the render gates by the
    /// flag (omit) or move/delete consults it (fixed).
    private func togglePackageFlag(_ keyPath: WritableKeyPath<HorizontalPlacement, Bool>, actionName: String) {
        guard !isReadOnly else { return }
        let refs = uniqueRefs(selectedObjects).filter { $0.type == .boardPackage }
        guard !refs.isEmpty else { return }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        var changed = false
        for ref in refs {
            if let index = draft.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                draft.packages[index][keyPath: keyPath].toggle()
                changed = true
            }
        }
        guard changed else { return }
        registerUndoSnapshot(previous, actionName: actionName)
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// "Smash silkscreen graphics" (smash_package_silkscreen_graphics):
    /// moves each selected package's own silkscreen lines/arcs/polygons to the
    /// board as editable graphics and sets omit_silkscreen (so the package's copy
    /// is hidden — only the editable board copies render).
    private func smashSilkscreenGraphicsSelection() {
        guard !isReadOnly else { return }
        let refs = uniqueRefs(selectedObjects).filter { $0.type == .boardPackage }
        guard !refs.isEmpty else { return }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        var changed = false
        for ref in refs {
            changed = smashSilkscreenGraphics(ref, in: &draft) || changed
        }
        guard changed else { return }
        registerUndoSnapshot(previous, actionName: "Smash Silkscreen Graphics")
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    private func smashSilkscreenGraphics(_ ref: HorizontalSelectableRef, in board: inout HorizontalBoard) -> Bool {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return false
        }
        // Horizon refuses to smash again once silkscreen is already omitted —
        // otherwise the lines/arcs would be copied a second time (duplicates).
        guard !board.packages[index].omitSilkscreen else { return false }
        let pkgID = normalizedID(board.packages[index].id)
        func belongs(_ id: String) -> Bool { packageID(forGeometryID: id).map(normalizedID) == pkgID }
        func isSilk(_ layer: Int?) -> Bool { layer.map(HorizontalBoardLayers.isSilkscreen) == true }

        // smash_package_silkscreen_graphics copies silk LINES and ARCS
        // only (not polygons or text); the package's copy is then hidden via
        // omit_silkscreen and only these board-level editable copies render.
        let silkLines = board.packageLines.filter { belongs($0.id) && isSilk($0.layer) }
        let silkArcs = board.packageArcs.filter { belongs($0.id) && isSilk($0.layer) }
        guard !silkLines.isEmpty || !silkArcs.isEmpty else {
            return false
        }

        func newID() -> String { UUID().uuidString.lowercased() }
        // Board lines/arcs reference junctions; ensure one exists at each endpoint
        // (the applicator resolves the point back to the junction id). Junctions
        // incident to a line/arc survive the connectivity vacuum. Reusing an
        // existing junction at the same coordinate keeps that resolution
        // unambiguous (no two junctions share a position).
        func ensureJunction(_ point: HorizontalPoint) {
            let key = pointKey(point)
            if !board.junctions.values.contains(where: { pointKey($0) == key }) {
                board.junctions[newID()] = point
            }
        }

        for var line in silkLines {
            ensureJunction(line.from)
            ensureJunction(line.to)
            line.id = newID()
            board.lines.append(line)
        }
        for var arc in silkArcs {
            ensureJunction(arc.from)
            ensureJunction(arc.to)
            ensureJunction(arc.center)
            arc.id = newID()
            board.arcs.append(arc)
        }
        board.packages[index].omitSilkscreen = true
        return true
    }

    private func setSelectedObject(_ ref: HorizontalSelectableRef?) {
        selectedObjects = ref.map { [$0] } ?? []
        selectedUnplacedObjectID = nil
        publishSelectionContext()
    }

    private func selectAllObjects() {
        guard moveState == nil, pastePlacementState == nil else {
            return
        }
        selectedObjects = boardSelectableScene().refs()
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        publishSelectionContext()
    }

    /// Selects every selectable copper object whose net matches the current
    /// selection's net(s) — "select net" (⇧L). Connectivity (Phase 1) keeps the
    /// nets accurate, so this picks up the whole electrical net.
    private func selectNetOfSelection() {
        guard moveState == nil, pastePlacementState == nil else {
            return
        }
        let nets = selectedNetIDs
        guard !nets.isEmpty else {
            return
        }
        let matching = boardSelectableScene().refs().filter { ref in
            guard let net = netID(for: ref).map(normalizedID) else { return false }
            return nets.contains(net)
        }
        guard !matching.isEmpty else {
            return
        }
        selectedObjects = matching
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        publishSelectionContext()
    }

    // MARK: - Copy / Paste / Duplicate

    private func copySelectionToClipboard() {
        let (items, bboxMin) = harvestClipboard(selectedObjects, from: board)
        guard !items.isEmpty else { return }
        boardClipboard = items
        // Anchor on the cursor at copy time so Paste reproduces the geometry's
        // exact offset relative to the cursor (paste offset = cursorNow − anchor).
        // Falls back to the selection's lower-left corner if the cursor is unknown.
        boardClipboardAnchor = lastCursorWorldPoint ?? bboxMin
    }

    /// Begins interactive paste: the clipboard contents become a ghost that
    /// follows the cursor. A click / Return commits it (`commitPastePlacement`),
    /// Esc cancels (`cancelPastePlacement`). Nothing is added until commit.
    private func pasteClipboard() {
        guard !isReadOnly,
              moveState == nil,
              drawTrackState == nil,
              drawGraphicsState == nil,
              pastePlacementState == nil,
              !boardClipboard.isEmpty else { return }
        // Anchor on the cursor at copy time; the ghost keeps that relative offset.
        let anchor = boardClipboardAnchor ?? lastCursorWorldPoint ?? .zero
        let cursor = lastCursorWorldPoint ?? anchor
        selectedObjects = []
        hoveredObject = nil
        pastePlacementState = PastePlacementState(items: boardClipboard, anchor: anchor, cursor: cursor)
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Commits the in-flight paste ghost at `point` (the click location) — or its
    /// last cursor position when committed via Return.
    private func commitPastePlacement(at point: HorizontalPoint?) {
        guard let state = pastePlacementState else { return }
        let offset = (point ?? state.cursor) - state.anchor
        pastePlacementState = nil
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        let refs = appendClipboardClones(state.items, offset: offset, into: &draft)
        guard !refs.isEmpty else {
            publishCanvasCommandActions()
            return
        }
        registerUndoSnapshot(previous, actionName: "Paste")
        selectedObjects = refs
        hoveredObject = nil
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Cancels the in-flight paste ghost (Esc). Nothing was committed, so this
    /// just drops the placement state; the ghost disappears on the next render.
    private func cancelPastePlacement() {
        guard pastePlacementState != nil else { return }
        pastePlacementState = nil
        publishCanvasCommandActions()
    }

    private func duplicateSelection() {
        guard !isReadOnly, moveState == nil, !selectedObjects.isEmpty else { return }
        let (items, _) = harvestClipboard(selectedObjects, from: board)
        guard !items.isEmpty else { return }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        let refs = appendClipboardClones(items, offset: duplicateOffset, into: &draft)
        guard !refs.isEmpty else { return }
        registerUndoSnapshot(previous, actionName: "Duplicate")
        selectedObjects = refs
        hoveredObject = nil
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// Fixed nudge for Duplicate (and the Paste fallback when there's no cursor):
    /// 1 mm down-right, so the clone is visible and easy to drag off the original.
    private var duplicateOffset: HorizontalPoint { HorizontalPoint(x: 1_000_000, y: -1_000_000) }

    /// Collects the full objects behind the selected refs (deduping polygons),
    /// plus their bounding-box minimum (paste anchor). Only standalone copper /
    /// graphics are harvested.
    private func harvestClipboard(
        _ refs: [HorizontalSelectableRef],
        from board: HorizontalBoard
    ) -> (items: [BoardClipboardItem], anchor: HorizontalPoint?) {
        var items = [BoardClipboardItem]()
        var seenPolygons = Set<String>()
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var found = false
        func note(_ points: [HorizontalPoint]) {
            for p in points { minX = min(minX, p.x); minY = min(minY, p.y); found = true }
        }
        func match<T: Identifiable>(_ array: [T], _ ref: HorizontalSelectableRef) -> T? where T.ID == String {
            array.first { normalizedID($0.id) == normalizedID(ref.id) }
        }

        for ref in uniqueRefs(refs) {
            switch ref.type {
            case .track:
                if let t = match(board.tracks, ref) { items.append(.track(t)); note([t.from, t.to]) }
            case .boardNetTie:
                if let t = match(board.netTies, ref) { items.append(.netTie(t)); note([t.from, t.to]) }
            case .boardLine:
                if let l = match(board.lines, ref) { items.append(.line(l)); note([l.from, l.to]) }
            case .boardArc:
                if let a = match(board.arcs, ref) { items.append(.arc(a)); note([a.from, a.to, a.center]) }
            case .via:
                if let v = match(board.vias, ref) {
                    let vid = normalizedID(v.id)
                    let holes = board.viaHoles.filter { normalizedID($0.id) == vid || normalizedID($0.id).hasPrefix("\(vid)/") }
                    items.append(.via(v, holes)); note([v.position])
                }
            case .text:
                if let t = match(board.texts, ref) { items.append(.text(t)); note([t.position]) }
            case .boardHole:
                if let h = match(board.holes, ref) { items.append(.hole(h)); note([h.position]) }
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                if seenPolygons.insert(normalizedID(ref.id)).inserted, let poly = match(board.polygons, ref) {
                    items.append(.polygon(poly)); note(poly.polygonVertices.map(\.position))
                }
            default:
                break
            }
        }
        return (items, found ? HorizontalPoint(x: minX, y: minY) : nil)
    }

    /// Appends fresh-id, `offset`-translated clones of `items` to `board` and
    /// returns refs to them (for selecting the result). Geometry is translated
    /// directly (not via the connectivity-dragging move funcs, which would also
    /// move the originals the clones overlap).
    private func appendClipboardClones(
        _ items: [BoardClipboardItem],
        offset: HorizontalPoint,
        into board: inout HorizontalBoard,
        idPrefix: String? = nil
    ) -> [HorizontalSelectableRef] {
        var refs = [HorizontalSelectableRef]()
        // For the live placement ghost, deterministic ids ("paste-preview-N")
        // keep the metal buckets stable across body passes; a real paste/
        // duplicate uses fresh UUIDs.
        var previewCounter = 0
        func newID() -> String {
            if let idPrefix {
                previewCounter += 1
                return "\(idPrefix)-\(previewCounter)"
            }
            return UUID().uuidString.lowercased()
        }
        func shift(_ p: HorizontalPoint) -> HorizontalPoint { p + offset }

        for item in items {
            switch item {
            case .track(var t):
                t.id = newID(); t.from = shift(t.from); t.to = shift(t.to); t.center = t.center.map(shift)
                board.tracks.append(t)
                refs.append(HorizontalSelectableRef(id: t.id, type: .track, layer: t.layer))
            case .netTie(var t):
                t.id = newID(); t.from = shift(t.from); t.to = shift(t.to); t.center = t.center.map(shift)
                board.netTies.append(t)
                refs.append(HorizontalSelectableRef(id: t.id, type: .boardNetTie, layer: t.layer))
            case .line(var l):
                l.id = newID(); l.from = shift(l.from); l.to = shift(l.to); l.center = l.center.map(shift)
                board.lines.append(l)
                refs.append(HorizontalSelectableRef(id: l.id, type: .boardLine, layer: l.layer))
            case .arc(var a):
                a.id = newID(); a.from = shift(a.from); a.to = shift(a.to); a.center = shift(a.center)
                board.arcs.append(a)
                refs.append(HorizontalSelectableRef(id: a.id, type: .boardArc, layer: a.layer))
            case .via(var v, let holes):
                let oldVid = normalizedID(v.id)
                let newVid = newID()
                v.id = newVid; v.position = shift(v.position)
                board.vias.append(v)
                for var h in holes {
                    let hn = normalizedID(h.id)
                    let suffix = hn == oldVid ? "" : (hn.hasPrefix("\(oldVid)/") ? String(h.id.dropFirst(oldVid.count)) : "/hole")
                    h.id = newVid + suffix
                    h.position = shift(h.position)
                    board.viaHoles.append(h)
                }
                refs.append(HorizontalSelectableRef(id: newVid, type: .via))
            case .text(var t):
                t.id = newID(); t.position = shift(t.position)
                board.texts.append(t)
                refs.append(HorizontalSelectableRef(id: t.id, type: .text, layer: t.layer))
            case .hole(var h):
                h.id = newID(); h.position = shift(h.position)
                board.holes.append(h)
                refs.append(HorizontalSelectableRef(id: h.id, type: .boardHole))
            case .polygon(var poly):
                poly.id = newID()
                poly.polygonVertices = poly.polygonVertices.map {
                    var v = $0; v.position = shift(v.position); v.arcCenter = shift(v.arcCenter); return v
                }
                board.polygons.append(poly)
                refs.append(HorizontalSelectableRef(id: poly.id, type: .polygonVertex))
            }
        }
        return refs
    }

    private func updateSelection(with ref: HorizontalSelectableRef?, action: HorizontalSelectionClickAction) {
        guard let updated = HorizontalCanvasModeSupport.updatedSelection(
            current: selectedObjects,
            ref: ref,
            action: action
        ) else {
            return
        }
        selectedObjects = updated
        selectedUnplacedObjectID = nil
        publishSelectionContext()
    }

    private func updateSelection(with refs: [HorizontalSelectableRef], action: HorizontalSelectionClickAction) {
        guard let updated = HorizontalCanvasModeSupport.updatedSelection(
            current: selectedObjects,
            refs: refs,
            action: action
        ) else {
            return
        }
        selectedObjects = updated
        selectedUnplacedObjectID = nil
        publishSelectionContext()
    }

    private func selectUnplacedObject(_ object: HorizontalUnplacedObject) {
        selectedObjects = []
        hoveredObject = nil
        selectedUnplacedObjectID = object.id
        publishSelectionContext()
    }

    private func uniqueRefs(_ refs: [HorizontalSelectableRef]) -> [HorizontalSelectableRef] {
        HorizontalCanvasModeSupport.uniqueRefs(refs)
    }

    private func beginMove(tracksCursor: Bool = true, editTextRefOnCommit: String? = nil) {
        guard pastePlacementState == nil else { return }
        let selectedCount = selectedObjects.count
        var timings = [(String, UInt64)]()
        func measure<T>(_ label: String, _ body: () -> T) -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = body()
            timings.append((label, elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)))
            return value
        }

        let originalBoard = measure("board snapshot") { board }
        let moveSelection = measure("expand selection") {
            // Fixed packages don't move (tool_move filters them out).
            expandedBoardMoveSelection(selectedObjects, in: originalBoard)
                .filter { !isFixedPackage($0, in: originalBoard) }
        }
        // Nothing movable (e.g. only a fixed package selected): leave the
        // selection intact and don't start a move.
        guard !moveSelection.isEmpty else { return }
        let fallbackSelectionCenter = lastCursorWorldPoint == nil
            ? measure("selection center") {
                HorizontalCanvasModeSupport.selectionCenter(for: moveSelection, anchorPoints: selectionAnchorPoints)
            }
            : nil
        let startPoint = measure("start point") {
            HorizontalCanvasModeSupport.moveStartPoint(
                modeName: "board",
                isReadOnly: isReadOnly,
                moveIsActive: moveState != nil,
                selectedObjects: moveSelection,
                lastCursorWorldPoint: lastCursorWorldPoint,
                selectionCenter: { fallbackSelectionCenter }
            )
        }
        guard let start = startPoint else {
            HorizontalMoveStartDiagnostics.report(
                modeName: "board",
                tracksCursor: tracksCursor,
                selectedCount: selectedCount,
                expandedCount: moveSelection.count,
                details: "aborted",
                timings: timings
            )
            return
        }
        measure("select move set") {
            selectedObjects = moveSelection
        }
        let snapTargets = measure("snap targets") { boardSnapTargets() }
        let residentMovePlan = measure("resident plan") {
            boardResidentMovePlan(for: moveSelection, in: originalBoard)
        }
        measure("state assign") {
            moveState = MoveState(
                startPoint: start,
                lastPoint: start,
                originalBoard: originalBoard,
                tracksCursor: tracksCursor,
                snapTargets: snapTargets,
                residentMovePlan: residentMovePlan,
                editTextRefOnCommit: editTextRefOnCommit
            )
            hoveredObject = nil
        }
        HorizontalMoveRateDiagnostics.beginMove(
            tracksCursor: tracksCursor,
            selectedCount: moveSelection.count,
            details: "board translated \(residentMovePlan.translatedRefs.count), segments \(residentMovePlan.segmentMoves.count), unsupported \(residentMovePlan.unsupportedRefs.count)"
        )
        measure("publish selection") {
            publishSelectionContext()
        }
        HorizontalMoveStartDiagnostics.report(
            modeName: "board",
            tracksCursor: tracksCursor,
            selectedCount: selectedCount,
            expandedCount: moveSelection.count,
            details: "translated \(residentMovePlan.translatedRefs.count), segments \(residentMovePlan.segmentMoves.count), unsupported \(residentMovePlan.unsupportedRefs.count), snap \(snapTargets.count)",
            timings: timings
        )
    }

    private func updateMove(to point: HorizontalPoint) {
        guard !isReadOnly,
              var state = moveState else {
            return
        }
        HorizontalMoveRateDiagnostics.mark(.moveAttempt)

        guard point != state.lastPoint else {
            HorizontalMoveRateDiagnostics.mark(.moveNoop)
            return
        }

        state.lastPoint = point
        moveState = state
        HorizontalMoveRateDiagnostics.mark(.moveAccepted)
    }

    private func commitMove() {
        guard !isReadOnly,
              let state = moveState else {
            return
        }
        let selectedCount = selectedObjects.count
        let plan = state.residentMovePlan
        var timings = [(String, UInt64)]()
        func measure<T>(_ label: String, _ body: () -> T) -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = body()
            timings.append((label, elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)))
            return value
        }

        // The place-text-then-edit flow rides the move machinery: capture its ref
        // so that on commit we open the inline editor instead of registering a
        // "Move" undo (the placement is finalized as a single "Add Text" step, or
        // reverted entirely, by the popover).
        #if os(macOS)
        let editTextRef = state.editTextRefOnCommit
        #else
        let editTextRef: String? = nil
        #endif
        let totalDelta = measure("delta") {
            state.lastPoint - state.startPoint
        }
        // A committed package move (and the tracks it drags along) doesn't reliably
        // survive the preserved metal scene: the cached buckets stay built from the
        // pre-move board, so the part and its tracks keep rendering at their old
        // spot until the next full rebuild (reopening the file fixes it). The data
        // is correct — only the live render is stale. Force a scene rebuild from the
        // committed board whenever a package moved so the render matches the data.
        let movesPackage = selectedObjects.contains { $0.type == .boardPackage }
        let canPreserveCommittedMetalScene = drawsBoardLinesInMetal
            && plan.isPatchable
            && !movesPackage
            && selectedObjects.allSatisfy(isBoardMetalMovePatchable)
        if totalDelta == .zero {
            measure("clear move state") {
                moveState = nil
            }
            measure("publish selection") {
                publishSelectionContext()
            }
            HorizontalMoveRateDiagnostics.endMove(committed: false)
            HorizontalMoveCommitDiagnostics.report(
                modeName: "board",
                selectedCount: selectedCount,
                details: "translated \(plan.translatedRefs.count), segments \(plan.segmentMoves.count), unsupported \(plan.unsupportedRefs.count), moved false, no-op true, preserved metal true",
                timings: timings
            )
            HorizontalMoveCommitDiagnostics.markCommitReturned()
            #if os(macOS)
            // Placeholder anchored where it was placed (no drag): still open the
            // inline editor. The text already lives in editedBoard from placeText.
            if editTextRef != nil {
                beginEditingPlacedText()
            }
            #endif
            return
        }
        var draft = measure("draft snapshot") {
            state.originalBoard
        }
        measure("apply move") {
            moveSelectedObjects(by: totalDelta, board: &draft)
        }
        measure("assign edited board") {
            editedBoard = draft
        }
        measure("register undo") {
            // The text-placement commit defers its single "Add Text" undo to
            // finalize; don't register a "Move" here (there's no committed prior
            // position — the text was never on the board before this flow).
            if editTextRef == nil {
                registerUndoSnapshot(state.originalBoard, actionName: "Move")
            }
        }
        measure("clear move state") {
            moveState = nil
        }
        measure("invalidate caches") {
            invalidateSelectableCache(preservesMetalScene: canPreserveCommittedMetalScene)
        }
        measure("publish board change") {
            publishConnectivityResolvedEdit(draft)
        }
        measure("publish selection") {
            publishSelectionContext()
        }
        HorizontalMoveRateDiagnostics.endMove(committed: true)
        HorizontalMoveCommitDiagnostics.report(
            modeName: "board",
            selectedCount: selectedCount,
            details: "translated \(plan.translatedRefs.count), segments \(plan.segmentMoves.count), unsupported \(plan.unsupportedRefs.count), moved true, preserved metal \(canPreserveCommittedMetalScene)",
            timings: timings
        )
        HorizontalMoveCommitDiagnostics.markCommitReturned()
        #if os(macOS)
        // Anchored at the dragged-to point: open the inline editor on the moved
        // text (editedBoard already holds it at the final position).
        if editTextRef != nil {
            beginEditingPlacedText()
        }
        #endif
    }

    private func cancelMove() {
        guard moveState != nil else {
            return
        }

        invalidateSelectableCache()
        moveState = nil
        publishSelectionContext()
        HorizontalMoveRateDiagnostics.endMove(committed: false)
    }

    private func boardMovePreviewBoard(for state: MoveState) -> HorizontalBoard {
        let totalDelta = state.lastPoint - state.startPoint
        guard totalDelta != .zero else {
            return state.originalBoard
        }

        return selectableCache.movePreview(
            key: BoardMovePreviewCacheKey(
                boardID: state.originalBoard.uuid,
                revision: selectableCacheRevision,
                counts: boardGeometryCounts(for: state.originalBoard),
                selectedRefs: selectedObjects,
                startPoint: state.startPoint,
                lastPoint: state.lastPoint
            )
        ) {
            var previewBoard = state.originalBoard
            moveSelectedObjects(by: totalDelta, board: &previewBoard)
            return previewBoard
        }
    }

    private func beginDrawGraphics(_ primitive: HorizontalDrawingPrimitive) {
        guard !isReadOnly,
              moveState == nil,
              pastePlacementState == nil else {
            return
        }
        drawGraphicsState = DrawGraphicsState(
            primitive: primitive,
            originalBoard: board,
            cursor: lastCursorWorldPoint,
            layer: drawingLayer
        )
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
    }

    /// Begin a "Draw Plane": a polygon-draw whose closed outline becomes a
    /// net-bound copper plane on commit. Reuses the polygon interaction wholesale
    /// (point accumulation, preview, Return/double-click to close, Esc to cancel).
    /// Applies a number-key layer pick, ignoring layers this board does not
    /// have — on a 2-layer board 4 through 9 name inner layers that do not
    /// exist, and selecting one would hide the board behind an empty layer.
    /// Takes on a board the pane replaced underneath us — a finished plane pour,
    /// a schematic sync — without the canvas being torn down and rebuilt.
    ///
    /// The draft has to be dropped or `board` would keep returning the stale
    /// `editedBoard` and the new fills would never appear; that is safe because
    /// the pane only publishes a replacement it built from the current board.
    /// In-progress interactions are cancelled for the same reason: they hold
    /// their own copy of the board from before the change.
    ///
    /// Selection, hover, undo and the viewport all survive deliberately — this
    /// is a redraw, not a reload, and losing them is exactly what the old
    /// rebuild-by-identity did.
    private func adoptExternallyUpdatedBoard() {
        editedBoard = nil
        moveState = nil
        drawGraphicsState = nil
        drawTrackState = nil
        trackRouterSession = nil
        pastePlacementState = nil
        invalidateSelectableCache()
        // Plane fills are geometry, and a net change is a colour change, so the
        // Metal scene has to be rebuilt rather than patched in place.
        metalSceneRevision &+= 1
        publishSelectionContext()
    }

    private func selectDrawingLayer(_ layer: Int) {
        let stackup = Set(board.stackupLayers.map(\.layer))
        guard stackup.contains(layer) else {
            return
        }
        onSelectDrawingLayer(layer)
    }

    private func beginDrawPlane() {
        guard !isReadOnly,
              moveState == nil,
              pastePlacementState == nil else {
            return
        }
        drawGraphicsState = DrawGraphicsState(
            primitive: .polygon,
            originalBoard: board,
            cursor: lastCursorWorldPoint,
            layer: drawingLayer,
            createsPlane: true
        )
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
    }

    private func addDrawGraphicsPoint(_ point: HorizontalPoint) {
        guard !isReadOnly,
              var state = drawGraphicsState else {
            return
        }
        state.points.append(point)
        state.cursor = point
        drawGraphicsState = state

        guard state.primitive != .line else {
            return
        }

        if state.primitive != .polygon,
           let result = finalizedGraphicsResult(for: state) {
            commitDrawGraphics(result, state: state)
        }
    }

    private func commitDrawGraphicsAtCursor() {
        guard !isReadOnly,
              var state = drawGraphicsState,
              let cursor = state.cursor else {
            return
        }
        if let result = finalizedGraphicsResult(for: state) {
            commitDrawGraphics(result, state: state)
            return
        }
        state.points.append(cursor)
        if let result = finalizedGraphicsResult(for: state) {
            commitDrawGraphics(result, state: state)
        } else {
            drawGraphicsState = state
        }
    }

    private func cancelDrawGraphics() {
        guard let state = drawGraphicsState else {
            return
        }
        editedBoard = state.originalBoard
        drawGraphicsState = nil
        invalidateSelectableCache()
        publishSelectionContext()
    }

    private func endDrawGraphicsInteraction() {
        guard !isReadOnly,
              let state = drawGraphicsState else {
            cancelDrawGraphics()
            return
        }

        guard state.primitive == .line else {
            cancelDrawGraphics()
            return
        }

        guard let result = finalizedGraphicsResult(for: state),
              drawGraphicsResultHasDrawableGeometry(result) else {
            cancelDrawGraphics()
            return
        }
        commitDrawGraphics(result, state: state)
    }

    // MARK: - Track drawing
    //
    // Interactive copper-track drawing, mirroring the reference ToolDrawTrack (the
    // non-router manual mode). Each click lays orthogonal track segments on the
    // active copper layer; the net is resolved from whatever copper sits under
    // the start point (pad / track / via / junction). This is the foundation
    // tool; push-and-shove "route track" mode is a separate effort
    // that depends on the (not-yet-vendored) KiCad PNS router.

    /// Whether the interactive push-and-shove autorouter is active. Always false
    /// where the router isn't built (iOS), so the manual path runs there.
    private var isRouterMode: Bool {
        #if canImport(HorizontalPushShoveRouter)
        return toolSettings.routerMode
        #else
        return false
        #endif
    }

    /// The legs of a route from `from` to `to`.
    ///
    /// With obstacle routing off this is the corner style the tool has always
    /// drawn. With it on, the route bends around existing copper instead —
    /// nothing is shoved, so everything already on the board stays put.
    ///
    /// A route the router could NOT complete is discarded rather than drawn.
    /// Its partial path collides with whatever stopped it, so showing it makes
    /// the router look like it ignores pads, and committing it would lay copper
    /// that violates the board's own rules. Falling back to the plain elbow
    /// leaves the user with the tool's ordinary behaviour, which is honest: the
    /// router had nothing better to offer here.
    private func trackSpecs(
        from: HorizontalPoint,
        to: HorizontalPoint,
        state: DrawTrackState,
        netID: String?
    ) -> [BoardTrackSegmentSpec] {
        if toolSettings.routerMode, let session = trackRouterSession {
            let result = session.route(
                from: from, to: to, layer: state.layer, netID: netID,
                width: state.width, diagonalFirst: state.bendMode == .xy)
            if result.isComplete {
                let specs = BoardTrackRouting.specs(alongPath: result.points)
                if !specs.isEmpty {
                    return specs
                }
            }
        }
        return BoardTrackRouting.route(
            from: from, to: to,
            horizontalFirst: state.bendMode == .xy,
            cornerStyle: state.cornerStyle
        )
    }

    /// True when `point` coincides with a pad center — those endpoints serialize
    /// as a direct pad connection and get no junction.
    private func isPadCenter(_ point: HorizontalPoint, in board: HorizontalBoard) -> Bool {
        let key = pointKey(point)
        return board.packagePadPositions.values.contains { pointKey($0) == key }
    }

    #if canImport(HorizontalPushShoveRouter)
    /// Starts a PNS session at `anchor` (called when the route's first point is
    /// set). Returns false if the router declined to start.
    @discardableResult
    private func routerStartSession(anchor: HorizontalPoint, net: String?, width: Double, layer: Int) -> Bool {
        let session = BoardPushShoveSession(board: board, clearanceLayer: layer)
        pushShoveSession = session
        return session.start(
            anchor: anchor,
            layer: layer,
            width: width,
            netID: net,
            viaTemplate: board.viaTemplate,
            mode: toolSettings.routerShove ? .shove : .walkaround
        )
    }

    /// Updates the live head toward `point` and refreshes the preview (routed
    /// geometry + the set of existing tracks the route will remove).
    private func routerRefreshPreview(at point: HorizontalPoint) {
        guard let session = pushShoveSession else { return }
        let preview = session.move(to: point)
        pushShovePreviewSpecs = preview.specs
        let removed = Set(preview.removedSegmentIDs.map(normalizedID))
        if pushShoveRemovedSegmentIDs != removed {
            pushShoveRemovedSegmentIDs = removed
        }
    }

    /// Applies a committed PNS route to the draft board: removes displaced
    /// existing copper (by id) and adds the routed tracks/vias, creating
    /// junctions at non-pad vertices for connectivity.
    private func applyPushShoveCommit(_ commit: BoardPushShoveCommit) {
        guard !commit.isEmpty else { return }
        var draft = editedBoard ?? sourceBoard

        let removedSegments = Set(commit.removedSegmentIDs.map(normalizedID))
        if !removedSegments.isEmpty {
            draft.tracks.removeAll { removedSegments.contains(normalizedID($0.id)) }
        }
        let removedVias = Set(commit.removedViaIDs.map(normalizedID))
        if !removedVias.isEmpty {
            draft.vias.removeAll { removedVias.contains(normalizedID($0.id)) }
        }

        for track in commit.addedTracks {
            let ends = track.center != nil
                ? BoardTrackRouting.orientedArc(from: track.from, to: track.to, center: track.center!)
                : (from: track.from, to: track.to)
            if !isPadCenter(track.from, in: draft) {
                _ = mergeBoardJunctions(at: track.from, preferredID: nil, netID: track.netID, board: &draft)
            }
            if !isPadCenter(track.to, in: draft) {
                _ = mergeBoardJunctions(at: track.to, preferredID: nil, netID: track.netID, board: &draft)
            }
            draft.tracks.append(
                HorizontalSegment(
                    id: UUID().uuidString.lowercased(),
                    from: ends.from,
                    to: ends.to,
                    width: track.width,
                    layer: track.layer,
                    center: track.center,
                    netID: track.netID
                )
            )
        }

        for via in commit.addedVias {
            if !isPadCenter(via.position, in: draft) {
                _ = mergeBoardJunctions(at: via.position, preferredID: nil, netID: via.netID, board: &draft)
            }
            draft.vias.append(
                HorizontalMarker(
                    id: UUID().uuidString.lowercased(),
                    position: via.position,
                    size: via.diameter,
                    holeSize: via.drill,
                    layer: nil,
                    connectedLayers: BoardTrackRouting.throughViaLayers(copperLayerCount: draft.copperLayerCount),
                    netID: via.netID
                )
            )
        }

        editedBoard = draft
        invalidateSelectableCache()
    }

    /// Tears down the active session and clears the preview.
    private func endRouterSession() {
        pushShoveSession?.stop()
        pushShoveSession = nil
        pushShovePreviewSpecs = []
        pushShoveRemovedSegmentIDs = []
    }
    #endif

    /// "Add Text" (menu bar): prompt for a string, create a board text on the
    /// current drawing layer at the cursor, then enter an interactive move so it
    /// follows the cursor until a click places it (mirrors flow).
    private func addText() {
        guard !isReadOnly,
              moveState == nil,
              drawTrackState == nil,
              drawGraphicsState == nil,
              pastePlacementState == nil else {
            return
        }
        #if os(macOS)
        // New UX: place a "Text" placeholder that hovers on the cursor; a click
        // anchors it and opens an inline editor with a live re-render (see
        // placeText / commitMove / the editingTextState popover overlay). No
        // upfront NSAlert.
        placeText("Text", editAfterCommit: true)
        #else
        promptRequest = HorizontalCanvasPromptRequest(
            title: "Add Text",
            confirmTitle: "Add",
            content: .text(seed: "") { entered in
                if let entered { placeText(entered) }
            }
        )
        #endif
    }

    /// "Edit…" entry point (context menu): reopen the inline editor on the
    /// currently-selected text. macOS only; iOS edits via the inspector.
    private func editSelectedText() {
        #if os(macOS)
        guard let ref = selectedObjects.first(where: { $0.type == .text }) else { return }
        beginEditingExistingText(ref)
        #endif
    }

    private func placeText(_ content: String, editAfterCommit: Bool = false) {
        let position = lastCursorWorldPoint ?? board.bounds.center
        let text = HorizontalText(
            id: UUID().uuidString.lowercased(),
            text: content,
            position: position,
            size: 1_000_000,
            layer: drawingLayer
        )
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        draft.texts.append(text)
        #if os(macOS)
        if editAfterCommit {
            // Defer the undo: the whole add-place-edit is ONE undo step,
            // registered at finalize only if real content is typed (cancel =
            // no-op). Stash the pre-add board so a cancel can revert cleanly.
            editingTextState = EditTextState(
                ref: text.id,
                worldPosition: position,
                content: content,
                preBoard: previous,
                isNewPlacement: true,
                originalContent: content
            )
            editedBoard = draft
            invalidateSelectableCache()
            selectedObjects = [HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer)]
            hoveredObject = nil
            publishConnectivityResolvedEdit(draft)
            publishSelectionContext()
            beginMove(tracksCursor: true, editTextRefOnCommit: text.id)
            return
        }
        #endif
        registerUndoSnapshot(previous, actionName: "Add Text")
        editedBoard = draft
        invalidateSelectableCache()
        selectedObjects = [HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer)]
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
        beginMove(tracksCursor: true)
    }

    #if os(macOS)
    /// After the placeholder is anchored (commitMove), re-anchor the inline editor
    /// at the text's *current* world position (it may have been dragged) and open
    /// the popover. No-op if the placement was already cancelled. Preserves the
    /// new-placement flags so finalize uses "Add Text" and an untouched-"Text"
    /// dismiss still deletes.
    private func beginEditingPlacedText() {
        guard let state = editingTextState else { return }
        let placed = (editedBoard ?? sourceBoard).texts.first(where: { normalizedID($0.id) == normalizedID(state.ref) })
        editingTextState = EditTextState(
            ref: state.ref,
            worldPosition: placed?.position ?? state.worldPosition,
            content: placed?.text ?? state.content,
            preBoard: state.preBoard,
            isEditing: true,
            isNewPlacement: state.isNewPlacement,
            originalContent: state.originalContent
        )
    }

    /// Reopen the inline editor on an already-placed text (double-click / "Edit…").
    /// No placeholder phase: the popover appears immediately, anchored at the text.
    /// `preBoard` is the CURRENT board so a no-op/empty dismiss restores the
    /// original content; a real change commits one "Edit Text" undo.
    private func beginEditingExistingText(_ ref: HorizontalSelectableRef) {
        guard !isReadOnly,
              moveState == nil,
              drawTrackState == nil,
              drawGraphicsState == nil,
              pastePlacementState == nil,
              editingTextState == nil else {
            return
        }
        let current = editedBoard ?? sourceBoard
        guard let text = current.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        selectedObjects = [HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer)]
        hoveredObject = nil
        publishSelectionContext()
        editingTextState = EditTextState(
            ref: text.id,
            worldPosition: text.position,
            content: text.text,
            preBoard: current,
            isEditing: true,
            isNewPlacement: false,
            originalContent: text.text
        )
    }

    /// Live update of the text as the user types. The cheap part — the
    /// `editingTextState.content` source of truth `finalizeTextEdit` reads — runs
    /// immediately so the TextField stays responsive; the expensive board mutation
    /// + connectivity recompute + Metal rebuild is debounced (~0.1s) so keystrokes
    /// never block on rendering. Registers NO undo (deferred to finalizeTextEdit).
    private func updateEditingTextContent(_ newContent: String) {
        guard !isReadOnly, var state = editingTextState else { return }
        state.content = newContent
        editingTextState = state
        textRenderDebounce?.cancel()
        textRenderDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            renderEditingTextLive()
        }
    }

    /// The debounced heavy half of a live keystroke: write the current edit
    /// content into the board draft and re-render through the same commit funnel
    /// placeText uses (no undo).
    private func renderEditingTextLive() {
        guard !isReadOnly, let state = editingTextState else { return }
        var draft = editedBoard ?? sourceBoard
        guard let index = draft.texts.firstIndex(where: { normalizedID($0.id) == normalizedID(state.ref) }) else {
            return
        }
        guard draft.texts[index].text != state.content else { return }
        draft.texts[index].text = state.content
        editedBoard = draft
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
    }

    /// Dismiss/Return/Esc: finalize new-placement OR existing-edit uniformly.
    /// Empty or unchanged content (`== originalContent`) is a no-op: revert to
    /// `preBoard` — which for a new placement has no text (deletes it) and for an
    /// existing edit holds the original (restores it). A real change commits one
    /// undo step ("Add Text" / "Edit Text").
    private func finalizeTextEdit() {
        guard let state = editingTextState else { return }
        textRenderDebounce?.cancel()
        textRenderDebounce = nil
        editingTextState = nil
        let trimmed = state.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || state.content == state.originalContent {
            editedBoard = state.preBoard
            if state.isNewPlacement {
                selectedObjects = []
                hoveredObject = nil
            }
            invalidateSelectableCache()
            publishConnectivityResolvedEdit(state.preBoard)
            publishSelectionContext()
            return
        }
        // Commit one undo step with the final content. A pending debounce may
        // never have fired, so apply state.content to the board here explicitly.
        var draft = editedBoard ?? sourceBoard
        if let index = draft.texts.firstIndex(where: { normalizedID($0.id) == normalizedID(state.ref) }) {
            draft.texts[index].text = state.content
        }
        editedBoard = draft
        registerUndoSnapshot(state.preBoard, actionName: state.isNewPlacement ? "Add Text" : "Edit Text")
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }
    #endif

    private func beginDrawTrack() {
        guard !isReadOnly,
              moveState == nil,
              pastePlacementState == nil,
              drawTrackState == nil else {
            return
        }
        // Extract and index the obstacle world ONCE for the gesture. It costs
        // about a millisecond on a real board — fine here, wasteful per frame,
        // and the board does not change while the user is dragging.
        trackRouterSession = toolSettings.routerMode
            ? HorizontalBoardTrackRouterSession(board: board)
            : nil
        let layer = HorizontalBoardLayers.isCopper(drawingLayer) ? drawingLayer : HorizontalBoardLayers.topCopper
        // Width may take a hint from the highlighted net, but the track's NET is
        // never seeded from the selection — it's derived from what the route
        // actually connects to (see publishConnectivityResolvedEdit). A track
        // touching no pad stays net-less (orange).
        let startNet = selectedNetIDs.first
        drawTrackState = DrawTrackState(
            originalBoard: board,
            anchor: nil,
            anchorJunctionID: nil,
            netID: nil,
            width: toolSettings.explicitTrackWidth ?? defaultTrackWidth(forNet: startNet),
            layer: layer,
            cursor: lastCursorWorldPoint,
            cornerStyle: toolSettings.cornerStyle
        )
        trackRouteHistory = []
        pushShovePreviewSpecs = []
        pushShoveRemovedSegmentIDs = []
        drawGraphicsState = nil
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
    }

    private func addDrawTrackPoint(_ point: HorizontalPoint) {
        guard !isReadOnly,
              var state = drawTrackState else {
            return
        }

        if state.anchor == nil {
            // Starting on a pad snaps the anchor to the pad center and
            // connects directly — no junction is placed on the pad.
            var anchorPoint = point
            if let padRef = boardPadReference(at: point, layer: state.layer) {
                anchorPoint = padRef.center
                state.anchorOnPad = true
            }
            state.anchor = anchorPoint
            state.anchorJunctionID = board.junctions.first { pointKey($0.value) == pointKey(anchorPoint) }?.key
            if let net = boardNetID(at: point) ?? boardNetID(at: anchorPoint) {
                state.netID = net
            }
            // An explicit width (set via `w`) wins; else continue at the width
            // of any track under the start point; else the net/board default.
            state.width = toolSettings.explicitTrackWidth
                ?? BoardTrackRouting.trackWidth(at: anchorPoint, tracks: board.tracks)
                ?? defaultTrackWidth(forNet: state.netID)
            state.cursor = anchorPoint
            if let bend = boardTrackBendMode(at: anchorPoint) {
                state.bendMode = bend
            }
            drawTrackState = state
            #if canImport(HorizontalPushShoveRouter)
            if isRouterMode {
                routerStartSession(anchor: anchorPoint, net: state.netID, width: state.width, layer: state.layer)
            }
            #endif
            return
        }

        // Ending on a pad snaps to the pad center, connects directly and
        // finishes the route (mirrors ToolDrawTrack, where clicking a
        // pad completes the track).
        let endPad = boardPadReference(at: point, layer: state.layer)
        let target = endPad?.center ?? point

        guard let anchor = state.anchor,
              pointKey(anchor) != pointKey(target) else {
            state.cursor = target
            drawTrackState = state
            return
        }

        #if canImport(HorizontalPushShoveRouter)
        if isRouterMode, let session = pushShoveSession {
            // The autorouter owns net adoption and collision handling; fix the
            // current segment(s). Clicking a pad finishes the route.
            let finish = endPad != nil
            _ = session.fix(at: target, finish: finish)
            routerRefreshPreview(at: target)
            state.cursor = target
            state.segmentCount += 1 // marks the route as having drawn something
            if !finish { state.anchor = target }
            drawTrackState = state
            if finish { commitDrawTrack() }
            return
        }
        #endif

        // Net compatibility (mirrors Horizon): never weld two different nets
        // together. If the end point already belongs to a different net, ignore
        // the click and keep routing from the same anchor.
        let endNet = boardNetID(at: point) ?? boardNetID(at: target)
        if let endNet,
           let trackNet = state.netID,
           normalizedID(endNet) != normalizedID(trackNet) {
            state.cursor = point
            drawTrackState = state
            return
        }
        let netID = state.netID ?? endNet

        // Lay the route legs for the active corner style: straight 90°, 45°
        // diagonal, or a tangent quarter-arc. Each leg becomes a track segment
        // (arc legs carry a center); junctions sit at the route vertices.
        let specs = trackSpecs(
            from: anchor, to: target, state: state, netID: netID)
        guard !specs.isEmpty else {
            state.cursor = target
            drawTrackState = state
            return
        }

        pushTrackRouteStep(state)
        var draft = editedBoard ?? sourceBoard
        if !state.anchorOnPad {
            _ = mergeBoardJunctions(at: anchor, preferredID: state.anchorJunctionID, netID: netID, board: &draft)
        }
        var segmentCount = 0
        var endJunctionID = state.anchorJunctionID
        for spec in specs {
            // Junction at the forward vertex, unless it is the pad target.
            let toIsPadTarget = endPad != nil && pointKey(spec.to) == pointKey(target)
            var junctionID: String?
            if !toIsPadTarget {
                junctionID = mergeBoardJunctions(at: spec.to, preferredID: nil, netID: netID, board: &draft)
            }
            let ends = spec.renderEndpoints
            draft.tracks.append(
                HorizontalSegment(
                    id: UUID().uuidString.lowercased(),
                    from: ends.from,
                    to: ends.to,
                    width: state.width,
                    layer: state.layer,
                    center: spec.center,
                    netID: netID
                )
            )
            segmentCount += 1
            endJunctionID = junctionID
        }
        editedBoard = draft
        invalidateSelectableCache()

        state.anchor = target
        state.anchorJunctionID = endJunctionID
        state.anchorOnPad = endPad != nil
        state.netID = netID
        state.cursor = target
        state.segmentCount += segmentCount
        drawTrackState = state

        if endPad != nil, state.segmentCount > 0 {
            commitDrawTrack()
        }
    }

    private func boardPadReference(at point: HorizontalPoint, layer: Int?) -> (path: String, center: HorizontalPoint)? {
        BoardTrackRouting.padReference(
            at: point,
            layer: layer,
            packagePads: board.packagePads,
            padPositions: board.packagePadPositions
        )
    }

    private func commitDrawTrack() {
        guard !isReadOnly,
              let state = drawTrackState else {
            return
        }
        #if canImport(HorizontalPushShoveRouter)
        // The autorouter only materializes geometry at commit: finish the route,
        // apply the result to the draft, then fall through to persistence.
        if isRouterMode, let session = pushShoveSession {
            _ = session.fix(at: state.cursor ?? state.anchor ?? .zero, finish: true)
            applyPushShoveCommit(session.commit())
            endRouterSession()
        }
        #endif
        drawTrackState = nil
        trackRouterSession = nil
        trackRouteHistory = []
        guard state.hasDrawn else {
            return
        }
        registerUndoSnapshot(state.originalBoard, actionName: "Draw Track")
        publishConnectivityResolvedEdit(board)
        publishSelectionContext()
    }

    private func cancelDrawTrack() {
        guard let state = drawTrackState else {
            return
        }
        #if canImport(HorizontalPushShoveRouter)
        endRouterSession()
        #endif
        editedBoard = state.originalBoard
        drawTrackState = nil
        trackRouterSession = nil
        trackRouteHistory = []
        invalidateSelectableCache()
        publishSelectionContext()
    }

    /// Snapshots the route state before a mutating step so Backspace can revert
    /// exactly one click's worth of routing (its segments, or a via).
    private func pushTrackRouteStep(_ state: DrawTrackState) {
        trackRouteHistory.append(
            BoardTrackRouteStep(
                board: editedBoard,
                anchor: state.anchor,
                anchorJunctionID: state.anchorJunctionID,
                anchorOnPad: state.anchorOnPad,
                netID: state.netID,
                width: state.width,
                layer: state.layer,
                segmentCount: state.segmentCount,
                viaCount: state.viaCount
            )
        )
    }

    /// `Backspace`: revert the last routing step. Pops one history entry,
    /// restoring the draft board and the route head; with no history left it
    /// clears the start anchor (back to "click to start"). Esc still cancels.
    private func undoLastTrackStep() {
        guard var state = drawTrackState else {
            return
        }
        #if canImport(HorizontalPushShoveRouter)
        if isRouterMode, let session = pushShoveSession {
            session.undoLastSegment()
            if let cursor = state.cursor { routerRefreshPreview(at: cursor) }
            return
        }
        #endif
        guard let step = trackRouteHistory.popLast() else {
            if state.anchor != nil {
                state.anchor = nil
                state.anchorJunctionID = nil
                state.anchorOnPad = false
                drawTrackState = state
            }
            return
        }
        editedBoard = step.board
        state.anchor = step.anchor
        state.anchorJunctionID = step.anchorJunctionID
        state.anchorOnPad = step.anchorOnPad
        state.netID = step.netID
        state.width = step.width
        state.layer = step.layer
        state.segmentCount = step.segmentCount
        state.viaCount = step.viaCount
        drawTrackState = state
        invalidateSelectableCache()
    }

    /// Orthogonal two-segment routing between anchor and point, with the corner
    /// Seeds the corner posture from an existing track touching the start point,
    /// so a new branch continues in a sensible direction.
    private func boardTrackBendMode(at point: HorizontalPoint) -> BoardTrackBendMode? {
        BoardTrackRouting.bendModeHorizontalFirst(at: point, tracks: board.tracks)
            .map { $0 ? .xy : .yx }
    }

    /// Resolves the net of whatever copper sits under `point`: junction, via,
    /// track (endpoint or body), package pad, or pad hole. Position-based, like
    /// the rest of Horizontal's connectivity model.
    private func boardNetID(at point: HorizontalPoint) -> String? {
        let snapshot = board
        return BoardTrackRouting.netID(
            at: point,
            junctions: snapshot.junctions,
            junctionNetIDs: snapshot.junctionNetIDs,
            vias: snapshot.vias,
            tracks: snapshot.tracks,
            packagePads: snapshot.packagePads,
            packageHoles: snapshot.packageHoles
        )
    }

    /// Default width for a freshly drawn track: the most common width already in
    /// use on the same net, else the board's most common track width, else
    /// 0.2 mm. (Horizontal does not model per-net-class default widths.)
    private func defaultTrackWidth(forNet netID: String?) -> Double {
        BoardTrackRouting.defaultWidth(tracks: board.tracks, net: netID)
    }

    /// Preview polylines for the in-progress route. The manual tool is a single
    /// connected rubber-band (anchor→cursor); the autorouter returns the live
    /// head plus every already-confirmed section as a SET of segments (not one
    /// ordered path), so each is its own polyline — chaining them would draw
    /// spurious connectors between disjoint pieces.
    private func trackPreviewPolylines(_ state: DrawTrackState) -> [[HorizontalPoint]] {
        if isRouterMode {
            return pushShovePreviewSpecs.compactMap { spec in
                let poly = spec.polyline()
                return poly.count >= 2 ? poly : nil
            }
        }
        guard let anchor = state.anchor, let cursor = state.cursor,
              pointKey(anchor) != pointKey(cursor) else {
            return []
        }
        let specs = trackSpecs(
            from: anchor, to: cursor, state: state, netID: state.netID)
        guard let chained = chainedPolyline(specs) else {
            return []
        }
        return [chained]
    }

    /// Flattens route legs into one continuous polyline in flow order.
    private func chainedPolyline(_ specs: [BoardTrackSegmentSpec]) -> [HorizontalPoint]? {
        var points = [HorizontalPoint]()
        for spec in specs {
            let poly = spec.polyline()
            points.append(contentsOf: points.isEmpty ? poly : Array(poly.dropFirst()))
        }
        return points.count >= 2 ? points : nil
    }

    private func drawTrackPreview(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard let state = drawTrackState else {
            return
        }
        let polylines = trackPreviewPolylines(state)
        guard !polylines.isEmpty else {
            return
        }
        var path = Path()
        for points in polylines where points.count >= 2 {
            path.move(to: transform.point(points[0]))
            for point in points.dropFirst() {
                path.addLine(to: transform.point(point))
            }
        }
        context.stroke(
            path,
            with: .color(layerColor(for: state.layer).opacity(0.5)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(state.width, minimum: 1.6),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    /// `c`: cycle the track corner style (90° ↔ 45°) while routing, else flip
    /// the rectangle placement mode for the graphics tool.
    private func toggleRectanglePlacementMode() {
        if var state = drawTrackState {
            toolSettings.cornerStyle.cycle()
            state.cornerStyle = toolSettings.cornerStyle
            drawTrackState = state
            return
        }
        guard var state = drawGraphicsState,
              state.primitive == .rectangle else {
            return
        }
        state.rectanglePlacementMode.toggle()
        drawGraphicsState = state
    }

    /// `/`: flip the routing posture (which leg of the corner leads).
    private func flipTrackPosture() {
        guard var state = drawTrackState else {
            return
        }
        #if canImport(HorizontalPushShoveRouter)
        if isRouterMode, let session = pushShoveSession {
            session.flipPosture()
            if let cursor = state.cursor { routerRefreshPreview(at: cursor) }
            return
        }
        #endif
        state.bendMode.toggle()
        drawTrackState = state
    }

    private var canToggleVia: Bool {
        drawTrackState != nil && board.viaTemplate != nil
    }

    /// `v`: drop a through via at the current route head and switch the active
    /// copper layer so subsequent segments route on the far side. The via, its
    /// hole and a junction all share the anchor position; connectivity unifies
    /// them by position. No-op when the board has no via template (no padstack).
    private func toggleVia() {
        guard !isReadOnly,
              var state = drawTrackState,
              let anchor = state.anchor,
              let template = board.viaTemplate else {
            return
        }
        #if canImport(HorizontalPushShoveRouter)
        if isRouterMode, let session = pushShoveSession {
            // The autorouter places the via at the head on the next fix and
            // continues on the far layer; just arm it and flip the active layer
            // so the preview/status reflect the new side.
            session.toggleVia()
            state.layer = BoardTrackRouting.oppositeRoutingLayer(state.layer)
            session.switchLayer(state.layer)
            state.viaCount += 1
            drawTrackState = state
            if let cursor = state.cursor { routerRefreshPreview(at: cursor) }
            return
        }
        #endif
        let netID = state.netID
        pushTrackRouteStep(state)
        var draft = editedBoard ?? sourceBoard
        let junctionID = mergeBoardJunctions(at: anchor, preferredID: state.anchorJunctionID, netID: netID, board: &draft)
        let viaID = UUID().uuidString.lowercased()
        let viaDiameter = toolSettings.resolvedViaDiameter(template: template)
        let viaHole = toolSettings.resolvedViaHoleDiameter(template: template)
        draft.vias.append(
            HorizontalMarker(
                id: viaID,
                position: anchor,
                size: viaDiameter,
                holeSize: viaHole,
                layer: nil,
                connectedLayers: BoardTrackRouting.throughViaLayers(copperLayerCount: board.copperLayerCount),
                netID: netID
            )
        )
        draft.viaHoles.append(
            HorizontalHole(
                id: "\(viaID)/hole",
                position: anchor,
                diameter: viaHole,
                length: viaHole,
                shape: .round,
                plated: true,
                netID: netID
            )
        )
        editedBoard = draft
        invalidateSelectableCache()

        state.layer = BoardTrackRouting.oppositeRoutingLayer(state.layer)
        state.anchorJunctionID = junctionID
        state.anchorOnPad = false
        state.viaCount += 1
        drawTrackState = state
    }

    /// `w`: set an explicit track width for the current and subsequent routes,
    /// seeded with the current width. macOS-only (the track tool is desktop).
    private func enterTrackWidth() {
        guard drawTrackState != nil else {
            return
        }
        let current = drawTrackState?.width ?? toolSettings.explicitTrackWidth ?? BoardTrackRouting.defaultTrackWidth
        #if os(macOS)
        guard let chosen = HorizontalTrackWidthPrompt.run(currentWidthNM: current) else {
            return
        }
        applyTrackWidth(chosen)
        #else
        let nmPerMM = 1_000_000.0
        promptRequest = HorizontalCanvasPromptRequest(
            title: "Track Width",
            confirmTitle: "Set",
            content: .number(seed: max(current, 0) / nmPerMM, unit: "mm") { mm in
                guard let mm, mm.isFinite, mm > 0 else { return }
                applyTrackWidth((mm * nmPerMM).rounded())
            }
        )
        #endif
    }

    private func applyTrackWidth(_ widthNM: Double) {
        toolSettings.explicitTrackWidth = widthNM
        if var state = drawTrackState {
            state.width = widthNM
            drawTrackState = state
        }
    }

    private func finalizedGraphicsResult(for state: DrawGraphicsState) -> DrawGraphicsResult? {
        HorizontalCanvasModeSupport.finalizedGraphicsResult(
            for: state.primitive,
            points: state.points,
            rectanglePlacementMode: state.rectanglePlacementMode,
            graphicsResult: { graphicsResult(for: $0, points: $1, layer: state.layer, rectanglePlacementMode: $2) }
        )
    }

    private func commitDrawGraphics(_ result: DrawGraphicsResult, state: DrawGraphicsState) {
        guard !isReadOnly else {
            return
        }
        if state.createsPlane {
            commitDrawPlane(result, state: state)
            return
        }
        let validLines = result.lines.filter { pointKey($0.from) != pointKey($0.to) }
        let validArcs = result.arcs.filter { pointKey($0.from) != pointKey($0.to) && $0.radius > 0 }
        let validPolygons = result.polygons.filter { $0.vertices.count >= 3 }
        guard !validLines.isEmpty || !validArcs.isEmpty || !validPolygons.isEmpty else {
            drawGraphicsState = state
            return
        }

        var draft = editedBoard ?? sourceBoard
        for line in validLines {
            ensureBoardJunction(at: line.from, board: &draft)
            ensureBoardJunction(at: line.to, board: &draft)
            draft.lines.append(line)
        }
        for arc in validArcs {
            ensureBoardJunction(at: arc.from, board: &draft)
            ensureBoardJunction(at: arc.to, board: &draft)
            ensureBoardJunction(at: arc.center, board: &draft)
            draft.arcs.append(arc)
        }
        draft.polygons.append(contentsOf: validPolygons)

        editedBoard = draft
        drawGraphicsState = nil
        invalidateSelectableCache()
        registerUndoSnapshot(state.originalBoard, actionName: "Draw \(state.primitive.title)")
        publishConnectivityResolvedEdit(board)
        publishSelectionContext()
    }

    /// Commit a Draw Plane: the closed outline becomes a copper polygon plus a
    /// net-bound `HorizontalPlane` (tool_draw_plane). The host re-pours and
    /// persists via `onPlaneEdit`; cancelling the net prompt reverts the whole draw
    /// (`ToolResponse::revert()`).
    private func commitDrawPlane(_ result: DrawGraphicsResult, state: DrawGraphicsState) {
        let polygons = result.polygons.filter { $0.vertices.count >= 3 }
        guard !polygons.isEmpty else {
            drawGraphicsState = state
            return
        }
        #if os(macOS)
        guard let netID = promptForPlaneNet() else {
            cancelDrawGraphics()
            return
        }
        finishDrawPlane(polygons: polygons, netID: netID)
        #else
        // iOS: pick the net via the canvas prompt (the draw stays in flight behind the
        // sheet). Default to the highlighted net, else the first; Cancel reverts.
        let options = sortedPlaneNetOptions()
        guard !options.isEmpty else {
            cancelDrawGraphics()
            return
        }
        let defaultNet = highlightedNetIDs.first.map(normalizedID) ?? options.first?.id
        promptRequest = HorizontalCanvasPromptRequest(
            title: "Plane Net",
            confirmTitle: "Create Plane",
            content: .optionPicker(options: options, selected: defaultNet) { picked in
                if let picked {
                    finishDrawPlane(polygons: polygons, netID: picked)
                } else {
                    cancelDrawGraphics()
                }
            }
        )
        #endif
    }

    private func finishDrawPlane(polygons: [HorizontalPolygon], netID: String) {
        var draft = editedBoard ?? sourceBoard
        for polygon in polygons {
            draft.polygons.append(polygon)
            draft.planes.append(makePlane(on: polygon, netID: netID))
        }

        drawGraphicsState = nil
        invalidateSelectableCache()
        publishSelectionContext()
        // The document pours all planes, writes the fragment cache, registers the
        // undo, and re-feeds the board (which remounts this canvas).
        onPlaneEdit(draft, "Draw Plane")
    }

    /// A fresh net-bound plane whose outline is `polygon` (Horizon: a polygon's
    /// `usage` becoming a plane). The plane derives its layer from the polygon and
    /// starts from-rules with default settings; the fill is computed on the pour.
    private func makePlane(on polygon: HorizontalPolygon, netID: String) -> HorizontalPlane {
        HorizontalPlane(
            id: UUID().uuidString.lowercased(),
            netID: netID,
            polygonID: polygon.id,
            layer: polygon.layer,
            priority: 0,
            fillStyle: "solid",
            minWidth: 0,
            keepOrphans: false,
            fragments: [],
            fallbackPolygon: polygon
        )
    }

    private func isPolygonRef(_ ref: HorizontalSelectableRef) -> Bool {
        ref.type == .polygonEdge || ref.type == .polygonVertex || ref.type == .polygonArcCenter
    }

    private func planeBackedByPolygon(_ polygonID: String, in board: HorizontalBoard) -> HorizontalPlane? {
        board.planes.first { normalizedID($0.polygonID) == normalizedID(polygonID) }
    }

    /// Context-menu "Define Plane": turns the right-clicked polygon into a copper
    /// plane (prompts for the net, like Draw Plane). The polygon already lives in
    /// `board.polygons`; only a plane referencing it is added, then poured.
    private func definePlaneForSelection() {
        guard !isReadOnly,
              let ref = selectedObjects.first(where: isPolygonRef),
              let polygon = boardPolygon(for: ref.id, in: board) else {
            return
        }
        // If it's somehow already a plane, edit it instead of duplicating.
        guard planeBackedByPolygon(polygon.id, in: board) == nil else {
            editPlaneForSelection()
            return
        }
        guard let netID = promptForPlaneNet() else {
            return
        }
        var draft = editedBoard ?? sourceBoard
        draft.planes.append(makePlane(on: polygon, netID: netID))
        invalidateSelectableCache()
        onPlaneEdit(draft, "Define Plane")
    }

    /// Context-menu "Edit Plane": selects the plane backing the right-clicked
    /// polygon so its inspector (net / priority / fill / min width / …) appears.
    private func editPlaneForSelection() {
        guard let ref = selectedObjects.first(where: isPolygonRef),
              let plane = planeBackedByPolygon(ref.id, in: board) else {
            return
        }
        setSelectedObject(HorizontalSelectableRef(id: plane.id, type: .plane, layer: plane.layer))
    }

    /// True for a standalone board polygon that can convert to a line loop — not a
    /// plane outline (that would orphan the plane) and not package-owned geometry.
    private func isConvertiblePolygon(_ ref: HorizontalSelectableRef) -> Bool {
        guard isPolygonRef(ref), !normalizedID(ref.id).contains("/") else {
            return false
        }
        guard let polygon = boardPolygon(for: ref.id, in: board), !polygon.id.contains("/") else {
            return false
        }
        return planeBackedByPolygon(polygon.id, in: board) == nil
    }

    /// `tool_polygon_to_line_loop`: explode the selected polygon into a
    /// closed loop of width-0 lines/arcs (junctions ensured at every endpoint and
    /// arc center) and drop the polygon.
    private func convertPolygonToLineLoopForSelection() {
        guard !isReadOnly,
              let ref = selectedObjects.first(where: isConvertiblePolygon),
              let polygon = boardPolygon(for: ref.id, in: board),
              let loop = HorizontalPolygonLineLoop.lineLoop(from: polygon, makeID: { UUID().uuidString.lowercased() }) else {
            return
        }
        let previousBoard = editedBoard ?? sourceBoard
        var draft = previousBoard
        for point in loop.junctionPoints {
            ensureBoardJunction(at: point, board: &draft)
        }
        draft.lines.append(contentsOf: loop.lines)
        draft.arcs.append(contentsOf: loop.arcs)
        draft.polygons.removeAll { normalizedID($0.id) == normalizedID(polygon.id) }
        // patchPolygons preserves unknown entries, so flag the removal explicitly.
        draft.removedPolygonIDs.insert(polygon.id)
        editedBoard = draft
        selectedObjects = []
        invalidateSelectableCache()
        registerUndoSnapshot(previousBoard, actionName: "Polygon to Line Loop")
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// `tool_line_loop_to_polygon`: find the loop reachable from the
    /// selected line/arc/junction and collapse it into a polygon, deleting the
    /// consumed lines/arcs. Orphaned junctions are vacuumed by the connectivity
    /// recompute in `publishConnectivityResolvedEdit`.
    private func convertLineLoopToPolygonForSelection() {
        guard !isReadOnly,
              let ref = selectedObjects.first(where: { $0.type == .boardLine || $0.type == .boardArc || $0.type == .junction }),
              let startPoint = lineLoopStartPoint(for: ref, in: board) else {
            return
        }
        guard let result = HorizontalPolygonLineLoop.polygon(
            startKey: HorizontalPolygonLineLoop.pointKey(startPoint),
            lines: board.lines,
            arcs: board.arcs,
            makeID: { UUID().uuidString.lowercased() }
        ) else {
            return
        }
        let previousBoard = editedBoard ?? sourceBoard
        var draft = previousBoard
        draft.lines.removeAll { result.consumedLineIDs.contains($0.id) }
        draft.arcs.removeAll { result.consumedArcIDs.contains($0.id) }
        draft.polygons.append(result.polygon)
        editedBoard = draft
        selectedObjects = [HorizontalSelectableRef(id: result.polygon.id, type: .polygonEdge, layer: result.polygon.layer)]
        invalidateSelectableCache()
        registerUndoSnapshot(previousBoard, actionName: "Line Loop to Polygon")
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    private func lineLoopStartPoint(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalPoint? {
        switch ref.type {
        case .boardLine:
            return board.lines.first { normalizedID($0.id) == normalizedID(ref.id) }?.from
        case .boardArc:
            return board.arcs.first { normalizedID($0.id) == normalizedID(ref.id) }?.from
        case .junction:
            return board.junctions[ref.id] ?? board.junctions.first { normalizedID($0.key) == normalizedID(ref.id) }?.value
        default:
            return nil
        }
    }

    /// Net chooser for a freshly drawn plane (Horizon requires a net; its OK button
    /// is disabled until one is picked). Returns nil to cancel the draw.
    private func promptForPlaneNet() -> String? {
        let nets = sortedPlaneNetOptions()
        guard !nets.isEmpty else {
            return nil
        }
        #if os(macOS)
        return HorizontalPlaneNetPrompt.run(nets: nets)
        #else
        // iOS has no plane dialog; bind the highlighted net, else the first net.
        return highlightedNetIDs.first.map(normalizedID) ?? nets.first?.id
        #endif
    }

    /// Board nets as `(id, name)` choices, sorted by display name. Shared by the
    /// draw-plane net prompt and the plane inspector's Net picker.
    private func sortedPlaneNetOptions() -> [HorizontalSelectionPropertyOption] {
        board.netDetails.values
            .map { HorizontalSelectionPropertyOption(id: normalizedID($0.id), title: nonEmpty($0.name) ?? shortID($0.id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func drawGraphicsResultHasDrawableGeometry(_ result: DrawGraphicsResult) -> Bool {
        result.lines.contains { pointKey($0.from) != pointKey($0.to) }
            || result.arcs.contains { pointKey($0.from) != pointKey($0.to) && $0.radius > 0 }
            || result.polygons.contains { $0.vertices.count >= 3 }
    }

    @discardableResult
    private func ensureBoardJunction(at point: HorizontalPoint, board: inout HorizontalBoard) -> String {
        mergeBoardJunctions(at: point, preferredID: nil, netID: nil, board: &board)
    }

    private func existingBoardJunctionID(matching id: String, in board: HorizontalBoard) -> String? {
        board.junctions.keys.first { normalizedID($0) == normalizedID(id) }
    }

    @discardableResult
    private func mergeBoardJunctions(
        at point: HorizontalPoint,
        preferredID: String?,
        netID: String?,
        board: inout HorizontalBoard
    ) -> String {
        let key = pointKey(point)
        let matchingIDs = board.junctions
            .filter { pointKey($0.value) == key }
            .map(\.key)
        let existingPreferredID = preferredID.flatMap { existingBoardJunctionID(matching: $0, in: board) }
        let keepID = existingPreferredID ?? matchingIDs.first ?? preferredID ?? UUID().uuidString.lowercased()
        let keepNetID = board.junctionNetIDs[keepID]
            ?? netID
            ?? matchingIDs.compactMap { board.junctionNetIDs[$0] }.first

        board.junctions[keepID] = point
        if let keepNetID {
            board.junctionNetIDs[keepID] = keepNetID
        } else {
            board.junctionNetIDs.removeValue(forKey: keepID)
        }

        for junctionID in matchingIDs where normalizedID(junctionID) != normalizedID(keepID) {
            board.junctions.removeValue(forKey: junctionID)
            board.junctionNetIDs.removeValue(forKey: junctionID)
        }

        return keepID
    }

    private func graphicsResult(
        for primitive: HorizontalDrawingPrimitive,
        points: [HorizontalPoint],
        layer: Int,
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner
    ) -> DrawGraphicsResult {
        HorizontalCanvasModeSupport.graphicsResult(
            for: primitive,
            points: points,
            rectanglePlacementMode: rectanglePlacementMode,
            pointKey: pointKey,
            makeSegment: { boardDrawingSegment(from: $0, to: $1, layer: layer) },
            makeArc: { boardDrawingArc(from: $0, to: $1, center: $2, layer: layer) },
            makePolygonResult: {
                DrawGraphicsResult(polygons: [
                    HorizontalPolygon(id: UUID().uuidString.lowercased(), vertices: $0, layer: layer)
                ])
            }
        )
    }

    private func boardDrawingSegment(from: HorizontalPoint, to: HorizontalPoint, layer: Int) -> HorizontalSegment {
        HorizontalSegment(id: UUID().uuidString.lowercased(), from: from, to: to, width: 0, layer: layer)
    }

    private func closedBoardDrawingSegments(points: [HorizontalPoint], layer: Int) -> [HorizontalSegment] {
        HorizontalCanvasModeSupport.closedSegmentPairs(points: points).map {
            boardDrawingSegment(from: $0.0, to: $0.1, layer: layer)
        }
    }

    private func boardDrawingArc(from: HorizontalPoint, to: HorizontalPoint, center: HorizontalPoint, layer: Int) -> HorizontalArc {
        HorizontalArc(id: UUID().uuidString.lowercased(), from: from, to: to, center: center, width: 0, layer: layer)
    }

    private func moveSelectionByGrid(_ delta: HorizontalPoint) {
        guard !isReadOnly,
              !selectedObjects.isEmpty,
              delta != .zero else {
            return
        }

        if moveState == nil {
            beginMove(tracksCursor: false)
        }

        guard let state = moveState else {
            return
        }

        HorizontalMoveRateDiagnostics.mark(.keyMove)
        updateMove(to: state.lastPoint + delta)
    }

    private func deleteSelection() {
        // While routing, Delete/Backspace steps the route back a click instead
        // of deleting a selection (there is none during routing).
        if drawTrackState != nil {
            undoLastTrackStep()
            return
        }
        guard !isReadOnly,
              moveState == nil,
              drawGraphicsState == nil,
              pastePlacementState == nil,
              !selectedObjects.isEmpty else {
            return
        }

        let previousBoard = editedBoard ?? sourceBoard
        // Horizon "walk the chain": when deleting a single track/via, line up the
        // next segment so repeated Delete unzips a trace from its free end.
        let unique = uniqueRefs(selectedObjects)
        let chainNext = unique.count == 1
            ? HorizontalBoardChainWalk.selection(afterDeleting: unique[0], in: previousBoard)
            : nil

        var draft = previousBoard
        guard deleteSelectedObjects(from: &draft) else {
            return
        }

        registerUndoSnapshot(previousBoard, actionName: "Delete")
        editedBoard = draft
        invalidateSelectableCache()
        // The neighbour (if any) wasn't deleted, so its ref stays valid through
        // the connectivity recompute below; selecting it renders it highlighted.
        selectedObjects = chainNext.map { [$0] } ?? []
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// Removes a selected junction when it's orphaned (no track / via / line /
    /// arc / net-tie still meets it). Connected junctions are left alone — you
    /// delete the copper, not the node — and a delete commit re-runs connectivity
    /// (`vacuum`) to clear any junctions the removed copper orphaned.
    private func deleteOrphanJunction(_ id: String, from board: inout HorizontalBoard) -> Bool {
        let target = normalizedID(id)
        guard let key = board.junctions.keys.first(where: { normalizedID($0) == target }),
              let point = board.junctions[key] else {
            return false
        }
        let pk = pointKey(point)
        let incident = board.tracks.contains { pointKey($0.from) == pk || pointKey($0.to) == pk }
            || board.vias.contains { pointKey($0.position) == pk }
            || board.netTies.contains { pointKey($0.from) == pk || pointKey($0.to) == pk }
            || board.lines.contains { pointKey($0.from) == pk || pointKey($0.to) == pk }
            || board.arcs.contains { pointKey($0.from) == pk || pointKey($0.to) == pk }
        guard !incident else {
            return false
        }
        board.junctions.removeValue(forKey: key)
        board.junctionNetIDs.removeValue(forKey: key)
        return true
    }

    private func deleteSelectedObjects(from board: inout HorizontalBoard) -> Bool {
        var changed = false
        // Fixed packages can't be deleted — filter them (and their connection
        // lines, added by the expansion) before expanding the delete set.
        let deletable = uniqueRefs(selectedObjects).filter { !isFixedPackage($0, in: board) }
        let refs = expandedBoardDeleteRefs(from: deletable, in: board)

        for ref in refs {
            switch ref.type {
            case .boardPackage:
                changed = deleteBoardPackage(ref.id, from: &board) || changed
            case .track:
                changed = removeElement(from: &board.tracks, matching: ref) || changed
            case .boardNetTie:
                changed = removeElement(from: &board.netTies, matching: ref) || changed
            case .boardLine:
                changed = removeElement(from: &board.lines, matching: ref) || changed
            case .boardArc:
                changed = removeElement(from: &board.arcs, matching: ref) || changed
            case .via:
                changed = removeElement(from: &board.vias, matching: ref) || changed
                let normalizedViaID = normalizedID(ref.id)
                changed = removeAll(from: &board.viaHoles) {
                    normalizedID($0.id) == normalizedViaID || normalizedID($0.id).hasPrefix("\(normalizedViaID)/")
                } || changed
            case .boardHole:
                changed = removeElement(from: &board.holes, matching: ref) || changed
                changed = removeElement(from: &board.packageHoles, matching: ref) || changed
                changed = removeElement(from: &board.viaHoles, matching: ref) || changed
            case .text:
                changed = removeElement(from: &board.texts, matching: ref) || changed
                changed = removeElement(from: &board.packageTexts, matching: ref) || changed
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                changed = deletePolygonVertices(ref, from: &board.polygons) || changed
            case .plane:
                changed = removeElement(from: &board.planes, matching: ref) || changed
            case .keepout:
                changed = removeElement(from: &board.keepouts, matching: ref) || changed
            case .dimension:
                changed = removeElement(from: &board.dimensions, matching: ref) || changed
            case .boardDecal:
                changed = removeElement(from: &board.decals, matching: ref) || changed
            case .connectionLine:
                changed = removeElement(from: &board.connectionLines, matching: ref) || changed
            case .boardPanel:
                changed = deleteBoardPanel(ref.id, from: &board) || changed
            case .junction:
                changed = deleteOrphanJunction(ref.id, from: &board) || changed
            case .pad:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }

        return changed
    }

    private func expandedBoardDeleteRefs(
        from refs: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> [HorizontalSelectableRef] {
        var seen = Set<HorizontalSelectableRef>()
        var expanded = [HorizontalSelectableRef]()

        func append(_ ref: HorizontalSelectableRef) {
            guard seen.insert(ref).inserted else {
                return
            }
            expanded.append(ref)
        }

        refs.forEach(append)

        for ref in refs {
            switch ref.type {
            case .boardPackage:
                let anchorKeys = packageConnectionAnchorKeys(packageID: ref.id, in: board)
                for connectionLine in board.connectionLines
                    where anchorKeys.contains(pointKey(connectionLine.from)) || anchorKeys.contains(pointKey(connectionLine.to)) {
                    append(HorizontalSelectableRef(id: connectionLine.id, type: .connectionLine))
                }
            default:
                break
            }
        }

        return expanded
    }

    private func deleteBoardPackage(_ packageID: String, from board: inout HorizontalBoard) -> Bool {
        let normalizedPackageID = normalizedID(packageID)
        var changed = removeAll(from: &board.packages) { normalizedID($0.id) == normalizedPackageID }
        let anchorKeys = packageConnectionAnchorKeys(packageID: packageID, in: board)

        func belongsToPackage(_ geometryID: String) -> Bool {
            self.packageID(forGeometryID: geometryID).map(normalizedID) == normalizedPackageID
        }

        changed = removeAll(from: &board.packagePads) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageHoles) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packagePolygons) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageLines) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageArcs) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageTexts) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.connectionLines) {
            anchorKeys.contains(pointKey($0.from)) || anchorKeys.contains(pointKey($0.to))
        } || changed
        return changed
    }

    private func deleteBoardPanel(_ panelID: String, from board: inout HorizontalBoard) -> Bool {
        let normalizedPanelID = normalizedID(panelID)
        var changed = removeAll(from: &board.boardPanels) { normalizedID($0.id) == normalizedPanelID }

        func belongsToPanel(_ id: String) -> Bool {
            let normalized = normalizedID(id)
            return normalized == normalizedPanelID || normalized.hasPrefix("\(normalizedPanelID)/")
        }

        changed = removeAll(from: &board.tracks) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.netTies) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.lines) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.arcs) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.connectionLines) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.polygons) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.planes) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.keepouts) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.dimensions) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.decals) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.holes) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.vias) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.viaHoles) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packages) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packagePads) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packageHoles) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packagePolygons) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packageLines) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packageArcs) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.packageTexts) { belongsToPanel($0.id) } || changed
        changed = removeAll(from: &board.texts) { belongsToPanel($0.id) } || changed
        return changed
    }

    private func deletePolygonVertices(_ ref: HorizontalSelectableRef, from polygons: inout [HorizontalPolygon]) -> Bool {
        guard let polygonIndex = polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              polygons[polygonIndex].polygonVertices.indices.contains(ref.vertex) else {
            return false
        }

        if ref.type == .polygonArcCenter {
            polygons[polygonIndex].polygonVertices[ref.vertex].type = .line
            return true
        }

        let indices: [Int]
        if ref.type == .polygonEdge {
            let next = polygons[polygonIndex].nextVertexIndex(after: ref.vertex)
            indices = Array(Set([ref.vertex, next])).sorted(by: >)
        } else {
            indices = [ref.vertex]
        }

        for index in indices where polygons[polygonIndex].polygonVertices.indices.contains(index) {
            polygons[polygonIndex].polygonVertices.remove(at: index)
        }
        if polygons[polygonIndex].polygonVertices.count < 3 || abs(polygons[polygonIndex].area) < 1 {
            polygons.remove(at: polygonIndex)
        }
        return true
    }

    private func packageConnectionAnchorKeys(packageID: String, in board: HorizontalBoard) -> Set<String> {
        let normalizedPackageID = normalizedID(packageID)
        var keys = Set<String>()

        func belongsToPackage(_ geometryID: String) -> Bool {
            self.packageID(forGeometryID: geometryID).map(normalizedID) == normalizedPackageID
        }

        for pad in board.packagePads where belongsToPackage(pad.id) {
            keys.insert(pointKey(HorizontalRect(points: pad.vertices).center))
            pad.vertices.forEach { keys.insert(pointKey($0)) }
        }
        for hole in board.packageHoles where belongsToPackage(hole.id) {
            keys.insert(pointKey(hole.position))
        }
        for package in board.packages where normalizedID(package.id) == normalizedPackageID {
            keys.insert(pointKey(package.position))
        }

        return keys
    }

    private func removeElement<T: Identifiable>(from values: inout [T], matching ref: HorizontalSelectableRef) -> Bool where T.ID == String {
        removeAll(from: &values) { normalizedID($0.id) == normalizedID(ref.id) }
    }

    private func removeAll<T>(from values: inout [T], where shouldRemove: (T) -> Bool) -> Bool {
        let oldCount = values.count
        values.removeAll(where: shouldRemove)
        return values.count != oldCount
    }

    private func mirrorSelection() {
        let cursor = lastCursorWorldPoint
        transformSelection(actionName: "Mirror") { center, draft in
            mirrorSelectedObjects(around: cursor ?? center, board: &draft)
        }
    }

    /// Mirror X — reflect across the vertical axis through the selection center
    /// (flips the X coordinate), independent of the cursor.
    private func mirrorSelectionHorizontal() {
        transformSelection(actionName: "Mirror") { center, draft in
            mirrorSelectedObjects(around: center, board: &draft)
        }
    }

    /// Mirror Y — reflect across the horizontal axis through the selection center
    /// (flips the Y coordinate). Composed as Mirror-X ∘ 180° rotate, which is
    /// exactly a Y reflection and yields the correct layer flip / orientation.
    private func mirrorSelectionVertical() {
        transformSelection(actionName: "Mirror") { center, draft in
            mirrorSelectedObjects(around: center, board: &draft)
            rotateSelectedObjects(around: center, by: Self.quarterTurnAngle * 2, board: &draft)
        }
    }

    private func rotateSelection() {
        let cursor = lastCursorWorldPoint
        transformSelection(actionName: "Rotate") { center, draft in
            rotateSelectedObjects(around: cursor ?? center, by: Self.quarterTurnAngle, board: &draft)
        }
    }

    /// Rotate 90° around the selection center, independent of the cursor.
    private func rotateSelectionAroundCenter() {
        transformSelection(actionName: "Rotate") { center, draft in
            rotateSelectedObjects(around: center, by: Self.quarterTurnAngle, board: &draft)
        }
    }

    /// Move exactly — prompt for an exact mm offset and translate the selection.
    private func moveSelectionExactly() {
        #if os(macOS)
        guard !isReadOnly, !selectedObjects.isEmpty,
              let delta = HorizontalTransformPrompt.runMoveExactly(), delta != .zero else {
            return
        }
        transformSelection(actionName: "Move") { _, draft in
            moveSelectedObjects(by: delta, board: &draft)
        }
        #endif
    }

    /// Rotate arbitrary — prompt for an arbitrary angle (degrees) and rotate the
    /// selection around its center. Degrees map to internal units at the same
    /// scale/sign as the 90° rotate (`quarterTurnAngle` per 90°).
    private func rotateSelectionArbitrary() {
        #if os(macOS)
        guard !isReadOnly, !selectedObjects.isEmpty,
              let degrees = HorizontalTransformPrompt.runRotateDegrees() else {
            return
        }
        let units = Int((degrees / 90.0 * Double(Self.quarterTurnAngle)).rounded())
        guard units != 0 else { return }
        transformSelection(actionName: "Rotate") { center, draft in
            rotateSelectedObjects(around: center, by: units, board: &draft)
        }
        #endif
    }

    private func twirlSelection() {
        let cursor = lastCursorWorldPoint
        transformSelection(actionName: "Twirl") { center, draft in
            rotateSelectedObjects(around: cursor ?? center, by: Self.quarterTurnAngle, board: &draft)
        }
    }

    private func transformSelection(
        actionName: String,
        _ transform: (HorizontalPoint, inout HorizontalBoard) -> Void
    ) {
        guard !isReadOnly,
              !selectedObjects.isEmpty,
              let center = boardSelectionCenter() else {
            return
        }

        let previousBoard = editedBoard ?? sourceBoard
        var draft = previousBoard
        transform(center, &draft)
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        if moveState == nil {
            registerUndoSnapshot(previousBoard, actionName: actionName)
            publishConnectivityResolvedEdit(draft)
        }
        publishSelectionContext()
    }

    private func boardSelectionCenter() -> HorizontalPoint? {
        HorizontalCanvasModeSupport.selectionCenter(for: selectedObjects, anchorPoints: selectionAnchorPoints)
    }

    private func selectionAnchorPoints(for ref: HorizontalSelectableRef) -> [HorizontalPoint] {
        selectionAnchorPoints(for: ref, in: board)
    }

    private func selectionAnchorPoints(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> [HorizontalPoint] {
        switch ref.type {
        case .boardPackage:
            return board.packages.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        case .track:
            return lineSelectionAnchorPoints(for: ref, in: board.tracks)
        case .boardNetTie:
            return lineSelectionAnchorPoints(for: ref, in: board.netTies)
        case .boardLine:
            return lineSelectionAnchorPoints(for: ref, in: board.lines)
        case .connectionLine:
            return lineSelectionAnchorPoints(for: ref, in: board.connectionLines)
        case .junction:
            return board.junctions.first { normalizedID($0.key) == normalizedID(ref.id) }.map { [$0.value] } ?? []
        case .boardArc:
            return board.arcs.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.from, $0.to, $0.center] } ?? []
        case .via:
            return board.vias.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        case .boardHole:
            return (board.holes + board.packageHoles + board.viaHoles)
                .first { normalizedID($0.id) == normalizedID(ref.id) }
                .map { [$0.position] } ?? []
        case .text:
            return (board.texts + board.packageTexts).first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        case .pad:
            return board.packagePads.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [HorizontalRect(points: $0.vertices).center] } ?? []
        case .polygonArcCenter:
            guard let polygon = boardPolygon(for: ref.id, in: board),
                  polygon.polygonVertices.indices.contains(ref.vertex) else {
                return []
            }
            return [polygon.polygonVertices[ref.vertex].arcCenter]
        case .polygonEdge, .polygonVertex:
            return boardPolygon(for: ref.id, in: board)?.renderVertices(arcPrecision: 24) ?? []
        case .keepout:
            return board.keepouts.first { normalizedID($0.id) == normalizedID(ref.id) }?.points ?? []
        case .dimension:
            return board.dimensions.first { normalizedID($0.id) == normalizedID(ref.id) }?.points ?? []
        case .boardDecal:
            return board.decals.first { normalizedID($0.id) == normalizedID(ref.id) }?.points ?? []
        case .plane:
            return board.planes.first { normalizedID($0.id) == normalizedID(ref.id) }?.points ?? []
        default:
            return []
        }
    }

    private func rotationVertex(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalPoint? {
        switch ref.type {
        case .boardArc:
            return board.arcs.first { normalizedID($0.id) == normalizedID(ref.id) }?.center
                ?? selectionAnchorPoints(for: ref, in: board).first
        case .polygonArcCenter:
            guard let polygon = boardPolygon(for: ref.id, in: board),
                  polygon.polygonVertices.indices.contains(ref.vertex) else {
                return nil
            }
            return polygon.polygonVertices[ref.vertex].arcCenter
        case .polygonEdge, .polygonVertex:
            guard let polygon = boardPolygon(for: ref.id, in: board) else {
                return nil
            }
            return polygon.polygonVertices.indices.contains(ref.vertex) ? polygon.polygonVertices[ref.vertex].position : polygon.vertices.first
        case .keepout:
            guard let keepout = board.keepouts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return keepout.points.indices.contains(ref.vertex) ? keepout.points[ref.vertex] : keepout.points.first
        case .dimension:
            guard let dimension = board.dimensions.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return dimension.points.indices.contains(ref.vertex) ? dimension.points[ref.vertex] : dimension.points.first
        case .boardDecal:
            guard let decal = board.decals.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return decal.points.indices.contains(ref.vertex) ? decal.points[ref.vertex] : decal.points.first
        case .plane:
            guard let plane = board.planes.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return plane.points.indices.contains(ref.vertex) ? plane.points[ref.vertex] : plane.points.first
        default:
            return selectionAnchorPoints(for: ref, in: board).first
        }
    }

    private func lineSelectionAnchorPoints(for ref: HorizontalSelectableRef, in segments: [HorizontalSegment]) -> [HorizontalPoint] {
        HorizontalCanvasModeSupport.lineSelectionAnchorPoints(for: ref, in: segments, includesArcCenter: true)
    }

    private func expandedBoardMoveSelection(
        _ refs: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> [HorizontalSelectableRef] {
        BoardMovePlanner.expandedSelection(
            refs,
            tracks: board.tracks,
            netTies: board.netTies,
            junctions: board.junctions,
            junctionNetIDs: board.junctionNetIDs,
            vias: board.vias
        )
    }

    private func boardResidentMovePlan(
        for refs: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> BoardResidentMovePlan {
        BoardMovePlanner.residentMovePlan(
            for: refs,
            tracks: board.tracks,
            netTies: board.netTies,
            junctions: board.junctions,
            junctionNetIDs: board.junctionNetIDs,
            vias: board.vias,
            packagePads: board.packagePads,
            packageHoles: board.packageHoles
        )
    }

    private func moveSelectedObjects(by delta: HorizontalPoint, board: inout HorizontalBoard) {
        var movedConnectionKeys = Set<String>()
        var movedLayerVertexKeys = Set<String>()
        let selectedRefSet = Set(selectedObjects)

        for ref in selectedObjects {
            switch ref.type {
            case .boardPackage:
                moveBoardPackage(ref: ref, by: delta, board: &board)
            case .track:
                if boardSegmentHasSelectedEndpointOwner(ref: ref, in: board.tracks, selectedRefs: selectedRefSet, board: board) {
                    break
                }
                moveBoardTrackSelection(ref: ref, by: delta, in: \.tracks, board: &board, movedKeys: &movedConnectionKeys)
            case .boardNetTie:
                if boardSegmentHasSelectedEndpointOwner(ref: ref, in: board.netTies, selectedRefs: selectedRefSet, board: board) {
                    break
                }
                moveBoardTrackSelection(ref: ref, by: delta, in: \.netTies, board: &board, movedKeys: &movedConnectionKeys)
            case .boardLine:
                moveBoardLayerSegmentSelection(&board.lines, ref: ref, by: delta, movedKeys: &movedLayerVertexKeys)
            case .junction:
                moveBoardJunction(ref: ref, by: delta, board: &board, movedKeys: &movedConnectionKeys)
            case .boardArc:
                moveArc(&board.arcs, ref: ref, by: delta)
            case .via:
                moveVia(ref: ref, by: delta, board: &board)
            case .boardHole:
                moveHole(&board.holes, ref: ref, by: delta)
                moveHole(&board.packageHoles, ref: ref, by: delta)
                moveHole(&board.viaHoles, ref: ref, by: delta)
            case .text:
                moveText(&board.texts, ref: ref, by: delta)
                moveText(&board.packageTexts, ref: ref, by: delta)
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                movePolygon(&board.polygons, ref: ref, by: delta)
            case .pad:
                movePolygon(&board.packagePads, ref: ref, by: delta)
            case .connectionLine:
                moveBoardLayerSegmentSelection(&board.connectionLines, ref: ref, by: delta, movedKeys: &movedLayerVertexKeys)
            case .keepout:
                moveKeepout(&board.keepouts, ref: ref, by: delta)
            case .dimension:
                moveDimension(&board.dimensions, ref: ref, by: delta)
            case .boardDecal:
                moveBoardDecal(&board.decals, ref: ref, by: delta)
            case .plane:
                movePlane(&board.planes, ref: ref, by: delta)
            case .boardPanel:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }
    }

    private func mirrorSelectedObjects(around center: HorizontalPoint, board: inout HorizontalBoard) {
        for ref in selectedObjects {
            switch ref.type {
            case .boardPackage:
                mirrorBoardPackage(ref: ref, around: center, board: &board)
            case .track:
                mirrorSegment(&board.tracks, ref: ref, around: center, flipsLayer: true)
            case .boardNetTie:
                mirrorSegment(&board.netTies, ref: ref, around: center, flipsLayer: true)
            case .boardLine:
                mirrorSegment(&board.lines, ref: ref, around: center, flipsLayer: false)
            case .boardArc:
                mirrorArc(&board.arcs, ref: ref, around: center, flipsLayer: false)
            case .via:
                mirrorVia(ref: ref, around: center, board: &board)
            case .boardHole:
                mirrorHole(&board.holes, ref: ref, around: center)
                mirrorHole(&board.packageHoles, ref: ref, around: center)
                mirrorHole(&board.viaHoles, ref: ref, around: center)
            case .text:
                mirrorText(&board.texts, ref: ref, around: center)
                mirrorText(&board.packageTexts, ref: ref, around: center)
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                mirrorPolygon(&board.polygons, ref: ref, around: center, flipsLayer: false)
            case .pad:
                mirrorPolygon(&board.packagePads, ref: ref, around: center, flipsLayer: true)
            case .boardDecal, .boardPanel, .dimension, .keepout, .plane:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .connectionLine, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }
    }

    private func rotateSelectedObjects(around center: HorizontalPoint, by angleDelta: Int, board: inout HorizontalBoard) {
        rotateSelectedObjects(by: angleDelta, board: &board) { _ in center }
    }

    private func rotateSelectedObjectsAroundVertices(by angleDelta: Int, board: inout HorizontalBoard) {
        let origins = selectedObjects.reduce(into: [HorizontalSelectableRef: HorizontalPoint]()) { result, ref in
            result[ref] = rotationVertex(for: ref, in: board)
        }
        rotateSelectedObjects(by: angleDelta, board: &board) { ref in
            origins[ref]
        }
    }

    private func rotateSelectedObjects(
        by angleDelta: Int,
        board: inout HorizontalBoard,
        originFor refOrigin: (HorizontalSelectableRef) -> HorizontalPoint?
    ) {
        var movedConnectionKeys = Set<String>()

        for ref in selectedObjects {
            guard let center = refOrigin(ref) else {
                continue
            }
            switch ref.type {
            case .boardPackage:
                rotateBoardPackage(ref: ref, around: center, by: angleDelta, board: &board)
            case .track:
                rotateBoardTrack(ref: ref, around: center, by: angleDelta, in: \.tracks, board: &board, movedKeys: &movedConnectionKeys)
            case .boardNetTie:
                rotateBoardTrack(ref: ref, around: center, by: angleDelta, in: \.netTies, board: &board, movedKeys: &movedConnectionKeys)
            case .boardLine:
                rotateSegment(&board.lines, ref: ref, around: center, by: angleDelta)
            case .boardArc:
                rotateArc(&board.arcs, ref: ref, around: center, by: angleDelta)
            case .via:
                rotateVia(ref: ref, around: center, by: angleDelta, board: &board)
            case .boardHole:
                rotateHole(&board.holes, ref: ref, around: center, by: angleDelta)
                rotateHole(&board.packageHoles, ref: ref, around: center, by: angleDelta)
                rotateHole(&board.viaHoles, ref: ref, around: center, by: angleDelta)
            case .text:
                rotateText(&board.texts, ref: ref, around: center, by: angleDelta)
                rotateText(&board.packageTexts, ref: ref, around: center, by: angleDelta)
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                rotatePolygon(&board.polygons, ref: ref, around: center, by: angleDelta)
            case .pad:
                rotatePolygon(&board.packagePads, ref: ref, around: center, by: angleDelta)
            case .boardDecal, .boardPanel, .dimension, .keepout, .plane:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .connectionLine, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }
    }

    private func moveBoardPackage(ref: HorizontalSelectableRef, by delta: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              !board.packages[index].fixed else {
            return
        }

        keepBoardTracksConnectedToMovingPackage(packageID: ref.id, delta: delta, board: &board)
        board.packages[index].position = board.packages[index].position + delta
        shiftBoardPackageGeometry(packageID: ref.id, by: delta, board: &board)
    }

    private func mirrorBoardPackage(ref: HorizontalSelectableRef, around center: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              !board.packages[index].fixed else {
            return
        }

        let anchors = boardPackageConnectionAnchors(packageID: ref.id, board: board)
        board.packages[index].position = mirrored(board.packages[index].position, around: center)
        board.packages[index].angle = wrappedAngle(-board.packages[index].angle)
        board.packages[index].mirrored.toggle()
        mirrorBoardPackageGeometry(packageID: ref.id, around: center, board: &board)
        for anchor in anchors {
            moveBoardTrackEndpoints(
                at: anchor.point,
                by: mirrored(anchor.point, around: center) - anchor.point,
                netID: anchor.netID,
                board: &board
            )
        }
    }

    private func rotateBoardPackage(ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int, board: inout HorizontalBoard) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              !board.packages[index].fixed else {
            return
        }

        let anchors = boardPackageConnectionAnchors(packageID: ref.id, board: board)
        let original = board.packages[index]
        board.packages[index].position = rotated(original.position, around: center, by: angleDelta)
        board.packages[index].angle = wrappedAngle(original.angle + angleDelta)
        rotateBoardPackageGeometry(packageID: ref.id, around: center, by: angleDelta, board: &board)
        for anchor in anchors {
            let rotatedPoint = rotated(anchor.point, around: center, by: angleDelta)
            moveBoardTrackEndpoints(
                at: anchor.point,
                by: rotatedPoint - anchor.point,
                netID: anchor.netID,
                board: &board
            )
        }
    }

    /// Flips a package to the opposite board side in place — `flip`
    /// (board_package.cpp `update_package`: `placement.mirror = flip` + every
    /// geometry layer flipped top↔bottom), NOT the mirror tool. Position and
    /// angle are preserved; only side/mirror change.
    ///
    /// The geometry is stored already-transformed (pool point → `Rot(θ)·M·p +
    /// shift`), so going from the un-mirrored to the mirrored state about the
    /// package origin is a reflection across the package's local-Y axis plus a
    /// layer flip. With `mirrored(_:around:)` being a reflection across the
    /// *vertical* line through the center, conjugating the local-x reflection by
    /// the package rotation gives exactly: vertical-reflect (with layer flip)
    /// then rotate by `2·angle` about the package origin. (Verified at θ = 0°,
    /// 90°, 45°, 180°.) Reload re-derives the same geometry from the pool with
    /// the persisted `flip`, so the in-memory result matches a fresh load.
    private func flipBoardPackage(ref: HorizontalSelectableRef, board: inout HorizontalBoard) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        let center = board.packages[index].position
        let rotation = 2 * board.packages[index].angle
        let anchors = boardPackageConnectionAnchors(packageID: ref.id, board: board)

        mirrorBoardPackageGeometry(packageID: ref.id, around: center, board: &board)
        rotateBoardPackageGeometry(packageID: ref.id, around: center, by: rotation, board: &board)
        board.packages[index].mirrored.toggle()

        for anchor in anchors {
            let flipped = rotated(mirrored(anchor.point, around: center), around: center, by: rotation)
            moveBoardTrackEndpoints(
                at: anchor.point,
                by: flipped - anchor.point,
                netID: anchor.netID,
                board: &board
            )
        }
    }

    private func keepBoardTracksConnectedToMovingPackage(
        packageID: String,
        delta: HorizontalPoint,
        board: inout HorizontalBoard
    ) {
        let anchors = boardPackageConnectionAnchors(packageID: packageID, board: board)
        guard !anchors.isEmpty else {
            return
        }

        for anchor in anchors {
            moveBoardTrackEndpoints(at: anchor.point, by: delta, netID: anchor.netID, board: &board)
        }
    }

    private func boardPackageConnectionAnchors(packageID: String, board: HorizontalBoard) -> [MovingConnectionPoint] {
        let normalizedPackageID = normalizedID(packageID)
        func belongsToPackage(_ geometryID: String) -> Bool {
            self.packageID(forGeometryID: geometryID).map(normalizedID) == normalizedPackageID
        }

        let padAnchors = board.packagePads
            .filter { belongsToPackage($0.id) }
            .map { MovingConnectionPoint(point: HorizontalRect(points: $0.vertices).center, netID: $0.netID) }
        let holeAnchors = board.packageHoles
            .filter { belongsToPackage($0.id) }
            .map { MovingConnectionPoint(point: $0.position, netID: $0.netID) }
        return padAnchors + holeAnchors
    }

    private func moveVia(ref: HorizontalSelectableRef, by delta: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = board.vias.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let oldPosition = board.vias[index].position
        board.vias[index].position = oldPosition + delta
        moveHole(&board.viaHoles, ref: ref, by: delta)
        moveBoardTrackEndpoints(at: oldPosition, by: delta, netID: board.vias[index].netID, board: &board)
    }

    private func rotateVia(ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int, board: inout HorizontalBoard) {
        guard let index = board.vias.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let oldPosition = board.vias[index].position
        let newPosition = rotated(oldPosition, around: center, by: angleDelta)
        board.vias[index].position = newPosition
        rotateHole(&board.viaHoles, ref: ref, around: center, by: angleDelta)
        moveBoardTrackEndpoints(at: oldPosition, by: newPosition - oldPosition, netID: board.vias[index].netID, board: &board)
    }

    private func moveBoardJunction(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        guard let entry = board.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
            return
        }
        moveBoardConnectionPoint(
            at: entry.value,
            by: delta,
            netID: board.junctionNetIDs[entry.key],
            board: &board,
            movedKeys: &movedKeys
        )
    }

    private func boardSegmentHasSelectedEndpointOwner(
        ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        selectedRefs: Set<HorizontalSelectableRef>,
        board: HorizontalBoard
    ) -> Bool {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return false
        }
        let owners = boardMovableEndpointOwnerRefs(at: segment.from, netID: segment.netID, board: board, includesPackages: true)
            + boardMovableEndpointOwnerRefs(at: segment.to, netID: segment.netID, board: board, includesPackages: true)
        return owners.contains { selectedRefs.contains($0) }
    }

    private func boardMovableEndpointOwnerRefs(
        at point: HorizontalPoint,
        netID: String?,
        board: HorizontalBoard,
        includesPackages: Bool
    ) -> [HorizontalSelectableRef] {
        BoardMovePlanner.movableEndpointOwnerRefs(
            at: point,
            netID: netID,
            junctions: board.junctions,
            junctionNetIDs: board.junctionNetIDs,
            vias: board.vias,
            packages: board.packages,
            packagePads: board.packagePads,
            packageHoles: board.packageHoles,
            includesPackages: includesPackages
        )
    }

    private func moveBoardTrackEndpoints(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        netID: String?,
        board: inout HorizontalBoard
    ) {
        let key = pointKey(point)
        for index in board.tracks.indices where netsMatch(board.tracks[index].netID, netID) {
            if pointKey(board.tracks[index].from) == key {
                board.tracks[index].from = board.tracks[index].from + delta
            }
            if pointKey(board.tracks[index].to) == key {
                board.tracks[index].to = board.tracks[index].to + delta
            }
        }
        for index in board.netTies.indices where netsMatch(board.netTies[index].netID, netID) {
            if pointKey(board.netTies[index].from) == key {
                board.netTies[index].from = board.netTies[index].from + delta
            }
            if pointKey(board.netTies[index].to) == key {
                board.netTies[index].to = board.netTies[index].to + delta
            }
        }
        var movedJunctionIDs = [String]()
        for junctionID in board.junctions.keys where pointKey(board.junctions[junctionID] ?? .zero) == key {
            board.junctions[junctionID] = (board.junctions[junctionID] ?? .zero) + delta
            movedJunctionIDs.append(junctionID)
        }
        if let preferredID = movedJunctionIDs.first {
            mergeBoardJunctions(
                at: point + delta,
                preferredID: preferredID,
                netID: board.junctionNetIDs[preferredID] ?? netID,
                board: &board
            )
        }
    }

    private func moveBoardTrackSelection(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        in segments: WritableKeyPath<HorizontalBoard, [HorizontalSegment]>,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        moveBoardTrack(ref: ref, by: delta, in: segments, board: &board, movedKeys: &movedKeys)
    }

    private func moveBoardLayerConnectionPoint(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        layer: Int?,
        netID: String?,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        let moveKey = "\(pointKey(point)):\(layer.map(String.init) ?? "nil")"
        guard movedKeys.insert(moveKey).inserted else {
            return
        }

        moveBoardSegmentEndpoints(at: point, layer: layer, by: delta, in: &board.tracks)
        moveBoardSegmentEndpoints(at: point, layer: layer, by: delta, in: &board.netTies)
        moveBoardSegmentEndpoints(at: point, layer: layer, by: delta, in: &board.lines)
        moveBoardSegmentEndpoints(at: point, layer: layer, by: delta, in: &board.connectionLines)

        let key = pointKey(point)
        var movedJunctionIDs = [String]()
        for junctionID in board.junctions.keys where pointKey(board.junctions[junctionID] ?? .zero) == key {
            board.junctions[junctionID] = (board.junctions[junctionID] ?? .zero) + delta
            movedJunctionIDs.append(junctionID)
        }
        if let preferredID = movedJunctionIDs.first {
            mergeBoardJunctions(
                at: point + delta,
                preferredID: preferredID,
                netID: board.junctionNetIDs[preferredID] ?? netID,
                board: &board
            )
        }
        for index in board.vias.indices where pointKey(board.vias[index].position) == key && netsMatch(board.vias[index].netID, netID) {
            board.vias[index].position = board.vias[index].position + delta
        }
        for index in board.viaHoles.indices where pointKey(board.viaHoles[index].position) == key && netsMatch(board.viaHoles[index].netID, netID) {
            board.viaHoles[index].position = board.viaHoles[index].position + delta
        }
    }

    private func moveBoardLayerSegmentSelection(
        _ segments: inout [HorizontalSegment],
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        movedKeys: inout Set<String>
    ) {
        moveSegment(&segments, ref: ref, by: delta)
    }

    private func moveBoardSegmentEndpoints(
        at point: HorizontalPoint,
        layer: Int?,
        by delta: HorizontalPoint,
        in segments: inout [HorizontalSegment]
    ) {
        let key = pointKey(point)
        for index in segments.indices where segments[index].layer == layer {
            if pointKey(segments[index].from) == key {
                segments[index].from = segments[index].from + delta
            }
            if pointKey(segments[index].to) == key {
                segments[index].to = segments[index].to + delta
            }
        }
    }

    private func moveBoardTrack(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        in segments: WritableKeyPath<HorizontalBoard, [HorizontalSegment]>,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        guard let index = board[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = board[keyPath: segments][index]
        if hasBoardMovableConnection(at: original.from, in: board) {
            moveBoardConnectionPoint(at: original.from, by: delta, netID: original.netID, board: &board, movedKeys: &movedKeys)
        } else {
            board[keyPath: segments][index].from = board[keyPath: segments][index].from + delta
        }
        if hasBoardMovableConnection(at: original.to, in: board) {
            moveBoardConnectionPoint(at: original.to, by: delta, netID: original.netID, board: &board, movedKeys: &movedKeys)
        } else {
            board[keyPath: segments][index].to = board[keyPath: segments][index].to + delta
        }
        if original.center != nil,
           let updatedIndex = board[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            board[keyPath: segments][updatedIndex].center = board[keyPath: segments][updatedIndex].center.map { $0 + delta }
        }
    }

    private func rotateBoardTrack(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        in segments: WritableKeyPath<HorizontalBoard, [HorizontalSegment]>,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        guard let index = board[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = board[keyPath: segments][index]
        if hasBoardMovableConnection(at: original.from, in: board) {
            rotateBoardConnectionPoint(at: original.from, around: center, by: angleDelta, netID: original.netID, board: &board, movedKeys: &movedKeys)
        } else if let updatedIndex = board[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            board[keyPath: segments][updatedIndex].from = rotated(original.from, around: center, by: angleDelta)
        }
        if hasBoardMovableConnection(at: original.to, in: board) {
            rotateBoardConnectionPoint(at: original.to, around: center, by: angleDelta, netID: original.netID, board: &board, movedKeys: &movedKeys)
        } else if let updatedIndex = board[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            board[keyPath: segments][updatedIndex].to = rotated(original.to, around: center, by: angleDelta)
        }
        if let originalCenter = original.center,
           let updatedIndex = board[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            board[keyPath: segments][updatedIndex].center = rotated(originalCenter, around: center, by: angleDelta)
        }
    }

    private func moveBoardConnectionPoint(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        netID: String?,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        guard delta != .zero else {
            return
        }

        let key = pointKey(point)
        guard movedKeys.insert(key).inserted else {
            return
        }

        moveBoardTrackEndpoints(at: point, by: delta, netID: netID, board: &board)
        for index in board.vias.indices where pointKey(board.vias[index].position) == key && netsMatch(board.vias[index].netID, netID) {
            board.vias[index].position = board.vias[index].position + delta
        }
        for index in board.viaHoles.indices where pointKey(board.viaHoles[index].position) == key && netsMatch(board.viaHoles[index].netID, netID) {
            board.viaHoles[index].position = board.viaHoles[index].position + delta
        }
    }

    private func rotateBoardConnectionPoint(
        at point: HorizontalPoint,
        around center: HorizontalPoint,
        by angleDelta: Int,
        netID: String?,
        board: inout HorizontalBoard,
        movedKeys: inout Set<String>
    ) {
        let newPoint = rotated(point, around: center, by: angleDelta)
        moveBoardConnectionPoint(at: point, by: newPoint - point, netID: netID, board: &board, movedKeys: &movedKeys)
    }

    private func hasBoardMovableConnection(at point: HorizontalPoint, in board: HorizontalBoard) -> Bool {
        let key = pointKey(point)
        if board.junctions.values.contains(where: { pointKey($0) == key }) {
            return true
        }
        if board.vias.contains(where: { pointKey($0.position) == key }) {
            return true
        }
        return false
    }

    private func moveSegment(_ segments: inout [HorizontalSegment], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = segments.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        segments[index] = shifted(segments[index], by: delta)
    }

    private func moveArc(_ arcs: inout [HorizontalArc], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = arcs.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        arcs[index] = shifted(arcs[index], by: delta)
    }

    private func moveHole(_ holes: inout [HorizontalHole], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = holes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        holes[index] = shifted(holes[index], by: delta)
    }

    private func moveText(_ texts: inout [HorizontalText], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        texts[index] = shifted(texts[index], by: delta)
    }

    private func movePolygon(_ polygons: inout [HorizontalPolygon], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        if ref.type == .polygonArcCenter, polygons[index].polygonVertices.indices.contains(ref.vertex) {
            polygons[index].polygonVertices[ref.vertex].arcCenter = polygons[index].polygonVertices[ref.vertex].arcCenter + delta
            return
        }
        if ref.type == .polygonVertex, polygons[index].polygonVertices.indices.contains(ref.vertex) {
            polygons[index].polygonVertices[ref.vertex].position = polygons[index].polygonVertices[ref.vertex].position + delta
            return
        }
        polygons[index] = shifted(polygons[index], by: delta)
    }

    private func moveKeepout(_ keepouts: inout [HorizontalKeepout], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = keepouts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        keepouts[index] = shifted(keepouts[index], by: delta)
    }

    private func moveDimension(_ dimensions: inout [HorizontalDimension], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = dimensions.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        dimensions[index] = shifted(dimensions[index], by: delta)
    }

    private func moveBoardDecal(_ decals: inout [HorizontalBoardDecal], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = decals.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        decals[index] = shifted(decals[index], by: delta)
    }

    private func movePlane(_ planes: inout [HorizontalPlane], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = planes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        planes[index] = shifted(planes[index], by: delta)
    }

    private func mirrorVia(ref: HorizontalSelectableRef, around center: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = board.vias.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let oldPosition = board.vias[index].position
        let newPosition = mirrored(oldPosition, around: center)
        board.vias[index].position = newPosition
        mirrorHole(&board.viaHoles, ref: ref, around: center)
        moveBoardTrackEndpoints(at: oldPosition, by: newPosition - oldPosition, netID: board.vias[index].netID, board: &board)
    }

    private func mirrorSegment(
        _ segments: inout [HorizontalSegment],
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        flipsLayer: Bool
    ) {
        guard let index = segments.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        segments[index] = mirrored(segments[index], around: center, flipsLayer: flipsLayer)
    }

    private func mirrorArc(
        _ arcs: inout [HorizontalArc],
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        flipsLayer: Bool
    ) {
        guard let index = arcs.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        arcs[index] = mirrored(arcs[index], around: center, flipsLayer: flipsLayer)
    }

    private func mirrorHole(_ holes: inout [HorizontalHole], ref: HorizontalSelectableRef, around center: HorizontalPoint) {
        guard let index = holes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        holes[index] = mirrored(holes[index], around: center)
    }

    private func mirrorText(_ texts: inout [HorizontalText], ref: HorizontalSelectableRef, around center: HorizontalPoint) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        texts[index] = mirrored(texts[index], around: center, flipsLayer: false)
    }

    private func mirrorPolygon(
        _ polygons: inout [HorizontalPolygon],
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        flipsLayer: Bool
    ) {
        guard let index = polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        if ref.type == .polygonArcCenter, polygons[index].polygonVertices.indices.contains(ref.vertex) {
            polygons[index].polygonVertices[ref.vertex].arcCenter = mirrored(polygons[index].polygonVertices[ref.vertex].arcCenter, around: center)
            polygons[index].polygonVertices[ref.vertex].arcReverse.toggle()
            return
        }
        if ref.type == .polygonVertex, polygons[index].polygonVertices.indices.contains(ref.vertex) {
            polygons[index].polygonVertices[ref.vertex].position = mirrored(polygons[index].polygonVertices[ref.vertex].position, around: center)
            return
        }
        polygons[index] = mirrored(polygons[index], around: center, flipsLayer: flipsLayer)
    }

    private func rotateSegment(_ segments: inout [HorizontalSegment], ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int) {
        guard let index = segments.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        segments[index] = rotated(segments[index], around: center, by: angleDelta)
    }

    private func rotateArc(_ arcs: inout [HorizontalArc], ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int) {
        guard let index = arcs.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        arcs[index] = rotated(arcs[index], around: center, by: angleDelta)
    }

    private func rotateHole(_ holes: inout [HorizontalHole], ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int) {
        guard let index = holes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        holes[index] = rotated(holes[index], around: center, by: angleDelta)
    }

    private func rotateText(_ texts: inout [HorizontalText], ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        texts[index] = rotated(texts[index], around: center, by: angleDelta)
    }

    private func rotatePolygon(_ polygons: inout [HorizontalPolygon], ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int) {
        guard let index = polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        if ref.type == .polygonArcCenter, polygons[index].polygonVertices.indices.contains(ref.vertex) {
            polygons[index].polygonVertices[ref.vertex].arcCenter = rotated(polygons[index].polygonVertices[ref.vertex].arcCenter, around: center, by: angleDelta)
            return
        }
        if ref.type == .polygonVertex, polygons[index].polygonVertices.indices.contains(ref.vertex) {
            polygons[index].polygonVertices[ref.vertex].position = rotated(polygons[index].polygonVertices[ref.vertex].position, around: center, by: angleDelta)
            return
        }
        polygons[index] = rotated(polygons[index], around: center, by: angleDelta)
    }

    private func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return normalizedID(lhs) == normalizedID(rhs)
    }

    private func applySelectionPropertyChange(_ change: HorizontalSelectionPropertyChange) {
        guard !isReadOnly else {
            return
        }
        let previousBoard = editedBoard ?? sourceBoard
        var draft = previousBoard
        let refs = change.applyToAll
            ? selectedObjects.filter { $0.type == change.type }
            : [change.ref]

        guard !refs.isEmpty else {
            return
        }

        var changedNetClasses = [(netID: String, netClassID: String?)]()
        var changedComponentRefdes = [(componentID: String, refdes: String)]()
        for ref in refs {
            apply(
                change.value,
                propertyID: change.propertyID,
                to: ref,
                board: &draft,
                changedNetClasses: &changedNetClasses,
                changedComponentRefdes: &changedComponentRefdes
            )
        }
        registerUndoSnapshot(previousBoard, actionName: "Edit Properties")
        editedBoard = draft
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        for change in changedNetClasses {
            onNetClassChange(change.netID, change.netClassID)
        }
        for change in changedComponentRefdes {
            onComponentRefdesChange(change.componentID, change.refdes)
        }
        publishSelectionContext()
    }

    private func configureUndoTarget() {
        undoTarget.configure(
            currentValue: { board },
            restoreValue: { value in
                let previousPackages = board.packages
                let previousDetails = board.netDetails
                editedBoard = value
                invalidateSelectableCache()
                moveState = nil
                hoveredObject = nil
                onBoardChange(value)
                reportNetClassDifferences(from: previousDetails, to: value.netDetails)
                reportComponentRefdesDifferences(from: previousPackages, to: value.packages)
            }
        )
    }

    /// Commit funnel: re-derive net connectivity (nets flow from pads; copper
    /// that reaches none goes net-less → orange), store it as the edited draft,
    /// and publish. Every editing commit routes its board through here so a drawn
    /// track without a connection, or copper left dangling by a delete/move,
    /// disconnects automatically (mirrors propagate_nets after edits).
    private func publishConnectivityResolvedEdit(_ board: HorizontalBoard) {
        let resolved = HorizontalBoardConnectivity.recompute(board)
        // A net change is a color change (net-less copper is orange), so force a
        // metal-scene rebuild even when the edit would otherwise patch in place.
        if resolved.tracks.map(\.netID) != board.tracks.map(\.netID) {
            metalSceneRevision &+= 1
        }
        editedBoard = resolved
        onBoardChange(resolved)
    }

    private func registerUndoSnapshot(_ previousBoard: HorizontalBoard, actionName: String) {
        configureUndoTarget()
        undoTarget.registerUndo(
            from: previousBoard,
            actionName: actionName,
            undoManager: undoManager
        )
    }

    private func apply(
        _ value: HorizontalSelectionPropertyValue,
        propertyID: String,
        to ref: HorizontalSelectableRef,
        board: inout HorizontalBoard,
        changedNetClasses: inout [(netID: String, netClassID: String?)],
        changedComponentRefdes: inout [(componentID: String, refdes: String)]
    ) {
        if propertyID == "netClass", case .choice(let classID) = value {
            updateNetClass(for: netID(for: ref), classID: classID, board: &board, changedNetClasses: &changedNetClasses)
            return
        }

        switch ref.type {
        case .track:
            updateSegment(&board.tracks, ref: ref, propertyID: propertyID, value: value)
        case .boardNetTie:
            updateSegment(&board.netTies, ref: ref, propertyID: propertyID, value: value)
        case .boardLine:
            updateSegment(&board.lines, ref: ref, propertyID: propertyID, value: value)
        case .boardArc:
            updateArc(&board.arcs, ref: ref, propertyID: propertyID, value: value)
        case .via:
            updateVia(ref: ref, propertyID: propertyID, value: value, board: &board)
        case .boardHole:
            updateHole(&board.holes, ref: ref, propertyID: propertyID, value: value)
            updateHole(&board.packageHoles, ref: ref, propertyID: propertyID, value: value)
            updateHole(&board.viaHoles, ref: ref, propertyID: propertyID, value: value)
        case .plane:
            updatePlane(ref: ref, propertyID: propertyID, value: value, board: &board)
        case .keepout:
            updateKeepout(&board.keepouts, ref: ref, propertyID: propertyID, value: value)
        case .dimension:
            updateDimension(&board.dimensions, ref: ref, propertyID: propertyID, value: value)
        case .text:
            updateText(&board.texts, ref: ref, propertyID: propertyID, value: value)
            updateText(&board.packageTexts, ref: ref, propertyID: propertyID, value: value)
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            updatePolygon(&board.polygons, ref: ref, propertyID: propertyID, value: value)
        case .pad:
            updatePad(&board.packagePads, ref: ref, propertyID: propertyID, value: value)
        case .boardPackage:
            updateBoardPackage(
                ref: ref,
                propertyID: propertyID,
                value: value,
                board: &board,
                changedComponentRefdes: &changedComponentRefdes
            )
        case .blockSymbolPort, .boardDecal, .boardPanel, .busLabel, .busRipper, .connectionLine, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            break
        }
    }

    private func updateNetClass(
        for netID: String?,
        classID: String,
        board: inout HorizontalBoard,
        changedNetClasses: inout [(netID: String, netClassID: String?)]
    ) {
        guard let netID else {
            return
        }

        let normalizedNetID = normalizedID(netID)
        let normalizedClassID = classID == Self.noNetClassChoiceID ? nil : normalizedID(classID)
        var detail = board.netDetails[normalizedNetID] ?? HorizontalNetDetails(
            id: normalizedNetID,
            name: shortID(netID),
            netClassID: nil,
            netClassName: nil
        )
        detail.netClassID = normalizedClassID
        detail.netClassName = normalizedClassID.flatMap { classID in
            netClasses.first { normalizedID($0.id) == classID }?.name
        }
        board.netDetails[normalizedNetID] = detail
        changedNetClasses.append((normalizedNetID, normalizedClassID))
    }

    private func reportNetClassDifferences(
        from previousDetails: [String: HorizontalNetDetails],
        to currentDetails: [String: HorizontalNetDetails]
    ) {
        let netIDs = Set(previousDetails.keys).union(currentDetails.keys)
        for netID in netIDs {
            let previousClassID = previousDetails[netID]?.netClassID.map(normalizedID)
            let currentClassID = currentDetails[netID]?.netClassID.map(normalizedID)
            guard previousClassID != currentClassID else {
                continue
            }
            onNetClassChange(netID, currentClassID)
        }
    }

    private func updateSegment(
        _ segments: inout [HorizontalSegment],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = segments.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("width", .length(let width)):
            segments[index].width = max(width, 0)
        case ("layer", .layer(let layer)):
            segments[index].layer = layer
        default:
            break
        }
    }

    private func updateArc(
        _ arcs: inout [HorizontalArc],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = arcs.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("width", .length(let width)):
            arcs[index].width = max(width, 0)
        case ("layer", .layer(let layer)):
            arcs[index].layer = layer
        default:
            break
        }
    }

    private func updateMarker(
        _ markers: inout [HorizontalMarker],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = markers.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("diameter", .length(let diameter)):
            markers[index].size = max(diameter, 0)
        case ("positionX", .length(let x)):
            markers[index].position.x = x
        case ("positionY", .length(let y)):
            markers[index].position.y = y
        default:
            break
        }
    }

    private func updateVia(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        board: inout HorizontalBoard
    ) {
        guard let index = board.vias.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("diameter", .length(let diameter)):
            board.vias[index].size = max(diameter, 0)
        case ("positionX", .length(let x)):
            let delta = HorizontalPoint(x: x - board.vias[index].position.x, y: 0)
            moveVia(ref: ref, by: delta, board: &board)
        case ("positionY", .length(let y)):
            let delta = HorizontalPoint(x: 0, y: y - board.vias[index].position.y)
            moveVia(ref: ref, by: delta, board: &board)
        default:
            break
        }
    }

    private func updateHole(
        _ holes: inout [HorizontalHole],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = holes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("diameter", .length(let diameter)):
            holes[index].diameter = max(diameter, 0)
            holes[index].length = max(holes[index].effectiveLength, holes[index].diameter)
        case ("length", .length(let length)):
            holes[index].length = max(length, holes[index].diameter)
            holes[index].shape = holes[index].effectiveLength > holes[index].diameter ? .slot : .round
        case ("positionX", .length(let x)):
            holes[index].position.x = x
        case ("positionY", .length(let y)):
            holes[index].position.y = y
        case ("plated", .bool(let plated)):
            holes[index].plated = plated
        default:
            break
        }
    }

    /// Applies an inspector edit to a plane. Takes the whole board because a
    /// layer change must also re-layer the plane's linked polygon (a
    /// plane has no layer of its own — it derives from the polygon). Pour-related
    /// edits take effect on the next "Update All Planes"; the persisted JSON is
    /// updated immediately by the normal property funnel.
    private func updatePlane(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        board: inout HorizontalBoard
    ) {
        guard let index = board.planes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        switch (propertyID, value) {
        case ("priority", .choice(let priority)):
            if let priority = Int(priority) {
                board.planes[index].priority = priority
            }
        case ("net", .choice(let netID)):
            board.planes[index].netID = normalizedID(netID)
        case ("fromRules", .bool(let on)):
            board.planes[index].fromRules = on
        case ("fill", .choice(let style)):
            board.planes[index].settings.fillStyle = (style == "hatch") ? .hatch : .solid
            board.planes[index].fillStyle = style
        case ("minWidth", .length(let width)):
            let nm = Int(max(width, 0).rounded())
            board.planes[index].settings.minWidth = nm
            board.planes[index].minWidth = Double(nm)
        case ("keepOrphans", .bool(let on)):
            board.planes[index].settings.keepOrphans = on
            board.planes[index].keepOrphans = on
        case ("layer", .layer(let layer)):
            board.planes[index].layer = layer
            let polygonID = board.planes[index].polygonID
            if let polygonIndex = board.polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(polygonID) }) {
                board.polygons[polygonIndex].layer = layer
            }
        default:
            break
        }
    }

    private func planeFillStyleID(_ style: HorizontalPlaneSettings.FillStyle) -> String {
        switch style {
        case .solid: return "solid"
        case .hatch: return "hatch"
        }
    }

    private func updateKeepout(
        _ keepouts: inout [HorizontalKeepout],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard propertyID == "keepoutClass",
              case .text(let keepoutClass) = value,
              let index = keepouts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        keepouts[index].keepoutClass = keepoutClass
    }

    private func updateDimension(
        _ dimensions: inout [HorizontalDimension],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = dimensions.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("size", .length(let size)):
            dimensions[index].labelSize = max(size, 0)
        case ("mode", .choice(let mode)):
            if let mode = HorizontalDimensionMode(rawValue: mode) {
                dimensions[index].mode = mode
            }
        default:
            break
        }
    }

    private func updateText(
        _ texts: inout [HorizontalText],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("text", .text(let text)):
            texts[index].text = text
        case ("size", .length(let size)):
            texts[index].size = max(size, 0)
        case ("width", .length(let width)):
            texts[index].width = max(width, 0)
        case ("layer", .layer(let layer)):
            texts[index].layer = layer
        case ("positionX", .length(let x)):
            texts[index].position.x = x
        case ("positionY", .length(let y)):
            texts[index].position.y = y
        case ("angle", .angle(let angle)):
            texts[index].angle = storedTextAngle(fromDisplayAngle: angle, mirrored: texts[index].mirrored)
        case ("mirror", .bool(let mirrored)):
            setTextMirror(mirrored, for: &texts[index])
        case ("allowUpsideDown", .bool(let allowUpsideDown)):
            texts[index].allowUpsideDown = allowUpsideDown
        default:
            break
        }
    }

    private func displayAngle(for text: HorizontalText) -> Int {
        text.mirrored ? wrappedAngle(32_768 - text.angle) : wrappedAngle(text.angle)
    }

    private func storedTextAngle(fromDisplayAngle angle: Int, mirrored: Bool) -> Int {
        mirrored ? wrappedAngle(32_768 - angle) : wrappedAngle(angle)
    }

    private func setTextMirror(_ mirrored: Bool, for text: inout HorizontalText) {
        guard text.mirrored != mirrored else {
            return
        }

        let displayAngle = displayAngle(for: text)
        text.mirrored = mirrored
        text.angle = storedTextAngle(fromDisplayAngle: displayAngle, mirrored: mirrored)
    }

    private func updatePad(
        _ pads: inout [HorizontalPolygon],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard propertyID == "layer",
              case .layer(let layer) = value,
              let index = pads.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        pads[index].layer = layer
    }

    private func updateBoardPackage(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        board: inout HorizontalBoard,
        changedComponentRefdes: inout [(componentID: String, refdes: String)]
    ) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("refdes", .text(let refdes)):
            updateComponentRefdes(
                componentID: board.packages[index].componentID,
                refdes: refdes,
                board: &board,
                changedComponentRefdes: &changedComponentRefdes
            )
        case ("positionX", .length(let x)):
            let delta = HorizontalPoint(x: x - board.packages[index].position.x, y: 0)
            moveBoardPackage(ref: ref, by: delta, board: &board)
        case ("positionY", .length(let y)):
            let delta = HorizontalPoint(x: 0, y: y - board.packages[index].position.y)
            moveBoardPackage(ref: ref, by: delta, board: &board)
        case ("angle", .angle(let angle)):
            let newAngle = wrappedAngle(angle)
            let angleDelta = newAngle - wrappedAngle(board.packages[index].angle)
            let origin = board.packages[index].position
            board.packages[index].angle = newAngle
            rotateBoardPackageGeometry(packageID: ref.id, around: origin, by: angleDelta, board: &board)
        case ("omitSilkscreen", .bool(let on)):
            board.packages[index].omitSilkscreen = on
        case ("omitOutline", .bool(let on)):
            board.packages[index].omitOutline = on
        case ("fixed", .bool(let on)):
            board.packages[index].fixed = on
        case ("flipped", .bool(let on)):
            guard on != board.packages[index].mirrored else { break }
            flipBoardPackage(ref: ref, board: &board)
        default:
            break
        }
    }

    private func updateComponentRefdes(
        componentID: String?,
        refdes: String,
        board: inout HorizontalBoard,
        changedComponentRefdes: inout [(componentID: String, refdes: String)]
    ) {
        guard let componentID else {
            return
        }

        let normalizedComponentID = normalizedID(componentID)
        for index in board.packages.indices
            where board.packages[index].componentID.map(normalizedID) == normalizedComponentID {
            let oldRefdes = board.packages[index].componentDetails?.refdes
            guard oldRefdes != refdes else {
                continue
            }

            if var details = board.packages[index].componentDetails {
                details.refdes = refdes
                board.packages[index].componentDetails = details
                board.packages[index].label = details.displayLabel
            }
            updatePackageTextRefdes(
                packageID: board.packages[index].id,
                oldRefdes: oldRefdes,
                newRefdes: refdes,
                board: &board
            )
        }
        changedComponentRefdes.append((normalizedComponentID, refdes))
    }

    private func updatePackageTextRefdes(
        packageID: String,
        oldRefdes: String?,
        newRefdes: String,
        board: inout HorizontalBoard
    ) {
        guard let oldRefdes = nonEmpty(oldRefdes), oldRefdes != newRefdes else {
            return
        }
        let normalizedPackageID = normalizedID(packageID)
        for index in board.packageTexts.indices
            where self.packageID(forGeometryID: board.packageTexts[index].id).map(normalizedID) == normalizedPackageID {
            board.packageTexts[index].text = board.packageTexts[index].text.replacingOccurrences(of: oldRefdes, with: newRefdes)
        }
    }

    private func reportComponentRefdesDifferences(
        from previousPackages: [HorizontalPlacement],
        to currentPackages: [HorizontalPlacement]
    ) {
        let previousByComponentID = componentRefdesByID(in: previousPackages)
        let currentByComponentID = componentRefdesByID(in: currentPackages)
        for componentID in Set(previousByComponentID.keys).union(currentByComponentID.keys) {
            guard let currentRefdes = currentByComponentID[componentID],
                  previousByComponentID[componentID] != currentRefdes else {
                continue
            }
            onComponentRefdesChange(componentID, currentRefdes)
        }
    }

    private func componentRefdesByID(in placements: [HorizontalPlacement]) -> [String: String] {
        placements.reduce(into: [String: String]()) { result, placement in
            guard let componentID = placement.componentID.map(normalizedID),
                  let refdes = placement.componentDetails?.refdes else {
                return
            }
            result[componentID] = refdes
        }
    }

    /// Applies a geometric transform to the retained pad-center map for one
    /// package, keeping `packagePadPositions` consistent with the pad polygons
    /// when a package is shifted/mirrored/rotated. Pad-path keys are
    /// "packageID/padID" (normalized), so a prefix match selects the package.
    private func updatePackagePadPositions(
        packageID normalizedPackageID: String,
        board: inout HorizontalBoard,
        transform: (HorizontalPoint) -> HorizontalPoint
    ) {
        let prefix = normalizedPackageID + "/"
        for (path, position) in board.packagePadPositions where path.hasPrefix(prefix) {
            board.packagePadPositions[path] = transform(position)
        }
    }

    private func shiftBoardPackageGeometry(
        packageID: String,
        by delta: HorizontalPoint,
        board: inout HorizontalBoard
    ) {
        guard delta != .zero else {
            return
        }

        let normalizedPackageID = normalizedID(packageID)
        func belongsToPackage(_ geometryID: String) -> Bool {
            self.packageID(forGeometryID: geometryID).map(normalizedID) == normalizedPackageID
        }

        for index in board.packagePads.indices where belongsToPackage(board.packagePads[index].id) {
            board.packagePads[index] = shifted(board.packagePads[index], by: delta)
        }
        updatePackagePadPositions(packageID: normalizedPackageID, board: &board) { $0 + delta }
        for index in board.packageHoles.indices where belongsToPackage(board.packageHoles[index].id) {
            board.packageHoles[index] = shifted(board.packageHoles[index], by: delta)
        }
        for index in board.packagePolygons.indices where belongsToPackage(board.packagePolygons[index].id) {
            board.packagePolygons[index] = shifted(board.packagePolygons[index], by: delta)
        }
        for index in board.packageLines.indices where belongsToPackage(board.packageLines[index].id) {
            board.packageLines[index] = shifted(board.packageLines[index], by: delta)
        }
        for index in board.packageArcs.indices where belongsToPackage(board.packageArcs[index].id) {
            board.packageArcs[index] = shifted(board.packageArcs[index], by: delta)
        }
        for index in board.packageTexts.indices where belongsToPackage(board.packageTexts[index].id) {
            board.packageTexts[index] = shifted(board.packageTexts[index], by: delta)
        }
    }

    private func mirrorBoardPackageGeometry(
        packageID: String,
        around center: HorizontalPoint,
        board: inout HorizontalBoard
    ) {
        let normalizedPackageID = normalizedID(packageID)
        func belongsToPackage(_ geometryID: String) -> Bool {
            self.packageID(forGeometryID: geometryID).map(normalizedID) == normalizedPackageID
        }

        for index in board.packagePads.indices where belongsToPackage(board.packagePads[index].id) {
            board.packagePads[index] = mirrored(board.packagePads[index], around: center, flipsLayer: true)
        }
        updatePackagePadPositions(packageID: normalizedPackageID, board: &board) { mirrored($0, around: center) }
        for index in board.packageHoles.indices where belongsToPackage(board.packageHoles[index].id) {
            board.packageHoles[index] = mirrored(board.packageHoles[index], around: center)
        }
        for index in board.packagePolygons.indices where belongsToPackage(board.packagePolygons[index].id) {
            board.packagePolygons[index] = mirrored(board.packagePolygons[index], around: center, flipsLayer: true)
        }
        for index in board.packageLines.indices where belongsToPackage(board.packageLines[index].id) {
            board.packageLines[index] = mirrored(board.packageLines[index], around: center, flipsLayer: true)
        }
        for index in board.packageArcs.indices where belongsToPackage(board.packageArcs[index].id) {
            board.packageArcs[index] = mirrored(board.packageArcs[index], around: center, flipsLayer: true)
        }
        for index in board.packageTexts.indices where belongsToPackage(board.packageTexts[index].id) {
            board.packageTexts[index] = mirrored(board.packageTexts[index], around: center, flipsLayer: true)
        }
    }

    private func rotateBoardPackageGeometry(
        packageID: String,
        around origin: HorizontalPoint,
        by angleDelta: Int,
        board: inout HorizontalBoard
    ) {
        guard wrappedAngle(angleDelta) != 0 else {
            return
        }

        let normalizedPackageID = normalizedID(packageID)
        func belongsToPackage(_ geometryID: String) -> Bool {
            self.packageID(forGeometryID: geometryID).map(normalizedID) == normalizedPackageID
        }

        for index in board.packagePads.indices where belongsToPackage(board.packagePads[index].id) {
            board.packagePads[index] = rotated(board.packagePads[index], around: origin, by: angleDelta)
        }
        updatePackagePadPositions(packageID: normalizedPackageID, board: &board) { rotated($0, around: origin, by: angleDelta) }
        for index in board.packageHoles.indices where belongsToPackage(board.packageHoles[index].id) {
            board.packageHoles[index] = rotated(board.packageHoles[index], around: origin, by: angleDelta)
        }
        for index in board.packagePolygons.indices where belongsToPackage(board.packagePolygons[index].id) {
            board.packagePolygons[index] = rotated(board.packagePolygons[index], around: origin, by: angleDelta)
        }
        for index in board.packageLines.indices where belongsToPackage(board.packageLines[index].id) {
            board.packageLines[index] = rotated(board.packageLines[index], around: origin, by: angleDelta)
        }
        for index in board.packageArcs.indices where belongsToPackage(board.packageArcs[index].id) {
            board.packageArcs[index] = rotated(board.packageArcs[index], around: origin, by: angleDelta)
        }
        for index in board.packageTexts.indices where belongsToPackage(board.packageTexts[index].id) {
            board.packageTexts[index] = rotated(board.packageTexts[index], around: origin, by: angleDelta)
        }
    }

    private func updatePolygon(
        _ polygons: inout [HorizontalPolygon],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard propertyID == "layer",
              case .layer(let layer) = value,
              let index = polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        polygons[index].layer = layer
    }

    private func netID(for ref: HorizontalSelectableRef?) -> String? {
        guard let ref else {
            return nil
        }

        switch ref.type {
        case .track:
            return board.tracks.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .boardNetTie:
            return board.netTies.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .boardLine:
            return board.lines.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .boardArc:
            return board.arcs.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .connectionLine:
            return board.connectionLines.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .pad:
            return board.packagePads.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .via:
            return board.vias.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .boardHole:
            return hole(for: ref.id)?.netID
        case .plane:
            return board.planes.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            return boardPolygon(for: ref.id, in: board)?.netID
        case .text:
            return (board.texts + board.packageTexts).first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .blockSymbolPort, .boardDecal, .boardPackage, .boardPanel, .busLabel, .busRipper, .dimension, .drawingArc, .drawingLine, .junction, .keepout, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return nil
        }
    }

    private func componentID(for ref: HorizontalSelectableRef?) -> String? {
        guard let ref else {
            return nil
        }

        switch ref.type {
        case .boardPackage:
            return board.packages.first { normalizedID($0.id) == normalizedID(ref.id) }?.componentID
        case .pad, .boardHole, .text:
            guard let packageID = packageID(forGeometryID: ref.id) else {
                return nil
            }
            return board.packages.first { normalizedID($0.id) == normalizedID(packageID) }?.componentID
        default:
            return nil
        }
    }

    private func shifted(_ segment: HorizontalSegment, by delta: HorizontalPoint) -> HorizontalSegment {
        HorizontalCanvasModeSupport.shifted(segment, by: delta)
    }

    private func shifted(_ arc: HorizontalArc, by delta: HorizontalPoint) -> HorizontalArc {
        HorizontalCanvasModeSupport.shifted(arc, by: delta)
    }

    private func shifted(_ polygon: HorizontalPolygon, by delta: HorizontalPoint) -> HorizontalPolygon {
        HorizontalCanvasModeSupport.shifted(polygon, by: delta)
    }

    private func shifted(_ hole: HorizontalHole, by delta: HorizontalPoint) -> HorizontalHole {
        HorizontalCanvasModeSupport.shifted(hole, by: delta)
    }

    private func shifted(_ text: HorizontalText, by delta: HorizontalPoint) -> HorizontalText {
        HorizontalCanvasModeSupport.shifted(text, by: delta)
    }

    private func shifted(_ keepout: HorizontalKeepout, by delta: HorizontalPoint) -> HorizontalKeepout {
        var keepout = keepout
        keepout.polygon = shifted(keepout.polygon, by: delta)
        return keepout
    }

    private func shifted(_ dimension: HorizontalDimension, by delta: HorizontalPoint) -> HorizontalDimension {
        var dimension = dimension
        dimension.p0 = dimension.p0 + delta
        dimension.p1 = dimension.p1 + delta
        return dimension
    }

    private func shifted(_ decal: HorizontalBoardDecal, by delta: HorizontalPoint) -> HorizontalBoardDecal {
        var decal = decal
        decal.polygons = decal.polygons.map { shifted($0, by: delta) }
        decal.lines = decal.lines.map { shifted($0, by: delta) }
        decal.arcs = decal.arcs.map { shifted($0, by: delta) }
        decal.texts = decal.texts.map { shifted($0, by: delta) }
        return decal
    }

    private func shifted(_ plane: HorizontalPlane, by delta: HorizontalPoint) -> HorizontalPlane {
        var plane = plane
        plane.fragments = plane.fragments.map { fragment in
            HorizontalPlaneFragment(
                paths: fragment.paths.map { path in path.map { $0 + delta } },
                orphan: fragment.orphan
            )
        }
        plane.fallbackPolygon = plane.fallbackPolygon.map { shifted($0, by: delta) }
        return plane
    }

    private func mirrored(_ segment: HorizontalSegment, around center: HorizontalPoint, flipsLayer: Bool) -> HorizontalSegment {
        var segment = segment
        segment.from = mirrored(segment.from, around: center)
        segment.to = mirrored(segment.to, around: center)
        segment.center = segment.center.map { mirrored($0, around: center) }
        segment.reverse.toggle()
        if flipsLayer, let layer = segment.layer {
            segment.layer = mirroredLayer(layer)
        }
        return segment
    }

    private func mirrored(_ arc: HorizontalArc, around center: HorizontalPoint, flipsLayer: Bool) -> HorizontalArc {
        var arc = arc
        arc.from = mirrored(arc.from, around: center)
        arc.to = mirrored(arc.to, around: center)
        arc.center = mirrored(arc.center, around: center)
        arc.reverse.toggle()
        if flipsLayer, let layer = arc.layer {
            arc.layer = mirroredLayer(layer)
        }
        return arc
    }

    private func mirrored(_ polygon: HorizontalPolygon, around center: HorizontalPoint, flipsLayer: Bool) -> HorizontalPolygon {
        var polygon = polygon.transformed({ mirrored($0, around: center) }, flipsArcReverse: true)
        if flipsLayer, let layer = polygon.layer {
            polygon.layer = mirroredLayer(layer)
        }
        return polygon
    }

    private func mirrored(_ hole: HorizontalHole, around center: HorizontalPoint) -> HorizontalHole {
        var hole = hole
        hole.position = mirrored(hole.position, around: center)
        hole.angle = wrappedAngle(32_768 - hole.angle)
        return hole
    }

    private func mirrored(_ text: HorizontalText, around center: HorizontalPoint, flipsLayer: Bool) -> HorizontalText {
        var text = text
        text.position = mirrored(text.position, around: center)
        setTextMirror(!text.mirrored, for: &text)
        if flipsLayer, let layer = text.layer {
            text.layer = mirroredLayer(layer)
        }
        return text
    }

    private func rotated(_ segment: HorizontalSegment, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalSegment {
        HorizontalCanvasModeSupport.rotated(segment, around: origin, by: angleDelta)
    }

    private func rotated(_ arc: HorizontalArc, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalArc {
        HorizontalCanvasModeSupport.rotated(arc, around: origin, by: angleDelta)
    }

    private func rotated(_ polygon: HorizontalPolygon, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalPolygon {
        HorizontalCanvasModeSupport.rotated(polygon, around: origin, by: angleDelta)
    }

    private func rotated(_ hole: HorizontalHole, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalHole {
        HorizontalCanvasModeSupport.rotated(hole, around: origin, by: angleDelta)
    }

    private func rotated(_ text: HorizontalText, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalText {
        HorizontalCanvasModeSupport.rotated(text, around: origin, by: angleDelta)
    }

    private func rotated(_ point: HorizontalPoint, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalPoint {
        HorizontalCanvasModeSupport.rotated(point, around: origin, by: angleDelta)
    }

    private func mirrored(_ point: HorizontalPoint, around center: HorizontalPoint) -> HorizontalPoint {
        HorizontalCanvasModeSupport.mirrored(point, around: center)
    }

    private func mirroredLayer(_ layer: Int) -> Int {
        HorizontalBoardLayers.flippedPackageLayer(layer, nInnerLayers: boardInnerLayerCount)
    }

    private var boardInnerLayerCount: Int {
        max(board.copperLayerCount - 2, 0)
    }

    private var board2DProfileID: String {
        "\(sourceBoard.uuid)-\(sourceBoard.url.path)-\(boardGeometryCounts(for: sourceBoard).hashValue)-\(metalSceneRevision)"
    }

    private var board2DProfileSummary: String {
        let planeFragments = sourceBoard.planes.reduce(0) { $0 + $1.renderFragments.count }
        return "\(sourceBoard.url.lastPathComponent)  packages \(sourceBoard.packages.count), pads \(sourceBoard.packagePads.count), tracks \(sourceBoard.tracks.count), planes \(sourceBoard.planes.count), plane fragments \(planeFragments)"
    }

    private func wrappedAngle(_ angle: Int) -> Int {
        HorizontalCanvasModeSupport.wrappedAngle(angle)
    }

    private var selectableCacheKey: BoardSelectableCacheKey {
        BoardSelectableCacheKey(
            boardID: board.uuid,
            revision: selectableCacheRevision,
            displayOptions: displayOptions,
            counts: boardGeometryCounts
        )
    }

    private var boardGeometryCounts: [Int] {
        boardGeometryCounts(for: board)
    }

    private func boardGeometryCounts(for board: HorizontalBoard) -> [Int] {
        [
            board.polygons.count,
            board.keepouts.count,
            board.planes.count,
            board.decals.count,
            board.dimensions.count,
            board.lines.count,
            board.arcs.count,
            board.tracks.count,
            board.netTies.count,
            board.connectionLines.count,
            board.vias.count,
            board.holes.count,
            board.packageHoles.count,
            board.packages.count,
            board.packagePads.count,
            board.packagePolygons.count,
            board.packageLines.count,
            board.packageArcs.count,
            board.packageTexts.count,
            board.texts.count,
            board.boardPanels.count,
            board.junctions.count
        ]
    }

    private var allSelectableCacheKey: BoardAllSelectableCacheKey {
        BoardAllSelectableCacheKey(
            boardID: board.uuid,
            revision: selectableCacheRevision,
            counts: boardGeometryCounts
        )
    }

    private func invalidateSelectableCache(preservesMetalScene: Bool = false) {
        selectableCacheRevision &+= 1
        if !preservesMetalScene {
            metalSceneRevision &+= 1
        }
        selectableCache.invalidate(preservesMetalScene: preservesMetalScene)
    }

    private func boardSelectableScene() -> HorizontalCanvasSelectableScene {
        selectableCache.selectableScene(key: selectableCacheKey) {
            let all = selectableCache.allSelectables(key: allSelectableCacheKey) {
                BoardLoadTimer.measure("BoardCanvasView.buildAllBoardSelectables") {
                    buildAllBoardSelectables(in: board)
                }
            }
            return BoardLoadTimer.measure("BoardCanvasView.filterVisibleSelectables") {
                filterVisibleSelectables(all, in: board)
            }
        }
    }

    private func boardSelectables() -> [HorizontalSelectable] {
        boardSelectableScene().selectables
    }

    private func boardSelectablesByRef() -> [HorizontalSelectableRef: [HorizontalSelectable]] {
        boardSelectableScene().selectablesByRef
    }

    private func filterVisibleSelectables(_ selectables: [HorizontalSelectable]) -> [HorizontalSelectable] {
        filterVisibleSelectables(selectables, in: board)
    }

    private func filterVisibleSelectables(_ selectables: [HorizontalSelectable], in board: HorizontalBoard) -> [HorizontalSelectable] {
        let keepoutAllCopperByID: [String: Bool] = Dictionary(
            uniqueKeysWithValues: board.keepouts.map { (normalizedID($0.id), $0.allCopperLayers) }
        )
        let planePolygonIDs = Set(board.planes.map { normalizedID($0.polygonID) })
        let visibleCopperLayers = Set(
            HorizontalBoardLayers.all.filter {
                HorizontalBoardLayers.isCopper($0) && displayOptions.isLayerVisible($0)
            }
        )
        let visibleDecalIDs = Set(board.decals.compactMap { decal -> String? in
            guard boardDecalHasVisibleLayer(decal) else {
                return nil
            }
            return normalizedID(decal.id)
        })
        let visibleViaIDs = Set(board.vias.compactMap { via -> String? in
            guard !visibleViaLayers(for: via).isEmpty else {
                return nil
            }
            return normalizedID(via.id)
        })
        let visiblePackageIDs = visibleBoardPackageIDs(in: board)
        return selectables.filter { selectable in
            isSelectableVisible(
                selectable.ref,
                keepoutAllCopperByID: keepoutAllCopperByID,
                planePolygonIDs: planePolygonIDs,
                visibleCopperLayers: visibleCopperLayers,
                visibleDecalIDs: visibleDecalIDs,
                visibleViaIDs: visibleViaIDs,
                visiblePackageIDs: visiblePackageIDs
            )
        }
    }

    private func boardSelectablesByRef(in board: HorizontalBoard) -> [HorizontalSelectableRef: [HorizontalSelectable]] {
        Dictionary(grouping: filterVisibleSelectables(buildAllBoardSelectables(in: board), in: board), by: \.ref)
    }

    private func isSelectableVisible(
        _ ref: HorizontalSelectableRef,
        keepoutAllCopperByID: [String: Bool],
        planePolygonIDs: Set<String>,
        visibleCopperLayers: Set<Int>,
        visibleDecalIDs: Set<String>,
        visibleViaIDs: Set<String>,
        visiblePackageIDs: Set<String>
    ) -> Bool {
        switch ref.type {
        case .boardPanel:
            return displayOptions.outline
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            if planePolygonIDs.contains(normalizedID(ref.id)) {
                return displayOptions.isLayerVisible(ref.layer)
            }
            if let layer = ref.layer, isBoardBodyLayer(layer) {
                return displayOptions.boardBody || displayOptions.outline
            }
            return displayOptions.isLayerVisible(ref.layer)
        case .keepout:
            guard displayOptions.keepouts else {
                return false
            }
            if keepoutAllCopperByID[normalizedID(ref.id)] == true {
                return !visibleCopperLayers.isEmpty
            }
            return displayOptions.isLayerVisible(ref.layer)
        case .plane:
            return false
        case .boardDecal:
            return displayOptions.decals && visibleDecalIDs.contains(normalizedID(ref.id))
        case .dimension:
            return displayOptions.dimensions
        case .boardLine, .boardArc, .track, .boardNetTie:
            return displayOptions.isLayerVisible(ref.layer)
        case .connectionLine:
            return displayOptions.connectionLines
        case .pad:
            return displayOptions.pads && displayOptions.isLayerVisible(ref.layer)
        case .via:
            return displayOptions.vias && visibleViaIDs.contains(normalizedID(ref.id))
        case .junction:
            return true
        case .boardHole:
            return displayOptions.holes
        case .boardPackage:
            return visiblePackageIDs.contains(normalizedID(ref.id))
        case .text:
            return displayOptions.text && displayOptions.isLayerVisible(ref.layer)
        default:
            return true
        }
    }

    private func visibleBoardPackageIDs(in board: HorizontalBoard) -> Set<String> {
        var packageIDs = Set<String>()

        func insertPackage(for geometryID: String) {
            if let packageID = packageID(forGeometryID: geometryID) {
                packageIDs.insert(normalizedID(packageID))
            }
        }

        if displayOptions.packages {
            for polygon in board.packagePolygons where displayOptions.isLayerVisible(polygon.layer) {
                insertPackage(for: polygon.id)
            }
            for line in board.packageLines where displayOptions.isLayerVisible(line.layer) {
                insertPackage(for: line.id)
            }
            for arc in board.packageArcs where displayOptions.isLayerVisible(arc.layer) {
                insertPackage(for: arc.id)
            }
        }

        if displayOptions.pads {
            for pad in board.packagePads where displayOptions.isLayerVisible(pad.layer) {
                insertPackage(for: pad.id)
            }
        }

        if displayOptions.holes {
            for hole in board.packageHoles {
                insertPackage(for: hole.id)
            }
        }

        if displayOptions.text || displayOptions.packages {
            for text in board.packageTexts where displayOptions.isLayerVisible(text.layer) {
                insertPackage(for: text.id)
            }
        }

        // Packages with no resolved geometry render as a fallback marker on the
        // package side layer, so retain the old side-layer visibility rule for
        // those placeholders only.
        let packagesWithGeometry = Set(boardPackageGeometryPoints(in: board).keys.map(normalizedID))
        if displayOptions.packages {
            for package in board.packages where !packagesWithGeometry.contains(normalizedID(package.id)) {
                let sideLayer = package.mirrored ? HorizontalBoardLayers.bottomPackage : HorizontalBoardLayers.topPackage
                if displayOptions.isLayerVisible(sideLayer) {
                    packageIDs.insert(normalizedID(package.id))
                }
            }
        }

        return packageIDs
    }

    private func boardDecalHasVisibleLayer(_ decal: HorizontalBoardDecal) -> Bool {
        decal.polygons.contains { displayOptions.isLayerVisible($0.layer) }
            || decal.lines.contains { displayOptions.isLayerVisible($0.layer) }
            || decal.arcs.contains { displayOptions.isLayerVisible($0.layer) }
            || decal.texts.contains { displayOptions.isLayerVisible($0.layer) }
    }

    private func metalTrianglePoints(
        for fragment: HorizontalPlaneFragment,
        fragmentKey: BoardPlaneFragmentKey
    ) -> [BoardMetalTrianglePoints] {
        // Tessellation runs in `BoardSelectableCache.startBackgroundTessellation`
        // off the main thread. If the fragment hasn't been tessellated yet, we
        // return [] and the bucket build proceeds without this fragment's fill.
        // When the background pass completes, tessellationVersion bumps, the
        // bucket cache invalidates, and body re-runs to paint the fill.
        if selectableCache.hasPlaneFragmentTrianglePoints(fragmentKey) {
            return selectableCache.planeFragmentTrianglePoints(fragmentKey) { [] }
        }
        return []
    }


    private func metalTriangles(
        for fragment: HorizontalPlaneFragment,
        fragmentKey: BoardPlaneFragmentKey,
        color: HorizontalMetalRGBA
    ) -> [HorizontalMetalTrianglePrimitive] {
        metalTriangles(for: fragment, fragmentKey: fragmentKey, color: color, compositeGroup: 0, compositeOpacity: 1)
    }

    private func metalTriangles(
        for fragment: HorizontalPlaneFragment,
        fragmentKey: BoardPlaneFragmentKey,
        color: HorizontalMetalRGBA,
        compositeGroup: Int,
        compositeOpacity: Float
    ) -> [HorizontalMetalTrianglePrimitive] {
        let key = BoardMetalPlaneTriangleCacheKey(
            fragmentKey: fragmentKey,
            color: color,
            compositeGroup: compositeGroup,
            compositeOpacity: compositeOpacity
        )
        return selectableCache.planeFragmentTriangles(key: key) {
            metalTrianglePoints(for: fragment, fragmentKey: fragmentKey).map {
                HorizontalMetalTrianglePrimitive(
                    a: $0.a,
                    b: $0.b,
                    c: $0.c,
                    color: color,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                )
            }
        }
    }

    private func metalOutlineLines(
        for fragment: HorizontalPlaneFragment,
        fragmentKey: BoardPlaneFragmentKey,
        color: HorizontalMetalRGBA,
        width: Double = 0,
        minimumWidth: Float,
        dash: (Float, Float)? = nil,
        compositeGroup: Int,
        compositeOpacity: Float
    ) -> [HorizontalMetalLinePrimitive] {
        let key = BoardMetalPlaneOutlineCacheKey(
            fragmentKey: fragmentKey,
            color: color,
            width: width,
            minimumWidth: minimumWidth,
            dashLength: dash?.0 ?? 0,
            dashGap: dash?.1 ?? 0,
            compositeGroup: compositeGroup,
            compositeOpacity: compositeOpacity
        )
        return selectableCache.planeFragmentOutlines(key: key) {
            var primitives = [HorizontalMetalLinePrimitive]()
            for path in fragment.paths {
                guard let first = path.first else {
                    continue
                }
                let closedPath = path + [first]
                for pair in zip(closedPath, closedPath.dropFirst()) {
                    primitives.append(
                        HorizontalMetalLinePrimitive(
                            from: pair.0,
                            to: pair.1,
                            color: color,
                            width: width,
                            minimumWidth: minimumWidth,
                            dashLength: dash?.0 ?? 0,
                            dashGap: dash?.1 ?? 0,
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity
                        )
                    )
                }
            }
            return primitives
        }
    }

    private func metalElementBucketsCacheKey(renderLayers: [Int]) -> BoardMetalElementBucketsCacheKey {
        // None of these colors include layerOpacity. The slider is applied at
        // composite time via the renderer's layerOpacity uniform.
        let keyBoard = boardForMetalBuckets
        return BoardMetalElementBucketsCacheKey(
            boardID: keyBoard.uuid,
            revision: metalSceneRevision,
            tessellationVersion: selectableCache.tessellationVersion,
            counts: boardGeometryCounts(for: keyBoard),
            movePreview: canPatchBoardMoveInMetal ? nil : boardMovePreviewSignature,
            pastePreview: pastePreviewSignature,
            routePreviewRemoved: pushShoveRemovedSegmentIDs.sorted(),
            renderLayers: renderLayers,
            layerColors: HorizontalBoardLayers.all.map { HorizontalMetalRGBA(layerColor(for: $0)) },
            layerFillModes: HorizontalBoardLayers.all.map { displayOptions.isLayerFilled($0) },
            bodyOutlineHighColor: HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.outline).opacity(0.74)),
            bodyOutlineLowColor: HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.outline).opacity(0.18)),
            bodyFillColor: HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.outline).opacity(0.23)),
            panelColor: HorizontalMetalRGBA(theme.textOverlay.opacity(0.36)),
            keepoutStrokeColor: HorizontalMetalRGBA(theme.error.opacity(0.76)),
            keepoutFillColor: HorizontalMetalRGBA(theme.error.opacity(0.12)),
            originXColor: HorizontalMetalRGBA(theme.error.opacity(0.42)),
            originYColor: HorizontalMetalRGBA(theme.origin.opacity(0.42)),
            originXLabelColor: HorizontalMetalRGBA(theme.error.opacity(0.58)),
            originYLabelColor: HorizontalMetalRGBA(theme.origin.opacity(0.58)),
            panelLabelColor: HorizontalMetalRGBA(theme.textOverlay.opacity(0.48)),
            // Overlay-label color is OPAQUE; its 0.86 comes from the dedicated
            // composite group's opacity (textOverlayMetalCompositeGroup), applied
            // once at composite time instead of baked per-vertex.
            textOverlayColor: HorizontalMetalRGBA(theme.textOverlay),
            dimensionColor: HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.dimensions).opacity(0.72)),
            connectionLineColor: HorizontalMetalRGBA(theme.connectionLine.opacity(0.86)),
            connectionLineDashColor: HorizontalMetalRGBA(theme.connectionLine.opacity(0.72)),
            airwireColor: HorizontalMetalRGBA(theme.airwire.opacity(0.72)),
            holeFillColor: HorizontalMetalRGBA(theme.background.opacity(0.95)),
            platedHoleStrokeColor: HorizontalMetalRGBA(theme.hole.opacity(0.7)),
            unplatedHoleStrokeColor: HorizontalMetalRGBA(theme.hole.opacity(0.45)),
            junctionColor: HorizontalMetalRGBA(theme.junction.opacity(0.82)),
            topFallbackColor: HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.topCopper).opacity(0.82)),
            bottomFallbackColor: HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.bottomCopper).opacity(0.82))
        )
    }

    /// World-space glyph height below which a generated label is unreadable at
    /// this transform, quantized DOWN to `labelLODStepsPerOctave` steps per
    /// octave. Quantizing is what keeps live zoom cheap: the concat cache is
    /// keyed on this value, so it only misses when a step is crossed. Returns 0
    /// (cull nothing) if the transform has no usable scale.
    static func minimumLegibleLabelSize(for transform: HorizontalCanvasTransform) -> Double {
        let worldUnitsPerPoint = transform.worldUnitsPerPoint
        guard worldUnitsPerPoint.isFinite, worldUnitsPerPoint > 0 else {
            return 0
        }

        let exact = minimumLegibleLabelPointSize * worldUnitsPerPoint
        guard exact.isFinite, exact > 0 else {
            return 0
        }

        let steps = (log2(exact) * labelLODStepsPerOctave).rounded(.down)
        let quantized = pow(2, steps / labelLODStepsPerOctave)
        return quantized.isFinite ? quantized : 0
    }

    /// True when a generated label's glyphs are still big enough to read at the
    /// current zoom. The main build applies this in bulk through
    /// `BoardMetalElementBatch.filtered(minimumLabelSize:)`; the much smaller
    /// highlight/selection/preview batches and the CoreGraphics fallback (none
    /// of which carry per-line label sizes) test it directly instead, so every
    /// path hides the same labels at the same zoom.
    private func isGeneratedLabelLegible(_ text: HorizontalText) -> Bool {
        minimumLabelSize <= 0 || text.size >= minimumLabelSize
    }

    private func metalVisibilitySignature() -> BoardMetalVisibilitySignature {
        BoardMetalVisibilitySignature(
            outline: displayOptions.outline,
            panelLabels: displayOptions.panelLabels,
            origin: displayOptions.origin,
            boardBody: displayOptions.boardBody,
            keepouts: displayOptions.keepouts,
            hasVisibleCopper: !visibleCopperLayers().isEmpty,
            packages: displayOptions.packages,
            decals: displayOptions.decals,
            pads: displayOptions.pads,
            padLabels: Self.emitsGeneratedBoardLabelsInMetal && displayOptions.padLabels,
            vias: displayOptions.vias,
            viaLabels: Self.emitsGeneratedBoardLabelsInMetal && displayOptions.viaLabels,
            holes: displayOptions.holes,
            text: displayOptions.text,
            trackLabels: Self.emitsGeneratedBoardLabelsInMetal && displayOptions.trackLabels,
            dimensions: displayOptions.dimensions,
            connectionLines: displayOptions.connectionLines,
            connectionLabels: displayOptions.connectionLabels,
            minimumLabelSize: minimumLabelSize
        )
    }

    private func recordBoardMetalWeightSummary(
        _ entries: [BoardMetalNamedPrimitiveWeight],
        label: String
    ) {
        let recordsLoadProfile = BoardLoadTimer.isCanvas2DProfilingEnabled
        let recordsPostCommitProfile = HorizontalMoveCommitDiagnostics.hasPendingPostCommitBody
        guard recordsLoadProfile || recordsPostCommitProfile else {
            return
        }

        func record(_ note: String) {
            if recordsLoadProfile {
                BoardLoadTimer.recordBoard2DNote(note, id: board2DProfileID)
            }
            if recordsPostCommitProfile {
                HorizontalMoveCommitDiagnostics.recordPostCommitBodyNote(note)
            }
        }

        let nonEmptyEntries = entries.filter { $0.weight.primitiveCount > 0 }
        guard !nonEmptyEntries.isEmpty else {
            record("Metal \(label) weight: empty")
            return
        }

        var total = BoardMetalPrimitiveWeight()
        for entry in nonEmptyEntries {
            total.add(entry.weight)
        }

        record("Metal \(label) total: \(boardMetalWeightDescription(total))")

        let topEntries = nonEmptyEntries
            .sorted {
                if $0.weight.drawVertexCount == $1.weight.drawVertexCount {
                    return $0.name < $1.name
                }
                return $0.weight.drawVertexCount > $1.weight.drawVertexCount
            }
            .prefix(8)

        for (index, entry) in topEntries.enumerated() {
            let percent = total.drawVertexCount > 0
                ? Double(entry.weight.drawVertexCount) / Double(total.drawVertexCount) * 100
                : 0
            record("Metal \(label) #\(index + 1): \(entry.name) \(boardMetalWeightDescription(entry.weight)) (\(String(format: "%.1f", percent))% vertices)")
        }
    }

    private func boardMetalWeightDescription(_ weight: BoardMetalPrimitiveWeight) -> String {
        "est vertices \(formattedCount(weight.drawVertexCount)); primitives \(formattedCount(weight.primitiveCount)) (lines \(formattedCount(weight.lines)), triangles \(formattedCount(weight.triangles)), handles \(formattedCount(weight.handles)), rects \(formattedCount(weight.anchoredRects)))"
    }

    private func formattedCount(_ value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let digits = Array(String(abs(value)).reversed())
        var groups = [String]()
        var index = 0
        while index < digits.count {
            let group = digits[index..<min(index + 3, digits.count)].reversed()
            groups.append(String(group))
            index += 3
        }
        return sign + groups.reversed().joined(separator: ",")
    }

    private func concatenateMetalBuckets(
        _ buckets: BoardMetalElementBuckets,
        signature: BoardMetalVisibilitySignature,
        bucketsKey: BoardMetalElementBucketsCacheKey,
        includesResidentMoveMetadata: Bool
    ) -> BoardMetalLineBatch {
        func profile<T>(_ label: String, _ body: () -> T) -> T {
            BoardLoadTimer.measure("concat: \(label)", body)
        }

        let activeBatches = profile("choose active batches") {
            var activeBatches = [(name: String, batch: BoardMetalElementBatch)]()
            activeBatches.reserveCapacity(32)

            func add(_ name: String, _ batch: BoardMetalElementBatch) {
                activeBatches.append((name, batch))
            }

            // Always-on per-layer geometry (board polygons, lines, arcs, tracks, netTies);
            // per-layer visibility is enforced by composite-group masking at draw time.
            add("layer polygons/lines/tracks", buckets.alwaysOnLayered)

            if signature.outline {
                add("panels", buckets.panels)
                add("body outline high", buckets.bodyOutlineHigh)
            } else if signature.boardBody {
                add("body outline low", buckets.bodyOutlineLow)
            }
            if signature.outline && signature.panelLabels {
                add("panel labels", buckets.panelLabels)
            }
            if signature.boardBody {
                add("body fill", buckets.bodyFill)
            }
            if signature.origin {
                add("origin", buckets.origin)
            }
            if signature.keepouts && signature.hasVisibleCopper {
                add("all-copper keepouts", buckets.keepoutsAllCopper)
            }
            if signature.keepouts {
                add("per-layer keepouts", buckets.keepoutsPerLayer)
            }
            // Planes are gated only by their copper layer, which the renderer
            // masks per composite group.
            add("planes", buckets.planes)
            if signature.packages {
                add("package geometry", buckets.packagesGeometry)
                add("package fallback", buckets.packagesFallback)
            }
            // packagesText: shown when EITHER packages or text is on (matches original
            // logic where packageTexts emit via the packages block, or via the text block
            // when packages is off).
            if signature.packages || signature.text {
                add("package text", buckets.packagesText)
            }
            if signature.decals {
                add("decals", buckets.decals)
            }
            if signature.pads {
                add("pads", buckets.pads)
            }
            if signature.vias {
                add("vias", buckets.vias)
            }
            if signature.holes {
                add("board holes", buckets.holesNone)
                if signature.pads {
                    add("package holes", buckets.holesPad)
                }
                if signature.vias {
                    add("via holes", buckets.holesVia)
                }
            }
            // Pad/via name labels composite AFTER holes so drill holes don't
            // punch through the text — matching TEXT_OVERLAY layer,
            // which renders on top of the copper and the holes.
            // The generated labels (and only these) are additionally culled by
            // zoom: once their glyphs shrink past legibility they are dropped
            // rather than drawn as unreadable clutter.
            if signature.pads && signature.padLabels {
                add("pad labels", buckets.padLabels.filtered(minimumLabelSize: signature.minimumLabelSize))
            }
            if signature.vias && signature.viaLabels {
                add("via labels", buckets.viaLabels.filtered(minimumLabelSize: signature.minimumLabelSize))
            }
            if signature.text {
                add("board text", buckets.text)
            }
            if signature.trackLabels {
                add("track labels", buckets.trackLabels.filtered(minimumLabelSize: signature.minimumLabelSize))
            }
            if signature.dimensions {
                add("dimensions", buckets.dimensions)
            }
            if signature.connectionLines {
                add("connection lines", buckets.connectionLines)
            }
            if signature.connectionLines && signature.connectionLabels {
                add("connection labels", buckets.connectionLabels)
            }
            return activeBatches
        }

        recordBoardMetalWeightSummary(
            activeBatches.map { BoardMetalNamedPrimitiveWeight(name: $0.name, weight: $0.batch.primitiveWeight) },
            label: "visible metal buckets"
        )

        let capacities = profile("count primitive capacities") {
            var lineCapacity = 0
            var triangleCapacity = 0
            var anchoredRectCapacity = 0
            for (_, batch) in activeBatches {
                lineCapacity += batch.lines.count
                triangleCapacity += batch.triangles.count
                anchoredRectCapacity += batch.anchoredRects.count
            }
            return (lineCapacity, triangleCapacity, anchoredRectCapacity)
        }

        var lines = [HorizontalMetalLinePrimitive]()
        var triangles = [HorizontalMetalTrianglePrimitive]()
        var anchoredRects = [HorizontalMetalAnchoredRectPrimitive]()
        var metadata = BoardMetalSceneMetadata()
        var lineCountsByGroup = [Int: Int]()
        var triangleCountsByGroup = [Int: Int]()
        var anchoredRectCountsByGroup = [Int: Int]()
        lines.reserveCapacity(capacities.0)
        triangles.reserveCapacity(capacities.1)
        anchoredRects.reserveCapacity(capacities.2)

        if !includesResidentMoveMetadata {
            profile("copy lines") {
                for (_, batch) in activeBatches {
                    lines.append(contentsOf: batch.lines)
                }
            }
            profile("copy triangles") {
                for (_, batch) in activeBatches {
                    triangles.append(contentsOf: batch.triangles)
                }
            }
            profile("copy anchored rects") {
                for (_, batch) in activeBatches {
                    anchoredRects.append(contentsOf: batch.anchoredRects)
                }
            }

            let composedKey = ((bucketsKey.hashValue &* 31) &+ signature.hashValue) &* 31
            return BoardMetalLineBatch(
                triangleKey: composedKey,
                triangles: triangles,
                lineKey: composedKey,
                lines: lines,
                handleKey: 0,
                handles: [],
                anchoredRectKey: composedKey,
                anchoredRects: anchoredRects,
                metadata: metadata
            )
        }

        profile("copy lines and metadata") {
            for (_, batch) in activeBatches {
                lines.append(contentsOf: batch.lines)
                var runOwner: HorizontalSelectableRef?
                var runGroup = 0
                var runStart = 0
                var runCount = 0
                var runPrimitives = [HorizontalMetalLinePrimitive]()

                func flushRun() {
                    guard let owner = runOwner,
                          runCount > 0 else {
                        runOwner = nil
                        runCount = 0
                        runPrimitives.removeAll(keepingCapacity: true)
                        return
                    }

                    metadata.lineSpansByRef[owner, default: []].append(
                        BoardMetalPrimitiveSpan(compositeGroup: runGroup, start: runStart, count: runCount)
                    )
                    if boardMetalShouldRetainLinePrimitives(for: owner), !runPrimitives.isEmpty {
                        metadata.linePrimitivesByRef[owner, default: []].append(contentsOf: runPrimitives)
                    }
                    runOwner = nil
                    runCount = 0
                    runPrimitives.removeAll(keepingCapacity: true)
                }

                for index in batch.lines.indices {
                    let primitive = batch.lines[index]
                    let group = primitive.compositeGroup
                    let start = lineCountsByGroup[group, default: 0]
                    lineCountsByGroup[group] = start + 1
                    guard index < batch.lineOwners.count,
                          let owner = batch.lineOwners[index] else {
                        flushRun()
                        continue
                    }

                    if runOwner == owner,
                       runGroup == group,
                       start == runStart + runCount {
                        runCount += 1
                        if boardMetalShouldRetainLinePrimitives(for: owner) {
                            runPrimitives.append(primitive)
                        }
                    } else {
                        flushRun()
                        runOwner = owner
                        runGroup = group
                        runStart = start
                        runCount = 1
                        if boardMetalShouldRetainLinePrimitives(for: owner) {
                            runPrimitives.append(primitive)
                        }
                    }
                }
                flushRun()
            }
        }

        profile("copy triangles and metadata") {
            for (_, batch) in activeBatches {
                triangles.append(contentsOf: batch.triangles)
                var runOwner: HorizontalSelectableRef?
                var runGroup = 0
                var runStart = 0
                var runCount = 0

                func flushRun() {
                    guard let owner = runOwner,
                          runCount > 0 else {
                        runOwner = nil
                        runCount = 0
                        return
                    }

                    metadata.triangleSpansByRef[owner, default: []].append(
                        BoardMetalPrimitiveSpan(compositeGroup: runGroup, start: runStart, count: runCount)
                    )
                    runOwner = nil
                    runCount = 0
                }

                for index in batch.triangles.indices {
                    let primitive = batch.triangles[index]
                    let group = primitive.compositeGroup
                    let start = triangleCountsByGroup[group, default: 0]
                    triangleCountsByGroup[group] = start + 1
                    guard index < batch.triangleOwners.count,
                          let owner = batch.triangleOwners[index] else {
                        flushRun()
                        continue
                    }

                    if runOwner == owner,
                       runGroup == group,
                       start == runStart + runCount {
                        runCount += 1
                    } else {
                        flushRun()
                        runOwner = owner
                        runGroup = group
                        runStart = start
                        runCount = 1
                    }
                }
                flushRun()
            }
        }

        profile("copy anchored rects and metadata") {
            for (_, batch) in activeBatches {
                anchoredRects.append(contentsOf: batch.anchoredRects)
                var runOwner: HorizontalSelectableRef?
                var runGroup = 0
                var runStart = 0
                var runCount = 0

                func flushRun() {
                    guard let owner = runOwner,
                          runCount > 0 else {
                        runOwner = nil
                        runCount = 0
                        return
                    }

                    metadata.anchoredRectSpansByRef[owner, default: []].append(
                        BoardMetalPrimitiveSpan(compositeGroup: runGroup, start: runStart, count: runCount)
                    )
                    runOwner = nil
                    runCount = 0
                }

                for index in batch.anchoredRects.indices {
                    let primitive = batch.anchoredRects[index]
                    let group = primitive.compositeGroup
                    let start = anchoredRectCountsByGroup[group, default: 0]
                    anchoredRectCountsByGroup[group] = start + 1
                    guard index < batch.anchoredRectOwners.count,
                          let owner = batch.anchoredRectOwners[index] else {
                        flushRun()
                        continue
                    }

                    if runOwner == owner,
                       runGroup == group,
                       start == runStart + runCount {
                        runCount += 1
                    } else {
                        flushRun()
                        runOwner = owner
                        runGroup = group
                        runStart = start
                        runCount = 1
                    }
                }
                flushRun()
            }
        }

        let composedKey = ((bucketsKey.hashValue &* 31) &+ signature.hashValue) &* 31 &+ 17
        return BoardMetalLineBatch(
            triangleKey: composedKey,
            triangles: triangles,
            lineKey: composedKey,
            lines: lines,
            handleKey: 0,
            handles: [],
            anchoredRectKey: composedKey,
            anchoredRects: anchoredRects,
            metadata: metadata
        )
    }

    private func measuredBoardMetalLineBatch(renderLayers: [Int]) -> BoardMetalLineBatch {
        guard moveState != nil else {
            return boardMetalLineBatch(renderLayers: renderLayers)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let batch = boardMetalLineBatch(renderLayers: renderLayers)
        HorizontalMoveRateDiagnostics.recordTiming(
            .boardLineBatch,
            nanoseconds: elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
            active: moveState != nil
        )
        return batch
    }

    private func boardMetalLineBatch(renderLayers: [Int]) -> BoardMetalLineBatch {
        guard drawsBoardLinesInMetal else {
            return .empty
        }

        // Kick off background plane-fragment tessellation. The first body call
        // returns immediately without plane fills (earcut on the heavy planes
        // runs on a detached Task with parallel workers). When that pass finishes
        // it bumps `selectableCache.tessellationVersion`, which invalidates this
        // bucket cache (the version is in the key) and triggers a re-render that
        // includes the freshly-tessellated fills.
        selectableCache.startBackgroundTessellation(planes: boardForMetalBuckets.planes)

        let bucketsKey = metalElementBucketsCacheKey(renderLayers: renderLayers)
        let buckets = selectableCache.elementBuckets(key: bucketsKey) {
            let result = BoardLoadTimer.measure("BoardCanvasView.buildBoardMetalElementBuckets") {
                buildBoardMetalElementBuckets(renderLayers: renderLayers)
            }
            BoardLoadTimer.flushPlaneTessellationSummary()
            return result
        }

        let signature = metalVisibilitySignature()
        let includesResidentMoveMetadata = canPatchBoardMoveInMetal
        let concatKey = BoardMetalLineBatchConcatKey(
            bucketsKey: bucketsKey,
            visibilitySignature: signature,
            includesResidentMoveMetadata: includesResidentMoveMetadata
        )
        return selectableCache.concatenatedLineBatch(key: concatKey) {
            BoardLoadTimer.measure("body: concatenateMetalBuckets") {
                concatenateMetalBuckets(
                    buckets,
                    signature: signature,
                    bucketsKey: bucketsKey,
                    includesResidentMoveMetadata: includesResidentMoveMetadata
                )
            }
        }
    }

    // The build emits every primitive into one of the BoardMetalElementBuckets; it
    // does NOT consult element-type displayOptions flags. Layer-override visibility
    // is handled by composite-group masking in the renderer; element-type and
    // category-level visibility are applied at concat time by concatenateMetalBuckets.
    private func buildBoardMetalElementBuckets(renderLayers: [Int]) -> BoardMetalElementBuckets {
        let board = boardForMetalBuckets
        let buckets = BoardMetalElementBuckets()

        func profile<T>(_ label: String, _ body: () -> T) -> T {
            BoardLoadTimer.measure("bucket: \(label)", body)
        }

        // layerOpacity is intentionally NOT consulted here. It is applied at
        // composite time as a uniform so the slider doesn't invalidate caches.
        // Every per-primitive `compositeOpacity` is set to 1.0 for the same
        // reason. The renderer multiplies by the live layerOpacity uniform
        // when compositing per-layer textures into the framebuffer.
        let fallbackLayerColor = layerColor(for: nil)
        let colorsByLayer = Dictionary(uniqueKeysWithValues: renderLayers.map { layer in
            (layer, layerColor(for: layer))
        })
        let derivedGeometryKey = BoardAllSelectableCacheKey(
            boardID: board.uuid,
            revision: metalSceneRevision,
            counts: boardGeometryCounts(for: board)
        )
        let padOutlineFragmentsByLayer = profile("pad outline fragments") {
            selectableCache.padOutlineFragments(key: derivedGeometryKey) {
                Dictionary(
                    grouping: horizonPadOutlineFragments(board.packagePads),
                    by: { $0.layer }
                )
            }
        }
        let viasByLayer = profile("vias by layer") {
            var result = [Int: [HorizontalMarker]]()
            result.reserveCapacity(renderLayers.count)
            for via in board.vias {
                for layer in renderedViaLayers(for: via) {
                    result[layer, default: []].append(via)
                }
            }
            return result
        }

        // OPAQUE: overlay labels are dimmed to 0.86 by their composite group
        // (textOverlayMetalCompositeGroup), not by a baked per-vertex alpha, so
        // overlapping glyph strokes no longer compound into darker seams.
        let textOverlayColor = HorizontalMetalRGBA(theme.textOverlay)
        // Pad-center keys for the track-label "connects to a pad" heuristic,
        // precomputed once so the per-track check is O(1).
        let trackLabelPadCenterKeys = Set(board.packagePadPositions.values.map { pointKey($0) })
        let dimensionColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.dimensions).opacity(0.72))
        let connectionLineColor = HorizontalMetalRGBA(theme.connectionLine.opacity(0.86))
        let connectionLineDashColor = HorizontalMetalRGBA(theme.connectionLine.opacity(0.72))
        let airwireDashColor = HorizontalMetalRGBA(theme.airwire.opacity(0.72))
        let platedHoleStrokeColor = HorizontalMetalRGBA(theme.hole.opacity(0.7))
        let unplatedHoleStrokeColor = HorizontalMetalRGBA(theme.hole.opacity(0.45))
        let holeFillColor = HorizontalMetalRGBA(theme.background.opacity(0.95))
        let topFallbackColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.topCopper).opacity(0.82))
        let bottomFallbackColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.bottomCopper).opacity(0.82))
        let panelColor = HorizontalMetalRGBA(theme.textOverlay.opacity(0.36))
        let panelLabelColor = HorizontalMetalRGBA(theme.textOverlay.opacity(0.48))
        let originXColor = HorizontalMetalRGBA(theme.error.opacity(0.42))
        let originYColor = HorizontalMetalRGBA(theme.origin.opacity(0.42))
        let originXLabelColor = HorizontalMetalRGBA(theme.error.opacity(0.58))
        let originYLabelColor = HorizontalMetalRGBA(theme.origin.opacity(0.58))
        let bodyHighColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.outline).opacity(0.74))
        let bodyLowColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.outline).opacity(0.18))
        let bodyFillColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.outline).opacity(0.23))
        let keepoutStrokeColor = HorizontalMetalRGBA(theme.error.opacity(0.76))
        let keepoutFillColor = HorizontalMetalRGBA(theme.error.opacity(0.12))

        func layerMetalColor(_ layer: Int?, opacity: Double = 1) -> HorizontalMetalRGBA {
            HorizontalMetalRGBA((layer.flatMap { colorsByLayer[$0] } ?? fallbackLayerColor).opacity(opacity))
        }

        // Net-less copper (a track that reaches no pad) renders orange, matching
        // ColorP::BUS — flags unconnected /
        // shorted copper. Connectivity is recomputed after every edit.
        let noNetTrackColor = HorizontalMetalRGBA(Color(red: 1.0, green: 0.4, blue: 0.0))

        // Render-time gating for the package omit_silkscreen / omit_outline flags:
        // package-id → (silk, outline). Empty for packages with no omit flag.
        let packageOmitByID: [String: (silk: Bool, outline: Bool)] = board.packages.reduce(into: [:]) { result, package in
            if package.omitSilkscreen || package.omitOutline {
                result[normalizedID(package.id)] = (package.omitSilkscreen, package.omitOutline)
            }
        }
        func isPackageGeometryHidden(_ geometryID: String, layer: Int) -> Bool {
            guard !packageOmitByID.isEmpty,
                  let pkg = packageID(forGeometryID: geometryID).map(normalizedID),
                  let flags = packageOmitByID[pkg] else {
                return false
            }
            return (flags.silk && HorizontalBoardLayers.isSilkscreen(layer))
                || (flags.outline && HorizontalBoardLayers.isOutline(layer))
        }

        func layerUsesFill(_ layer: Int?) -> Bool {
            displayOptions.isLayerFilled(layer)
        }

        func appendLine(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float = 1,
            dash: (Float, Float)? = nil,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            buckets[keyPath: bucketKey].appendLine(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    dashLength: dash?.0 ?? 0,
                    dashGap: dash?.1 ?? 0,
                    outlineOnly: outlineOnly,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                ),
                owner: owner
            )
        }

        func appendSegment(
            _ segment: HorizontalSegment,
            color: HorizontalMetalRGBA,
            minimumWidth: Float = 1.1,
            dash: (Float, Float)? = nil,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            buckets[keyPath: bucketKey].appendLine(
                HorizontalMetalLinePrimitive(
                    from: segment.from,
                    to: segment.to,
                    color: color,
                    width: segment.width,
                    minimumWidth: minimumWidth,
                    dashLength: dash?.0 ?? 0,
                    dashGap: dash?.1 ?? 0,
                    outlineOnly: outlineOnly,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                ),
                owner: owner
            )
        }

        func appendPolyline(
            _ points: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            width: Double,
            minimumWidth: Float,
            dash: (Float, Float)? = nil,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            guard points.count >= 2 else { return }
            for pair in zip(points, points.dropFirst()) {
                buckets[keyPath: bucketKey].appendLine(
                    HorizontalMetalLinePrimitive(
                        from: pair.0,
                        to: pair.1,
                        color: color,
                        width: width,
                        minimumWidth: minimumWidth,
                        dashLength: dash?.0 ?? 0,
                        dashGap: dash?.1 ?? 0,
                        outlineOnly: outlineOnly,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity
                    ),
                    owner: owner
                )
            }
        }

        func appendArc(
            _ arc: HorizontalArc,
            color: HorizontalMetalRGBA,
            minimumWidth: Float = 1.1,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            appendPolyline(
                arc.polyline(precision: 48),
                color: color,
                width: arc.width,
                minimumWidth: minimumWidth,
                outlineOnly: outlineOnly,
                compositeGroup: compositeGroup,
                compositeOpacity: compositeOpacity,
                owner: owner,
                to: bucketKey
            )
        }

        func appendText(
            _ text: HorizontalText,
            color: HorizontalMetalRGBA,
            minimumWidth: Float = 0.75,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                buckets[keyPath: bucketKey].appendLine(
                    HorizontalMetalLinePrimitive(
                        from: segment.0,
                        to: segment.1,
                        color: color,
                        width: text.width,
                        minimumWidth: minimumWidth,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity
                    ),
                    owner: owner,
                    // Recorded for every text; only the generated-label buckets
                    // are actually filtered on it at concat time.
                    labelSize: text.size
                )
            }
        }

        func appendClosedPolyline(
            _ points: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float = 1,
            dash: (Float, Float)? = nil,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            guard let first = points.first else { return }
            appendPolyline(
                points + [first],
                color: color,
                width: width,
                minimumWidth: minimumWidth,
                dash: dash,
                compositeGroup: compositeGroup,
                compositeOpacity: compositeOpacity,
                owner: owner,
                to: bucketKey
            )
        }

        func circlePoints(center: HorizontalPoint, radius: Double, segments: Int = 48) -> [HorizontalPoint] {
            guard radius > 0 else { return [] }
            return (0..<max(segments, 12)).map { index in
                let angle = Double(index) / Double(max(segments, 12)) * Double.pi * 2
                return HorizontalPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
        }

        func appendArrowhead(
            at origin: HorizontalPoint,
            angle: Double,
            direction: Double,
            size: Double,
            color: HorizontalMetalRGBA,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            func rotated(_ point: HorizontalPoint) -> HorizontalPoint {
                HorizontalPoint(
                    x: point.x * cos(angle) - point.y * sin(angle),
                    y: point.x * sin(angle) + point.y * cos(angle)
                )
            }
            let first = origin + rotated(HorizontalPoint(x: direction * size, y: size / 2))
            let second = origin + rotated(HorizontalPoint(x: direction * size, y: -size / 2))
            appendLine(from: origin, to: first, color: color, minimumWidth: 0.8, owner: owner, to: bucketKey)
            appendLine(from: origin, to: second, color: color, minimumWidth: 0.8, owner: owner, to: bucketKey)
        }

        func appendTriangles(
            _ triangles: [HorizontalMetalTrianglePrimitive],
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            buckets[keyPath: bucketKey].appendTriangles(triangles.map { triangle in
                HorizontalMetalTrianglePrimitive(
                    a: triangle.a,
                    b: triangle.b,
                    c: triangle.c,
                    color: triangle.color,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                )
            }, owner: owner)
        }

        func appendFilledPolygon(
            _ vertices: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            appendTriangles(
                HorizontalMetalTessellator.triangles(for: vertices, color: color),
                compositeGroup: compositeGroup,
                compositeOpacity: compositeOpacity,
                owner: owner,
                to: bucketKey
            )
        }

        func appendFilledPaths(
            _ paths: [[HorizontalPoint]],
            color: HorizontalMetalRGBA,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            appendTriangles(
                HorizontalMetalTessellator.triangles(for: paths, color: color),
                compositeGroup: compositeGroup,
                compositeOpacity: compositeOpacity,
                owner: owner,
                to: bucketKey
            )
        }

        func appendFilledCircle(
            center: HorizontalPoint,
            radius: Double,
            color: HorizontalMetalRGBA,
            points: [HorizontalPoint]? = nil,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            let points = points ?? circlePoints(center: center, radius: radius)
            guard points.count >= 3 else {
                return
            }
            var triangles = [HorizontalMetalTrianglePrimitive]()
            triangles.reserveCapacity(points.count)
            for index in points.indices {
                let nextIndex = index == points.index(before: points.endIndex)
                    ? points.startIndex
                    : points.index(after: index)
                triangles.append(
                    HorizontalMetalTrianglePrimitive(
                        a: center,
                        b: points[index],
                        c: points[nextIndex],
                        color: color,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity
                    )
                )
            }
            buckets[keyPath: bucketKey].appendTriangles(triangles, owner: owner)
        }

        func appendHoleFill(
            _ hole: HorizontalHole,
            points: [HorizontalPoint]? = nil,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            // Composite in the dedicated holes group (sorts above copper, below the
            // overlay-label group) at full opacity, so the fill punches copper as
            // before but no longer covers pad/via/track name labels.
            appendFilledPolygon(
                points ?? hole.outlinePoints(precision: 32),
                color: holeFillColor,
                compositeGroup: Self.holesMetalCompositeGroup,
                compositeOpacity: 1,
                owner: owner,
                to: bucketKey
            )
        }

        func appendHoleOutline(
            _ hole: HorizontalHole,
            points: [HorizontalPoint]? = nil,
            owner: HorizontalSelectableRef? = nil,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            appendClosedPolyline(
                points ?? hole.outlinePoints(precision: 32),
                color: hole.plated ? platedHoleStrokeColor : unplatedHoleStrokeColor,
                minimumWidth: 0.75,
                compositeGroup: Self.holesMetalCompositeGroup,
                compositeOpacity: 1,
                owner: owner,
                to: bucketKey
            )
        }

        func selectableRef(id: String, type: HorizontalObjectType, layer: Int? = nil) -> HorizontalSelectableRef {
            HorizontalSelectableRef(id: id, type: type, layer: layer)
        }

        func packageOwner(for geometryID: String, layer: Int? = nil) -> HorizontalSelectableRef? {
            packageID(forGeometryID: geometryID).map {
                selectableRef(id: $0, type: .boardPackage)
            }
        }

        let viaCirclePointsByID = profile("via circle points") {
            Dictionary(uniqueKeysWithValues: board.vias.map { via in
                (via.id, circlePoints(center: via.position, radius: via.size / 2, segments: 24))
            })
        }

        let padLabelTextsByLayer = profile("pad label texts by layer") {
            selectableCache.padLabelTexts(key: derivedGeometryKey) {
                packagePadLabelTextsByLayer(board: board)
            }
        }

        // ============================================================
        // Panels (outline)
        // ============================================================
        profile("panels") {
            for panel in board.boardPanels where !panel.bounds.isEmpty {
                appendClosedPolyline(
                    [
                        HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.minY),
                        HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.minY),
                        HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.maxY),
                        HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.maxY),
                    ],
                    color: panelColor,
                    minimumWidth: 1.1,
                    dash: (7, 4),
                    to: \.panels
                )
            }

            // Panel labels (gated at concat by outline && panelLabels)
            for text in board.boardPanels.compactMap(boardPanelLabelText) {
                appendText(text, color: panelLabelColor, minimumWidth: 0.85, to: \.panelLabels)
            }
        }

        // ============================================================
        // Origin (lines + labels)
        // ============================================================
        profile("origin") {
            let originLength = 1_500_000.0
            appendLine(
                from: HorizontalPoint(x: -originLength, y: 0),
                to: HorizontalPoint(x: originLength, y: 0),
                color: originXColor,
                minimumWidth: 0.8,
                to: \.origin
            )
            appendLine(
                from: HorizontalPoint(x: 0, y: -originLength),
                to: HorizontalPoint(x: 0, y: originLength),
                color: originYColor,
                minimumWidth: 0.8,
                to: \.origin
            )
            appendText(
                boardOriginText("X", at: HorizontalPoint(x: 1_500_000, y: 0)),
                color: originXLabelColor,
                minimumWidth: 0.8,
                to: \.origin
            )
            appendText(
                boardOriginText("Y", at: HorizontalPoint(x: 0, y: 1_500_000)),
                color: originYLabelColor,
                minimumWidth: 0.8,
                to: \.origin
            )
        }

        // ============================================================
        // Body (boardBody and outline) — outlines emitted in two opacity variants
        // ============================================================
        profile("board body") {
            for polygon in board.polygons where isBoardBodyLayer(polygon.layer) {
                let owner = selectableRef(id: polygon.id, type: .polygonEdge, layer: polygon.layer)
                appendClosedPolyline(
                    polygon.renderVertices(arcPrecision: 24),
                    color: bodyHighColor,
                    minimumWidth: 1.25,
                    compositeGroup: Self.boardBodyMetalCompositeGroup,
                    owner: owner,
                    to: \.bodyOutlineHigh
                )
                appendClosedPolyline(
                    polygon.renderVertices(arcPrecision: 24),
                    color: bodyLowColor,
                    minimumWidth: 1.25,
                    compositeGroup: Self.boardBodyMetalCompositeGroup,
                    owner: owner,
                    to: \.bodyOutlineLow
                )
                if layerUsesFill(HorizontalBoardLayers.outline) {
                    appendFilledPolygon(
                        polygon.renderVertices(arcPrecision: 24),
                        color: bodyFillColor,
                        compositeGroup: Self.boardBodyMetalCompositeGroup,
                        owner: owner,
                        to: \.bodyFill
                    )
                }
            }
        }

        // ============================================================
        // Keepouts (allCopper variant — gated by hasVisibleCopper at concat)
        // ============================================================
        profile("all-copper keepouts") {
            for keepout in board.keepouts where keepout.allCopperLayers {
                let owner = selectableRef(id: keepout.id, type: .keepout, layer: keepout.polygon.layer)
                appendClosedPolyline(
                    keepout.polygon.renderVertices(arcPrecision: 24),
                    color: keepoutStrokeColor,
                    minimumWidth: 1.3,
                    dash: (7, 4),
                    owner: owner,
                    to: \.keepoutsAllCopper
                )
                appendFilledPolygon(
                    keepout.polygon.renderVertices(arcPrecision: 24),
                    color: keepoutFillColor,
                    owner: owner,
                    to: \.keepoutsAllCopper
                )
            }
        }

        // ============================================================
        // Connection lines / airwires + labels
        // ============================================================
        profile("connection lines") {
            for connectionLine in board.connectionLines {
                appendSegment(
                    connectionLine,
                    color: connectionLineDashColor,
                    minimumWidth: 0.9,
                    dash: (6, 4),
                    owner: selectableRef(id: connectionLine.id, type: .connectionLine),
                    to: \.connectionLines
                )
            }
            for airwire in board.airwires {
                appendSegment(
                    airwire,
                    color: airwireDashColor,
                    minimumWidth: 0.9,
                    dash: (6, 4),
                    to: \.connectionLines
                )
            }
            for connectionLine in board.connectionLines {
                appendText(
                    segmentLengthLabelText(connectionLine, idSuffix: "connection-length-label"),
                    color: connectionLineColor,
                    owner: selectableRef(id: connectionLine.id, type: .connectionLine),
                    to: \.connectionLabels
                )
            }
        }

        // ============================================================
        // Dimensions (lines + arrows + labels)
        // ============================================================
        profile("dimensions") {
            for dimension in board.dimensions {
                let owner = selectableRef(id: dimension.id, type: .dimension)
                let geometry = dimension.measurementGeometry
                let vector = geometry.p1Projected - geometry.p0Projected
                let length = hypot(vector.x, vector.y)
                guard length > 0 else { continue }

                let direction = vector.normalized
                let normal = geometry.normal
                let sign = dimension.labelDistance >= 0 ? 1.0 : -1.0
                let q0 = geometry.p0Projected + normal * dimension.labelDistance
                let q1 = geometry.p1Projected + normal * dimension.labelDistance
                let extensionLength = dimension.labelDistance + sign * dimension.labelSize / 2

                appendLine(
                    from: dimension.p0,
                    to: geometry.p0Projected + normal * extensionLength,
                    color: dimensionColor,
                    minimumWidth: 0.8,
                    owner: owner,
                    to: \.dimensions
                )
                appendLine(
                    from: dimension.p1,
                    to: geometry.p1Projected + normal * extensionLength,
                    color: dimensionColor,
                    minimumWidth: 0.8,
                    owner: owner,
                    to: \.dimensions
                )

                let labelWidth = HorizontalOutlineTextRenderer.textWidth(
                    dimension.label,
                    font: .simplex,
                    size: dimension.labelSize
                )
                let center = q0 + vector * 0.5
                let lineGap = labelWidth / 2 + dimension.labelSize * 0.45
                let labelFitsBetweenArrows = labelWidth + dimension.labelSize * 2 <= length

                if !labelFitsBetweenArrows {
                    appendLine(from: q0, to: q1, color: dimensionColor, minimumWidth: 0.8, owner: owner, to: \.dimensions)
                } else {
                    appendLine(from: q0, to: center - direction * lineGap, color: dimensionColor, minimumWidth: 0.8, owner: owner, to: \.dimensions)
                    appendLine(from: center + direction * lineGap, to: q1, color: dimensionColor, minimumWidth: 0.8, owner: owner, to: \.dimensions)
                }

                let arrowMul = length > dimension.labelSize * 2 ? 1.0 : -1.0
                let angle = atan2(direction.y, direction.x)
                appendArrowhead(at: q0, angle: angle, direction: arrowMul, size: dimension.labelSize, color: dimensionColor, owner: owner, to: \.dimensions)
                appendArrowhead(at: q1, angle: angle, direction: -arrowMul, size: dimension.labelSize, color: dimensionColor, owner: owner, to: \.dimensions)

                if let labelText = dimension.labelText {
                    appendText(labelText, color: dimensionColor, minimumWidth: 0.7, owner: owner, to: \.dimensions)
                }
            }
        }

        // ============================================================
        // Per-layer geometry
        // ============================================================
        for layer in renderLayers {
            let compositeGroup = metalCompositeGroup(for: layer)
            // Constant — layerOpacity is applied as a uniform at composite time.
            let compositeOpacity: Float = 1
            let outlineOnly = !layerUsesFill(layer)

            // Always-on per-layer: board polygons (non-body), lines, arcs, tracks, netTies
            profile("layer polygons lines tracks") {
                for polygon in board.polygons where polygon.layer == layer && !isBoardBodyLayer(polygon.layer) {
                    let owner = selectableRef(id: polygon.id, type: .polygonEdge, layer: layer)
                    appendClosedPolyline(
                        polygon.renderVertices(arcPrecision: 24),
                        color: layerMetalColor(layer),
                        minimumWidth: 1.2,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: owner,
                        to: \.alwaysOnLayered
                    )
                    if layerUsesFill(layer) {
                        appendFilledPolygon(
                            polygon.renderVertices(arcPrecision: 24),
                            color: layerMetalColor(layer, opacity: 0.12),
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity,
                            owner: owner,
                            to: \.alwaysOnLayered
                        )
                    }
                }

                for line in board.lines where line.layer == layer {
                    appendSegment(
                        line,
                        color: layerMetalColor(layer),
                        minimumWidth: 1.1,
                        outlineOnly: outlineOnly,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: selectableRef(id: line.id, type: .boardLine, layer: layer),
                        to: \.alwaysOnLayered
                    )
                }
                for arc in board.arcs where arc.layer == layer {
                    appendArc(
                        arc,
                        color: layerMetalColor(layer),
                        minimumWidth: 1,
                        outlineOnly: outlineOnly,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: selectableRef(id: arc.id, type: .boardArc, layer: layer),
                        to: \.alwaysOnLayered
                    )
                }
                for track in board.tracks where track.layer == layer {
                    let trackColor = track.netID == nil ? noNetTrackColor : layerMetalColor(layer)
                    let owner = selectableRef(id: track.id, type: .track, layer: layer)
                    if let arc = track.arc {
                        appendArc(arc, color: trackColor, minimumWidth: 1.1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.alwaysOnLayered)
                    } else {
                        appendSegment(track, color: trackColor, minimumWidth: 1.1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.alwaysOnLayered)
                    }
                }
                for netTie in board.netTies where netTie.layer == layer {
                    appendSegment(
                        netTie,
                        color: layerMetalColor(layer),
                        minimumWidth: 1.1,
                        outlineOnly: outlineOnly,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: selectableRef(id: netTie.id, type: .boardNetTie, layer: layer),
                        to: \.alwaysOnLayered
                    )
                }

                // Keepouts (per-layer)
                for keepout in board.keepouts where !keepout.allCopperLayers && keepout.polygon.layer == layer {
                    let owner = selectableRef(id: keepout.id, type: .keepout, layer: layer)
                    appendClosedPolyline(
                        keepout.polygon.renderVertices(arcPrecision: 24),
                        color: keepoutStrokeColor,
                        minimumWidth: 1.3,
                        dash: (7, 4),
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: owner,
                        to: \.keepoutsPerLayer
                    )
                    appendFilledPolygon(
                        keepout.polygon.renderVertices(arcPrecision: 24),
                        color: keepoutFillColor,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: owner,
                        to: \.keepoutsPerLayer
                    )
                }
            }

            // Planes (outline + fill)
            profile("planes") {
                for plane in board.planes where plane.layer == layer {
                    let owner = selectableRef(id: plane.id, type: .plane, layer: layer)
                    let planeStrokeColor = layerMetalColor(layer, opacity: plane.fragments.isEmpty ? 0.42 : 1)
                    let planeDash: (Float, Float)? = plane.fragments.isEmpty ? (4, 3) : nil
                    let planeMinimumWidth: Float = plane.fragments.isEmpty ? 1.1 : 0.7
                    let planeFillColor = layerMetalColor(layer, opacity: plane.fragments.isEmpty ? 0.1 : 1)
                    for (fragmentIndex, fragment) in plane.renderFragments.enumerated() {
                        let fragmentKey = boardPlaneFragmentKey(
                            planeID: plane.id,
                            fragmentIndex: fragmentIndex,
                            fragment: fragment
                        )
                        buckets.planes.appendLines(metalOutlineLines(
                            for: fragment,
                            fragmentKey: fragmentKey,
                            color: planeStrokeColor,
                            minimumWidth: planeMinimumWidth,
                            dash: planeDash,
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity
                        ), owner: owner)
                        if layerUsesFill(layer) {
                            buckets.planes.appendTriangles(metalTriangles(
                                for: fragment,
                                fragmentKey: fragmentKey,
                                color: planeFillColor,
                                compositeGroup: compositeGroup,
                                compositeOpacity: compositeOpacity
                            ), owner: owner)
                        }
                    }
                }
            }

            // Packages (geometry + texts)
            profile("package geometry") {
                for polygon in board.packagePolygons
                    where polygon.layer == layer && !isPackageGeometryHidden(polygon.id, layer: layer) {
                    let owner = packageOwner(for: polygon.id, layer: layer)
                    appendClosedPolyline(
                        polygon.renderVertices(arcPrecision: 24),
                        color: layerMetalColor(layer),
                        minimumWidth: 1,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: owner,
                        to: \.packagesGeometry
                    )
                    if layerUsesFill(layer) {
                        appendFilledPolygon(
                            polygon.renderVertices(arcPrecision: 24),
                            color: layerMetalColor(layer, opacity: 0.12),
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity,
                            owner: owner,
                            to: \.packagesGeometry
                        )
                    }
                }
                for line in board.packageLines
                    where line.layer == layer && !isPackageGeometryHidden(line.id, layer: layer) {
                    appendSegment(line, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: line.id, layer: layer), to: \.packagesGeometry)
                }
                for arc in board.packageArcs
                    where arc.layer == layer && !isPackageGeometryHidden(arc.id, layer: layer) {
                    appendArc(arc, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: arc.id, layer: layer), to: \.packagesGeometry)
                }
            }

            profile("package text") {
                for text in board.packageTexts where text.layer == layer {
                    // omit_silkscreen hides the package's own silk text too, but
                    // never the smashed (`fromSmash`) board-level copies, which
                    // are the whole point of smashing.
                    if !text.fromSmash, isPackageGeometryHidden(text.id, layer: layer) { continue }
                    appendText(text, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: text.id, layer: layer), to: \.packagesText)
                }
            }

            // Decals
            profile("decals") {
                for decal in board.decals {
                    let owner = selectableRef(id: decal.id, type: .boardDecal)
                    for polygon in decal.polygons where polygon.layer == layer {
                        appendClosedPolyline(
                            polygon.renderVertices(arcPrecision: 24),
                            color: layerMetalColor(layer),
                            minimumWidth: 0.7,
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity,
                            owner: owner,
                            to: \.decals
                        )
                        if layerUsesFill(layer) {
                            appendFilledPolygon(
                                polygon.renderVertices(arcPrecision: 24),
                                color: layerMetalColor(layer),
                                compositeGroup: compositeGroup,
                                compositeOpacity: compositeOpacity,
                                owner: owner,
                                to: \.decals
                            )
                        }
                    }
                    for line in decal.lines where line.layer == layer {
                        appendSegment(line, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                    }
                    for arc in decal.arcs where arc.layer == layer {
                        appendArc(arc, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                    }
                    for text in decal.texts where text.layer == layer {
                        appendText(text, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                    }
                }
            }

            // Pads
            profile("pads") {
                for pad in padOutlineFragmentsByLayer[layer] ?? [] {
                    let owner = packageOwner(for: pad.id, layer: layer)
                    if layerUsesFill(layer) {
                        appendFilledPaths(
                            pad.paths,
                            color: layerMetalColor(layer),
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity,
                            owner: owner,
                            to: \.pads
                        )
                    } else {
                        for path in pad.paths {
                            appendClosedPolyline(
                                path,
                                color: layerMetalColor(layer),
                                minimumWidth: 0.75,
                                compositeGroup: compositeGroup,
                                compositeOpacity: compositeOpacity,
                                owner: owner,
                                to: \.pads
                            )
                        }
                    }
                }
            }

            // Vias (ring + fill)
            profile("vias") {
                for via in viasByLayer[layer] ?? [] {
                    let outerRadius = via.size / 2
                    let owner = selectableRef(id: via.id, type: .via)
                    let points = viaCirclePointsByID[via.id]
                        ?? circlePoints(center: via.position, radius: outerRadius, segments: 24)
                    appendClosedPolyline(
                        points,
                        color: layerMetalColor(layer),
                        minimumWidth: 0.55,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: owner,
                        to: \.vias
                    )
                    if layerUsesFill(layer) {
                        appendFilledCircle(
                            center: via.position,
                            radius: outerRadius,
                            color: layerMetalColor(layer),
                            points: points,
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity,
                            owner: owner,
                            to: \.vias
                        )
                    }
                }
            }

            // Texts (board)
            profile("board text") {
                for text in board.texts where text.layer == layer {
                    appendText(
                        text,
                        color: layerMetalColor(layer),
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: selectableRef(id: text.id, type: .text, layer: layer),
                        to: \.text
                    )
                }
            }

            if Self.emitsGeneratedBoardLabelsInMetal {
                // Track / netTie net labels (per-layer)
                profile("track labels") {
                    for track in board.tracks where track.layer == layer && track.center == nil {
                        if let text = segmentNetLabelText(track, idSuffix: "track-net-label", padCenterKeys: trackLabelPadCenterKeys) {
                            appendText(
                                text,
                                color: textOverlayColor,
                                compositeGroup: Self.textOverlayMetalCompositeGroup,
                                compositeOpacity: Self.textOverlayMetalCompositeOpacity,
                                owner: selectableRef(id: track.id, type: .track, layer: layer),
                                to: \.trackLabels
                            )
                        }
                    }
                    for netTie in board.netTies where netTie.layer == layer {
                        if let text = segmentNetLabelText(netTie, idSuffix: "net-tie-net-label", padCenterKeys: trackLabelPadCenterKeys) {
                            appendText(
                                text,
                                color: textOverlayColor,
                                compositeGroup: Self.textOverlayMetalCompositeGroup,
                                compositeOpacity: Self.textOverlayMetalCompositeOpacity,
                                owner: selectableRef(id: netTie.id, type: .boardNetTie, layer: layer),
                                to: \.trackLabels
                            )
                        }
                    }
                }

                // Pad labels (per-layer)
                profile("pad labels") {
                    for text in padLabelTextsByLayer[layer] ?? [] {
                        appendText(
                            text,
                            color: textOverlayColor,
                            minimumWidth: 0.7,
                            compositeGroup: Self.textOverlayMetalCompositeGroup,
                            compositeOpacity: Self.textOverlayMetalCompositeOpacity,
                            owner: packageOwner(for: text.id, layer: layer),
                            to: \.padLabels
                        )
                    }
                }
            }
        }

        // ============================================================
        // Holes (outlines + fills)
        // ============================================================
        profile("holes") {
            for hole in board.holes {
                let owner = selectableRef(id: hole.id, type: .boardHole)
                let points = hole.outlinePoints(precision: 32)
                appendHoleOutline(hole, points: points, owner: owner, to: \.holesNone)
                appendHoleFill(hole, points: points, owner: owner, to: \.holesNone)
            }
            for hole in board.packageHoles {
                let owner = packageOwner(for: hole.id)
                let points = hole.outlinePoints(precision: 32)
                appendHoleOutline(hole, points: points, owner: owner, to: \.holesPad)
                appendHoleFill(hole, points: points, owner: owner, to: \.holesPad)
            }
            for hole in board.viaHoles {
                let owner = selectableRef(id: hole.id, type: .via)
                let points = hole.outlinePoints(precision: 32)
                appendHoleOutline(hole, points: points, owner: owner, to: \.holesVia)
                appendHoleFill(hole, points: points, owner: owner, to: \.holesVia)
            }
        }

        // Generated labels are intentionally omitted from Metal for now while we
        // isolate their impact on board-view interaction latency.
        if Self.emitsGeneratedBoardLabelsInMetal {
            profile("via labels") {
                for via in board.vias {
                    if let label = viaLabelText(via) {
                        appendText(label, color: textOverlayColor, minimumWidth: 0.7, compositeGroup: Self.textOverlayMetalCompositeGroup, compositeOpacity: Self.textOverlayMetalCompositeOpacity, owner: selectableRef(id: via.id, type: .via), to: \.viaLabels)
                    }
                }
            }
        }

        // Package fallback labels + anchored rect markers (for packages with no
        // resolved geometry). Gated at concat by signature.packages.
        profile("package fallback labels") {
            let resolvedPackageIDs = packageIDsWithGeometry(in: board)
            for package in board.packages where !resolvedPackageIDs.contains(package.id) {
                appendText(
                    packageFallbackLabelText(package),
                    color: package.mirrored ? bottomFallbackColor : topFallbackColor,
                    minimumWidth: 0.8,
                    owner: selectableRef(id: package.id, type: .boardPackage),
                    to: \.packagesFallback
                )
                buckets.packagesFallback.appendAnchoredRect(
                    HorizontalMetalAnchoredRectPrimitive(
                        center: package.position,
                        color: package.mirrored
                            ? HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.bottomCopper).opacity(0.55))
                            : HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.topCopper).opacity(0.55)),
                        width: 6,
                        height: 6
                    ),
                    owner: selectableRef(id: package.id, type: .boardPackage)
                )
            }
        }

        recordBoardMetalWeightSummary(buckets.namedBatches(), label: "built bucket")

        return buckets
    }

    private func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else {
            return 0
        }
        return end - start
    }

    private func measuredBoardMetalMovePatches(metadata: BoardMetalSceneMetadata) -> HorizontalMetalBufferPatches {
        guard moveState != nil else {
            return .empty
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let patches = boardMetalMovePatches(metadata: metadata)
        HorizontalMoveRateDiagnostics.recordMetalPatches(
            .boardMove,
            nanoseconds: elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
            patches: patches,
            active: moveState != nil
        )
        return patches
    }

    private func boardMetalMovePatches(metadata: BoardMetalSceneMetadata) -> HorizontalMetalBufferPatches {
        guard canPatchBoardMoveInMetal,
              let moveState else {
            return .empty
        }

        let totalDelta = moveState.lastPoint - moveState.startPoint
        let plan = moveState.residentMovePlan
        let refs = plan.translatedRefs.union(plan.segmentMoves.keys)
        guard !refs.isEmpty else {
            return .empty
        }

        // One-time id-keyed segment lookup so the per-press isRigid check is O(1)
        // per ref instead of a linear board.tracks scan (which was
        // O(segmentMoves × tracks) every press — quadratic for whole-board nudges).
        let segmentsByID = boardSegmentLookup(in: moveState.originalBoard)

        var patches = HorizontalMetalBufferPatches()
        for ref in refs {
            if let spans = metadata.lineSpansByRef[ref] {
                if let segmentMove = plan.segmentMoves[ref] {
                    if let segment = segmentsByID[normalizedID(ref.id)],
                       segmentMove.isRigid(for: segment) {
                        patches.lineTranslationPatches.append(contentsOf: metalLineTranslationPatches(spans: spans, delta: totalDelta))
                    } else if let endpointPatch = boardMetalLineEndpointPatch(
                        for: ref,
                        move: segmentMove,
                        by: totalDelta,
                        in: moveState.originalBoard,
                        spans: spans
                    ) {
                        patches.lineEndpointPatches.append(endpointPatch)
                    } else {
                        let primitives = boardResidentMovedLinePrimitives(
                            for: ref,
                            move: segmentMove,
                            by: totalDelta,
                            in: moveState.originalBoard,
                            retained: metadata.linePrimitivesByRef[ref]
                        ) ?? metadata.linePrimitivesByRef[ref] ?? []
                        HorizontalMoveRateDiagnostics.recordLineRegeneration(
                            sample: "\(ref.type):\(String(ref.id.prefix(8))) spans \(spans.count)",
                            primitiveCount: primitives.count
                        )
                        patches.linePatches.append(contentsOf: metalLinePatches(spans: spans, primitives: primitives))
                    }
                } else {
                    patches.lineTranslationPatches.append(contentsOf: metalLineTranslationPatches(spans: spans, delta: totalDelta))
                }
            }

            if let spans = metadata.triangleSpansByRef[ref],
               plan.translatedRefs.contains(ref) {
                patches.triangleTranslationPatches.append(contentsOf: metalTriangleTranslationPatches(spans: spans, delta: totalDelta))
            }

            if let spans = metadata.anchoredRectSpansByRef[ref],
               plan.translatedRefs.contains(ref) {
                patches.anchoredRectTranslationPatches.append(contentsOf: metalAnchoredRectTranslationPatches(spans: spans, delta: totalDelta))
            }
        }
        return patches
    }

    private func boardMetalLineEndpointPatch(
        for ref: HorizontalSelectableRef,
        move: BoardResidentSegmentMove,
        by delta: HorizontalPoint,
        in board: HorizontalBoard,
        spans: [BoardMetalPrimitiveSpan]
    ) -> HorizontalMetalLineEndpointPatch? {
        guard let segment = boardSegment(for: ref, in: board),
              segment.center == nil,
              move.movesFrom || move.movesTo,
              let firstSpan = spans.first,
              firstSpan.count > 0 else {
            return nil
        }

        return HorizontalMetalLineEndpointPatch(
            compositeGroup: firstSpan.compositeGroup,
            start: firstSpan.start,
            from: move.movesFrom ? segment.from + delta : nil,
            to: move.movesTo ? segment.to + delta : nil
        )
    }

    private func boardResidentMovedLinePrimitives(
        for ref: HorizontalSelectableRef,
        move: BoardResidentSegmentMove,
        by delta: HorizontalPoint,
        in board: HorizontalBoard,
        retained: [HorizontalMetalLinePrimitive]?
    ) -> [HorizontalMetalLinePrimitive]? {
        guard let segment = boardSegment(for: ref, in: board) else {
            return retained?.map { translated($0, by: delta) }
        }

        if move.isRigid(for: segment),
           let retained {
            return retained.map { translated($0, by: delta) }
        }

        return boardMetalLinePrimitives(
            for: boardResidentMovedSegment(segment, move: move, by: delta),
            type: ref.type
        )
    }

    private func boardResidentMovedSegment(
        _ segment: HorizontalSegment,
        move: BoardResidentSegmentMove,
        by delta: HorizontalPoint
    ) -> HorizontalSegment {
        var segment = segment
        if move.movesFrom {
            segment.from = segment.from + delta
        }
        if move.movesTo {
            segment.to = segment.to + delta
        }
        if move.movesCenter {
            segment.center = segment.center.map { $0 + delta }
        }
        return segment
    }

    /// One-time id-keyed lookup of all segment-like geometry, so resolving a
    /// segment for a moved ref is O(1) instead of a linear `.first(where:)` scan.
    /// UUIDs are unique across types, so a single id-keyed map is unambiguous.
    private func boardSegmentLookup(in board: HorizontalBoard) -> [String: HorizontalSegment] {
        var lookup = [String: HorizontalSegment]()
        lookup.reserveCapacity(board.tracks.count + board.netTies.count + board.lines.count + board.connectionLines.count)
        for segment in board.tracks { lookup[normalizedID(segment.id)] = segment }
        for segment in board.netTies { lookup[normalizedID(segment.id)] = segment }
        for segment in board.lines { lookup[normalizedID(segment.id)] = segment }
        for segment in board.connectionLines { lookup[normalizedID(segment.id)] = segment }
        return lookup
    }

    private func boardSegment(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalSegment? {
        let id = normalizedID(ref.id)
        switch ref.type {
        case .track:
            return board.tracks.first { normalizedID($0.id) == id }
        case .boardNetTie:
            return board.netTies.first { normalizedID($0.id) == id }
        case .boardLine:
            return board.lines.first { normalizedID($0.id) == id }
        case .connectionLine:
            return board.connectionLines.first { normalizedID($0.id) == id }
        default:
            return nil
        }
    }

    private func movedBoardRefDelta(
        ref: HorizontalSelectableRef,
        from originalBoard: HorizontalBoard,
        to currentBoard: HorizontalBoard
    ) -> HorizontalPoint? {
        guard let original = boardPatchReferencePoint(for: ref, in: originalBoard),
              let current = boardPatchReferencePoint(for: ref, in: currentBoard) else {
            return nil
        }
        return current - original
    }

    private func boardPatchReferencePoint(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalPoint? {
        let id = normalizedID(ref.id)
        switch ref.type {
        case .boardPackage:
            return board.packages.first { normalizedID($0.id) == id }?.position
        case .track:
            return board.tracks.first { normalizedID($0.id) == id }?.from
        case .boardNetTie:
            return board.netTies.first { normalizedID($0.id) == id }?.from
        case .boardLine:
            return board.lines.first { normalizedID($0.id) == id }?.from
        case .connectionLine:
            return board.connectionLines.first { normalizedID($0.id) == id }?.from
        case .boardArc:
            return board.arcs.first { normalizedID($0.id) == id }?.center
        case .via:
            return board.vias.first { normalizedID($0.id) == id }?.position
                ?? board.viaHoles.first { normalizedID($0.id) == id }?.position
        case .junction:
            return board.junctions.first { normalizedID($0.key) == id }?.value
        case .boardHole:
            return board.holes.first { normalizedID($0.id) == id }?.position
        case .text:
            return board.texts.first { normalizedID($0.id) == id }?.position
        case .keepout:
            return board.keepouts.first { normalizedID($0.id) == id }.map { HorizontalRect(points: $0.points).center }
        case .dimension:
            return board.dimensions.first { normalizedID($0.id) == id }.map { ($0.p0 + $0.p1) * 0.5 }
        case .boardDecal:
            return board.decals.first { normalizedID($0.id) == id }.map { HorizontalRect(points: $0.points).center }
        case .polygonArcCenter:
            guard let polygon = board.polygons.first(where: { normalizedID($0.id) == id }),
                  polygon.polygonVertices.indices.contains(ref.vertex) else {
                return nil
            }
            return polygon.polygonVertices[ref.vertex].arcCenter
        case .polygonEdge, .polygonVertex:
            return board.polygons.first { normalizedID($0.id) == id }.map { HorizontalRect(points: $0.renderVertices(arcPrecision: 24)).center }
        case .plane:
            return board.planes.first { normalizedID($0.id) == id }.map { HorizontalRect(points: $0.points).center }
        case .blockSymbolPort, .boardPanel, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .pad, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return nil
        }
    }

    private func changedBoardSegmentRefs(
        from originalSegments: [HorizontalSegment],
        to currentSegments: [HorizontalSegment],
        type: HorizontalObjectType
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSegments.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for segment in currentSegments {
            guard let original = originalByID[normalizedID(segment.id)] else {
                continue
            }
            if original != segment {
                refs.insert(HorizontalSelectableRef(id: segment.id, type: type, layer: segment.layer))
            }
        }
        return refs
    }

    private func nonRigidBoardSegmentRefs(
        from originalSegments: [HorizontalSegment],
        to currentSegments: [HorizontalSegment],
        type: HorizontalObjectType
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSegments.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for segment in currentSegments {
            guard let original = originalByID[normalizedID(segment.id)],
                  original != segment,
                  rigidDelta(from: original, to: segment) == nil else {
                continue
            }
            refs.insert(HorizontalSelectableRef(id: segment.id, type: type, layer: segment.layer))
        }
        return refs
    }

    private func rigidDelta(from original: HorizontalSegment, to current: HorizontalSegment) -> HorizontalPoint? {
        let delta = current.from - original.from
        guard current.to == original.to + delta else {
            return nil
        }
        switch (original.center, current.center) {
        case (.none, .none):
            return delta
        case (.some(let originalCenter), .some(let currentCenter)) where currentCenter == originalCenter + delta:
            return delta
        default:
            return nil
        }
    }

    private func changedBoardArcRefs(from originalArcs: [HorizontalArc], to currentArcs: [HorizontalArc]) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalArcs.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for arc in currentArcs {
            guard let original = originalByID[normalizedID(arc.id)] else {
                continue
            }
            if original != arc {
                refs.insert(HorizontalSelectableRef(id: arc.id, type: .boardArc, layer: arc.layer))
            }
        }
        return refs
    }

    private func nonRigidBoardArcRefs(from originalArcs: [HorizontalArc], to currentArcs: [HorizontalArc]) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalArcs.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for arc in currentArcs {
            guard let original = originalByID[normalizedID(arc.id)],
                  original != arc,
                  rigidDelta(from: original, to: arc) == nil else {
                continue
            }
            refs.insert(HorizontalSelectableRef(id: arc.id, type: .boardArc, layer: arc.layer))
        }
        return refs
    }

    private func rigidDelta(from original: HorizontalArc, to current: HorizontalArc) -> HorizontalPoint? {
        let delta = current.center - original.center
        guard current.from == original.from + delta,
              current.to == original.to + delta else {
            return nil
        }
        return delta
    }

    private func changedBoardMarkerRefs(
        from originalMarkers: [HorizontalMarker],
        to currentMarkers: [HorizontalMarker],
        type: HorizontalObjectType
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalMarkers.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for marker in currentMarkers {
            guard let original = originalByID[normalizedID(marker.id)] else {
                continue
            }
            if original != marker {
                refs.insert(HorizontalSelectableRef(id: marker.id, type: type, layer: type == .via ? nil : marker.layer))
            }
        }
        return refs
    }

    private func changedBoardTextRefs(from originalTexts: [HorizontalText], to currentTexts: [HorizontalText]) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalTexts.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for text in currentTexts {
            guard let original = originalByID[normalizedID(text.id)] else {
                continue
            }
            if original != text {
                refs.insert(HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer))
            }
        }
        return refs
    }

    private func changedBoardHoleOwnerRefs(from originalBoard: HorizontalBoard, to currentBoard: HorizontalBoard) -> Set<HorizontalSelectableRef> {
        changedBoardHoleRefs(from: originalBoard.holes, to: currentBoard.holes) { hole in
            HorizontalSelectableRef(id: hole.id, type: .boardHole)
        }
        .union(changedBoardHoleRefs(from: originalBoard.packageHoles, to: currentBoard.packageHoles) { hole in
            packageID(forGeometryID: hole.id).map { HorizontalSelectableRef(id: $0, type: .boardPackage) }
        })
        .union(changedBoardHoleRefs(from: originalBoard.viaHoles, to: currentBoard.viaHoles) { hole in
            HorizontalSelectableRef(id: hole.id, type: .via)
        })
    }

    private func changedBoardHoleRefs(
        from originalHoles: [HorizontalHole],
        to currentHoles: [HorizontalHole],
        owner: (HorizontalHole) -> HorizontalSelectableRef?
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalHoles.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for hole in currentHoles {
            guard let original = originalByID[normalizedID(hole.id)] else {
                continue
            }
            if original != hole,
               let owner = owner(hole) {
                refs.insert(owner)
            }
        }
        return refs
    }

    private func boardMetalLinePrimitives(
        for segment: HorizontalSegment,
        type: HorizontalObjectType
    ) -> [HorizontalMetalLinePrimitive] {
        var primitives = [HorizontalMetalLinePrimitive]()

        func layerMetalColor(_ layer: Int?, opacity: Double = 1) -> HorizontalMetalRGBA {
            HorizontalMetalRGBA(layerColor(for: layer).opacity(opacity))
        }

        func appendLine(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float = 1,
            dash: (Float, Float)? = nil,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0
        ) {
            primitives.append(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    dashLength: dash?.0 ?? 0,
                    dashGap: dash?.1 ?? 0,
                    outlineOnly: outlineOnly,
                    compositeGroup: compositeGroup,
                    compositeOpacity: 1
                )
            )
        }

        func appendPolyline(
            _ points: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            width: Double,
            minimumWidth: Float,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0
        ) {
            guard points.count >= 2 else { return }
            for pair in zip(points, points.dropFirst()) {
                appendLine(
                    from: pair.0,
                    to: pair.1,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    outlineOnly: outlineOnly,
                    compositeGroup: compositeGroup
                )
            }
        }

        func appendSegment(_ segment: HorizontalSegment, dash: (Float, Float)? = nil) {
            let layer = segment.layer
            let isConnectionLine = type == .connectionLine
            appendLine(
                from: segment.from,
                to: segment.to,
                color: isConnectionLine ? HorizontalMetalRGBA(theme.connectionLine.opacity(0.72)) : layerMetalColor(layer),
                width: segment.width,
                minimumWidth: isConnectionLine ? 0.9 : 1.1,
                dash: dash,
                outlineOnly: isConnectionLine ? false : !displayOptions.isLayerFilled(layer),
                compositeGroup: isConnectionLine ? 0 : (layer.map(metalCompositeGroup(for:)) ?? 0)
            )
        }

        func appendArc(_ arc: HorizontalArc) {
            appendPolyline(
                arc.polyline(precision: 48),
                color: layerMetalColor(arc.layer),
                width: arc.width,
                minimumWidth: 1.1,
                outlineOnly: !displayOptions.isLayerFilled(arc.layer),
                compositeGroup: arc.layer.map(metalCompositeGroup(for:)) ?? 0
            )
        }

        func appendText(_ text: HorizontalText, color: HorizontalMetalRGBA, minimumWidth: Float = 0.75, compositeGroup: Int = 0) {
            for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                appendLine(
                    from: segment.0,
                    to: segment.1,
                    color: color,
                    width: text.width,
                    minimumWidth: minimumWidth,
                    compositeGroup: compositeGroup
                )
            }
        }

        switch type {
        case .track:
            if let arc = segment.arc {
                appendArc(arc)
            } else {
                appendSegment(segment)
            }
            if Self.emitsGeneratedBoardLabelsInMetal,
               displayOptions.trackLabels,
               segment.center == nil,
               let text = segmentNetLabelText(segment, idSuffix: "track-net-label"),
               isGeneratedLabelLegible(text) {
                appendText(
                    text,
                    // OPAQUE + overlay group, matching the full build: a non-rigid
                    // move replaces this label's buffer subrange with the color
                    // carried here, so a baked 0.86 would re-darken the moved label
                    // (0.86 × the group's 0.86) and bring the seams back.
                    color: HorizontalMetalRGBA(theme.textOverlay),
                    compositeGroup: Self.textOverlayMetalCompositeGroup
                )
            }
        case .boardNetTie:
            appendSegment(segment)
            if Self.emitsGeneratedBoardLabelsInMetal,
               displayOptions.trackLabels,
               let text = segmentNetLabelText(segment, idSuffix: "net-tie-net-label"),
               isGeneratedLabelLegible(text) {
                appendText(
                    text,
                    // OPAQUE + overlay group, matching the full build: a non-rigid
                    // move replaces this label's buffer subrange with the color
                    // carried here, so a baked 0.86 would re-darken the moved label
                    // (0.86 × the group's 0.86) and bring the seams back.
                    color: HorizontalMetalRGBA(theme.textOverlay),
                    compositeGroup: Self.textOverlayMetalCompositeGroup
                )
            }
        case .boardLine:
            appendSegment(segment)
        case .connectionLine:
            appendSegment(segment, dash: (6, 4))
            if displayOptions.connectionLabels {
                appendText(
                    segmentLengthLabelText(segment, idSuffix: "connection-length-label"),
                    color: HorizontalMetalRGBA(theme.connectionLine.opacity(0.86))
                )
            }
        default:
            break
        }

        return primitives
    }

    private func boardMetalLinePrimitives(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> [HorizontalMetalLinePrimitive] {
        var primitives = [HorizontalMetalLinePrimitive]()

        func layerMetalColor(_ layer: Int?, opacity: Double = 1) -> HorizontalMetalRGBA {
            HorizontalMetalRGBA(layerColor(for: layer).opacity(opacity))
        }

        func layerUsesFill(_ layer: Int?) -> Bool {
            displayOptions.isLayerFilled(layer)
        }

        func appendLine(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float = 1,
            dash: (Float, Float)? = nil,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1
        ) {
            primitives.append(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    dashLength: dash?.0 ?? 0,
                    dashGap: dash?.1 ?? 0,
                    outlineOnly: outlineOnly,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                )
            )
        }

        func appendPolyline(
            _ points: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            width: Double,
            minimumWidth: Float,
            dash: (Float, Float)? = nil,
            outlineOnly: Bool = false,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1
        ) {
            guard points.count >= 2 else { return }
            for pair in zip(points, points.dropFirst()) {
                appendLine(
                    from: pair.0,
                    to: pair.1,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    dash: dash,
                    outlineOnly: outlineOnly,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                )
            }
        }

        func appendClosedPolyline(
            _ points: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float = 1,
            dash: (Float, Float)? = nil,
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1
        ) {
            guard let first = points.first else { return }
            appendPolyline(
                points + [first],
                color: color,
                width: width,
                minimumWidth: minimumWidth,
                dash: dash,
                compositeGroup: compositeGroup,
                compositeOpacity: compositeOpacity
            )
        }

        func appendSegment(_ segment: HorizontalSegment, type: HorizontalObjectType, dash: (Float, Float)? = nil) {
            let layer = segment.layer
            let compositeGroup = layer.map(metalCompositeGroup(for:)) ?? 0
            appendLine(
                from: segment.from,
                to: segment.to,
                color: type == .connectionLine ? HorizontalMetalRGBA(theme.connectionLine.opacity(0.72)) : layerMetalColor(layer),
                width: segment.width,
                minimumWidth: type == .connectionLine ? 0.9 : 1.1,
                dash: dash,
                outlineOnly: type == .connectionLine ? false : !layerUsesFill(layer),
                compositeGroup: type == .connectionLine ? 0 : compositeGroup,
                compositeOpacity: 1
            )
        }

        func appendArc(_ arc: HorizontalArc) {
            appendPolyline(
                arc.polyline(precision: 48),
                color: layerMetalColor(arc.layer),
                width: arc.width,
                minimumWidth: 1,
                outlineOnly: !layerUsesFill(arc.layer),
                compositeGroup: arc.layer.map(metalCompositeGroup(for:)) ?? 0,
                compositeOpacity: 1
            )
        }

        func appendText(_ text: HorizontalText, color: HorizontalMetalRGBA, minimumWidth: Float = 0.75, compositeGroup: Int = 0) {
            for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                appendLine(
                    from: segment.0,
                    to: segment.1,
                    color: color,
                    width: text.width,
                    minimumWidth: minimumWidth,
                    compositeGroup: compositeGroup,
                    compositeOpacity: 1
                )
            }
        }

        func circlePoints(center: HorizontalPoint, radius: Double, segments: Int = 48) -> [HorizontalPoint] {
            guard radius > 0 else { return [] }
            return (0..<max(segments, 12)).map { index in
                let angle = Double(index) / Double(max(segments, 12)) * Double.pi * 2
                return HorizontalPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
        }

        switch ref.type {
        case .track:
            guard let track = board.tracks.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else { break }
            if let arc = track.arc {
                appendArc(arc)
            } else {
                appendSegment(track, type: .track)
            }
            if Self.emitsGeneratedBoardLabelsInMetal,
               displayOptions.trackLabels,
               track.center == nil,
               let text = segmentNetLabelText(track, idSuffix: "track-net-label"),
               isGeneratedLabelLegible(text) {
                appendText(
                    text,
                    // OPAQUE + overlay group, matching the full build (see the
                    // textOverlayMetalCompositeGroup notes).
                    color: HorizontalMetalRGBA(theme.textOverlay),
                    compositeGroup: Self.textOverlayMetalCompositeGroup
                )
            }
        case .boardNetTie:
            if let netTie = board.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendSegment(netTie, type: .boardNetTie)
                if Self.emitsGeneratedBoardLabelsInMetal,
                   displayOptions.trackLabels,
                   let text = segmentNetLabelText(netTie, idSuffix: "net-tie-net-label"),
                   isGeneratedLabelLegible(text) {
                    appendText(
                        text,
                        // OPAQUE + overlay group, matching the full build (see the
                        // textOverlayMetalCompositeGroup notes).
                        color: HorizontalMetalRGBA(theme.textOverlay),
                        compositeGroup: Self.textOverlayMetalCompositeGroup
                    )
                }
            }
        case .boardLine:
            if let line = board.lines.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendSegment(line, type: .boardLine)
            }
        case .connectionLine:
            if let line = board.connectionLines.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendSegment(line, type: .connectionLine, dash: (6, 4))
                if displayOptions.connectionLabels {
                    appendText(
                        segmentLengthLabelText(line, idSuffix: "connection-length-label"),
                        color: HorizontalMetalRGBA(theme.connectionLine.opacity(0.86))
                    )
                }
            }
        case .boardArc:
            if let arc = board.arcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendArc(arc)
            }
        case .via:
            if let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                let radius = via.size / 2
                for layer in renderedViaLayers(for: via) {
                    appendClosedPolyline(
                        circlePoints(center: via.position, radius: radius),
                        color: layerMetalColor(layer),
                        minimumWidth: 0.55,
                        compositeGroup: metalCompositeGroup(for: layer)
                    )
                }
                if Self.emitsGeneratedBoardLabelsInMetal,
                   displayOptions.viaLabels,
                   let label = viaLabelText(via),
                   isGeneratedLabelLegible(label) {
                    appendText(label, color: HorizontalMetalRGBA(theme.textOverlay), minimumWidth: 0.7, compositeGroup: Self.textOverlayMetalCompositeGroup)
                }
            }
            if let hole = board.viaHoles.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendClosedPolyline(
                    hole.outlinePoints(precision: 32),
                    color: hole.plated ? HorizontalMetalRGBA(theme.hole.opacity(0.7)) : HorizontalMetalRGBA(theme.hole.opacity(0.45)),
                    minimumWidth: 0.75
                )
            }
        case .boardHole:
            if let hole = board.holes.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendClosedPolyline(
                    hole.outlinePoints(precision: 32),
                    color: hole.plated ? HorizontalMetalRGBA(theme.hole.opacity(0.7)) : HorizontalMetalRGBA(theme.hole.opacity(0.45)),
                    minimumWidth: 0.75
                )
            }
        case .text:
            if let text = board.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendText(text, color: layerMetalColor(text.layer), compositeGroup: text.layer.map(metalCompositeGroup(for:)) ?? 0)
            }
        case .boardPackage, .blockSymbolPort, .boardDecal, .boardPanel, .busLabel, .busRipper, .dimension, .drawingArc, .drawingLine, .junction, .keepout, .lineNet, .netLabel, .pad, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            break
        }

        return primitives
    }

    private func boardMetalTrianglePrimitives(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> [HorizontalMetalTrianglePrimitive] {
        var primitives = [HorizontalMetalTrianglePrimitive]()

        func layerMetalColor(_ layer: Int?, opacity: Double = 1) -> HorizontalMetalRGBA {
            HorizontalMetalRGBA(layerColor(for: layer).opacity(opacity))
        }

        func appendTriangles(
            _ triangles: [HorizontalMetalTrianglePrimitive],
            compositeGroup: Int = 0,
            compositeOpacity: Float = 1
        ) {
            primitives.append(contentsOf: triangles.map { triangle in
                HorizontalMetalTrianglePrimitive(
                    a: triangle.a,
                    b: triangle.b,
                    c: triangle.c,
                    color: triangle.color,
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity
                )
            })
        }

        switch ref.type {
        case .via:
            if let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                for layer in renderedViaLayers(for: via) where displayOptions.isLayerFilled(layer) {
                    appendTriangles(
                        HorizontalMetalTessellator.circle(center: via.position, radius: via.size / 2, color: layerMetalColor(layer)),
                        compositeGroup: metalCompositeGroup(for: layer)
                    )
                }
            }
            if let hole = board.viaHoles.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendTriangles(HorizontalMetalTessellator.triangles(for: hole.outlinePoints(precision: 32), color: HorizontalMetalRGBA(theme.background.opacity(0.95))))
            }
        case .boardHole:
            if let hole = board.holes.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendTriangles(HorizontalMetalTessellator.triangles(for: hole.outlinePoints(precision: 32), color: HorizontalMetalRGBA(theme.background.opacity(0.95))))
            }
        case .boardPackage, .track, .boardNetTie, .boardLine, .boardArc, .connectionLine, .text:
            break
        case .blockSymbolPort, .boardDecal, .boardPanel, .busLabel, .busRipper, .dimension, .drawingArc, .drawingLine, .junction, .keepout, .lineNet, .netLabel, .pad, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            break
        }

        return primitives
    }

    private func translated(_ primitive: HorizontalMetalLinePrimitive, by delta: HorizontalPoint) -> HorizontalMetalLinePrimitive {
        var primitive = primitive
        primitive.from = primitive.from + delta
        primitive.to = primitive.to + delta
        return primitive
    }

    private func translated(_ primitive: HorizontalMetalTrianglePrimitive, by delta: HorizontalPoint) -> HorizontalMetalTrianglePrimitive {
        var primitive = primitive
        primitive.a = primitive.a + delta
        primitive.b = primitive.b + delta
        primitive.c = primitive.c + delta
        return primitive
    }

    private func translated(_ primitive: HorizontalMetalHandlePrimitive, by delta: HorizontalPoint) -> HorizontalMetalHandlePrimitive {
        var primitive = primitive
        primitive.center = primitive.center + delta
        return primitive
    }

    private func translated(_ primitive: HorizontalMetalAnchoredRectPrimitive, by delta: HorizontalPoint) -> HorizontalMetalAnchoredRectPrimitive {
        var primitive = primitive
        primitive.center = primitive.center + delta
        return primitive
    }

    private func metalLinePatches(
        spans: [BoardMetalPrimitiveSpan],
        primitives: [HorizontalMetalLinePrimitive]
    ) -> [HorizontalMetalLineBufferPatch] {
        var patches = [HorizontalMetalLineBufferPatch]()
        var primitiveIndex = 0
        var pendingGroup: Int?
        var pendingStart = 0
        var pendingPrimitives = [HorizontalMetalLinePrimitive]()

        func flushPending() {
            guard let pendingGroup,
                  !pendingPrimitives.isEmpty else {
                return
            }
            patches.append(
                HorizontalMetalLineBufferPatch(
                    compositeGroup: pendingGroup,
                    start: pendingStart,
                    primitives: pendingPrimitives
                )
            )
            pendingPrimitives.removeAll(keepingCapacity: true)
        }

        for span in spans {
            guard primitiveIndex + span.count <= primitives.count else {
                return []
            }
            let spanPrimitives = Array(primitives[primitiveIndex..<(primitiveIndex + span.count)])
            if pendingGroup == span.compositeGroup,
               pendingStart + pendingPrimitives.count == span.start {
                pendingPrimitives.append(contentsOf: spanPrimitives)
            } else {
                flushPending()
                pendingGroup = span.compositeGroup
                pendingStart = span.start
                pendingPrimitives.append(contentsOf: spanPrimitives)
            }
            primitiveIndex += span.count
        }
        flushPending()
        return primitiveIndex == primitives.count ? patches : []
    }

    private func metalLineTranslationPatches(
        spans: [BoardMetalPrimitiveSpan],
        delta: HorizontalPoint
    ) -> [HorizontalMetalLineTranslationPatch] {
        var patches = [HorizontalMetalLineTranslationPatch]()
        for span in spans where span.count > 0 {
            if let last = patches.last,
               last.compositeGroup == span.compositeGroup,
               last.start + last.count == span.start {
                patches[patches.index(before: patches.endIndex)].count += span.count
            } else {
                patches.append(
                    HorizontalMetalLineTranslationPatch(
                        compositeGroup: span.compositeGroup,
                        start: span.start,
                        count: span.count,
                        delta: delta
                    )
                )
            }
        }
        return patches
    }

    private func metalTrianglePatches(
        spans: [BoardMetalPrimitiveSpan],
        primitives: [HorizontalMetalTrianglePrimitive]
    ) -> [HorizontalMetalTriangleBufferPatch] {
        var patches = [HorizontalMetalTriangleBufferPatch]()
        var primitiveIndex = 0
        var pendingGroup: Int?
        var pendingStart = 0
        var pendingPrimitives = [HorizontalMetalTrianglePrimitive]()

        func flushPending() {
            guard let pendingGroup,
                  !pendingPrimitives.isEmpty else {
                return
            }
            patches.append(
                HorizontalMetalTriangleBufferPatch(
                    compositeGroup: pendingGroup,
                    start: pendingStart,
                    primitives: pendingPrimitives
                )
            )
            pendingPrimitives.removeAll(keepingCapacity: true)
        }

        for span in spans {
            guard primitiveIndex + span.count <= primitives.count else {
                return []
            }
            let spanPrimitives = Array(primitives[primitiveIndex..<(primitiveIndex + span.count)])
            if pendingGroup == span.compositeGroup,
               pendingStart + pendingPrimitives.count == span.start {
                pendingPrimitives.append(contentsOf: spanPrimitives)
            } else {
                flushPending()
                pendingGroup = span.compositeGroup
                pendingStart = span.start
                pendingPrimitives.append(contentsOf: spanPrimitives)
            }
            primitiveIndex += span.count
        }
        flushPending()
        return primitiveIndex == primitives.count ? patches : []
    }

    private func metalTriangleTranslationPatches(
        spans: [BoardMetalPrimitiveSpan],
        delta: HorizontalPoint
    ) -> [HorizontalMetalTriangleTranslationPatch] {
        var patches = [HorizontalMetalTriangleTranslationPatch]()
        for span in spans where span.count > 0 {
            if let last = patches.last,
               last.compositeGroup == span.compositeGroup,
               last.start + last.count == span.start {
                patches[patches.index(before: patches.endIndex)].count += span.count
            } else {
                patches.append(
                    HorizontalMetalTriangleTranslationPatch(
                        compositeGroup: span.compositeGroup,
                        start: span.start,
                        count: span.count,
                        delta: delta
                    )
                )
            }
        }
        return patches
    }

    private func metalAnchoredRectPatches(
        spans: [BoardMetalPrimitiveSpan],
        primitives: [HorizontalMetalAnchoredRectPrimitive]
    ) -> [HorizontalMetalAnchoredRectBufferPatch] {
        var patches = [HorizontalMetalAnchoredRectBufferPatch]()
        var primitiveIndex = 0
        var pendingGroup: Int?
        var pendingStart = 0
        var pendingPrimitives = [HorizontalMetalAnchoredRectPrimitive]()

        func flushPending() {
            guard let pendingGroup,
                  !pendingPrimitives.isEmpty else {
                return
            }
            patches.append(
                HorizontalMetalAnchoredRectBufferPatch(
                    compositeGroup: pendingGroup,
                    start: pendingStart,
                    primitives: pendingPrimitives
                )
            )
            pendingPrimitives.removeAll(keepingCapacity: true)
        }

        for span in spans {
            guard primitiveIndex + span.count <= primitives.count else {
                return []
            }
            let spanPrimitives = Array(primitives[primitiveIndex..<(primitiveIndex + span.count)])
            if pendingGroup == span.compositeGroup,
               pendingStart + pendingPrimitives.count == span.start {
                pendingPrimitives.append(contentsOf: spanPrimitives)
            } else {
                flushPending()
                pendingGroup = span.compositeGroup
                pendingStart = span.start
                pendingPrimitives.append(contentsOf: spanPrimitives)
            }
            primitiveIndex += span.count
        }
        flushPending()
        return primitiveIndex == primitives.count ? patches : []
    }

    private func metalAnchoredRectTranslationPatches(
        spans: [BoardMetalPrimitiveSpan],
        delta: HorizontalPoint
    ) -> [HorizontalMetalAnchoredRectTranslationPatch] {
        var patches = [HorizontalMetalAnchoredRectTranslationPatch]()
        for span in spans where span.count > 0 {
            if let last = patches.last,
               last.compositeGroup == span.compositeGroup,
               last.start + last.count == span.start {
                patches[patches.index(before: patches.endIndex)].count += span.count
            } else {
                patches.append(
                    HorizontalMetalAnchoredRectTranslationPatch(
                        compositeGroup: span.compositeGroup,
                        start: span.start,
                        count: span.count,
                        delta: delta
                    )
                )
            }
        }
        return patches
    }

    private func boardMetalHighlightBatch() -> BoardMetalLineBatch {
        guard drawsBoardLinesInMetal, hasActiveHighlight else {
            return .empty
        }

        let highlightColor = HorizontalMetalRGBA(theme.junction)
        let highlightOuterColor = HorizontalMetalRGBA(theme.junction.opacity(0.94))
        let highlightPolygonFillColor = HorizontalMetalRGBA(theme.junction.opacity(0.28))
        let highlightPolygonStrokeColor = HorizontalMetalRGBA(theme.junction.opacity(0.96))
        let highlightPlaneFillColor = HorizontalMetalRGBA(theme.junction.opacity(0.18))
        let highlightPlaneStrokeColor = HorizontalMetalRGBA(theme.junction.opacity(0.78))
        let highlightHoleColor = HorizontalMetalRGBA(theme.junction.opacity(0.95))
        let highlightMarkerStrokeColor = HorizontalMetalRGBA(theme.junction.opacity(0.98))
        let highlightTextColor = HorizontalMetalRGBA(theme.junction.opacity(0.96))
        let backgroundColor = HorizontalMetalRGBA(theme.background.opacity(0.55))
        let key = BoardMetalHighlightCacheKey(
            selectableKey: selectableCacheKey,
            highlightedNetIDs: highlightedNetIDs.sorted(),
            highlightedComponentIDs: highlightedComponentIDs.sorted(),
            highlightColor: highlightColor,
            backgroundColor: backgroundColor,
            layerOpacity: layerOpacity,
            minimumLabelSize: minimumLabelSize
        )
        let boardSnapshot = board
        let displayOptionsSnapshot = displayOptions
        let pointsByPackage = boardPackageGeometryPoints()

        return selectableCache.metalHighlight(key: key) {
            var lines = [HorizontalMetalLinePrimitive]()
            var triangles = [HorizontalMetalTrianglePrimitive]()
            let highlightedNetIDs = highlightedNetIDs
            let highlightedComponentIDSet = Set(highlightedComponentIDs.map { $0.lowercased() })

            func matches(_ netID: String?) -> Bool {
                guard let netID else {
                    return false
                }
                return highlightedNetIDs.contains(netID.lowercased())
            }

            func matchesComponent(_ componentID: String?) -> Bool {
                guard let componentID else {
                    return false
                }
                return highlightedComponentIDSet.contains(componentID.lowercased())
            }

            func appendLine(
                from: HorizontalPoint,
                to: HorizontalPoint,
                color: HorizontalMetalRGBA,
                width: Double = 0,
                minimumWidth: Float,
                dash: (Float, Float)? = nil
            ) {
                lines.append(
                    HorizontalMetalLinePrimitive(
                        from: from,
                        to: to,
                        color: color,
                        width: width,
                        minimumWidth: minimumWidth,
                        dashLength: dash?.0 ?? 0,
                        dashGap: dash?.1 ?? 0
                    )
                )
            }

            func appendPolyline(
                _ points: [HorizontalPoint],
                color: HorizontalMetalRGBA,
                width: Double = 0,
                minimumWidth: Float,
                dash: (Float, Float)? = nil
            ) {
                guard points.count >= 2 else {
                    return
                }
                for pair in zip(points, points.dropFirst()) {
                    appendLine(from: pair.0, to: pair.1, color: color, width: width, minimumWidth: minimumWidth, dash: dash)
                }
            }

            func appendClosedPolyline(
                _ points: [HorizontalPoint],
                color: HorizontalMetalRGBA,
                minimumWidth: Float,
                dash: (Float, Float)? = nil
            ) {
                guard let first = points.first else {
                    return
                }
                appendPolyline(points + [first], color: color, minimumWidth: minimumWidth, dash: dash)
            }

            func appendHighlightedPolyline(
                _ points: [HorizontalPoint],
                width: Double = 0,
                minimumWidth: Float,
                dash: (Float, Float)? = nil
            ) {
                appendPolyline(points, color: highlightOuterColor, width: width, minimumWidth: minimumWidth, dash: dash)
                appendPolyline(points, color: backgroundColor, width: width, minimumWidth: 1.0, dash: dash)
            }

            func appendHighlightedSegment(_ segment: HorizontalSegment, dashed: Bool = false) {
                appendHighlightedPolyline(
                    [segment.from, segment.to],
                    width: segment.width,
                    minimumWidth: 3.2,
                    dash: dashed ? (7, 4) : nil
                )
            }

            func appendHighlightedArc(_ arc: HorizontalArc) {
                appendHighlightedPolyline(arc.polyline(precision: 48), width: arc.width, minimumWidth: 3.2)
            }

            func appendHighlightedPolygon(_ polygon: HorizontalPolygon) {
                triangles.append(contentsOf: HorizontalMetalTessellator.triangles(
                    for: polygon.renderVertices(arcPrecision: 24),
                    color: highlightPolygonFillColor
                ))
                appendClosedPolyline(polygon.renderVertices(arcPrecision: 24), color: highlightPolygonStrokeColor, minimumWidth: 2.2)
            }

            func appendHighlightedPadFragment(_ pad: HorizontalPadOutlineFragment) {
                triangles.append(contentsOf: HorizontalMetalTessellator.triangles(
                    for: pad.paths,
                    color: highlightPolygonFillColor
                ))
                for path in pad.paths {
                    appendClosedPolyline(path, color: highlightPolygonStrokeColor, minimumWidth: 2.2)
                }
            }

            func appendHighlightedHole(_ hole: HorizontalHole) {
                appendClosedPolyline(
                    hole.outlinePoints(precision: 32),
                    color: highlightHoleColor,
                    minimumWidth: 1.8
                )
            }

            func appendHighlightedMarker(_ marker: HorizontalMarker) {
                let radius = marker.size / 2 + 250_000
                triangles.append(contentsOf: HorizontalMetalTessellator.circle(
                    center: marker.position,
                    radius: radius,
                    color: highlightPolygonFillColor,
                    segments: 48
                ))
                appendClosedPolyline(
                    (0..<48).map { index in
                        let angle = Double(index) / 48 * Double.pi * 2
                        return HorizontalPoint(
                            x: marker.position.x + cos(angle) * radius,
                            y: marker.position.y + sin(angle) * radius
                        )
                    },
                    color: highlightMarkerStrokeColor,
                    minimumWidth: 2.0
                )
            }

            func appendHighlightedText(_ text: HorizontalText) {
                for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                    appendLine(
                        from: segment.0,
                        to: segment.1,
                        color: highlightTextColor,
                        width: text.width,
                        minimumWidth: 1.1
                    )
                }
            }

            func visibleViaLayersLocal(for via: HorizontalMarker) -> [Int] {
                let layers = via.connectedLayers.isEmpty
                    ? [via.layer ?? HorizontalBoardLayers.topCopper]
                    : via.connectedLayers
                return layers
                    .filter { displayOptionsSnapshot.isLayerVisible($0) }
                    .sorted()
            }

            func isBodyLayer(_ layer: Int?) -> Bool {
                guard let layer else {
                    return false
                }
                return HorizontalBoardLayers.isOutline(layer)
            }

            func packageIDPrefix(for geometryID: String) -> String? {
                let separators: Set<String> = ["arc", "hole", "line", "pad", "polygon", "text"]
                let components = geometryID.lowercased().split(separator: "/").map(String.init)
                guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
                      separatorIndex > components.startIndex else {
                    return nil
                }
                return components[..<separatorIndex].joined(separator: "/")
            }

            func belongsToPackage(_ geometryID: String, packageID: String) -> Bool {
                packageIDPrefix(for: geometryID).map { $0 == packageID } ?? false
            }

            func appendHighlightedPackage(_ package: HorizontalPlacement) {
                let packageID = package.id.lowercased()
                let packagePoints = pointsByPackage[packageID] ?? []
                let selectable = HorizontalSelectable.bounds(
                    ref: HorizontalSelectableRef(id: package.id, type: .boardPackage),
                    points: packagePoints,
                    fallbackCenter: package.position,
                    fallbackSize: 2_000_000
                )
                triangles.append(contentsOf: HorizontalMetalTessellator.triangles(for: selectable.corners, color: highlightPolygonFillColor))
                appendClosedPolyline(selectable.corners, color: highlightMarkerStrokeColor, minimumWidth: 2.0)

                if displayOptionsSnapshot.packages {
                    for polygon in boardSnapshot.packagePolygons where displayOptionsSnapshot.isLayerVisible(polygon.layer) && belongsToPackage(polygon.id, packageID: packageID) {
                        appendHighlightedPolygon(polygon)
                    }
                    for line in boardSnapshot.packageLines where displayOptionsSnapshot.isLayerVisible(line.layer) && belongsToPackage(line.id, packageID: packageID) {
                        appendHighlightedSegment(line)
                    }
                    for arc in boardSnapshot.packageArcs where displayOptionsSnapshot.isLayerVisible(arc.layer) && belongsToPackage(arc.id, packageID: packageID) {
                        appendHighlightedArc(arc)
                    }
                    for text in boardSnapshot.packageTexts where displayOptionsSnapshot.isLayerVisible(text.layer) && belongsToPackage(text.id, packageID: packageID) {
                        appendHighlightedText(text)
                    }
                }

                if displayOptionsSnapshot.pads {
                    let pads = boardSnapshot.packagePads.filter {
                        displayOptionsSnapshot.isLayerVisible($0.layer) && belongsToPackage($0.id, packageID: packageID)
                    }
                    for pad in horizonPadOutlineFragments(pads) {
                        appendHighlightedPadFragment(pad)
                    }
                }

                if displayOptionsSnapshot.holes {
                    for hole in boardSnapshot.packageHoles where belongsToPackage(hole.id, packageID: packageID) {
                        appendHighlightedHole(hole)
                    }
                }

                if displayOptionsSnapshot.text && !displayOptionsSnapshot.packages {
                    for text in boardSnapshot.packageTexts where displayOptionsSnapshot.isLayerVisible(text.layer) && belongsToPackage(text.id, packageID: packageID) {
                        appendHighlightedText(text)
                    }
                }
            }

            if displayOptionsSnapshot.packages || displayOptionsSnapshot.pads || displayOptionsSnapshot.holes || displayOptionsSnapshot.text {
                for package in boardSnapshot.packages where matchesComponent(package.componentID) {
                    appendHighlightedPackage(package)
                }
            }

            for plane in boardSnapshot.planes where displayOptionsSnapshot.isLayerVisible(plane.layer) && matches(plane.netID) {
                for (fragmentIndex, fragment) in plane.renderFragments.enumerated() {
                    let fragmentKey = boardPlaneFragmentKey(
                        planeID: plane.id,
                        fragmentIndex: fragmentIndex,
                        fragment: fragment
                    )
                    triangles.append(contentsOf: metalTriangles(for: fragment, fragmentKey: fragmentKey, color: highlightPlaneFillColor))
                    for path in fragment.paths {
                        appendClosedPolyline(path, color: highlightPlaneStrokeColor, minimumWidth: 1.5)
                    }
                }
            }

            for polygon in boardSnapshot.polygons where displayOptionsSnapshot.isLayerVisible(polygon.layer) && !isBodyLayer(polygon.layer) && matches(polygon.netID) {
                appendHighlightedPolygon(polygon)
            }

            for line in boardSnapshot.lines where displayOptionsSnapshot.isLayerVisible(line.layer) && matches(line.netID) {
                appendHighlightedSegment(line)
            }

            for arc in boardSnapshot.arcs where displayOptionsSnapshot.isLayerVisible(arc.layer) && matches(arc.netID) {
                appendHighlightedArc(arc)
            }

            for track in boardSnapshot.tracks where displayOptionsSnapshot.isLayerVisible(track.layer) && matches(track.netID) {
                if let arc = track.arc {
                    appendHighlightedArc(arc)
                } else {
                    appendHighlightedSegment(track)
                }
            }

            for netTie in boardSnapshot.netTies where displayOptionsSnapshot.isLayerVisible(netTie.layer) && matches(netTie.netID) {
                appendHighlightedSegment(netTie)
            }

            if displayOptionsSnapshot.connectionLines {
                for connectionLine in boardSnapshot.connectionLines where matches(connectionLine.netID) {
                    appendHighlightedSegment(connectionLine, dashed: true)
                }
                for airwire in boardSnapshot.airwires where matches(airwire.netID) {
                    appendHighlightedSegment(airwire, dashed: true)
                }
            }

            if displayOptionsSnapshot.pads {
                let pads = boardSnapshot.packagePads.filter {
                    displayOptionsSnapshot.isLayerVisible($0.layer) && matches($0.netID)
                }
                for pad in horizonPadOutlineFragments(pads) {
                    appendHighlightedPadFragment(pad)
                }

                if displayOptionsSnapshot.holes {
                    for hole in boardSnapshot.packageHoles where matches(hole.netID) {
                        appendHighlightedHole(hole)
                    }
                }
            }

            if displayOptionsSnapshot.vias {
                for via in boardSnapshot.vias where !visibleViaLayersLocal(for: via).isEmpty && matches(via.netID) {
                    appendHighlightedMarker(via)
                }

                if displayOptionsSnapshot.holes {
                    for hole in boardSnapshot.viaHoles where matches(hole.netID) {
                        appendHighlightedHole(hole)
                    }
                }
            }

            if displayOptionsSnapshot.holes {
                for hole in boardSnapshot.holes where matches(hole.netID) {
                    appendHighlightedHole(hole)
                }
            }

            if displayOptionsSnapshot.text {
                for text in (boardSnapshot.texts + boardSnapshot.packageTexts) where displayOptionsSnapshot.isLayerVisible(text.layer) && matches(text.netID) {
                    appendHighlightedText(text)
                }
            }

            let batchKey = key.hashValue
            return BoardMetalLineBatch(
                triangleKey: batchKey,
                triangles: triangles,
                lineKey: batchKey,
                lines: lines,
                handleKey: 0,
                handles: [],
                anchoredRectKey: 0,
                anchoredRects: []
            )
        }
    }

    private func boardMetalDimBatch(hasMetalHighlight: Bool) -> BoardMetalLineBatch {
        guard drawsBoardLinesInMetal,
              hasMetalHighlight,
              hasActiveHighlight,
              displayOptions.highlightMode != "as_is",
              !board.bounds.isEmpty else {
            return .empty
        }

        let opacity = displayOptions.highlightMode == "hide_other" ? 0.92 : 0.54
        let color = HorizontalMetalRGBA(theme.background.opacity(opacity))
        let vertices = [
            HorizontalPoint(x: board.bounds.minX, y: board.bounds.minY),
            HorizontalPoint(x: board.bounds.maxX, y: board.bounds.minY),
            HorizontalPoint(x: board.bounds.maxX, y: board.bounds.maxY),
            HorizontalPoint(x: board.bounds.minX, y: board.bounds.maxY)
        ]
        let triangles = HorizontalMetalTessellator.triangles(for: vertices, color: color)
        let key = highlightedNetIDs.hashValue
            &* 31
            &+ highlightedComponentIDs.hashValue
            &* 31
            &+ displayOptions.highlightMode.hashValue
            &+ board.bounds.minX.hashValue
            &+ board.bounds.minY.hashValue
            &+ board.bounds.maxX.hashValue
            &+ board.bounds.maxY.hashValue
        return BoardMetalLineBatch(
            triangleKey: key,
            triangles: triangles,
            lineKey: key,
            lines: [],
            handleKey: 0,
            handles: [],
            anchoredRectKey: 0,
            anchoredRects: []
        )
    }

    private func measuredBoardMetalSelectionBatch() -> BoardMetalLineBatch {
        guard moveState != nil else {
            return boardMetalSelectionBatch()
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let batch = boardMetalSelectionBatch()
        HorizontalMoveRateDiagnostics.recordTiming(
            .boardSelectionBatch,
            nanoseconds: elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
            active: moveState != nil
        )
        return batch
    }

    private func boardMetalSelectionBatch() -> BoardMetalLineBatch {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported,
              (!selectedObjects.isEmpty || hoveredObject != nil) else {
            return .empty
        }

        let selectedOuterColor = HorizontalMetalRGBA(theme.selectableOuter.opacity(0.95))
        let selectedInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.62))
        let selectedHandleInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.82))
        let selectedGroupPreviewColor = HorizontalMetalRGBA(theme.selectableAlways.opacity(0.92))
        let hoverOuterColor = HorizontalMetalRGBA(theme.selectablePrelight.opacity(0.78))
        let hoverInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.38))
        let handleShape = appearanceSettings.canvasSelectionHandleShape
        let key = BoardMetalSelectionCacheKey(
            selectableKey: selectableCacheKey,
            movePreview: canPatchBoardMoveInMetal ? nil : boardMovePreviewSignature,
            selectedRefs: selectedObjects,
            hoveredRef: hoveredObject,
            selectedOuterColor: selectedOuterColor,
            selectedInnerColor: selectedInnerColor,
            selectedHandleInnerColor: selectedHandleInnerColor,
            selectedGroupPreviewColor: selectedGroupPreviewColor,
            hoverOuterColor: hoverOuterColor,
            hoverInnerColor: hoverInnerColor,
            minimumLabelSize: minimumLabelSize,
            handleShape: handleShape
        )

        return selectableCache.metalSelection(key: key) {
            // Look up only the relevant selectables (selected + hovered) instead
            // of scanning every entry in boardSelectables(). With ~10k
            // selectables on a typical board, the previous O(n) scan ran on
            // every body fire and dominated wall time during interaction.
            let selectionBoard = canPatchBoardMoveInMetal ? (moveState?.originalBoard ?? board) : board
            let selectablesByRef = boardSelectablesByRef(in: selectionBoard)
            let style = HorizontalCanvasSelectionOverlayStyle(
                selectedOuterColor: selectedOuterColor,
                selectedInnerColor: selectedInnerColor,
                selectedHandleInnerColor: selectedHandleInnerColor,
                hoverOuterColor: hoverOuterColor,
                hoverInnerColor: hoverInnerColor,
                handleShape: handleShape
            )
            let overlay = HorizontalCanvasModeSupport.metalSelectionOverlay(
                selectablesForRef: { selectablesByRef[$0] ?? [] },
                selectedRefs: selectedObjects,
                hoveredRef: hoveredObject,
                style: style,
                outlineForSelectable: boardSelectionOutline
            )
            let polygonGroupPreviewLines = boardMetalPolygonSelectionPreviewLines(
                in: selectionBoard,
                selectedRefs: selectedObjects,
                hoveredRef: hoveredObject,
                color: selectedGroupPreviewColor
            )
            let polygonControlHandles = boardMetalPolygonSelectionControlHandles(
                in: selectionBoard,
                selectedRefs: selectedObjects,
                outerColor: selectedGroupPreviewColor,
                innerColor: selectedHandleInnerColor,
                shape: handleShape
            )

            let batchKey = key.hashValue
            return BoardMetalLineBatch(
                triangleKey: batchKey,
                triangles: [],
                lineKey: batchKey,
                lines: polygonGroupPreviewLines + overlay.lines,
                handleKey: batchKey,
                handles: polygonControlHandles + overlay.handles,
                anchoredRectKey: 0,
                anchoredRects: []
            )
        }
        #else
        return .empty
        #endif
    }

    private func measuredBoardMetalSelectionMovePatches(
        baseSelectionBatch: BoardMetalLineBatch,
        lineStart: Int,
        handleStart: Int
    ) -> HorizontalMetalBufferPatches {
        guard moveState != nil else {
            return .empty
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let patches = boardMetalSelectionMovePatches(
            baseSelectionBatch: baseSelectionBatch,
            lineStart: lineStart,
            handleStart: handleStart
        )
        HorizontalMoveRateDiagnostics.recordMetalPatches(
            .boardSelection,
            nanoseconds: elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
            patches: patches,
            active: moveState != nil
        )
        return patches
    }

    private func boardMetalSelectionMovePatches(
        baseSelectionBatch: BoardMetalLineBatch,
        lineStart: Int,
        handleStart: Int
    ) -> HorizontalMetalBufferPatches {
        guard canPatchBoardMoveInMetal,
              let moveState,
              (!baseSelectionBatch.lines.isEmpty || !baseSelectionBatch.handles.isEmpty) else {
            return .empty
        }

        let totalDelta = moveState.lastPoint - moveState.startPoint
        var patches = HorizontalMetalBufferPatches()
        if !baseSelectionBatch.lines.isEmpty {
            patches.lineTranslationPatches.append(
                HorizontalMetalLineTranslationPatch(
                    compositeGroup: 0,
                    start: lineStart,
                    count: baseSelectionBatch.lines.count,
                    delta: totalDelta
                )
            )
        }
        if !baseSelectionBatch.handles.isEmpty {
            patches.handleTranslationPatches.append(
                HorizontalMetalHandleTranslationPatch(
                    start: handleStart,
                    count: baseSelectionBatch.handles.count,
                    delta: totalDelta
                )
            )
        }
        return patches
    }

    private func boardSelectionOutline(for selectable: HorizontalSelectable) -> HorizontalCanvasSelectionOutline? {
        switch selectable.ref.type {
        case .polygonEdge:
            guard selectable.handlePoints.count >= 2 else {
                return nil
            }
            return HorizontalCanvasSelectionOutline(
                points: selectable.handlePoints,
                closesPath: false,
                normalOffset: 0,
                handlePoints: [],
                dashesWhenSelected: true,
                drawsInnerStroke: false
            )
        case .polygonArcCenter, .polygonVertex:
            return HorizontalCanvasSelectionOutline(
                points: [],
                closesPath: false,
                normalOffset: 0,
                handlePoints: [selectable.center],
                dashesWhenSelected: true,
                drawsInnerStroke: false
            )
        default:
            return nil
        }
    }

    private func boardMetalPolygonSelectionControlHandles(
        in board: HorizontalBoard,
        selectedRefs: [HorizontalSelectableRef],
        outerColor: HorizontalMetalRGBA,
        innerColor: HorizontalMetalRGBA,
        shape: HorizontalSelectionHandleShape
    ) -> [HorizontalMetalHandlePrimitive] {
        let polygonRefs = selectedRefs.filter(isPolygonControlRef)
        guard !polygonRefs.isEmpty else {
            return []
        }

        let selectedControlRefs = Set(
            polygonRefs.filter { $0.type == .polygonArcCenter || $0.type == .polygonVertex }
        )
        let polygonIDs = Set(polygonRefs.map { normalizedID($0.id) })
        let polygons = board.polygons + board.planes.compactMap(\.fallbackPolygon)
        let outerRadius = max(Float(shape.outerRadius) * 0.56, 5)
        let innerRadius = max(Float(shape.innerRadius) * 0.56, 2.5)

        var seenRefs = Set<HorizontalSelectableRef>()
        var handles = [HorizontalMetalHandlePrimitive]()

        func appendHandle(ref: HorizontalSelectableRef, center: HorizontalPoint) {
            guard !selectedControlRefs.contains(ref),
                  seenRefs.insert(ref).inserted else {
                return
            }
            handles.append(
                HorizontalMetalHandlePrimitive(
                    center: center,
                    outerColor: outerColor,
                    innerColor: innerColor,
                    shape: shape,
                    outerRadius: outerRadius,
                    innerRadius: innerRadius
                )
            )
        }

        for polygon in polygons where polygonIDs.contains(normalizedID(polygon.id)) {
            guard displayOptions.isLayerVisible(polygon.layer) else {
                continue
            }
            for (index, vertex) in polygon.polygonVertices.enumerated() {
                appendHandle(
                    ref: HorizontalSelectableRef(id: polygon.id, type: .polygonVertex, vertex: index, layer: polygon.layer),
                    center: vertex.position
                )
                if vertex.type == .arc {
                    appendHandle(
                        ref: HorizontalSelectableRef(id: polygon.id, type: .polygonArcCenter, vertex: index, layer: polygon.layer),
                        center: vertex.arcCenter
                    )
                }
            }
        }

        return handles
    }

    private func boardMetalPolygonSelectionPreviewLines(
        in board: HorizontalBoard,
        selectedRefs: [HorizontalSelectableRef],
        hoveredRef: HorizontalSelectableRef?,
        color: HorizontalMetalRGBA
    ) -> [HorizontalMetalLinePrimitive] {
        let activeRefs = HorizontalCanvasModeSupport.uniqueRefs(selectedRefs + [hoveredRef].compactMap { $0 })
            .filter { $0.type == .polygonArcCenter || $0.type == .polygonEdge || $0.type == .polygonVertex }
        guard !activeRefs.isEmpty else {
            return []
        }

        let polygonIDs = Set(activeRefs.map { normalizedID($0.id) })
        let activeEdgeKeys = Set(
            activeRefs
                .filter { $0.type == .polygonEdge }
                .map(polygonEdgeSelectionKey)
        )
        let polygons = board.polygons + board.planes.compactMap(\.fallbackPolygon)
        let edgeSelectables = filterVisibleSelectables(
            polygonEdgeSelectables(polygons, type: .polygonEdge),
            in: board
        )

        var seenEdges = Set<String>()
        var lines = [HorizontalMetalLinePrimitive]()
        for selectable in edgeSelectables where polygonIDs.contains(normalizedID(selectable.ref.id)) {
            let key = polygonEdgeSelectionKey(selectable.ref)
            guard !activeEdgeKeys.contains(key),
                  seenEdges.insert(key).inserted,
                  selectable.handlePoints.count >= 2 else {
                continue
            }
            lines.append(contentsOf: zip(selectable.handlePoints, selectable.handlePoints.dropFirst()).map {
                HorizontalMetalLinePrimitive(
                    from: $0.0,
                    to: $0.1,
                    color: color,
                    minimumWidth: 1.8,
                    dashLength: 5,
                    dashGap: 4,
                    normalOffset: 0
                )
            })
        }
        return lines
    }

    private func isPolygonControlRef(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            return true
        default:
            return false
        }
    }

    private func polygonEdgeSelectionKey(_ ref: HorizontalSelectableRef) -> String {
        [
            normalizedID(ref.id),
            String(ref.vertex),
            ref.layer.map(String.init) ?? "nil"
        ].joined(separator: ":")
    }

    private func boardMetalPreviewBatch() -> BoardMetalLineBatch {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported else {
            return .empty
        }

        var lines = [HorizontalMetalLinePrimitive]()

        func appendSegment(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float = 1.6
        ) {
            guard pointKey(from) != pointKey(to) else {
                return
            }
            lines.append(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    dashLength: 5,
                    dashGap: 4
                )
            )
        }

        func appendSegment(_ segment: HorizontalSegment, opacity: Double = 0.82) {
            appendSegment(
                from: segment.from,
                to: segment.to,
                color: HorizontalMetalRGBA(theme.textOverlay.opacity(opacity))
            )
        }

        func appendArc(_ arc: HorizontalArc, opacity: Double = 0.82) {
            let color = HorizontalMetalRGBA(theme.textOverlay.opacity(opacity))
            let points = arc.polyline(precision: 48)
            for pair in zip(points, points.dropFirst()) {
                appendSegment(from: pair.0, to: pair.1, color: color)
            }
        }

        if let state = drawGraphicsState {
            var points = state.points
            if let cursor = state.cursor,
               points.isEmpty || pointKey(points.last ?? cursor) != pointKey(cursor) {
                points.append(cursor)
            }

            let result = previewGraphicsResult(
                for: state.primitive,
                points: points,
                layer: state.layer,
                rectanglePlacementMode: state.rectanglePlacementMode
            )
            for segment in result.lines {
                appendSegment(segment)
            }
            for arc in result.arcs {
                appendArc(arc)
            }
            for polygon in result.polygons {
                for segment in closedBoardDrawingSegments(points: polygon.renderVertices(arcPrecision: 24), layer: polygon.layer ?? state.layer) {
                    appendSegment(segment)
                }
            }

            if state.primitive == .arc, let center = state.points.first, let cursor = state.cursor {
                appendSegment(
                    HorizontalSegment(id: "arc-radius-preview", from: center, to: cursor, width: 0, layer: nil),
                    opacity: 0.35
                )
            }
        }

        // Track preview: a translucent rubber-band route at the real copper
        // width on the active layer, following the cursor between clicks. Drawn
        // solid (not dashed) so it reads as a ghost of the finished track.
        if let track = drawTrackState {
            let color = HorizontalMetalRGBA(layerColor(for: track.layer).opacity(0.5))
            for routePoints in trackPreviewPolylines(track) {
                for pair in zip(routePoints, routePoints.dropFirst()) where pointKey(pair.0) != pointKey(pair.1) {
                    lines.append(
                        HorizontalMetalLinePrimitive(
                            from: pair.0,
                            to: pair.1,
                            color: color,
                            width: track.width,
                            minimumWidth: 1.6
                        )
                    )
                }
            }
        }

        guard !lines.isEmpty else {
            return .empty
        }
        let key = lines.hashValue
        return BoardMetalLineBatch(
            triangleKey: key,
            triangles: [],
            lineKey: key,
            lines: lines,
            handleKey: 0,
            handles: [],
            anchoredRectKey: 0,
            anchoredRects: []
        )
        #else
        return .empty
        #endif
    }

    private func buildAllBoardSelectables(in board: HorizontalBoard) -> [HorizontalSelectable] {
        // Visibility-independent: emits every potentially selectable object.
        // filterVisibleSelectables(_:) applies the live displayOptions at hit-test time.
        var selectables = [HorizontalSelectable]()

        selectables.append(contentsOf: boardPanelSelectables(in: board))

        selectables.append(contentsOf: polygonEdgeSelectables(
            board.polygons,
            type: .polygonEdge
        ))
        selectables.append(contentsOf: polygonEdgeSelectables(
            board.planes.compactMap(\.fallbackPolygon),
            type: .polygonEdge
        ))

        selectables.append(contentsOf: board.keepouts.map { keepout in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: keepout.id, type: .keepout, layer: keepout.polygon.layer),
                points: keepout.points,
                fallbackCenter: HorizontalRect(points: keepout.points).center,
                fallbackSize: 1_000_000
            )
        })

        selectables.append(contentsOf: board.decals.compactMap { decal in
            // Use the full geometric bounds; visibility is applied at filter time.
            // Hit bounds may be slightly larger than the visible silhouette when
            // some sub-layers are hidden — acceptable trade-off for cache stability.
            let allPoints = decal.polygons.flatMap(\.vertices)
                + decal.lines.flatMap { [$0.from, $0.to] }
                + decal.arcs.flatMap { $0.polyline(precision: 24) }
                + decal.texts.flatMap(\.renderBoundsPoints)
            guard !allPoints.isEmpty else {
                return nil
            }
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: decal.id, type: .boardDecal),
                points: allPoints,
                fallbackCenter: HorizontalRect(points: allPoints).center,
                fallbackSize: 1_000_000
            )
        })

        selectables.append(contentsOf: board.dimensions.map { dimension in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: dimension.id, type: .dimension),
                points: dimension.points,
                fallbackCenter: (dimension.p0 + dimension.p1) * 0.5,
                fallbackSize: dimension.labelSize
            )
        })

        selectables.append(contentsOf: segmentSelectables(board.lines, type: .boardLine))
        selectables.append(contentsOf: arcSelectables(board.arcs, type: .boardArc))
        selectables.append(contentsOf: segmentSelectables(board.tracks, type: .track))
        selectables.append(contentsOf: segmentSelectables(board.netTies, type: .boardNetTie))

        selectables.append(contentsOf: segmentSelectables(board.connectionLines, type: .connectionLine))

        selectables.append(contentsOf: board.junctions.map { id, point in
            HorizontalSelectable.point(ref: HorizontalSelectableRef(id: id, type: .junction), at: point)
        })

        selectables.append(contentsOf: board.vias.map { via in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: via.id, type: .via, layer: via.layer),
                points: via.boundsPoints,
                fallbackCenter: via.position,
                fallbackSize: via.size
            )
        })

        selectables.append(contentsOf: (board.holes + board.packageHoles).map { hole in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: hole.id, type: .boardHole),
                points: hole.boundsPoints,
                fallbackCenter: hole.position,
                fallbackSize: hole.diameter
            )
        })

        selectables.append(contentsOf: boardPackageSelectables(in: board))

        // Standalone board text is independently selectable. Package-owned text
        // (refdes / value / assembly annotations) normally is NOT — it belongs to
        // its package — EXCEPT a SMASHED package's extracted `fromSmash` copies,
        // which are the point of smashing: individually editable board text.
        selectables.append(contentsOf: textSelectables(board.texts))
        selectables.append(contentsOf: textSelectables(board.packageTexts.filter { $0.fromSmash }))

        return selectables
    }

    private func boardSnapTargets() -> [HorizontalPoint] {
        if let moveSnapTargets = moveState?.snapTargets {
            return moveSnapTargets
        }
        return selectableCache.snapTargets(key: selectableCacheKey) {
            boardSelectableScene().snapTargets(pointKey: pointKey)
        }
    }

    private func segmentSelectables(_ segments: [HorizontalSegment], type: HorizontalObjectType) -> [HorizontalSelectable] {
        HorizontalCanvasModeSupport.segmentSelectables(segments, type: type, convertsArcSegments: true)
    }

    private func segmentSelectable(for ref: HorizontalSelectableRef, in segments: [HorizontalSegment]) -> HorizontalSelectable? {
        HorizontalCanvasModeSupport.segmentSelectable(for: ref, in: segments)
    }

    private func arcSelectables(_ arcs: [HorizontalArc], type: HorizontalObjectType) -> [HorizontalSelectable] {
        HorizontalCanvasModeSupport.arcSelectables(arcs, type: type)
    }

    private func polygonEdgeSelectables(_ polygons: [HorizontalPolygon], type: HorizontalObjectType) -> [HorizontalSelectable] {
        polygons.flatMap { polygon in
            guard polygon.polygonVertices.count >= 2 else {
                return [HorizontalSelectable]()
            }

            var result = [HorizontalSelectable]()
            for index in polygon.polygonVertices.indices {
                let vertex = polygon.polygonVertices[index]
                let edgePoints = polygon.edgePolyline(at: index, arcPrecision: 24)
                if vertex.type == .arc {
                    result.append(HorizontalSelectable.bounds(
                        ref: HorizontalSelectableRef(id: polygon.id, type: type, vertex: index, layer: polygon.layer),
                        points: edgePoints,
                        fallbackCenter: vertex.arcCenter,
                        fallbackSize: 1_000_000
                    ))
                    result.append(HorizontalSelectable.point(
                        ref: HorizontalSelectableRef(id: polygon.id, type: .polygonArcCenter, vertex: index, layer: polygon.layer),
                        at: vertex.arcCenter
                    ))
                } else if edgePoints.count >= 2 {
                    result.append(HorizontalSelectable.line(
                        ref: HorizontalSelectableRef(id: polygon.id, type: type, vertex: index, layer: polygon.layer),
                        from: edgePoints[0],
                        to: edgePoints[1],
                        width: 0,
                        layer: polygon.layer
                    ))
                }
                result.append(HorizontalSelectable.point(
                    ref: HorizontalSelectableRef(id: polygon.id, type: .polygonVertex, vertex: index, layer: polygon.layer),
                    at: vertex.position
                ))
            }
            return result
        }
    }

    private func boardPanelSelectables() -> [HorizontalSelectable] {
        boardPanelSelectables(in: board)
    }

    private func boardPanelSelectables(in board: HorizontalBoard) -> [HorizontalSelectable] {
        board.boardPanels.compactMap { panel in
            guard !panel.bounds.isEmpty else {
                return nil
            }
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: panel.id, type: .boardPanel),
                points: [
                    HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.minY),
                    HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.maxY)
                ],
                fallbackCenter: panel.bounds.center,
                fallbackSize: 1_000_000
            )
        }
    }

    private func textSelectables(_ texts: [HorizontalText]) -> [HorizontalSelectable] {
        HorizontalCanvasModeSupport.textSelectables(texts)
    }

    private func drawGrid(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        HorizontalGridRenderer.drawCrossGrid(
            context: context,
            transform: transform,
            baseSpacing: board.grid.spacing,
            origin: board.grid.origin,
            color: theme.grid,
            lineWidth: appearanceSettings.gridMarkLineWidth
        )
    }

    private func drawBoardBeforeMetalLines(
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        renderLayers: [Int]
    ) {
        if displayOptions.grid && !drawsGridInMetal {
            drawGrid(context: context, transform: transform)
        }

        drawLayerPlanesBeforeMetalLines(renderLayers: renderLayers, context: context, transform: transform)
    }

    private func drawBoardTopCanvasOverlay(
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        drawsPlaneHighlightInCanvas: Bool,
        drawsSelectionOutlinesInMetal: Bool,
        drawsPreviewInMetal: Bool
    ) {
        if drawsPlaneHighlightInCanvas {
            drawComplexPlaneNetHighlight(context: context, transform: transform)
        }
        if !drawsSelectionOutlinesInMetal {
            drawSelection(context: context, transform: transform)
        }
        if !drawsPreviewInMetal {
            drawGraphicsPreview(context: context, transform: transform)
            drawTrackPreview(context: context, transform: transform)
        }
    }

    private func diameterString(_ diameter: Double) -> String {
        lengthString(diameter)
    }

    private func lengthString(_ length: Double) -> String {
        let millimeters = length / 1_000_000
        if millimeters >= 1 {
            return millimeters.formatted(.number.precision(.fractionLength(2))) + " mm"
        }
        return (millimeters * 1_000).formatted(.number.precision(.fractionLength(0))) + " um"
    }

    private func areaString(_ area: Double) -> String {
        let squareMillimeters = area / 1_000_000_000_000
        return squareMillimeters.formatted(.number.precision(.fractionLength(2))) + " mm^2"
    }

    private func coordinateString(_ point: HorizontalPoint) -> String {
        "\(lengthString(point.x)), \(lengthString(point.y))"
    }

    private func angleString(_ angle: Int) -> String {
        let degrees = Double(angle) / 65_536.0 * 360.0
        return degrees.formatted(.number.precision(.fractionLength(0))) + " deg"
    }

    private func angle(from: HorizontalPoint, to: HorizontalPoint) -> Int {
        let radians = atan2(to.y - from.y, to.x - from.x)
        return Int((radians / (2 * .pi) * 65_536).rounded())
    }

    private func boardPanelLabelTexts() -> [HorizontalText] {
        board.boardPanels.compactMap(boardPanelLabelText)
    }

    private func boardPanelLabelText(_ panel: HorizontalBoardPanel) -> HorizontalText? {
        guard !panel.boardName.isEmpty else {
            return nil
        }
        let shortSide = min(panel.bounds.width, panel.bounds.height)
        let textSize = min(max(shortSide * 0.035, 900_000), 2_200_000)
        let inset = textSize * 0.8
        return HorizontalText(
            id: "\(panel.id)/panel-label",
            text: panel.boardName,
            position: HorizontalPoint(x: panel.bounds.minX + inset, y: panel.bounds.maxY - inset),
            size: textSize,
            layer: nil,
            origin: .baseline
        )
    }

    private func boardOriginText(_ label: String, at position: HorizontalPoint) -> HorizontalText {
        HorizontalText(
            id: "board-origin-\(label)",
            text: label,
            position: position,
            size: 700_000,
            layer: nil,
            origin: .center,
            centered: true
        )
    }

    private func drawLayerPlanesBeforeMetalLines(
        renderLayers: [Int],
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for layer in renderLayers {
            context.drawLayer { layerContext in
                layerContext.opacity = layerOpacity
                drawBoardLayerBeforeMetalLines(layer, context: layerContext, transform: transform)
            }
        }
    }

    private func drawBoardLayerBeforeMetalLines(_ layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        drawPlanesRequiringCanvas(on: layer, context: context, transform: transform)
    }

    private func visibleRenderLayers() -> [Int] {
        selectableCache.visibleRenderLayers(key: selectableCacheKey) {
            buildVisibleRenderLayers()
        }
    }

    private func buildVisibleRenderLayers() -> [Int] {
        var layers = Set<Int>()

        func insert(_ layer: Int?) {
            guard let layer, displayOptions.isLayerVisible(layer) else {
                return
            }
            layers.insert(layer)
        }

        for polygon in board.polygons where !isBoardBodyLayer(polygon.layer) {
            insert(polygon.layer)
        }
        if displayOptions.keepouts {
            for keepout in board.keepouts {
                if !keepout.allCopperLayers {
                    insert(keepout.polygon.layer)
                }
            }
        }
        for plane in board.planes {
            insert(plane.layer)
        }
        if displayOptions.packages {
            for polygon in board.packagePolygons {
                insert(polygon.layer)
            }
            for line in board.packageLines {
                insert(line.layer)
            }
            for arc in board.packageArcs {
                insert(arc.layer)
            }
        }
        for line in board.lines {
            insert(line.layer)
        }
        for arc in board.arcs {
            insert(arc.layer)
        }
        for track in board.tracks {
            insert(track.layer)
        }
        for netTie in board.netTies {
            insert(netTie.layer)
        }
        if displayOptions.pads {
            for pad in board.packagePads {
                insert(pad.layer)
            }
        }
        if displayOptions.vias {
            for via in board.vias {
                for layer in visibleViaLayers(for: via) {
                    layers.insert(layer)
                }
            }
        }
        if displayOptions.decals {
            for decal in board.decals {
                for polygon in decal.polygons {
                    insert(polygon.layer)
                }
                for line in decal.lines {
                    insert(line.layer)
                }
                for arc in decal.arcs {
                    insert(arc.layer)
                }
                for text in decal.texts {
                    insert(text.layer)
                }
            }
        }
        if displayOptions.text {
            for text in board.texts {
                insert(text.layer)
            }
            for text in board.packageTexts {
                insert(text.layer)
            }
        }

        return layers.sorted { layerRenderPrecedence($0) < layerRenderPrecedence($1) }
    }

    private func boardMetalRenderLayers() -> [Int] {
        // Build only the layers that can currently contribute visible primitives.
        // Hidden layers will rebuild the Metal bucket cache when they are shown,
        // but initial load avoids baking invisible layer groups into the scene.
        visibleRenderLayers()
    }

    private func buildBoardMetalRenderLayers() -> [Int] {
        // Element-type displayOptions flags are intentionally NOT consulted here so
        // the bucket cache keyed on this list survives element-type toggles. The
        // bucket build emits primitives for every element type; concat applies
        // visibility at draw time.
        var layers = Set<Int>()

        func insert(_ layer: Int?) {
            guard let layer else {
                return
            }
            layers.insert(layer)
        }

        for polygon in board.polygons where !isBoardBodyLayer(polygon.layer) {
            insert(polygon.layer)
        }
        for keepout in board.keepouts where !keepout.allCopperLayers {
            insert(keepout.polygon.layer)
        }
        for plane in board.planes {
            insert(plane.layer)
        }
        for polygon in board.packagePolygons {
            insert(polygon.layer)
        }
        for line in board.packageLines {
            insert(line.layer)
        }
        for arc in board.packageArcs {
            insert(arc.layer)
        }
        for line in board.lines {
            insert(line.layer)
        }
        for arc in board.arcs {
            insert(arc.layer)
        }
        for track in board.tracks {
            insert(track.layer)
        }
        for netTie in board.netTies {
            insert(netTie.layer)
        }
        for pad in board.packagePads {
            insert(pad.layer)
        }
        for via in board.vias {
            for layer in renderedViaLayers(for: via) {
                layers.insert(layer)
            }
        }
        for decal in board.decals {
            for polygon in decal.polygons {
                insert(polygon.layer)
            }
            for line in decal.lines {
                insert(line.layer)
            }
            for arc in decal.arcs {
                insert(arc.layer)
            }
            for text in decal.texts {
                insert(text.layer)
            }
        }
        for text in board.texts {
            insert(text.layer)
        }
        for text in board.packageTexts {
            insert(text.layer)
        }

        return layers.sorted { layerRenderPrecedence($0) < layerRenderPrecedence($1) }
    }

    private func visibleMetalCompositeGroups(for renderLayers: [Int]) -> Set<Int> {
        var groups = Set(renderLayers.map(metalCompositeGroup(for:)))
        if displayOptions.boardBody || displayOptions.outline {
            groups.insert(Self.boardBodyMetalCompositeGroup)
        }
        // The overlay-label group must be composited whenever labels can appear.
        // Inserting it unconditionally is free when no labels are present: the
        // renderer drops empty composite batches, so an empty label group never
        // allocates an offscreen texture or a composite pass.
        groups.insert(Self.textOverlayMetalCompositeGroup)
        // Likewise the drill-hole group. activeCompositeBatches() filters on
        // currentVisibleCompositeGroups, so an un-listed group's texture is
        // discarded; empty batches are dropped, so inserting it unconditionally is
        // free when no holes are present.
        groups.insert(Self.holesMetalCompositeGroup)
        return groups
    }

    private func visibleCopperLayers() -> [Int] {
        HorizontalBoardLayers.all.filter {
            HorizontalBoardLayers.isCopper($0) && displayOptions.isLayerVisible($0)
        }
    }

    private func layerRenderPrecedence(_ layer: Int) -> Int {
        layer
    }

    private func metalCompositeGroup(for layer: Int) -> Int {
        BoardLayerStyle.compositeGroup(for: layer)
    }

    private func drawBoardPolygons(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for polygon in board.polygons where polygon.layer == layer && !isBoardBodyLayer(polygon.layer) {
            let path = closedPath(for: polygon.renderVertices(arcPrecision: 24), transform: transform)
            context.fill(path, with: .color(layerColor(for: layer).opacity(0.12)))
            context.stroke(path, with: .color(layerColor(for: layer).opacity(0.75)), lineWidth: transform.strokeWidth(0, minimum: 1.2))
        }
    }

    private func drawPlanes(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for plane in board.planes where plane.layer == layer {
            let planeColor = layerColor(for: layer)
            let isFallback = plane.fragments.isEmpty

            for fragment in plane.renderFragments {
                let path = compoundPath(for: fragment.paths, transform: transform)
                if displayOptions.isLayerFilled(layer) {
                    context.fill(
                        path,
                        with: .color(planeColor.opacity(isFallback ? 0.1 : 0.22)),
                        style: FillStyle(eoFill: true, antialiased: true)
                    )
                }
                context.stroke(
                    path,
                    with: .color(planeColor.opacity(isFallback ? 0.42 : 0.34)),
                    style: StrokeStyle(lineWidth: transform.strokeWidth(0, minimum: isFallback ? 1.1 : 0.7), dash: isFallback ? [4, 3] : [])
                )
            }
        }
    }

    private func drawPlanesRequiringCanvas(on _: Int, context _: GraphicsContext, transform _: HorizontalCanvasTransform) {
    }

    private func drawKeepouts(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for keepout in board.keepouts where !keepout.allCopperLayers && keepout.polygon.layer == layer {
            let path = closedPath(for: keepout.polygon.renderVertices(arcPrecision: 24), transform: transform)
            context.fill(path, with: .color(theme.error.opacity(0.12)))
            context.stroke(
                path,
                with: .color(theme.error.opacity(0.76)),
                style: StrokeStyle(lineWidth: transform.strokeWidth(0, minimum: 1.3), dash: [7, 4])
            )
        }
    }

    private func drawDecals(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for decal in board.decals {
            for polygon in decal.polygons where polygon.layer == layer {
                let path = closedPath(for: polygon.renderVertices(arcPrecision: 24), transform: transform)
                context.fill(path, with: .color(layerColor(for: layer)))
                context.stroke(path, with: .color(layerColor(for: layer)), lineWidth: transform.strokeWidth(0, minimum: 0.7))
            }

            for line in decal.lines where line.layer == layer {
                drawSegment(line, transform: transform, context: context, fallbackColor: layerColor(for: layer))
            }

            for arc in decal.arcs where arc.layer == layer {
                drawArc(arc, transform: transform, context: context, color: layerColor(for: layer), minimumWidth: 1)
            }

            for text in decal.texts where text.layer == layer {
                HorizontalOutlineTextRenderer.draw(
                    text,
                    color: layerColor(for: layer),
                    context: context,
                    transform: transform
                )
            }
        }
    }

    private func holePath(
        _ hole: HorizontalHole,
        transform: HorizontalCanvasTransform,
        minimumRadius: CGFloat,
        outset: CGFloat = 0
    ) -> Path {
        if hole.shape == .round || hole.effectiveLength <= hole.diameter {
            let point = transform.point(hole.position)
            let radius = max(transform.length(hole.diameter) / 2, minimumRadius) + outset
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            return Path(ellipseIn: rect)
        }

        var path = Path()
        let points = hole.outlinePoints(precision: 32).map(transform.point)
        guard let first = points.first else {
            return path
        }

        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        if outset <= 0 {
            return path
        }

        return path.strokedPath(StrokeStyle(lineWidth: outset * 2, lineCap: .round, lineJoin: .round))
    }

    private func holeLabel(for hole: HorizontalHole) -> String {
        guard hole.shape == .slot, hole.effectiveLength > hole.diameter else {
            return diameterString(hole.diameter)
        }
        return "\(diameterString(hole.diameter)) x \(diameterString(hole.effectiveLength))"
    }

    private func drawVias(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for via in board.vias where visibleViaLayers(for: via).contains(layer) {
            drawViaRing(via, layer: layer, context: context, transform: transform)
        }
    }

    private func visibleViaLayers(for via: HorizontalMarker) -> [Int] {
        renderedViaLayers(for: via)
            .filter { displayOptions.isLayerVisible($0) }
    }

    private func renderedViaLayers(for via: HorizontalMarker) -> [Int] {
        BoardLayerStyle.renderedViaLayers(for: via)
    }

    private func drawViaRing(
        _ via: HorizontalMarker,
        layer: Int,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let point = transform.point(via.position)
        let outerRadius = max(transform.length(via.size) / 2, 1.8)
        let outerRect = CGRect(x: point.x - outerRadius, y: point.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2)
        let outerPath = Path(ellipseIn: outerRect)

        context.fill(outerPath, with: .color(layerColor(for: layer).opacity(0.86)))
        context.stroke(outerPath, with: .color(layerColor(for: layer).opacity(0.9)), lineWidth: transform.strokeWidth(0, minimum: 0.55))
    }

    private func drawViaLabel(
        _ via: HorizontalMarker,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        guard transform.length(via.size) >= 5 else {
            return
        }

        guard let label = viaLabelText(via),
              isGeneratedLabelLegible(label) else {
            return
        }
        HorizontalOutlineTextRenderer.draw(
            label,
            color: theme.textOverlay,
            context: context,
            transform: transform,
            minimumLineWidth: 0.7
        )
    }

    /// A via's label is its net name, fitted INSIDE the via like a (circular) pad
    /// — the via is a `via.size`-diameter disc, so it runs through the same
    /// `BoardPadLabelLayout` frame + fit machinery pads use, centered on the via.
    /// Returns nil for a via with no net (nothing to label).
    private func viaLabelText(_ via: HorizontalMarker) -> HorizontalText? {
        guard let netName = namedNetDisplayName(via.netID),
              !netName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let descriptor = PadLabelFrameDescriptor(
            center: via.position,
            halfWidth: via.size / 2,
            halfHeight: via.size / 2,
            angle: 0
        )
        guard let frame = BoardPadLabelLayout.frame(fromDescriptor: descriptor) else {
            return nil
        }
        let size = BoardPadLabelLayout.fittedTextSize(netName, frame: frame, mode: .full)
        guard size > 0 else {
            return nil
        }
        return HorizontalText(
            id: "\(via.id)/net-label",
            text: netName,
            position: frame.center,
            size: size,
            layer: nil,
            angle: frame.angle,
            origin: .center,
            centered: true
        )
    }

    private func drawConnectionSegment(
        _ connectionLine: HorizontalSegment,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        labels: Bool
    ) {
        var path = Path()
        path.move(to: transform.point(connectionLine.from))
        path.addLine(to: transform.point(connectionLine.to))
        context.stroke(
            path,
            with: .color(color.opacity(0.72)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(0, minimum: 0.9),
                lineCap: .round,
                lineJoin: .round,
                dash: [6, 4]
            )
        )
        if labels {
            drawConnectionLabel(connectionLine, context: context, transform: transform)
        }
    }

    private func drawConnectionLabel(
        _ connectionLine: HorizontalSegment,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        drawSegmentLengthLabel(
            connectionLine,
            color: theme.connectionLine.opacity(0.86),
            idSuffix: "connection-length-label",
            context: context,
            transform: transform
        )
    }

    private func drawSegmentLengthLabel(
        _ segment: HorizontalSegment,
        color: Color,
        idSuffix: String,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        drawSegmentLabel(segmentLengthLabelText(segment, idSuffix: idSuffix), color: color, context: context, transform: transform)
    }

    private func drawSegmentNetLabel(
        _ segment: HorizontalSegment,
        color: Color,
        idSuffix: String,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        guard let label = namedNetDisplayName(segment.netID) else {
            return
        }

        guard transform.length(segment.length) >= 44,
              transform.length(segment.width) >= HorizontalOutlineTextRenderer.minimumDrawableScreenHeight else {
            return
        }

        guard let size = fittedNetLineTextSize(label, segment: segment, transform: transform) else {
            return
        }
        drawSegmentLabel(segmentLabelText(segment, text: label, idSuffix: idSuffix, size: size), color: color, context: context, transform: transform)
    }

    private func fittedNetLineTextSize(
        _ text: String,
        segment: HorizontalSegment,
        transform: HorizontalCanvasTransform
    ) -> Double? {
        guard transform.length(segment.length) >= 44,
              transform.length(segment.width) >= HorizontalOutlineTextRenderer.minimumDrawableScreenHeight else {
            return nil
        }

        guard let size = fittedNetLineTextSize(text, segment: segment),
              transform.length(size) >= HorizontalOutlineTextRenderer.minimumDrawableScreenHeight else {
            return nil
        }
        return size
    }

    private func fittedNetLineTextSize(
        _ text: String,
        segment: HorizontalSegment
    ) -> Double? {
        guard segment.width > 0, segment.length > 0 else {
            return nil
        }

        var boxWidth = segment.length
        var boxHeight = segment.width
        if boxHeight > boxWidth {
            swap(&boxWidth, &boxHeight)
        }

        let textSize = HorizontalOutlineTextRenderer.textSize(text, font: .simplex, size: 1_000_000)
        guard textSize.width > 0, textSize.height > 0 else {
            return nil
        }

        // Text-length-aware "too short" gate (width-INDEPENDENT): if the net name,
        // laid ALONG the track, would have to shrink below a legible font size just
        // to fit the track's LENGTH, skip the label. Longer names need longer
        // tracks; the track's WIDTH deliberately isn't a factor — a fat short track
        // shouldn't be forced to a huge length just because it's wide, and a thin
        // long track keeps its label. `sizeIfLengthLimited` is what the fitted font
        // size would be if the length (not the width) were the binding constraint.
        // (Tunable: lower the floor to keep labels on shorter tracks.)
        let sizeIfLengthLimited = segment.length * 1_000_000 / (textSize.width * 1.5)
        guard sizeIfLengthLimited >= 200_000 else {
            return nil
        }

        let scaleX = textSize.width / boxWidth
        let scaleY = textSize.height / boxHeight
        let scaleFactor = max(scaleX, scaleY) * 1.5
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            return nil
        }

        let size = 1_000_000 / scaleFactor
        return size.isFinite ? size : nil
    }

    private func drawSegmentLabel(
        _ label: HorizontalText,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        HorizontalOutlineTextRenderer.draw(
            label,
            color: color,
            context: context,
            transform: transform,
            minimumLineWidth: 0.75
        )
    }

    private func segmentLengthLabelText(_ segment: HorizontalSegment, idSuffix: String) -> HorizontalText {
        segmentLabelText(segment, text: lengthString(segment.length), idSuffix: idSuffix, size: 900_000)
    }

    private func segmentNetLabelText(_ segment: HorizontalSegment, idSuffix: String, padCenterKeys: Set<String>? = nil) -> HorizontalText? {
        guard let label = namedNetDisplayName(segment.netID),
              let size = fittedNetLineTextSize(label, segment: segment) else {
            return nil
        }
        // A track that ends on a pad is already labeled by that pad's net name,
        // so skip the redundant track label.
        if segmentTouchesPad(segment, padCenterKeys: padCenterKeys) {
            return nil
        }
        return segmentLabelText(segment, text: label, idSuffix: idSuffix, size: size)
    }

    /// Whether either endpoint of `segment` lands on a pad center. Pass a
    /// precomputed key set (from `board.packagePadPositions`) on hot paths so the
    /// check is O(1); falls back to the O(pads) `isPadCenter` scan when nil, which
    /// is fine for the low-volume selection/highlight paths.
    private func segmentTouchesPad(_ segment: HorizontalSegment, padCenterKeys: Set<String>?) -> Bool {
        if let padCenterKeys {
            return padCenterKeys.contains(pointKey(segment.from))
                || padCenterKeys.contains(pointKey(segment.to))
        }
        return isPadCenter(segment.from, in: board) || isPadCenter(segment.to, in: board)
    }

    private func segmentLabelText(
        _ segment: HorizontalSegment,
        text: String,
        idSuffix: String,
        size: Double
    ) -> HorizontalText {
        let midpoint = HorizontalPoint(
            x: (segment.from.x + segment.to.x) / 2,
            y: (segment.from.y + segment.to.y) / 2
        )
        return HorizontalText(
            id: "\(segment.id)/\(idSuffix)",
            text: text,
            position: midpoint,
            size: size,
            layer: nil,
            angle: angle(from: segment.from, to: segment.to),
            origin: .center,
            centered: true
        )
    }

    private func packageFallbackLabelText(_ package: HorizontalPlacement) -> HorizontalText {
        HorizontalText(
            id: "\(package.id)/fallback-label",
            text: package.label,
            position: package.position + HorizontalPoint(x: 1_100_000, y: -1_100_000),
            size: 1_250_000,
            layer: nil,
            origin: .baseline
        )
    }

    private func drawPackageArtwork(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for polygon in board.packagePolygons where polygon.layer == layer {
            let path = closedPath(for: polygon.renderVertices(arcPrecision: 24), transform: transform)
            context.fill(path, with: .color(layerColor(for: layer).opacity(0.12)))
            context.stroke(path, with: .color(layerColor(for: layer).opacity(0.7)), lineWidth: transform.strokeWidth(0, minimum: 1))
        }

        for line in board.packageLines where line.layer == layer {
            drawSegment(line, transform: transform, context: context, fallbackColor: layerColor(for: layer).opacity(0.7))
        }

        for arc in board.packageArcs where arc.layer == layer {
            drawArc(arc, transform: transform, context: context, color: layerColor(for: layer).opacity(0.7), minimumWidth: 1)
        }
    }

    private func drawPackagePads(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for pad in horizonPadOutlineFragments(board.packagePads).filter({ $0.layer == layer }) {
            for vertices in pad.paths {
                let path = closedPath(for: vertices, transform: transform)
                context.fill(path, with: .color(layerColor(for: layer).opacity(0.82)))
            }
        }
    }

    private func drawPackagePadLabels(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard HorizontalBoardLayers.isCopper(layer) else {
            return
        }

        var groups = [String: PadLabelGroup]()
        var order = [String]()
        for pad in board.packagePads where pad.layer == layer {
            let groupID = padLabelGroupID(for: pad.id)
            if var group = groups[groupID] {
                group.vertices.append(contentsOf: pad.vertices)
                if group.netID == nil {
                    group.netID = pad.netID
                }
                for (key, value) in pad.metadata where group.metadata[key] == nil {
                    group.metadata[key] = value
                }
                group.labelFrame = mergedPadLabelFrame(group.labelFrame, pad.padLabelFrame)
                groups[groupID] = group
            } else {
                groups[groupID] = PadLabelGroup(
                    id: groupID,
                    vertices: pad.vertices,
                    netID: pad.netID,
                    metadata: pad.metadata,
                    labelFrame: pad.padLabelFrame
                )
                order.append(groupID)
            }
        }

        for groupID in order {
            guard let group = groups[groupID] else {
                continue
            }
            drawPadLabel(group, context: context, transform: transform)
        }
    }

    private func packagePadLabelTexts(on layer: Int) -> [HorizontalText] {
        packagePadLabelTexts(on: layer, board: board)
    }

    private func packagePadLabelTexts(on layer: Int, board: HorizontalBoard) -> [HorizontalText] {
        guard HorizontalBoardLayers.isCopper(layer) else {
            return []
        }

        var groups = [String: PadLabelGroup]()
        var order = [String]()
        for pad in board.packagePads where pad.layer == layer {
            let groupID = padLabelGroupID(for: pad.id)
            if var group = groups[groupID] {
                group.vertices.append(contentsOf: pad.vertices)
                if group.netID == nil {
                    group.netID = pad.netID
                }
                for (key, value) in pad.metadata where group.metadata[key] == nil {
                    group.metadata[key] = value
                }
                group.labelFrame = mergedPadLabelFrame(group.labelFrame, pad.padLabelFrame)
                groups[groupID] = group
            } else {
                groups[groupID] = PadLabelGroup(
                    id: groupID,
                    vertices: pad.vertices,
                    netID: pad.netID,
                    metadata: pad.metadata,
                    labelFrame: pad.padLabelFrame
                )
                order.append(groupID)
            }
        }

        return order.compactMap { groups[$0] }.flatMap(padLabelTexts(for:))
    }

    private func packagePadLabelTextsByLayer(board: HorizontalBoard) -> [Int: [HorizontalText]] {
        var groupsByLayer = [Int: [String: PadLabelGroup]]()
        var orderByLayer = [Int: [String]]()
        var result = [Int: [HorizontalText]]()

        BoardLoadTimer.measure("pad labels: group pads") {
            for pad in board.packagePads {
                guard let layer = pad.layer,
                      HorizontalBoardLayers.isCopper(layer) else {
                    continue
                }

                let groupID = padLabelGroupID(for: pad.id)
                var groups = groupsByLayer[layer] ?? [:]
                if var group = groups[groupID] {
                    group.vertices.append(contentsOf: pad.polygonVertices.map(\.position))
                    if group.netID == nil {
                        group.netID = pad.netID
                    }
                    for (key, value) in pad.metadata where group.metadata[key] == nil {
                        group.metadata[key] = value
                    }
                    group.labelFrame = mergedPadLabelFrame(group.labelFrame, pad.padLabelFrame)
                    groups[groupID] = group
                } else {
                    groups[groupID] = PadLabelGroup(
                        id: groupID,
                        vertices: pad.polygonVertices.map(\.position),
                        netID: pad.netID,
                        metadata: pad.metadata,
                        labelFrame: pad.padLabelFrame
                    )
                    orderByLayer[layer, default: []].append(groupID)
                }
                groupsByLayer[layer] = groups
            }
        }

        result.reserveCapacity(groupsByLayer.count)
        var textCache = [String: [HorizontalText]]()
        BoardLoadTimer.measure("pad labels: build texts") {
            for (layer, order) in orderByLayer {
                let groups = groupsByLayer[layer] ?? [:]
                result[layer] = order.compactMap { groups[$0] }.flatMap { group in
                    if let cached = textCache[group.id] {
                        return cached
                    }
                    let texts = padLabelTexts(for: group)
                    textCache[group.id] = texts
                    return texts
                }
            }
        }
        return result
    }

    private func drawPadLabel(
        _ pad: PadLabelGroup,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        guard let frame = padLabelFrame(for: pad),
              min(transform.length(frame.width), transform.length(frame.height)) >= 12 else {
            return
        }

        let textColor = theme.textOverlay.opacity(0.86)

        for text in padLabelTexts(for: pad, frame: frame) where isGeneratedLabelLegible(text) {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: textColor,
                context: context,
                transform: transform,
                minimumLineWidth: 0.7
            )
        }
    }

    private func padLabelTexts(for pad: PadLabelGroup) -> [HorizontalText] {
        guard let frame = padLabelFrame(for: pad) else {
            return []
        }
        return padLabelTexts(for: pad, frame: frame)
    }

    private func padLabelTexts(for pad: PadLabelGroup, frame: PadLabelFrame) -> [HorizontalText] {
        let padText = padLabel(for: pad.id, metadata: pad.metadata)
        let netText = namedNetDisplayName(pad.netID)

        if let netText {
            let primarySize = BoardPadLabelLayout.fittedTextSize(padText, frame: frame, mode: .upper)
            let secondarySize = BoardPadLabelLayout.fittedTextSize(netText, frame: frame, mode: .lower)
            // Horizon puts the two rows at ±height/4 of the (already
            // readability-flipped) box; `frame.normal` carries the flip, so the
            // pad name always lands on the text's upper half.
            let rowOffset = frame.height * BoardPadLabelLayout.rowOffsetFraction
            return [
                padTextLabel(
                    padText,
                    id: "\(pad.id)/pad-label",
                    position: frame.center + frame.normal * rowOffset,
                    size: primarySize,
                    angle: frame.angle
                ),
                padTextLabel(
                    netText,
                    id: "\(pad.id)/pad-net-label",
                    position: frame.center - frame.normal * rowOffset,
                    size: secondarySize,
                    angle: frame.angle
                )
            ]
        } else {
            let size = BoardPadLabelLayout.fittedTextSize(padText, frame: frame, mode: .full)
            return [
                padTextLabel(
                    padText,
                    id: "\(pad.id)/pad-label",
                    position: frame.center,
                    size: size,
                    angle: frame.angle
                )
            ]
        }
    }

    private func padLabelFrame(for pad: PadLabelGroup) -> PadLabelFrame? {
        // Prefer the intrinsic descriptor when the parser captured one — this
        // bypasses the polygon-edge scoring heuristic, which picks essentially
        // arbitrary angles for roundrect (dozens of corner chords each clear
        // the minimum-edge-length filter) and for circles (every chord is the
        // same length at a different angle). Matches what the reference implementation's
        // `canvas_gl.cpp::draw_bitmap_text_box` does.
        if let descriptor = pad.labelFrame,
           let frame = BoardPadLabelLayout.frame(fromDescriptor: descriptor) {
            return frame
        }
        return BoardPadLabelLayout.frame(
            forVertices: pad.vertices,
            padText: padLabel(for: pad.id, metadata: pad.metadata),
            netText: namedNetDisplayName(pad.netID)
        )
    }

    /// Merge rule for combining `PadLabelFrameDescriptor`s contributed by
    /// multiple polygons in the same pad-label group: prefer non-nil; if both
    /// non-nil take the one with larger intrinsic area (so the copper pad
    /// frame wins over a smaller mask/paste aperture).
    private func mergedPadLabelFrame(
        _ existing: PadLabelFrameDescriptor?,
        _ candidate: PadLabelFrameDescriptor?
    ) -> PadLabelFrameDescriptor? {
        switch (existing, candidate) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return a.area >= b.area ? a : b
        }
    }

    private func drawPadText(
        _ text: String,
        id: String,
        position: HorizontalPoint,
        size: Double,
        angle: Int,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        HorizontalOutlineTextRenderer.draw(
            padTextLabel(text, id: id, position: position, size: size, angle: angle),
            color: color,
            context: context,
            transform: transform,
            minimumLineWidth: 0.7
        )
    }

    private func padTextLabel(
        _ text: String,
        id: String,
        position: HorizontalPoint,
        size: Double,
        angle: Int
    ) -> HorizontalText {
        HorizontalText(
            id: id,
            text: text,
            position: position,
            size: size,
            layer: nil,
            angle: angle,
            // Stroke weight has to scale with the glyphs: `HorizontalOutlineTextRenderer`
            // strokes with `transform.strokeWidth(text.width, minimum:)`, so leaving
            // `width` at its 0 default collapsed every pad label to the 0.7pt floor —
            // a hairline at any zoom. The simplex font uses `scale = size / 21`, so
            // size/8 is ≈2.6 glyph units: heavy enough to read like bitmap
            // pad text. `drawPadLabel` still passes `minimumLineWidth: 0.7` so labels
            // stay visible when zoomed out.
            width: size / 8,
            origin: .center,
            centered: true
        )
    }

    private func padLabel(for pad: HorizontalPolygon) -> String {
        padLabel(for: pad.id, metadata: pad.metadata)
    }

    private func padLabel(for id: String, metadata: [String: String]) -> String {
        if let padName = nonEmpty(metadata["Pad"]) {
            return padName
        }
        let components = id.split(separator: "/").map(String.init)
        return components.last ?? id
    }

    private func padLabelGroupID(for id: String) -> String {
        let components = normalizedID(id).split(separator: "/").map(String.init)
        if let shapeIndex = components.firstIndex(of: "shape") {
            return components[..<shapeIndex].joined(separator: "/")
        }
        return normalizedID(id)
    }

    private func drawText(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for text in board.texts where displayOptions.isLayerVisible(text.layer) {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: color(for: text.layer).opacity(0.82),
                context: context,
                transform: transform
            )
        }

        for text in board.packageTexts where displayOptions.isLayerVisible(text.layer) {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: color(for: text.layer).opacity(0.86),
                context: context,
                transform: transform
            )
        }
    }

    private func drawText(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for text in board.texts where text.layer == layer {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: layerColor(for: layer).opacity(0.82),
                context: context,
                transform: transform
            )
        }

        for text in board.packageTexts where text.layer == layer {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: layerColor(for: layer).opacity(0.86),
                context: context,
                transform: transform
            )
        }
    }

    private func drawNetHighlight(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard !highlightedNetIDs.isEmpty else {
            return
        }

        let color = theme.junction

        for plane in board.planes where displayOptions.isLayerVisible(plane.layer) && matchesHighlightedNet(plane.netID) {
            drawHighlightedPlane(plane, color: color, context: context, transform: transform)
        }

        for polygon in board.polygons where displayOptions.isLayerVisible(polygon.layer) && !isBoardBodyLayer(polygon.layer) && matchesHighlightedNet(polygon.netID) {
            drawHighlightedPolygon(polygon, color: color, context: context, transform: transform)
        }

        for line in board.lines where displayOptions.isLayerVisible(line.layer) && matchesHighlightedNet(line.netID) {
            drawHighlightedSegment(line, color: color, context: context, transform: transform)
        }

        for arc in board.arcs where displayOptions.isLayerVisible(arc.layer) && matchesHighlightedNet(arc.netID) {
            drawHighlightedArc(arc, color: color, context: context, transform: transform)
        }

        for track in board.tracks where displayOptions.isLayerVisible(track.layer) && matchesHighlightedNet(track.netID) {
            drawHighlightedBoardTrack(track, color: color, context: context, transform: transform)
        }

        for netTie in board.netTies where displayOptions.isLayerVisible(netTie.layer) && matchesHighlightedNet(netTie.netID) {
            drawHighlightedSegment(netTie, color: color, context: context, transform: transform)
        }

        if displayOptions.connectionLines {
            for connectionLine in board.connectionLines where matchesHighlightedNet(connectionLine.netID) {
                drawHighlightedSegment(connectionLine, color: color, context: context, transform: transform, dashed: true)
            }
            for airwire in board.airwires where matchesHighlightedNet(airwire.netID) {
                drawHighlightedSegment(airwire, color: color, context: context, transform: transform, dashed: true)
            }
        }

        if displayOptions.pads {
            let pads = board.packagePads.filter {
                displayOptions.isLayerVisible($0.layer) && matchesHighlightedNet($0.netID)
            }
            for pad in horizonPadOutlineFragments(pads) {
                drawHighlightedPadFragment(pad, color: color, context: context, transform: transform)
            }

            if displayOptions.holes {
                for hole in board.packageHoles where matchesHighlightedNet(hole.netID) {
                    drawHighlightedHole(hole, color: color, context: context, transform: transform)
                }
            }
        }

        if displayOptions.vias {
            for via in board.vias where matchesHighlightedNet(via.netID) {
                drawHighlightedMarker(via, color: color, context: context, transform: transform)
            }

            if displayOptions.holes {
                for hole in board.viaHoles where matchesHighlightedNet(hole.netID) {
                    drawHighlightedHole(hole, color: color, context: context, transform: transform)
                }
            }
        }

        if displayOptions.holes {
            for hole in board.holes where matchesHighlightedNet(hole.netID) {
                drawHighlightedHole(hole, color: color, context: context, transform: transform)
            }
        }

        if displayOptions.text {
            for text in (board.texts + board.packageTexts) where displayOptions.isLayerVisible(text.layer) && matchesHighlightedNet(text.netID) {
                drawHighlightedText(text, color: color, context: context, transform: transform)
            }
        }
    }

    private func drawComponentHighlight(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard !highlightedComponentIDs.isEmpty,
              displayOptions.packages else {
            return
        }

        let color = theme.junction
        for selectable in boardPackageSelectables() {
            guard let package = board.packages.first(where: { normalizedID($0.id) == normalizedID(selectable.ref.id) }),
                  matchesHighlightedComponent(package.componentID) else {
                continue
            }
            let path = selectablePath(selectable, transform: transform)
            context.fill(path, with: .color(color.opacity(0.16)))
            context.stroke(
                path,
                with: .color(color.opacity(0.95)),
                style: StrokeStyle(lineWidth: 2.0, lineJoin: .round)
            )
        }
    }

    private func drawComplexPlaneNetHighlight(context _: GraphicsContext, transform _: HorizontalCanvasTransform) {
    }

    private func dimDesignForNetHighlight(context: GraphicsContext, size: CGSize) {
        let opacity = displayOptions.highlightMode == "hide_other" ? 0.92 : 0.54
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(theme.background.opacity(opacity))
        )
    }

    private func matchesHighlightedNet(_ netID: String?) -> Bool {
        guard let netID else {
            return false
        }
        return highlightedNetIDs.contains(normalizedID(netID))
    }

    private func matchesHighlightedComponent(_ componentID: String?) -> Bool {
        guard let componentID else {
            return false
        }
        return highlightedComponentIDs.contains(normalizedID(componentID))
    }

    private func drawHighlightedSegment(
        _ segment: HorizontalSegment,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        dashed: Bool = false
    ) {
        var path = Path()
        path.move(to: transform.point(segment.from))
        path.addLine(to: transform.point(segment.to))
        context.stroke(
            path,
            with: .color(color.opacity(0.94)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(segment.width, minimum: 3.2),
                lineCap: .round,
                lineJoin: .round,
                dash: dashed ? [7, 4] : []
            )
        )
        context.stroke(
            path,
            with: .color(theme.background.opacity(0.55)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(segment.width, minimum: 1.0),
                lineCap: .round,
                lineJoin: .round,
                dash: dashed ? [7, 4] : []
            )
        )
    }

    private func drawHighlightedArc(
        _ arc: HorizontalArc,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        var path = Path()
        let points = arc.polyline(precision: 48)
        guard let first = points.first else {
            return
        }

        path.move(to: transform.point(first))
        for point in points.dropFirst() {
            path.addLine(to: transform.point(point))
        }
        context.stroke(
            path,
            with: .color(color.opacity(0.94)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(arc.width, minimum: 3.2),
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.stroke(
            path,
            with: .color(theme.background.opacity(0.55)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(arc.width, minimum: 1.0),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func drawHighlightedPolygon(
        _ polygon: HorizontalPolygon,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let path = closedPath(for: polygon.renderVertices(arcPrecision: 24), transform: transform)
        context.fill(path, with: .color(color.opacity(0.28)))
        context.stroke(
            path,
            with: .color(color.opacity(0.96)),
            style: StrokeStyle(lineWidth: transform.strokeWidth(0, minimum: 2.2), lineJoin: .round)
        )
    }

    private func drawHighlightedPadFragment(
        _ pad: HorizontalPadOutlineFragment,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let path = compoundPath(for: pad.paths, transform: transform)
        context.fill(path, with: .color(color.opacity(0.28)), style: FillStyle(eoFill: true, antialiased: true))
        context.stroke(
            path,
            with: .color(color.opacity(0.96)),
            style: StrokeStyle(lineWidth: transform.strokeWidth(0, minimum: 2.2), lineJoin: .round)
        )
    }

    private func drawHighlightedPlane(
        _ plane: HorizontalPlane,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for fragment in plane.renderFragments {
            let path = compoundPath(for: fragment.paths, transform: transform)
            context.fill(path, with: .color(color.opacity(0.18)), style: FillStyle(eoFill: true, antialiased: true))
            context.stroke(path, with: .color(color.opacity(0.78)), lineWidth: transform.strokeWidth(0, minimum: 1.5))
        }
    }

    private func drawHighlightedMarker(
        _ marker: HorizontalMarker,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let point = transform.point(marker.position)
        let radius = max(transform.length(marker.size) / 2, 2.2) + 2.0
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        context.fill(path, with: .color(color.opacity(0.28)))
        context.stroke(path, with: .color(color.opacity(0.98)), lineWidth: transform.strokeWidth(0, minimum: 2.0))
    }

    private func drawHighlightedHole(
        _ hole: HorizontalHole,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let path = holePath(hole, transform: transform, minimumRadius: 1.8, outset: 2.0)
        context.stroke(path, with: .color(color.opacity(0.95)), lineWidth: transform.strokeWidth(0, minimum: 1.8))
    }

    private func drawHighlightedText(
        _ text: HorizontalText,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        HorizontalOutlineTextRenderer.draw(
            text,
            color: color.opacity(0.96),
            context: context,
            transform: transform,
            minimumLineWidth: 1.1
        )
    }

    private func drawBoardLines(on layer: Int, context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for line in board.lines where line.layer == layer {
            drawSegment(line, transform: transform, context: context, fallbackColor: layerColor(for: layer).opacity(0.8))
        }

        for arc in board.arcs where arc.layer == layer {
            drawArc(arc, transform: transform, context: context, color: layerColor(for: layer).opacity(0.8), minimumWidth: 1)
        }

        for track in board.tracks where track.layer == layer {
            drawBoardTrack(track, transform: transform, context: context, fallbackColor: layerColor(for: layer))
            if displayOptions.trackLabels, track.center == nil {
                drawSegmentNetLabel(
                    track,
                    color: theme.textOverlay.opacity(0.88),
                    idSuffix: "track-net-label",
                    context: context,
                    transform: transform
                )
            }
        }

        for netTie in board.netTies where netTie.layer == layer {
            drawSegment(netTie, transform: transform, context: context, fallbackColor: layerColor(for: layer))
            if displayOptions.trackLabels {
                drawSegmentNetLabel(
                    netTie,
                    color: theme.textOverlay.opacity(0.88),
                    idSuffix: "net-tie-net-label",
                    context: context,
                    transform: transform
                )
            }
        }
    }

    private func drawBoardLineLabels(
        renderLayers: [Int],
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        for layer in renderLayers {
            context.drawLayer { layerContext in
                layerContext.opacity = layerOpacity
                for track in board.tracks where track.layer == layer && track.center == nil {
                    drawSegmentNetLabel(
                        track,
                        color: theme.textOverlay.opacity(0.88),
                        idSuffix: "track-net-label",
                        context: layerContext,
                        transform: transform
                    )
                }

                for netTie in board.netTies where netTie.layer == layer {
                    drawSegmentNetLabel(
                        netTie,
                        color: theme.textOverlay.opacity(0.88),
                        idSuffix: "net-tie-net-label",
                        context: layerContext,
                        transform: transform
                    )
                }
            }
        }
    }

    private func drawSegment(
        _ segment: HorizontalSegment,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        fallbackColor: Color
    ) {
        var path = Path()
        path.move(to: transform.point(segment.from))
        path.addLine(to: transform.point(segment.to))
        context.stroke(
            path,
            with: .color(fallbackColor.opacity(0.82)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(segment.width, minimum: 1.1),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func drawBoardTrack(
        _ track: HorizontalSegment,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        fallbackColor: Color
    ) {
        if let arc = track.arc {
            drawArc(arc, transform: transform, context: context, color: fallbackColor.opacity(0.82), minimumWidth: 1.1)
        } else {
            drawSegment(track, transform: transform, context: context, fallbackColor: fallbackColor)
        }
    }

    private func drawHighlightedBoardTrack(
        _ track: HorizontalSegment,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        if let arc = track.arc {
            drawHighlightedArc(arc, color: color, context: context, transform: transform)
        } else {
            drawHighlightedSegment(track, color: color, context: context, transform: transform)
        }
    }

    private func drawArc(
        _ arc: HorizontalArc,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color,
        minimumWidth: CGFloat
    ) {
        var path = Path()
        let points = arc.polyline(precision: 48)
        guard let first = points.first else {
            return
        }

        path.move(to: transform.point(first))
        for point in points.dropFirst() {
            path.addLine(to: transform.point(point))
        }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(arc.width, minimum: minimumWidth),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func drawGraphicsPreview(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard let state = drawGraphicsState else {
            return
        }

        var points = state.points
        if let cursor = state.cursor,
           points.isEmpty || pointKey(points.last ?? cursor) != pointKey(cursor) {
            points.append(cursor)
        }

        let result = previewGraphicsResult(
            for: state.primitive,
            points: points,
            layer: state.layer,
            rectanglePlacementMode: state.rectanglePlacementMode
        )
        for segment in result.lines {
            drawPreviewSegment(segment, context: context, transform: transform)
        }
        for arc in result.arcs {
            drawPreviewArc(arc, context: context, transform: transform)
        }
        for polygon in result.polygons {
            for segment in closedBoardDrawingSegments(points: polygon.renderVertices(arcPrecision: 24), layer: polygon.layer ?? state.layer) {
                drawPreviewSegment(segment, context: context, transform: transform)
            }
        }

        if state.primitive == .arc, let center = state.points.first, let cursor = state.cursor {
            drawPreviewSegment(
                HorizontalSegment(id: "arc-radius-preview", from: center, to: cursor, width: 0, layer: nil),
                context: context,
                transform: transform,
                opacity: 0.35
            )
        }
    }

    private func previewGraphicsResult(
        for primitive: HorizontalDrawingPrimitive,
        points: [HorizontalPoint],
        layer: Int,
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner
    ) -> DrawGraphicsResult {
        HorizontalCanvasModeSupport.previewGraphicsResult(
            for: primitive,
            points: points,
            rectanglePlacementMode: rectanglePlacementMode,
            pointKey: pointKey,
            makeSegment: { boardDrawingSegment(from: $0, to: $1, layer: layer) },
            makeArc: { boardDrawingArc(from: $0, to: $1, center: $2, layer: layer) },
            finalizedResult: { graphicsResult(for: $0, points: $1, layer: layer, rectanglePlacementMode: $2) }
        )
    }

    private func drawPreviewSegment(
        _ segment: HorizontalSegment,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        opacity: Double = 0.82
    ) {
        var path = Path()
        path.move(to: transform.point(segment.from))
        path.addLine(to: transform.point(segment.to))
        context.stroke(
            path,
            with: .color(theme.textOverlay.opacity(opacity)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(0, minimum: 1.6),
                lineCap: .round,
                lineJoin: .round,
                dash: [5, 4]
            )
        )
    }

    private func drawPreviewArc(
        _ arc: HorizontalArc,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        opacity: Double = 0.82
    ) {
        drawArc(arc, transform: transform, context: context, color: theme.textOverlay.opacity(opacity), minimumWidth: 1.6)
    }

    private func drawWorldLine(
        from: HorizontalPoint,
        to: HorizontalPoint,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        color: Color,
        width: CGFloat
    ) {
        var path = Path()
        path.move(to: transform.point(from))
        path.addLine(to: transform.point(to))
        context.stroke(path, with: .color(color), lineWidth: transform.strokeWidth(0, minimum: width))
    }

    private func drawArrowhead(
        at origin: HorizontalPoint,
        angle: Double,
        direction: Double,
        size: Double,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        color: Color
    ) {
        let first = origin + rotate(HorizontalPoint(x: direction * size, y: size / 2), angle: angle)
        let second = origin + rotate(HorizontalPoint(x: direction * size, y: -size / 2), angle: angle)
        drawWorldLine(from: origin, to: first, context: context, transform: transform, color: color, width: 0.8)
        drawWorldLine(from: origin, to: second, context: context, transform: transform, color: color, width: 0.8)
    }

    private func rotate(_ point: HorizontalPoint, angle: Double) -> HorizontalPoint {
        HorizontalPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }

    private func closedPath(for vertices: [HorizontalPoint], transform: HorizontalCanvasTransform) -> Path {
        var path = Path()
        guard let first = vertices.first else {
            return path
        }

        path.move(to: transform.point(first))
        for vertex in vertices.dropFirst() {
            path.addLine(to: transform.point(vertex))
        }
        path.closeSubpath()
        return path
    }

    private func panelBoundsPath(_ bounds: HorizontalRect, transform: HorizontalCanvasTransform) -> Path {
        var path = Path()
        path.move(to: transform.point(HorizontalPoint(x: bounds.minX, y: bounds.minY)))
        path.addLine(to: transform.point(HorizontalPoint(x: bounds.maxX, y: bounds.minY)))
        path.addLine(to: transform.point(HorizontalPoint(x: bounds.maxX, y: bounds.maxY)))
        path.addLine(to: transform.point(HorizontalPoint(x: bounds.minX, y: bounds.maxY)))
        path.closeSubpath()
        return path
    }

    private func compoundPath(for paths: [[HorizontalPoint]], transform: HorizontalCanvasTransform) -> Path {
        var path = Path()

        for points in paths {
            guard let first = points.first else {
                continue
            }

            path.move(to: transform.point(first))
            for point in points.dropFirst() {
                path.addLine(to: transform.point(point))
            }
            path.closeSubpath()
        }

        return path
    }

    private func drawSelection(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for selectable in boardSelectables() {
            let isSelected = selectedObjects.contains(selectable.ref)
            let isHovered = selectable.ref == hoveredObject
            guard isSelected || isHovered else {
                continue
            }

            drawSelectable(
                selectable,
                selected: isSelected,
                context: context,
                transform: transform
            )
        }
    }

    private func drawSelectionHandles(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for selectable in boardSelectables() where selectedObjects.contains(selectable.ref) {
            for point in HorizontalCanvasModeSupport.selectionHandlePoints(for: selectable) {
                drawSelectionHandle(
                    at: point,
                    color: theme.selectableOuter,
                    context: context,
                    transform: transform
                )
            }
        }
    }

    private func drawSelectable(
        _ selectable: HorizontalSelectable,
        selected: Bool,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let path = selectablePath(
            selectable,
            transform: transform,
            screenMargin: CGFloat(HorizontalSelectable.selectionOutlineScreenMargin)
        )
        let outerColor = selected ? theme.selectableOuter : theme.selectablePrelight
        context.stroke(
            path,
            with: .color(outerColor.opacity(selected ? 0.95 : 0.78)),
            style: StrokeStyle(lineWidth: selected ? 2.4 : 1.8, lineJoin: .round, dash: [5, 4])
        )

        if selected {
            for point in HorizontalCanvasModeSupport.selectionHandlePoints(for: selectable) {
                drawSelectionHandle(
                    at: point,
                    color: outerColor,
                    context: context,
                    transform: transform
                )
            }
        }
    }

    private func drawSelectionHandle(
        at point: HorizontalPoint,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let handleShape = appearanceSettings.canvasSelectionHandleShape
        HorizontalCanvasModeSupport.drawSelectionHandle(
            at: point,
            outerColor: color.opacity(0.95),
            innerColor: theme.selectableInner.opacity(0.82),
            context: context,
            transform: transform,
            shape: handleShape
        )
    }

    private func selectablePath(
        _ selectable: HorizontalSelectable,
        transform: HorizontalCanvasTransform,
        screenMargin: CGFloat = 0
    ) -> Path {
        HorizontalCanvasModeSupport.selectablePath(
            for: selectable,
            transform: transform,
            screenMargin: screenMargin
        )
    }

    private func boardPackageSelectables() -> [HorizontalSelectable] {
        boardPackageSelectables(in: board)
    }

    private func boardPackageSelectables(in board: HorizontalBoard) -> [HorizontalSelectable] {
        let pointsByPackage = boardPackageGeometryPoints(in: board)
        return board.packages.map { package in
            let packagePoints = pointsByPackage[normalizedID(package.id)] ?? []
            // The package's selectable ref must NOT encode the side (top/bottom):
            // every other `.boardPackage` ref in the codebase uses `layer: nil`
            // (selection membership, the move planner, the metal owner), and the
            // selection overlay resolves the box by exact-ref lookup. Encoding
            // `mirrored` here made the ref flip top↔bottom when a package was
            // flipped, so the stored selection ref no longer matched the rebuilt
            // selectable and the on-canvas box vanished (apparent deselection).
            // Keep it side-independent so flipping (and any other property edit)
            // preserves the selection. The box color comes from the theme, not the
            // layer, so nothing visual depends on it.
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: package.id, type: .boardPackage),
                points: packagePoints,
                fallbackCenter: package.position,
                fallbackSize: 2_000_000
            )
        }
    }

    private func boardPackageGeometryPoints() -> [String: [HorizontalPoint]] {
        boardPackageGeometryPoints(in: board)
    }

    private func boardPackageGeometryPoints(in board: HorizontalBoard) -> [String: [HorizontalPoint]] {
        var pointsByPackage = [String: [HorizontalPoint]]()

        func append(id: String, points: [HorizontalPoint]) {
            guard let packageID = packageID(forGeometryID: id) else {
                return
            }
            pointsByPackage[packageID, default: []].append(contentsOf: points)
        }

        for pad in board.packagePads {
            append(id: pad.id, points: pad.vertices)
        }
        for polygon in board.packagePolygons where isBoardPackageBBoxPolygonLayer(polygon.layer) {
            append(id: polygon.id, points: polygon.renderVertices(arcPrecision: 24))
        }

        return pointsByPackage
    }

    private func isBoardPackageBBoxPolygonLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return layer == HorizontalBoardLayers.topPackage
            || layer == HorizontalBoardLayers.bottomPackage
            || layer == HorizontalBoardLayers.outline
    }

    private func packageID(forGeometryID geometryID: String) -> String? {
        objectIDPrefix(
            in: geometryID,
            separators: ["arc", "hole", "line", "pad", "polygon", "text"]
        )
    }

    private func color(for layer: Int?) -> Color {
        layerColor(for: layer).opacity(layerOpacity)
    }

    private var layerOpacity: Double {
        min(max(displayOptions.layerOpacity, 0), 1)
    }

    private func layerColor(for layer: Int?) -> Color {
        if let layer,
           let userLayer = board.userLayers.first(where: { $0.id == layer }) {
            return theme.layerColor(for: userLayer.colorLayer)
        }
        return theme.layerColor(for: layer)
    }

    private func layerName(for layer: Int?) -> String? {
        guard let layer else {
            return nil
        }
        if let userLayer = board.userLayers.first(where: { $0.id == layer }),
           let name = nonEmpty(userLayer.name) {
            return name
        }
        return HorizontalBoardLayers.name(for: layer)
    }

    private func netDisplayName(_ netID: String?) -> String? {
        guard let netID else {
            return nil
        }
        return board.netDetails[normalizedID(netID)]?.name ?? shortID(netID)
    }

    private func namedNetDisplayName(_ netID: String?) -> String? {
        guard let netID else {
            return nil
        }
        return nonEmpty(board.netDetails[normalizedID(netID)]?.name)
    }

    private func padColor(for layer: Int?) -> Color {
        layerColor(for: layer)
    }

    private func isBoardBodyLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return HorizontalBoardLayers.isOutline(layer)
    }

    private func packageIDsWithGeometry() -> Set<String> {
        packageIDsWithGeometry(in: board)
    }

    private func packageIDsWithGeometry(in board: HorizontalBoard) -> Set<String> {
        let geometryPackageIDs = Set(boardPackageGeometryPoints(in: board).keys)
        return Set(board.packages.compactMap { package in
            geometryPackageIDs.contains(normalizedID(package.id)) ? package.id : nil
        })
    }

    private func objectIDPrefix(in geometryID: String, separators: Set<String>) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
              separatorIndex > components.startIndex else {
            return nil
        }
        return components[..<separatorIndex].joined(separator: "/")
    }

    private func hole(for id: String) -> HorizontalHole? {
        (board.holes + board.packageHoles + board.viaHoles).first {
            normalizedID($0.id) == normalizedID(id)
        }
    }

    private func displayName(for type: HorizontalObjectType) -> String {
        switch type {
        case .boardPackage: "Board package"
        case .boardDecal: "Board decal"
        case .boardHole: "Board hole"
        case .boardArc: "Board arc"
        case .boardLine: "Board line"
        case .boardNetTie: "Board net tie"
        case .boardPanel: "Board panel"
        case .connectionLine: "Connection line"
        case .dimension: "Dimension"
        case .keepout: "Keepout"
        case .pad: "Pad"
        case .plane: "Plane"
        case .polygonArcCenter: "Polygon arc center"
        case .polygonEdge: "Polygon edge"
        case .polygonVertex: "Polygon vertex"
        case .text: "Text"
        case .track: "Track"
        case .via: "Via"
        case .blockSymbolPort: "Block symbol port"
        case .busLabel: "Bus label"
        case .busRipper: "Bus ripper"
        case .drawingArc: "Drawing arc"
        case .drawingLine: "Drawing line"
        case .junction: "Junction"
        case .lineNet: "Net line"
        case .netLabel: "Net label"
        case .powerSymbol: "Power symbol"
        case .schematicBlockSymbol: "Block symbol"
        case .schematicNetTie: "Schematic net tie"
        case .schematicSymbol: "Schematic symbol"
        case .symbolPin: "Symbol pin"
        }
    }

    private func pluralDisplayName(for type: HorizontalObjectType) -> String {
        switch type {
        case .boardPackage: "Board packages"
        case .boardDecal: "Board decals"
        case .boardHole: "Board holes"
        case .boardArc: "Board arcs"
        case .boardLine: "Board lines"
        case .boardNetTie: "Board net ties"
        case .boardPanel: "Board panels"
        case .connectionLine: "Connection lines"
        case .dimension: "Dimensions"
        case .keepout: "Keepouts"
        case .pad: "Pads"
        case .plane: "Planes"
        case .polygonArcCenter: "Polygon arc centers"
        case .polygonEdge: "Polygon edges"
        case .polygonVertex: "Polygon vertices"
        case .text: "Texts"
        case .track: "Tracks"
        case .via: "Vias"
        case .blockSymbolPort: "Block symbol ports"
        case .busLabel: "Bus labels"
        case .busRipper: "Bus rippers"
        case .drawingArc: "Drawing arcs"
        case .drawingLine: "Drawing lines"
        case .junction: "Junctions"
        case .lineNet: "Net lines"
        case .netLabel: "Net labels"
        case .powerSymbol: "Power symbols"
        case .schematicBlockSymbol: "Block symbols"
        case .schematicNetTie: "Schematic net ties"
        case .schematicSymbol: "Schematic symbols"
        case .symbolPin: "Symbol pins"
        }
    }

    private func normalizedID(_ id: String) -> String {
        HorizontalCanvasModeSupport.normalizedID(id)
    }

    private func pointKey(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
    }

    private func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

#if os(macOS)
/// The TextField hosted inside the macOS inline text-placement popover. Focuses
/// on appear and selects all of the seeded `"Text"` so the first keystroke
/// replaces it. Submit (Return) calls `onSubmit`; the popover's own dismissal
/// (click-away / Esc) is what finalizes a non-submit edit.
struct BoardInlineTextEditorField: View {
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    /// The popover grows with the content: wide enough for the longest line up
    /// to a cap, past which the field wraps onto further lines (Option-Return
    /// inserts a newline; plain Return still submits).
    private static let minWidth: CGFloat = 200
    private static let maxWidth: CGFloat = 460

    var body: some View {
        TextField("Text", text: $text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...10)
            .frame(width: fieldWidth)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(10)
            .onAppear {
                focused = true
                // Select-all so typing replaces the "Text" placeholder. The field
                // editor only exists once focus lands, so defer a tick.
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                        editor.selectAll(nil)
                    }
                }
            }
    }

    private var fieldWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widestLine = text.components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // ~28pt covers the rounded-border field's text insets plus caret slack,
        // so the line about to hit the cap doesn't wrap a character early.
        return min(max(widestLine + 28, Self.minWidth), Self.maxWidth)
    }
}
#endif

private extension HorizontalRGBColor {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

extension HorizontalDimensionMode: CaseIterable {
    static var allCases: [HorizontalDimensionMode] {
        [.distance, .horizontal, .vertical]
    }
}

private extension HorizontalDimensionMode {
    var title: String {
        switch self {
        case .distance: "Distance"
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }
}
