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
    /// Package editor: a pad, re-baked at its new position on paste.
    case pad(HorizontalPad)
    /// Padstack editor: a shape, re-baked on paste.
    case padstackShape(HorizontalPadstackShape)
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

/// Live placement of a pool object — a pad in the package editor, a shape or
/// a hole in the padstack editor, a decal, via or hole on the board —
/// following the cursor until a click places it. The pad, shape, hole and via
/// tools then re-arm with the same padstack / form / angle / net so a row of
/// pads is one click each, as Horizon's place tools do; a decal's ends with
/// the one, as Horizon's does. Render-only until the commit, so Esc simply
/// drops it.
private enum PoolPlacementKind {
    /// The pad, and its copper/mask/paste/holes baked at the origin.
    case pad(HorizontalPad, geometry: HorizontalPackageGeometry)
    case shape(HorizontalPadstackShape)
    /// A padstack's hole, or on the board a board hole on a hole padstack.
    case hole(HorizontalHole)
    /// The decal, and the board decal it makes drawn at the origin.
    case decal(HorizontalBoardDecalPlacement, geometry: HorizontalBoardDecal)
    /// A via of the shape the rules give `netID`, pinned on it.
    case via(HorizontalBoardViaTemplate, netID: String)
}

/// What the board's net chooser is open for.
private enum BoardNetPickerPurpose {
    /// Set Net… on these tracks and vias.
    case setNet([HorizontalSelectableRef])
    /// Place Via…, which places vias on the net chosen.
    case placeVia
}

private struct PoolPlacementState {
    var kind: PoolPlacementKind
    var cursor: HorizontalPoint
}

/// The plane editor popover, anchored on the canvas: defining a plane on a
/// polygon, editing the plane a polygon backs, or finishing a drawn one.
private struct PlaneEditorState {
    enum Purpose {
        case define(polygonID: String)
        case edit(planeID: String)
        /// Draw Plane: the polygons are still the tool's draft; confirming
        /// commits them with their planes, cancelling drops them.
        case finishDrawing(polygons: [HorizontalPolygon])
    }

    var purpose: Purpose
    var worldPosition: HorizontalPoint
    var layer: Int?
    var draft: HorizontalPlaneEditorDraft
}

/// Horizon's map-package tool in flight: a component's package, just put on
/// the board, follows the cursor until a click settles it.
private struct PackagePlacementState {
    /// The board before the package: what Esc goes back to.
    var originalBoard: HorizontalBoard
    var placementID: String
}

/// Where the pointer last picked something on the board — a click or a
/// right-click — and how many world units a point was there. A polygon edge
/// and the board's fill name the polygon alike, as its first edge, so this is
/// what tells a click on that edge from one inside the board. Kept outside
/// SwiftUI state, as the live transform is.
@MainActor
private final class BoardPointerPick {
    var point: HorizontalPoint?
    var worldUnitsPerPoint = 0.0
}

/// Horizon's `ToolRoundOffVertex` in flight: the corner's rounding, the
/// arc direction (E flips it) and the radius the cursor last set. A corner
/// rounded off before starts at its arc's radius and direction, and keeps
/// them until the cursor moves.
/// Add Vertex (K) on a board polygon's edge, as Horizon's: a vertex goes
/// into the edge and follows the cursor, each click leaves it there and puts
/// the next one in after it, and Return, Esc or a double-click ends the tool,
/// keeping what the clicks placed and dropping the vertex at the cursor.
private struct AddVertexState {
    var polygonID: String
    /// The polygon as it would be: the vertices placed so far, and the one
    /// at the cursor (`floatingIndex`).
    var polygon: HorizontalPolygon
    var floatingIndex: Int
    var placedCount = 0
    /// What was selected when K was pressed, given back when nothing is
    /// added.
    var selection: [HorizontalSelectableRef] = []

    /// A vertex at `cursor` into `polygon`'s edge that starts at `vertex`;
    /// nil on an arc, which a vertex would bend out of shape.
    init?(polygon: HorizontalPolygon, afterVertex vertex: Int, cursor: HorizontalPoint) {
        guard polygon.polygonVertices.indices.contains(vertex), polygon.polygonVertices[vertex].type == .line else {
            return nil
        }
        polygonID = polygon.id
        self.polygon = polygon
        floatingIndex = vertex + 1
        self.polygon.polygonVertices.insert(HorizontalPolygonVertex(position: cursor), at: floatingIndex)
    }

    var cursor: HorizontalPoint {
        polygon.polygonVertices[floatingIndex].position
    }

    mutating func update(cursor: HorizontalPoint) {
        polygon.polygonVertices[floatingIndex].position = cursor
    }

    /// The vertex at the cursor stays where it is; the next goes in after it.
    mutating func place() {
        placedCount += 1
        polygon.polygonVertices.insert(HorizontalPolygonVertex(position: cursor), at: floatingIndex + 1)
        floatingIndex += 1
    }

    /// What the clicks placed, without the vertex at the cursor.
    var placed: HorizontalPolygon {
        var placed = polygon
        placed.polygonVertices.remove(at: floatingIndex)
        return placed
    }
}

private struct RoundOffVertexState {
    var polygonID: String
    var rounding: HorizontalPolygonRounding
    var reverse: Bool
    var radius: Double
    var cursor: HorizontalPoint

    init(polygonID: String, rounding: HorizontalPolygonRounding, cursor: HorizontalPoint) {
        self.polygonID = polygonID
        self.rounding = rounding
        self.reverse = rounding.existing?.reverse ?? rounding.reverse
        self.radius = rounding.existing?.radius ?? rounding.radius(for: cursor)
        self.cursor = cursor
    }

    /// Whether the corner was rounded off before, so a zero radius makes it
    /// sharp rather than leaving it as it was.
    var adjustsRounding: Bool {
        rounding.existing != nil
    }

    var vertexIndex: Int {
        rounding.vertexIndex
    }

    var clampedRadius: Double {
        rounding.clamped(radius)
    }

    /// Whether the radius is too small for an arc, so the corner is sharp.
    var isSharp: Bool {
        clampedRadius < HorizontalPolygonRounding.minimumRadius
    }

    /// Whether committing would leave the corner as it was.
    var isUnchanged: Bool {
        guard let existing = rounding.existing else {
            return isSharp
        }
        return abs(clampedRadius - existing.radius) < 0.5 && reverse == existing.reverse
    }

    func polygon() -> HorizontalPolygon {
        rounding.polygon(radius: radius, reverse: reverse)
    }

    mutating func update(cursor: HorizontalPoint) {
        self.cursor = cursor
        radius = rounding.radius(for: cursor)
    }
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
    // Every via's diameter in solid green (`viaDiameterFill`), drawn once per
    // via above every copper layer it spans, whichever is on top, and below
    // its hole. Its colour is baked into the vertex colours, so the group
    // itself composites at 1 and keeps the inline fast path.
    private static let viaDiameterMetalCompositeGroup = 1_800_000
    // A highlight's dim, under the highlighted copper the top overlay draws
    // over it in their layers' groups: below every group, the board body's
    // (1) included. Exempt from the layer opacity, as the dim's strength is
    // the highlight mode's.
    private static let highlightDimMetalCompositeGroup = -1
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
    /// The most text strokes a turn during a move redraws in place (122).
    /// They are written again on every step of the move after it, so past
    /// this (a whole board turned, say) the one rebuild costs less.
    private static let maximumTurnedTextStrokes = 20_000

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
        /// The move's live rats' nest (`BoardSelectableCache.requestMovingAirwires`),
        /// for a move that carries a package.
        var airwireRequest: Int? = nil
        /// The board from before the move, once E (or a turn that can't be
        /// patched) has rewritten `originalBoard` (105). Undo goes back to it,
        /// and a commit lands even when nothing moved after it.
        var boardBeforeMove: HorizontalBoard? = nil
        /// R and T as the move turned in place (122); nil until one does.
        var turn: BoardMoveTurn? = nil
        /// Set when this is a drag of a track keeping its slopes, or of a via
        /// (`HorizontalCopperDrag`), which shapes the copper instead of
        /// shifting the selection, and takes no turn.
        var copperDrag: HorizontalCopperDrag? = nil

        /// Where the move draws `originalBoard`'s copy of what moves: the turns
        /// so far, then the shift since the last of them.
        var livePlacement: HorizontalPlacementTransform {
            let delta = lastPoint - startPoint
            guard let turn else {
                return HorizontalPlacementTransform(shift: delta, angle: 0, mirrored: false)
            }
            return HorizontalPlacementTransform(
                shift: turn.placement.shift + delta,
                angle: turn.placement.angle,
                mirrored: false
            )
        }
    }

    /// A move's quarter turns, made in place (122). The resident scene, the
    /// resident move plan and the live airwires stay those of `originalBoard`,
    /// which is left alone; only where its copy of what moves is drawn changes.
    /// Turning the model instead, as 105 did, rebuilt the whole scene on
    /// every key press.
    private struct BoardMoveTurn {
        /// `originalBoard` with the move so far and the turns in it, made as
        /// 105 made it. The commit, and a preview that can't be patched, carry
        /// on from it.
        var board: HorizontalBoard
        /// Takes `originalBoard`'s copy of what moves to where `board` has it:
        /// whole quarter turns, then a shift.
        var placement: HorizontalPlacementTransform
        /// How many turns, for the caches keyed on the move's points.
        var count: Int
    }

    /// R, T and Rotate Around Center as turns, so a move can make them in place
    /// (122). The transform each passes is still what changes the model.
    private struct BoardSelectionTurn {
        var angle: Int
        /// About the cursor when there is one (R, T), or always about the
        /// selection's centre.
        var aboutCursor: Bool
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
        var rectanglePlacementMode = HorizontalDrawingToolSettings.rectanglePlacementMode()
        var layer: Int
        /// What the finished drawing becomes. Every outcome reuses the same
        /// interaction hooks — points, cursor, escape, commit — so a new one
        /// needs no state-machine plumbing; only `commitDrawGraphics` branches.
        /// `plane` is Horizon's tool_draw_plane: draw a polygon, then bind it to
        /// a net. `dimension` draws a two-point measurement.
        var outcome: Outcome = .geometry

        enum Outcome {
            case geometry
            case plane
            case dimension
        }
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
        /// Where `width` comes from (`HorizontalRouteWidth`): whether it
        /// follows the route onto another layer or net, or a change to the
        /// rules, and what the route inspector says of it.
        var widthSource: HorizontalRouteWidthSource
        var layer: Int
        var cursor: HorizontalPoint?
        var bendMode: BoardTrackBendMode = .xy
        var cornerStyle: BoardTrackCornerStyle = .fortyFive
        var segmentCount = 0
        var viaCount = 0
        /// `v` armed a via, as Horizon's router places one: it rides on the
        /// end of the route at the cursor, and the next click lays the route
        /// there, drops the via at its end and carries on on the far layer.
        var placesVia = false
        /// The layer the route was on before the click that just dropped a
        /// via took it to the far one; nil once a click lays anything after
        /// the via. A double-click then ends the route at the via and goes
        /// back to that layer, as a via down to a plane on another layer
        /// wants: the next route starts where this one did.
        var layerBeforeVia: Int?
        /// Where the stretch being drawn left copper that was there before the
        /// route; a click that reaches its net's copper again replaces what
        /// joined the two (`BoardTrackLoops`).
        var loopStart: BoardTrackLoopEnd?
        /// The tracks the route has laid, which loop removal never takes.
        var routeTrackIDs: Set<String> = []

        /// Whether the route has committed anything to the draft board yet
        /// (segments or vias) — gates finishing so an empty route is discarded.
        var hasDrawn: Bool { segmentCount > 0 || viaCount > 0 }
    }

    /// What the route inspector shows of a route, compared on every pass.
    private struct BoardRouteInspectorSignature: Hashable {
        var layer: Int
        var netID: String?
        var width: Double
        var widthSource: HorizontalRouteWidthSource
        var anchor: HorizontalPoint?
        var cursor: HorizontalPoint?
        var bendMode: Bool
        var cornerStyle: String
        var placesVia: Bool
        var segmentCount: Int
        var viaCount: Int
        var history: Int
        var rulesRevision: Int
        var previewCount: Int
        var viaDiameter: Double?
        var viaHoleDiameter: Double?
    }

    /// What a click at the cursor would do when it closes a loop
    /// (`BoardTrackLoops`): end the route, and change the copper already there
    /// when it replaces some — the tracks and vias it takes off, a track it
    /// cuts among them, and the pieces of a cut track that stay. The legs it
    /// lays are the route preview's own. Render-only.
    private struct BoardRouteLoopPreview: Equatable {
        var hiddenTrackIDs: Set<String>
        var hiddenViaIDs: Set<String>
        var pieces: [HorizontalSegment]
        /// What it does to the copper, sorted, which keys the Metal scene.
        var signature: [String]

        var replacesCopper: Bool { !hiddenTrackIDs.isEmpty || !hiddenViaIDs.isEmpty }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature == rhs.signature }

        func applied(to board: HorizontalBoard) -> HorizontalBoard {
            guard replacesCopper else {
                return board
            }
            var result = board
            result.tracks.removeAll { hiddenTrackIDs.contains($0.id) }
            result.tracks.append(contentsOf: pieces)
            if !hiddenViaIDs.isEmpty {
                result.vias.removeAll { hiddenViaIDs.contains($0.id) }
                result.viaHoles.removeAll { hole in
                    hiddenViaIDs.contains(hole.id) || hiddenViaIDs.contains { hole.id.hasPrefix("\($0)/") }
                }
            }
            return result
        }
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
        var widthSource: HorizontalRouteWidthSource
        var layer: Int
        var segmentCount: Int
        var viaCount: Int
        var placesVia: Bool
        var loopStart: BoardTrackLoopEnd?
        var routeTrackIDs: Set<String>
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
    /// The parts selected in another view — the workspace's selection when
    /// this canvas didn't make it — boxed in blue here without becoming this
    /// canvas's selection, so its inspector and keys stay as they are.
    var crossSelectedComponentIDs = Set<String>()
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
    /// Q, or the Update All Planes menu item and rail button: the host pours
    /// every plane on its current board.
    var onUpdateAllPlanes: () -> Void = {}
    var onNetClassChange: (String, String?) -> Void = { _, _ in }
    /// Where the inspector's Diff pair row sends Set and Clear Diff Pair, for
    /// the nets it can edit; nil leaves the row read-only.
    var onEditDiffpair: HorizontalDiffpairEditing? = nil
    /// Horizon's Measure Track and Measure All Tracks: the selected tracks,
    /// by id, to the Length Tuning window, with whether to measure all of
    /// their nets' tracks. Nil where the host has no window.
    var onMeasureTracks: ((Set<String>, Bool) -> Void)? = nil
    /// The design's block instances, for the instances of a block laid out
    /// alike: what the inspector says of an instance's parts, and what Select
    /// Instance selects. Nil or empty where no block is used twice.
    var blockInstances: HorizontalBoardBlockInstances? = nil
    /// The Length Tuning window's reference length, the tune tool's target
    /// unless one is typed (`HorizontalBoardToolSettings.tuneTarget`).
    var tuningReferenceLength: Double? = nil
    var onComponentRefdesChange: (String, String) -> Void = { _, _ in }
    var onSelectionDetailsChange: (HorizontalSelectionDetailState) -> Void = { _ in }
    var onCanvasCommandActionsChange: (HorizontalCanvasCommandActions?) -> Void = { _ in }
    var hasKeyboardFocus = true
    var onRequestKeyboardFocus: () -> Void = {}
    /// Tab: the host gives the schematic the keyboard, or shows it in the
    /// board's place. Nil leaves Tab to the window.
    var onSwitchPane: (() -> Void)?
    var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    var drawingToolCommand: HorizontalDrawingToolCommand?
    var drawTrackCommand: HorizontalDrawTrackCommand?
    /// A decal from the Pools pane, taken up as one chosen in Place Decal…'s
    /// chooser is.
    var placeDecalRequest: HorizontalBoardDecalPlacementRequest?
    /// The route inspector's "Rules" width: the route in progress takes the
    /// rules' width again, even one continuing a track's.
    var routeWidthCommand: HorizontalRouteWidthCommand?
    /// Fed while a track is routed, for the sidebar to show; nil where the
    /// host shows no route inspector. Held, not observed: a cursor move
    /// redraws the inspector, not the canvas.
    var routeInspector: HorizontalRouteInspectorModel? = nil
    /// Bumped by the host when the board's rules change without a reload
    /// (the route inspector, the rules window, their undo): the canvas takes
    /// the board's new rules into what it is editing and applies them, and a
    /// route whose width is the rules' takes their new one.
    var rulesRevision: Int = 0
    /// Bumped with `rulesRevision` when applying the new rules changed the
    /// host's board — a track's width, a via's shape — which the canvas then
    /// draws again.
    var rulesShapeRevision: Int = 0
    var onShowToolSettings: () -> Void = {}
    /// Opens the sidebar on the selection's details, as Edit Plane… and
    /// Define Keepout… do.
    var onShowSelectionDetails: () -> Void = {}
    var drawingLayer: Int = HorizontalBoardLayers.topCopper
    /// Bumped by the pane when the board changes underneath the canvas — a plane
    /// pour, a schematic sync. The canvas adopts the new board in place rather
    /// than being rebuilt, so the view never blanks for work it did not ask for.
    var syncRevision: Int = 0
    /// Bumped by the pane each time "Update All Planes" lands. The silkscreen
    /// clip is refreshed alongside the fills rather than on every edit.
    var planePourRevision: Int = 0
    /// A pour's fills, newest last: taken into the board shown without
    /// `syncRevision`'s reset, so a pour landing while you work stops
    /// nothing. Held while a tool is in use, and dropped when the board no
    /// longer has the copper they were poured around.
    var planeFillDelivery: HorizontalPlaneFillDelivery? = nil
    /// Number keys pick the working copper layer; the pane owns the selection,
    /// so the canvas reports the request rather than applying it.
    var onSelectDrawingLayer: (Int) -> Void = { _ in }
    /// Shifted / control number keys jump to a board view preset.
    var onSelectBoardLayerView: (HorizontalBoardLayerViewPreset) -> Void = { _ in }
    /// Design ▸ Filter Airwires…: the host opens its airwire filter. Nil
    /// leaves the menu item off.
    var onFilterAirwires: (() -> Void)? = nil
    /// Pool directory URL, for re-deriving a package's silk on Unsmash.
    var poolURL: URL?
    /// What the canvas is editing: a board, or a pool package / padstack /
    /// decal in the mode Horizon's layered imp would open it with.
    var modeProfile: HorizontalBoardModeProfile = .board
    /// Padstack resolution and naming for a package / padstack editor.
    var poolContext: HorizontalPoolEditorContext? = nil
    /// The host can show a package in a pool window (macOS project windows).
    var canRevealPoolPackages = false
    var onRevealPoolPackage: (String, HorizontalPoolRevealTarget) -> Void = { _, _ in }
    /// The rules checks' findings, marked where they are: the clearance
    /// check's, from the last run.
    var ruleMarkers: [HorizontalCanvasWarning] = []
    @ObservedObject var toolSettings: HorizontalBoardToolSettings

    @State private var hoveredObject: HorizontalSelectableRef?
    @State private var selectedObjects: [HorizontalSelectableRef] = []
    @State private var selectedUnplacedObjectID: String?
    @State private var editedBoard: HorizontalBoard?
    @State private var moveState: MoveState?
    @State private var drawGraphicsState: DrawGraphicsState?
    /// Design ▸ Measure Distance while it is on (`BoardMeasureState`).
    @State private var measureState: BoardMeasureState?
    @State private var drawTrackState: DrawTrackState?
    /// Obstacle world for the active drawing gesture, built once when it starts.
    /// See `docs/push-shove-router.md`.
    @State private var trackRouterSession: HorizontalBoardTrackRouterSession?
    /// Live PNS head, as preview specs, while the autorouter is active (empty in
    /// manual mode). A universal type so the preview renderers stay
    /// platform-agnostic; the session that produces it is macOS-only.
    @State private var pushShovePreviewSpecs: [BoardTrackSegmentSpec] = []
    #if canImport(HorizontalPushShoveRouter)
    /// Existing tracks (by id) the previewing route will remove (track repair /
    /// shove) — hidden from the board render until commit.
    @State private var pushShoveRemovedSegmentIDs: Set<String> = []
    @State private var pushShoveSession: BoardPushShoveSession?
    #endif
    /// What a click at the cursor would do when it closes a loop
    /// (`BoardTrackLoops`): the copper it would take off is drawn as gone, and
    /// the armed via as not dropped, until the cursor moves on. Nil everywhere
    /// else.
    @State private var routeLoopPreview: BoardRouteLoopPreview?
    /// What `routeLoopPreview` was last worked out for, so a cursor resting
    /// on one point asks once.
    @State private var routeLoopPreviewQuery: String?
    /// In-app copy buffer for board objects (Copy → Paste/Duplicate). Holds the
    /// harvested objects + their bounding-box min so Paste can land at the cursor.
    @State private var boardClipboard: [BoardClipboardItem] = []
    @State private var boardClipboardAnchor: HorizontalPoint?
    /// Active while Paste is placing the clipboard ghost: the harvested objects
    /// follow the cursor (`cursor − anchor` offset) until a click / Return
    /// commits them, or Esc cancels. Nothing is added to the board until commit.
    @State private var pastePlacementState: PastePlacementState?
    @State private var poolPlacementState: PoolPlacementState?
    @State private var roundOffVertexState: RoundOffVertexState?
    @State private var addVertexState: AddVertexState?
    /// The tune tool, while it is in use (`BoardTuneState`).
    @State private var tuneState: BoardTuneState?
    /// U during a move, route or paste: the edit is this block instance's
    /// alone, the instances laid out like it left as they are.
    @State private var instanceOnlyEdit = false
    /// Said for a moment where the hints go: what the last edit also changed
    /// in other block instances, or why a tool didn't start.
    @State private var canvasNote: String?
    @State private var canvasNoteID = 0
    @State private var packagePlacementState: PackagePlacementState?
    @State private var planeEditorState: PlaneEditorState?
    @State private var padstackPickerPresented = false
    /// Place Decal…'s chooser, while it is up: the decals the board can take.
    @State private var decalPickerIndex: HorizontalPoolLibraryIndex?
    /// The net chooser, while it is up, and what it chooses a net for.
    @State private var netPickerPurpose: BoardNetPickerPurpose?
    /// Place Board Hole…'s chooser, while it is up: the hole and mechanical
    /// padstacks the pools hold.
    @State private var holePadstackChoices: [HorizontalPoolPadstackInfo]?
    /// The last `placeDecalRequest` taken up, so the mount doesn't take up
    /// again one its change already did.
    @State private var handledPlaceDecalRequestID: UUID?
    /// Step-back history for the in-progress route (Backspace pops one).
    @State private var trackRouteHistory: [BoardTrackRouteStep] = []
    @State private var lastCursorWorldPoint: HorizontalPoint?
    @State private var selectableCacheRevision = 0
    @State private var metalSceneRevision = 0
    /// The last `planeFillDelivery` taken or turned down.
    @State private var takenPlaneFillRevision = 0
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
    /// Every reported transform, for the live channel (see HorizontalLiveCanvasTransform).
    @State private var liveCanvasTransform = HorizontalLiveCanvasTransform()
    @State private var lastPointerPick = BoardPointerPick()
    /// The airwires the scene last handed over was built with, for the live
    /// channel (see HorizontalLiveCanvasAirwires).
    @State private var liveCanvasAirwires = HorizontalLiveCanvasAirwires()
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
    @State private var blockLayoutCache = BoardBlockLayoutCache()
    @Environment(\.colorScheme) private var colorScheme
    /// The window's Pools pane, for Alternate Parts…; nil where there is none.
    @Environment(\.horizonPoolRevealAction) private var poolRevealAction
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(
        board: HorizontalBoard,
        netClasses: [HorizontalNetClass] = [],
        viewport: Binding<CanvasViewport>,
        displayOptions: BoardDisplayOptions,
        fitSafeAreaInsets: EdgeInsets? = nil,
        highlightedNetIDs: Set<String> = [],
        highlightedComponentIDs: Set<String> = [],
        crossSelectedComponentIDs: Set<String> = [],
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
        onUpdateAllPlanes: @escaping () -> Void = {},
        onNetClassChange: @escaping (String, String?) -> Void = { _, _ in },
        onEditDiffpair: HorizontalDiffpairEditing? = nil,
        onMeasureTracks: ((Set<String>, Bool) -> Void)? = nil,
        blockInstances: HorizontalBoardBlockInstances? = nil,
        tuningReferenceLength: Double? = nil,
        onComponentRefdesChange: @escaping (String, String) -> Void = { _, _ in },
        onSelectionDetailsChange: @escaping (HorizontalSelectionDetailState) -> Void = { _ in },
        onCanvasCommandActionsChange: @escaping (HorizontalCanvasCommandActions?) -> Void = { _ in },
        hasKeyboardFocus: Bool = true,
        onRequestKeyboardFocus: @escaping () -> Void = {},
        onSwitchPane: (() -> Void)? = nil,
        selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand? = nil,
        drawingToolCommand: HorizontalDrawingToolCommand? = nil,
        drawTrackCommand: HorizontalDrawTrackCommand? = nil,
        placeDecalRequest: HorizontalBoardDecalPlacementRequest? = nil,
        routeWidthCommand: HorizontalRouteWidthCommand? = nil,
        routeInspector: HorizontalRouteInspectorModel? = nil,
        rulesRevision: Int = 0,
        rulesShapeRevision: Int = 0,
        onShowToolSettings: @escaping () -> Void = {},
        onShowSelectionDetails: @escaping () -> Void = {},
        toolSettings: HorizontalBoardToolSettings,
        drawingLayer: Int = HorizontalBoardLayers.topCopper,
        syncRevision: Int = 0,
        planePourRevision: Int = 0,
        planeFillDelivery: HorizontalPlaneFillDelivery? = nil,
        onSelectDrawingLayer: @escaping (Int) -> Void = { _ in },
        onSelectBoardLayerView: @escaping (HorizontalBoardLayerViewPreset) -> Void = { _ in },
        onFilterAirwires: (() -> Void)? = nil,
        poolURL: URL? = nil,
        modeProfile: HorizontalBoardModeProfile = .board,
        poolContext: HorizontalPoolEditorContext? = nil,
        canRevealPoolPackages: Bool = false,
        onRevealPoolPackage: @escaping (String, HorizontalPoolRevealTarget) -> Void = { _, _ in },
        ruleMarkers: [HorizontalCanvasWarning] = []
    ) {
        self.sourceBoard = board
        self.netClasses = netClasses
        self._viewport = viewport
        self.displayOptions = displayOptions
        self.fitSafeAreaInsets = fitSafeAreaInsets
        self.highlightedNetIDs = highlightedNetIDs
        self.highlightedComponentIDs = highlightedComponentIDs
        self.crossSelectedComponentIDs = crossSelectedComponentIDs
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
        self.onUpdateAllPlanes = onUpdateAllPlanes
        self.onNetClassChange = onNetClassChange
        self.onEditDiffpair = onEditDiffpair
        self.onMeasureTracks = onMeasureTracks
        self.blockInstances = blockInstances
        self.tuningReferenceLength = tuningReferenceLength
        self.onComponentRefdesChange = onComponentRefdesChange
        self.onSelectionDetailsChange = onSelectionDetailsChange
        self.onCanvasCommandActionsChange = onCanvasCommandActionsChange
        self.hasKeyboardFocus = hasKeyboardFocus
        self.onRequestKeyboardFocus = onRequestKeyboardFocus
        self.onSwitchPane = onSwitchPane
        self.selectionPropertyChangeCommand = selectionPropertyChangeCommand
        self.drawingToolCommand = drawingToolCommand
        self.drawTrackCommand = drawTrackCommand
        self.placeDecalRequest = placeDecalRequest
        self.routeWidthCommand = routeWidthCommand
        self.routeInspector = routeInspector
        self.rulesRevision = rulesRevision
        self.rulesShapeRevision = rulesShapeRevision
        self.onShowToolSettings = onShowToolSettings
        self.onShowSelectionDetails = onShowSelectionDetails
        self.toolSettings = toolSettings
        self.drawingLayer = drawingLayer
        self.syncRevision = syncRevision
        self.planePourRevision = planePourRevision
        self.planeFillDelivery = planeFillDelivery
        self.onSelectDrawingLayer = onSelectDrawingLayer
        self.onSelectBoardLayerView = onSelectBoardLayerView
        self.onFilterAirwires = onFilterAirwires
        self.poolURL = poolURL
        self.modeProfile = modeProfile
        self.poolContext = poolContext
        self.canRevealPoolPackages = canRevealPoolPackages
        self.onRevealPoolPackage = onRevealPoolPackage
        self.ruleMarkers = ruleMarkers
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
        if let poolPlacementState {
            var preview = base
            appendPoolPlacementGhost(poolPlacementState, into: &preview)
            return preview
        }
        if let tuneState, tuneState.result?.hasCells == true {
            return tuneState.preview(of: base)
        }
        if let roundOffVertexState {
            var preview = base
            let liftedOutlines = preview.liftPlaneOutlines()
            let polygonID = normalizedID(roundOffVertexState.polygonID)
            if let index = preview.polygons.firstIndex(where: { normalizedID($0.id) == polygonID }) {
                preview.polygons[index] = roundOffVertexState.polygon()
            }
            preview.lowerPlaneOutlines(lifted: liftedOutlines)
            return preview
        }
        if let addVertexState {
            var preview = base
            let liftedOutlines = preview.liftPlaneOutlines()
            let polygonID = normalizedID(addVertexState.polygonID)
            if let index = preview.polygons.firstIndex(where: { normalizedID($0.id) == polygonID }) {
                preview.polygons[index] = addVertexState.polygon
            }
            preview.lowerPlaneOutlines(lifted: liftedOutlines)
            return preview
        }
        return base
    }

    private var pastePreviewSignature: BoardPastePreviewSignature? {
        if let pastePlacementState {
            let offset = pastePlacementState.cursor - pastePlacementState.anchor
            return BoardPastePreviewSignature(
                itemCount: pastePlacementState.items.count,
                offsetX: Int64(offset.x.rounded()),
                offsetY: Int64(offset.y.rounded())
            )
        }
        if let poolPlacementState {
            // The pool ghost rides the same cache slot: its kind, angle and
            // mirror fold into the count, the cursor into the offset.
            return BoardPastePreviewSignature(
                itemCount: poolPlacementSignatureCount(poolPlacementState.kind),
                offsetX: Int64(poolPlacementState.cursor.x.rounded()),
                offsetY: Int64(poolPlacementState.cursor.y.rounded())
            )
        }
        if let signature = tuneState?.previewSignature {
            // A tune's meander rides the same slot: its pieces in the count
            // and a hash, its length.
            return BoardPastePreviewSignature(
                itemCount: 2_000_000 + signature.count,
                offsetX: signature.hash,
                offsetY: signature.length
            )
        }
        if let addVertexState {
            // The added vertices ride the same slot: how many in the count,
            // where the one at the cursor is in the offset.
            return BoardPastePreviewSignature(
                itemCount: 3_000_000 + addVertexState.polygon.polygonVertices.count,
                offsetX: Int64(addVertexState.cursor.x.rounded()),
                offsetY: Int64(addVertexState.cursor.y.rounded())
            )
        }
        if let roundOffVertexState {
            // The rounded corner rides the same slot: the vertex in the
            // count, the radius and arc direction in the offset.
            return BoardPastePreviewSignature(
                itemCount: roundOffVertexState.vertexIndex + 1,
                offsetX: Int64(roundOffVertexState.clampedRadius.rounded()),
                offsetY: roundOffVertexState.reverse ? 1 : 0
            )
        }
        return nil
    }

    private var boardMovePreviewSignature: BoardMovePreviewSignature? {
        guard let moveState else {
            return nil
        }
        return BoardMovePreviewSignature(
            selectedRefs: selectedObjects,
            startPoint: moveState.startPoint,
            lastPoint: moveState.lastPoint,
            turns: moveState.turn?.count ?? 0
        )
    }

    private var boardForMetalBuckets: HorizontalBoard {
        if canPatchBoardMoveInMetal,
           let moveState {
            return moveState.originalBoard
        }
        // Draw the copper a click at the cursor would replace as gone, so the
        // removal is previewed before it is made. Render-only — `board`
        // (selection, hit-testing) is unchanged.
        return routeLoopPreview?.applied(to: board) ?? board
    }

    private var theme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .board, colorScheme: colorScheme)
    }

    /// The net a route under way connects, from its first click, or from the
    /// click that reached a net when it began on copper on none.
    private var routeHighlightNetID: String? {
        drawTrackState?.netID.map(normalizedID)
    }

    private var shownHighlightNetIDs: Set<String> {
        Self.shownHighlightNetIDs(window: highlightedNetIDs, routeNetID: drawTrackState?.netID)
    }

    /// The nets the canvas draws highlighted: the window's, and the route's
    /// while it lasts, as KiCad's router highlights the net it routes. The
    /// route's is the canvas's own, so the window's highlight, the schematic
    /// and the live channel don't take it, and it ends with the route.
    static func shownHighlightNetIDs(window: Set<String>, routeNetID: String?) -> Set<String> {
        guard let routeNetID else {
            return window
        }
        return window.union([HorizontalCanvasModeSupport.normalizedID(routeNetID)])
    }

    private var hasActiveHighlight: Bool {
        !highlightedNetIDs.isEmpty || routeHighlightNetID != nil || !highlightedComponentIDs.isEmpty
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
                || displayOptions.showsOutlineLayer
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

    /// Whether the move is drawn by patching the resident scene. Every read of
    /// `board` asks this during a move, so it reads only the plan, which has
    /// what the patches can't draw (`isBoardMetalMovePatchable`) among its
    /// unsupported refs. Checking the selection here, once per selection
    /// detail item, cost the first nudge of Board C's Select All 2 s.
    private var canPatchBoardMoveInMetal: Bool {
        guard let moveState,
              moveState.copperDrag == nil,
              !selectedObjects.isEmpty,
              drawsBoardLinesInMetal else {
            return false
        }
        return moveState.residentMovePlan.isPatchable
    }

    /// Whether the resident scene's patches draw `ref` moved, given the
    /// packages that move with it (normalized ids).
    private func isBoardMetalMovePatchable(_ ref: HorizontalSelectableRef, movingPackageIDs: Set<String>) -> Bool {
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
             .polygonVertex,
             .polygonArcCenter,
             .plane,
             .junction:
            // A polygon whose points do not all move changes shape, which
            // its spans' shift cannot draw; the resident plan marks those
            // (`boardResidentMovePlan`), so they fall back to a rebuild.
            return true
        case .text:
            // Standalone board text owns an individually-patchable resident span.
            // A smashed package's `fromSmash` text is drawn as its package's
            // (no span of its own), so, as a pad, it moves with the package's
            // spans when the package moves too (Select All, where every smashed
            // refdes is selected), and alone falls back to a rebuilt scene.
            guard let packageID = packageID(forGeometryID: ref.id) else {
                return true
            }
            return movingPackageIDs.contains(normalizedID(packageID))
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
            return movingPackageIDs.contains(normalizedID(packageID))
        case .blockSymbolPort, .boardPanel, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .padstackShape, .symbolPin:
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
            measuredBoardMetalMovePatches(lineBatch: metalLineBatch)
        }
        let visibleCompositeGroups = measureBody("visible composite groups") {
            visibleMetalCompositeGroups(for: visibleLayers)
        }
        let metalHighlightBatch = measureBody("highlight batch") {
            boardMetalHighlightBatch(
                renderLayers: metalRenderLayers,
                visibleCompositeGroups: visibleCompositeGroups,
                sceneGroupKeys: metalLineBatch.groupKeys
            )
        }
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
        let crossSelection = measureBody("cross selection") { crossSelectionLines() }
        let instanceAnchorMark = measureBody("instance anchor mark") { blockInstanceAnchorMark() }
        // Last, after the selection and the preview, whose places in the
        // buffer a move patches.
        let metalTopOverlayLines = measureBody("overlay lines") {
            metalHighlightBatch.lines + metalSelectionBatch.lines + metalPreviewBatch.lines + crossSelection.lines
        }
        let metalTopOverlayHandles = measureBody("overlay handles") {
            metalHighlightBatch.handles + metalSelectionBatch.handles + metalPreviewBatch.handles
        }
        let metalTopOverlayKey = measureBody("overlay key") {
            (((metalDimBatch.triangleKey &* 31 &+ metalHighlightBatch.lineKey) &* 31 &+ metalSelectionBatch.lineKey) &* 31
                &+ metalPreviewBatch.lineKey) &* 31 &+ crossSelection.key
        }
        // The top overlay's composite groups, each keyed by the batches that
        // draw in it, so a hover or selection change (group 0) leaves a
        // highlight's layer groups where they are.
        let metalTopOverlayGroupKeys = measureBody("overlay group keys") { () -> [Int: Int] in
            var hashers = [Int: Hasher]()
            func fold(_ key: Int, _ groups: some Sequence<Int>) {
                for group in groups {
                    hashers[group, default: Hasher()].combine(key)
                }
            }
            func groups(of batch: BoardMetalLineBatch) -> Set<Int> {
                var groups = Set<Int>()
                for triangle in batch.triangles { groups.insert(triangle.compositeGroup) }
                for line in batch.lines { groups.insert(line.compositeGroup) }
                for rect in batch.anchoredRects { groups.insert(rect.compositeGroup) }
                return groups
            }
            fold(metalDimBatch.triangleKey, groups(of: metalDimBatch))
            fold(metalHighlightBatch.lineKey, metalHighlightBatch.groupKeys.map { Set($0.keys) } ?? groups(of: metalHighlightBatch))
            fold(metalSelectionBatch.lineKey, groups(of: metalSelectionBatch))
            fold(metalPreviewBatch.lineKey, groups(of: metalPreviewBatch))
            fold(crossSelection.key, Set(crossSelection.lines.map(\.compositeGroup)))
            fold(instanceAnchorMark.key, instanceAnchorMark.rects.isEmpty ? [] : [0])
            return hashers.mapValues { $0.finalize() }
        }
        let metalTopOverlayHandleKey = measureBody("handle key") {
            (metalHighlightBatch.handleKey &* 31 &+ metalSelectionBatch.handleKey) &* 31 &+ metalPreviewBatch.handleKey
        }
        let metalTopOverlayBufferPatches = measureBody("selection move patches") {
            // The direct line buffer holds only the ungrouped lines, so the
            // selection's start there counts only the highlight's ungrouped ones.
            measuredBoardMetalSelectionMovePatches(
                baseSelectionBatch: metalSelectionBatch,
                lineStart: metalHighlightBatch.lines.reduce(0) { $0 + ($1.compositeGroup == 0 ? 1 : 0) },
                handleStart: metalHighlightBatch.handles.count
            )
        }
        let _ = HorizontalMoveCommitDiagnostics.reportPostCommitBody(timings: postCommitBodyTimings)

        let canvas = InteractiveCanvasView(
            bounds: board.bounds,
            // A board's bounds are its content's, so a paste or a part placed
            // past them changes them; the view, measured from the bounds its
            // viewport pinned for this board, stays put. A pool editor's
            // board is its item's.
            boundsIdentity: board.uuid,
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
            showsOriginMark: displayOptions.origin && HorizontalMetalBackdropView.isSupported,
            originMarkColor: theme.grid,
            metalOverlayTriangles: metalLineBatch.triangles,
            metalOverlayTriangleKey: metalLineBatch.triangleKey,
            metalOverlayLines: metalLineBatch.lines,
            metalOverlayLineKey: metalLineBatch.lineKey,
            metalOverlayAnchoredRects: metalLineBatch.anchoredRects,
            metalOverlayAnchoredRectKey: metalLineBatch.anchoredRectKey,
            metalOverlayBufferPatches: metalBufferPatches,
            metalOverlayBufferPatchKey: metalBufferPatches.hashValue,
            metalOverlayGroupKeys: metalLineBatch.groupKeys,
            metalOverlayVisibleCompositeGroups: visibleCompositeGroups,
            metalOverlayLayerOpacityExemptGroups: [Self.textOverlayMetalCompositeGroup, Self.holesMetalCompositeGroup],
            metalTopOverlayTriangles: metalTopOverlayTriangles,
            metalTopOverlayTriangleKey: metalTopOverlayKey,
            metalTopOverlayLines: metalTopOverlayLines,
            metalTopOverlayLineKey: metalTopOverlayKey,
            metalTopOverlayHandles: metalTopOverlayHandles,
            metalTopOverlayHandleKey: metalTopOverlayHandleKey,
            metalTopOverlayAnchoredRects: metalHighlightBatch.anchoredRects + instanceAnchorMark.rects,
            metalTopOverlayAnchoredRectKey: metalHighlightBatch.anchoredRectKey &* 31 &+ instanceAnchorMark.key,
            metalTopOverlayBufferPatches: metalTopOverlayBufferPatches,
            metalTopOverlayBufferPatchKey: metalTopOverlayBufferPatches.hashValue,
            metalTopOverlayGroupKeys: metalTopOverlayGroupKeys,
            // The highlighted copper is composited in its layers' groups at
            // the layers' opacity, as the board's overlay composites it.
            metalTopOverlayLayerOpacity: layerOpacity,
            metalTopOverlayLayerOpacityExemptGroups: [
                Self.highlightDimMetalCompositeGroup,
                Self.textOverlayMetalCompositeGroup,
                Self.holesMetalCompositeGroup
            ],
            metalLoadProfileID: board2DProfileID,
            cursorSize: appearanceSettings.canvasCursorSize,
            snapTargets: boardSnapTargets(),
            fitSafeAreaInsets: fitSafeAreaInsets,
            minimumLineWidth: appearanceSettings.minimumLineWidth(for: .board),
            metalLayerOpacity: layerOpacity,
            selectionHUD: selectionHUD,
            // A note is what the last click did, said for a moment over the
            // tool's hints: a via a tool refused to put down, say.
            hoverStatusText: canvasNote ?? interactionStatusText.map(withInstanceOnlyHint) ?? hoverStatusText,
            showsHoverPopover: appearanceSettings.shouldShowHoverPopover,
            selectionDetails: selectionDetails,
            showsSelectionDetails: Self.showsInCanvasSelectionInspector,
            unplacedObjects: currentUnplacedObjects,
            selectedUnplacedObjectID: selectedUnplacedObjectID,
            placesUnplacedObjectsOnTrailingEdge: appearanceSettings.shouldSwapViewControlsAndUnplacedReferences,
            selectionToolSettings: selectionToolSettings,
            selectionSelectables: boardSelectables(),
            // Where the copper is, not where a move is taking it.
            warnings: moveState == nil && appearanceSettings.shouldDisplayCanvasWarnings ? ruleMarkers : [],
            handlesSelectionDeletion: canDeleteSelection,
            undoManager: undoManager,
            ignoresCanvasMouseEvents: ignoresCanvasMouseEvents,
            onCursorWorldPointChange: { pointer, worldUnitsPerPoint in
                updateCursor(at: pointer, worldUnitsPerPoint: worldUnitsPerPoint)
            },
            onPrimaryClick: { pointer, worldUnitsPerPoint, clickAction, clickCount in
                let point = pointer.snapped
                if measureState != nil {
                    measureState?.click(at: point)
                    return
                }
                if packagePlacementState != nil {
                    commitPackagePlacement(at: point)
                    return
                }
                if roundOffVertexState != nil {
                    commitRoundOffVertex(at: point)
                    return
                }
                if addVertexState != nil {
                    // A click leaves the vertex there and adds the next; a
                    // double-click's second ends the tool, as Return does.
                    if clickCount >= 2 {
                        commitAddVertex()
                    } else {
                        placeAddVertex(at: point)
                    }
                    return
                }
                if tuneState != nil {
                    clickTune(at: pointer.raw, worldUnitsPerPoint: worldUnitsPerPoint)
                    return
                }
                if pastePlacementState != nil {
                    commitPastePlacement(at: point)
                    return
                }
                if poolPlacementState != nil {
                    commitPoolPlacement(at: point)
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
                    // A double-click ends the route where its first click
                    // left it: the second lays nothing, so a cursor that
                    // moved a grid step between them adds no stub, and starts
                    // nothing, so one whose first click ended the route on a
                    // pad or a track doesn't begin the next route there.
                    if clickCount >= 2 {
                        if let state = drawTrackState, state.hasDrawn {
                            // A via the first click dropped (V) ends the
                            // route there, on the layer it was on before the
                            // via: the via reaches the far layer, a plane
                            // there, and routing goes on where it was.
                            commitDrawTrack(armingLayer: state.layerBeforeVia)
                            // The via turned the board to the route's layer;
                            // turn it back. Against the route's layer, not
                            // `drawingLayer`, which this click's closure may
                            // hold from before the board turned.
                            if let layer = state.layerBeforeVia, layer != state.layer {
                                onSelectDrawingLayer(layer)
                            }
                        }
                        return
                    }
                    // ⌘-click starts a route anywhere, where the tool would
                    // start one only on copper (`startsOnCopper`).
                    addDrawTrackPoint(point, raw: pointer.raw, startsAnywhere: clickAction == .toggle)
                    return
                }

                lastPointerPick.point = pointer.raw
                lastPointerPick.worldUnitsPerPoint = worldUnitsPerPoint
                let hitRef = hitSelectable(at: pointer.raw, worldUnitsPerPoint: worldUnitsPerPoint)
                #if os(macOS)
                // Double-click a text → reopen the inline editor instead of just
                // selecting it.
                if clickCount >= 2, let hitRef, hitRef.type == .text {
                    beginEditingExistingText(hitRef)
                    return
                }
                #endif
                // Double-click a track → the run of track it is part of, out
                // to its pads, as Horizon's double-click on one runs Select
                // More. The pair's first click has selected the track, as
                // the polygon's below.
                if clickCount >= 2, let hitRef, hitRef.type == .track {
                    updateSelection(
                        with: BoardSelectMore.selection(from: [hitRef], in: board, stopsAtVias: false),
                        action: BoardPolygonParts.doubleClickAction(for: clickAction)
                    )
                    return
                }
                // Double-click a polygon's edge, vertex or arc centre → the
                // whole polygon, as Horizon's double-click selects it.
                if clickCount >= 2, let hitRef,
                   let whole = BoardPolygonParts.doubleClickSelection(of: hitRef, in: boardPolygon(for: hitRef.id, in: board)) {
                    updateSelection(with: whole, action: BoardPolygonParts.doubleClickAction(for: clickAction))
                    return
                }
                updateSelection(with: hitRef, action: clickAction)
            },
            onAreaSelection: { refs, action in
                guard moveState == nil,
                      drawGraphicsState == nil,
                      drawTrackState == nil,
                      pastePlacementState == nil,
                      poolPlacementState == nil,
                      measureState == nil,
                      roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil else {
                    return
                }
                updateSelection(with: selectionFilterAdmits.map { refs.filter($0) } ?? refs, action: action)
            },
            targetMenuItems: { pointer, worldUnitsPerPoint in
                lastPointerPick.point = pointer.raw
                lastPointerPick.worldUnitsPerPoint = worldUnitsPerPoint
                return targetMenuItems(at: pointer.raw, worldUnitsPerPoint: worldUnitsPerPoint)
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
                switch command {
                case .setDiffpair, .clearDiffpair:
                    // They name the nets they edit, so the selection, two
                    // nets' to pair, stays as it is.
                    break
                default:
                    setSelectedObject(ref)
                }
                dispatchCanvasCommand(command)
            },
            onUnplacedObjectSelection: { object in
                selectUnplacedObject(object)
            },
            onSelectionPropertyChange: applySelectionPropertyChange,
            onCommand: dispatchCanvasCommand,
            hitsSelection: { worldPoint, worldUnitsPerPoint in
                pressLandsOnSelection(at: worldPoint, worldUnitsPerPoint: worldUnitsPerPoint)
            },
            clickPicksOutright: { worldPoint, worldUnitsPerPoint in
                selectionVertex(at: worldPoint, worldUnitsPerPoint: worldUnitsPerPoint) != nil
            },
            onCanvasDisplayTransformChange: { transform in
                liveCanvasTransform.transform = transform
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
                // buckets, so doing it per frame made pinch-zoom lag. A canvas
                // with no area (the board kept mounted while the schematic
                // shows) keeps the threshold it was shown at, so its labels
                // are there the moment it is shown again.
                guard transform.size.width >= 1, transform.size.height >= 1 else {
                    labelLODDebouncer.canvasHasNoArea()
                    return
                }
                labelLODDebouncer.schedule(Self.minimumLegibleLabelSize(for: transform)) { settled in
                    if settled != minimumLabelSize {
                        minimumLabelSize = settled
                    }
                }
            },
            onViewportMovement: {
                labelLODDebouncer.postponeForViewportMovement()
            },
            canvasDisplayTransformReportTrigger: inlineTextEditorReportTrigger,
            allowsContextMenu: moveState == nil && drawGraphicsState == nil && drawTrackState == nil && pastePlacementState == nil && poolPlacementState == nil && roundOffVertexState == nil && addVertexState == nil && tuneState == nil && packagePlacementState == nil && measureState == nil,
            handlesInteractionKeys: moveState != nil || drawGraphicsState != nil || drawTrackState != nil || pastePlacementState != nil || poolPlacementState != nil || roundOffVertexState != nil || addVertexState != nil || tuneState != nil || packagePlacementState != nil || measureState != nil,
            usesCrosshairCursor: drawGraphicsState != nil || drawTrackState != nil || measureState != nil,
            hasKeyboardFocus: hasKeyboardFocus,
            onRequestKeyboardFocus: onRequestKeyboardFocus,
            samplesCursorContinuously: drawTrackState != nil
                || drawGraphicsState != nil
                || measureState != nil
                || pastePlacementState != nil
                || poolPlacementState != nil
                || roundOffVertexState != nil || addVertexState != nil || tuneState != nil || packagePlacementState != nil
                || moveState?.tracksCursor == true,
            supportsTrackVias: true,
            switchesPanes: onSwitchPane != nil
        )
        .onChange(of: syncRevision) { _, _ in
            adoptExternallyUpdatedBoard()
        }
        .onChange(of: sourceBoard.grid) { _, grid in
            adoptSourceGrid(grid)
        }
        .onChange(of: planeFillDelivery?.revision) { _, _ in
            takePlaneFillDelivery()
        }
        .onChange(of: holdsPlaneFills) { _, holds in
            if !holds {
                takePlaneFillDelivery()
            }
        }
        .task(id: silkscreenClipTrigger) {
            refreshSilkscreenClips()
        }
        .sheet(isPresented: $padstackPickerPresented) {
            HorizontalPadstackPickerSheet(
                choices: poolContext?.padstackChoices() ?? [],
                onPick: { padstackID in
                    padstackPickerPresented = false
                    beginPlacePad(padstackID: padstackID)
                },
                onCancel: { padstackPickerPresented = false }
            )
        }
        .sheet(isPresented: Binding(
            get: { decalPickerIndex != nil },
            set: { if !$0 { decalPickerIndex = nil } }
        )) {
            HorizontalPoolItemPickerSheet(
                title: "Place Decal",
                category: .decal,
                index: decalPickerIndex ?? .empty,
                showsPreview: true,
                onPick: { item in
                    decalPickerIndex = nil
                    beginPlaceDecal(item)
                },
                onCancel: { decalPickerIndex = nil }
            )
            .environmentObject(appearanceSettings)
        }
        .sheet(isPresented: Binding(
            get: { netPickerPurpose != nil },
            set: { if !$0 { netPickerPurpose = nil } }
        )) {
            HorizontalNetPickerSheet(
                title: netPickerPurpose.map(netPickerTitle) ?? "",
                message: netPickerPurpose.map(netPickerMessage) ?? "",
                confirmTitle: netPickerPurpose.map(netPickerConfirmTitle) ?? "Choose",
                nets: sortedNetOptions(),
                onPick: { chooseNet($0) },
                onCancel: { netPickerPurpose = nil }
            )
        }
        .sheet(isPresented: Binding(
            get: { holePadstackChoices != nil },
            set: { if !$0 { holePadstackChoices = nil } }
        )) {
            HorizontalPadstackPickerSheet(
                choices: holePadstackChoices ?? [],
                onPick: { chooseHolePadstack($0) },
                onCancel: { holePadstackChoices = nil }
            )
        }
        .onChange(of: sourceBoard.uuid) { _, _ in
            undoTarget.removeAllActions(from: undoManager)
            editedBoard = nil
            invalidateSelectableCache()
            selectedObjects = []
            selectedUnplacedObjectID = nil
            hoveredObject = nil
            moveState = nil
            packagePlacementState = nil
            drawGraphicsState = nil
            measureState = nil
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
            // A canvas mounted after a pour starts from a board that has it.
            takenPlaneFillRevision = planeFillDelivery?.revision ?? 0
            // A board first shown for the Pools pane's Place.
            takeUpPlaceDecalRequest()
        }
        .onDisappear {
            onSelectionDetailsChange(.empty)
            onCanvasCommandActionsChange(nil)
            routeInspector?.endRoute()
        }
        .horizonCanvasPrompt($promptRequest)
        .overlay { inlineTextEditorOverlay }
        .overlay { planeEditorOverlay }
        .onChange(of: canvasCommandActionsSignature) { _, _ in
            publishCanvasCommandActions()
        }
        .onChange(of: selectionDetails) { _, details in
            onSelectionDetailsChange(details)
        }
        .onChange(of: selectionPropertyChangeCommand?.id) { _, _ in
            guard let selectionPropertyChangeCommand else { return }
            // Measuring and selecting change nothing, so a locked board does
            // them too.
            if measureTracks(for: selectionPropertyChangeCommand.change)
                || selectBlockInstance(for: selectionPropertyChangeCommand.change) {
                return
            }
            if !isReadOnly {
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
        .onChange(of: placeDecalRequest?.id) { _, _ in
            takeUpPlaceDecalRequest()
        }
        .onChange(of: isReadOnly) { _, readOnly in
            if readOnly {
                cancelDrawGraphics()
                cancelDrawTrack()
                cancelMove()
                endTune()
            }
        }
        return tracksRoute(canvas)
    }

    /// The route tool's upkeep, kept out of `body`'s one expression, which
    /// is already as long as the type checker takes: the inspector fed as the
    /// route goes, and the route given a new width when the rules, the custom
    /// width or the layer change under it.
    private func tracksRoute<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: drawTrackState == nil) { _, ended in
                if ended {
                    routeInspector?.endRoute()
                } else if let state = drawTrackState {
                    routeInspector?.beginRoute(on: state.originalBoard)
                    publishRouteInspector()
                }
            }
            .onChange(of: routeInspectorSignature) { _, _ in
                publishRouteInspector()
            }
            // The tune tool's inspector, and its meander worked out again when
            // the settings or the target change under it.
            .onChange(of: tuneState == nil) { _, ended in
                if ended {
                    routeInspector?.endRoute()
                }
            }
            .onChange(of: tuneInspectorState) { _, state in
                if let state {
                    routeInspector?.updateTune(state)
                }
            }
            .onChange(of: TuneInputs(settings: toolSettings.meanderSettings, target: tuneTarget)) { _, inputs in
                if var state = tuneState, state.hasStarted {
                    state.update(target: inputs.target, settings: inputs.settings)
                    tuneState = state
                }
            }
            .onChange(of: rulesRevision) { _, _ in
                adoptBoardRules()
            }
            .onChange(of: rulesShapeRevision) { _, _ in
                // The board drawn is the host's: what applying the rules
                // changed in it is drawn again.
                metalSceneRevision &+= 1
                invalidateSelectableCache()
            }
            .onChange(of: toolSettings.explicitTrackWidth) { _, width in
                takeExplicitTrackWidth(width)
            }
            // The inspector's corner style and Route around reach the route
            // under way, as C does.
            .onChange(of: toolSettings.cornerStyle) { _, style in
                guard var state = drawTrackState, state.cornerStyle != style else { return }
                state.cornerStyle = style
                drawTrackState = state
            }
            .onChange(of: toolSettings.routerMode) { _, routes in
                guard drawTrackState != nil else { return }
                trackRouterSession = routes ? HorizontalBoardTrackRouterSession(board: board) : nil
                pushShovePreviewSpecs = []
            }
            .onChange(of: routeWidthCommand?.id) { _, _ in
                if routeWidthCommand != nil {
                    useRuleTrackWidth()
                }
            }
            .onChange(of: drawingLayer) { _, layer in
                moveUnstartedRoute(to: layer)
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
                    bounds: viewport.measuringBounds(for: board.uuid, contentBounds: board.bounds),
                    size: proxy.size,
                    fitInsets: boardCanvasFitInsets(safeArea: proxy.safeAreaInsets),
                    zoom: viewport.zoom,
                    pan: viewport.pan,
                    mirrored: viewport.mirrored
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
    /// instant an inline edit or the plane editor begins (so the anchor is
    /// fresh even when the viewport hasn't changed since the last report).
    private var inlineTextEditorReportTrigger: AnyHashable? {
        if let planeEditorState {
            return AnyHashable("plane:\(planeEditorState.worldPosition.x),\(planeEditorState.worldPosition.y)")
        }
        #if os(macOS)
        return editingTextState.map { AnyHashable($0.ref) }
        #else
        return nil
        #endif
    }

    /// The plane editor: on macOS a 1pt anchor at the polygon under the
    /// cursor hosts the popover, the same way the inline text editor is
    /// placed; on iOS the editor is a sheet.
    @ViewBuilder
    private var planeEditorOverlay: some View {
        #if os(macOS)
        GeometryReader { proxy in
            if let state = planeEditorState {
                let transform = canvasDisplayTransform ?? HorizontalCanvasTransform(
                    bounds: viewport.measuringBounds(for: board.uuid, contentBounds: board.bounds),
                    size: proxy.size,
                    fitInsets: boardCanvasFitInsets(safeArea: proxy.safeAreaInsets),
                    zoom: viewport.zoom,
                    pan: viewport.pan,
                    mirrored: viewport.mirrored
                )
                let anchor = transform.point(state.worldPosition)
                Color.clear
                    .frame(width: 1, height: 1)
                    .popover(isPresented: planeEditorPresented, arrowEdge: .top) {
                        HorizontalPlaneSettingsPopover(
                            title: planeEditorTitle(for: state.purpose),
                            confirmTitle: planeEditorConfirmTitle(for: state.purpose),
                            nets: sortedNetOptions(),
                            layerName: layerName(for: state.layer),
                            draft: state.draft,
                            ruleSettings: planeRuleSettings(layer: state.layer),
                            canDelete: { if case .edit = state.purpose { return true } else { return false } }(),
                            onConfirm: { confirmPlaneEditor($0) },
                            onDelete: { deletePlaneFromEditor() },
                            onCancel: { cancelPlaneEditor() }
                        )
                    }
                    .position(anchor)
            }
        }
        .allowsHitTesting(false)
        #else
        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: planeEditorPresented) {
                if let state = planeEditorState {
                    HorizontalPlaneSettingsPopover(
                        title: planeEditorTitle(for: state.purpose),
                        confirmTitle: planeEditorConfirmTitle(for: state.purpose),
                        nets: sortedNetOptions(),
                        layerName: layerName(for: state.layer),
                        draft: state.draft,
                        ruleSettings: planeRuleSettings(layer: state.layer),
                        canDelete: { if case .edit = state.purpose { return true } else { return false } }(),
                        onConfirm: { confirmPlaneEditor($0) },
                        onDelete: { deletePlaneFromEditor() },
                        onCancel: { cancelPlaneEditor() }
                    )
                }
            }
        #endif
    }

    /// The settings the plane rules give a plane on a net, on `layer`, for
    /// the plane editor to show while the plane's settings are the rules'.
    private func planeRuleSettings(layer: Int?) -> (String?) -> HorizontalPlaneSettings {
        let rules = board.rules
        return { net in
            rules.planeSettings(net: net?.lowercased(), layer: layer ?? 10000)
        }
    }

    private var planeEditorPresented: Binding<Bool> {
        Binding(
            get: { planeEditorState != nil },
            set: { presented in
                if !presented {
                    cancelPlaneEditor()
                }
            }
        )
    }

    private func planeEditorTitle(for purpose: PlaneEditorState.Purpose) -> String {
        switch purpose {
        case .define: "Define Plane"
        case .edit: "Edit Plane"
        case .finishDrawing: "Draw Plane"
        }
    }

    private func planeEditorConfirmTitle(for purpose: PlaneEditorState.Purpose) -> String {
        switch purpose {
        case .define: "Define Plane"
        case .edit: "Apply"
        case .finishDrawing: "Create Plane"
        }
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
            textVariables: editingTextState.map { board.textVariables(forTextID: $0.ref).metadataItems } ?? [],
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
        hasher.combine(measureState != nil)
        hasher.combine(drawGraphicsState?.primitive.rawValue)
        hasher.combine(drawGraphicsState?.points.count ?? 0)
        hasher.combine(drawGraphicsState?.rectanglePlacementMode == .center)
        hasher.combine(drawTrackState != nil)
        hasher.combine(drawTrackState?.segmentCount ?? 0)
        hasher.combine(drawTrackState?.cornerStyle.rawValue)
        // The route's net, found by its first click, decides whether it has a via.
        hasher.combine(canToggleVia)
        hasher.combine(boardClipboard.isEmpty)
        hasher.combine(pastePlacementState != nil)
        hasher.combine(poolPlacementState != nil)
        // The Place Decal, net and hole padstack choosers coming up or going.
        hasher.combine(decalPickerIndex != nil)
        hasher.combine(netPickerPurpose != nil)
        hasher.combine(holePadstackChoices != nil)
        // Lock, Unlock and Unlock All, as the copper is (an undo too).
        hasher.combine(BoardCopperLock.commandSignature(selectedObjects, in: board))
        return hasher.finalize()
    }

    private func publishCanvasCommandActions() {
        onCanvasCommandActionsChange(canvasCommandActions())
    }

    private var hasMetalHighlightCandidates: Bool {
        guard hasActiveHighlight else {
            return false
        }
        let highlightedNetIDs = shownHighlightNetIDs

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
            || board.airwires.contains(where: { matches($0.netID) && displayOptions.showsAirwires(ofNet: $0.netID) }) {
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
        if let measureState {
            return measureState.statusText
        }
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
                    let start = toolSettings.startsOnCopper
                        ? "click a pad, track or via to start, ⌘-click anywhere"
                        : "click to start"
                    return "Autoroute \(kind) (\(layerName), \(widthMM) mm): \(start)   W width   Esc leaves the tool"
                }
                let viaHint = canToggleVia ? "   V via" : ""
                return "Autoroute \(kind) (\(layerName), \(widthMM) mm): click to route   / posture\(viaHint)   ⌫ back   Return, Esc or double-click finishes"
            }
            if state.anchor == nil {
                let start = toolSettings.startsOnCopper
                    ? "click a pad, track or via to start, ⌘-click anywhere"
                    : "click to start"
                return "Track (\(layerName), \(widthMM) mm): \(start)   W width   Esc leaves the tool"
            }
            let undoHint = trackRouteHistory.isEmpty ? "" : "   ⌫ back"
            // Horizon's tip says where an armed via's shape comes from.
            var viaHint = board.rules.viaRules.isEmpty
                ? "   V via (the board has no via rules)"
                : "   V via (no via rule for this net)"
            var viaArmed = ""
            if let via = routeVia(netID: state.netID) {
                viaHint = state.placesVia ? "   V no via   double-click ends at the via, on this layer" : "   V via"
                if state.placesVia {
                    let diameter = String(format: "%g", via.diameter / 1_000_000)
                    let hole = String(format: "%g", via.holeDiameter / 1_000_000)
                    viaArmed = ", via \(diameter)/\(hole) mm\(via.fromRules ? " from rules" : "")"
                }
            }
            return "Track (\(layerName), \(widthMM) mm, \(state.cornerStyle.label)\(viaArmed)): click to route   / posture   C corner (45/90/arc)   W width\(viaHint)\(undoHint)   Return, Esc or double-click finishes"
        }
        // Ahead of the move hint: placing a package rides the move tool.
        if let state = packagePlacementState {
            let label = board.packages.first { normalizedID($0.id) == normalizedID(state.placementID) }?.label ?? "package"
            return "Place \(label): click places   R rotates   E flips to the other side   Esc cancels"
        }
        if let drag = moveState?.copperDrag {
            return "\(drag.actionName): click or Return commits   Esc cancels"
        }
        if moveState != nil {
            return "Move: click or Return commits   Esc cancels"
        }
        if let state = poolPlacementState {
            switch state.kind {
            case .pad(let pad, _):
                return "Place pad \(pad.name): click places   R rotates   E mirrors   Esc ends"
            case .shape(let shape):
                return "Place \(shape.form.displayName.lowercased()) shape: click places   R rotates   Esc ends"
            case .hole(let hole):
                // A board hole is named for its padstack.
                let padstack = hole.padstackID.flatMap { id in
                    poolURL.flatMap { HorizontalPoolPadstacks.padstackName(id: id, poolURL: $0) }
                }
                let what = padstack.map { "hole (\($0))" } ?? "\(hole.shape == .slot ? "slot" : "round") hole"
                return "Place \(what): click places   R rotates   Esc ends"
            case .decal(let placement, _):
                let scale = placement.scale == 1 ? "" : String(format: ", scale %g", placement.scale)
                return "Place decal \(placement.name)\(scale): click places   R rotates   E flips to the other side   S sets the scale   Esc cancels"
            case .via(let via, let netID):
                let diameter = String(format: "%g", via.diameter / 1_000_000)
                let hole = String(format: "%g", via.holeDiameter / 1_000_000)
                let net = netDisplayName(netID) ?? shortID(netID)
                return "Place via (\(net), \(diameter)/\(hole) mm\(via.fromRules ? " from rules" : "")): click places   Esc ends"
            }
        }
        if let tuneState {
            return tuneState.hint
        }
        if let state = addVertexState {
            let placed = state.placedCount == 1 ? "1 vertex" : "\(state.placedCount) vertices"
            return "Add vertex (\(placed) added): click adds it and the next   Return, Esc or double-click ends"
        }
        if let state = roundOffVertexState {
            let radiusMM = String(format: "%.3f", state.clampedRadius / 1_000_000)
            if state.adjustsRounding {
                let radius = state.isSharp ? "sharp" : "radius \(radiusMM) mm"
                return "Adjust rounding (\(radius)): click sets the radius, at the corner it goes sharp   E flips the arc   Return enters a radius   Esc cancels"
            }
            return "Round off vertex (radius \(radiusMM) mm): click sets the radius   E flips the arc   Return enters a radius   Esc cancels"
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

        // A dimension's points and label are one dimension to the inspector.
        var listedDimensions = Set<String>()
        let items = selectedObjects
            .filter { $0.type != .dimension || listedDimensions.insert(normalizedID($0.id)).inserted }
            .compactMap(selectionDetailItem)
        let groups = Dictionary(grouping: items, by: { $0.ref.type })
            .map { type, items in
                var group = HorizontalSelectionDetailGroup(
                    type: type,
                    title: displayName(for: type),
                    pluralTitle: pluralDisplayName(for: type),
                    items: items
                )
                if type == .track {
                    addTrackSummary(to: &group)
                }
                if type == .boardPackage {
                    addBlockInstanceSummary(to: &group)
                }
                return group
            }
            .sorted { $0.title < $1.title }
        return HorizontalSelectionDetailState(hovered: nil, groups: groups)
    }

    /// Horizon's track HUD over the selected tracks as a whole: their total
    /// length, the spacing of two parallel ones, their net's routed length
    /// and its skew against its diff pair partner; with Measure and Measure
    /// All, which add them to the Length Tuning window.
    private func addTrackSummary(to group: inout HorizontalSelectionDetailGroup) {
        let ids = Set(group.items.map { normalizedID($0.ref.id) })
        let selected = board.tracks.filter { ids.contains(normalizedID($0.id)) }
        guard let summary = HorizontalTrackSelectionSummary(selected: selected, board: board.tracks, netDetails: board.netDetails) else {
            return
        }
        group.summary = summary.details(
            layerName: { layerName(for: $0) },
            netName: { netDisplayName($0) ?? shortID($0) }
        )
        if onMeasureTracks != nil {
            group.actions = HorizontalTrackSelectionSummary.measureActions
        }
    }

    /// The block instances the selected packages are parts of: which, the
    /// instances laid out like it and what differs, with Select Instance.
    private func addBlockInstanceSummary(to group: inout HorizontalSelectionDetailGroup) {
        guard let match = blockLayoutMatch else {
            return
        }
        let instances = HorizontalBlockInstanceSummary.instances(ofPackages: group.items.map(\.ref.id), in: match)
        guard !instances.isEmpty else {
            return
        }
        group.summary = HorizontalBlockInstanceSummary.details(for: instances, in: match)
        if instances.count == 1 {
            group.properties = HorizontalBlockInstanceSummary.placementProperties(for: instances[0], in: match)
        }
        group.actions = HorizontalBlockInstanceSummary.actions(canCopyLayout: !isReadOnly && instances.count == 1)
    }

    /// Which instances of the design's blocks are laid out alike on the
    /// board as it is, made again only when it changes.
    private var blockLayoutMatch: HorizontalBlockLayoutMatch? {
        guard let blockInstances, !blockInstances.isEmpty else {
            return nil
        }
        let current = board
        let key = BoardBlockLayoutCache.Key(
            boardID: current.uuid,
            revision: selectableCacheRevision,
            counts: boardGeometryCounts(for: current),
            packageCount: current.packages.count
        )
        return blockLayoutCache.match(key: key) {
            HorizontalBlockLayoutMatch(board: current, instances: blockInstances)
        }
    }

    /// Select Instance: the selected packages' instances, their parts and
    /// their own copper, so they move as one. Selecting changes nothing, so
    /// a locked board selects too.
    private func selectBlockInstance(for change: HorizontalSelectionPropertyChange) -> Bool {
        guard change.propertyID == HorizontalBlockInstanceSummary.selectActionID else {
            return false
        }
        selectBlockInstances()
        return true
    }

    /// The block instances the selected packages are parts of, innermost.
    private var selectedBlockInstances: [HorizontalBoardBlockInstances.Instance] {
        guard let match = blockLayoutMatch else {
            return []
        }
        let packages = selectedObjects.filter { $0.type == .boardPackage }.map(\.id)
        return packages.isEmpty ? [] : HorizontalBlockInstanceSummary.instances(ofPackages: packages, in: match)
    }

    /// Copy Layout to Other Instances: the selected part's instance laid out
    /// in every other instance of its block, as one undo step. Their own
    /// copper gives way to its copper; what isn't theirs stays.
    private func copyBlockLayoutToOtherInstances() {
        guard !isReadOnly, moveState == nil, pastePlacementState == nil, drawTrackState == nil,
              let blockInstances, let source = selectedBlockInstances.first, selectedBlockInstances.count == 1 else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        let targets = blockInstances.siblings(of: source).map(\.path)
        let changes = HorizontalBlockLayoutSync.copyLayout(from: source.path, to: targets, board: previous, instances: blockInstances)
        guard !changes.isEmpty else {
            return
        }
        var draft = previous
        let report = HorizontalBlockLayoutSync.apply(changes, to: &draft, poolURL: poolURL)
        registerUndoSnapshot(previous, actionName: "Copy Block Layout")
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft)
        showBlockSyncNote(report, lead: "Copied \(source.name)'s layout to")
    }

    /// Instance X, Y, angle and flipped: the selected parts' instance moved,
    /// turned or flipped whole, its parts and its own copper, about its
    /// anchor, so the anchor takes the value; one undo step. Moved whole,
    /// the instance is no edit for the others to follow
    /// (`HorizontalBlockLayoutSync`). The selection stays as it was.
    private func placeBlockInstance(_ change: HorizontalSelectionPropertyChange) {
        guard !isReadOnly, moveState == nil, pastePlacementState == nil, drawTrackState == nil,
              let match = blockLayoutMatch, selectedBlockInstances.count == 1, let instance = selectedBlockInstances.first,
              let anchor = match.anchor(of: instance.path),
              match.layouts[instance.path]?.packages.values.contains(where: { $0.fixed }) == false else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        guard let package = previous.packages.first(where: { normalizedID($0.id) == normalizedID(anchor.package.id) }) else {
            return
        }
        let parts = HorizontalBlockInstanceSummary.parts(of: instance, in: match, board: previous)
        guard !parts.isEmpty else {
            return
        }
        // What the edit does to the instance; nothing where the anchor
        // already has the value.
        let edit: (actionName: String, apply: (inout HorizontalBoard) -> Void)
        switch (change.propertyID, change.value) {
        case (HorizontalBlockInstanceSummary.positionXPropertyID, .length(let x)) where x != package.position.x:
            edit = ("Move Instance", { moveSelectedObjects(by: HorizontalPoint(x: x - package.position.x, y: 0), board: &$0) })
        case (HorizontalBlockInstanceSummary.positionYPropertyID, .length(let y)) where y != package.position.y:
            edit = ("Move Instance", { moveSelectedObjects(by: HorizontalPoint(x: 0, y: y - package.position.y), board: &$0) })
        case (HorizontalBlockInstanceSummary.anglePropertyID, .angle(let angle))
            where wrappedAngle(angle) != wrappedAngle(package.angle):
            let turn = wrappedAngle(angle) - wrappedAngle(package.angle)
            edit = ("Rotate Instance", { rotateSelectedObjects(around: package.position, by: turn, board: &$0) })
        case (HorizontalBlockInstanceSummary.flippedPropertyID, .bool(let on)) where on != package.mirrored:
            edit = ("Flip Instance", { mirrorSelectedObjects(around: package.position, board: &$0) })
        default:
            return
        }
        var draft = previous
        // The move, turn and flip act on the selection.
        let kept = selectedObjects
        selectedObjects = parts
        edit.apply(&draft)
        selectedObjects = kept
        let actionName = edit.actionName
        registerUndoSnapshot(previous, actionName: actionName)
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previous, kind: .transform))
        publishSelectionContext()
    }

    /// The anchor of the instance the selection is, whole
    /// (`HorizontalBlockInstanceSummary.wholeInstance`), where it is on
    /// `board`: what R and E turn and flip it about.
    private func selectedInstanceAnchor(in board: HorizontalBoard) -> HorizontalPoint? {
        guard let match = blockLayoutMatch else {
            return nil
        }
        let packages = selectedObjects.filter { $0.type == .boardPackage }.map(\.id)
        guard let instance = HorizontalBlockInstanceSummary.wholeInstance(selectedPackages: packages, in: match),
              let anchor = match.anchor(of: instance.path) else {
            return nil
        }
        let id = normalizedID(anchor.package.id)
        return board.packages.first { normalizedID($0.id) == id }?.position
    }

    /// The mark on the anchor of the block instance the selection is, whole:
    /// a cross on a halo, a fixed size on screen, at the point Instance X and
    /// Y place. None while something is being moved or placed, which would
    /// leave it behind.
    func blockInstanceAnchorMark() -> (rects: [HorizontalMetalAnchoredRectPrimitive], key: Int) {
        guard moveState == nil, pastePlacementState == nil, packagePlacementState == nil, poolPlacementState == nil,
              let anchor = selectedInstanceAnchor(in: board) else {
            return ([], 0)
        }
        let halo = HorizontalMetalRGBA(theme.background.opacity(0.9))
        let cross = HorizontalMetalRGBA(theme.selectableOuter.opacity(0.95))
        let rects = [
            HorizontalMetalAnchoredRectPrimitive(center: anchor, color: halo, width: 26, height: 6),
            HorizontalMetalAnchoredRectPrimitive(center: anchor, color: halo, width: 6, height: 26),
            HorizontalMetalAnchoredRectPrimitive(center: anchor, color: cross, width: 22, height: 2),
            HorizontalMetalAnchoredRectPrimitive(center: anchor, color: cross, width: 2, height: 22),
        ]
        var hasher = Hasher()
        hasher.combine(rects)
        return (rects, hasher.finalize())
    }

    private func selectBlockInstances() {
        guard moveState == nil, pastePlacementState == nil, let match = blockLayoutMatch else {
            return
        }
        let packages = selectedObjects.filter { $0.type == .boardPackage }.map(\.id)
        let instances = HorizontalBlockInstanceSummary.instances(ofPackages: packages, in: match)
        let refs = HorizontalBlockInstanceSummary.selection(of: instances, in: match, from: boardSelectableScene().refs())
        guard !refs.isEmpty else {
            return
        }
        selectedObjects = refs
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        publishSelectionContext()
    }

    private var selectedNetID: String? {
        selectedNetIDs.first
    }

    private var selectedNetIDs: Set<String> {
        let netID = netIDLookup(for: selectedObjects)
        return Set(selectedObjects.compactMap { netID($0).map(normalizedID) })
    }

    private var selectedComponentIDs: Set<String> {
        // Asked for on every body pass (the cross-selection boxes); with
        // Select All's thousands of refs, kept while they and the packages
        // are what they were.
        var ids = selectableCache.contentMemo.value(
            "selected component ids",
            input: BoardContentPair(selectedObjects, board.packages.map(\.componentID))
        ) {
            let componentID = componentIDLookup(for: selectedObjects)
            return Set(selectedObjects.compactMap { componentID($0).map(normalizedID) })
        }
        if let selectedUnplacedObject,
           let componentID = selectedUnplacedObject.componentID.map(normalizedID) {
            ids.insert(componentID)
        }
        return ids
    }

    /// The blue boxes round `crossSelectedComponentIDs`, the parts another
    /// view selected, but not round any this canvas has selected itself,
    /// which its own selection marks: the outline a selection takes, as far
    /// out from the part (a few points, whatever the zoom), in the 3D view's
    /// selection blue, and a key for them.
    func crossSelectionLines() -> (lines: [HorizontalMetalLinePrimitive], key: Int) {
        let wanted = Set(crossSelectedComponentIDs.map(normalizedID)).subtracting(selectedComponentIDs)
        guard !wanted.isEmpty else {
            return ([], 0)
        }
        let selectables = boardSelectablesByRef()
        let refs = board.packages.compactMap { package -> HorizontalSelectableRef? in
            guard let componentID = package.componentID, wanted.contains(normalizedID(componentID)) else {
                return nil
            }
            return HorizontalSelectableRef(id: package.id, type: .boardPackage)
        }
        return HorizontalCanvasModeSupport.crossSelectionLines(for: refs.flatMap { selectables[$0] ?? [] })
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
            properties: selectionProperties(for: ref),
            openSections: [Self.planeSection, Self.keepoutSection]
        )
    }

    private func selectionDetailItem(for object: HorizontalUnplacedObject) -> HorizontalSelectionDetailItem {
        HorizontalSelectionDetailItem(
            ref: HorizontalSelectableRef(id: object.id, type: .boardPackage),
            title: object.label,
            subtitle: object.subtitle,
            details: componentDetailRows(object.details),
            properties: [
                readOnlyProperty("state", "State", "Unplaced"),
                readOnlyProperty("kind", "Kind", object.subtitle),
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
                title: nonEmpty(package.label) ?? "Board package",
                subtitle: "\(nonEmpty(package.componentDetails?.packageName) ?? "Board package") on \(side)",
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
            if modeProfile.mode == .package {
                return poolPadHUDItem(for: ref)
            }
            guard let pad = board.packagePads.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Pad \(padLabel(for: pad))",
                subtitle: hudSubtitle(netDisplayName(pad.netID), layerName(for: pad.layer)),
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
                subtitle: hudSubtitle(netDisplayName(via.netID), diameterString(via.size)),
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
                subtitle: hudSubtitle(netDisplayName(plane.netID) ?? "No net", layerName(for: plane.layer)),
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
                subtitle: hudSubtitle(
                    keepout.keepoutClass,
                    keepout.allCopperLayers ? "All copper" : layerName(for: keepout.polygon.layer)
                ),
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
            return HorizontalSelectionHUDItem(title: nonEmpty(decal.name) ?? "Board decal", subtitle: "")
        case .boardPanel:
            guard let panel = board.boardPanels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(title: nonEmpty(panel.boardName) ?? "Board panel", subtitle: "")
        case .text:
            guard let text = (board.texts + board.packageTexts).first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: nonEmpty(text.text) ?? "Text",
                subtitle: hudSubtitle(netDisplayName(text.netID), layerName(for: text.layer)),
                details: netDetailRows(text.netID) + [
                    detailRow("Layer", layerName(for: text.layer)),
                    detailRow("Size", lengthString(text.size)),
                ].compactMap { $0 }
            )
        case .padstackShape:
            return padstackShapeHUDItem(for: ref)
        case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return genericHUDItem(for: ref)
        }
    }

    /// `segments`' segment `id`, from an index of them by id kept while they
    /// are unchanged: the inspector asks for each of Select All's thousands
    /// of tracks, and a search of all of them for each made it quadratic.
    private func segment(_ id: String, in segments: [HorizontalSegment], _ name: String) -> HorizontalSegment? {
        selectableCache.contentMemo.value("segments by id: \(name)", input: segments) {
            var index = [String: HorizontalSegment](minimumCapacity: segments.count)
            for segment in segments where index[normalizedID(segment.id)] == nil {
                index[normalizedID(segment.id)] = segment
            }
            return index
        }[normalizedID(id)]
    }

    private func segmentHUDItem(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        title: String
    ) -> HorizontalSelectionHUDItem {
        guard let segment = segment(ref.id, in: segments, title) else {
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
            subtitle: hudSubtitle(netDisplayName(segment.netID), layerName(for: segment.layer), lengthString(segment.length)),
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
            subtitle: hudSubtitle(netDisplayName(arc.netID), layerName(for: arc.layer), lengthString(arc.length)),
            details: netDetailRows(arc.netID) + [
                detailRow("Layer", layerName(for: arc.layer)),
                detailRow("Radius", lengthString(arc.radius)),
                detailRow("Length", lengthString(arc.length)),
                detailRow("Width", arc.width > 0 ? lengthString(arc.width) : nil),
            ].compactMap { $0 }
        )
    }

    /// A polygon's part is told apart by its layer and, for a plane's polygon,
    /// the plane's net, as Horizon's "Polygon edge Plane: GND (Top Copper)":
    /// the plane, not its polygon, carries the net.
    private func polygonHUDItem(for ref: HorizontalSelectableRef, title: String) -> HorizontalSelectionHUDItem {
        guard let polygon = boardPolygon(for: ref.id, in: board) else {
            return genericHUDItem(for: ref)
        }

        let plane = board.planes.first { normalizedID($0.polygonID) == normalizedID(polygon.id) }
        let netID = plane?.netID ?? polygon.netID
        let keepout = plane == nil ? keepoutBackedByPolygon(polygon.id, in: board) : nil
        let net = plane.map { "Plane \(netDisplayName($0.netID) ?? "with no net")" }
            ?? keepout.map { _ in "Keepout" }
            ?? netDisplayName(polygon.netID)
        return HorizontalSelectionHUDItem(
            title: title,
            subtitle: hudSubtitle(net, layerName(for: polygon.layer)),
            details: netDetailRows(netID) + [
                detailRow("Layer", layerName(for: polygon.layer)),
                detailRow("Area", areaString(polygon.area)),
            ].compactMap { $0 }
        )
    }

    /// The parts of a HUD subtitle that apply, which the which-object menu
    /// shows after the title. Never an object's id: it tells the user nothing.
    private func hudSubtitle(_ parts: String?...) -> String {
        parts.compactMap { nonEmpty($0) }.joined(separator: " - ")
    }

    private func boardPolygon(for id: String, in board: HorizontalBoard) -> HorizontalPolygon? {
        let normalizedPolygonID = normalizedID(id)
        return board.polygons.first { normalizedID($0.id) == normalizedPolygonID }
            ?? board.outlinePolygons.first { normalizedID($0.id) == normalizedPolygonID }
    }

    private func genericHUDItem(for ref: HorizontalSelectableRef) -> HorizontalSelectionHUDItem {
        HorizontalSelectionHUDItem(title: displayName(for: ref.type), subtitle: "")
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
            detailRow("MPN", component.mpn, poolSearch: .part),
            detailRow("Manufacturer", component.manufacturer, poolSearch: .part),
            detailRow("Package", component.packageName, poolSearch: .package),
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

    /// `poolSearch`: the value doubles as a link that filters that category
    /// of the Pools pane to it.
    private func detailRow(
        _ label: String,
        _ value: String?,
        poolSearch category: HorizontalPoolItemCategory? = nil
    ) -> HorizontalSelectionHUDDetail? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        return HorizontalSelectionHUDDetail(
            label: label,
            value: value,
            poolSearch: category.map { HorizontalPoolSearch(category: $0, term: value) }
        )
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
            return viaProperties(via)
        case .boardHole:
            guard let hole = hole(for: ref.id) else {
                return []
            }
            var properties = [
                readOnlyProperty("name", "Net", netDisplayName(hole.netID)),
                editableNetClassProperty(for: hole.netID),
                modeProfile.mode == .padstack
                    ? editableChoiceProperty(
                        "shape",
                        "Shape",
                        value: hole.shape.rawValue,
                        options: [
                            HorizontalSelectionPropertyOption(id: "round", title: "Round"),
                            HorizontalSelectionPropertyOption(id: "slot", title: "Slot"),
                        ]
                    )
                    : readOnlyProperty("shape", "Shape", hole.shape.rawValue.capitalized),
                modeProfile.mode == .padstack
                    ? editableTextProperty("parameterClass", "Parameter class", hole.parameterClass)
                    : nil,
                hole.padstackID != nil
                    ? padstackProperty(for: hole.padstackID, types: ["hole", "mechanical"])
                    : nil,
                editableLengthProperty("diameter", "Diameter", hole.diameter),
                hole.shape == .slot ? editableLengthProperty("length", "Length", hole.effectiveLength) : nil,
                // Plating comes from the padstack for padstack-backed holes, so
                // only plain holes offer the toggle.
                hole.padstackID == nil
                    ? editableBoolProperty("plated", "Plated", hole.plated)
                    : readOnlyProperty("plated", "Plated", hole.plated ? "Yes" : "No"),
            ].compactMap { $0 }
            properties.append(contentsOf: extraParameterProperties(
                parameterSet: hole.parameterSet,
                padstackID: hole.padstackID,
                excluding: ["hole_diameter", "hole_length"]
            ))
            if hole.padstackID != nil,
               let addParameter = addParameterProperty(
                   existing: Set(hole.parameterSet.keys).union(["hole_diameter", "hole_length"])
               ) {
                properties.append(addParameter)
            }
            properties.append(contentsOf: [
                editableLengthProperty("positionX", "Position X", hole.position.x),
                editableLengthProperty("positionY", "Position Y", hole.position.y),
            ])
            return properties
        case .plane:
            guard let plane = board.planes.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableNetClassProperty(for: plane.netID),
                editableLayerProperty("layer", "Layer", plane.layer, copperOnly: true),
            ].compactMap { $0 } + planeSettingsProperties(plane, prefix: "", section: nil)
        case .keepout:
            guard let keepout = board.keepouts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return keepoutProperties(keepout, prefix: "", section: nil)
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
            let plane = planeBackedByPolygon(polygon.id, in: board)
            let keepout = keepoutBackedByPolygon(polygon.id, in: board)
            return [
                readOnlyProperty("net", "Net", netDisplayName(polygon.netID)),
                editableNetClassProperty(for: polygon.netID),
                editableLayerProperty("layer", "Layer", polygon.layer, copperOnly: plane != nil),
                modeProfile.isPoolMode
                    ? editableTextProperty("parameterClass", "Parameter class", polygon.parameterClass)
                    : readOnlyProperty("usage", "Usage", plane != nil ? "Plane" : keepout != nil ? "Keepout" : "Polygon"),
                readOnlyProperty("area", "Area", areaString(polygon.area)),
            ].compactMap { $0 } + polygonUsageProperties(for: polygon, plane: plane, keepout: keepout)
        case .pad:
            if modeProfile.mode == .package {
                return poolPadProperties(for: ref)
            }
            guard let pad = board.packagePads.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("name", "Name", padLabel(for: pad)),
                readOnlyProperty("value", "Padstack", pad.metadata["Padstack"]),
                readOnlyProperty("padType", "Pad type", pad.metadata["Pad type"]),
                readOnlyProperty("net", "Net", netDisplayName(pad.netID)),
                editableNetClassProperty(for: pad.netID),
                diffpairProperty(for: pad.netID),
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
        case .padstackShape:
            return padstackShapeProperties(for: ref)
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
        guard let segment = segment(ref.id, in: segments, "\(ref.type)") else {
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
        ].compactMap { $0 }
        if editable, modeProfile.mode == .board, let locked = BoardCopperLockCommands.lockedProperty(ref, locked: segment.locked) {
            properties.append(locked)
        }
        // A track's or net tie's width is the track width rule's or its own
        // (Horizon's width_from_rules), and the rule says what it would be.
        if editable, includesNetClass {
            properties.append(HorizontalSelectionProperty(
                id: "widthSource", label: "Width from", editor: .segmented(Self.ruleSourceOptions),
                value: .choice(segment.widthFromRules ? "rules" : "custom")))
            if let layer = segment.layer, let rule = board.rules.trackWidth(net: segment.netID, layer: layer) {
                let brief = HorizontalRouteRuleNames(netDetails: board.netDetails, netClasses: netClasses).match(rule.rule.match)
                if let ruleProperty = readOnlyProperty("widthRule", "Rule", "\(brief) · \(lengthString(rule.widths.def))") {
                    properties.append(ruleProperty)
                }
            } else if let noRule = readOnlyProperty("widthRule", "Rule", "No track width rule takes this net") {
                properties.append(noRule)
            }
        }
        if includesNetClass, let netClass = editableNetClassProperty(for: segment.netID) {
            properties.append(netClass)
        }
        if includesNetClass, let diffpair = diffpairProperty(for: segment.netID) {
            properties.append(diffpair)
        }
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
        // What the file stores, "$rev" rather than the revision it draws.
        var textProperty = editableTextProperty("text", "Text", text.editableText, multiline: true)
        textProperty.textVariables = board.textVariables(forTextID: text.id).metadataItems
        return [
            textProperty,
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

    /// Where a value comes from: the rules, or the object's own.
    private static let ruleSourceOptions = [
        HorizontalSelectionPropertyOption(id: "rules", title: "Rules"),
        HorizontalSelectionPropertyOption(id: "custom", title: "Custom"),
    ]

    // MARK: - Plane and keepout definitions in the sidebar

    static let planeSection = "Plane"
    static let keepoutSection = "Keepout"
    static let definePlaneActionID = "definePlane"
    static let defineKeepoutActionID = "defineKeepout"
    static let deletePlaneActionID = "deletePlaneDefinition"
    static let deleteKeepoutActionID = "deleteKeepoutDefinition"
    /// A plane setting shown on its outline's polygon is the plane's
    /// property of the same id, prefixed so it reaches the plane.
    static let planePropertyPrefix = "plane."
    /// So is a keepout's, in its polygon's Keepout section.
    static let keepoutPropertyPrefix = "keepout."
    static let keepoutPatchPrefix = "patch."
    /// The copper a keepout can keep out, as Horizon's keepout editor lists
    /// it: the file's names and what the sidebar calls them.
    static let keepoutPatchTypes: [(id: String, title: String)] = [
        ("track", "Tracks"), ("pad", "Pads"), ("pad_th", "TH pads"), ("via", "Vias"), ("plane", "Planes"),
        ("text", "Text"), ("net_tie", "Net ties"), ("hole_pth", "Plated holes"), ("hole_npth", "NPTH holes"),
    ]
    /// What a keepout defined here keeps out, as a package's keepout starts:
    /// the board's copper and its plated holes.
    static let defaultKeepoutPatchTypes = ["track", "pad", "pad_th", "via", "plane", "hole_pth"]

    private func actionProperty(_ id: String, _ title: String, section: String? = nil) -> HorizontalSelectionProperty {
        HorizontalSelectionProperty(id: id, label: title, editor: .action, value: .bool(true), section: section)
    }

    /// Under a board polygon's details, as Horizon's polygon offers them: the
    /// plane or the keepout it outlines, its settings in a section ending in
    /// Delete Plane or Delete Keepout Definition; else Define Plane… (on a
    /// board's copper) and Define Keepout…. A package's keepouts are its own
    /// polygons' too.
    private func polygonUsageProperties(
        for polygon: HorizontalPolygon,
        plane: HorizontalPlane?,
        keepout: HorizontalKeepout?
    ) -> [HorizontalSelectionProperty] {
        guard !normalizedID(polygon.id).contains("/") else {
            return []
        }
        if let plane, !modeProfile.isPoolMode {
            return planeSettingsProperties(plane, prefix: Self.planePropertyPrefix, section: Self.planeSection)
        }
        if let keepout {
            return keepoutProperties(keepout, prefix: Self.keepoutPropertyPrefix, section: Self.keepoutSection)
        }
        var actions = [HorizontalSelectionProperty]()
        if !modeProfile.isPoolMode, let layer = polygon.layer, HorizontalBoardLayers.isCopper(layer) {
            actions.append(actionProperty(Self.definePlaneActionID, "Define Plane…"))
        }
        if allowsKeepouts {
            actions.append(actionProperty(Self.defineKeepoutActionID, "Define Keepout…"))
        }
        return actions
    }

    /// A board's and a package's polygons can be keepouts, as Horizon's can.
    private var allowsKeepouts: Bool {
        modeProfile.mode == .board || modeProfile.mode == .package
    }

    /// A plane's settings, as Horizon's plane editor has them, ending in
    /// Delete Plane Definition: in the Plane section of its outline's details,
    /// their ids prefixed to reach the plane, or the plane's own. Those of a
    /// thermal and of a hatch show only when it connects by thermals and
    /// fills with a hatch.
    private func planeSettingsProperties(_ plane: HorizontalPlane, prefix: String, section: String?) -> [HorizontalSelectionProperty] {
        let settings = plane.settings
        let thermal = settings.thermalSettings
        let netOptions = sortedNetOptions()
        let netValue = plane.netID.map(normalizedID)
        func option(_ id: String, _ title: String) -> HorizontalSelectionPropertyOption {
            HorizontalSelectionPropertyOption(id: id, title: title)
        }
        var properties: [HorizontalSelectionProperty?] = [
            netOptions.isEmpty || netValue == nil
                ? readOnlyProperty("name", "Net", netDisplayName(plane.netID))
                : editableChoiceProperty("net", "Net", value: netValue ?? "", options: netOptions),
            editableChoiceProperty(
                "priority", "Fill order", value: String(plane.priority),
                options: (0...20).map { option(String($0), String($0)) }
            ),
            HorizontalSelectionProperty(
                id: "fromRules", label: "Settings from", editor: .segmented(Self.ruleSourceOptions),
                value: .choice(plane.fromRules ? "rules" : "custom")),
            editableLengthProperty("minWidth", "Min width", Double(settings.minWidth)),
            editableChoiceProperty("style", "Style", value: Self.planeStyleID(settings.style),
                                   options: [option("round", "Round"), option("square", "Bevel"), option("miter", "Sharp")]),
            editableBoolProperty("keepOrphans", "Keep orphans", settings.keepOrphans),
            editableChoiceProperty("textStyle", "Text style", value: settings.textStyle == .bbox ? "bbox" : "expand",
                                   options: [option("expand", "Expand"), option("bbox", "Bounding box")]),
            editableChoiceProperty("connectStyle", "Connect style", value: thermal.connectStyle == .thermal ? "thermal" : "solid",
                                   options: [option("solid", "Solid"), option("thermal", "Thermal relief")]),
        ]
        if thermal.connectStyle == .thermal {
            properties += [
                editableLengthProperty("thermalGap", "Thermal gap", Double(thermal.thermalGapWidth)),
                editableLengthProperty("thermalSpoke", "Spoke width", Double(thermal.thermalSpokeWidth)),
                editableChoiceProperty("spokes", "Spokes", value: String(thermal.nSpokes),
                                       options: (1...8).map { option(String($0), String($0)) }),
                editableAngleProperty("spokeAngle", "Spoke angle", thermal.angle),
            ]
        }
        properties.append(editableChoiceProperty("fill", "Fill", value: planeFillStyleID(settings.fillStyle),
                                                 options: [option("solid", "Solid"), option("hatch", "Hatch")]))
        if settings.fillStyle == .hatch {
            properties += [
                editableLengthProperty("hatchBorder", "Hatch border", Double(settings.hatchBorderWidth)),
                editableLengthProperty("hatchLine", "Hatch line", Double(settings.hatchLineWidth)),
                editableLengthProperty("hatchSpacing", "Hatch spacing", Double(settings.hatchLineSpacing)),
            ]
        }
        let planeRows = properties.compactMap { $0 }.map { property -> HorizontalSelectionProperty in
            var property = property
            property.id = prefix + property.id
            property.section = section
            return property
        }
        return planeRows + [actionProperty(Self.deletePlaneActionID, "Delete Plane Definition", section: section)]
    }

    private static func planeStyleID(_ style: HorizontalPlaneSettings.Style) -> String {
        switch style {
        case .round: "round"
        case .square: "square"
        case .miter: "miter"
        }
    }

    /// A keepout's options, as Horizon's keepout editor has them, ending in
    /// Delete Keepout Definition, which leaves the polygon a polygon: its
    /// class, whether it is on all copper layers or its polygon's, whether
    /// only exposed copper, and what it keeps out. In the Keepout section of
    /// its polygon's details, their ids prefixed to reach the keepout, or the
    /// keepout's own.
    private func keepoutProperties(_ keepout: HorizontalKeepout, prefix: String, section: String?) -> [HorizontalSelectionProperty] {
        var properties: [HorizontalSelectionProperty?] = [
            editableTextProperty("keepoutClass", "Keepout class", keepout.keepoutClass),
            editableBoolProperty("allCopperLayers", "All copper layers", keepout.allCopperLayers),
            editableBoolProperty("exposedCopperOnly", "Exposed copper only", keepout.exposedCopperOnly),
        ]
        let keptOut = Set(keepout.copperPatchTypes.map { $0.lowercased() })
        for type in Self.keepoutPatchTypes {
            properties.append(editableBoolProperty(Self.keepoutPatchPrefix + type.id, type.title, keptOut.contains(type.id)))
        }
        let rows = properties.compactMap { $0 }.map { property -> HorizontalSelectionProperty in
            var property = property
            property.id = prefix + property.id
            property.section = section
            return property
        }
        return rows + [actionProperty(Self.deleteKeepoutActionID, "Delete Keepout Definition", section: section)]
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

    /// Horizon's Diffpair property, a choice of partner for a net the host
    /// can pair (`HorizontalDiffpairProperty`).
    private func diffpairProperty(for netID: String?) -> HorizontalSelectionProperty? {
        guard modeProfile.mode != .package, let netID else {
            return nil
        }
        let editable = !isReadOnly && onEditDiffpair?.canEdit(normalizedID(netID)) == true
        return HorizontalDiffpairProperty.property(for: netID, in: board.netDetails, editable: editable)
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

    /// Inspector rows for a via, mirroring Horizon's Edit Via dialog: identity
    /// (net, span), where the geometry comes from (rules / via definition /
    /// custom), the padstack, the parameter set, then position. Parameter rows
    /// stay editable in every mode; editing one takes local control of the via
    /// (see takeLocalViaControl).
    private func viaProperties(_ via: HorizontalMarker) -> [HorizontalSelectionProperty] {
        var properties = [
            (modeProfile.mode == .board && !isReadOnly
                ? BoardCopperLockCommands.viaNetProperty(via, in: board, options: { sortedNetOptions() }) : nil)
                ?? readOnlyProperty("name", "Net", netDisplayName(via.netID)),
            modeProfile.mode == .board
                ? BoardCopperLockCommands.lockedProperty(HorizontalSelectableRef(id: via.id, type: .via), locked: via.locked) : nil,
            editableNetClassProperty(for: via.netID),
            diffpairProperty(for: via.netID),
            readOnlyProperty("span", "Span", viaSpanName(via)),
        ].compactMap { $0 }

        var sourceOptions = [
            HorizontalSelectionPropertyOption(id: "rules", title: "Rules"),
            HorizontalSelectionPropertyOption(id: "local", title: "Custom"),
        ]
        if !board.viaDefinitions.isEmpty || via.definitionID != nil {
            sourceOptions.insert(
                HorizontalSelectionPropertyOption(id: "definition", title: "Definition"),
                at: 1
            )
        }
        let source = via.fromRules ? "rules" : (via.definitionID != nil ? "definition" : "local")
        properties.append(HorizontalSelectionProperty(
            id: "viaSource", label: "Shape from", editor: .segmented(sourceOptions), value: .choice(source)))

        if source == "definition", let definitionID = via.definitionID {
            var definitionOptions = board.viaDefinitions.map {
                HorizontalSelectionPropertyOption(id: $0.id, title: $0.name)
            }
            let current = normalizedID(definitionID)
            if !definitionOptions.contains(where: { $0.id == current }) {
                definitionOptions.append(
                    HorizontalSelectionPropertyOption(id: current, title: shortID(definitionID))
                )
            }
            properties.append(
                editableChoiceProperty("viaDefinition", "Definition", value: current, options: definitionOptions)
            )
        }

        properties.append(contentsOf: [
            padstackProperty(for: via.padstackID, types: ["via"]),
            editableLengthProperty("diameter", "Diameter", via.size),
            editableLengthProperty("holeDiameter", "Hole diameter", via.holeSize ?? 0),
        ].compactMap { $0 })

        properties.append(contentsOf: extraParameterProperties(
            parameterSet: via.parameterSet,
            padstackID: via.padstackID,
            excluding: ["via_diameter", "hole_diameter"]
        ))
        if let addParameter = addParameterProperty(
            existing: Set(via.parameterSet.keys).union(["via_diameter", "hole_diameter"])
        ) {
            properties.append(addParameter)
        }

        properties.append(contentsOf: [
            editableLengthProperty("positionX", "Position X", via.position.x),
            editableLengthProperty("positionY", "Position Y", via.position.y),
        ])
        return properties
    }

    /// A one-shot "Add parameter" picker, mirroring Horizon's ParameterSetEditor
    /// "+" button: choosing a parameter seeds it into the object's parameter
    /// set, after which it appears above as a regular editable row.
    private func addParameterProperty(existing: Set<String>) -> HorizontalSelectionProperty? {
        let available = Self.knownParameterDisplayNames.keys
            .filter { !existing.contains($0) }
            .sorted { Self.parameterDisplayName($0) < Self.parameterDisplayName($1) }
        guard !available.isEmpty else {
            return nil
        }
        let options = [HorizontalSelectionPropertyOption(id: "none", title: "Choose…")]
            + available.map { HorizontalSelectionPropertyOption(id: $0, title: Self.parameterDisplayName($0)) }
        return editableChoiceProperty("addParameter", "Add parameter", value: "none", options: options)
    }

    /// The starting value for a freshly added parameter: the padstack's own
    /// default when it declares one, else the same defaults Horizon's rules
    /// parameters use, else zero.
    private func seededParameterValue(_ key: String, padstackID: String?) -> Double {
        if let padstackID, let poolURL,
           let padstackJSON = HorizontalPoolPadstacks.padstack(id: padstackID, poolURL: poolURL),
           let value = padstackJSON.dictionary("parameter_set")?.double(key) {
            return value
        }
        switch key {
        case "solder_mask_expansion", "via_solder_mask_expansion", "hole_solder_mask_expansion":
            return 100_000
        case "courtyard_expansion":
            return 250_000
        default:
            return 0
        }
    }

    /// A "Padstack" row: a picker over the pool's padstacks of the given types
    /// when the pool offers alternatives, else the current padstack read-only.
    /// Nil when the object has no padstack reference at all (e.g. a via placed
    /// this session — the template padstack is attached at save).
    private func padstackProperty(
        for padstackID: String?,
        types: Set<String>
    ) -> HorizontalSelectionProperty? {
        guard let padstackID else {
            return nil
        }
        let currentID = normalizedID(padstackID)
        var options = poolURL
            .map { HorizontalPoolPadstacks.padstacks(ofTypes: types, poolURL: $0) }?
            .map { HorizontalSelectionPropertyOption(id: $0.id, title: $0.name) } ?? []
        // Read-only only when the pool catalog is unreachable; a pool with a
        // single via padstack still gets a working (one-entry) picker.
        let hasCatalog = !options.isEmpty
        if !options.contains(where: { $0.id == currentID }) {
            options.append(
                HorizontalSelectionPropertyOption(id: currentID, title: padstackDisplayName(padstackID))
            )
        }
        guard hasCatalog else {
            return readOnlyProperty("padstack", "Padstack", padstackDisplayName(padstackID))
        }
        return editableChoiceProperty("padstack", "Padstack", value: currentID, options: options)
    }

    private func padstackDisplayName(_ padstackID: String) -> String {
        poolURL.flatMap { HorizontalPoolPadstacks.padstackName(id: padstackID, poolURL: $0) }
            ?? shortID(padstackID)
    }

    /// Editable rows for every parameter beyond the dedicated diameter/hole
    /// rows: whatever the entry already carries, plus whatever the padstack
    /// declares as required (Horizon's "add parameter" affordance — a required
    /// parameter is always offered, seeded from the padstack's defaults).
    private func extraParameterProperties(
        parameterSet: [String: Double],
        padstackID: String?,
        excluding excluded: Set<String>
    ) -> [HorizontalSelectionProperty] {
        var keys = Set(parameterSet.keys)
        var required = Set<String>()
        var defaults = [String: Double]()
        if let padstackID, let poolURL,
           let padstackJSON = HorizontalPoolPadstacks.padstack(id: padstackID, poolURL: poolURL) {
            for case let key as String in padstackJSON["parameters_required"] as? [Any] ?? [] {
                required.insert(key)
            }
            keys.formUnion(required)
            for (key, value) in padstackJSON.dictionary("parameter_set") ?? [:] {
                defaults[key] = JSONHelper.doubleValue(value)
            }
        }
        return keys.subtracting(excluded).sorted().map { key in
            var property = editableLengthProperty(
                "param:\(key)",
                Self.parameterDisplayName(key),
                parameterSet[key] ?? defaults[key] ?? 0
            )
            // Only parameters the object actually carries can be removed, and
            // never ones the padstack requires — a required row without a
            // stored value is just the padstack default being offered.
            if parameterSet[key] != nil, !required.contains(key) {
                property.removeID = "removeParam:\(key)"
            }
            return property
        }
    }

    /// Horizon's display names for its built-in parameter IDs
    /// (parameter/set.cpp); unknown IDs (custom parameter classes) fall back to
    /// a humanized spelling of the key.
    static let knownParameterDisplayNames: [String: String] = [
        "pad_width": "Pad width",
        "pad_height": "Pad height",
        "pad_diameter": "Pad diameter",
        "solder_mask_expansion": "Solder mask expansion",
        "paste_mask_margin": "Paste mask margin",
        "hole_diameter": "Hole diameter",
        "hole_length": "Hole length",
        "via_diameter": "Via diameter",
        "hole_solder_mask_expansion": "Hole solder mask expansion",
        "via_solder_mask_expansion": "Via solder mask expansion",
        "courtyard_expansion": "Courtyard expansion",
        "corner_radius": "Corner radius",
    ]

    static func parameterDisplayName(_ key: String) -> String {
        if let name = knownParameterDisplayNames[key] {
            return name
        }
        let words = key.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
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
            if !modeProfile.allows(layer: layer) {
                return false
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
        var actions = canvasCommandHandlers().actions()
        // The live channel (docs/automation.md): what the canvas shows, and
        // framing a rectangle in it.
        actions.visibleWorldBounds = { liveCanvasTransform.transform?.visibleBounds }
        actions.drawnAirwires = { liveCanvasAirwires.drawn }
        actions.confirmPlaneEditor = { confirmPlaneEditor($0) }
        actions.deletePlaneInEditor = { deletePlaneFromEditor() }
        actions.cancelPlaneEditor = { cancelPlaneEditor() }
        actions.decalChoices = decalPickerIndex?.items(in: .decal)
        actions.chooseDecal = { item in
            guard decalPickerIndex != nil else {
                return
            }
            decalPickerIndex = nil
            beginPlaceDecal(item)
        }
        actions.netChoices = netPickerPurpose != nil ? sortedNetOptions() : nil
        actions.chooseNet = { chooseNet($0) }
        actions.holePadstackChoices = holePadstackChoices
        actions.chooseHolePadstack = { chooseHolePadstack($0) }
        actions.pickUnplacedObject = { id in
            guard let object = currentUnplacedObjects.first(where: { $0.id == id }) else {
                return
            }
            selectUnplacedObject(object)
        }
        actions.frameWorldRect = { rect in
            guard let transform = liveCanvasTransform.transform else {
                return
            }
            viewport = CanvasViewport.framing(rect, in: transform, identity: board.uuid)
        }
        actions.revealWorldRect = { rect, scale in
            guard let transform = liveCanvasTransform.transform,
                  let revealed = CanvasViewport.revealing(rect, in: transform, scale: scale, identity: board.uuid) else {
                return
            }
            viewport = revealed
        }
        actions.drawingScale = { liveCanvasTransform.transform?.length(1) }
        actions.zoomBy = { factor in
            guard let transform = liveCanvasTransform.transform, factor >= 0 else {
                return
            }
            if factor == 0 {
                // Fit: everything, seen from the side it was being seen from.
                viewport = CanvasViewport(mirrored: viewport.mirrored)
                return
            }
            viewport = CanvasViewport.framing(transform.visibleBounds.scaled(by: 1 / factor), in: transform, fill: 1, identity: board.uuid)
        }
        actions.selectComponents = { componentIDs in
            let wanted = Set(componentIDs.map(normalizedID))
            guard wanted != selectedComponentIDs, moveState == nil, pastePlacementState == nil else {
                return false
            }
            let before = (selectedObjects, selectedUnplacedObjectID)
            selectedObjects = boardSelectableScene().refs().filter { ref in
                ref.type == .boardPackage && componentID(for: ref).map { wanted.contains(normalizedID($0)) } == true
            }
            // A part with no package on the board is picked in the unplaced
            // column instead, which scrolls to it: the first of them there,
            // since the column picks one.
            selectedUnplacedObjectID = currentUnplacedObjects.first { object in
                object.componentID.map { wanted.contains(normalizedID($0)) } == true
            }?.id
            hoveredObject = nil
            // No report back: the workspace asked for this, so it knows. A
            // report would carry whatever this canvas could show of it — one
            // of several parts not on the board, say — and the workspace
            // would take that as the new selection and clear every other view.
            return before != (selectedObjects, selectedUnplacedObjectID)
        }
        actions.selectUnplacedComponents = { componentIDs in
            // A part being placed, moved or pasted keeps the column as it is.
            guard moveState == nil, pastePlacementState == nil, packagePlacementState == nil else {
                return false
            }
            let wanted = Set(componentIDs.map(normalizedID))
            if let object = currentUnplacedObjects.first(where: { object in
                object.componentID.map { wanted.contains(normalizedID($0)) } == true
            }) {
                guard selectedUnplacedObjectID != object.id || !selectedObjects.isEmpty else {
                    return false
                }
                // The column's pick is the board's selection, as a click on
                // its row makes it, though without starting to place it.
                selectedObjects = []
                selectedUnplacedObjectID = object.id
            } else {
                // The schematic has moved on: a pick it no longer selects
                // goes, when it is all the board has selected.
                guard selectedObjects.isEmpty, let picked = selectedUnplacedObject,
                      picked.componentID.map({ wanted.contains(normalizedID($0)) }) != true else {
                    return false
                }
                selectedUnplacedObjectID = nil
            }
            hoveredObject = nil
            return true
        }
        return actions
    }

    private func canvasCommandHandlers() -> HorizontalCanvasCommandHandlerSet {
        // Built as the board handler set, then trimmed for pool modes: the
        // many conditional closures in one initializer expression exceed what
        // the type checker will resolve.
        var handlers = HorizontalCanvasCommandHandlerSet(
            isReadOnly: isReadOnly,
            hasInteraction: drawGraphicsState != nil || drawTrackState != nil || moveState != nil || pastePlacementState != nil || poolPlacementState != nil || roundOffVertexState != nil || addVertexState != nil || tuneState != nil || packagePlacementState != nil || measureState != nil,
            selectAll: selectAllObjects,
            selectNet: selectNetOfSelection,
            selectMore: { selectMoreOfSelection(stopsAtVias: $0) },
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
            defineKeepout: { if let ref = selectedObjects.first(where: isPolygonRef) { defineKeepout(on: ref) } },
            editKeepout: { editKeepoutForSelection() },
            updateAllPlanes: { onUpdateAllPlanes() },
            convertPolygonToLineLoop: { convertPolygonToLineLoopForSelection() },
            convertLineLoopToPolygon: { convertLineLoopToPolygonForSelection() },
            roundOffVertex: canRoundOffVertex ? { beginRoundOffVertex() } : nil,
            addText: { addText() },
            editText: { editSelectedText() },
            openDatasheet: { openSelectedDatasheet() },
            setSmashed: { smashSelection($0) },
            smashSilkscreenGraphics: { smashSilkscreenGraphicsSelection() },
            toggleOmitSilkscreen: { togglePackageFlag(\.omitSilkscreen, actionName: "Omit Silkscreen") },
            toggleOmitOutline: { togglePackageFlag(\.omitOutline, actionName: "Omit Outline") },
            toggleFixed: { togglePackageFlag(\.fixed, actionName: "Fix Package") },
            flipTrackPosture: drawTrackState != nil ? { flipTrackPosture() } : nil,
            enterTrackWidth: drawTrackState != nil ? { enterTrackWidth() } : nil,
            toggleVia: canToggleVia ? { toggleVia() } : nil,
            // The settings are the route inspector's, which is there while
            // the track tool is.
            showToolSettings: drawTrackState != nil ? { onShowToolSettings() } : nil,
            editSymbolPinNames: nil,
            toggleRectanglePlacementMode: toggleRectanglePlacementMode,
            moveSelectionBy: moveSelectionByGrid,
            hasPlacementInteraction: poolPlacementState != nil,
            hasRoundOffVertexInteraction: roundOffVertexState != nil,
            roundOffVertexAdjustsRounding: canRoundOffVertex && roundOffVertexAdjustsRounding,
            commitInteraction: {
                if measureState != nil {
                    measureState = nil
                } else if packagePlacementState != nil {
                    commitPackagePlacement(at: lastCursorWorldPoint)
                } else if addVertexState != nil {
                    commitAddVertex()
                } else if roundOffVertexState != nil {
                    // Return is Horizon's "enter datum": type the radius.
                    enterRoundOffVertexRadius()
                } else if tuneState != nil {
                    // Return types the target, as it types a radius.
                    enterTuneTarget()
                } else if pastePlacementState != nil {
                    commitPastePlacement(at: lastCursorWorldPoint)
                } else if poolPlacementState != nil {
                    commitPoolPlacement(at: lastCursorWorldPoint)
                } else if drawGraphicsState != nil {
                    commitDrawGraphicsAtCursor()
                } else if drawTrackState != nil {
                    endDrawTrack()
                } else {
                    commitMove()
                }
            },
            cancelInteraction: {
                if measureState != nil {
                    measureState = nil
                } else if packagePlacementState != nil {
                    cancelPackagePlacement()
                } else if addVertexState != nil {
                    // Esc ends Add Vertex keeping what was placed, as
                    // Horizon's does.
                    commitAddVertex()
                } else if roundOffVertexState != nil {
                    cancelRoundOffVertex()
                } else if tuneState != nil {
                    cancelTune()
                } else if pastePlacementState != nil {
                    cancelPastePlacement()
                } else if poolPlacementState != nil {
                    cancelPoolPlacement()
                } else if drawGraphicsState != nil {
                    endDrawGraphicsInteraction()
                } else if drawTrackState != nil {
                    endDrawTrack()
                } else if moveState != nil {
                    cancelMove()
                } else {
                    clearSelectionAndHighlight()
                }
            }
        )
        // Select More has nothing to start from without a track, junction
        // or via, and Horizon doesn't offer it then.
        if modeProfile.isPoolMode || !BoardSelectMore.canSelectMore(from: selectedObjects) {
            handlers.selectMore = nil
        }
        // K: Add Vertex on a polygon's edge (or after its vertex), Horizon's.
        if canAddPolygonVertex {
            handlers.bendNetLine = { beginAddPolygonVertex() }
        }
        // A text size step needs a text, and none while an edit is under way.
        if !handlers.hasInteraction, !selectedSizedTexts.isEmpty {
            handlers.stepTextSize = { stepSelectedTextSize(larger: $0) }
        }
        if modeProfile.isPoolMode {
            handlers.selectNet = nil
            handlers.drawTrack = nil
            handlers.drawPlane = nil
            handlers.selectBoardLayerView = nil
            handlers.definePlane = nil
            handlers.editPlane = nil
            handlers.updateAllPlanes = nil
            handlers.openDatasheet = nil
            handlers.setSmashed = nil
            handlers.smashSilkscreenGraphics = nil
            handlers.toggleOmitSilkscreen = nil
            handlers.toggleOmitOutline = nil
            handlers.toggleFixed = nil
            handlers.showToolSettings = nil
        }
        if !modeProfile.allowsGraphics, !modeProfile.allowsPolygons {
            handlers.drawGraphics = nil
        }
        if !modeProfile.allowsText {
            handlers.addText = nil
            handlers.editText = nil
        }
        if modeProfile.placesPads {
            handlers.placePad = { requestPlacePad() }
        }
        if modeProfile.placesShapes {
            handlers.placeShape = { beginPlaceShape(form: $0) }
        }
        if modeProfile.placesHoles {
            handlers.placeHole = { beginPlaceHole(shape: $0) }
        }
        if modeProfile.mode == .board {
            // Dimensions are the board's: a package or padstack has no use for
            // one, and Horizon offers the tool only there.
            handlers.drawDimension = { beginDrawDimension() }
            handlers.measureDistance = { beginMeasure() }
            if canPlaceDecal {
                handlers.placeDecal = { requestPlaceDecal() }
            }
            if case .decal? = poolPlacementState?.kind {
                handlers.enterSize = { enterDecalScale() }
            }
            if canPlaceVia {
                handlers.placeVia = { requestPlaceVia() }
            }
            if canPlaceBoardHole {
                handlers.placeBoardHole = { requestPlaceBoardHole() }
            }
            // Whether the selection can take a net is worked out when asked:
            // it floods the copper each selected track and via is part of.
            handlers.setNet = { requestSetNet() }
            installCopperLockHandlers(&handlers)
            handlers.tuneTrack = { beginTuneTrack() }
            handlers.dragCopper = { beginCopperDrag() }
            let alignable = BoardAlignment.alignableRefs(selectedObjects, in: editedBoard ?? sourceBoard)
            if alignable.count >= 2 {
                handlers.alignSelection = { alignSelection($0) }
                handlers.alignableSelectionCount = alignable.count
            }
            if let onEditDiffpair {
                handlers.setDiffpair = { netIDs in
                    guard netIDs.allSatisfy(onEditDiffpair.canEdit),
                          let edit = HorizontalDiffpairProperty.pairing(of: Set(netIDs), in: board.netDetails) else { return }
                    onEditDiffpair.apply(edit.ops, edit.actionName)
                }
                handlers.clearDiffpair = { netID in
                    guard onEditDiffpair.canEdit(netID),
                          let edit = HorizontalDiffpairProperty.clearing(of: [netID], in: board.netDetails) else { return }
                    onEditDiffpair.apply(edit.ops, edit.actionName)
                }
            }
            handlers.filterAirwires = onFilterAirwires
            handlers.toggleInstanceOnly = { toggleInstanceOnlyEdit() }
            if !selectedBlockInstances.isEmpty {
                handlers.selectBlockInstance = { selectBlockInstances() }
                if selectedBlockInstances.count == 1 {
                    handlers.copyBlockLayout = { copyBlockLayoutToOtherInstances() }
                }
            }
            if selectedObjects.contains(where: canDisconnect) {
                handlers.disconnect = { disconnectSelection() }
            }
            if canRevealPoolPackages, selectedPackagePoolID() != nil {
                handlers.showInPoolManager = { revealSelectedPackage(.registeredPool) }
                handlers.showInProjectPoolManager = { revealSelectedPackage(.projectPool) }
            }
        }
        if let poolRevealAction, !modeProfile.isPoolMode {
            handlers.showAlternateParts = { poolRevealAction(.alternateParts) }
        }
        handlers.switchPane = onSwitchPane
        return handlers
    }

    private func updateCursor(at pointer: HorizontalCanvasPointer?, worldUnitsPerPoint: Double) {
        let point = pointer?.snapped
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

        if var state = measureState {
            if state.move(to: point) {
                measureState = state
            }
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

        if var state = roundOffVertexState {
            if state.cursor != point {
                state.update(cursor: point)
                roundOffVertexState = state
            }
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if var state = addVertexState {
            if state.cursor != point {
                state.update(cursor: point)
                addVertexState = state
            }
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if var state = tuneState {
            // The raw point: the stretch follows the pointer, not the grid.
            let raw = pointer?.raw ?? point
            if state.hasStarted, state.cursor != raw {
                state.move(to: raw, target: tuneTarget, settings: toolSettings.meanderSettings)
                tuneState = state
            }
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if packagePlacementState != nil {
            updatePackagePlacement(to: point)
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        if var state = poolPlacementState {
            if state.cursor != point {
                state.cursor = point
                poolPlacementState = state
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
            refreshRouteLoopPreview()
            if hoveredObject != nil {
                hoveredObject = nil
            }
            return
        }

        let newHover = hitSelectable(at: pointer?.raw ?? point, worldUnitsPerPoint: worldUnitsPerPoint)
        if hoveredObject != newHover {
            hoveredObject = newHover
        }
    }

    private func hitSelectable(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> HorizontalSelectableRef? {
        selectionVertex(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
            ?? boardSelectableScene().hitSelectable(
                at: point, worldUnitsPerPoint: worldUnitsPerPoint, admits: selectionFilterAdmits
            )
    }

    /// The selection filter (`BoardSelectionFilter`), on the board only, and
    /// nil while it lets everything through. A part of what is selected
    /// already (`selectionVertex`) is picked whatever it says.
    private var selectionFilterAdmits: ((HorizontalSelectableRef) -> Bool)? {
        let filter = selectionToolSettings.boardFilter
        guard modeProfile.mode == .board, filter.isFiltering else {
            return nil
        }
        return filter.admits
    }

    /// The part of the selection marked under the cursor (`BoardSelectionVertices`):
    /// a vertex of a selected polygon, a selected track's end, a selected
    /// dimension's point or label. A click there picks it ahead of anything
    /// else under the cursor, and without the menu asking which.
    private func selectionVertex(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> HorizontalSelectableRef? {
        guard !selectedObjects.isEmpty else {
            return nil
        }
        let expand = HorizontalSelectable.minimumScreenSize * worldUnitsPerPoint
        let index = selectableCache.selectionVertices(
            key: BoardSelectionVerticesCacheKey(selectableKey: selectableCacheKey, selectedRefs: selectedObjects)
        ) {
            let selectablesByRef = boardSelectablesByRef()
            return BoardSelectionVertices.refs(of: selectedObjects, in: selectableSceneBoard).flatMap { selectablesByRef[$0] ?? [] }
        }
        return BoardSelectionVertices.pick(at: point, among: index.candidates(at: point, expand: expand), expand: expand)
    }

    /// Whether a primary-drag press lands on the current selection — the drag
    /// then moves the selection instead of rubber-banding. Never during another
    /// interaction or read-only: those own the pointer already.
    private func pressLandsOnSelection(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> Bool {
        guard !isReadOnly,
              moveState == nil,
              drawTrackState == nil,
              drawGraphicsState == nil,
              pastePlacementState == nil,
              !selectedObjects.isEmpty else {
            return false
        }
        let refs = boardSelectableScene().targetRefs(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
        return !Set(selectedObjects).isDisjoint(with: refs)
    }

    private func targetMenuItems(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> [HorizontalSelectionTargetItem] {
        let admits = selectionFilterAdmits
        return HorizontalCanvasModeSupport.targetMenuItems(
            scene: boardSelectableScene(),
            at: point,
            worldUnitsPerPoint: worldUnitsPerPoint,
            itemForRef: { ref in admits?(ref) == false ? nil : hudItem(for: ref) }
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
            if ref.type == .track || ref.type == .via {
                move.append(.command(title: ref.type == .track ? "Drag keep slope" : "Drag", .dragCopper))
            }
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
                packageIsSmashed(ref) ? .command(title: "Unsmash Text", .unsmash) : .command(title: "Smash Text", .smash),
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
                entries.append(.command(title: "Edit Plane…", .editPlane))
                entries.append(.command(title: "Update All Planes", .updateAllPlanes))
            } else if canDefinePlane(on: ref) {
                entries.append(.command(title: "Define Plane…", .definePlane))
            }
            if canDefineKeepout(on: ref) {
                entries.append(.command(title: "Define Keepout…", .defineKeepout))
            }
        }
        if ref.type == .keepout || (isPolygonRef(ref) && keepoutBackedByPolygon(ref.id, in: board) != nil) {
            entries.append(.command(title: "Edit Keepout…", .editKeepout))
        }

        // Polygon ↔ line loop (reciprocal tools).
        if writable, isConvertiblePolygon(ref) {
            entries.append(.command(title: "Convert to Line Loop", .convertPolygonToLineLoop))
        }
        if writable, let state = roundOffVertexState(for: ref) {
            entries.append(.command(title: state.adjustsRounding ? "Adjust Rounding" : "Round Off Vertex", .roundOffVertex))
        }
        // K, on a straight edge or the vertex starting one.
        if writable, let target = addVertexTarget(ref), target.polygon.polygonVertices[target.vertex].type == .line {
            entries.append(.command(title: "Add Vertex", .bendNetLine))
        }
        if writable, ref.type == .boardLine || ref.type == .boardArc || ref.type == .junction {
            entries.append(.command(title: "Convert to Polygon", .convertLineLoopToPolygon))
        }

        // Destructive
        entries.append(.separator)
        if writable, isDeletable(ref) { entries.append(.command(title: "Delete", .deleteSelection)) }
        if writable, canDisconnect(ref) { entries.append(.command(title: "Disconnect", .disconnect)) }
        if writable, modeProfile.mode == .board, let entry = BoardCopperLockCommands.menuEntry(for: ref, in: board) {
            entries.append(entry)
        }

        // Net
        if hasNet {
            entries.append(.separator)
            entries.append(.command(title: "Spotlight", .highlightNet))
            entries.append(.command(title: "Select Net", .selectNet))
            // Set and Clear Differential Pair, for the top block's nets.
            if writable, modeProfile.mode == .board, let onEditDiffpair {
                entries.append(contentsOf: HorizontalDiffpairProperty.menuEntries(
                    for: netID(for: ref), selectedNetIDs: selectedNetIDs, in: board.netDetails,
                    canEdit: { onEditDiffpair.canEdit($0) }))
            }
        }
        // Set Net… on a track or via whose copper no pad gives a net
        // (Horizon's Set via net), or why it can't take one.
        if writable, modeProfile.mode == .board, let availability = BoardSetNet.availability(of: ref, in: board) {
            if !hasNet {
                entries.append(.separator)
            }
            if let reason = availability.reason {
                entries.append(.unavailable(title: "Set Net…", reason: reason))
            } else {
                entries.append(.command(title: "Set Net…", .setNet))
            }
        }

        // The run of track (Horizon's Select More, + and =).
        if BoardSelectMore.canSelectMore(from: [ref]) {
            entries.append(.separator)
            entries.append(.command(title: "Select More", .selectMore(stopsAtVias: false)))
            entries.append(.command(title: "Select More (Stop at Vias)", .selectMore(stopsAtVias: true)))
        }

        // Block instances (packages)
        if isPackage, let match = blockLayoutMatch, !match.instances(ofPackage: ref.id).isEmpty {
            entries.append(.separator)
            entries.append(.command(title: "Select Instance", .selectBlockInstance))
            if writable {
                entries.append(.command(title: "Copy Layout to Other Instances", .copyBlockLayout))
            }
        }

        // Pool / datasheet (packages)
        if isPackage {
            entries.append(.separator)
            if canRevealPoolPackages, packagePoolID(for: ref) != nil {
                entries.append(.command(title: "Show in Pool Manager", .showInPoolManager))
                entries.append(.command(title: "Show in Project Pool Manager", .showInProjectPoolManager))
            } else {
                entries.append(.todo(title: "Show in Pool Manager"))
                entries.append(.todo(title: "Show in Project Pool Manager"))
            }
            if packageDatasheetURL(for: ref) != nil {
                entries.append(.command(title: "Open Datasheet", .openDatasheet))
            } else {
                entries.append(.todo(title: "Open datasheet"))
            }
            for link in packagePartPageLinks(for: ref) {
                entries.append(.action(title: link.title, .openURL(link.url)))
            }
            // The Pools pane on the parts that can replace the package's
            // component's, as its Replace offers them.
            if poolRevealAction != nil, !modeProfile.isPoolMode {
                entries.append(.command(title: "Alternate Parts…", .showAlternateParts))
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
        case .pad: return modeProfile.mode == .package && poolPad(for: ref) != nil
        case .padstackShape: return padstackShape(for: ref) != nil
        default: return false
        }
    }

    /// Objects the Move transform operates on (the broadest set — includes
    /// dimensions and decals, which can be moved).
    private func isTransformable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .track, .boardNetTie, .boardLine, .boardArc, .via, .text, .boardHole,
             .polygonVertex, .polygonEdge, .polygonArcCenter, .boardPackage, .dimension, .boardDecal,
             .padstackShape:
            return true
        case .pad:
            return modeProfile.mode == .package
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
             .polygonVertex, .polygonEdge, .polygonArcCenter, .boardPackage, .padstackShape:
            return true
        case .pad:
            return modeProfile.mode == .package
        default:
            return false
        }
    }

    /// Whether `deleteSelectedObjects` can actually remove this ref's type (pads
    /// and connected junctions are no-ops there, so we don't offer Delete).
    private func isDeletable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .pad:
            return modeProfile.mode == .package
        case .junction,
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

    /// Open on each distributor Settings has on, for the package's part.
    private func packagePartPageLinks(for ref: HorizontalSelectableRef) -> [HorizontalPartPageLink] {
        guard ref.type == .boardPackage,
              let component = board.packages.first(where: { normalizedID($0.id) == normalizedID(ref.id) })?.componentDetails else {
            return []
        }
        return HorizontalPartPageLink.links(mpn: component.mpn ?? "", manufacturer: component.manufacturer ?? "")
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

    /// Smash (H) or Unsmash (⇧H) the selected package(s) (tool_smash).
    /// Smash extracts an unsmashed package's own silk text into
    /// independently editable `fromSmash` board text and hides the package
    /// silk; Unsmash removes a smashed one's copies and re-derives the
    /// package silk from the pool. H on a package smashed already selects
    /// its smashed refdes, to move or edit, and changes nothing.
    private func smashSelection(_ smashing: Bool) {
        guard !isReadOnly else { return }
        let packageRefs = uniqueRefs(selectedObjects).filter { $0.type == .boardPackage }
        guard !packageRefs.isEmpty else { return }

        let previous = editedBoard ?? sourceBoard
        let refdesRefs = smashing ? smashedRefdesRefs(of: packageRefs, in: previous) : []
        var draft = previous
        var changedPackageIDs = Set<String>()
        for ref in packageRefs where smash(ref, smashing: smashing, in: &draft) {
            changedPackageIDs.insert(normalizedID(ref.id))
        }
        guard !changedPackageIDs.isEmpty else {
            guard !refdesRefs.isEmpty else { return }
            hoveredObject = nil
            selectedObjects = refdesRefs
            publishSelectionContext()
            return
        }

        registerUndoSnapshot(previous, actionName: smashing ? "Smash" : "Unsmash")
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        // After smashing, select the new editable from-smash texts so they can be
        // immediately repositioned / edited, with the refdes of any package
        // smashed already.
        if smashing {
            selectedObjects = draft.packageTexts.compactMap { text in
                guard text.fromSmash,
                      let pkg = packageID(forGeometryID: text.id).map(normalizedID),
                      changedPackageIDs.contains(pkg) else {
                    return nil
                }
                return HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer)
            } + refdesRefs
        }
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// The refdes texts the smashed packages among `packageRefs` own: the
    /// `fromSmash` texts that store $RD.
    private func smashedRefdesRefs(of packageRefs: [HorizontalSelectableRef], in board: HorizontalBoard) -> [HorizontalSelectableRef] {
        let smashedIDs = Set(board.packages.filter(\.smashed).map { normalizedID($0.id) })
            .intersection(packageRefs.map { normalizedID($0.id) })
        guard !smashedIDs.isEmpty else { return [] }
        return board.packageTexts.compactMap { text in
            guard text.fromSmash, HorizontalSmash.isRefdes(text),
                  let pkg = packageID(forGeometryID: text.id).map(normalizedID),
                  smashedIDs.contains(pkg) else {
                return nil
            }
            return HorizontalSelectableRef(id: text.id, type: .text, layer: text.layer)
        }
    }

    /// Smashes or unsmashes one package. Returns whether anything changed:
    /// nothing does for a package already that way.
    private func smash(_ ref: HorizontalSelectableRef, smashing: Bool, in board: inout HorizontalBoard) -> Bool {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              board.packages[index].smashed != smashing else {
            return false
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

        if !smashing {
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
            return true
        }

        // SMASH: copy the package's own SILKSCREEN text into editable `fromSmash`
        // board text and remove the pool silk (now represented by the copies).
        let poolSilk = board.packageTexts.filter { !$0.fromSmash && belongs($0) && isSilk($0) }
        guard !poolSilk.isEmpty else {
            return false
        }
        board.packageTexts.removeAll { !$0.fromSmash && belongs($0) && isSilk($0) }
        let prefix = board.packages[index].id
        for var text in poolSilk {
            text.id = "\(prefix)/text/\(UUID().uuidString.lowercased())"
            text.fromSmash = true
            board.packageTexts.append(text)
        }
        board.packages[index].smashed = true
        return true
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
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previous, kind: .flags))
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

    /// Ends the window's highlight, wherever it came from.
    private func clearHighlight() {
        guard !highlightedNetIDs.isEmpty || !highlightedComponentIDs.isEmpty else {
            return
        }
        onHighlightNetCommand([])
        onHighlightComponentCommand([])
    }

    /// Escape with no tool active: Horizon empties the selection, and with
    /// it the highlight.
    private func clearSelectionAndHighlight() {
        if !selectedObjects.isEmpty {
            setSelectedObject(nil)
        }
        clearHighlight()
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
        let refs = boardSelectableScene().refs()
        selectedObjects = selectionFilterAdmits.map { refs.filter($0) } ?? refs
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

    /// Horizon's Select More (+), or Select More (stop at vias) (=): the
    /// selection becomes the run of track its tracks, junctions and vias are
    /// part of, out to its pads, or its vias too (`BoardSelectMore`).
    private func selectMoreOfSelection(stopsAtVias: Bool) {
        guard moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil,
              roundOffVertexState == nil, addVertexState == nil, tuneState == nil, packagePlacementState == nil else {
            return
        }
        let run = BoardSelectMore.selection(from: selectedObjects, in: board, stopsAtVias: stopsAtVias)
        guard !run.isEmpty else {
            return
        }
        selectedObjects = run
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        publishSelectionContext()
    }

    /// The selected objects a text size step changes: texts (a smashed
    /// refdes or value among them) and dimensions, whose label it sizes.
    private var selectedSizedTexts: [HorizontalSelectableRef] {
        selectedObjects.filter { $0.type == .text || $0.type == .dimension }
    }

    /// ⌘⇧+ and ⌘⇧−: every selected text a size bigger or smaller, each from
    /// its own size (`HorizontalTextSizeStep`), as one undo step, as an
    /// edit of their Size in the inspector is; one at the smallest stays.
    private func stepSelectedTextSize(larger: Bool) {
        guard !isReadOnly else {
            return
        }
        let refs = selectedSizedTexts
        let textIDs = Set(refs.filter { $0.type == .text }.map { normalizedID($0.id) })
        let dimensionIDs = Set(refs.filter { $0.type == .dimension }.map { normalizedID($0.id) })
        let previousBoard = editedBoard ?? sourceBoard
        var draft = previousBoard
        var changed = false
        func step(_ texts: inout [HorizontalText]) {
            for index in texts.indices where textIDs.contains(normalizedID(texts[index].id)) {
                if let size = HorizontalTextSizeStep.stepped(texts[index].size, larger: larger) {
                    texts[index].size = size
                    changed = true
                }
            }
        }
        step(&draft.texts)
        step(&draft.packageTexts)
        for index in draft.dimensions.indices where dimensionIDs.contains(normalizedID(draft.dimensions[index].id)) {
            if let size = HorizontalTextSizeStep.stepped(draft.dimensions[index].labelSize, larger: larger) {
                draft.dimensions[index].labelSize = size
                changed = true
            }
        }
        guard changed else {
            return
        }
        registerUndoSnapshot(previousBoard, actionName: larger ? "Increase Text Size" : "Decrease Text Size")
        editedBoard = draft
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previousBoard, kind: .properties))
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
              poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil,
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
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previous, kind: .paste))
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
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previous, kind: .duplicate))
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
            case .pad:
                if modeProfile.mode == .package, let pad = poolPad(for: ref, in: board) {
                    items.append(.pad(pad)); note([pad.placement.shift])
                }
            case .padstackShape:
                if let shape = padstackShape(for: ref, in: board) {
                    items.append(.padstackShape(shape)); note([shape.placement.shift])
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
                // The original's junctions aren't where the copy lands.
                t.fromJunctionID = nil; t.toJunctionID = nil
                board.tracks.append(t)
                refs.append(HorizontalSelectableRef(id: t.id, type: .track, layer: t.layer))
            case .netTie(var t):
                t.id = newID(); t.from = shift(t.from); t.to = shift(t.to); t.center = t.center.map(shift)
                t.fromJunctionID = nil; t.toJunctionID = nil
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
                refs.append(contentsOf: BoardPolygonParts.wholeSelection(of: poly))
            case .pad(var pad):
                pad.id = newID()
                pad.name = HorizontalPoolPackage.nextPadName(among: board.pads)
                pad.placement.shift = shift(pad.placement.shift)
                board.pads.append(pad)
                if let poolContext {
                    board.rebakePoolPad(id: pad.id, context: poolContext)
                }
                refs.append(HorizontalSelectableRef(id: board.padRefID(for: pad), type: .pad))
            case .padstackShape(var shape):
                shape.id = newID()
                shape.placement.shift = shift(shape.placement.shift)
                board.padstackShapes.append(shape)
                board.rebakePadstackShape(id: shape.id)
                refs.append(HorizontalSelectableRef(id: shape.id, type: .padstackShape, layer: shape.layer))
            }
        }
        // The copies' ends go on junctions where they land, or the writer
        // leaves them out of the file. Not for the placement ghost, which is
        // only drawn.
        if idPrefix == nil, modeProfile.mode == .board {
            func ids(_ type: HorizontalObjectType) -> Set<String> {
                Set(refs.filter { $0.type == type }.map(\.id))
            }
            BoardTrackRouting.attachJunctions(
                tracks: ids(.track), netTies: ids(.boardNetTie), lines: ids(.boardLine), arcs: ids(.boardArc),
                vias: ids(.via), on: &board)
        }
        return refs
    }

    private func updateSelection(with ref: HorizontalSelectableRef?, action: HorizontalSelectionClickAction) {
        if HorizontalCanvasModeSupport.clearsHighlight(hitNothing: ref == nil, action: action) {
            clearHighlight()
        }
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
        if HorizontalCanvasModeSupport.clearsHighlight(hitNothing: refs.isEmpty, action: action) {
            clearHighlight()
        }
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

    /// A component picked in the unplaced column: its package comes onto
    /// the board under the cursor (Horizon's map-package tool). Read-only,
    /// or without a pool to bake from, it is only selected.
    private func selectUnplacedObject(_ object: HorizontalUnplacedObject) {
        // A pick from this list need not be a click on the canvas (VoiceOver,
        // the keyboard), so take the keys here: R, E and Esc now belong to the
        // package being placed.
        onRequestKeyboardFocus()
        selectedObjects = []
        hoveredObject = nil
        selectedUnplacedObjectID = object.id
        publishSelectionContext()
        beginPackagePlacement(for: object)
    }

    // MARK: Place package (Horizon's map-package tool)

    private func beginPackagePlacement(for object: HorizontalUnplacedObject) {
        guard !isReadOnly,
              modeProfile.mode == .board,
              let poolURL,
              moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, roundOffVertexState == nil && addVertexState == nil && tuneState == nil,
              packagePlacementState == nil else {
            return
        }
        let originalBoard = board
        // What the cursor snaps to: the board as it is, without the package.
        let snapTargets = boardSnapTargets()
        let position = lastCursorWorldPoint ?? originalBoard.bounds.center
        guard let draft = HorizontalBoard.placingPackage(
            for: object,
            in: originalBoard,
            at: position,
            poolURL: poolURL
        ) else {
            return
        }
        editedBoard = draft.board
        packagePlacementState = PackagePlacementState(originalBoard: originalBoard, placementID: draft.placementID)
        selectedObjects = [HorizontalSelectableRef(id: draft.placementID, type: .boardPackage)]
        hoveredObject = nil
        // One rebuild for the board with the package on it, which draws only
        // the package (`BoardSceneObjectCache`). From then on the package rides
        // the move tool, whose resident plan shifts its spans on the GPU per
        // cursor step; writing a new board per step instead rebuilt the whole
        // scene, the selectables and the snap index every time.
        invalidateSelectableCache()
        startPlacingPackageMove(on: draft.board, from: position, snapTargets: snapTargets)
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Hands the package being placed to the move tool: the cursor drags it
    /// from `origin`, where it sits on `board`.
    private func startPlacingPackageMove(on board: HorizontalBoard, from origin: HorizontalPoint, snapTargets: [HorizontalPoint]?) {
        let plan = boardResidentMovePlan(for: selectedObjects, in: board)
        moveState = MoveState(
            startPoint: origin,
            lastPoint: origin,
            originalBoard: board,
            tracksCursor: true,
            snapTargets: snapTargets,
            residentMovePlan: plan,
            airwireRequest: startMovingAirwires(plan: plan, board: board)
        )
        HorizontalMoveRateDiagnostics.beginMove(
            tracksCursor: true,
            selectedCount: selectedObjects.count,
            details: "package placement, translated \(plan.translatedRefs.count), unsupported \(plan.unsupportedRefs.count)"
        )
    }

    private func updatePackagePlacement(to point: HorizontalPoint) {
        guard packagePlacementState != nil, moveState != nil else {
            return
        }
        updateMove(to: point)
    }

    /// The placement draft with the package where the cursor has taken it.
    private func placingPackageBoard() -> HorizontalBoard? {
        guard let state = moveState else {
            return nil
        }
        var draft = state.turn?.board ?? state.originalBoard
        let delta = state.lastPoint - state.startPoint
        if delta != .zero {
            moveSelectedObjects(by: delta, board: &draft)
        }
        return draft
    }

    /// R and E while placing: turn or flip the package about its own
    /// origin, with no undo step of their own. R turns it in place, as a move
    /// does (122); E rebuilds, and the move then carries on from the flipped
    /// package.
    private func transformPlacingPackage(
        turn: BoardSelectionTurn? = nil,
        _ transform: (HorizontalPoint, inout HorizontalBoard) -> Void
    ) {
        guard let state = packagePlacementState,
              var move = moveState,
              var draft = placingPackageBoard(),
              let package = draft.packages.first(where: { normalizedID($0.id) == normalizedID(state.placementID) }) else {
            return
        }
        transform(package.position, &draft)
        if let turn, canTurnBoardMoveInPlace(by: turn.angle) {
            move.turn = BoardMoveTurn(
                board: draft,
                placement: turned(move.livePlacement, about: package.position, by: turn.angle),
                count: (move.turn?.count ?? 0) + 1
            )
            move.startPoint = move.lastPoint
            moveState = move
            return
        }
        let origin = draft.packages.first(where: { normalizedID($0.id) == normalizedID(state.placementID) })?.position ?? package.position
        editedBoard = draft
        invalidateSelectableCache()
        startPlacingPackageMove(on: draft, from: origin, snapTargets: move.snapTargets)
    }

    private func commitPackagePlacement(at point: HorizontalPoint?) {
        guard !isReadOnly, let state = packagePlacementState else {
            return
        }
        if let point {
            updatePackagePlacement(to: point)
        }
        guard let draft = placingPackageBoard() else {
            return
        }
        editedBoard = draft
        moveState = nil
        packagePlacementState = nil
        selectedUnplacedObjectID = nil
        HorizontalMoveRateDiagnostics.endMove(committed: true)
        registerUndoSnapshot(state.originalBoard, actionName: "Place Package")
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: state.originalBoard, kind: .placePackage))
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    private func cancelPackagePlacement() {
        guard let state = packagePlacementState else {
            return
        }
        editedBoard = state.originalBoard
        moveState = nil
        packagePlacementState = nil
        selectedObjects = []
        hoveredObject = nil
        HorizontalMoveRateDiagnostics.endMove(committed: false)
        invalidateSelectableCache()
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    private func uniqueRefs(_ refs: [HorizontalSelectableRef]) -> [HorizontalSelectableRef] {
        HorizontalCanvasModeSupport.uniqueRefs(refs)
    }

    private func beginMove(tracksCursor: Bool = true, editTextRefOnCommit: String? = nil) {
        guard pastePlacementState == nil, poolPlacementState == nil, roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil else { return }
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
            // Fixed packages don't move (tool_move filters them out), nor
            // does locked copper (`BoardCopperLock`).
            expandedBoardMoveSelection(BoardCopperLock.removingHeld(selectedObjects, in: originalBoard), in: originalBoard)
                .filter { !isFixedPackage($0, in: originalBoard) }
        }
        // Nothing movable (e.g. only a fixed package selected): leave the
        // selection intact and don't start a move.
        guard !moveSelection.isEmpty else { return }
        let fallbackSelectionCenter = lastCursorWorldPoint == nil
            ? measure("selection center") {
                HorizontalCanvasModeSupport.selectionCenter(
                    for: moveSelection,
                    anchorPoints: selectionAnchorPointLookup(for: moveSelection, in: board)
                )
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
        let selectionPointKeys = measure("selection points") { boardSnapTargetKeys(for: moveSelection) }
        // The cursor snaps to everything but what moves, as Horizon's move
        // tool filters the selection out of its targets.
        let snapTargets = measure("snap targets") {
            boardSnapTargets().filter { !selectionPointKeys.contains(pointKey($0)) }
        }
        let grabbedPoint = tracksCursor
            ? HorizontalCanvasModeSupport.cursorAnchor(
                cursor: start,
                cursorIsOnSelection: selectionPointKeys.contains(pointKey(start)),
                snapToGrid: snapBoardPointToGrid
            )
            : start
        // A block instance selected whole is held by its anchor: grabbed by
        // anything but a point of its own, the move takes the anchor onto the
        // grid, where Instance X and Y would place it, and keeps it there.
        let anchorOffset = measure("instance anchor") { () -> HorizontalPoint in
            guard tracksCursor, !selectionPointKeys.contains(pointKey(start)),
                  let anchor = selectedInstanceAnchor(in: originalBoard) else {
                return .zero
            }
            return anchor - snapBoardPointToGrid(anchor)
        }
        let residentMovePlan = measure("resident plan") {
            boardResidentMovePlan(for: moveSelection, in: originalBoard)
        }
        let airwireRequest = measure("moving airwires") {
            startMovingAirwires(plan: residentMovePlan, board: originalBoard)
        }
        measure("state assign") {
            moveState = MoveState(
                startPoint: grabbedPoint + anchorOffset,
                lastPoint: grabbedPoint,
                originalBoard: originalBoard,
                tracksCursor: tracksCursor,
                snapTargets: snapTargets,
                residentMovePlan: residentMovePlan,
                editTextRefOnCommit: editTextRefOnCommit,
                airwireRequest: airwireRequest
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
        if totalDelta == .zero, state.boardBeforeMove == nil, state.turn == nil {
            measure("clear move state") {
                moveState = nil
            }
            // Its scene is kept, with the moving nets' airwires patched out
            // for the live ones; rebuild to bring them back.
            if let airwireRequest = state.airwireRequest, selectableCache.movingAirwires(for: airwireRequest) != nil {
                invalidateSelectableCache()
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
            state.turn?.board ?? state.originalBoard
        }
        measure("apply move") {
            if let drag = state.copperDrag {
                draft = drag.applied(to: draft, shift: totalDelta)
            } else if totalDelta != .zero {
                moveSelectedObjects(by: totalDelta, board: &draft)
            }
        }
        measure("assign edited board") {
            editedBoard = draft
        }
        measure("register undo") {
            // The text-placement commit defers its single "Add Text" undo to
            // finalize; don't register a "Move" here (there's no committed prior
            // position — the text was never on the board before this flow).
            if editTextRef == nil {
                registerUndoSnapshot(state.boardBeforeMove ?? state.originalBoard, actionName: state.copperDrag?.actionName ?? "Move")
            }
        }
        measure("clear move state") {
            moveState = nil
        }
        measure("invalidate caches") {
            // The scene is built again from the committed board, whatever
            // moved. The resident patches end with the move, and the renderer
            // then puts back the scene it was given; one kept from before the
            // move drew everything that moved at its old place until something
            // else rebuilt it (a pour, or Q).
            invalidateSelectableCache()
        }
        measure("publish board change") {
            // The text-placement flow has no board before it to read an edit
            // from.
            publishConnectivityResolvedEdit(
                draft,
                sync: editTextRef == nil ? BoardLayoutSyncIntent(baseline: state.boardBeforeMove ?? state.originalBoard, kind: .move) : nil
            )
        }
        measure("publish selection") {
            publishSelectionContext()
        }
        HorizontalMoveRateDiagnostics.endMove(committed: true)
        HorizontalMoveCommitDiagnostics.report(
            modeName: "board",
            selectedCount: selectedCount,
            details: "translated \(plan.translatedRefs.count), segments \(plan.segmentMoves.count), unsupported \(plan.unsupportedRefs.count), moved true",
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
        // A turn made in place (122) is in its own board; the move carries on
        // from there.
        let base = state.turn?.board ?? state.originalBoard
        let totalDelta = state.lastPoint - state.startPoint
        guard totalDelta != .zero else {
            return base
        }
        if let drag = state.copperDrag {
            return drag.applied(to: base, shift: totalDelta)
        }

        return selectableCache.movePreview(
            key: BoardMovePreviewCacheKey(
                boardID: base.uuid,
                revision: selectableCacheRevision,
                counts: boardGeometryCounts(for: base),
                selectedRefs: selectedObjects,
                startPoint: state.startPoint,
                lastPoint: state.lastPoint,
                turns: state.turn?.count ?? 0
            )
        ) {
            if let reshaped = reshapedPolygonPreview(of: base, by: totalDelta) {
                if BoardSceneVerifier.isEnabled {
                    var moved = base
                    moveSelectedObjects(by: totalDelta, board: &moved)
                    BoardSceneVerifier.compareReshapePreview(reshaped, with: moved)
                }
                return reshaped
            }
            var previewBoard = base
            moveSelectedObjects(by: totalDelta, board: &previewBoard)
            return previewBoard
        }
    }

    /// A drag of polygon parts alone that reshapes every polygon it touches
    /// (a vertex or an edge, say): those polygons changed where the board
    /// keeps them (its own, a plane's outline, a keepout's) and nothing else,
    /// which is what `moveSelectedObjects` makes of it, without its
    /// whole-board pass. Everything else the board holds keeps its storage,
    /// so the scene and selectable caches see it unchanged. Nil for anything
    /// else, a polygon moved whole included: a plane's fills go with it.
    private func reshapedPolygonPreview(of base: HorizontalBoard, by delta: HorizontalPoint) -> HorizontalBoard? {
        guard !selectedObjects.isEmpty, selectedObjects.allSatisfy({ BoardPolygonParts.isPart($0.type) }) else {
            return nil
        }
        let ids = Set(selectedObjects.map { normalizedID($0.id) })
        let originals = (base.polygons + base.outlinePolygons).filter { ids.contains(normalizedID($0.id)) }
        guard Set(originals.map { normalizedID($0.id) }).count == originals.count else {
            return nil
        }
        var polygons = originals
        var done = Set<String>()
        for ref in selectedObjects {
            BoardPolygonParts.change(&polygons, ref: ref, done: &done) { $0 + delta }
        }
        guard !originals.contains(where: { BoardPolygonParts.changedWhole($0, done: done) }) else {
            return nil
        }
        var board = base
        for polygon in polygons {
            let id = normalizedID(polygon.id)
            if let index = board.polygons.firstIndex(where: { normalizedID($0.id) == id }) {
                board.polygons[index] = polygon
            } else if let index = board.planes.firstIndex(where: { !$0.id.contains("/") && normalizedID($0.polygonID) == id }) {
                board.planes[index].fallbackPolygon = polygon
                board.planes[index].layer = polygon.layer
            } else if let index = board.keepouts.firstIndex(where: { !$0.id.contains("/") && normalizedID($0.polygonID) == id }) {
                board.keepouts[index].polygon = polygon
            }
        }
        return board
    }

    private func beginDrawGraphics(_ primitive: HorizontalDrawingPrimitive) {
        guard !isReadOnly,
              moveState == nil,
              pastePlacementState == nil,
              poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil,
              primitive.producesPolygon ? modeProfile.allowsPolygons : modeProfile.allowsGraphics else {
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
        #if os(macOS)
        textRenderDebounce?.cancel()
        editingTextState = nil
        #endif
        let routing = drawTrackState != nil
        editedBoard = nil
        moveState = nil
        drawGraphicsState = nil
        drawTrackState = nil
        trackRouterSession = nil
        pastePlacementState = nil
        poolPlacementState = nil
        roundOffVertexState = nil
        addVertexState = nil
        packagePlacementState = nil
        invalidateSelectableCache()
        // The track tool stays, as it does when a route ends: only a route
        // under way, laid on the board from before, goes, and the next one
        // starts on this board.
        if routing, !isReadOnly {
            armDrawTrack()
            routeInspector?.beginRoute(on: board)
        }
        // invalidateSelectableCache also rebuilds the Metal scene.
        publishSelectionContext()
    }

    /// The grid the pane's grid settings give the board, taken into the
    /// canvas's own board in place, as a pour's fills are. Once an edit has
    /// given the canvas a board of its own it draws, snaps and steps the arrow
    /// keys by that board's grid, and commits its next edit from it, so a grid
    /// changed in the pane showed there and was put back by the next edit.
    private func adoptSourceGrid(_ grid: HorizontalGridSettings) {
        guard editedBoard != nil, editedBoard?.grid != grid else {
            return
        }
        editedBoard?.grid = grid
    }

    /// Whether a tool is in use, with a board of its own to commit or to put
    /// back on cancel. New fills wait until it is done: taken in now, they
    /// would be lost when it commits or cancels from its own copy, and a move
    /// draws from that copy meanwhile anyway. The track tool has one only
    /// once its route has laid something: waiting for a route, or for the
    /// route's second click, it takes the fills (`takePlaneFillDelivery`).
    private var holdsPlaneFills: Bool {
        var editingText = false
        #if os(macOS)
        editingText = editingTextState != nil
        #endif
        return moveState != nil || drawGraphicsState != nil || drawTrackState?.hasDrawn == true
            || pastePlacementState != nil || poolPlacementState != nil || roundOffVertexState != nil || addVertexState != nil || tuneState != nil
            || packagePlacementState != nil || planeEditorState != nil || editingText
    }

    /// Takes the newest pour's fills into the board shown, if they are still
    /// its fills. Only the plane batches of the scene are made again (and the
    /// airwire batches when the fills joined or parted some copper); the
    /// selectables, the snap index and every tool's state stay as they are.
    private func takePlaneFillDelivery() {
        guard let delivery = planeFillDelivery, delivery.revision != takenPlaneFillRevision,
              modeProfile.mode == .board, !holdsPlaneFills else {
            return
        }
        takenPlaneFillRevision = delivery.revision
        let triangles = delivery.triangles
        delivery.triangles = [:]
        let base = editedBoard ?? sourceBoard
        // The board has moved on since the pour began; a pour for the board
        // as it is now is already on its way.
        guard HorizontalBoardPlaneInputs.signature(of: base) == delivery.fills.inputs else {
            return
        }
        var filled = base
        _ = filled.takePlaneFills(delivery.fills)
        selectableCache.takePlaneFills(triangles: triangles, keeping: delivery.fragmentKeys)
        // A fragment the pour took to be the canvas's already, and that it no
        // longer has, is tessellated here, and the scene built again with it.
        selectableCache.startBackgroundTessellation(planes: filled.planes)
        editedBoard = filled
        // A route that has laid nothing starts from the board as filled.
        if var state = drawTrackState {
            state.originalBoard = filled
            drawTrackState = state
        }
        // The next build draws the planes the pour changed, and the rats'
        // nest if it changed; the rest it replays (`BoardSceneObjectCache`).
        metalSceneRevision &+= 1
    }

    private func selectDrawingLayer(_ layer: Int) {
        let stackup = Set(board.stackupLayers.map(\.layer))
        guard stackup.contains(layer) else {
            return
        }
        onSelectDrawingLayer(layer)
    }

    /// Begin a dimension: a two-point measurement, drawn with the line tool's
    /// own interaction and committed as a `HorizontalDimension` rather than as
    /// board graphics.
    /// Design ▸ Measure Distance (`BoardMeasureState`). Nothing changes on
    /// the board, so it starts on a locked one too, but not over another
    /// tool.
    private func beginMeasure() {
        guard moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, packagePlacementState == nil,
              roundOffVertexState == nil, addVertexState == nil, tuneState == nil else {
            return
        }
        measureState = BoardMeasureState(cursor: lastCursorWorldPoint)
        hoveredObject = nil
    }

    private func beginDrawDimension() {
        guard !isReadOnly,
              modeProfile.mode == .board,
              moveState == nil,
              pastePlacementState == nil,
              poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil else {
            return
        }
        drawGraphicsState = DrawGraphicsState(
            primitive: .line,
            originalBoard: board,
            cursor: lastCursorWorldPoint,
            layer: drawingLayer,
            outcome: .dimension
        )
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
    }

    private func commitDrawDimension(_ result: DrawGraphicsResult, state: DrawGraphicsState) {
        // The line tool hands back a segment; a dimension is its two ends. A
        // zero-length one measures nothing, so the tool stays armed rather than
        // dropping a dimension the user cannot see.
        guard let line = result.lines.first(where: { pointKey($0.from) != pointKey($0.to) }) else {
            drawGraphicsState = state
            return
        }
        var draft = editedBoard ?? sourceBoard
        draft.dimensions.append(
            HorizontalDimension(
                id: UUID().uuidString.lowercased(),
                p0: line.from,
                p1: line.to,
                labelDistance: 1_000_000,
                labelSize: 1_500_000,
                mode: .distance
            )
        )
        editedBoard = draft
        drawGraphicsState = nil
        invalidateSelectableCache()
        registerUndoSnapshot(state.originalBoard, actionName: "Draw Dimension")
        // Through the same funnel as every other commit: setting `editedBoard`
        // alone draws the dimension and tells the document nothing, so it
        // would be gone at the next save.
        publishConnectivityResolvedEdit(board)
        publishSelectionContext()
    }

    private func beginDrawPlane() {
        guard !isReadOnly,
              modeProfile.usesConnectivity,
              moveState == nil,
              pastePlacementState == nil,
              poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil else {
            return
        }
        drawGraphicsState = DrawGraphicsState(
            primitive: .polygon,
            originalBoard: board,
            cursor: lastCursorWorldPoint,
            layer: drawingLayer,
            outcome: .plane
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
    /// With it on and no legal route to `to`, the legs stop at the nearest
    /// point a legal route reaches (`HorizontalRouteFinder.approach`): the
    /// edge of the clearance round the pad or track the cursor is over, or as
    /// near an enclosed cursor as the route gets. They never go nearer
    /// anything than the rules allow — a route drawn into what it should
    /// avoid looks like the router ignoring obstacles, and laid is copper
    /// that breaks the board's own rules. So the last leg can end short of
    /// `to`, and a click lays what the preview shows; nothing at all when the
    /// route can go nowhere towards it.
    private func trackSpecs(
        from: HorizontalPoint,
        to: HorizontalPoint,
        state: DrawTrackState,
        netID: String?
    ) -> [BoardTrackSegmentSpec] {
        if toolSettings.routerMode, let session = trackRouterSession {
            let approach = session.approach(
                from: from, to: to, layer: state.layer, netID: netID,
                width: state.width, diagonalFirst: state.bendMode == .xy)
            return BoardTrackRouting.specs(alongPath: approach.points)
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
                    netID: via.netID,
                    // Router vias are pinned (patchNewBoardVias writes net_set),
                    // so the model pins them too.
                    netSetID: via.netID
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
        var text = HorizontalText(
            id: UUID().uuidString.lowercased(),
            text: content,
            position: position,
            size: 1_000_000,
            layer: drawingLayer
        )
        text.setStoredText(content, variables: board.textVariables)
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
            content: placed?.editableText ?? state.content,
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
            content: text.editableText,
            preBoard: current,
            isEditing: true,
            isNewPlacement: false,
            originalContent: text.editableText
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
        guard draft.texts[index].editableText != state.content else { return }
        draft.texts[index].setStoredText(state.content, variables: draft.textVariables(forTextID: state.ref))
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
            draft.texts[index].setStoredText(state.content, variables: draft.textVariables(forTextID: state.ref))
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
              modeProfile.usesConnectivity,
              moveState == nil,
              pastePlacementState == nil,
              poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil,
              drawTrackState == nil else {
            return
        }
        armDrawTrack()
    }

    /// The track tool waiting for the click that starts a route: when it is
    /// picked, and again each time a route ends, so the next one starts with
    /// a click, as Horizon's router goes back to waiting once a route is done.
    /// It routes on `layer`, or on the pane's working layer.
    private func armDrawTrack(layer: Int? = nil) {
        // Extract and index the obstacle world ONCE for the route. It costs
        // about a millisecond on a real board — fine here, wasteful per frame,
        // and the board does not change while the user is dragging.
        trackRouterSession = toolSettings.routerMode
            ? HorizontalBoardTrackRouterSession(board: board)
            : nil
        let picked = layer ?? drawingLayer
        let layer = HorizontalBoardLayers.isCopper(picked) ? picked : HorizontalBoardLayers.topCopper
        // Width may take a hint from the highlighted net, but the track's NET is
        // never seeded from the selection — it's derived from what the route
        // actually connects to (see publishConnectivityResolvedEdit). A track
        // touching no pad stays net-less (orange).
        let startNet = selectedNetIDs.first
        let width = HorizontalRouteWidth.start(
            explicit: toolSettings.explicitTrackWidth, startTrack: nil,
            net: startNet, layer: layer, rules: board.rules, tracks: board.tracks)
        drawTrackState = DrawTrackState(
            originalBoard: board,
            anchor: nil,
            anchorJunctionID: nil,
            netID: nil,
            width: width.width,
            widthSource: width.source,
            layer: layer,
            cursor: lastCursorWorldPoint,
            cornerStyle: toolSettings.cornerStyle
        )
        trackRouteHistory = []
        pushShovePreviewSpecs = []
        clearRouteLoopPreview()
        drawGraphicsState = nil
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
    }

    private func addDrawTrackPoint(_ point: HorizontalPoint, raw: HorizontalPoint? = nil, startsAnywhere: Bool = false) {
        guard !isReadOnly,
              var state = drawTrackState else {
            return
        }

        if state.anchor == nil {
            var point = point
            // Set to start only on copper, a click off it starts nothing; the
            // status line says where to click.
            if toolSettings.startsOnCopper, !startsAnywhere {
                let layer = state.layer
                guard let start = BoardTrackRouting.copperStart(
                    at: point, raw: raw, layer: layer, in: board,
                    onPad: { boardPadReference(at: $0, layer: layer) != nil }
                ) else {
                    return
                }
                point = start
            }
            // Starting on a pad snaps the anchor to the pad center and
            // connects directly — no junction is placed on the pad.
            var anchorPoint = point
            if let padRef = boardPadReference(at: point, layer: state.layer) {
                anchorPoint = padRef.center
                state.anchorOnPad = true
            }
            state.anchor = anchorPoint
            // Not a junction only copper on the other layer is on: the route
            // gets one of its own there.
            state.anchorJunctionID = BoardTrackRouting.junctionID(at: anchorPoint, layer: state.layer, in: board)
            // The route takes its net, width and bend from copper on its own
            // layer only, as it snaps only to that (`boardSnapTargets`).
            if let net = boardNetID(at: point, layer: state.layer) ?? boardNetID(at: anchorPoint, layer: state.layer) {
                state.netID = net
            }
            // On a pad the rules' width; on a track the track's (or the
            // rules', where the track's is theirs); on either the rules' via;
            // anywhere else a custom width (W) and via when they are set. A
            // route that starts on a pad or a track clears the custom width
            // and via, as Horizon's router keeps them for its route.
            let startTrack = BoardTrackRouting.track(at: anchorPoint, layer: state.layer, tracks: board.tracks)
            let width = HorizontalRouteWidth.start(
                explicit: toolSettings.explicitTrackWidth,
                onPad: state.anchorOnPad,
                startTrack: startTrack,
                net: state.netID, layer: state.layer, rules: board.rules, tracks: board.tracks)
            state.width = width.width
            state.widthSource = width.source
            toolSettings.startRoute(onPadOrTrack: state.anchorOnPad || startTrack != nil)
            state.cursor = anchorPoint
            if let bend = boardTrackBendMode(at: anchorPoint, layer: state.layer) {
                state.bendMode = bend
            }
            state.loopStart = BoardTrackLoops.start(
                at: anchorPoint, layer: state.layer, onPad: state.anchorOnPad, in: editedBoard ?? sourceBoard)
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
            // A click on the end of the route with a via armed drops it
            // there: on the track or via the route began from, or where the
            // last click left it. Not in a pad the route began on, which
            // connects it already.
            if state.placesVia, endPad == nil {
                layRoute([], to: target, endsOnPad: false, netID: state.netID, state: &state)
            }
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
        // together. If the end point already belongs to a different net on
        // the route's layer, ignore the click and keep routing from the same
        // anchor; copper on another layer is crossed, not joined. Routing
        // around obstacles, the route stops at that copper's clearance, as
        // the preview shows it, aimed at the cursor rather than the pad's
        // centre, and the click lays that.
        let endNet = boardNetID(at: point, layer: state.layer) ?? boardNetID(at: target, layer: state.layer)
        var routeTarget = target
        var routeEndPad = endPad
        if let endNet,
           let trackNet = state.netID,
           normalizedID(endNet) != normalizedID(trackNet) {
            guard toolSettings.routerMode, trackRouterSession != nil else {
                state.cursor = point
                drawTrackState = state
                return
            }
            routeTarget = point
            routeEndPad = nil
        }
        let netID = state.netID ?? endNet

        // Lay the route legs for the active corner style: straight 90°, 45°
        // diagonal, or a tangent quarter-arc. Each leg becomes a track segment
        // (arc legs carry a center); junctions sit at the route vertices.
        let specs = trackSpecs(
            from: anchor, to: routeTarget, state: state, netID: netID)
        guard let routeEnd = specs.last?.to else {
            state.cursor = routeTarget
            drawTrackState = state
            return
        }
        // The router stops short of a target it can't legally reach: then the
        // click lays the route to where it stopped, which is in no pad.
        let arrives = pointKey(routeEnd) == pointKey(routeTarget)
        let endsOnPad = arrives && routeEndPad != nil

        // The armed via goes at the end of what this click lays. A click on a
        // pad ends the route in the pad instead, and drops no via in it; so
        // does a click on other copper the route joins there, a track of its
        // net, a via, or copper that closes a loop (`BoardTrackLoops`).
        let endsRoute = layRoute(
            specs, to: arrives ? routeTarget : routeEnd, endsOnPad: endsOnPad, netID: netID, state: &state)
        state.cursor = routeTarget
        drawTrackState = state

        if endsOnPad || endsRoute, state.segmentCount > 0 {
            commitDrawTrack()
        }
    }

    /// Lays one click's worth of route on the draft board, with the via `v`
    /// armed (`BoardTrackRouting.lay`), and moves the route's head on. One
    /// step for Backspace to take back, when it laid anything. Returns whether
    /// it joined copper on its layer, or closed a loop, which ends the route.
    @discardableResult
    private func layRoute(
        _ specs: [BoardTrackSegmentSpec],
        to target: HorizontalPoint,
        endsOnPad: Bool,
        netID: String?,
        state: inout DrawTrackState
    ) -> Bool {
        guard let anchor = state.anchor else {
            return false
        }
        let head = BoardTrackRouteHead(
            anchor: anchor,
            anchorJunctionID: state.anchorJunctionID,
            anchorOnPad: state.anchorOnPad,
            netID: netID,
            width: state.width,
            layer: state.layer,
            placesVia: state.placesVia,
            widthFromRules: state.widthSource.isRule
        )
        var draft = editedBoard ?? sourceBoard
        // The via opens the mask where its padstack does, read here, once a
        // click drops it, rather than with every preview that asks its shape.
        let via = state.placesVia
            ? routeVia(netID: netID).map { draft.viaWithMaskOpenings($0, poolURL: poolURL) }
            : nil
        // A route that rejoins its net's copper replaces what joined the two
        // points, as the preview showed while the cursor rested there.
        let step = BoardTrackLoops.lay(
            specs, to: target, endsOnPad: endsOnPad,
            via: via,
            from: head,
            loopStart: state.loopStart,
            routeTrackIDs: state.routeTrackIDs,
            removesLoops: toolSettings.removeLoops,
            on: &draft
        )
        let laid = step.laid
        guard laid.segments > 0 || laid.vias > 0 else {
            return false
        }
        pushTrackRouteStep(state)
        editedBoard = draft
        invalidateSelectableCache()
        clearRouteLoopPreview()
        state.loopStart = step.loopStart
        state.routeTrackIDs = step.routeTrackIDs

        state.anchor = laid.head.anchor
        state.anchorJunctionID = laid.head.anchorJunctionID
        state.anchorOnPad = laid.head.anchorOnPad
        let movedOn = state.netID != netID || state.layer != laid.head.layer
        state.netID = netID
        state.layer = laid.head.layer
        state.placesVia = laid.head.placesVia
        state.layerBeforeVia = laid.vias > 0 && laid.head.layer != head.layer ? head.layer : nil
        state.segmentCount += laid.segments
        state.viaCount += laid.vias
        // A route whose width is the rules' takes the rules' width on the
        // layer a via took it to, and for the net it joined.
        if movedOn {
            refreshRouteWidth(&state)
        }
        if laid.vias > 0 {
            followRouteLayer(state.layer)
        }
        return step.endsRoute
    }

    /// Works out whether a click at the cursor would close a loop, and what
    /// it would replace, and shows it (`routeLoopPreview`), once per point
    /// the cursor rests on.
    private func refreshRouteLoopPreview() {
        guard let state = drawTrackState, state.loopStart != nil,
              let anchor = state.anchor, let cursor = state.cursor else {
            clearRouteLoopPreview()
            return
        }
        let query = [
            pointKey(cursor), pointKey(anchor), "\(state.layer)", "\(state.segmentCount)",
            "\(state.viaCount)", "\(state.placesVia)", "\(trackRouteHistory.count)",
            "\(toolSettings.removeLoops)"
        ].joined(separator: "|")
        guard query != routeLoopPreviewQuery else {
            return
        }
        routeLoopPreviewQuery = query
        let preview = loopPreview(for: state, anchor: anchor, cursor: cursor)
        if preview != routeLoopPreview {
            routeLoopPreview = preview
        }
    }

    private func clearRouteLoopPreview() {
        routeLoopPreviewQuery = nil
        if routeLoopPreview != nil {
            routeLoopPreview = nil
        }
    }

    /// The click at `cursor` as `addDrawTrackPoint` would make it, made on a
    /// copy of the board: what it changes of the copper there, or nil unless
    /// it closes a loop.
    private func loopPreview(
        for state: DrawTrackState,
        anchor: HorizontalPoint,
        cursor: HorizontalPoint
    ) -> BoardRouteLoopPreview? {
        let current = board
        // A click in a pad ends the route at its centre.
        let endPad = boardPadReference(at: cursor, layer: state.layer)
        let target = endPad?.center ?? cursor
        guard pointKey(anchor) != pointKey(target),
              endPad != nil
                || BoardTrackLoops.reachesCopper(target, layer: state.layer, sparing: state.routeTrackIDs, in: current) else {
            return nil
        }
        // A click on another net's copper lays nothing.
        let endNet = boardNetID(at: cursor, layer: state.layer) ?? boardNetID(at: target, layer: state.layer)
        if let endNet, let net = state.netID, normalizedID(endNet) != normalizedID(net) {
            return nil
        }
        let netID = state.netID ?? endNet
        // A route the router stopped short of the copper closes nothing.
        let specs = trackSpecs(from: anchor, to: target, state: state, netID: netID)
        guard let end = specs.last?.to, pointKey(end) == pointKey(target) else {
            return nil
        }
        let head = BoardTrackRouteHead(
            anchor: anchor,
            anchorJunctionID: state.anchorJunctionID,
            anchorOnPad: state.anchorOnPad,
            netID: netID,
            width: state.width,
            layer: state.layer,
            placesVia: state.placesVia
        )
        var draft = current
        let step = BoardTrackLoops.lay(
            specs, to: target, endsOnPad: endPad != nil,
            via: state.placesVia ? routeVia(netID: netID) : nil,
            from: head,
            loopStart: state.loopStart,
            routeTrackIDs: state.routeTrackIDs,
            removesLoops: toolSettings.removeLoops,
            on: &draft
        )
        guard step.closesLoop else {
            return nil
        }
        guard !step.removedTrackIDs.isEmpty || !step.removedViaIDs.isEmpty else {
            return BoardRouteLoopPreview(hiddenTrackIDs: [], hiddenViaIDs: [], pieces: [], signature: [])
        }
        // What the click lays is the route preview's to draw; what is left
        // is what it does to the copper already there.
        let laid = Set(step.laid.trackIDs)
        let existing = Set(current.tracks.map(\.id))
        let hidden = existing.subtracting(draft.tracks.map(\.id))
        let pieces = draft.tracks.filter { !existing.contains($0.id) && !laid.contains($0.id) }
        // A cut track's pieces have new ids every time; their ends say the same.
        let signature = hidden.sorted() + step.removedViaIDs.sorted()
            + pieces.map { "\(pointKey($0.from))-\(pointKey($0.to))" }.sorted()
        return BoardRouteLoopPreview(
            hiddenTrackIDs: hidden,
            hiddenViaIDs: Set(step.removedViaIDs),
            pieces: pieces,
            signature: signature
        )
    }

    private func boardPadReference(at point: HorizontalPoint, layer: Int?) -> (path: String, center: HorizontalPoint)? {
        BoardTrackRouting.padReference(
            at: point,
            layer: layer,
            packagePads: board.packagePads,
            padPositions: board.packagePadPositions,
            packageHoles: board.packageHoles
        )
    }

    /// Ends the route: what its clicks laid goes to the document as one
    /// undoable step, and the tool waits for the click that starts the next
    /// route (`armDrawTrack`). A route that laid nothing just ends.
    /// Keeps what the route laid and waits for the next one, on `armingLayer`
    /// when given, else the board's drawing layer.
    private func commitDrawTrack(armingLayer: Int? = nil) {
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
        trackRouteHistory = []
        clearRouteLoopPreview()
        if state.hasDrawn {
            registerUndoSnapshot(state.originalBoard, actionName: "Draw Track")
            publishConnectivityResolvedEdit(board, sync: BoardLayoutSyncIntent(baseline: state.originalBoard, kind: .drawTrack))
        }
        armDrawTrack(layer: armingLayer)
        // The route inspector measures the next route against the board this
        // one left; the tool never stopped, so nothing else tells it.
        routeInspector?.beginRoute(on: board)
    }

    /// Return, Escape, a right-click, and the iPad's Finish and Cancel: end
    /// the route under way, keeping what its clicks laid, up to the last of
    /// them, wherever it ends, and drop the rubber band to the cursor, and
    /// the tool waits for the next route. With no route under way they
    /// leave the tool.
    private func endDrawTrack() {
        guard let state = drawTrackState else {
            return
        }
        if state.anchor != nil || state.hasDrawn {
            commitDrawTrack()
        } else {
            cancelDrawTrack()
        }
    }

    /// Leaves the tool, and takes off what a route under way has laid.
    private func cancelDrawTrack() {
        guard let state = drawTrackState else {
            return
        }
        #if canImport(HorizontalPushShoveRouter)
        endRouterSession()
        #endif
        // A route that laid nothing left the board as it was, or as a pour
        // has filled it since the tool started waiting.
        if state.hasDrawn {
            editedBoard = state.originalBoard
        }
        drawTrackState = nil
        trackRouterSession = nil
        trackRouteHistory = []
        clearRouteLoopPreview()
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
                widthSource: state.widthSource,
                layer: state.layer,
                segmentCount: state.segmentCount,
                viaCount: state.viaCount,
                placesVia: state.placesVia,
                loopStart: state.loopStart,
                routeTrackIDs: state.routeTrackIDs
            )
        )
    }

    /// `Backspace`: revert the last routing step. Pops one history entry,
    /// restoring the draft board and the route head; with no history left it
    /// clears the start anchor (back to "click to start").
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
                state.loopStart = nil
                drawTrackState = state
            }
            refreshRouteLoopPreview()
            return
        }
        editedBoard = step.board
        let layerBefore = state.layer
        state.anchor = step.anchor
        state.anchorJunctionID = step.anchorJunctionID
        state.anchorOnPad = step.anchorOnPad
        state.netID = step.netID
        state.width = step.width
        state.widthSource = step.widthSource
        state.layer = step.layer
        state.segmentCount = step.segmentCount
        state.viaCount = step.viaCount
        state.placesVia = step.placesVia
        state.layerBeforeVia = nil
        state.loopStart = step.loopStart
        state.routeTrackIDs = step.routeTrackIDs
        drawTrackState = state
        if state.layer != layerBefore {
            followRouteLayer(state.layer)
        }
        invalidateSelectableCache()
        refreshRouteLoopPreview()
    }

    /// Orthogonal two-segment routing between anchor and point, with the corner
    /// Seeds the corner posture from an existing track touching the start point,
    /// so a new branch continues in a sensible direction.
    private func boardTrackBendMode(at point: HorizontalPoint, layer: Int) -> BoardTrackBendMode? {
        BoardTrackRouting.bendModeHorizontalFirst(at: point, tracks: board.tracks.filter { $0.layer == nil || $0.layer == layer })
            .map { $0 ? .xy : .yx }
    }

    /// Resolves the net of whatever copper sits under `point`: junction, via,
    /// track (endpoint or body), package pad, or pad hole. Position-based, like
    /// the rest of Horizontal's connectivity model: only the copper a route on
    /// `layer` reaches.
    private func boardNetID(at point: HorizontalPoint, layer: Int) -> String? {
        let snapshot = board
        return BoardTrackRouting.netID(
            at: point,
            layer: layer,
            junctions: snapshot.junctions,
            junctionNetIDs: snapshot.junctionNetIDs,
            vias: snapshot.vias,
            tracks: snapshot.tracks,
            packagePads: snapshot.packagePads,
            packageHoles: snapshot.packageHoles
        )
    }

    /// The width the rules give the route where it now is, unless a custom
    /// width or the track it continues pins it (`force` takes the rules'
    /// even then).
    private func refreshRouteWidth(_ state: inout DrawTrackState, force: Bool = false) {
        guard force || state.widthSource.followsRules else {
            return
        }
        let width = HorizontalRouteWidth.fromRules(
            net: state.netID, layer: state.layer, rules: board.rules, tracks: board.tracks)
        state.width = width.width
        state.widthSource = width.source
    }

    /// A custom width set with W, in the tool settings or the inspector
    /// becomes the route's; one cleared gives it the rules' again.
    private func takeExplicitTrackWidth(_ width: Double?) {
        guard var state = drawTrackState else {
            return
        }
        if let width, width > 0 {
            guard state.width != width || state.widthSource != .custom else {
                return
            }
            state.width = width
            state.widthSource = .custom
        } else if state.widthSource == .custom {
            refreshRouteWidth(&state, force: true)
        } else {
            return
        }
        drawTrackState = state
    }

    /// The inspector's Rules: the route takes the rules' width, even one
    /// that continued a track's.
    private func useRuleTrackWidth() {
        guard var state = drawTrackState else {
            return
        }
        refreshRouteWidth(&state, force: true)
        drawTrackState = state
    }

    /// A route not yet started goes on the layer the pane picks, and takes
    /// that layer's width from the rules. One started stays on its own until
    /// a via takes it across.
    private func moveUnstartedRoute(to layer: Int) {
        guard var state = drawTrackState, state.anchor == nil,
              HorizontalBoardLayers.isCopper(layer), state.layer != layer else {
            return
        }
        state.layer = layer
        refreshRouteWidth(&state)
        drawTrackState = state
    }

    /// The board's rules changed without a reload: everything the canvas
    /// holds a board in takes the new ones and has them applied, as the
    /// document has applied them to its board, so what it commits or puts
    /// back keeps them, and a route whose width is the rules' takes their
    /// new one.
    private func adoptBoardRules() {
        let source = sourceBoard
        if var edited = editedBoard {
            edited.takeRules(of: source)
            let ruled = !HorizontalBoardRuleApplication.apply(to: &edited, poolURL: poolURL).isEmpty
            editedBoard = edited
            if ruled {
                metalSceneRevision &+= 1
                invalidateSelectableCache()
            }
        }
        for index in trackRouteHistory.indices {
            trackRouteHistory[index].board?.takeRules(of: source)
            if var board = trackRouteHistory[index].board {
                HorizontalBoardRuleApplication.apply(to: &board, poolURL: poolURL)
                trackRouteHistory[index].board = board
            }
        }
        if var state = drawTrackState {
            state.originalBoard.takeRules(of: source)
            HorizontalBoardRuleApplication.apply(to: &state.originalBoard, poolURL: poolURL)
            refreshRouteWidth(&state)
            drawTrackState = state
            if trackRouterSession != nil {
                trackRouterSession = HorizontalBoardTrackRouterSession(board: board)
            }
        }
        publishRouteInspector()
    }

    /// What the route inspector is worked out from, cheaply compared on
    /// every pass so it is fed only when something it shows has changed.
    private var routeInspectorSignature: BoardRouteInspectorSignature? {
        guard routeInspector != nil, let state = drawTrackState else {
            return nil
        }
        return BoardRouteInspectorSignature(
            layer: state.layer, netID: state.netID, width: state.width, widthSource: state.widthSource,
            anchor: state.anchor, cursor: state.cursor, bendMode: state.bendMode == .xy,
            cornerStyle: state.cornerStyle.rawValue, placesVia: state.placesVia,
            segmentCount: state.segmentCount, viaCount: state.viaCount, history: trackRouteHistory.count,
            rulesRevision: rulesRevision, previewCount: pushShovePreviewSpecs.count,
            viaDiameter: toolSettings.viaDiameter, viaHoleDiameter: toolSettings.viaHoleDiameter)
    }

    private func publishRouteInspector() {
        guard let routeInspector, let state = drawTrackState else {
            return
        }
        var route = trackPreviewPolylines(state)
        if route.isEmpty {
            if let point = state.anchor ?? state.cursor {
                route = [[point]]
            }
        }
        // The copper the route is meant to touch: where it starts and, while
        // it has no net, what its next click joins; before it starts, the
        // cursor is both.
        var connecting = [HorizontalPoint]()
        if let anchor = state.anchor {
            connecting.append(anchor)
        }
        if state.netID == nil, let cursor = state.cursor {
            connecting.append(cursor)
        }
        routeInspector.update(HorizontalRouteInspectorInput(
            board: board,
            netClasses: netClasses,
            layer: state.layer,
            netID: state.netID,
            width: state.width,
            widthSource: state.widthSource,
            hasStarted: state.anchor != nil,
            isRouterMode: isRouterMode,
            route: route,
            connecting: connecting,
            via: routeVia(netID: state.netID),
            viaArmed: state.placesVia,
            customVia: toolSettings.viaDiameter != nil || toolSettings.viaHoleDiameter != nil,
            rulesRevision: rulesRevision
        ))
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
        let color = layerColor(for: state.layer).opacity(0.5)
        if !polylines.isEmpty {
            var path = Path()
            for points in polylines where points.count >= 2 {
                path.move(to: transform.point(points[0]))
                for point in points.dropFirst() {
                    path.addLine(to: transform.point(point))
                }
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: transform.strokeWidth(state.width, minimum: 1.6),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        // Over the route, as a placed via is drawn: its diameter in green,
        // then its hole.
        if let armed = armedViaPreview(state, polylines: polylines) {
            func disc(_ diameter: Double) -> Path {
                let center = transform.point(armed.head)
                let radius = transform.length(diameter) / 2
                return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            let outline = disc(armed.via.diameter)
            let hole = disc(armed.via.holeDiameter)
            context.fill(outline, with: .color(Self.viaDiameterFill))
            context.fill(hole, with: .color(theme.background.opacity(0.95)))
            context.stroke(hole, with: .color(theme.hole.opacity(0.7)), lineWidth: transform.strokeWidth(0, minimum: 0.75))
        }
    }

    /// A via's diameter is drawn green over its copper, placed or armed on a
    /// route, so it stands out from the tracks it joins: a solid disc, with no
    /// edge.
    static let viaDiameterFill = Color(red: 0.2, green: 1, blue: 0.35)

    /// How wide airwires and drawn connection lines are at the least, in
    /// pixels: Settings' Connection lines width, 3 (twice the board's default
    /// minimum line width) unless set.
    private var connectionLineMinimumWidth: Float {
        Float(appearanceSettings.lineWidth(for: .connectionLine))
    }

    /// How wide a smashed text's line to its package is at the least, in
    /// pixels: Settings' Smashed connection lines width, the board's default
    /// minimum line width unless set.
    private var smashedConnectionLineMinimumWidth: Float {
        Float(appearanceSettings.lineWidth(for: .smashedConnectionLine))
    }

    /// Where the next click drops the armed via, and its shape: on the end of
    /// the preview, or on the end of the route itself while the cursor rests
    /// there (see `addDrawTrackPoint`). Nil with no via armed, and over a pad
    /// or where a click closes a loop, which ends the route there and drops
    /// none.
    private func armedViaPreview(
        _ state: DrawTrackState,
        polylines: [[HorizontalPoint]]
    ) -> (head: HorizontalPoint, via: HorizontalBoardViaTemplate)? {
        // A click that closes a loop ends the route there, and drops none.
        guard state.placesVia, routeLoopPreview == nil, let via = routeVia(netID: state.netID) else {
            return nil
        }
        var head = polylines.last?.last
        if head == nil, !state.anchorOnPad, let anchor = state.anchor, let cursor = state.cursor,
           pointKey(anchor) == pointKey(cursor) {
            head = anchor
        }
        guard let head, boardPadReference(at: head, layer: state.layer) == nil else {
            return nil
        }
        return (head, via)
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
              state.primitive.isRectangle else {
            return
        }
        state.rectanglePlacementMode.toggle()
        HorizontalDrawingToolSettings.setRectanglePlacementMode(state.rectanglePlacementMode)
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
        guard let state = drawTrackState else {
            return false
        }
        return routeVia(netID: state.netID) != nil
    }

    /// `v`: arm a via at the end of the route, or disarm it, as Horizon's
    /// router toggles via placement. It rides on the cursor end of the
    /// preview; the next click lays the route there and drops it at the end
    /// (see `addDrawTrackPoint`). Nothing happens where no via rule gives the
    /// route's net a via (`routeVia`).
    private func toggleVia() {
        guard !isReadOnly,
              var state = drawTrackState,
              state.anchor != nil,
              routeVia(netID: state.netID) != nil else {
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
        state.placesVia.toggle()
        drawTrackState = state
    }

    /// The via the route drops on `netID`: the board's (`HorizontalBoard.routeVia`),
    /// at the size the tool settings give a via when they give one, which
    /// makes it the via's own.
    private func routeVia(netID: String?) -> HorizontalBoardViaTemplate? {
        guard var via = board.routeVia(netID: netID) else {
            return nil
        }
        if toolSettings.viaDiameter != nil || toolSettings.viaHoleDiameter != nil {
            via.diameter = toolSettings.resolvedViaDiameter(template: via)
            via.holeDiameter = toolSettings.resolvedViaHoleDiameter(template: via)
            via.fromRules = false
        }
        return via
    }

    /// The working layer follows the route through a via, as Horizon sets its
    /// work layer to the router's, so the layer picker says where the route
    /// now runs and the next route starts there. Asked only for a change: the
    /// pane solos the layer when asked for the one it already has.
    private func followRouteLayer(_ layer: Int) {
        if drawingLayer != layer {
            onSelectDrawingLayer(layer)
        }
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
        takeExplicitTrackWidth(widthNM)
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
        switch state.outcome {
        case .plane:
            commitDrawPlane(result, state: state)
            return
        case .dimension:
            commitDrawDimension(result, state: state)
            return
        case .geometry:
            break
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
        // The plane editor on the last vertex; the drawing stays the tool's
        // draft behind it until the editor confirms or cancels.
        let nets = sortedNetOptions()
        let defaultNet = highlightedNetIDs.first.map(normalizedID).flatMap { id in nets.first { $0.id == id }?.id } ?? nets.first?.id
        let anchor = state.points.last ?? polygons[0].vertices.last ?? board.bounds.center
        planeEditorState = PlaneEditorState(
            purpose: .finishDrawing(polygons: polygons),
            worldPosition: anchor,
            layer: polygons[0].layer,
            draft: HorizontalPlaneEditorDraft(netID: defaultNet)
        )
    }

    private func finishDrawPlane(polygons: [HorizontalPolygon], draft planeDraft: HorizontalPlaneEditorDraft) {
        var draft = editedBoard ?? sourceBoard
        // Each outline is kept in its plane, as the board loads a plane's.
        for polygon in polygons {
            var plane = HorizontalPlane(polygon: polygon, draft: planeDraft)
            HorizontalBoardRuleApplication.applySettings(to: &plane, rules: draft.rules)
            draft.planes.append(plane)
        }

        drawGraphicsState = nil
        commitPlaneEdit(draft, actionName: "Draw Plane")
    }

    /// A plane editor's edit, which the document persists, registers the undo
    /// for and pours. The canvas takes the board first: once it has a board of
    /// its own (any edit makes one, and so does every pour it takes in place)
    /// it draws from it, takes a pour only for the copper in it, and commits
    /// its next edit from it, so a plane left out of it was never drawn,
    /// never filled, and dropped again by the next edit.
    private func commitPlaneEdit(_ board: HorizontalBoard, actionName: String) {
        editedBoard = board
        hoveredObject = nil
        invalidateSelectableCache()
        publishSelectionContext()
        onPlaneEdit(board, actionName)
    }

    private func isPolygonRef(_ ref: HorizontalSelectableRef) -> Bool {
        ref.type == .polygonEdge || ref.type == .polygonVertex || ref.type == .polygonArcCenter
    }

    private func planeBackedByPolygon(_ polygonID: String, in board: HorizontalBoard) -> HorizontalPlane? {
        board.planes.first { normalizedID($0.polygonID) == normalizedID(polygonID) }
    }

    /// A polygon that can become a plane: on a copper layer (Horizon's
    /// add-plane tool asks the same), not package-owned, not one already.
    private func canDefinePlane(on ref: HorizontalSelectableRef) -> Bool {
        guard isPolygonRef(ref), !normalizedID(ref.id).contains("/"),
              let polygon = boardPolygon(for: ref.id, in: board),
              let layer = polygon.layer, HorizontalBoardLayers.isCopper(layer) else {
            return false
        }
        return planeBackedByPolygon(polygon.id, in: board) == nil && keepoutBackedByPolygon(polygon.id, in: board) == nil
    }

    /// Context-menu "Define Plane": the plane editor on the right-clicked
    /// polygon; confirming adds a plane referencing it and pours.
    private func definePlaneForSelection() {
        guard !isReadOnly,
              let ref = selectedObjects.first(where: isPolygonRef),
              let polygon = boardPolygon(for: ref.id, in: board) else {
            return
        }
        // Already a plane: edit it instead of duplicating.
        guard planeBackedByPolygon(polygon.id, in: board) == nil else {
            editPlaneForSelection()
            return
        }
        // A polygon is a plane or a keepout, as Horizon's has one usage.
        guard keepoutBackedByPolygon(polygon.id, in: board) == nil,
              let layer = polygon.layer, HorizontalBoardLayers.isCopper(layer) else {
            return
        }
        let nets = sortedNetOptions()
        let defaultNet = highlightedNetIDs.first.map(normalizedID).flatMap { id in nets.first { $0.id == id }?.id } ?? nets.first?.id
        planeEditorState = PlaneEditorState(
            purpose: .define(polygonID: polygon.id),
            worldPosition: lastCursorWorldPoint ?? HorizontalRect(points: polygon.vertices).center,
            layer: polygon.layer,
            draft: HorizontalPlaneEditorDraft(netID: defaultNet)
        )
    }

    /// Context-menu "Edit Plane": the right-clicked polygon's parts alone
    /// left selected and the sidebar open on them, where the polygon's Plane
    /// section has the plane's settings.
    private func editPlaneForSelection() {
        guard let ref = selectedObjects.first(where: isPolygonRef),
              planeBackedByPolygon(ref.id, in: board) != nil else {
            return
        }
        let id = normalizedID(ref.id)
        selectedObjects = selectedObjects.filter { isPolygonRef($0) && normalizedID($0.id) == id }
        publishSelectionContext()
        onShowSelectionDetails()
    }

    private func keepoutBackedByPolygon(_ polygonID: String, in board: HorizontalBoard) -> HorizontalKeepout? {
        board.keepouts.first { !$0.id.contains("/") && normalizedID($0.polygonID) == normalizedID(polygonID) }
    }

    /// A polygon that can become a keepout: one of the board's or the
    /// package's own, not a package's on the board, a plane's outline or a
    /// keepout's already.
    private func canDefineKeepout(on ref: HorizontalSelectableRef) -> Bool {
        guard allowsKeepouts, isPolygonRef(ref), !normalizedID(ref.id).contains("/"),
              board.polygons.contains(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return false
        }
        return planeBackedByPolygon(ref.id, in: board) == nil && keepoutBackedByPolygon(ref.id, in: board) == nil
    }

    /// The polygon's parts in the selection, or `ref` alone when there are
    /// none: what Define Keepout… and Delete Keepout Definition leave
    /// selected, so the sidebar shows the polygon with its Keepout section,
    /// or without it, where it was.
    private func selectPolygonParts(of ref: HorizontalSelectableRef) {
        let id = normalizedID(ref.id)
        let parts = selectedObjects.filter { isPolygonRef($0) && normalizedID($0.id) == id }
        selectedObjects = parts.isEmpty ? [ref] : parts
    }

    /// A keepout defined on its polygon or deleted from it, a board edit as
    /// any other, which the document saves and pours planes again for.
    private func commitKeepoutEdit(_ board: HorizontalBoard, from previous: HorizontalBoard, actionName: String) {
        registerUndoSnapshot(previous, actionName: actionName)
        editedBoard = board
        hoveredObject = nil
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(board)
        publishSelectionContext()
    }

    /// Define Keepout…: the polygon a keepout at once, as Horizon's polygon
    /// becomes one, keeping out the copper on its layer, or all copper when
    /// it is on none. It stays a polygon to pick and reshape, now with a
    /// Keepout section in its details, where the sidebar opens. The keepout
    /// holds its polygon, as the board loads one.
    private func defineKeepout(on ref: HorizontalSelectableRef) {
        guard !isReadOnly, canDefineKeepout(on: ref) else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        var board = previous
        guard let polygon = board.polygons.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        board.keepouts.append(HorizontalKeepout(
            id: UUID().uuidString.lowercased(),
            polygonID: polygon.id,
            polygon: polygon,
            keepoutClass: "",
            allCopperLayers: !(polygon.layer.map(HorizontalBoardLayers.isCopper) ?? false),
            exposedCopperOnly: false,
            copperPatchTypes: Self.defaultKeepoutPatchTypes
        ))
        // The polygon is the keepout's outline now, kept in the keepout.
        board.lowerPlaneOutlines()
        selectPolygonParts(of: ref)
        commitKeepoutEdit(board, from: previous, actionName: "Define Keepout")
        onShowSelectionDetails()
    }

    /// Delete Keepout Definition, in a keepout's or its polygon's details:
    /// the keepout goes and its polygon stays, a polygon again, selected.
    private func deleteKeepoutDefinition(_ ref: HorizontalSelectableRef) {
        guard !isReadOnly else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        var board = previous
        let keepout = ref.type == .keepout
            ? board.keepouts.first { normalizedID($0.id) == normalizedID(ref.id) }
            : isPolygonRef(ref) ? keepoutBackedByPolygon(ref.id, in: board) : nil
        guard let keepout, !keepout.id.contains("/"),
              let index = board.keepouts.firstIndex(where: { normalizedID($0.id) == normalizedID(keepout.id) }) else {
            return
        }
        board.keepouts.remove(at: index)
        // patchKeepouts keeps entries the model lacks.
        board.removedKeepoutIDs.insert(keepout.id)
        board.polygons.append(keepout.polygon)
        selectPolygonParts(of: isPolygonRef(ref) ? ref : HorizontalSelectableRef(
            id: keepout.polygon.id, type: .polygonEdge, vertex: 0, layer: keepout.polygon.layer))
        commitKeepoutEdit(board, from: previous, actionName: "Delete Keepout")
    }

    /// Context-menu "Edit Keepout": the right-clicked polygon's parts alone
    /// left selected and the sidebar open on them, where the polygon's
    /// Keepout section has the keepout's options.
    private func editKeepoutForSelection() {
        guard let ref = selectedObjects.first(where: { isPolygonRef($0) && keepoutBackedByPolygon($0.id, in: board) != nil })
                ?? selectedObjects.first(where: { $0.type == .keepout }) else {
            return
        }
        if ref.type == .keepout {
            setSelectedObject(ref)
        } else {
            let id = normalizedID(ref.id)
            selectedObjects = selectedObjects.filter { isPolygonRef($0) && normalizedID($0.id) == id }
            publishSelectionContext()
        }
        onShowSelectionDetails()
    }

    /// Delete Plane Definition, in a plane's or its outline's details: the
    /// plane goes and its polygon stays, a polygon again, selected.
    private func deletePlaneDefinition(outlinedBy ref: HorizontalSelectableRef) {
        guard !isReadOnly else {
            return
        }
        let plane = ref.type == .plane
            ? board.planes.first { normalizedID($0.id) == normalizedID(ref.id) }
            : isPolygonRef(ref) ? planeBackedByPolygon(ref.id, in: board) : nil
        guard let plane, !plane.id.contains("/") else {
            return
        }
        removePlane(plane.id, actionName: "Delete Plane")
        if let outline = plane.fallbackPolygon {
            setSelectedObject(HorizontalSelectableRef(id: outline.id, type: .polygonEdge,
                                                      vertex: isPolygonRef(ref) ? ref.vertex : 0, layer: outline.layer))
        }
    }

    /// The plane out of the board and the file, its polygon kept a polygon:
    /// patchPlanes keeps entries the model lacks, so the removal is flagged
    /// rather than inferred from absence.
    private func removePlane(_ planeID: String, actionName: String) {
        var board = editedBoard ?? sourceBoard
        let liftedOutlines = board.liftPlaneOutlines()
        board.planes.removeAll { normalizedID($0.id) == normalizedID(planeID) }
        board.removedPlaneIDs.insert(planeID)
        board.lowerPlaneOutlines(lifted: liftedOutlines)
        selectedObjects = []
        commitPlaneEdit(board, actionName: actionName)
    }

    private func confirmPlaneEditor(_ draft: HorizontalPlaneEditorDraft) {
        guard !isReadOnly, let state = planeEditorState else {
            return
        }
        planeEditorState = nil
        var board = editedBoard ?? sourceBoard
        switch state.purpose {
        case .define(let polygonID):
            guard let polygon = boardPolygon(for: polygonID, in: board),
                  planeBackedByPolygon(polygon.id, in: board) == nil else {
                return
            }
            var plane = HorizontalPlane(polygon: polygon, draft: draft)
            HorizontalBoardRuleApplication.applySettings(to: &plane, rules: board.rules)
            board.planes.append(plane)
            // The polygon is the plane's outline now, kept in the plane as
            // the board loads it, and no polygon of the board's own.
            board.lowerPlaneOutlines()
            // The polygon stays selected, its Plane section now in the sidebar.
            if !selectedObjects.contains(where: { isPolygonRef($0) && normalizedID($0.id) == normalizedID(polygon.id) }) {
                selectedObjects = [HorizontalSelectableRef(id: polygon.id, type: .polygonEdge, vertex: 0, layer: polygon.layer)]
            }
            commitPlaneEdit(board, actionName: "Define Plane")
            onShowSelectionDetails()
        case .edit(let planeID):
            guard let index = board.planes.firstIndex(where: { normalizedID($0.id) == normalizedID(planeID) }) else {
                return
            }
            board.planes[index].apply(draft)
            HorizontalBoardRuleApplication.applySettings(to: &board.planes[index], rules: board.rules)
            commitPlaneEdit(board, actionName: "Edit Plane")
        case .finishDrawing(let polygons):
            finishDrawPlane(polygons: polygons, draft: draft)
        }
    }

    private func deletePlaneFromEditor() {
        guard !isReadOnly, let state = planeEditorState, case .edit(let planeID) = state.purpose else {
            return
        }
        planeEditorState = nil
        // The polygon stays, a polygon again; only the plane over it goes.
        removePlane(planeID, actionName: "Delete Plane")
    }

    private func cancelPlaneEditor() {
        guard let state = planeEditorState else {
            return
        }
        planeEditorState = nil
        if case .finishDrawing = state.purpose {
            cancelDrawGraphics()
        }
    }

    /// True for a standalone board polygon that can convert to a line loop — not a
    /// plane's or a keepout's outline (that would orphan it) and not
    /// package-owned geometry.
    private func isConvertiblePolygon(_ ref: HorizontalSelectableRef) -> Bool {
        guard isPolygonRef(ref), !normalizedID(ref.id).contains("/") else {
            return false
        }
        guard let polygon = boardPolygon(for: ref.id, in: board), !polygon.id.contains("/") else {
            return false
        }
        return planeBackedByPolygon(polygon.id, in: board) == nil && keepoutBackedByPolygon(polygon.id, in: board) == nil
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
        selectedObjects = BoardPolygonParts.wholeSelection(of: result.polygon)
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

    /// Board nets as `(id, name)` choices, sorted by display name. Shared by the
    /// draw-plane net prompt and the plane inspector's Net picker.
    private func sortedNetOptions() -> [HorizontalSelectionPropertyOption] {
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

    @discardableResult
    private func mergeBoardJunctions(
        at point: HorizontalPoint,
        preferredID: String?,
        netID: String?,
        board: inout HorizontalBoard
    ) -> String {
        BoardTrackRouting.mergeJunctions(at: point, preferredID: preferredID, netID: netID, board: &board)
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
                    HorizontalPolygon(id: UUID().uuidString.lowercased(), polygonVertices: $0, layer: layer)
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
              poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil,
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
        // A polygon edge's next is the edge across the gap it left, so the
        // next Delete goes on along the outline.
        let polygonNext = unique.count == 1
            ? polygonEdgeSelection(afterDeleting: unique[0], from: previousBoard, to: draft)
            : nil
        registerUndoSnapshot(previousBoard, actionName: "Delete")
        editedBoard = draft
        // The next build draws again only the copper whose net the delete
        // changed and the rats' nest, and replays the rest
        // (`BoardSceneObjectCache`), as a splice of the old scene once did.
        invalidateSelectableCache()
        // The neighbour (if any) wasn't deleted, so its ref stays valid through
        // the connectivity recompute below; selecting it renders it highlighted.
        selectedObjects = (chainNext ?? polygonNext).map { [$0] } ?? []
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previousBoard, kind: .delete))
        publishSelectionContext()
    }

    /// Removes a selected junction once nothing meets it any more: the tracks,
    /// net ties, lines and arcs that end on it go with it
    /// (`expandedBoardDeleteRefs`), as Horizon's delete takes them, and a via
    /// standing on it keeps it. A delete commit re-runs connectivity (`vacuum`)
    /// to clear any junctions the removed copper orphaned.
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

    /// The board hole entry a hole belongs to: its own id, or the id its
    /// padstack's holes are numbered under ("<id>/hole/<n>").
    private func boardHoleEntryID(_ id: String) -> String {
        let id = normalizedID(id)
        guard let range = id.range(of: "/hole/", options: .backwards) else {
            return id
        }
        return String(id[..<range.lowerBound])
    }

    private func deleteSelectedObjects(from board: inout HorizontalBoard) -> Bool {
        // A plane's outline is deleted as a polygon, and takes its plane with it.
        let liftedOutlines = board.liftPlaneOutlines()
        defer { board.lowerPlaneOutlines(lifted: liftedOutlines) }
        var changed = false
        // Fixed packages can't be deleted — filter them (and their connection
        // lines, added by the expansion) before expanding the delete set.
        // Nor can locked copper (`BoardCopperLock`), before and after.
        let deletable = BoardCopperLock.removingHeld(uniqueRefs(selectedObjects), in: board).filter { !isFixedPackage($0, in: board) }
        // Junctions last, once what ends on them is gone.
        let refs = BoardCopperLock.removingHeld(expandedBoardDeleteRefs(from: deletable, in: board), in: board).sorted {
            ($0.type == .junction ? 1 : 0) < ($1.type == .junction ? 1 : 0)
        }

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
                // patchVias keeps entries the model lacks, so the removal is
                // flagged rather than inferred from absence.
                if removeElement(from: &board.vias, matching: ref) {
                    board.removedViaIDs.insert(ref.id)
                    changed = true
                }
                let normalizedViaID = normalizedID(ref.id)
                changed = removeAll(from: &board.viaHoles) {
                    normalizedID($0.id) == normalizedViaID || normalizedID($0.id).hasPrefix("\(normalizedViaID)/")
                } || changed
            case .boardHole:
                if modeProfile.mode == .board {
                    // The whole board hole goes, every hole of its padstack,
                    // and patchHoles keeps entries the model lacks.
                    let entryID = boardHoleEntryID(ref.id)
                    if removeAll(from: &board.holes, where: { boardHoleEntryID($0.id) == entryID }) {
                        board.removedHoleIDs.insert(entryID)
                        changed = true
                    }
                } else {
                    changed = removeElement(from: &board.holes, matching: ref) || changed
                }
                changed = removeElement(from: &board.packageHoles, matching: ref) || changed
                changed = removeElement(from: &board.viaHoles, matching: ref) || changed
            case .text:
                changed = removeElement(from: &board.texts, matching: ref) || changed
                changed = removeElement(from: &board.packageTexts, matching: ref) || changed
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                changed = deletePolygonVertices(ref, from: &board.polygons) || changed
                // One left with too few points is gone, which patchPolygons
                // takes only from the flag.
                if !ref.id.contains("/"), !board.polygons.contains(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                    board.removedPolygonIDs.insert(ref.id)
                }
            case .plane:
                // patchPlanes keeps entries the model lacks, as patchVias does.
                if removeElement(from: &board.planes, matching: ref) {
                    board.removedPlaneIDs.insert(ref.id)
                    changed = true
                }
            case .keepout:
                // With its outline, as Horizon's keepout goes with its polygon;
                // the writer keeps both entries unless they are flagged.
                if let keepout = board.keepouts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }),
                   removeElement(from: &board.keepouts, matching: ref) {
                    if !keepout.id.contains("/") {
                        board.removedKeepoutIDs.insert(keepout.id)
                        board.removedPolygonIDs.insert(keepout.polygonID)
                    }
                    changed = true
                }
            case .dimension:
                // patchDimensions preserves unknown entries, so the removal is
                // flagged rather than inferred from absence.
                if removeElement(from: &board.dimensions, matching: ref) {
                    board.removedDimensionIDs.insert(ref.id)
                    changed = true
                }
            case .boardDecal:
                // patchDecals keeps entries the model lacks.
                if removeElement(from: &board.decals, matching: ref) {
                    if !ref.id.contains("/") {
                        board.removedDecalIDs.insert(ref.id)
                    }
                    changed = true
                }
            case .connectionLine:
                changed = removeElement(from: &board.connectionLines, matching: ref) || changed
            case .boardPanel:
                changed = deleteBoardPanel(ref.id, from: &board) || changed
            case .junction:
                changed = deleteOrphanJunction(ref.id, from: &board) || changed
            case .pad:
                if modeProfile.mode == .package {
                    changed = deletePoolPad(ref: ref, from: &board) || changed
                }
            case .padstackShape:
                changed = deletePadstackShape(ref: ref, from: &board) || changed
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

        let junctionLayers = refs.contains { $0.type == .junction } ? board.junctionLayers() : [:]
        for ref in refs {
            switch ref.type {
            case .junction:
                board.refsEnding(onJunction: ref.id, layers: junctionLayers).forEach(append)
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
            BoardMovePlanner.geometryID(geometryID, belongsToPackage: normalizedPackageID)
        }

        changed = removeAll(from: &board.packagePads) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageHoles) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packagePolygons) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageLines) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageArcs) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.packageTexts) { belongsToPackage($0.id) } || changed
        changed = removeAll(from: &board.keepouts) { belongsToPackage($0.id) } || changed
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

    /// The edge to select once `ref`, a polygon's edge, is deleted: the one
    /// joining the vertices either side of the gap
    /// (`HorizontalPolygonEdgeDeletion`), in a board's polygon or a plane's
    /// outline; nil for anything else, or when the polygon went with it.
    private func polygonEdgeSelection(
        afterDeleting ref: HorizontalSelectableRef,
        from before: HorizontalBoard,
        to after: HorizontalBoard
    ) -> HorizontalSelectableRef? {
        guard ref.type == .polygonEdge else {
            return nil
        }
        func polygon(in board: HorizontalBoard) -> HorizontalPolygon? {
            board.polygons.first { normalizedID($0.id) == normalizedID(ref.id) }
                ?? board.outlinePolygons.first { normalizedID($0.id) == normalizedID(ref.id) }
        }
        guard let old = polygon(in: before), let new = polygon(in: after),
              new.polygonVertices.count == old.polygonVertices.count - 2,
              let index = HorizontalPolygonEdgeDeletion.edgeIndex(afterDeleting: ref.vertex, vertexCount: old.polygonVertices.count),
              new.polygonVertices.indices.contains(index) else {
            return nil
        }
        return HorizontalSelectableRef(id: new.id, type: .polygonEdge, vertex: index, layer: new.layer)
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
            BoardMovePlanner.geometryID(geometryID, belongsToPackage: normalizedPackageID)
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
        if poolPlacementState != nil {
            mirrorPoolPlacement()
            return
        }
        if packagePlacementState != nil {
            transformPlacingPackage { center, draft in
                mirrorSelectedObjects(around: center, board: &draft)
            }
            return
        }
        if var state = roundOffVertexState {
            // Horizon's "flip arc" (also E): the arc bulges the other way.
            state.reverse.toggle()
            roundOffVertexState = state
            return
        }
        let cursor = transformPivotCursor
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

    /// Edit ▸ Align and Edit ▸ Distribute (`BoardAlignment`): each object
    /// moved on its own by what lines it up, its copper following as a move
    /// takes it, all as one undoable edit. A fixed package stays. Left and
    /// right are the screen's, so they swap seen from below.
    private func alignSelection(_ operation: BoardAlignOperation) {
        guard !isReadOnly, moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, packagePlacementState == nil,
              roundOffVertexState == nil, addVertexState == nil, tuneState == nil else {
            return
        }
        let previousBoard = editedBoard ?? sourceBoard
        let lookup = boardSelectablesByRef()
        let items = BoardAlignment.items(for: selectedObjects, in: previousBoard) { BoardAlignment.bounds(of: lookup[$0] ?? []) }
        let offsets = BoardAlignment.offsets(operation.onBoard(viewMirrored: viewport.mirrored), items: items)
        guard !offsets.isEmpty else {
            return
        }
        var draft = previousBoard
        var points = BoardMovingPoints()
        for (ref, delta) in offsets.sorted(by: { $0.key.id < $1.key.id }) {
            switch ref.type {
            case .boardPackage: moveBoardPackage(ref: ref, by: delta, board: &draft)
            case .via: moveVia(ref: ref, by: delta, in: previousBoard, points: &points)
            case .boardHole: moveHole(&draft.holes, ref: ref, by: delta)
            case .boardDecal: moveBoardDecal(&draft.decals, ref: ref, by: delta)
            case .text: moveText(&draft.texts, ref: ref, by: delta)
            default: break
            }
        }
        points.apply(from: previousBoard, to: &draft)
        registerUndoSnapshot(previousBoard, actionName: operation.actionName)
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previousBoard, kind: .transform))
        publishSelectionContext()
    }

    private func rotateSelection() {
        if poolPlacementState != nil {
            rotatePoolPlacement()
            return
        }
        if packagePlacementState != nil {
            transformPlacingPackage(turn: BoardSelectionTurn(angle: Self.quarterTurnAngle, aboutCursor: false)) { center, draft in
                rotateSelectedObjects(around: center, by: Self.quarterTurnAngle, board: &draft)
            }
            return
        }
        let cursor = transformPivotCursor
        transformSelection(actionName: "Rotate", turn: BoardSelectionTurn(angle: Self.quarterTurnAngle, aboutCursor: true)) { center, draft in
            rotateSelectedObjects(around: cursor ?? center, by: Self.quarterTurnAngle, board: &draft)
        }
    }

    /// Rotate 90° around the selection center, independent of the cursor.
    private func rotateSelectionAroundCenter() {
        transformSelection(actionName: "Rotate", turn: BoardSelectionTurn(angle: Self.quarterTurnAngle, aboutCursor: false)) { center, draft in
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

    /// The point R, E and T turn and flip about, when not the selection's
    /// pivot: the cursor, and only in a move that follows it, where the
    /// pointer holds what moves. A selection at rest (124) and a move made with
    /// the arrow keys (123) turn about what they hold, since the pointer may be
    /// resting anywhere on the canvas. It is where the
    /// move has taken the grabbed point.
    private var transformPivotCursor: HorizontalPoint? {
        moveState?.tracksCursor == true ? moveState?.lastPoint : nil
    }

    /// T, Horizon's "rotate around cursor": a selection at rest turns about
    /// the point under the cursor, as `HorizontalCanvasModeSupport.cursorAnchor`
    /// picks it; one being moved, as R does, about what the cursor holds.
    private func twirlSelection() {
        let cursor = transformPivotCursor ?? (moveState == nil ? boardCursorPivot() : nil)
        transformSelection(actionName: "Rotate", turn: BoardSelectionTurn(angle: Self.quarterTurnAngle, aboutCursor: true)) { center, draft in
            rotateSelectedObjects(around: cursor ?? center, by: Self.quarterTurnAngle, board: &draft)
        }
    }

    private func boardCursorPivot() -> HorizontalPoint? {
        lastCursorWorldPoint.map { cursor in
            HorizontalCanvasModeSupport.cursorAnchor(
                cursor: cursor,
                cursorIsOnSelection: boardSnapTargetKeys(for: selectedObjects).contains(pointKey(cursor)),
                snapToGrid: snapBoardPointToGrid
            )
        }
    }

    /// `turn` says what `transform` does when it is a turn, so a move can
    /// make it in place (122); anything else rebuilds the move.
    private func transformSelection(
        actionName: String,
        turn: BoardSelectionTurn? = nil,
        _ transform: (HorizontalPoint, inout HorizontalBoard) -> Void
    ) {
        guard !isReadOnly,
              !selectedObjects.isEmpty,
              let center = boardSelectionPivot(in: board) else {
            return
        }

        if moveState?.copperDrag != nil {
            // A drag shapes the copper it holds; it takes no turn.
            return
        }
        if var state = moveState, packagePlacementState == nil {
            // R, E and T while moving turn what is being moved, where the
            // cursor has taken it, and the move carries on from the turned
            // copy, as the schematic's does (105). The board itself is left
            // alone until the commit, so Esc still puts everything back.
            var draft = boardMovePreviewBoard(for: state)
            // The pivot of the selection where it is now: `board` is still the
            // pre-move board while the move is patched in Metal.
            let movedCenter = boardSelectionPivot(in: draft) ?? center
            transform(movedCenter, &draft)
            if let turn, canTurnBoardMoveInPlace(by: turn.angle) {
                // A quarter turn of what the scene can turn whole is made the
                // way the move itself is (122): the resident copy is drawn
                // turned, and nothing is rebuilt. The pivot is the one the
                // transform used.
                let pivot = turn.aboutCursor ? (transformPivotCursor ?? movedCenter) : movedCenter
                state.turn = BoardMoveTurn(
                    board: draft,
                    placement: turned(state.livePlacement, about: pivot, by: turn.angle),
                    count: (state.turn?.count ?? 0) + 1
                )
                state.startPoint = state.lastPoint
                moveState = state
                hoveredObject = nil
                publishSelectionContext()
                return
            }
            if state.boardBeforeMove == nil {
                state.boardBeforeMove = state.originalBoard
            }
            state.originalBoard = draft
            state.turn = nil
            state.startPoint = state.lastPoint
            moveState = state
            invalidateSelectableCache()
            state.residentMovePlan = boardResidentMovePlan(for: selectedObjects, in: draft)
            state.airwireRequest = startMovingAirwires(plan: state.residentMovePlan, board: draft)
            moveState = state
            hoveredObject = nil
            publishSelectionContext()
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
            publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previousBoard, kind: .transform))
        }
        publishSelectionContext()
    }

    /// The point R and E turn and flip the selection about
    /// (`HorizontalCanvasModeSupport.selectionPivot`). A group's goes onto the
    /// board grid only when everything that places it is on that grid
    /// already: a board holds parts placed off the grid on purpose, and those
    /// turn about their exact middle, as Horizon turns a board's selection.
    /// A block instance selected whole turns and flips about its anchor
    /// instead, where Instance X and Y place it.
    private func boardSelectionPivot(in board: HorizontalBoard) -> HorizontalPoint? {
        if let anchor = selectedInstanceAnchor(in: board) {
            return anchor
        }
        return HorizontalCanvasModeSupport.selectionPivot(
            for: selectedObjects,
            origins: { selectionAnchorPoints(for: $0, in: board) },
            snapToGrid: { center, origins in
                origins.allSatisfy { HorizontalCanvasModeSupport.isOnGrid($0, snapToGrid: snapBoardPointToGrid) }
                    ? snapBoardPointToGrid(center)
                    : center
            }
        )
    }

    /// Whether the move in progress can take a turn by `angle` in place (122):
    /// a whole number of quarter turns, on a move patched in Metal, of things
    /// whose turn in the model is the same rigid turn of what the scene drew.
    /// Tracks, junctions and the rest are left to the rebuild: the model turns
    /// a track's connections its own way, and keepouts, planes, dimensions
    /// and decals don't turn at all.
    private func canTurnBoardMoveInPlace(by angle: Int) -> Bool {
        guard wrappedAngle(angle) % 16_384 == 0,
              canPatchBoardMoveInMetal,
              let moveState else {
            return false
        }
        let turnsRigidly = selectedObjects.allSatisfy { ref in
            switch ref.type {
            case .boardPackage, .pad, .via, .boardHole, .boardLine, .boardArc, .text:
                return true
            default:
                return false
            }
        }
        guard turnsRigidly else {
            return false
        }
        // The scene the move is patching, as the next body pass will ask for
        // it: its texts are what the turn will redraw.
        let textSpans = boardMetalLineBatch(renderLayers: boardMetalRenderLayers()).metadata.textSpansByRef
        let strokes = moveState.residentMovePlan.translatedRefs.reduce(0) { total, ref in
            total + (textSpans[ref]?.reduce(0) { $0 + $1.count } ?? 0)
        }
        return strokes <= Self.maximumTurnedTextStrokes
    }

    /// `placement` followed by a turn about `pivot`.
    private func turned(_ placement: HorizontalPlacementTransform, about pivot: HorizontalPoint, by angle: Int) -> HorizontalPlacementTransform {
        let turn = HorizontalPlacementTransform(shift: .zero, angle: angle, mirrored: false)
        return HorizontalPlacementTransform(
            shift: turn.applying(to: placement.shift - pivot) + pivot,
            angle: placement.angle + angle,
            mirrored: false
        )
    }

    private func selectionAnchorPoints(for ref: HorizontalSelectableRef) -> [HorizontalPoint] {
        selectionAnchorPoints(for: ref, in: board)
    }

    /// `selectionAnchorPoints(for:in:)` for many refs at once, the
    /// collections they name indexed by id once (`netIDLookup`).
    private func selectionAnchorPointLookup(
        for refs: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> (HorizontalSelectableRef) -> [HorizontalPoint] {
        guard refs.count > 32 else {
            return { selectionAnchorPoints(for: $0, in: board) }
        }
        let types = Set(refs.map(\.type))
        func index<Item>(_ type: HorizontalObjectType, _ items: [Item], id: (Item) -> String, points: (Item) -> [HorizontalPoint]) -> [String: [HorizontalPoint]] {
            guard types.contains(type) else {
                return [:]
            }
            var result = [String: [HorizontalPoint]](minimumCapacity: items.count)
            for item in items where result[normalizedID(id(item))] == nil {
                result[normalizedID(id(item))] = points(item)
            }
            return result
        }
        let packages = index(.boardPackage, board.packages, id: \.id) { [$0.position] }
        let tracks = index(.track, board.tracks, id: \.id) { [$0.from, $0.to] }
        let netTies = index(.boardNetTie, board.netTies, id: \.id) { [$0.from, $0.to] }
        let lines = index(.boardLine, board.lines, id: \.id) { [$0.from, $0.to] }
        let connectionLines = index(.connectionLine, board.connectionLines, id: \.id) { [$0.from, $0.to] }
        let arcs = index(.boardArc, board.arcs, id: \.id) { [$0.from, $0.to, $0.center] }
        let vias = index(.via, board.vias, id: \.id) { [$0.position] }
        let holes = index(.boardHole, board.holes + board.packageHoles + board.viaHoles, id: \.id) { [$0.position] }
        let texts = index(.text, board.texts + board.packageTexts, id: \.id) { [$0.position] }
        let junctions = types.contains(.junction)
            ? Dictionary(board.junctions.map { (normalizedID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
            : [:]
        return { ref in
            let id = normalizedID(ref.id)
            switch ref.type {
            case .boardPackage: return packages[id] ?? []
            case .track: return tracks[id] ?? []
            case .boardNetTie: return netTies[id] ?? []
            case .boardLine: return lines[id] ?? []
            case .connectionLine: return connectionLines[id] ?? []
            case .boardArc: return arcs[id] ?? []
            case .via: return vias[id] ?? []
            case .boardHole: return holes[id] ?? []
            case .text: return texts[id] ?? []
            case .junction: return junctions[id].map { [$0] } ?? []
            default: return selectionAnchorPoints(for: ref, in: board)
            }
        }
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
            if modeProfile.mode == .package {
                return poolPad(for: ref, in: board).map { [$0.placement.shift] } ?? []
            }
            return board.packagePads.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [HorizontalRect(points: $0.vertices).center] } ?? []
        case .padstackShape:
            return padstackShape(for: ref, in: board).map { [$0.placement.shift] } ?? []
        case .polygonArcCenter:
            guard let polygon = boardPolygon(for: ref.id, in: board),
                  polygon.polygonVertices.indices.contains(ref.vertex) else {
                return []
            }
            return [polygon.polygonVertices[ref.vertex].arcCenter]
        case .polygonEdge, .polygonVertex:
            // The points the ref moves (`BoardPolygonParts`): an edge's two
            // ends, a vertex itself. The rest of the polygon stays put, so it
            // is no part of the pivot and stays a snap target.
            guard let polygon = boardPolygon(for: ref.id, in: board) else {
                return []
            }
            return BoardPolygonParts.parts(of: ref, in: polygon).vertices.sorted().map {
                polygon.polygonVertices[$0].position
            }
        case .keepout:
            return board.keepouts.first { normalizedID($0.id) == normalizedID(ref.id) }?.points ?? []
        case .dimension:
            // The point the part stands for: one of the two, or the label's origin.
            return board.dimensions.first { normalizedID($0.id) == normalizedID(ref.id) }
                .flatMap { BoardDimensionParts.anchor(of: $0, part: ref.vertex) }
                .map { [$0] } ?? []
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
            return board.dimensions.first { normalizedID($0.id) == normalizedID(ref.id) }
                .flatMap { BoardDimensionParts.anchor(of: $0, part: ref.vertex) }
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
            vias: board.vias,
            padPositions: BoardCopperLock.pinnedEndPositions(board)
        )
    }

    private func boardResidentMovePlan(
        for refs: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> BoardResidentMovePlan {
        var plan = BoardMovePlanner.residentMovePlan(
            for: refs,
            tracks: board.tracks,
            netTies: board.netTies,
            junctions: board.junctions,
            junctionNetIDs: board.junctionNetIDs,
            vias: board.vias,
            packagePads: board.packagePads,
            packageHoles: board.packageHoles,
            padPositions: BoardCopperLock.pinnedEndPositions(board)
        )
        // Polygon parts share their polygon's resident spans, which a shift
        // moves whole. One with a point left behind (an edge moved alone, a
        // vertex) changes shape, so it is previewed from a rebuilt scene.
        let reshaped = BoardPolygonParts.reshapedPolygonIDs(
            by: refs, in: board.polygons + board.outlinePolygons
        )
        if !reshaped.isEmpty {
            plan.unsupportedRefs.formUnion(refs.filter {
                BoardPolygonParts.isPart($0.type) && reshaped.contains(normalizedID($0.id))
            })
        }
        // So does a dimension with one point, or only its label, moving: the
        // shift of its spans draws only a dimension that moves whole.
        let dimensionParts = BoardDimensionParts.selectedParts(in: refs)
        plan.unsupportedRefs.formUnion(refs.filter {
            $0.type == .dimension && !BoardDimensionParts.movesWhole(dimensionParts[normalizedID($0.id)] ?? [])
        })
        // And whatever else the patches don't draw: a pad or smashed text whose
        // package stays, anything of the schematic's.
        let movingPackageIDs = Set(refs.filter { $0.type == .boardPackage }.map { normalizedID($0.id) })
        plan.unsupportedRefs.formUnion(refs.filter {
            !isBoardMetalMovePatchable($0, movingPackageIDs: movingPackageIDs)
        })
        // And a junction that carries the end of a line or arc the selection
        // doesn't move whole, which the plan's track patches leave behind.
        let junctionRefs = refs.filter { $0.type == .junction }
        if !junctionRefs.isEmpty {
            let movedWhole = Set(refs.map { normalizedID($0.id) })
            var carriedEnds = Set<String>()
            for segment in board.lines + board.connectionLines where !movedWhole.contains(normalizedID(segment.id)) {
                carriedEnds.insert(pointKey(segment.from))
                carriedEnds.insert(pointKey(segment.to))
            }
            for arc in board.arcs where !movedWhole.contains(normalizedID(arc.id)) {
                carriedEnds.formUnion([arc.from, arc.to, arc.center].map(pointKey))
            }
            if !carriedEnds.isEmpty {
                let junctionPoints = Dictionary(
                    board.junctions.map { (normalizedID($0.key), $0.value) },
                    uniquingKeysWith: { first, _ in first }
                )
                plan.unsupportedRefs.formUnion(junctionRefs.filter { ref in
                    junctionPoints[normalizedID(ref.id)].map { carriedEnds.contains(pointKey($0)) } ?? false
                })
            }
        }
        return plan
    }

    /// The packages of `selectedObjects` that move (a fixed one stays),
    /// normalized. Each carries its texts, smashed refdes too, so a selected
    /// text of one is not moved, turned or mirrored again
    /// (`isCarriedByPackage`), as Horizon's move adds a package's texts to the
    /// selection and moves each once.
    private func movingPackageIDs(in board: HorizontalBoard) -> Set<String> {
        Set(selectedObjects.filter { $0.type == .boardPackage && !isFixedPackage($0, in: board) }.map { normalizedID($0.id) })
    }

    private func isCarriedByPackage(_ ref: HorizontalSelectableRef, movingPackageIDs: Set<String>) -> Bool {
        guard !movingPackageIDs.isEmpty, let packageID = packageID(forGeometryID: ref.id) else {
            return false
        }
        return movingPackageIDs.contains(normalizedID(packageID))
    }

    private func moveSelectedObjects(by delta: HorizontalPoint, board: inout HorizontalBoard) {
        // A plane's outline moves as a polygon, with the board's own.
        let liftedOutlines = board.liftPlaneOutlines()
        defer { board.lowerPlaneOutlines(lifted: liftedOutlines) }
        // Junctions and vias, and what stands on them, move once, after the
        // rest, matched against the board as it was (`BoardMovingPoints`).
        let original = board
        var movingPoints = BoardMovingPoints()
        var padEnds = BoardTrackPadEnds(padPositions: BoardCopperLock.pinnedEndPositions(original))
        var movedLayerVertexKeys = Set<String>()
        let selectedRefSet = Set(selectedObjects)
        var movedPolygonPoints = Set<String>()
        let dimensionParts = BoardDimensionParts.selectedParts(in: selectedObjects)
        var movedDimensionIDs = Set<String>()
        let movingPackageIDs = self.movingPackageIDs(in: original)
        let packageGeometry = BoardPackageGeometry.index(of: original, packageIDs: movingPackageIDs)
        // Lines, arcs and connection lines the selection moves whole; a
        // selected junction carries the ends of the rest.
        let graphicsMovedWhole = Set(
            selectedObjects
                .filter { $0.type == .boardLine || $0.type == .boardArc || $0.type == .connectionLine }
                .map { normalizedID($0.id) }
        )

        // A track or net tie with a junction, via or package the selection
        // moves at either end goes with that. Who owns the ends is gathered
        // once, at the first: asked end by end, every package's pads were read
        // again for each (Select All on Board C, 22 s a nudge).
        var segmentEnds: BoardMovePlanner.SegmentEndOwners?
        func hasSelectedEndpointOwner(_ ref: HorizontalSelectableRef) -> Bool {
            if segmentEnds == nil {
                segmentEnds = BoardMovePlanner.SegmentEndOwners(
                    tracks: original.tracks, netTies: original.netTies,
                    junctions: original.junctions, junctionNetIDs: original.junctionNetIDs, vias: original.vias,
                    packages: original.packages, packagePads: original.packagePads, packageHoles: original.packageHoles,
                    includesPackages: true
                )
            }
            return segmentEnds?.refs(of: ref).contains { selectedRefSet.contains($0) } ?? false
        }

        for ref in BoardCopperLock.removingHeld(selectedObjects, in: original) {
            switch ref.type {
            case .boardPackage:
                moveBoardPackage(ref: ref, by: delta, board: &board, geometry: packageGeometry[normalizedID(ref.id)])
            case .track:
                if hasSelectedEndpointOwner(ref) {
                    break
                }
                moveBoardTrack(ref: ref, by: delta, in: \.tracks, original: original, board: &board, points: &movingPoints, padEnds: &padEnds)
            case .boardNetTie:
                if hasSelectedEndpointOwner(ref) {
                    break
                }
                moveBoardTrack(ref: ref, by: delta, in: \.netTies, original: original, board: &board, points: &movingPoints, padEnds: &padEnds)
            case .boardLine:
                moveBoardLayerSegmentSelection(&board.lines, ref: ref, by: delta, movedKeys: &movedLayerVertexKeys)
            case .junction:
                moveBoardJunction(ref: ref, by: delta, in: original, points: &movingPoints)
            case .boardArc:
                moveArc(&board.arcs, ref: ref, by: delta)
            case .via:
                moveVia(ref: ref, by: delta, in: original, points: &movingPoints)
            case .boardHole:
                moveHole(&board.holes, ref: ref, by: delta)
                moveHole(&board.packageHoles, ref: ref, by: delta)
                moveHole(&board.viaHoles, ref: ref, by: delta)
            case .text:
                if isCarriedByPackage(ref, movingPackageIDs: movingPackageIDs) {
                    break
                }
                moveText(&board.texts, ref: ref, by: delta)
                moveText(&board.packageTexts, ref: ref, by: delta)
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                BoardPolygonParts.change(&board.polygons, ref: ref, done: &movedPolygonPoints) { $0 + delta }
            case .pad:
                if modeProfile.mode == .package {
                    movePoolPad(ref: ref, by: delta, board: &board)
                } else {
                    movePolygon(&board.packagePads, ref: ref, by: delta)
                }
            case .padstackShape:
                movePadstackShape(ref: ref, by: delta, board: &board)
            case .connectionLine:
                moveBoardLayerSegmentSelection(&board.connectionLines, ref: ref, by: delta, movedKeys: &movedLayerVertexKeys)
            case .keepout:
                moveKeepout(&board.keepouts, ref: ref, by: delta)
            case .dimension:
                moveDimension(&board.dimensions, ref: ref, parts: dimensionParts, by: delta, done: &movedDimensionIDs)
            case .boardDecal:
                moveBoardDecal(&board.decals, ref: ref, by: delta)
            case .plane:
                movePlane(&board.planes, ref: ref, by: delta, polygons: &board.polygons, done: &movedPolygonPoints)
            case .boardPanel:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }
        // A plane whose polygon moved whole takes its fills along, as a plane
        // moved itself does, until it is poured again where it now is. One
        // whose polygon changed shape keeps them until that pour.
        let movedPlaneIDs = Set(selectedObjects.filter { $0.type == .plane }.map { normalizedID($0.id) })
        for index in board.planes.indices where !movedPlaneIDs.contains(normalizedID(board.planes[index].id)) {
            let polygonID = normalizedID(board.planes[index].polygonID)
            guard let polygon = original.polygons.first(where: { normalizedID($0.id) == polygonID }),
                  BoardPolygonParts.changedWhole(polygon, done: movedPolygonPoints) else {
                continue
            }
            board.planes[index] = shifted(board.planes[index], by: delta)
        }
        movingPoints.apply(from: original, to: &board, graphicsMovedWhole: graphicsMovedWhole)
    }

    private func mirrorSelectedObjects(around center: HorizontalPoint, board: inout HorizontalBoard) {
        let liftedOutlines = board.liftPlaneOutlines()
        defer { board.lowerPlaneOutlines(lifted: liftedOutlines) }
        let original = board
        var movingPoints = BoardMovingPoints()
        var mirroredPolygonPoints = Set<String>()
        let movingPackageIDs = self.movingPackageIDs(in: original)
        let packageGeometry = BoardPackageGeometry.index(of: original, packageIDs: movingPackageIDs)
        for ref in BoardCopperLock.removingHeld(selectedObjects, in: original) {
            switch ref.type {
            case .boardPackage:
                mirrorBoardPackage(ref: ref, around: center, board: &board, geometry: packageGeometry[normalizedID(ref.id)])
            case .track:
                mirrorSegment(&board.tracks, ref: ref, around: center, flipsLayer: true)
            case .boardNetTie:
                mirrorSegment(&board.netTies, ref: ref, around: center, flipsLayer: true)
            case .boardLine:
                mirrorSegment(&board.lines, ref: ref, around: center, flipsLayer: false)
            case .boardArc:
                mirrorArc(&board.arcs, ref: ref, around: center, flipsLayer: false)
            case .via:
                mirrorVia(ref: ref, around: center, in: original, points: &movingPoints)
            case .boardHole:
                mirrorHole(&board.holes, ref: ref, around: center)
                mirrorHole(&board.packageHoles, ref: ref, around: center)
                mirrorHole(&board.viaHoles, ref: ref, around: center)
            case .text:
                if isCarriedByPackage(ref, movingPackageIDs: movingPackageIDs) {
                    break
                }
                mirrorText(&board.texts, ref: ref, around: center)
                mirrorText(&board.packageTexts, ref: ref, around: center)
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                BoardPolygonParts.change(&board.polygons, ref: ref, done: &mirroredPolygonPoints, mirrorsArcs: true) {
                    mirrored($0, around: center)
                }
            case .pad:
                if modeProfile.mode == .package {
                    mirrorPoolPad(ref: ref, around: center, board: &board)
                } else {
                    mirrorPolygon(&board.packagePads, ref: ref, around: center, flipsLayer: true)
                }
            case .padstackShape:
                mirrorPadstackShape(ref: ref, around: center, board: &board)
            case .boardDecal, .boardPanel, .dimension, .keepout, .plane:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .connectionLine, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }
        movingPoints.apply(from: original, to: &board)
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
        // As a move does (`moveSelectedObjects`): a track and its via both
        // turned the via, the second time from where the first had put it.
        // A plane's outline turns as a polygon.
        let liftedOutlines = board.liftPlaneOutlines()
        defer { board.lowerPlaneOutlines(lifted: liftedOutlines) }
        let original = board
        var movingPoints = BoardMovingPoints()
        var padEnds = BoardTrackPadEnds(padPositions: BoardCopperLock.pinnedEndPositions(original))
        var turnedPolygonPoints = Set<String>()
        let movingPackageIDs = self.movingPackageIDs(in: original)
        let packageGeometry = BoardPackageGeometry.index(of: original, packageIDs: movingPackageIDs)

        for ref in BoardCopperLock.removingHeld(selectedObjects, in: original) {
            guard let center = refOrigin(ref) else {
                continue
            }
            switch ref.type {
            case .boardPackage:
                rotateBoardPackage(
                    ref: ref, around: center, by: angleDelta, board: &board, geometry: packageGeometry[normalizedID(ref.id)]
                )
            case .track:
                rotateBoardTrack(ref: ref, around: center, by: angleDelta, in: \.tracks, original: original, board: &board, points: &movingPoints, padEnds: &padEnds)
            case .boardNetTie:
                rotateBoardTrack(ref: ref, around: center, by: angleDelta, in: \.netTies, original: original, board: &board, points: &movingPoints, padEnds: &padEnds)
            case .boardLine:
                rotateSegment(&board.lines, ref: ref, around: center, by: angleDelta)
            case .boardArc:
                rotateArc(&board.arcs, ref: ref, around: center, by: angleDelta)
            case .via:
                rotateVia(ref: ref, around: center, by: angleDelta, in: original, points: &movingPoints)
            case .boardHole:
                rotateHole(&board.holes, ref: ref, around: center, by: angleDelta)
                rotateHole(&board.packageHoles, ref: ref, around: center, by: angleDelta)
                rotateHole(&board.viaHoles, ref: ref, around: center, by: angleDelta)
            case .text:
                if isCarriedByPackage(ref, movingPackageIDs: movingPackageIDs) {
                    break
                }
                rotateText(&board.texts, ref: ref, around: center, by: angleDelta)
                rotateText(&board.packageTexts, ref: ref, around: center, by: angleDelta)
            case .polygonArcCenter, .polygonEdge, .polygonVertex:
                BoardPolygonParts.change(&board.polygons, ref: ref, done: &turnedPolygonPoints) {
                    rotated($0, around: center, by: angleDelta)
                }
            case .pad:
                if modeProfile.mode == .package {
                    rotatePoolPad(ref: ref, around: center, by: angleDelta, board: &board)
                } else {
                    rotatePolygon(&board.packagePads, ref: ref, around: center, by: angleDelta)
                }
            case .padstackShape:
                rotatePadstackShape(ref: ref, around: center, by: angleDelta, board: &board)
            case .boardDecal, .boardPanel, .dimension, .keepout, .plane:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .connectionLine, .drawingArc, .drawingLine, .junction, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                break
            }
        }
        movingPoints.apply(from: original, to: &board)
    }

    /// `geometry` is where the package's geometry sits on `board`
    /// (`BoardPackageGeometry`), when the caller has found it for many
    /// packages at once; left out, it is looked up.
    private func moveBoardPackage(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              !board.packages[index].fixed else {
            return
        }

        let geometry = geometry ?? BoardPackageGeometry(packageID: ref.id, in: board)
        keepBoardTracksConnectedToMovingPackage(packageID: ref.id, delta: delta, board: &board, geometry: geometry)
        board.packages[index].position = board.packages[index].position + delta
        shiftBoardPackageGeometry(packageID: ref.id, by: delta, board: &board, geometry: geometry)
    }

    private func mirrorBoardPackage(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              !board.packages[index].fixed else {
            return
        }

        let geometry = geometry ?? BoardPackageGeometry(packageID: ref.id, in: board)
        let anchors = boardPackageConnectionAnchors(packageID: ref.id, board: board, geometry: geometry)
        board.packages[index].position = mirrored(board.packages[index].position, around: center)
        board.packages[index].angle = wrappedAngle(-board.packages[index].angle)
        board.packages[index].mirrored.toggle()
        mirrorBoardPackageGeometry(packageID: ref.id, around: center, board: &board, geometry: geometry)
        for anchor in anchors {
            moveBoardTrackEndpoints(
                at: anchor.point,
                by: mirrored(anchor.point, around: center) - anchor.point,
                netID: anchor.netID,
                board: &board
            )
        }
    }

    private func rotateBoardPackage(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        guard let index = board.packages.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              !board.packages[index].fixed else {
            return
        }

        let geometry = geometry ?? BoardPackageGeometry(packageID: ref.id, in: board)
        let anchors = boardPackageConnectionAnchors(packageID: ref.id, board: board, geometry: geometry)
        let original = board.packages[index]
        board.packages[index].position = rotated(original.position, around: center, by: angleDelta)
        board.packages[index].angle = wrappedAngle(original.angle + angleDelta)
        rotateBoardPackageGeometry(packageID: ref.id, around: center, by: angleDelta, board: &board, geometry: geometry)
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
        let geometry = BoardPackageGeometry(packageID: ref.id, in: board)
        let anchors = boardPackageConnectionAnchors(packageID: ref.id, board: board, geometry: geometry)

        mirrorBoardPackageGeometry(packageID: ref.id, around: center, board: &board, geometry: geometry)
        rotateBoardPackageGeometry(packageID: ref.id, around: center, by: rotation, board: &board, geometry: geometry)
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
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        let anchors = boardPackageConnectionAnchors(packageID: packageID, board: board, geometry: geometry)
        guard !anchors.isEmpty else {
            return
        }

        // Every anchor moves by the same delta, so the tracks are walked once
        // against all of them — not once per pad shape, each pass formatting a
        // point key for every track on the board. An endpoint also moves at
        // most once, even where two pads sit exactly `delta` apart.
        var anchorNetsByKey = [String: [String?]]()
        var anchorKeys = [(key: String, point: HorizontalPoint, netID: String?)]()
        for anchor in anchors {
            let key = pointKey(anchor.point)
            if anchorNetsByKey[key] == nil {
                anchorKeys.append((key, anchor.point, anchor.netID))
            }
            anchorNetsByKey[key, default: []].append(anchor.netID)
        }
        func followsAnchor(_ point: HorizontalPoint, netID: String?) -> Bool {
            anchorNetsByKey[pointKey(point)]?.contains { netsMatch(netID, $0) } == true
        }
        for index in board.tracks.indices {
            let netID = board.tracks[index].netID
            if followsAnchor(board.tracks[index].from, netID: netID) {
                board.tracks[index].from = board.tracks[index].from + delta
            }
            if followsAnchor(board.tracks[index].to, netID: netID) {
                board.tracks[index].to = board.tracks[index].to + delta
            }
        }
        for index in board.netTies.indices {
            let netID = board.netTies[index].netID
            if followsAnchor(board.netTies[index].from, netID: netID) {
                board.netTies[index].from = board.netTies[index].from + delta
            }
            if followsAnchor(board.netTies[index].to, netID: netID) {
                board.netTies[index].to = board.netTies[index].to + delta
            }
        }

        var junctionIDsByKey = [String: [String]]()
        for (junctionID, position) in board.junctions {
            let key = pointKey(position)
            if anchorNetsByKey[key] != nil {
                junctionIDsByKey[key, default: []].append(junctionID)
            }
        }
        for anchor in anchorKeys {
            guard let junctionIDs = junctionIDsByKey[anchor.key] else {
                continue
            }
            var movedJunctionIDs = [String]()
            for junctionID in junctionIDs {
                // An earlier merge can have absorbed this one.
                guard let position = board.junctions[junctionID], pointKey(position) == anchor.key else {
                    continue
                }
                board.junctions[junctionID] = position + delta
                movedJunctionIDs.append(junctionID)
            }
            if let preferredID = movedJunctionIDs.first {
                mergeBoardJunctions(
                    at: anchor.point + delta,
                    preferredID: preferredID,
                    netID: board.junctionNetIDs[preferredID] ?? anchor.netID,
                    board: &board
                )
            }
        }
    }

    private func boardPackageConnectionAnchors(
        packageID: String,
        board: HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) -> [MovingConnectionPoint] {
        let geometry = geometry ?? BoardPackageGeometry(packageID: packageID, in: board)
        let padAnchors = geometry.pads.map { index in
            let pad = board.packagePads[index]
            return MovingConnectionPoint(point: HorizontalRect(points: pad.vertices).center, netID: pad.netID)
        }
        let holeAnchors = geometry.holes.map { index in
            MovingConnectionPoint(point: board.packageHoles[index].position, netID: board.packageHoles[index].netID)
        }
        return padAnchors + holeAnchors
    }

    /// Moves a via with its drill and the copper on it, as the inspector's
    /// position fields do.
    private func moveVia(ref: HorizontalSelectableRef, by delta: HorizontalPoint, board: inout HorizontalBoard) {
        // A locked via stays, as a fixed package does (`BoardCopperLock`).
        guard !BoardCopperLock.isLocked(ref, in: board) else { return }
        let original = board
        var points = BoardMovingPoints()
        moveVia(ref: ref, by: delta, in: original, points: &points)
        points.apply(from: original, to: &board)
    }

    /// A via goes with its point (`BoardMovingPoints`), which carries its
    /// drill and the copper on it.
    private func moveVia(ref: HorizontalSelectableRef, by delta: HorizontalPoint, in board: HorizontalBoard, points: inout BoardMovingPoints) {
        guard let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        points.add(via.position, to: via.position + delta, netID: via.netID)
    }

    private func rotateVia(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        in board: HorizontalBoard,
        points: inout BoardMovingPoints
    ) {
        guard let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        points.add(via.position, to: rotated(via.position, around: center, by: angleDelta), netID: via.netID)
    }

    /// A junction goes with its point (`BoardMovingPoints`). Lines and arcs
    /// end on junctions as tracks do, and Horizon's follow the junction they
    /// end on. The model keeps their ends as points, so the ends at the
    /// junction's point go with it.
    private func moveBoardJunction(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        in board: HorizontalBoard,
        points: inout BoardMovingPoints
    ) {
        guard let entry = board.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
            return
        }
        points.add(entry.value, to: entry.value + delta, netID: board.junctionNetIDs[entry.key], carriesGraphics: true)
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
        original: HorizontalBoard,
        board: inout HorizontalBoard,
        points: inout BoardMovingPoints,
        padEnds: inout BoardTrackPadEnds
    ) {
        transformBoardTrack(ref: ref, in: segments, original: original, board: &board, points: &points, padEnds: &padEnds) {
            $0 + delta
        }
    }

    private func rotateBoardTrack(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        in segments: WritableKeyPath<HorizontalBoard, [HorizontalSegment]>,
        original: HorizontalBoard,
        board: inout HorizontalBoard,
        points: inout BoardMovingPoints,
        padEnds: inout BoardTrackPadEnds
    ) {
        transformBoardTrack(ref: ref, in: segments, original: original, board: &board, points: &points, padEnds: &padEnds) {
            rotated($0, around: center, by: angleDelta)
        }
    }

    /// A track end on a junction or via goes with that point
    /// (`BoardMovingPoints`), which carries the rest of the copper there; a
    /// free end, and an arc's centre, go on their own. Both are taken from
    /// `original`, the board before the change, so an end goes once. An end
    /// on a pad stays there with what else is on it (`BoardTrackPadEnds`),
    /// and so does an arc's centre unless both ends go.
    private func transformBoardTrack(
        ref: HorizontalSelectableRef,
        in segments: WritableKeyPath<HorizontalBoard, [HorizontalSegment]>,
        original: HorizontalBoard,
        board: inout HorizontalBoard,
        points: inout BoardMovingPoints,
        padEnds: inout BoardTrackPadEnds,
        _ transform: (HorizontalPoint) -> HorizontalPoint
    ) {
        guard let index = original[keyPath: segments].firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              board[keyPath: segments].indices.contains(index),
              board[keyPath: segments][index].id == original[keyPath: segments][index].id else {
            return
        }

        let segment = original[keyPath: segments][index]
        let pinsFrom = padEnds.isOnPad(segment.from)
        let pinsTo = padEnds.isOnPad(segment.to)
        if !pinsFrom {
            if hasBoardMovableConnection(at: segment.from, in: original) {
                points.add(segment.from, to: transform(segment.from), netID: segment.netID)
            } else {
                board[keyPath: segments][index].from = transform(segment.from)
            }
        }
        if !pinsTo {
            if hasBoardMovableConnection(at: segment.to, in: original) {
                points.add(segment.to, to: transform(segment.to), netID: segment.netID)
            } else {
                board[keyPath: segments][index].to = transform(segment.to)
            }
        }
        if let center = segment.center, !pinsFrom, !pinsTo {
            board[keyPath: segments][index].center = transform(center)
        }
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
        polygons[index] = shifted(polygons[index], by: delta)
    }

    private func moveKeepout(_ keepouts: inout [HorizontalKeepout], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = keepouts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        keepouts[index] = shifted(keepouts[index], by: delta)
    }

    /// Moves the parts of a dimension the selection holds, once however many
    /// of them it holds (`BoardDimensionParts`).
    private func moveDimension(
        _ dimensions: inout [HorizontalDimension],
        ref: HorizontalSelectableRef,
        parts: [String: Set<Int>],
        by delta: HorizontalPoint,
        done: inout Set<String>
    ) {
        let id = normalizedID(ref.id)
        guard done.insert(id).inserted,
              let index = dimensions.firstIndex(where: { normalizedID($0.id) == id }) else {
            return
        }
        dimensions[index] = BoardDimensionParts.moved(dimensions[index], parts: parts[id] ?? [ref.vertex], by: delta)
    }

    private func moveBoardDecal(_ decals: inout [HorizontalBoardDecal], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = decals.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        decals[index] = shifted(decals[index], by: delta)
    }

    /// A plane has no outline of its own: Horizon's is its polygon, so the
    /// polygon moves whole with it, each point once however many of its parts
    /// are selected too (`done`). Its fills move along until it is poured again.
    private func movePlane(
        _ planes: inout [HorizontalPlane],
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        polygons: inout [HorizontalPolygon],
        done: inout Set<String>
    ) {
        guard let index = planes.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        planes[index] = shifted(planes[index], by: delta)
        guard let polygon = polygons.first(where: { normalizedID($0.id) == normalizedID(planes[index].polygonID) }) else {
            return
        }
        for part in BoardPolygonParts.wholeSelection(of: polygon) {
            BoardPolygonParts.change(&polygons, ref: part, done: &done) { $0 + delta }
        }
    }

    private func mirrorVia(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        in board: HorizontalBoard,
        points: inout BoardMovingPoints
    ) {
        guard let via = board.vias.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        points.add(via.position, to: mirrored(via.position, around: center), netID: via.netID)
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
        polygons[index] = rotated(polygons[index], around: center, by: angleDelta)
    }

    private func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return normalizedID(lhs) == normalizedID(rhs)
    }

    /// The track group's Measure and Measure All: every selected track to
    /// the Length Tuning window. False for any other change.
    private func measureTracks(for change: HorizontalSelectionPropertyChange) -> Bool {
        guard let allTracks = HorizontalTrackSelectionSummary.measuresAllTracks(change.propertyID) else {
            return false
        }
        let tracks = Set(selectedObjects.filter { $0.type == .track }.map { normalizedID($0.id) })
        if !tracks.isEmpty {
            onMeasureTracks?(tracks, allTracks)
        }
        return true
    }

    private func applySelectionPropertyChange(_ change: HorizontalSelectionPropertyChange) {
        guard !isReadOnly else {
            return
        }
        if change.propertyID == HorizontalBlockInstanceSummary.copyLayoutActionID {
            copyBlockLayoutToOtherInstances()
            return
        }
        if HorizontalBlockInstanceSummary.placementPropertyIDs.contains(change.propertyID) {
            placeBlockInstance(change)
            return
        }
        // The sidebar's plane and keepout buttons, each its own edit.
        switch change.propertyID {
        case Self.definePlaneActionID:
            setSelectedObject(change.ref)
            definePlaneForSelection()
            return
        case Self.defineKeepoutActionID:
            defineKeepout(on: change.ref)
            return
        case Self.deletePlaneActionID:
            deletePlaneDefinition(outlinedBy: change.ref)
            return
        case Self.deleteKeepoutActionID:
            deleteKeepoutDefinition(change.ref)
            return
        default:
            break
        }
        // Set and Clear Diff Pair edit the block, through the host's
        // project edit, which reloads the board with the pair.
        if change.propertyID == HorizontalDiffpairProperty.id, case .choice(let partner) = change.value {
            if let netID = netID(for: change.ref).map(normalizedID), let onEditDiffpair, onEditDiffpair.canEdit(netID),
               let edit = HorizontalDiffpairProperty.operations(for: netID, choice: partner, in: board.netDetails) {
                onEditDiffpair.apply(edit.ops, edit.actionName)
            }
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
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previousBoard, kind: .properties))
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
                packagePlacementState = nil
                hoveredObject = nil
                // The track tool waits on, for a route on the board put back,
                // as it does when a route ends, with a route under way dropped:
                // the next route's undo step starts from this board, not from
                // the one the tool had, which still held what was undone.
                if let route = drawTrackState {
                    armDrawTrack(layer: route.layer)
                    routeInspector?.beginRoute(on: value)
                }
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
    ///
    /// Every edit leaves the rats' nest of the board it makes, rebuilt from the
    /// nets the pass just gave. Built before it, on a board whose file stores
    /// no junction nets (Horizon writes none), placing a package brought back
    /// an airwire for every routed connection that bends — on Board A, 328 where
    /// there are 32. Only a placement, a move and R, E and T rebuilt it once,
    /// and the rest (a drawn track, a delete, a paste) left it to the pour that
    /// follows, which a board with no planes never has: on Board C the canvas
    /// drew 33 airwires where the board has 8, some to where parts had been.
    private func publishConnectivityResolvedEdit(
        _ board: HorizontalBoard,
        sync: BoardLayoutSyncIntent? = nil
    ) {
        // A pool item has no nets: nothing to propagate, and the recompute
        // would strip the (absent) net of every pad anyway.
        guard modeProfile.usesConnectivity else {
            var board = board
            board.regenerateAirwires()
            board.recomputePoolEditorBounds()
            editedBoard = board
            onBoardChange(board)
            return
        }
        // The edit made in the block instances laid out like the one it was
        // made in, before the nets are given: the copies take theirs from
        // their own pads.
        var board = board
        var synced = false
        if let sync, let result = syncedBlockInstances(board, sync: sync) {
            board = result.board
            synced = !result.changes.isEmpty
            showBlockSyncNote(result.report)
        }
        instanceOnlyEdit = false
        var resolved = HorizontalBoardConnectivity.recompute(board)
        // A plane's outline is kept in the plane, with its layer, before the
        // rules give the plane that layer's settings.
        resolved.lowerPlaneOutlines()
        // The rules stay applied: a track on another layer or net takes the
        // width the rules give it there, a via the shape, a plane the
        // settings, from the nets the pass just gave.
        let ruled = !HorizontalBoardRuleApplication.apply(to: &resolved, poolURL: poolURL).isEmpty
        // From the planes' fills as they are; a pour that follows remakes it
        // from its own.
        resolved.regenerateAirwires()
        // A net change is a color change (net-less copper is orange), so force a
        // metal-scene rebuild even when the edit would otherwise patch in place.
        // So does a changed rats' nest: a route's commit adds no track the
        // scene of its last click didn't have.
        if ruled || resolved.tracks.map(\.netID) != board.tracks.map(\.netID) || resolved.airwires != board.airwires {
            metalSceneRevision &+= 1
        }
        editedBoard = resolved
        if ruled || synced {
            invalidateSelectableCache()
        }
        onBoardChange(resolved)
    }

    /// The edit, made the same in the block instances laid out like the one
    /// it was made in; nil where the switch is off, U made it this
    /// instance's alone, or it reaches no other instance.
    private func syncedBlockInstances(_ board: HorizontalBoard, sync: BoardLayoutSyncIntent)
        -> (board: HorizontalBoard, changes: HorizontalBlockLayoutSync.ChangeSet, report: HorizontalBlockLayoutSync.Report)? {
        guard displayOptions.syncsBlockInstances, !instanceOnlyEdit,
              let blockInstances, !blockInstances.isEmpty,
              let changes = HorizontalBlockLayoutSync.propagate(
                baseline: sync.baseline, edited: board, instances: blockInstances, intent: .init(sync.kind)
              ) else {
            return nil
        }
        var synced = board
        let report = HorizontalBlockLayoutSync.apply(changes, to: &synced, poolURL: poolURL)
        return (synced, changes, report)
    }

    /// U: this edit only for the block instance it is made in. Only while an
    /// edit that syncs is under way, on a design with an instanced block.
    private func toggleInstanceOnlyEdit() {
        guard syncableInteraction, blockInstances?.isEmpty == false else {
            return
        }
        instanceOnlyEdit.toggle()
    }

    /// Whether an edit that keeps block instances alike is under way.
    private var syncableInteraction: Bool {
        moveState != nil || drawTrackState != nil || pastePlacementState != nil || packagePlacementState != nil || tuneState != nil
    }

    /// The tool's hint, with U where an edit would reach other instances.
    private func withInstanceOnlyHint(_ text: String) -> String {
        guard syncableInteraction, displayOptions.syncsBlockInstances, blockInstances?.isEmpty == false else {
            return text
        }
        return text + (instanceOnlyEdit ? "   Only this instance (U)" : "   U only this instance")
    }

    /// Says for a few seconds which instances an edit also changed, and what
    /// it left and why.
    private func showBlockSyncNote(_ report: HorizontalBlockLayoutSync.Report, lead: String = "Also in") {
        var parts = [String]()
        if !report.changed.isEmpty {
            parts.append("\(lead) \(report.changed.joined(separator: ", "))")
        }
        if !report.skipped.isEmpty {
            parts.append("left: \(report.skipped.joined(separator: "; "))")
        }
        if !report.conflicts.isEmpty {
            parts.append(report.conflicts.joined(separator: "; "))
        }
        guard !parts.isEmpty else {
            return
        }
        showCanvasNote(parts.joined(separator: " — "))
    }

    /// Says `note` for a few seconds where the hints go.
    private func showCanvasNote(_ note: String) {
        canvasNote = note
        canvasNoteID &+= 1
        let id = canvasNoteID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if canvasNoteID == id {
                canvasNote = nil
            }
        }
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
        // Locked, and a via's Net (`BoardCopperLock`, `BoardSetNet`).
        if BoardCopperLockCommands.apply(value, propertyID: propertyID, to: ref, board: &board) {
            return
        }
        // A keepout option in its polygon's Keepout section is the keepout's.
        if isPolygonRef(ref), propertyID.hasPrefix(Self.keepoutPropertyPrefix),
           let keepout = keepoutBackedByPolygon(ref.id, in: board) {
            updateKeepout(
                &board.keepouts,
                ref: HorizontalSelectableRef(id: keepout.id, type: .keepout, layer: keepout.polygon.layer),
                propertyID: String(propertyID.dropFirst(Self.keepoutPropertyPrefix.count)),
                value: value
            )
            return
        }
        // A plane setting in its outline's Plane section is the plane's.
        if isPolygonRef(ref), propertyID.hasPrefix(Self.planePropertyPrefix),
           let plane = planeBackedByPolygon(ref.id, in: board) {
            updatePlane(
                ref: HorizontalSelectableRef(id: plane.id, type: .plane, layer: plane.layer),
                propertyID: String(propertyID.dropFirst(Self.planePropertyPrefix.count)),
                value: value,
                board: &board
            )
            return
        }

        switch ref.type {
        case .track:
            let rules = board.rules
            updateSegment(&board.tracks, ref: ref, propertyID: propertyID, value: value, rules: rules)
        case .boardNetTie:
            let rules = board.rules
            updateSegment(&board.netTies, ref: ref, propertyID: propertyID, value: value, rules: rules)
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
            syncViaFromHole(ref: ref, board: &board)
        case .plane:
            updatePlane(ref: ref, propertyID: propertyID, value: value, board: &board)
        case .keepout:
            updateKeepout(&board.keepouts, ref: ref, propertyID: propertyID, value: value)
        case .dimension:
            updateDimension(&board.dimensions, ref: ref, propertyID: propertyID, value: value)
        case .text:
            let variables = board.textVariables(forTextID: ref.id)
            updateText(&board.texts, ref: ref, propertyID: propertyID, value: value, variables: variables)
            updateText(&board.packageTexts, ref: ref, propertyID: propertyID, value: value, variables: variables)
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            // A plane's outline too, whose layer is the plane's.
            let liftedOutlines = board.liftPlaneOutlines()
            updatePolygon(&board.polygons, ref: ref, propertyID: propertyID, value: value)
            board.lowerPlaneOutlines(lifted: liftedOutlines)
        case .pad:
            if modeProfile.mode == .package {
                updatePoolPad(ref: ref, propertyID: propertyID, value: value, board: &board)
            } else {
                updatePad(&board.packagePads, ref: ref, propertyID: propertyID, value: value)
            }
        case .padstackShape:
            updatePadstackShape(ref: ref, propertyID: propertyID, value: value, board: &board)
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

    /// `rules` are the board's, for a track's or net tie's width from them.
    private func updateSegment(
        _ segments: inout [HorizontalSegment],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        rules: HorizontalBoardRules? = nil
    ) {
        guard let index = segments.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("width", .length(let width)):
            segments[index].width = max(width, 0)
            // A width typed in is the track's own, as in Horizon, where one
            // from the rules can't be set.
            segments[index].widthFromRules = false
        case ("widthSource", .choice(let source)):
            segments[index].widthFromRules = source == "rules"
            // From the rules: the width the rule gives it now, as the rules
            // window's Apply would. With no rule to give one it keeps its own.
            if source == "rules", let rules, let layer = segments[index].layer,
               let rule = rules.trackWidth(net: segments[index].netID, layer: layer), rule.widths.def > 0 {
                segments[index].width = rule.widths.def
            }
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
        case ("positionX", .length(let x)):
            let delta = HorizontalPoint(x: x - board.vias[index].position.x, y: 0)
            moveVia(ref: ref, by: delta, board: &board)
            return
        case ("positionY", .length(let y)):
            let delta = HorizontalPoint(x: 0, y: y - board.vias[index].position.y)
            moveVia(ref: ref, by: delta, board: &board)
            return
        default:
            break
        }

        var via = board.vias[index]
        switch (propertyID, value) {
        case ("diameter", .length(let diameter)):
            via.size = max(diameter, 0)
            via.parameterSet["via_diameter"] = via.size
            takeLocalViaControl(&via)
        case ("holeDiameter", .length(let diameter)):
            via.holeSize = max(diameter, 0)
            via.parameterSet["hole_diameter"] = max(diameter, 0)
            takeLocalViaControl(&via)
        case ("viaSource", .choice(let source)):
            switch source {
            case "rules":
                via.fromRules = true
                via.definitionID = nil
                // The rule's padstack and parameters at once, as applying
                // the rules gives them.
                HorizontalBoardRuleApplication.shape(&via, in: board, poolURL: poolURL)
            case "definition":
                via.fromRules = false
                if let definitionID = via.definitionID ?? board.viaDefinitions.first?.id {
                    applyViaDefinition(definitionID, to: &via, definitions: board.viaDefinitions)
                }
            default:
                via.fromRules = false
                via.definitionID = nil
            }
        case ("viaDefinition", .choice(let definitionID)):
            applyViaDefinition(definitionID, to: &via, definitions: board.viaDefinitions)
        case ("padstack", .choice(let padstackID)):
            via.padstackID = padstackID
            takeLocalViaControl(&via)
            adoptViaPadstack(&via, padstackID: padstackID)
        case ("addParameter", .choice(let key)):
            guard key != "none", via.parameterSet[key] == nil else {
                return
            }
            let seeded = seededParameterValue(key, padstackID: via.padstackID)
            via.parameterSet[key] = seeded
            syncViaMaskExpansion(&via, key: key, value: seeded)
            takeLocalViaControl(&via)
        default:
            if propertyID.hasPrefix("removeParam:") {
                let key = String(propertyID.dropFirst("removeParam:".count))
                guard via.parameterSet.removeValue(forKey: key) != nil else {
                    return
                }
                takeLocalViaControl(&via)
            } else if propertyID.hasPrefix("param:"), case .length(let parameter) = value {
                let key = String(propertyID.dropFirst("param:".count))
                via.parameterSet[key] = max(parameter, 0)
                syncViaMaskExpansion(&via, key: key, value: max(parameter, 0))
                takeLocalViaControl(&via)
            } else {
                return
            }
        }
        board.vias[index] = via
        board.syncHole(of: via)
    }

    /// Selecting a padstack copies a base-pool padstack into the project
    /// pool's cache (so the reference survives a reload and the project stays
    /// self-contained for Horizon) and re-derives the via's solder-mask
    /// openings from the new padstack's shapes — switching a via between a
    /// tented and an untented padstack takes effect immediately.
    private func adoptViaPadstack(_ via: inout HorizontalMarker, padstackID: String) {
        guard let poolURL else {
            return
        }
        HorizontalPoolPadstacks.ensureCached(id: padstackID, poolURL: poolURL)
        guard let padstackJSON = HorizontalPoolPadstacks.padstack(id: padstackID, poolURL: poolURL) else {
            return
        }
        let parameters = via.parameterSet.reduce(into: JSONDictionary()) { result, item in
            result[item.key] = item.value
        }
        let expansions = HorizontalBoard.viaMaskExpansions(
            padstackJSON: padstackJSON,
            parameterSet: parameters,
            viaDiameter: via.size,
            ruleMaskExpansion: board.ruleViaMaskExpansion
        )
        via.topMaskExpansion = expansions.top
        via.bottomMaskExpansion = expansions.bottom
    }

    /// Keeps the rendered solder-mask openings live when the mask-expansion
    /// parameter itself is edited. Only existing openings resize — a tented
    /// via (nil expansion) stays tented.
    private func syncViaMaskExpansion(_ via: inout HorizontalMarker, key: String, value: Double) {
        guard key == "via_solder_mask_expansion" else {
            return
        }
        if via.topMaskExpansion != nil {
            via.topMaskExpansion = value
        }
        if via.bottomMaskExpansion != nil {
            via.bottomMaskExpansion = value
        }
    }

    /// Any direct geometry edit takes local control of the via: Horizon only
    /// honors a via's own parameter_set when its source is local, so a
    /// rules/definition via must flip to Custom or the edit would silently be
    /// overwritten on the next rules expansion.
    private func takeLocalViaControl(_ via: inout HorizontalMarker) {
        via.fromRules = false
        via.definitionID = nil
    }

    /// Points a via at a board via definition and adopts its padstack and
    /// parameter values, mirroring Horizon's expand (definition vias serialize
    /// the definition's parameters).
    private func applyViaDefinition(
        _ definitionID: String,
        to via: inout HorizontalMarker,
        definitions: [HorizontalViaDefinition]
    ) {
        via.fromRules = false
        via.definitionID = definitionID
        guard let definition = definitions.first(where: { normalizedID($0.id) == normalizedID(definitionID) }) else {
            return
        }
        if let padstackID = definition.padstackID {
            via.padstackID = padstackID
            adoptViaPadstack(&via, padstackID: padstackID)
        }
        for (key, value) in definition.parameters {
            via.parameterSet[key] = value
            syncViaMaskExpansion(&via, key: key, value: value)
        }
        if let diameter = definition.parameters["via_diameter"] {
            via.size = diameter
        }
        if let holeDiameter = definition.parameters["hole_diameter"] {
            via.holeSize = holeDiameter
        }
    }

    /// Re-derives the via's drill object (rendered and selectable on its own)
    /// from the marker's hole size after a parameter edit. A via read with no
    /// hole diameter has no drill object, which the loader makes only from
    /// one; it gets one here, where it went on drawing no hole until the
    /// board was opened again.
    /// A via's drill is selectable as its own board-hole object; pushing a
    /// diameter edit back onto the owning via keeps the marker (and the
    /// persisted via parameter_set) in sync.
    private func syncViaFromHole(ref: HorizontalSelectableRef, board: inout HorizontalBoard) {
        let holeID = normalizedID(ref.id)
        guard holeID.hasSuffix("/hole"),
              let hole = board.viaHoles.first(where: { normalizedID($0.id) == holeID }),
              let index = board.vias.firstIndex(where: { normalizedID($0.id) + "/hole" == holeID }),
              board.vias[index].holeSize != hole.diameter else {
            return
        }
        board.vias[index].holeSize = hole.diameter
        board.vias[index].parameterSet["hole_diameter"] = hole.diameter
        takeLocalViaControl(&board.vias[index])
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
            syncHoleParameters(&holes[index])
        case ("length", .length(let length)):
            holes[index].length = max(length, holes[index].diameter)
            holes[index].shape = holes[index].effectiveLength > holes[index].diameter ? .slot : .round
            syncHoleParameters(&holes[index])
        case ("positionX", .length(let x)):
            holes[index].position.x = x
        case ("positionY", .length(let y)):
            holes[index].position.y = y
        case ("plated", .bool(let plated)):
            holes[index].plated = plated
        case ("shape", .choice(let shape)):
            holes[index].shape = shape == "slot" ? .slot : .round
            if holes[index].shape == .slot, holes[index].effectiveLength <= holes[index].diameter {
                holes[index].length = holes[index].diameter + 500_000
            } else if holes[index].shape == .round {
                holes[index].length = holes[index].diameter
            }
        case ("parameterClass", .text(let parameterClass)):
            holes[index].parameterClass = parameterClass
        case ("padstack", .choice(let padstackID)):
            guard holes[index].padstackID != nil else {
                break
            }
            holes[index].padstackID = padstackID
            if let poolURL {
                HorizontalPoolPadstacks.ensureCached(id: padstackID, poolURL: poolURL)
            }
        case ("addParameter", .choice(let key)):
            guard key != "none", holes[index].padstackID != nil, holes[index].parameterSet[key] == nil else {
                break
            }
            holes[index].parameterSet[key] = seededParameterValue(key, padstackID: holes[index].padstackID)
        default:
            if propertyID.hasPrefix("removeParam:") {
                let key = String(propertyID.dropFirst("removeParam:".count))
                holes[index].parameterSet.removeValue(forKey: key)
            } else if propertyID.hasPrefix("param:"), case .length(let parameter) = value {
                let key = String(propertyID.dropFirst("param:".count))
                holes[index].parameterSet[key] = max(parameter, 0)
            }
        }
    }

    /// Mirrors a padstack-backed hole's geometry into its parameter set — for
    /// those holes the parameters are what persists (BoardHole::serialize keeps
    /// geometry in parameter_set, not direct keys). hole_length is only
    /// materialized when the entry already speaks it or the hole is a slot.
    private func syncHoleParameters(_ hole: inout HorizontalHole) {
        guard hole.padstackID != nil else {
            return
        }
        hole.parameterSet["hole_diameter"] = hole.diameter
        if hole.parameterSet["hole_length"] != nil || hole.shape == .slot {
            hole.parameterSet["hole_length"] = hole.effectiveLength
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
            HorizontalBoardRuleApplication.applySettings(to: &board.planes[index], rules: board.rules)
        case ("fromRules", .choice(let source)):
            board.planes[index].fromRules = source == "rules"
            // From the rules: the plane rule's settings at once, as applying
            // the rules gives them.
            HorizontalBoardRuleApplication.applySettings(to: &board.planes[index], rules: board.rules)
        // A setting given the plane is its own, as a width typed into a
        // track is, so the rules no longer set it.
        case ("fill", .choice(let style)):
            board.planes[index].fromRules = false
            board.planes[index].settings.fillStyle = (style == "hatch") ? .hatch : .solid
            board.planes[index].fillStyle = style
        case ("minWidth", .length(let width)):
            let nm = Int(max(width, 0).rounded())
            board.planes[index].fromRules = false
            board.planes[index].settings.minWidth = nm
            board.planes[index].minWidth = Double(nm)
        case ("keepOrphans", .bool(let on)):
            board.planes[index].fromRules = false
            board.planes[index].settings.keepOrphans = on
            board.planes[index].keepOrphans = on
        case ("style", .choice(let style)):
            board.planes[index].fromRules = false
            board.planes[index].settings.style = style == "square" ? .square : style == "miter" ? .miter : .round
        case ("textStyle", .choice(let style)):
            board.planes[index].fromRules = false
            board.planes[index].settings.textStyle = style == "bbox" ? .bbox : .expand
        case ("connectStyle", .choice(let style)):
            board.planes[index].fromRules = false
            board.planes[index].settings.thermalSettings.connectStyle = style == "thermal" ? .thermal : .solid
        case ("thermalGap", .length(let width)):
            board.planes[index].fromRules = false
            board.planes[index].settings.thermalSettings.thermalGapWidth = Int(max(width, 0).rounded())
        case ("thermalSpoke", .length(let width)):
            board.planes[index].fromRules = false
            board.planes[index].settings.thermalSettings.thermalSpokeWidth = Int(max(width, 0).rounded())
        case ("spokes", .choice(let count)):
            if let count = Int(count) {
                board.planes[index].fromRules = false
                board.planes[index].settings.thermalSettings.nSpokes = count
            }
        case ("spokeAngle", .angle(let angle)):
            board.planes[index].fromRules = false
            board.planes[index].settings.thermalSettings.angle = angle
        case ("hatchBorder", .length(let width)):
            board.planes[index].fromRules = false
            board.planes[index].settings.hatchBorderWidth = Int(max(width, 0).rounded())
        case ("hatchLine", .length(let width)):
            board.planes[index].fromRules = false
            board.planes[index].settings.hatchLineWidth = Int(max(width, 0).rounded())
        case ("hatchSpacing", .length(let width)):
            board.planes[index].fromRules = false
            board.planes[index].settings.hatchLineSpacing = Int(max(width, 0).rounded())
        case ("layer", .layer(let layer)):
            // A plane's layer is its outline's.
            board.planes[index].layer = layer
            board.planes[index].fallbackPolygon?.layer = layer
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
        guard let index = keepouts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        switch (propertyID, value) {
        case ("keepoutClass", .text(let keepoutClass)):
            keepouts[index].keepoutClass = keepoutClass
        case ("allCopperLayers", .bool(let on)):
            keepouts[index].allCopperLayers = on
        case ("exposedCopperOnly", .bool(let on)):
            keepouts[index].exposedCopperOnly = on
        case (let id, .bool(let on)) where id.hasPrefix(Self.keepoutPatchPrefix):
            let type = String(id.dropFirst(Self.keepoutPatchPrefix.count))
            var types = keepouts[index].copperPatchTypes.filter { $0.lowercased() != type }
            if on {
                types.append(type)
            }
            // In the order the editor lists them, as the file had them.
            let order = Self.keepoutPatchTypes.map(\.id)
            keepouts[index].copperPatchTypes = types.sorted {
                (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
            }
        default:
            break
        }
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
        value: HorizontalSelectionPropertyValue,
        variables: HorizontalTextVariables
    ) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("text", .text(let text)):
            texts[index].setStoredText(text, variables: variables)
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
            board.packageTexts[index].redraw { $0.replacingOccurrences(of: oldRefdes, with: newRefdes) }
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
    /// "packageID/padID" (normalized); `geometry.padPositionKeys` are the
    /// package's.
    private func updatePackagePadPositions(
        _ geometry: BoardPackageGeometry,
        board: inout HorizontalBoard,
        transform: (HorizontalPoint) -> HorizontalPoint
    ) {
        for key in geometry.padPositionKeys {
            if let position = board.packagePadPositions[key] {
                board.packagePadPositions[key] = transform(position)
            }
        }
    }

    private func shiftBoardPackageGeometry(
        packageID: String,
        by delta: HorizontalPoint,
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        guard delta != .zero else {
            return
        }

        let geometry = geometry ?? BoardPackageGeometry(packageID: packageID, in: board)

        for index in geometry.pads {
            board.packagePads[index] = shifted(board.packagePads[index], by: delta)
        }
        updatePackagePadPositions(geometry, board: &board) { $0 + delta }
        for index in geometry.holes {
            board.packageHoles[index] = shifted(board.packageHoles[index], by: delta)
        }
        for index in geometry.polygons {
            board.packagePolygons[index] = shifted(board.packagePolygons[index], by: delta)
        }
        for index in geometry.lines {
            board.packageLines[index] = shifted(board.packageLines[index], by: delta)
        }
        for index in geometry.arcs {
            board.packageArcs[index] = shifted(board.packageArcs[index], by: delta)
        }
        for index in geometry.texts {
            board.packageTexts[index] = shifted(board.packageTexts[index], by: delta)
        }
        for index in geometry.keepouts {
            board.keepouts[index] = shifted(board.keepouts[index], by: delta)
        }
    }

    private func mirrorBoardPackageGeometry(
        packageID: String,
        around center: HorizontalPoint,
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        let geometry = geometry ?? BoardPackageGeometry(packageID: packageID, in: board)

        for index in geometry.pads {
            board.packagePads[index] = mirrored(board.packagePads[index], around: center, flipsLayer: true)
        }
        updatePackagePadPositions(geometry, board: &board) { mirrored($0, around: center) }
        for index in geometry.holes {
            board.packageHoles[index] = mirrored(board.packageHoles[index], around: center)
        }
        for index in geometry.polygons {
            board.packagePolygons[index] = mirrored(board.packagePolygons[index], around: center, flipsLayer: true)
        }
        for index in geometry.lines {
            board.packageLines[index] = mirrored(board.packageLines[index], around: center, flipsLayer: true)
        }
        for index in geometry.arcs {
            board.packageArcs[index] = mirrored(board.packageArcs[index], around: center, flipsLayer: true)
        }
        for index in geometry.texts {
            board.packageTexts[index] = mirrored(board.packageTexts[index], around: center, flipsLayer: true)
        }
        for index in geometry.keepouts {
            board.keepouts[index] = mirrored(board.keepouts[index], around: center, flipsLayer: true)
        }
    }

    private func rotateBoardPackageGeometry(
        packageID: String,
        around origin: HorizontalPoint,
        by angleDelta: Int,
        board: inout HorizontalBoard,
        geometry: BoardPackageGeometry? = nil
    ) {
        guard wrappedAngle(angleDelta) != 0 else {
            return
        }

        let geometry = geometry ?? BoardPackageGeometry(packageID: packageID, in: board)

        for index in geometry.pads {
            board.packagePads[index] = rotated(board.packagePads[index], around: origin, by: angleDelta)
        }
        updatePackagePadPositions(geometry, board: &board) { rotated($0, around: origin, by: angleDelta) }
        for index in geometry.holes {
            board.packageHoles[index] = rotated(board.packageHoles[index], around: origin, by: angleDelta)
        }
        for index in geometry.polygons {
            board.packagePolygons[index] = rotated(board.packagePolygons[index], around: origin, by: angleDelta)
        }
        for index in geometry.lines {
            board.packageLines[index] = rotated(board.packageLines[index], around: origin, by: angleDelta)
        }
        for index in geometry.arcs {
            board.packageArcs[index] = rotated(board.packageArcs[index], around: origin, by: angleDelta)
        }
        for index in geometry.texts {
            board.packageTexts[index] = rotated(board.packageTexts[index], around: origin, by: angleDelta)
        }
        for index in geometry.keepouts {
            board.keepouts[index] = rotated(board.keepouts[index], around: origin, by: angleDelta)
        }
    }

    private func updatePolygon(
        _ polygons: inout [HorizontalPolygon],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        switch (propertyID, value) {
        case ("layer", .layer(let layer)):
            polygons[index].layer = layer
        case ("parameterClass", .text(let parameterClass)):
            polygons[index].parameterClass = parameterClass
        default:
            break
        }
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
        case .blockSymbolPort, .boardDecal, .boardPackage, .boardPanel, .busLabel, .busRipper, .dimension, .drawingArc, .drawingLine, .junction, .keepout, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .padstackShape, .symbolPin:
            return nil
        }
    }

    /// `netID(for:)` for many refs at once (Select All's thousands): each
    /// collection the refs name indexed by id once, where a search of it per
    /// ref made the lookup quadratic. A few refs search as they did.
    private func netIDLookup(for refs: [HorizontalSelectableRef]) -> (HorizontalSelectableRef) -> String? {
        guard refs.count > 32 else {
            return { netID(for: $0) }
        }
        let types = Set(refs.map(\.type))
        func index<Item>(_ type: HorizontalObjectType, _ items: [Item], id: (Item) -> String, net: (Item) -> String?) -> [String: String?] {
            guard types.contains(type) else {
                return [:]
            }
            var result = [String: String?](minimumCapacity: items.count)
            for item in items where result[normalizedID(id(item))] == nil {
                result[normalizedID(id(item))] = .some(net(item))
            }
            return result
        }
        let tracks = index(.track, board.tracks, id: \.id, net: \.netID)
        let netTies = index(.boardNetTie, board.netTies, id: \.id, net: \.netID)
        let lines = index(.boardLine, board.lines, id: \.id, net: \.netID)
        let arcs = index(.boardArc, board.arcs, id: \.id, net: \.netID)
        let connectionLines = index(.connectionLine, board.connectionLines, id: \.id, net: \.netID)
        let pads = index(.pad, board.packagePads, id: \.id, net: \.netID)
        let vias = index(.via, board.vias, id: \.id, net: \.netID)
        let texts = index(.text, board.texts + board.packageTexts, id: \.id, net: \.netID)
        return { ref in
            let id = normalizedID(ref.id)
            switch ref.type {
            case .track: return tracks[id] ?? nil
            case .boardNetTie: return netTies[id] ?? nil
            case .boardLine: return lines[id] ?? nil
            case .boardArc: return arcs[id] ?? nil
            case .connectionLine: return connectionLines[id] ?? nil
            case .pad: return pads[id] ?? nil
            case .via: return vias[id] ?? nil
            case .text: return texts[id] ?? nil
            default: return netID(for: ref)
            }
        }
    }

    /// `componentID(for:)` for many refs at once, the packages indexed by id.
    private func componentIDLookup(for refs: [HorizontalSelectableRef]) -> (HorizontalSelectableRef) -> String? {
        guard refs.count > 32 else {
            return { componentID(for: $0) }
        }
        var packages = [String: String?](minimumCapacity: board.packages.count)
        for package in board.packages where packages[normalizedID(package.id)] == nil {
            packages[normalizedID(package.id)] = .some(package.componentID)
        }
        return { ref in
            switch ref.type {
            case .boardPackage:
                return packages[normalizedID(ref.id)] ?? nil
            case .pad, .boardHole, .text:
                return packageID(forGeometryID: ref.id).flatMap { packages[normalizedID($0)] ?? nil }
            default:
                return nil
            }
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

    private func mirrored(_ keepout: HorizontalKeepout, around center: HorizontalPoint, flipsLayer: Bool) -> HorizontalKeepout {
        var keepout = keepout
        keepout.polygon = mirrored(keepout.polygon, around: center, flipsLayer: flipsLayer)
        return keepout
    }

    private func rotated(_ keepout: HorizontalKeepout, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalKeepout {
        var keepout = keepout
        keepout.polygon = rotated(keepout.polygon, around: origin, by: angleDelta)
        return keepout
    }

    private func shifted(_ decal: HorizontalBoardDecal, by delta: HorizontalPoint) -> HorizontalBoardDecal {
        var decal = decal
        decal.polygons = decal.polygons.map { shifted($0, by: delta) }
        decal.lines = decal.lines.map { shifted($0, by: delta) }
        decal.arcs = decal.arcs.map { shifted($0, by: delta) }
        decal.texts = decal.texts.map { shifted($0, by: delta) }
        decal.position = decal.position.map { $0 + delta }
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

    /// The board the revision-keyed caches (the selectable scene, the
    /// selection's vertices, the snap targets) are built from and keyed by:
    /// the board as edited, never a move's, paste's or tool's preview of it,
    /// which shares its revision and may share its counts, so a scene built
    /// from a preview would be served once the preview is gone.
    private var selectableSceneBoard: HorizontalBoard {
        editedBoard ?? sourceBoard
    }

    private var selectableCacheKey: BoardSelectableCacheKey {
        let board = selectableSceneBoard
        return BoardSelectableCacheKey(
            boardID: board.uuid,
            revision: selectableCacheRevision,
            displayOptions: displayOptions,
            counts: boardGeometryCounts(for: board)
        )
    }

    /// As `selectableCacheKey`, for what is drawn: the board as shown,
    /// preview and all.
    private var renderLayersCacheKey: BoardSelectableCacheKey {
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
            board.pads.count,
            board.padstackShapes.count,
            board.packageTexts.count,
            board.texts.count,
            board.boardPanels.count,
            board.junctions.count
        ]
    }

    private var allSelectableCacheKey: BoardAllSelectableCacheKey {
        let board = selectableSceneBoard
        return BoardAllSelectableCacheKey(
            boardID: board.uuid,
            revision: selectableCacheRevision,
            counts: boardGeometryCounts(for: board)
        )
    }

    private func invalidateSelectableCache() {
        selectableCacheRevision &+= 1
        metalSceneRevision &+= 1
        selectableCache.invalidate()
    }

    private func boardSelectableScene() -> HorizontalCanvasSelectableScene {
        let board = selectableSceneBoard
        // Put together from the board's kinds of selectable, each built,
        // filtered, grouped and indexed only when what it comes from changed.
        return selectableCache.selectableScene(key: selectableCacheKey, buildScene: {
            let categories = BoardLoadTimer.measure("BoardCanvasView.buildAllBoardSelectables") {
                boardSelectableCategories(in: board)
            }
            return BoardLoadTimer.measure("BoardCanvasView.indexSelectables") {
                HorizontalCanvasSelectableScene(parts: categories.map { ($0.visible, $0.byRef, $0.index()) })
            }
        })
    }

    private func boardSelectables() -> [HorizontalSelectable] {
        boardSelectableScene().selectables
    }

    private func boardSelectablesByRef() -> HorizontalSelectableLookup {
        boardSelectableScene().lookup
    }

    private func filterVisibleSelectables(_ selectables: [HorizontalSelectable]) -> [HorizontalSelectable] {
        filterVisibleSelectables(selectables, in: board)
    }

    /// What decides whether a selectable shows, beyond its own ref: which
    /// polygons are plane or keepout outlines, which copper, decals, vias and
    /// packages show, and which junctions span no copper that does. Each part
    /// is kept while the content it comes from (and the display options) is
    /// unchanged: worked out afresh, the package, via and junction passes over
    /// the whole board ran on every filter.
    private func selectableVisibility(in board: HorizontalBoard) -> BoardSelectableVisibility {
        let memo = selectableCache.contentMemo
        let keepouts = memo.value("visibility: keepouts", input: board.keepouts) { () -> BoardContentPair<[String: Bool], [String: Bool]> in
            BoardContentPair(
                Dictionary(uniqueKeysWithValues: board.keepouts.map { (normalizedID($0.id), $0.allCopperLayers) }),
                Dictionary(
                    board.keepouts.filter { !$0.id.contains("/") }.map { (normalizedID($0.polygonID), $0.allCopperLayers) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        let planePolygonIDs = memo.value("visibility: plane polygons", input: board.planes.map(\.polygonID)) {
            Set(board.planes.map { normalizedID($0.polygonID) })
        }
        let visibleCopperLayers = Set(
            HorizontalBoardLayers.all.filter {
                HorizontalBoardLayers.isCopper($0) && displayOptions.isLayerVisible($0)
            }
        )
        let visibleDecalIDs = memo.value("visibility: decals", input: BoardContentPair(board.decals, displayOptions)) {
            Set(board.decals.compactMap { decal -> String? in
                boardDecalHasVisibleLayer(decal) ? normalizedID(decal.id) : nil
            })
        }
        let visibleViaIDs = memo.value("visibility: vias", input: BoardContentPair(board.vias, displayOptions)) {
            Set(board.vias.compactMap { via -> String? in
                visibleViaLayers(for: via).isEmpty ? nil : normalizedID(via.id)
            })
        }
        let packageContent = BoardContentTriple(
            BoardContentTriple(board.packagePolygons, board.packageLines, board.packageArcs),
            BoardContentTriple(board.packagePads, board.packageHoles, board.packageTexts),
            board.packages
        )
        let visiblePackageIDs = memo.value("visibility: packages", input: BoardContentPair(packageContent, displayOptions)) {
            visibleBoardPackageIDs(in: board)
        }
        // A junction shows on the copper layers it spans, as Horizon gives
        // it its layers: a via's at its point, else its tracks' and net
        // ties'. One with all of them hidden can't be picked, any more than
        // its tracks can; one on no copper at all still can, to delete it.
        let junctionRanges = memo.value(
            "junction layer ranges",
            input: BoardContentTriple(board.tracks, board.netTies, BoardContentPair(board.vias, board.junctions))
        ) {
            board.junctionLayerRanges()
        }
        let hiddenJunctionIDs = memo.value("visibility: hidden junctions", input: BoardContentPair(junctionRanges, visibleCopperLayers)) {
            Set(junctionRanges.compactMap { id, span -> String? in
                visibleCopperLayers.contains(where: span.contains) ? nil : id
            })
        }
        return BoardSelectableVisibility(
            keepoutAllCopperByID: keepouts.first,
            keepoutAllCopperByPolygonID: keepouts.second,
            planePolygonIDs: planePolygonIDs,
            visibleCopperLayers: visibleCopperLayers,
            visibleDecalIDs: visibleDecalIDs,
            visibleViaIDs: visibleViaIDs,
            visiblePackageIDs: visiblePackageIDs,
            hiddenJunctionIDs: hiddenJunctionIDs
        )
    }

    private func filterVisibleSelectables(_ selectables: [HorizontalSelectable], in board: HorizontalBoard) -> [HorizontalSelectable] {
        filterVisibleSelectables(selectables, visibility: selectableVisibility(in: board))
    }

    private func filterVisibleSelectables(
        _ selectables: [HorizontalSelectable],
        visibility: BoardSelectableVisibility
    ) -> [HorizontalSelectable] {
        selectables.filter { selectable in
            if selectable.ref.type == .junction {
                return !visibility.hiddenJunctionIDs.contains(normalizedID(selectable.ref.id))
            }
            return isSelectableVisible(
                selectable.ref,
                keepoutAllCopperByID: visibility.keepoutAllCopperByID,
                keepoutAllCopperByPolygonID: visibility.keepoutAllCopperByPolygonID,
                planePolygonIDs: visibility.planePolygonIDs,
                visibleCopperLayers: visibility.visibleCopperLayers,
                visibleDecalIDs: visibility.visibleDecalIDs,
                visibleViaIDs: visibility.visibleViaIDs,
                visiblePackageIDs: visibility.visiblePackageIDs
            )
        }
    }

    /// The visible selectables of `board` by ref, for a board the selectable
    /// scene's key can't see (a move's or a placement's preview): looked up
    /// in each category's own map, so only the categories the preview changed
    /// are built and grouped again.
    private func boardSelectableLookup(in board: HorizontalBoard) -> (HorizontalSelectableRef) -> [HorizontalSelectable]? {
        let lookup = HorizontalSelectableLookup(maps: boardSelectableCategories(in: board).map(\.byRef))
        return { lookup[$0] }
    }

    private func isSelectableVisible(
        _ ref: HorizontalSelectableRef,
        keepoutAllCopperByID: [String: Bool],
        keepoutAllCopperByPolygonID: [String: Bool],
        planePolygonIDs: Set<String>,
        visibleCopperLayers: Set<Int>,
        visibleDecalIDs: Set<String>,
        visibleViaIDs: Set<String>,
        visiblePackageIDs: Set<String>
    ) -> Bool {
        switch ref.type {
        case .boardPanel:
            return displayOptions.showsOutlineLayer
        case .polygonArcCenter, .polygonEdge, .polygonVertex:
            if planePolygonIDs.contains(normalizedID(ref.id)) {
                return displayOptions.isLayerVisible(ref.layer)
            }
            // A keepout's polygon shows while keepouts do, on its layer, or
            // on any copper shown for one on all copper layers.
            if let allCopper = keepoutAllCopperByPolygonID[normalizedID(ref.id)] {
                guard displayOptions.keepouts else {
                    return false
                }
                return allCopper ? !visibleCopperLayers.isEmpty : displayOptions.isLayerVisible(ref.layer)
            }
            if let layer = ref.layer, isBoardBodyLayer(layer) {
                return displayOptions.boardBody || displayOptions.showsOutlineLayer
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
        case .padstackShape:
            return displayOptions.pads && displayOptions.isLayerVisible(ref.layer)
        case .via:
            return displayOptions.vias && visibleViaIDs.contains(normalizedID(ref.id))
        case .junction:
            // By the layers it spans, in `filterVisibleSelectables`.
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
                let phases = dash == nil ? [] : HorizontalMetalLinePrimitive.dashPhases(along: closedPath)
                for (index, pair) in zip(closedPath, closedPath.dropFirst()).enumerated() {
                    primitives.append(
                        HorizontalMetalLinePrimitive(
                            from: pair.0,
                            to: pair.1,
                            color: color,
                            width: width,
                            minimumWidth: minimumWidth,
                            dashLength: dash?.0 ?? 0,
                            dashGap: dash?.1 ?? 0,
                            dashPhase: phases.isEmpty ? 0 : phases[index],
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity
                        )
                    )
                }
            }
            return primitives
        }
    }

    /// The part of the scene's cache key that is style rather than content:
    /// its colours and widths. A change of it clears the scene's per-object
    /// cache, as every primitive's colour may have changed with it; the render
    /// layers and their fill modes are keyed per section instead.
    private func metalSceneStyleKey(renderLayers: [Int]) -> Int {
        var key = metalElementBucketsCacheKey(renderLayers: renderLayers)
        key.boardID = ""
        key.revision = 0
        key.tessellationVersion = 0
        key.counts = []
        key.movePreview = nil
        key.pastePreview = nil
        key.routePreviewRemoved = []
        key.renderLayers = []
        key.silkscreenClipVersion = 0
        key.layerFillModes = []
        return key.hashValue
    }

    /// What a plane draws: its fills, or its outline while it has none, and
    /// whether each fill's tessellation had arrived (a fill drawn before it
    /// did is drawn again once it has).
    private func planeSceneInput(_ plane: HorizontalPlane, filled: Bool) -> BoardScenePlaneInput {
        let fragments = plane.renderFragments
        let tessellated = !filled || fragments.enumerated().allSatisfy { index, fragment in
            selectableCache.hasPlaneFragmentTrianglePoints(
                boardPlaneFragmentKey(planeID: plane.id, fragmentIndex: index, fragment: fragment)
            )
        }
        return BoardScenePlaneInput(
            fragments: plane.fragments,
            outline: plane.fragments.isEmpty ? plane.fallbackPolygon?.vertices : nil,
            tessellated: tessellated
        )
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
            routePreviewRemoved: routeLoopPreview?.signature ?? [],
            renderLayers: renderLayers,
            silkscreenClipping: appearanceSettings.silkscreenClipping,
            silkscreenClipVersion: selectableCache.silkscreenClipVersion,
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
            connectionLineMinimumWidth: connectionLineMinimumWidth,
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
            outline: displayOptions.showsOutlineLayer,
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
            minimumLabelSize: minimumLabelSize,
            hiddenAirwireNetIDs: displayOptions.connectionLines ? displayOptions.hiddenAirwireNetIDs : []
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
            var activeBatches = [(name: String, bucket: BoardSceneBucket, filter: Int, batch: BoardMetalElementBatch)]()
            activeBatches.reserveCapacity(32)

            /// `filter` stands for what concat filters the bucket by, which
            /// changes its primitives as much as its build does.
            func add(_ name: String, _ bucket: BoardSceneBucket, _ batch: BoardMetalElementBatch, filter: Int = 0) {
                activeBatches.append((name, bucket, filter, batch))
            }
            let labelFilter = signature.minimumLabelSize.hashValue
            /// A label bucket culled to the legible zoom, kept while the
            /// bucket's primitives and the zoom step are what they were.
            func legible(_ name: String, _ bucket: BoardSceneBucket) -> BoardMetalElementBatch {
                guard let stamps = buckets.groupStamps?[bucket] else {
                    return buckets[keyPath: bucket].filtered(minimumLabelSize: signature.minimumLabelSize)
                }
                var hasher = Hasher()
                for group in stamps.keys.sorted() {
                    hasher.combine(group)
                    hasher.combine(stamps[group])
                }
                hasher.combine(signature.minimumLabelSize)
                return selectableCache.legibleLabels(name, key: hasher.finalize()) {
                    buckets[keyPath: bucket].filtered(minimumLabelSize: signature.minimumLabelSize)
                }
            }

            // Always-on per-layer geometry (board polygons, lines, arcs, tracks, netTies);
            // per-layer visibility is enforced by composite-group masking at draw time.
            add("layer polygons/lines/tracks", \.alwaysOnLayered, buckets.alwaysOnLayered)

            if signature.outline {
                add("panels", \.panels, buckets.panels)
                add("body outline high", \.bodyOutlineHigh, buckets.bodyOutlineHigh)
            } else if signature.boardBody {
                add("body outline low", \.bodyOutlineLow, buckets.bodyOutlineLow)
            }
            if signature.outline && signature.panelLabels {
                add("panel labels", \.panelLabels, buckets.panelLabels)
            }
            if signature.boardBody {
                add("body fill", \.bodyFill, buckets.bodyFill)
            }
            if signature.origin {
                add("origin", \.origin, buckets.origin)
            }
            if signature.keepouts && signature.hasVisibleCopper {
                add("all-copper keepouts", \.keepoutsAllCopper, buckets.keepoutsAllCopper)
            }
            if signature.keepouts {
                add("per-layer keepouts", \.keepoutsPerLayer, buckets.keepoutsPerLayer)
            }
            // Planes are gated only by their copper layer, which the renderer
            // masks per composite group.
            add("planes", \.planes, buckets.planes)
            if signature.packages {
                add("package geometry", \.packagesGeometry, buckets.packagesGeometry)
                add("package fallback", \.packagesFallback, buckets.packagesFallback)
            }
            // packagesText: shown when EITHER packages or text is on (matches original
            // logic where packageTexts emit via the packages block, or via the text block
            // when packages is off).
            if signature.packages || signature.text {
                add("package text", \.packagesText, buckets.packagesText)
            }
            if signature.decals {
                add("decals", \.decals, buckets.decals)
            }
            if signature.pads {
                add("pads", \.pads, buckets.pads)
            }
            if signature.vias {
                add("vias", \.vias, buckets.vias)
            }
            if signature.holes {
                add("board holes", \.holesNone, buckets.holesNone)
                if signature.pads {
                    add("package holes", \.holesPad, buckets.holesPad)
                }
                if signature.vias {
                    add("via holes", \.holesVia, buckets.holesVia)
                }
            }
            // Pad/via name labels composite AFTER holes so drill holes don't
            // punch through the text — matching TEXT_OVERLAY layer,
            // which renders on top of the copper and the holes.
            // The generated labels (and only these) are additionally culled by
            // zoom: once their glyphs shrink past legibility they are dropped
            // rather than drawn as unreadable clutter.
            if signature.pads && signature.padLabels {
                add("pad labels", \.padLabels, legible("pad labels", \.padLabels), filter: labelFilter)
            }
            if signature.vias && signature.viaLabels {
                add("via labels", \.viaLabels, legible("via labels", \.viaLabels), filter: labelFilter)
            }
            if signature.text {
                add("board text", \.text, buckets.text)
            }
            if signature.trackLabels {
                add("track labels", \.trackLabels, legible("track labels", \.trackLabels), filter: labelFilter)
            }
            if signature.dimensions {
                add("dimensions", \.dimensions, buckets.dimensions)
            }
            if signature.connectionLines {
                add("connection lines", \.connectionLines, buckets.connectionLines.filtered(hidingAirwiresOf: signature.hiddenAirwireNetIDs), filter: signature.hiddenAirwireNetIDs.hashValue)
            }
            if signature.connectionLines && signature.connectionLabels {
                add("connection labels", \.connectionLabels, buckets.connectionLabels)
            }
            return activeBatches
        }

        recordBoardMetalWeightSummary(
            activeBatches.map { BoardMetalNamedPrimitiveWeight(name: $0.name, weight: $0.batch.primitiveWeight) },
            label: "visible metal buckets"
        )

        // Each composite group's key: what its primitives were drawn from,
        // bucket by bucket in concat order, with what concat filtered them by.
        // A group whose key is unchanged holds the same primitives in the same
        // order, which the renderer then leaves where they are. A scene with no
        // stamps (a partial build's) leaves every group to be uploaded.
        let groupKeys = profile("group keys") { () -> [Int: Int]? in
            guard let stamps = buckets.groupStamps else {
                return nil
            }
            var hashers = [Int: Hasher]()
            for (name, bucket, filter, batch) in activeBatches {
                guard let groups = stamps[bucket] else {
                    if batch.lines.isEmpty, batch.triangles.isEmpty, batch.anchoredRects.isEmpty {
                        continue
                    }
                    return nil
                }
                for (group, stamp) in groups {
                    hashers[group, default: Hasher()].combine(name)
                    hashers[group, default: Hasher()].combine(stamp)
                    hashers[group, default: Hasher()].combine(filter)
                }
            }
            return hashers.mapValues { $0.finalize() }
        }

        let capacities = profile("count primitive capacities") {
            var lineCapacity = 0
            var triangleCapacity = 0
            var anchoredRectCapacity = 0
            for (_, _, _, batch) in activeBatches {
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
                for (_, _, _, batch) in activeBatches {
                    lines.append(contentsOf: batch.lines)
                }
            }
            profile("copy triangles") {
                for (_, _, _, batch) in activeBatches {
                    triangles.append(contentsOf: batch.triangles)
                }
            }
            profile("copy anchored rects") {
                for (_, _, _, batch) in activeBatches {
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
                metadata: metadata,
                groupKeys: groupKeys
            )
        }

        profile("copy lines and metadata") {
            for (_, _, _, batch) in activeBatches {
                let batchLineBase = lines.count
                lines.append(contentsOf: batch.lines)
                var textRunIndex = 0
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
                    // A text's strokes are consecutive and share one group,
                    // so its span starts where its first stroke lands.
                    var textRun: BoardMetalTextRun?
                    if textRunIndex < batch.textRuns.count,
                       batch.textRuns[textRunIndex].lineStart == index {
                        textRun = batch.textRuns[textRunIndex]
                        textRunIndex += 1
                    }
                    guard index < batch.lineOwners.count,
                          let owner = batch.lineOwners[index] else {
                        flushRun()
                        continue
                    }
                    if let textRun {
                        metadata.textSpansByRef[owner, default: []].append(
                            BoardMetalTextSpan(
                                textID: textRun.textID,
                                compositeGroup: group,
                                start: start,
                                count: textRun.lineCount,
                                lineIndex: batchLineBase + index
                            )
                        )
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
            for (_, _, _, batch) in activeBatches {
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
            for (_, _, _, batch) in activeBatches {
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
            metadata: metadata,
            groupKeys: groupKeys
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
            liveCanvasAirwires.drawn = nil
            return .empty
        }

        let bucketsKey = metalElementBucketsCacheKey(renderLayers: renderLayers)
        let buckets = selectableCache.elementBuckets(key: bucketsKey) {
            // Kick off background plane-fragment tessellation. The first build
            // goes ahead without plane fills (earcut on the heavy planes runs on
            // a detached Task with parallel workers). When that pass finishes it
            // bumps `selectableCache.tessellationVersion`, which invalidates this
            // bucket cache (the version is in the key) and so comes back here
            // with the freshly-tessellated fills. Only a rebuild can have new
            // fragments: called on every body pass instead, it hashed every
            // plane vertex on each step of a move.
            selectableCache.startBackgroundTessellation(planes: boardForMetalBuckets.planes)
            let result = BoardLoadTimer.measure("BoardCanvasView.buildBoardMetalElementBuckets") {
                buildBoardMetalElementBuckets(renderLayers: renderLayers)
            }
            BoardLoadTimer.flushPlaneTessellationSummary()
            if BoardSceneVerifier.isEnabled {
                BoardSceneVerifier.compare(
                    result,
                    with: buildBoardMetalElementBuckets(renderLayers: renderLayers, bypassesSceneCaches: true)
                )
            }
            return result
        }
        // The buckets just fetched are the ones drawn, cached or not, so what
        // they were built with is what the canvas shows.
        liveCanvasAirwires.drawn = HorizontalDrawnAirwires(
            airwires: buckets.airwires,
            shown: displayOptions.connectionLines,
            hiddenNetIDs: displayOptions.hiddenAirwireNetIDs
        )

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

    /// The silkscreen clip a scene build draws from. On the board it is the
    /// snapshot `refreshSilkscreenClips` keeps, which edits don't recompute;
    /// a pool editor's board is one package, cheap enough to clip every build.
    private func silkscreenClips(for board: HorizontalBoard) -> [Int: HorizontalClippedSilkscreenLayer] {
        guard let clipping = appearanceSettings.silkscreenClipping else {
            return [:]
        }
        guard modeProfile.mode == .board else {
            return HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        }
        return selectableCache.silkscreenClips(for: clipping)
    }

    /// Re-clips the silkscreen in the background, on the occasions that
    /// `BoardSilkscreenClipTrigger` names.
    private func refreshSilkscreenClips() {
        guard modeProfile.mode == .board else {
            return
        }
        selectableCache.refreshSilkscreenClips(
            board: editedBoard ?? sourceBoard,
            clipping: appearanceSettings.silkscreenClipping
        )
    }

    private var silkscreenClipTrigger: BoardSilkscreenClipTrigger {
        BoardSilkscreenClipTrigger(
            boardID: sourceBoard.uuid,
            clipping: appearanceSettings.silkscreenClipping,
            planePourRevision: planePourRevision
        )
    }

    // The build emits every primitive into one of the BoardMetalElementBuckets; it
    // does NOT consult element-type displayOptions flags. Layer-override visibility
    // is handled by composite-group masking in the renderer; element-type and
    // category-level visibility are applied at concat time by concatenateMetalBuckets.
    //
    // `partialBoard` builds just that board's primitives (a package being
    // placed) for merging into the scene already built; it leaves the
    // whole-board derived-geometry caches alone.
    private func buildBoardMetalElementBuckets(
        renderLayers: [Int],
        partialBoard: HorizontalBoard? = nil,
        bypassesSceneCaches: Bool = false
    ) -> BoardMetalElementBuckets {
        let board = partialBoard ?? boardForMetalBuckets
        let isPartial = partialBoard != nil
        let buckets = BoardMetalElementBuckets()
        // Each section replays what it drew last build for what is unchanged
        // (`BoardSceneObjectCache`); a partial or verifying build draws all.
        let scene = BoardSceneBuild(
            cache: isPartial || bypassesSceneCaches ? nil : selectableCache.sceneObjects,
            buckets: buckets
        )
        scene.cache?.beginBuild(styleKey: metalSceneStyleKey(renderLayers: renderLayers))

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
        // The pads' outlines and labels are worked out from the pads (and the
        // net names) alone, so they are kept while those are unchanged, edits
        // to anything else included. A verifying build works them out afresh.
        let memo = bypassesSceneCaches || isPartial ? BoardContentMemo() : selectableCache.contentMemo
        let padOutlineFragmentsByLayer = profile("pad outline fragments") {
            guard !isPartial, !bypassesSceneCaches else {
                return Dictionary(grouping: horizonPadOutlineFragments(board.packagePads), by: { $0.layer })
            }
            return memo.value("pad outline fragments", input: board.packagePads) {
                Dictionary(
                    grouping: horizonPadOutlineFragments(board.packagePads, unionCache: selectableCache.padOutlineUnionCache),
                    by: { $0.layer }
                )
            }
        }
        let viasByLayer = profile("vias by layer") { memo.value("vias by layer", input: board.vias) {
            var result = [Int: [HorizontalMarker]]()
            result.reserveCapacity(renderLayers.count)
            for via in board.vias {
                for layer in renderedViaLayers(for: via) {
                    result[layer, default: []].append(via)
                }
                // Solder-mask openings render on the mask layers alongside the
                // pads' mask shapes; the draw loop picks the mask diameter.
                for layer in via.maskLayers {
                    result[layer, default: []].append(via)
                }
            }
            return result
        } }

        // OPAQUE: overlay labels are dimmed to 0.86 by their composite group
        // (textOverlayMetalCompositeGroup), not by a baked per-vertex alpha, so
        // overlapping glyph strokes no longer compound into darker seams.
        let textOverlayColor = HorizontalMetalRGBA(theme.textOverlay)
        // Pad-center keys for the track-label "connects to a pad" heuristic,
        // precomputed once so the per-track check is O(1).
        let trackLabelPadCenterKeys = memo.value("pad centre keys", input: board.packagePadPositions) {
            Set(board.packagePadPositions.values.map { pointKey($0) })
        }
        let dimensionColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.dimensions).opacity(0.72))
        let connectionLineColor = HorizontalMetalRGBA(theme.connectionLine.opacity(0.86))
        let connectionLineDashColor = HorizontalMetalRGBA(theme.connectionLine.opacity(0.72))
        let airwireDashColor = HorizontalMetalRGBA(theme.airwire.opacity(0.72))
        let connectionLineMinimumWidth = connectionLineMinimumWidth
        let platedHoleStrokeColor = HorizontalMetalRGBA(theme.hole.opacity(0.7))
        let unplatedHoleStrokeColor = HorizontalMetalRGBA(theme.hole.opacity(0.45))
        let holeFillColor = HorizontalMetalRGBA(theme.background.opacity(0.95))
        let topFallbackColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.topCopper).opacity(0.82))
        let bottomFallbackColor = HorizontalMetalRGBA(layerColor(for: HorizontalBoardLayers.bottomCopper).opacity(0.82))
        let panelColor = HorizontalMetalRGBA(theme.textOverlay.opacity(0.36))
        let panelLabelColor = HorizontalMetalRGBA(theme.textOverlay.opacity(0.48))
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
        let packageOmitByID: [String: BoardScenePackageOmit] = board.packages.reduce(into: [:]) { result, package in
            if package.omitSilkscreen || package.omitOutline {
                result[normalizedID(package.id)] = BoardScenePackageOmit(silk: package.omitSilkscreen, outline: package.omitOutline)
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
            let phases = dash == nil ? [] : HorizontalMetalLinePrimitive.dashPhases(along: points)
            for (index, pair) in zip(points, points.dropFirst()).enumerated() {
                buckets[keyPath: bucketKey].appendLine(
                    HorizontalMetalLinePrimitive(
                        from: pair.0,
                        to: pair.1,
                        color: color,
                        width: width,
                        minimumWidth: minimumWidth,
                        dashLength: dash?.0 ?? 0,
                        dashGap: dash?.1 ?? 0,
                        dashPhase: phases.isEmpty ? 0 : phases[index],
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
            let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
            if !segments.isEmpty {
                buckets[keyPath: bucketKey].textRuns.append(BoardMetalTextRun(
                    textID: text.id,
                    lineStart: buckets[keyPath: bucketKey].lines.count,
                    lineCount: segments.count
                ))
            }
            for segment in segments {
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

        // Each layer's objects, grouped once while the collection is unchanged.
        func byLayer<Item: Equatable>(_ name: String, _ items: [Item], _ layer: (Item) -> Int?) -> [Int?: [Item]] {
            memo.value("\(name) by layer", input: items) { Dictionary(grouping: items, by: layer) }
        }
        let polygonsByLayer = byLayer("polygons", board.polygons) { $0.layer }
        let linesByLayer = byLayer("lines", board.lines) { $0.layer }
        let arcsByLayer = byLayer("arcs", board.arcs) { $0.layer }
        let tracksByLayer = byLayer("tracks", board.tracks) { $0.layer }
        let netTiesByLayer = byLayer("net ties", board.netTies) { $0.layer }
        let layerKeepoutsByLayer = byLayer("keepouts", board.keepouts.filter { !$0.allCopperLayers }) { $0.polygon.layer }
        let planesByLayer = byLayer("planes", board.planes) { $0.layer }
        let packagePolygonsByLayer = byLayer("package polygons", board.packagePolygons) { $0.layer }
        let packageLinesByLayer = byLayer("package lines", board.packageLines) { $0.layer }
        let packageArcsByLayer = byLayer("package arcs", board.packageArcs) { $0.layer }
        let packageTextsByLayer = byLayer("package texts", board.packageTexts) { $0.layer }
        let textsByLayer = byLayer("texts", board.texts) { $0.layer }
        let tessellationVersion = selectableCache.tessellationVersion

        let padLabelTextsByLayer = profile("pad label texts by layer") {
            guard !isPartial else {
                return packagePadLabelTextsByLayer(board: board)
            }
            return memo.value("pad label texts", input: BoardContentPair(board.packagePads, board.netDetails)) {
                packagePadLabelTextsByLayer(board: board)
            }
        }

        // ============================================================
        // Panels (outline)
        // ============================================================
        profile("panels") {
            let panelLabelTexts = board.boardPanels.compactMap(boardPanelLabelText)
            scene.section(
                .init("panels"),
                writes: [\.panels, \.panelLabels],
                source: BoardContentPair(board.boardPanels.map(\.bounds), panelLabelTexts)
            ) {
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
            for text in panelLabelTexts {
                appendText(text, color: panelLabelColor, minimumWidth: 0.85, to: \.panelLabels)
            }
            }
        }

        // The origin is the backdrop's mark now (see HorizontalGridRenderer.
        // drawOriginMark); the "origin" bucket stays empty.

        // ============================================================
        // Body (boardBody and outline) — outlines emitted in two opacity variants
        // ============================================================
        profile("board body") {
            let bodyPolygons = memo.value("body polygons", input: board.polygons) {
                board.polygons.filter { isBoardBodyLayer($0.layer) }
            }
            scene.section(
                .init("board body"),
                writes: [\.bodyOutlineHigh, \.bodyOutlineLow, \.bodyFill],
                source: BoardContentPair(bodyPolygons, layerUsesFill(HorizontalBoardLayers.outline))
            ) {
            for polygon in bodyPolygons {
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
            }
            // The fill is the board itself: each outer piece minus the
            // cutouts drawn inside it, which stay empty.
            if layerUsesFill(HorizontalBoardLayers.outline) {
                for shape in HorizontalBoardOutlines.shapes(from: board.polygons, arcPrecision: 24) {
                    let owner = selectableRef(id: shape.outer.id, type: .polygonEdge, layer: shape.outer.layer)
                    appendTriangles(
                        HorizontalMetalTessellator.fragmentTriangles([shape.vertices] + shape.cutouts, color: bodyFillColor),
                        compositeGroup: Self.boardBodyMetalCompositeGroup,
                        owner: owner,
                        to: \.bodyFill
                    )
                }
            }
            }
        }

        // ============================================================
        // Keepouts (allCopper variant — gated by hasVisibleCopper at concat)
        // ============================================================
        profile("all-copper keepouts") {
            let allCopperKeepouts = memo.value("all-copper keepouts", input: board.keepouts) {
                board.keepouts.filter(\.allCopperLayers)
            }
            scene.section(.init("all-copper keepouts"), writes: [\.keepoutsAllCopper], source: allCopperKeepouts, objects: HorizontalKeepout.self) { draw in
            for keepout in allCopperKeepouts { draw(keepout.id, keepout) {
                // A board keepout's spans are its polygon's, which its parts
                // pick and a move shifts, as a polygon's are.
                let owner = packageOwner(for: keepout.id)
                    ?? selectableRef(id: keepout.polygon.id, type: .polygonEdge, layer: keepout.polygon.layer)
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
            } }
            }
        }

        // ============================================================
        // Connection lines / airwires + labels
        // ============================================================
        profile("connection lines") {
            buckets.airwires = board.airwires
            scene.section(
                .init("connection lines"),
                writes: [\.connectionLines, \.connectionLabels],
                source: BoardContentPair(board.connectionLines, board.airwires)
            ) {
            for connectionLine in board.connectionLines {
                appendSegment(
                    connectionLine,
                    color: connectionLineDashColor,
                    minimumWidth: connectionLineMinimumWidth,
                    dash: (6, 4),
                    owner: selectableRef(id: connectionLine.id, type: .connectionLine),
                    to: \.connectionLines
                )
            }
            for airwire in board.airwires {
                appendSegment(
                    airwire,
                    color: airwireDashColor,
                    minimumWidth: connectionLineMinimumWidth,
                    dash: (6, 4),
                    owner: airwire.netID.map(airwireOwner),
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
        }

        // ============================================================
        // Dimensions (lines + arrows + labels)
        // ============================================================
        profile("dimensions") {
            scene.section(.init("dimensions"), writes: [\.dimensions], source: board.dimensions, objects: HorizontalDimension.self) { draw in
            for dimension in board.dimensions { draw(dimension.id, dimension) {
                let owner = selectableRef(id: dimension.id, type: .dimension)
                let geometry = dimension.measurementGeometry
                let vector = geometry.p1Projected - geometry.p0Projected
                let length = hypot(vector.x, vector.y)
                guard length > 0 else { return }

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
            } }
            }
        }

        // ============================================================
        // Per-layer geometry
        // ============================================================
        // Clip-silkscreen-to-mask mode: a silkscreen object near a mask
        // opening draws from its clipped fragments instead of its strokes, as
        // long as it is still the object that was clipped.
        let clippedSilkscreenLayers = silkscreenClips(for: board)
        func clippedSilkscreen<Source: Hashable>(_ id: String, layer: Int, source: Source) -> HorizontalClippedSilkscreenObject? {
            clippedSilkscreenLayers[layer]?.object(id, matching: source)
        }
        /// `strokeMinimumWidth` is the screen width the object's strokes are
        /// held to when drawn unclipped (a polygon has none).
        func appendClippedSilkscreen(
            _ clipped: HorizontalClippedSilkscreenObject,
            color: HorizontalMetalRGBA,
            strokeMinimumWidth: Float = 0.75,
            compositeGroup: Int,
            compositeOpacity: Float,
            owner: HorizontalSelectableRef?,
            to bucketKey: ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>
        ) {
            for (index, fragment) in clipped.fragments.enumerated() {
                appendTriangles(
                    HorizontalMetalTessellator.triangles(for: fragment, color: color),
                    compositeGroup: compositeGroup,
                    compositeOpacity: compositeOpacity,
                    owner: owner,
                    to: bucketKey
                )
                // What is left of a stroke's centerline, as a hairline held
                // to the stroke's own minimum: zoomed out it gives the
                // clipped stroke the weight of an unclipped one, zoomed in
                // it lies hidden in the fill.
                let centerlines = clipped.centerlines(inFragment: index)
                if !centerlines.isEmpty {
                    for piece in centerlines {
                        appendPolyline(
                            piece,
                            color: color,
                            width: 0,
                            minimumWidth: strokeMinimumWidth,
                            compositeGroup: compositeGroup,
                            compositeOpacity: compositeOpacity,
                            owner: owner,
                            to: bucketKey
                        )
                    }
                    continue
                }
                // A polygon, or a sliver off the side of a stroke: the
                // outline keeps it visible when zoomed out.
                for path in fragment {
                    appendClosedPolyline(
                        path,
                        color: color,
                        minimumWidth: 0.7,
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: owner,
                        to: bucketKey
                    )
                }
            }
        }

        for layer in renderLayers {
            let compositeGroup = metalCompositeGroup(for: layer)
            // Constant — layerOpacity is applied as a uniform at composite time.
            let compositeOpacity: Float = 1
            let outlineOnly = !layerUsesFill(layer)
            // What every section on this layer draws with besides its objects:
            // the layer's fill, and the silkscreen clip its objects may be cut by.
            let layerStyle = BoardContentPair(
                layerUsesFill(layer),
                clippedSilkscreenLayers[layer] == nil ? 0 : selectableCache.silkscreenClipVersion
            )

            // Always-on per-layer: board polygons (non-body), lines, arcs, tracks, netTies
            profile("layer polygons lines tracks") {
                let layerPolygons = isBoardBodyLayer(layer) ? [] : polygonsByLayer[layer] ?? []
                scene.section(.init("polygons", layer: layer), writes: [\.alwaysOnLayered], source: BoardContentPair(layerPolygons, layerStyle), objects: HorizontalPolygon.self) { draw in
                for polygon in layerPolygons { draw(polygon.id, polygon) {
                    let owner = selectableRef(id: polygon.id, type: .polygonEdge, layer: layer)
                    if let clipped = clippedSilkscreen(polygon.id, layer: layer, source: polygon) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.alwaysOnLayered)
                        return
                    }
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
                } }
                }

                let layerLines = linesByLayer[layer] ?? []
                scene.section(.init("lines", layer: layer), writes: [\.alwaysOnLayered], source: BoardContentPair(layerLines, layerStyle), objects: HorizontalSegment.self) { draw in
                for line in layerLines { draw(line.id, line) {
                    if let clipped = clippedSilkscreen(line.id, layer: layer, source: line) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), strokeMinimumWidth: 1.1, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: selectableRef(id: line.id, type: .boardLine, layer: layer), to: \.alwaysOnLayered)
                        return
                    }
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
                } }
                }
                let layerArcs = arcsByLayer[layer] ?? []
                scene.section(.init("arcs", layer: layer), writes: [\.alwaysOnLayered], source: BoardContentPair(layerArcs, layerStyle), objects: HorizontalArc.self) { draw in
                for arc in layerArcs { draw(arc.id, arc) {
                    if let clipped = clippedSilkscreen(arc.id, layer: layer, source: arc) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), strokeMinimumWidth: 1, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: selectableRef(id: arc.id, type: .boardArc, layer: layer), to: \.alwaysOnLayered)
                        return
                    }
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
                } }
                }
                let layerTracks = tracksByLayer[layer] ?? []
                scene.section(.init("tracks", layer: layer), writes: [\.alwaysOnLayered], source: BoardContentPair(layerTracks, layerStyle), objects: HorizontalSegment.self) { draw in
                for track in layerTracks { draw(track.id, track) {
                    let trackColor = track.netID == nil ? noNetTrackColor : layerMetalColor(layer)
                    let owner = selectableRef(id: track.id, type: .track, layer: layer)
                    if let arc = track.arc {
                        appendArc(arc, color: trackColor, minimumWidth: 1.1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.alwaysOnLayered)
                    } else {
                        appendSegment(track, color: trackColor, minimumWidth: 1.1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.alwaysOnLayered)
                    }
                } }
                }
                let layerNetTies = netTiesByLayer[layer] ?? []
                scene.section(.init("net ties", layer: layer), writes: [\.alwaysOnLayered], source: BoardContentPair(layerNetTies, layerStyle), objects: HorizontalSegment.self) { draw in
                for netTie in layerNetTies { draw(netTie.id, netTie) {
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
                } }
                }

                // Keepouts (per-layer)
                let layerKeepouts = layerKeepoutsByLayer[layer] ?? []
                scene.section(.init("keepouts", layer: layer), writes: [\.keepoutsPerLayer], source: BoardContentPair(layerKeepouts, layerStyle), objects: HorizontalKeepout.self) { draw in
                for keepout in layerKeepouts { draw(keepout.id, keepout) {
                    let owner = packageOwner(for: keepout.id, layer: layer)
                        ?? selectableRef(id: keepout.polygon.id, type: .polygonEdge, layer: layer)
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
                } }
                }
            }

            // Planes (outline + fill)
            profile("planes") {
                let layerPlanes = planesByLayer[layer] ?? []
                scene.section(
                    .init("planes", layer: layer),
                    writes: [\.planes],
                    source: BoardContentTriple(layerPlanes, layerStyle, tessellationVersion),
                    objects: BoardScenePlaneInput.self
                ) { draw in
                for plane in layerPlanes { draw(plane.id, planeSceneInput(plane, filled: layerUsesFill(layer))) {
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
                } }
                }
            }

            // Packages (geometry + texts)
            profile("package geometry") {
                let packageStyle = BoardContentPair(layerStyle, packageOmitByID)
                // Filtered only when a package omits something, so an unchanged
                // layer's array is the one last build had.
                func shown<Item>(_ items: [Item], _ id: (Item) -> String) -> [Item] {
                    packageOmitByID.isEmpty ? items : items.filter { !isPackageGeometryHidden(id($0), layer: layer) }
                }
                let layerPackagePolygons = shown(packagePolygonsByLayer[layer] ?? []) { $0.id }
                scene.section(.init("package polygons", layer: layer), writes: [\.packagesGeometry], source: BoardContentPair(layerPackagePolygons, packageStyle), objects: HorizontalPolygon.self) { draw in
                for polygon in layerPackagePolygons { draw(polygon.id, polygon) {
                    let owner = packageOwner(for: polygon.id, layer: layer)
                    if let clipped = clippedSilkscreen(polygon.id, layer: layer, source: polygon) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.packagesGeometry)
                        return
                    }
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
                } }
                }
                let layerPackageLines = shown(packageLinesByLayer[layer] ?? []) { $0.id }
                scene.section(.init("package lines", layer: layer), writes: [\.packagesGeometry], source: BoardContentPair(layerPackageLines, packageStyle), objects: HorizontalSegment.self) { draw in
                for line in layerPackageLines { draw(line.id, line) {
                    if let clipped = clippedSilkscreen(line.id, layer: layer, source: line) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), strokeMinimumWidth: 1, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: line.id, layer: layer), to: \.packagesGeometry)
                        return
                    }
                    appendSegment(line, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: line.id, layer: layer), to: \.packagesGeometry)
                } }
                }
                let layerPackageArcs = shown(packageArcsByLayer[layer] ?? []) { $0.id }
                scene.section(.init("package arcs", layer: layer), writes: [\.packagesGeometry], source: BoardContentPair(layerPackageArcs, packageStyle), objects: HorizontalArc.self) { draw in
                for arc in layerPackageArcs { draw(arc.id, arc) {
                    if let clipped = clippedSilkscreen(arc.id, layer: layer, source: arc) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), strokeMinimumWidth: 1, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: arc.id, layer: layer), to: \.packagesGeometry)
                        return
                    }
                    appendArc(arc, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: arc.id, layer: layer), to: \.packagesGeometry)
                } }
                }
            }

            profile("package text") {
                // omit_silkscreen hides the package's own silk text too, but
                // never the smashed (`fromSmash`) board-level copies, which
                // are the whole point of smashing.
                let layerPackageTexts = packageOmitByID.isEmpty
                    ? packageTextsByLayer[layer] ?? []
                    : (packageTextsByLayer[layer] ?? []).filter { $0.fromSmash || !isPackageGeometryHidden($0.id, layer: layer) }
                scene.section(.init("package texts", layer: layer), writes: [\.packagesText], source: BoardContentPair(layerPackageTexts, BoardContentPair(layerStyle, packageOmitByID)), objects: HorizontalText.self) { draw in
                for text in layerPackageTexts { draw(text.id, text) {
                    if let clipped = clippedSilkscreen(text.id, layer: layer, source: text) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: text.id, layer: layer), to: \.packagesText)
                        return
                    }
                    appendText(text, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: packageOwner(for: text.id, layer: layer), to: \.packagesText)
                } }
                }
            }

            // Decals
            profile("decals") {
                scene.section(.init("decals", layer: layer), writes: [\.decals], source: BoardContentPair(board.decals, layerStyle), objects: HorizontalBoardDecal.self) { draw in
                for decal in board.decals { draw(decal.id, decal) {
                    let owner = selectableRef(id: decal.id, type: .boardDecal)
                    for polygon in decal.polygons where polygon.layer == layer {
                        if let clipped = clippedSilkscreen(polygon.id, layer: layer, source: polygon) {
                            appendClippedSilkscreen(clipped, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                            continue
                        }
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
                        if let clipped = clippedSilkscreen(line.id, layer: layer, source: line) {
                            appendClippedSilkscreen(clipped, color: layerMetalColor(layer), strokeMinimumWidth: 1, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                            continue
                        }
                        appendSegment(line, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                    }
                    for arc in decal.arcs where arc.layer == layer {
                        if let clipped = clippedSilkscreen(arc.id, layer: layer, source: arc) {
                            appendClippedSilkscreen(clipped, color: layerMetalColor(layer), strokeMinimumWidth: 1, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                            continue
                        }
                        appendArc(arc, color: layerMetalColor(layer), minimumWidth: 1, outlineOnly: outlineOnly, compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                    }
                    for text in decal.texts where text.layer == layer {
                        if let clipped = clippedSilkscreen(text.id, layer: layer, source: text) {
                            appendClippedSilkscreen(clipped, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                            continue
                        }
                        appendText(text, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: owner, to: \.decals)
                    }
                } }
                }
            }

            // Pads
            profile("pads") {
                let layerPads = padOutlineFragmentsByLayer[layer] ?? []
                scene.section(.init("pads", layer: layer), writes: [\.pads], source: BoardContentPair(layerPads, layerStyle), objects: HorizontalPadOutlineFragment.self) { draw in
                for pad in layerPads { draw(pad.id, pad) {
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
                } }
                }
            }

            // Vias (ring + fill on copper; the padstack's mask opening on mask)
            profile("vias") {
                let layerVias = viasByLayer[layer] ?? []
                scene.section(.init("vias", layer: layer), writes: [\.vias], source: BoardContentPair(layerVias, layerStyle), objects: HorizontalMarker.self) { draw in
                for via in layerVias { draw(via.id, via) {
                    let maskDiameter = via.maskDiameter(on: layer)
                    let outerRadius = (maskDiameter ?? via.size) / 2
                    let owner = selectableRef(id: via.id, type: .via)
                    let points = circlePoints(center: via.position, radius: outerRadius, segments: 24)
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
                } }
                }
            }

            // Texts (board)
            profile("board text") {
                let layerTexts = textsByLayer[layer] ?? []
                scene.section(.init("texts", layer: layer), writes: [\.text], source: BoardContentPair(layerTexts, layerStyle), objects: HorizontalText.self) { draw in
                for text in layerTexts { draw(text.id, text) {
                    if let clipped = clippedSilkscreen(text.id, layer: layer, source: text) {
                        appendClippedSilkscreen(clipped, color: layerMetalColor(layer), compositeGroup: compositeGroup, compositeOpacity: compositeOpacity, owner: selectableRef(id: text.id, type: .text, layer: layer), to: \.text)
                        return
                    }
                    appendText(
                        text,
                        color: layerMetalColor(layer),
                        compositeGroup: compositeGroup,
                        compositeOpacity: compositeOpacity,
                        owner: selectableRef(id: text.id, type: .text, layer: layer),
                        to: \.text
                    )
                } }
                }
            }

            if Self.emitsGeneratedBoardLabelsInMetal {
                // Track / netTie net labels (per-layer)
                profile("track labels") {
                    // A label is its net's name fitted to the track, unless an
                    // end is on a pad: worked out for each track (cheap), and
                    // stroked again only when it changed.
                    let labelSource = BoardContentPair(board.netDetails, trackLabelPadCenterKeys)
                    let layerTracks = tracksByLayer[layer] ?? []
                    let labelTracks = memo.value("label tracks \(layer)", input: layerTracks) { layerTracks.filter { $0.center == nil } }
                    scene.section(.init("track labels", layer: layer), writes: [\.trackLabels], source: BoardContentPair(labelTracks, labelSource), objects: HorizontalText?.self) { draw in
                    for track in labelTracks {
                        let label = segmentNetLabelText(track, idSuffix: "track-net-label", padCenterKeys: trackLabelPadCenterKeys)
                        draw(track.id, label) {
                        if let text = label {
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
                    }
                    }
                    let labelNetTies = netTiesByLayer[layer] ?? []
                    scene.section(.init("net tie labels", layer: layer), writes: [\.trackLabels], source: BoardContentPair(labelNetTies, labelSource), objects: HorizontalText?.self) { draw in
                    for netTie in labelNetTies {
                        let label = segmentNetLabelText(netTie, idSuffix: "net-tie-net-label", padCenterKeys: trackLabelPadCenterKeys)
                        draw(netTie.id, label) {
                        if let text = label {
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
                    }
                }

                // Pad labels (per-layer)
                profile("pad labels") {
                    let layerPadLabels = padLabelTextsByLayer[layer] ?? []
                    scene.section(.init("pad labels", layer: layer), writes: [\.padLabels], source: layerPadLabels, objects: HorizontalText.self) { draw in
                    for text in layerPadLabels { draw(text.id, text) {
                        appendText(
                            text,
                            color: textOverlayColor,
                            minimumWidth: 0.7,
                            compositeGroup: Self.textOverlayMetalCompositeGroup,
                            compositeOpacity: Self.textOverlayMetalCompositeOpacity,
                            owner: packageOwner(for: text.id, layer: layer),
                            to: \.padLabels
                        )
                    } }
                    }
                }
            }
        }

        // Via diameters, green over the copper of each via that shows any
        // filled on a visible layer; the holes go over them.
        profile("via diameters") {
            let copperLayers = Set(renderLayers.filter(HorizontalBoardLayers.isCopper))
            let filledCopperLayers = copperLayers.filter(layerUsesFill)
            let fill = HorizontalMetalRGBA(Self.viaDiameterFill)
            scene.section(.init("via diameters"), writes: [\.vias], source: BoardContentTriple(board.vias, copperLayers, filledCopperLayers), objects: HorizontalMarker.self) { draw in
            for via in board.vias { draw(via.id, via) {
                let layers = renderedViaLayers(for: via).filter(copperLayers.contains)
                guard layers.contains(where: layerUsesFill) else {
                    return
                }
                let owner = selectableRef(id: via.id, type: .via)
                let points = circlePoints(center: via.position, radius: via.size / 2, segments: 24)
                appendFilledCircle(
                    center: via.position,
                    radius: via.size / 2,
                    color: fill,
                    points: points,
                    compositeGroup: Self.viaDiameterMetalCompositeGroup,
                    owner: owner,
                    to: \.vias
                )
            } }
            }
        }

        // ============================================================
        // Holes (outlines + fills)
        // ============================================================
        profile("holes") {
            scene.section(.init("board holes"), writes: [\.holesNone], source: board.holes, objects: HorizontalHole.self) { draw in
            for hole in board.holes { draw(hole.id, hole) {
                let owner = selectableRef(id: hole.id, type: .boardHole)
                let points = hole.outlinePoints(precision: 32)
                appendHoleOutline(hole, points: points, owner: owner, to: \.holesNone)
                appendHoleFill(hole, points: points, owner: owner, to: \.holesNone)
            } }
            }
            scene.section(.init("package holes"), writes: [\.holesPad], source: board.packageHoles, objects: HorizontalHole.self) { draw in
            for hole in board.packageHoles { draw(hole.id, hole) {
                let owner = packageOwner(for: hole.id)
                let points = hole.outlinePoints(precision: 32)
                appendHoleOutline(hole, points: points, owner: owner, to: \.holesPad)
                appendHoleFill(hole, points: points, owner: owner, to: \.holesPad)
            } }
            }
            scene.section(.init("via holes"), writes: [\.holesVia], source: board.viaHoles, objects: HorizontalHole.self) { draw in
            for hole in board.viaHoles { draw(hole.id, hole) {
                // Drawn as part of its via, which a move shifts, drill and all.
                let owner = selectableRef(id: HorizontalBoard.viaID(ofViaHole: hole.id) ?? hole.id, type: .via)
                let points = hole.outlinePoints(precision: 32)
                appendHoleOutline(hole, points: points, owner: owner, to: \.holesVia)
                appendHoleFill(hole, points: points, owner: owner, to: \.holesVia)
            } }
            }
        }

        // Generated labels are intentionally omitted from Metal for now while we
        // isolate their impact on board-view interaction latency.
        if Self.emitsGeneratedBoardLabelsInMetal {
            profile("via labels") {
                // Only over copper that shows: hiding a layer changes the
                // render layers, which rebuilds these buckets.
                let shownVias = memo.value("label vias", input: BoardContentPair(board.vias, displayOptions)) {
                    board.vias.filter { displayOptions.showsCopper(of: $0) }
                }
                scene.section(.init("via labels"), writes: [\.viaLabels], source: BoardContentPair(shownVias, board.netDetails), objects: HorizontalText?.self) { draw in
                for via in shownVias {
                    let label = viaLabelText(via)
                    draw(via.id, label) {
                    if let label {
                        appendText(label, color: textOverlayColor, minimumWidth: 0.7, compositeGroup: Self.textOverlayMetalCompositeGroup, compositeOpacity: Self.textOverlayMetalCompositeOpacity, owner: selectableRef(id: via.id, type: .via), to: \.viaLabels)
                    }
                    }
                }
                }
            }
        }

        // Package fallback labels + anchored rect markers (for packages with no
        // resolved geometry). Gated at concat by signature.packages.
        profile("package fallback labels") {
            let resolvedPackageIDs = packageIDsWithGeometry(in: board)
            let fallbackPackages = memo.value("fallback packages", input: BoardContentPair(board.packages, resolvedPackageIDs)) {
                board.packages.filter { !resolvedPackageIDs.contains($0.id) }
            }
            scene.section(.init("package fallback labels"), writes: [\.packagesFallback], source: fallbackPackages, objects: HorizontalPlacement.self) { draw in
            for package in fallbackPackages { draw(package.id, package) {
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
            } }
            }
        }

        recordBoardMetalWeightSummary(buckets.namedBatches(), label: "built bucket")

        scene.finish()
        return buckets
    }

    private func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else {
            return 0
        }
        return end - start
    }

    private func measuredBoardMetalMovePatches(lineBatch: BoardMetalLineBatch) -> HorizontalMetalBufferPatches {
        guard moveState != nil else {
            return .empty
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let patches = boardMetalMovePatches(lineBatch: lineBatch)
        HorizontalMoveRateDiagnostics.recordMetalPatches(
            .boardMove,
            nanoseconds: elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
            patches: patches,
            active: moveState != nil
        )
        return patches
    }

    private func boardMetalMovePatches(lineBatch: BoardMetalLineBatch) -> HorizontalMetalBufferPatches {
        guard canPatchBoardMoveInMetal,
              let moveState else {
            return .empty
        }

        let metadata = lineBatch.metadata
        // The move's shift, and any turn R or T made in place (122).
        let placement = moveState.livePlacement
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
                        patches.lineTranslationPatches.append(contentsOf: metalLineTranslationPatches(spans: spans, placement: placement))
                    } else if let endpointPatch = boardMetalLineEndpointPatch(
                        for: segmentsByID[normalizedID(ref.id)],
                        move: segmentMove,
                        placement: placement,
                        spans: spans
                    ) {
                        patches.lineEndpointPatches.append(endpointPatch)
                    } else {
                        let primitives = boardResidentMovedLinePrimitives(
                            for: ref,
                            move: segmentMove,
                            placement: placement,
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
                    patches.lineTranslationPatches.append(contentsOf: metalLineTranslationPatches(spans: spans, placement: placement))
                }
            }

            if let spans = metadata.triangleSpansByRef[ref],
               plan.translatedRefs.contains(ref) {
                patches.triangleTranslationPatches.append(contentsOf: metalTriangleTranslationPatches(spans: spans, placement: placement))
            }

            if let spans = metadata.anchoredRectSpansByRef[ref],
               plan.translatedRefs.contains(ref) {
                patches.anchoredRectTranslationPatches.append(contentsOf: metalAnchoredRectTranslationPatches(spans: spans, placement: placement))
            }
        }

        // The texts the turn redraws, shifted by the move since it.
        if let turn = moveState.turn {
            let delta = moveState.lastPoint - moveState.startPoint
            let redraws = selectableCache.turnedMoveTexts(
                key: BoardTurnedMoveTextsKey(lineKey: lineBatch.lineKey, turns: turn.count, placement: turn.placement)
            ) {
                boardTurnedTextRedraws(
                    for: plan.translatedRefs,
                    lineBatch: lineBatch,
                    turnedBoard: turn.board
                )
            }
            patches.lineRedrawPatches = delta == .zero ? redraws : redraws.map { patch in
                var patch = patch
                patch.primitives = patch.primitives.map { translated($0, by: delta) }
                return patch
            }
        }

        // The net labels of the tracks the move stretches or turns, drawn
        // from where it takes them, or hidden until the commit.
        patches.lineRedrawPatches += boardMovingSegmentLabelRedraws(
            plan: plan,
            placement: placement,
            lineBatch: lineBatch,
            segmentsByID: segmentsByID
        )

        // The nets the move drags draw their airwires live in the preview
        // overlay; their resident airwires go transparent meanwhile.
        if let airwireRequest = moveState.airwireRequest,
           let movingAirwires = selectableCache.movingAirwires(for: airwireRequest) {
            let transparent = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 0)
            for netID in movingAirwires.netIDs {
                let owner = airwireOwner(netID: netID)
                guard let spans = metadata.lineSpansByRef[owner],
                      let primitives = metadata.linePrimitivesByRef[owner] else {
                    continue
                }
                let hidden = primitives.map { primitive in
                    var primitive = primitive
                    primitive.color = transparent
                    return primitive
                }
                patches.linePatches.append(contentsOf: metalLinePatches(spans: spans, primitives: hidden))
            }
        }
        return patches
    }

    /// The strokes to write over the labels of the tracks and net ties the
    /// move reshapes (`BoardMovingSegmentLabels`): each label as the scene
    /// would draw it on the moved track, or hidden. The moved track is not
    /// tested against the pads, as the scene's labels are: an end the move
    /// brings onto a pad keeps its label until the commit's rebuild drops it.
    private func boardMovingSegmentLabelRedraws(
        plan: BoardResidentMovePlan,
        placement: HorizontalPlacementTransform,
        lineBatch: BoardMetalLineBatch,
        segmentsByID: [String: HorizontalSegment]
    ) -> [HorizontalMetalLineBufferPatch] {
        guard !lineBatch.metadata.textSpansByRef.isEmpty else {
            return []
        }
        let reshaped = BoardMovingSegmentLabels.reshaped(
            plan: plan,
            placement: placement,
            segments: segmentsByID,
            textSpans: lineBatch.metadata.textSpansByRef
        )
        var redrawnStrokes = 0
        var patches = [HorizontalMetalLineBufferPatch]()
        for segment in reshaped {
            let strokes = segment.spans.reduce(0) { $0 + $1.count }
            redrawnStrokes += strokes
            let label = redrawnStrokes <= BoardMovingSegmentLabels.maximumRedrawnStrokes
                ? segmentNetLabelText(
                    segment.moved,
                    idSuffix: segment.ref.type == .boardNetTie ? "net-tie-net-label" : "track-net-label",
                    padCenterKeys: []
                )
                : nil
            for span in segment.spans {
                if let patch = BoardMovingSegmentLabels.patch(
                    for: span,
                    label: label.flatMap { normalizedID($0.id) == normalizedID(span.textID) ? $0 : nil },
                    lines: lineBatch.lines,
                    minimumLabelSize: minimumLabelSize
                ) {
                    patches.append(patch)
                }
            }
        }
        return patches
    }

    /// What a net's resident airwires are drawn under, so a move can find and
    /// hide them while it draws that net's live ones.
    private func airwireOwner(netID: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: "airwire/" + normalizedID(netID), type: .connectionLine)
    }

    /// Starts making the live rats' nest of a move that carries a package, as
    /// Horizon's move tool keeps one; nil for any other move.
    private func startMovingAirwires(plan: BoardResidentMovePlan, board: HorizontalBoard) -> Int? {
        let packageIDs = Set(plan.translatedRefs.filter { $0.type == .boardPackage }.map { normalizedID($0.id) })
        guard modeProfile.mode == .board, !packageIDs.isEmpty else {
            return nil
        }
        let viaIDs = Set(plan.translatedRefs.filter { $0.type == .via }.map { normalizedID($0.id) })
        let junctionIDs = Set(plan.translatedRefs.filter { $0.type == .junction }.map { normalizedID($0.id) })
        var segmentEnds = [String: (from: Bool, to: Bool)]()
        for ref in plan.translatedRefs where ref.type == .track || ref.type == .boardNetTie {
            segmentEnds[normalizedID(ref.id)] = (true, true)
        }
        for (ref, move) in plan.segmentMoves {
            segmentEnds[normalizedID(ref.id)] = (move.movesFrom, move.movesTo)
        }
        let movingSegmentEnds = segmentEnds
        // The planes whose outlines move whole, their fills with them.
        let movedPolygonIDs = Set(selectedObjects.filter { BoardPolygonParts.isPart($0.type) }.map { normalizedID($0.id) })
            .subtracting(BoardPolygonParts.reshapedPolygonIDs(by: selectedObjects, in: board.polygons + board.outlinePolygons))
        let planeIDs = Set(board.planes.filter { movedPolygonIDs.contains(normalizedID($0.polygonID)) }.map { normalizedID($0.id) })
        return selectableCache.requestMovingAirwires {
            // After the editor's connectivity pass, as the commit makes the
            // rats' nest: a board as loaded has no junction nets, and without
            // them the live airwires skipped every routed bend (125). Off the
            // main thread, like the rest of the request.
            HorizontalBoardConnectivity.recompute(board)
                .movingAirwires(packageIDs: packageIDs, viaIDs: viaIDs, junctionIDs: junctionIDs, segmentEnds: movingSegmentEnds,
                                planeIDs: planeIDs)
        }
    }

    /// `segment` is the moved track or line, looked up once for the whole
    /// move (`boardSegmentLookup`): found by a search of the board per ref,
    /// a whole-board move searched every track for each.
    private func boardMetalLineEndpointPatch(
        for segment: HorizontalSegment?,
        move: BoardResidentSegmentMove,
        placement: HorizontalPlacementTransform,
        spans: [BoardMetalPrimitiveSpan]
    ) -> HorizontalMetalLineEndpointPatch? {
        guard let segment,
              segment.center == nil,
              move.movesFrom || move.movesTo,
              let firstSpan = spans.first,
              firstSpan.count > 0 else {
            return nil
        }

        return HorizontalMetalLineEndpointPatch(
            compositeGroup: firstSpan.compositeGroup,
            start: firstSpan.start,
            from: move.movesFrom ? placement.applying(to: segment.from) : nil,
            to: move.movesTo ? placement.applying(to: segment.to) : nil
        )
    }

    private func boardResidentMovedLinePrimitives(
        for ref: HorizontalSelectableRef,
        move: BoardResidentSegmentMove,
        placement: HorizontalPlacementTransform,
        in board: HorizontalBoard,
        retained: [HorizontalMetalLinePrimitive]?
    ) -> [HorizontalMetalLinePrimitive]? {
        guard let segment = boardSegment(for: ref, in: board) else {
            return retained?.map { placed($0, by: placement) }
        }

        if move.isRigid(for: segment),
           let retained {
            return retained.map { placed($0, by: placement) }
        }

        return boardMetalLinePrimitives(
            for: boardResidentMovedSegment(segment, move: move, placement: placement),
            type: ref.type
        )
    }

    private func boardResidentMovedSegment(
        _ segment: HorizontalSegment,
        move: BoardResidentSegmentMove,
        placement: HorizontalPlacementTransform
    ) -> HorizontalSegment {
        var segment = segment
        if move.movesFrom {
            segment.from = placement.applying(to: segment.from)
        }
        if move.movesTo {
            segment.to = placement.applying(to: segment.to)
        }
        if move.movesCenter {
            segment.center = segment.center.map { placement.applying(to: $0) }
        }
        return segment
    }

    /// The strokes of the moving texts as a rebuilt scene would draw them
    /// after the turn (122), to write over the turned copies. A quarter turn
    /// moves a text's strokes rigidly only while it keeps reading the same
    /// way: one turned into the angles drawn the other way round
    /// (`HorizontalOutlineTextRenderer`'s `backwards`), or a pad label, which
    /// settles on its own readable angle, is drawn differently. So each text
    /// of a moving owner is drawn again, from where the turned model has it,
    /// in the style the scene gave it. A text whose strokes don't match its
    /// span one for one is left to the turned copy.
    private func boardTurnedTextRedraws(
        for refs: Set<HorizontalSelectableRef>,
        lineBatch: BoardMetalLineBatch,
        turnedBoard: HorizontalBoard
    ) -> [HorizontalMetalLineBufferPatch] {
        let spansByRef = lineBatch.metadata.textSpansByRef
        let movingSpans = refs.flatMap { spansByRef[$0] ?? [] }
        guard !movingSpans.isEmpty else {
            return []
        }
        let packageIDs = Set(refs.filter { $0.type == .boardPackage }.map { normalizedID($0.id) })
        let viaIDs = Set(refs.filter { $0.type == .via }.map { normalizedID($0.id) })
        let textIDs = Set(refs.filter { $0.type == .text }.map { normalizedID($0.id) })

        var turnedTexts = [String: HorizontalText]()
        for text in turnedBoard.packageTexts {
            if let packageID = packageID(forGeometryID: text.id), packageIDs.contains(normalizedID(packageID)) {
                turnedTexts[normalizedID(text.id)] = text
            }
        }
        // A text selected on its own: the board's, or a package editor's.
        for text in turnedBoard.texts + turnedBoard.packageTexts where textIDs.contains(normalizedID(text.id)) {
            turnedTexts[normalizedID(text.id)] = text
        }
        // A package with no geometry draws its name level beside its origin.
        for package in turnedBoard.packages where packageIDs.contains(normalizedID(package.id)) {
            let text = packageFallbackLabelText(package)
            turnedTexts[normalizedID(text.id)] = text
        }
        if !packageIDs.isEmpty {
            var padsOnly = turnedBoard
            padsOnly.packagePads = turnedBoard.packagePads.filter { pad in
                packageID(forGeometryID: pad.id).map { packageIDs.contains(normalizedID($0)) } == true
            }
            for text in packagePadLabelTextsByLayer(board: padsOnly).values.joined() {
                turnedTexts[normalizedID(text.id)] = text
            }
        }
        for via in turnedBoard.vias where viaIDs.contains(normalizedID(via.id)) {
            if let text = viaLabelText(via) {
                turnedTexts[normalizedID(text.id)] = text
            }
        }

        var patches = [HorizontalMetalLineBufferPatch]()
        for span in movingSpans {
            guard let text = turnedTexts[normalizedID(span.textID)],
                  lineBatch.lines.indices.contains(span.lineIndex) else {
                continue
            }
            let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
            let style = lineBatch.lines[span.lineIndex]
            guard segments.count == span.count,
                  style.compositeGroup == span.compositeGroup else {
                continue
            }
            patches.append(HorizontalMetalLineBufferPatch(
                compositeGroup: span.compositeGroup,
                start: span.start,
                primitives: segments.map { segment in
                    var primitive = style
                    primitive.from = segment.0
                    primitive.to = segment.1
                    return primitive
                }
            ))
        }
        return patches
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
        case .blockSymbolPort, .boardPanel, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .pad, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .padstackShape, .symbolPin:
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
            HorizontalSelectableRef(id: HorizontalBoard.viaID(ofViaHole: hole.id) ?? hole.id, type: .via)
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
                minimumWidth: isConnectionLine ? connectionLineMinimumWidth : 1.1,
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
            dashPhase: Double = 0,
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
                    dashPhase: dashPhase,
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
            let phases = dash == nil ? [] : HorizontalMetalLinePrimitive.dashPhases(along: points)
            for (index, pair) in zip(points, points.dropFirst()).enumerated() {
                appendLine(
                    from: pair.0,
                    to: pair.1,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    dash: dash,
                    dashPhase: phases.isEmpty ? 0 : phases[index],
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
                minimumWidth: type == .connectionLine ? connectionLineMinimumWidth : 1.1,
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
                for layer in via.maskLayers {
                    guard let maskDiameter = via.maskDiameter(on: layer) else { continue }
                    appendClosedPolyline(
                        circlePoints(center: via.position, radius: maskDiameter / 2),
                        color: layerMetalColor(layer),
                        minimumWidth: 0.55,
                        compositeGroup: metalCompositeGroup(for: layer)
                    )
                }
                // The rings above on hidden layers go with their composite
                // groups; the label's overlay group is always drawn.
                if Self.emitsGeneratedBoardLabelsInMetal,
                   displayOptions.viaLabels,
                   displayOptions.showsCopper(of: via),
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
        case .boardPackage, .blockSymbolPort, .boardDecal, .boardPanel, .busLabel, .busRipper, .dimension, .drawingArc, .drawingLine, .junction, .keepout, .lineNet, .netLabel, .pad, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .padstackShape, .symbolPin:
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
                for layer in via.maskLayers where displayOptions.isLayerFilled(layer) {
                    guard let maskDiameter = via.maskDiameter(on: layer) else { continue }
                    appendTriangles(
                        HorizontalMetalTessellator.circle(center: via.position, radius: maskDiameter / 2, color: layerMetalColor(layer)),
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
        case .blockSymbolPort, .boardDecal, .boardPanel, .busLabel, .busRipper, .dimension, .drawingArc, .drawingLine, .junction, .keepout, .lineNet, .netLabel, .pad, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .padstackShape, .symbolPin:
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

    private func placed(_ primitive: HorizontalMetalLinePrimitive, by placement: HorizontalPlacementTransform) -> HorizontalMetalLinePrimitive {
        var primitive = primitive
        primitive.from = placement.applying(to: primitive.from)
        primitive.to = placement.applying(to: primitive.to)
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
        placement: HorizontalPlacementTransform
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
                        delta: placement.shift,
                        angle: placement.angle
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
        placement: HorizontalPlacementTransform
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
                        delta: placement.shift,
                        angle: placement.angle
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
        placement: HorizontalPlacementTransform
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
                        delta: placement.shift,
                        angle: placement.angle
                    )
                )
            }
        }
        return patches
    }

    /// The highlighted nets and components drawn again over the dimmed board,
    /// as the board draws them: the scene build over just what is highlighted
    /// (`BoardHighlightSubset`), in its layers' composite groups and on the
    /// layers the board shows, so a highlight only dims the rest. With the
    /// highlight mode at As is nothing dims, and they are drawn lighter, as
    /// Horizon's Highlight mode lightens them.
    private func boardMetalHighlightBatch(
        renderLayers: [Int],
        visibleCompositeGroups: Set<Int>,
        sceneGroupKeys: [Int: Int]? = nil
    ) -> BoardMetalLineBatch {
        guard drawsBoardLinesInMetal, hasActiveHighlight else {
            return .empty
        }

        let netIDs = shownHighlightNetIDs
        let componentIDs = Set(highlightedComponentIDs.map { $0.lowercased() })
        let bucketsKey = metalElementBucketsCacheKey(renderLayers: renderLayers)
        let signature = metalVisibilitySignature()
        let lightens = displayOptions.highlightMode == "as_is"
        let key = BoardMetalHighlightCacheKey(
            bucketsKey: sceneGroupKeys == nil ? bucketsKey : nil,
            sceneGroupKeys: sceneGroupKeys,
            renderLayers: renderLayers,
            visibilitySignature: signature,
            visibleCompositeGroups: visibleCompositeGroups,
            highlightedNetIDs: netIDs.sorted(),
            highlightedComponentIDs: componentIDs.sorted(),
            lightens: lightens
        )

        return selectableCache.metalHighlight(key: key) {
            let subset = BoardHighlightSubset.board(boardForMetalBuckets, netIDs: netIDs, componentIDs: componentIDs)
            let scene = concatenateMetalBuckets(
                buildBoardMetalElementBuckets(renderLayers: renderLayers, partialBoard: subset),
                signature: signature,
                bucketsKey: bucketsKey,
                includesResidentMoveMetadata: false
            )
            // The board's overlay hides a layer by leaving its composite group
            // out; the top overlay draws every group it is given.
            func shown(_ group: Int) -> Bool {
                group == 0 || visibleCompositeGroups.contains(group)
            }
            // Lighter, as Horizon's highlight_lighten; the drill holes, the
            // background seen through the board, stay as they are. The local
            // function is nonisolated, so it captures the group, not Self's.
            let holesGroup = Self.holesMetalCompositeGroup
            func drawn(_ color: HorizontalMetalRGBA, group: Int) -> HorizontalMetalRGBA {
                guard lightens, group != holesGroup else {
                    return color
                }
                return HorizontalMetalRGBA(
                    red: min(color.red + 0.3, 1),
                    green: min(color.green + 0.3, 1),
                    blue: min(color.blue + 0.3, 1),
                    alpha: color.alpha
                )
            }
            let triangles = scene.triangles.compactMap { triangle -> HorizontalMetalTrianglePrimitive? in
                guard shown(triangle.compositeGroup) else {
                    return nil
                }
                var triangle = triangle
                triangle.color = drawn(triangle.color, group: triangle.compositeGroup)
                return triangle
            }
            let lines = scene.lines.compactMap { line -> HorizontalMetalLinePrimitive? in
                guard shown(line.compositeGroup) else {
                    return nil
                }
                var line = line
                line.color = drawn(line.color, group: line.compositeGroup)
                return line
            }
            let anchoredRects = scene.anchoredRects.compactMap { rect -> HorizontalMetalAnchoredRectPrimitive? in
                guard shown(rect.compositeGroup) else {
                    return nil
                }
                var rect = rect
                rect.color = drawn(rect.color, group: rect.compositeGroup)
                return rect
            }

            let batchKey = key.hashValue
            var groups = Set<Int>()
            for triangle in triangles { groups.insert(triangle.compositeGroup) }
            for line in lines { groups.insert(line.compositeGroup) }
            for rect in anchoredRects { groups.insert(rect.compositeGroup) }
            return BoardMetalLineBatch(
                triangleKey: batchKey,
                triangles: triangles,
                lineKey: batchKey,
                lines: lines,
                handleKey: 0,
                handles: [],
                anchoredRectKey: batchKey,
                anchoredRects: anchoredRects,
                // The groups it draws in, each under the batch's key, for the
                // top overlay's group keys.
                groupKeys: Dictionary(uniqueKeysWithValues: groups.map { ($0, batchKey) })
            )
        }
    }

    /// The background laid over the whole board under a highlight, which the
    /// highlight batch draws over again. It is in a composite group of its own
    /// that sorts below every other (`highlightDimMetalCompositeGroup`), since
    /// the top overlay draws its groups before its ungrouped primitives.
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
        let triangles = HorizontalMetalTessellator.triangles(for: vertices, color: color).map { triangle in
            var triangle = triangle
            triangle.compositeGroup = Self.highlightDimMetalCompositeGroup
            return triangle
        }
        let key = shownHighlightNetIDs.hashValue
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
        let patchesMove = canPatchBoardMoveInMetal
        let key = BoardMetalSelectionCacheKey(
            selectableKey: selectableCacheKey,
            movePreview: patchesMove ? nil : boardMovePreviewSignature,
            patchesMove: patchesMove,
            selectedRefs: selectedObjects,
            hoveredRef: hoveredObject,
            selectedOuterColor: selectedOuterColor,
            selectedInnerColor: selectedInnerColor,
            selectedHandleInnerColor: selectedHandleInnerColor,
            selectedGroupPreviewColor: selectedGroupPreviewColor,
            hoverOuterColor: hoverOuterColor,
            hoverInnerColor: hoverInnerColor,
            minimumLabelSize: minimumLabelSize,
            handleShape: handleShape,
            smashedConnectionLineMinimumWidth: smashedConnectionLineMinimumWidth
        )

        return selectableCache.metalSelection(key: key) {
            // Look up only the relevant selectables (selected + hovered) instead
            // of scanning every entry in boardSelectables(). With ~10k
            // selectables on a typical board, the previous O(n) scan ran on
            // every body fire and dominated wall time during interaction.
            let selectionBoard = patchesMove ? (moveState?.originalBoard ?? board) : board
            // The hit-testing scene already holds these selectables, grouped
            // by ref, for the same board. Rebuilding them here repeated a
            // whole-board build on every hover and selection change. Only a
            // preview board the scene's key can't see (a move that can't be
            // patched, a paste or pool ghost, a corner being rounded) needs
            // them fresh.
            let previewsUnkeyedBoard = (moveState != nil && !patchesMove)
                || pastePlacementState != nil
                || poolPlacementState != nil
                || roundOffVertexState != nil || addVertexState != nil || tuneState != nil
            let selectablesForRef: (HorizontalSelectableRef) -> [HorizontalSelectable]?
            if previewsUnkeyedBoard {
                selectablesForRef = boardSelectableLookup(in: selectionBoard)
            } else {
                let byRef = boardSelectablesByRef()
                selectablesForRef = { byRef[$0] }
            }
            let style = HorizontalCanvasSelectionOverlayStyle(
                selectedOuterColor: selectedOuterColor,
                selectedInnerColor: selectedInnerColor,
                selectedHandleInnerColor: selectedHandleInnerColor,
                hoverOuterColor: hoverOuterColor,
                hoverInnerColor: hoverInnerColor,
                handleShape: handleShape
            )
            // The tracks a patched move reshapes, an end of theirs staying
            // put, are outlined apart, last, so the move can redraw their
            // boxes from where it takes their ends while it shifts the rest.
            var movingTracks = BoardMovingTrackOutlines()
            if patchesMove, let moveState {
                movingTracks = BoardMovingTrackOutlines(
                    selectedRefs: selectedObjects.filter { selectablesForRef($0) != nil },
                    plan: moveState.residentMovePlan,
                    board: selectionBoard
                )
            }
            let movingTrackRefs = movingTracks.refs
            let shiftedRefs = movingTrackRefs.isEmpty
                ? selectedObjects
                : selectedObjects.filter { !movingTrackRefs.contains($0) }
            let arcTrackWidths = BoardTrackSelectionOutline.arcWidths(
                in: selectionBoard,
                refs: shiftedRefs + [hoveredObject].compactMap { $0 }
            )
            let overlay = HorizontalCanvasModeSupport.metalSelectionOverlay(
                selectablesForRef: { selectablesForRef($0) ?? [] },
                selectedRefs: shiftedRefs,
                hoveredRef: hoveredObject.flatMap { movingTrackRefs.contains($0) ? nil : $0 },
                style: style,
                outlineForSelectable: { boardSelectionOutline(for: $0, arcTrackWidths: arcTrackWidths) }
            )
            let movingTrackOverlay = movingTracks.isEmpty
                ? HorizontalCanvasMetalSelectionOverlay()
                : boardMovingTrackOutlineOverlay(movingTracks, at: .identity, style: style)
            let polygonGroupPreviewLines = boardMetalPolygonSelectionPreviewLines(
                in: selectionBoard,
                selectedRefs: selectedObjects,
                hoveredRef: hoveredObject,
                color: selectedGroupPreviewColor
            )
            let vertexMarks = boardMetalSelectionVertexMarks(
                in: selectionBoard,
                selectablesForRef: selectablesForRef,
                selectedRefs: selectedObjects,
                hoveredRef: hoveredObject,
                outerColor: selectedGroupPreviewColor,
                hoverColor: hoverOuterColor,
                innerColor: selectedHandleInnerColor,
                shape: handleShape
            )
            // A smashed text's line to its package, a hairline as Horizon's
            // unless Settings makes it wider (never under the board's minimum
            // line width). During a move these are carried with the rest of
            // the selection's lines, which is right: a move that can be
            // patched carries a smashed text only with its package, and one
            // that moves the text alone rebuilds this batch.
            let textOwnerLines = boardTextOwnerLines(in: selectionBoard).map { line in
                HorizontalMetalLinePrimitive(
                    from: line.text,
                    to: line.package,
                    color: selectedOuterColor,
                    minimumWidth: key.smashedConnectionLineMinimumWidth
                )
            }

            let batchKey = key.hashValue
            return BoardMetalLineBatch(
                triangleKey: batchKey,
                triangles: [],
                lineKey: batchKey,
                lines: polygonGroupPreviewLines + vertexMarks.lines + textOwnerLines + overlay.lines
                    + movingTrackOverlay.lines,
                handleKey: batchKey,
                handles: vertexMarks.handles + overlay.handles + movingTrackOverlay.handles,
                anchoredRectKey: 0,
                anchoredRects: [],
                movingTrackOutlines: movingTracks.isEmpty ? nil : BoardMetalMovingTrackOutlines(
                    outlines: movingTracks,
                    style: style,
                    lineCount: movingTrackOverlay.lines.count,
                    handleCount: movingTrackOverlay.handles.count
                )
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

        // The selection turns with what it outlines (122): a quarter turn of a
        // box is the box of the turned part.
        let placement = moveState.livePlacement
        let movingTracks = baseSelectionBatch.movingTrackOutlines
        let shiftedLineCount = baseSelectionBatch.lines.count - (movingTracks?.lineCount ?? 0)
        let shiftedHandleCount = baseSelectionBatch.handles.count - (movingTracks?.handleCount ?? 0)
        var patches = HorizontalMetalBufferPatches()
        if shiftedLineCount > 0 {
            patches.lineTranslationPatches.append(
                HorizontalMetalLineTranslationPatch(
                    compositeGroup: 0,
                    start: lineStart,
                    count: shiftedLineCount,
                    delta: placement.shift,
                    angle: placement.angle
                )
            )
        }
        if shiftedHandleCount > 0 {
            patches.handleTranslationPatches.append(
                HorizontalMetalHandleTranslationPatch(
                    start: handleStart,
                    count: shiftedHandleCount,
                    delta: placement.shift,
                    angle: placement.angle
                )
            )
        }
        // The tracks the move reshapes are outlined where it has taken their
        // ends, as the scene draws them, not shifted whole off the copper.
        if let movingTracks {
            let overlay = boardMovingTrackOutlineOverlay(movingTracks.outlines, at: placement, style: movingTracks.style)
            if movingTracks.lineCount > 0 {
                patches.linePatches.append(
                    HorizontalMetalLineBufferPatch(
                        compositeGroup: 0,
                        start: lineStart + shiftedLineCount,
                        primitives: Self.fitted(overlay.lines, to: Array(baseSelectionBatch.lines.suffix(movingTracks.lineCount)))
                    )
                )
            }
            if movingTracks.handleCount > 0 {
                patches.handlePatches.append(
                    HorizontalMetalHandleBufferPatch(
                        start: handleStart + shiftedHandleCount,
                        primitives: Self.fitted(overlay.handles, to: Array(baseSelectionBatch.handles.suffix(movingTracks.handleCount)))
                    )
                )
            }
        }
        return patches
    }

    /// The selection outlines of the tracks a move reshapes
    /// (`BoardMovingTrackOutlines`), where `placement` has taken their moving
    /// ends; `.identity` outlines them where they were.
    private func boardMovingTrackOutlineOverlay(
        _ outlines: BoardMovingTrackOutlines,
        at placement: HorizontalPlacementTransform,
        style: HorizontalCanvasSelectionOverlayStyle
    ) -> HorizontalCanvasMetalSelectionOverlay {
        let selectables = outlines.selectables(at: placement)
        let arcWidths = outlines.arcWidths
        return HorizontalCanvasModeSupport.metalSelectionOverlay(
            selectablesForRef: { selectables[$0] ?? [] },
            selectedRefs: outlines.tracks.map(\.ref),
            hoveredRef: nil,
            style: style,
            outlineForSelectable: { boardSelectionOutline(for: $0, arcTrackWidths: arcWidths) }
        )
    }

    /// `primitives` laid over `base`, the run they redraw, which they must
    /// fill exactly: a short redraw keeps the rest of `base`, a long one is cut.
    /// A track's outline takes as many primitives wherever its ends are, so
    /// this only guards the buffer.
    private static func fitted<Primitive>(_ primitives: [Primitive], to base: [Primitive]) -> [Primitive] {
        guard primitives.count != base.count else {
            return primitives
        }
        return Array(primitives.prefix(base.count)) + base.dropFirst(min(primitives.count, base.count))
    }

    /// The selected smashed texts' lines to their packages, and a selected
    /// package's to its smashed texts that show (Horizon's text owner
    /// annotation).
    private func boardTextOwnerLines(in board: HorizontalBoard) -> [BoardTextOwnerLines.Line] {
        BoardTextOwnerLines.lines(in: board, selectedRefs: selectedObjects) { text in
            displayOptions.text && displayOptions.isLayerVisible(text.layer)
        }
    }

    private func boardSelectionOutline(
        for selectable: HorizontalSelectable,
        arcTrackWidths: [String: Double]
    ) -> HorizontalCanvasSelectionOutline? {
        switch selectable.ref.type {
        case .track:
            // Horizon's box round the track, not a line along its middle.
            return BoardTrackSelectionOutline.outline(for: selectable, arcWidths: arcTrackWidths)
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
        case .dimension where selectable.isPoint:
            // A dimension's point is a handle, as a polygon's vertex is.
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

    /// The marks on the selection's parts that select on their own
    /// (`BoardSelectionVertices`), apart from those selected themselves,
    /// which the selection overlay draws: a handle on each point, and a
    /// dimension's label outlined in dashes, as Horizon previews the rest of
    /// a selected dimension's group. The one under the cursor, which a click
    /// picks, is lit as hovered.
    private func boardMetalSelectionVertexMarks(
        in board: HorizontalBoard,
        selectablesForRef: (HorizontalSelectableRef) -> [HorizontalSelectable]?,
        selectedRefs: [HorizontalSelectableRef],
        hoveredRef: HorizontalSelectableRef?,
        outerColor: HorizontalMetalRGBA,
        hoverColor: HorizontalMetalRGBA,
        innerColor: HorizontalMetalRGBA,
        shape: HorizontalSelectionHandleShape
    ) -> (handles: [HorizontalMetalHandlePrimitive], lines: [HorizontalMetalLinePrimitive]) {
        let selected = Set(selectedRefs)
        let outerRadius = max(Float(shape.outerRadius) * 0.56, 5)
        let innerRadius = max(Float(shape.innerRadius) * 0.56, 2.5)
        var handles = [HorizontalMetalHandlePrimitive]()
        var lines = [HorizontalMetalLinePrimitive]()
        for ref in BoardSelectionVertices.refs(of: selectedRefs, in: board) where !selected.contains(ref) {
            let outerColor = ref == hoveredRef ? hoverColor : outerColor
            for selectable in selectablesForRef(ref) ?? [] {
                if selectable.isPoint {
                    handles.append(
                        HorizontalMetalHandlePrimitive(
                            center: selectable.center,
                            outerColor: outerColor,
                            innerColor: innerColor,
                            shape: shape,
                            outerRadius: outerRadius,
                            innerRadius: innerRadius
                        )
                    )
                    continue
                }
                let corners = selectable.corners
                let points = corners + corners.prefix(1)
                let phases = HorizontalMetalLinePrimitive.dashPhases(along: points)
                lines.append(contentsOf: zip(points, points.dropFirst()).enumerated().map { index, pair in
                    HorizontalMetalLinePrimitive(
                        from: pair.0,
                        to: pair.1,
                        color: outerColor,
                        minimumWidth: 1.8,
                        dashLength: 5,
                        dashGap: 4,
                        dashPhase: phases[index],
                        normalOffset: 0
                    )
                })
            }
        }
        return (handles, lines)
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
        let polygons = (board.polygons + board.outlinePolygons).filter { polygonIDs.contains(normalizedID($0.id)) }
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
            let points = selectable.handlePoints
            let phases = HorizontalMetalLinePrimitive.dashPhases(along: points)
            lines.append(contentsOf: zip(points, points.dropFirst()).enumerated().map { index, pair in
                HorizontalMetalLinePrimitive(
                    from: pair.0,
                    to: pair.1,
                    color: color,
                    minimumWidth: 1.8,
                    dashLength: 5,
                    dashGap: 4,
                    dashPhase: phases[index],
                    normalOffset: 0
                )
            })
        }
        return lines
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

        if let measurement = measureState?.measurement {
            appendSegment(from: measurement.from, to: measurement.to, color: HorizontalMetalRGBA(theme.textOverlay.opacity(0.9)))
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
        // width on the active layer, following the cursor between clicks, with
        // the via `v` armed on its end. Drawn solid (not dashed) so it reads as
        // a ghost of the finished track.
        if let track = drawTrackState {
            let color = HorizontalMetalRGBA(layerColor(for: track.layer).opacity(0.5))
            let polylines = trackPreviewPolylines(track)
            for routePoints in polylines {
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
            // The armed via over the route, as a placed via is drawn: its
            // diameter in green, then its hole. The overlay draws every
            // triangle before every line, so each is a line, one micron long,
            // which the line shader draws as a disc of its width (or the
            // disc's rim, outlineOnly), and none of the track shows through.
            if let armed = armedViaPreview(track, polylines: polylines) {
                func disc(_ diameter: Double, _ color: Color, outlineOnly: Bool = false) -> HorizontalMetalLinePrimitive {
                    HorizontalMetalLinePrimitive(
                        from: armed.head,
                        to: armed.head + HorizontalPoint(x: 1_000, y: 0),
                        color: HorizontalMetalRGBA(color),
                        width: diameter,
                        minimumWidth: 0,
                        outlineOnly: outlineOnly
                    )
                }
                lines.append(disc(armed.via.diameter, Self.viaDiameterFill))
                lines.append(disc(armed.via.holeDiameter, theme.background.opacity(0.95)))
                lines.append(disc(armed.via.holeDiameter, theme.hole.opacity(0.7), outlineOnly: true))
            }
        }

        // A move's live airwires, styled as the resident ones they stand in for.
        if displayOptions.connectionLines,
           canPatchBoardMoveInMetal,
           let state = moveState,
           let airwireRequest = state.airwireRequest,
           let airwires = selectableCache.movingAirwireSegments(for: airwireRequest, placement: state.livePlacement) {
            let color = HorizontalMetalRGBA(theme.airwire.opacity(0.72))
            for airwire in airwires where displayOptions.showsAirwires(ofNet: airwire.netID) {
                lines.append(
                    HorizontalMetalLinePrimitive(
                        from: airwire.from,
                        to: airwire.to,
                        color: color,
                        minimumWidth: connectionLineMinimumWidth,
                        dashLength: 6,
                        dashGap: 4
                    )
                )
            }
        }

        guard !lines.isEmpty else {
            return .empty
        }
        let key = lines.hashValue
        return BoardMetalLineBatch(
            triangleKey: 0,
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
        boardSelectableCategories(in: board).flatMap(\.all)
    }

    /// The board's selectables, category by category in hit-testing order,
    /// each with its visible ones and those by ref. A category is built
    /// again only when the content it comes from changed, and filtered and
    /// grouped again only when that or what decides visibility did, so an
    /// edit, or a move's preview, rebuilds the categories it touched.
    private func boardSelectableCategories(in board: HorizontalBoard) -> [BoardSelectableCategory] {
        let memo = selectableCache.contentMemo
        let visibility = selectableVisibility(in: board)
        func category<Input: Equatable>(_ name: String, _ input: Input, _ build: () -> [HorizontalSelectable]) -> BoardSelectableCategory {
            let all = memo.value("selectables: \(name)", input: input, build: build)
            let visible = memo.value("visible selectables: \(name)", input: BoardContentPair(input, visibility)) {
                filterVisibleSelectables(all, visibility: visibility)
            }
            let byRef = memo.value("selectables by ref: \(name)", input: BoardContentPair(input, visibility)) {
                Dictionary(grouping: visible, by: \.ref)
            }
            return BoardSelectableCategory(all: all, visible: visible, byRef: byRef) {
                memo.value("selectable index: \(name)", input: BoardContentPair(input, visibility)) {
                    HorizontalSelectableSpatialIndex(visible)
                }
            }
        }
        func uncached(_ all: [HorizontalSelectable]) -> BoardSelectableCategory {
            let visible = filterVisibleSelectables(all, visibility: visibility)
            return BoardSelectableCategory(all: all, visible: visible, byRef: Dictionary(grouping: visible, by: \.ref)) {
                HorizontalSelectableSpatialIndex(visible)
            }
        }

        var categories = [BoardSelectableCategory]()
        categories.append(uncached(boardPanelSelectables(in: board)))
        categories.append(category("polygons", board.polygons) {
            polygonEdgeSelectables(board.polygons, type: .polygonEdge)
        })
        // A plane's outline and a keepout's are picked, moved and reshaped by
        // their parts, as any polygon is; a package's keepouts and drills are
        // parts of it, which a click picks and a move moves only as the whole
        // package, as in Horizon.
        let outlinePolygons = board.outlinePolygons
        categories.append(category("outline polygons", outlinePolygons) {
            polygonEdgeSelectables(outlinePolygons, type: .polygonEdge)
        })
        categories.append(category("decals", board.decals) {
            board.decals.compactMap { decal in
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
            }
        })
        // Horizon's three: the two points and the label, not a box round it all.
        categories.append(category("dimensions", board.dimensions) {
            board.dimensions.flatMap(BoardDimensionParts.selectables)
        })
        categories.append(category("lines", board.lines) { segmentSelectables(board.lines, type: .boardLine) })
        categories.append(category("arcs", board.arcs) { arcSelectables(board.arcs, type: .boardArc) })
        categories.append(category("tracks", board.tracks) { segmentSelectables(board.tracks, type: .track) })
        categories.append(category("net ties", board.netTies) { segmentSelectables(board.netTies, type: .boardNetTie) })
        categories.append(category("connection lines", board.connectionLines) {
            segmentSelectables(board.connectionLines, type: .connectionLine)
        })
        categories.append(category("junctions", board.junctions) {
            board.junctions.map { id, point in
                HorizontalSelectable.point(ref: HorizontalSelectableRef(id: id, type: .junction), at: point)
            }
        })
        categories.append(category("vias", board.vias) {
            board.vias.map { via in
                HorizontalSelectable.bounds(
                    ref: HorizontalSelectableRef(id: via.id, type: .via, layer: via.layer),
                    points: via.boundsPoints,
                    fallbackCenter: via.position,
                    fallbackSize: via.size
                )
            }
        })
        // Pad holes belong to their pads, on a board and in a package editor.
        categories.append(category("holes", board.holes) {
            board.holes.map { hole in
                HorizontalSelectable.bounds(
                    ref: HorizontalSelectableRef(id: hole.id, type: .boardHole),
                    points: hole.boundsPoints,
                    fallbackCenter: hole.position,
                    fallbackSize: hole.diameter
                )
            }
        })
        categories.append(category(
            "packages",
            BoardContentTriple(board.packages, board.packagePads, BoardContentPair(board.packagePolygons, board.packagePadPositions))
        ) {
            boardPackageSelectables(in: board)
        })
        if modeProfile.mode == .package {
            categories.append(uncached(poolPadSelectables(in: board)))
        }
        if modeProfile.mode == .padstack {
            categories.append(uncached(padstackShapeSelectables(in: board)))
        }
        // Standalone board text is independently selectable. Package-owned text
        // (refdes / value / assembly annotations) normally is NOT — it belongs to
        // its package — EXCEPT a SMASHED package's extracted `fromSmash` copies,
        // which are the point of smashing: individually editable board text.
        categories.append(category("texts", board.texts) { textSelectables(board.texts) })
        categories.append(category("smashed texts", board.packageTexts) {
            textSelectables(board.packageTexts.filter { $0.fromSmash })
        })
        return categories
    }

    private func boardSnapTargets() -> [HorizontalPoint] {
        if let moveSnapTargets = moveState?.snapTargets {
            return moveSnapTargets
        }
        // A route snaps only to copper on the layer it is drawn on, from its
        // first click: a track begun on the bottom doesn't jump to a pad or
        // track on the top.
        if let layer = drawTrackState?.layer {
            let key = BoardTrackSnapTargetsKey(selectables: selectableCacheKey, layer: layer)
            return selectableCache.trackSnapTargets(key: key) {
                BoardTrackRouting.snapTargets(on: layer, in: selectableSceneBoard)
            }
        }
        return selectableCache.snapTargets(key: selectableCacheKey) {
            boardSelectableScene().snapTargets(pointKey: pointKey)
        }
    }

    /// The selection's own snap points, by key: what moves with it. A
    /// polygon's part brings the points it moves; the rest are looked up by
    /// ref, so a large selection costs no search per object.
    private func boardSnapTargetKeys(for refs: [HorizontalSelectableRef]) -> Set<String> {
        let selectablesByRef = boardSelectablesByRef()
        var keys = Set<String>()
        for ref in uniqueRefs(refs) {
            for selectable in selectablesByRef[ref] ?? [] {
                keys.formUnion(selectable.anchorSnapPoints.map(pointKey))
            }
            switch ref.type {
            case .polygonEdge, .polygonVertex, .polygonArcCenter:
                keys.formUnion(selectionAnchorPoints(for: ref).map(pointKey))
            default:
                break
            }
        }
        return keys
    }

    private func snapBoardPointToGrid(_ point: HorizontalPoint) -> HorizontalPoint {
        HorizontalCanvasInputCore.snapToGrid(point, grid: board.grid, divisor: 1)
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
        if displayOptions.origin && !HorizontalMetalBackdropView.isSupported {
            HorizontalGridRenderer.drawOriginMark(
                context: context,
                transform: transform,
                color: theme.grid,
                lineWidth: appearanceSettings.gridMarkLineWidth
            )
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
        selectableCache.visibleRenderLayers(key: renderLayersCacheKey) {
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
                // A via's solder-mask openings live on the mask layers. On a
                // board with no pads those layers carry nothing else, and a
                // layer missing here is masked out of the draw entirely — so
                // the openings vanished even with the mask layer shown.
                for layer in via.maskLayers where displayOptions.isLayerVisible(layer) {
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
            for layer in via.maskLayers {
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
        if displayOptions.boardBody || displayOptions.showsOutlineLayer {
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
        // And the via diameters, which follow their copper's visibility when
        // the buckets are built.
        groups.insert(Self.viaDiameterMetalCompositeGroup)
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
        for via in board.vias {
            let drawsCopper = visibleViaLayers(for: via).contains(layer)
            let drawsMask = via.maskDiameter(on: layer) != nil && displayOptions.isLayerVisible(layer)
            if drawsCopper || drawsMask {
                drawViaRing(via, layer: layer, context: context, transform: transform)
            }
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
        let diameter = via.maskDiameter(on: layer) ?? via.size
        let outerRadius = max(transform.length(diameter) / 2, 1.8)
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
    /// `BoardPadLabelLayout` frame + fit machinery and stroke weight pads use,
    /// centered on the via.
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
            width: size * BoardPadLabelLayout.strokeWidthFraction,
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
        drawSegmentLabel(segmentNetLabelText(segment, text: label, idSuffix: idSuffix, size: size), color: color, context: context, transform: transform)
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

        guard let size = Self.fittedNetLineTextSize(text, segment: segment),
              transform.length(size) >= HorizontalOutlineTextRenderer.minimumDrawableScreenHeight else {
            return nil
        }
        return size
    }

    /// The text size of `text` as a net label along `segment`, or nil when the
    /// segment is too short to carry it.
    static func fittedNetLineTextSize(
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
              let size = Self.fittedNetLineTextSize(label, segment: segment) else {
            return nil
        }
        // A track that ends on a pad is already labeled by that pad's net name,
        // so skip the redundant track label.
        if segmentTouchesPad(segment, padCenterKeys: padCenterKeys) {
            return nil
        }
        return segmentNetLabelText(segment, text: label, idSuffix: idSuffix, size: size)
    }

    /// A net label along `segment`, stroked as heavily for its size as a pad label.
    private func segmentNetLabelText(
        _ segment: HorizontalSegment,
        text: String,
        idSuffix: String,
        size: Double
    ) -> HorizontalText {
        var label = segmentLabelText(segment, text: text, idSuffix: idSuffix, size: size)
        label.width = size * BoardPadLabelLayout.strokeWidthFraction
        return label
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
            // a hairline at any zoom. `drawPadLabel` still passes
            // `minimumLineWidth: 0.7` so labels stay visible when zoomed out.
            width: size * BoardPadLabelLayout.strokeWidthFraction,
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
        guard !highlightedNetIDs.isEmpty || routeHighlightNetID != nil else {
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
            for airwire in board.airwires where matchesHighlightedNet(airwire.netID) && displayOptions.showsAirwires(ofNet: airwire.netID) {
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
        let id = normalizedID(netID)
        return highlightedNetIDs.contains(id) || id == routeHighlightNetID
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
        if let measurement = measureState?.measurement {
            drawPreviewSegment(
                HorizontalSegment(id: "measure-preview", from: measurement.from, to: measurement.to, width: 0, layer: nil),
                context: context, transform: transform
            )
        }
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
        for line in boardTextOwnerLines(in: board) {
            var path = Path()
            path.move(to: transform.point(line.text))
            path.addLine(to: transform.point(line.package))
            context.stroke(
                path,
                with: .color(theme.selectableOuter.opacity(0.95)),
                lineWidth: max(CGFloat(smashedConnectionLineMinimumWidth), transform.minimumLineWidth)
            )
        }
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
        // The selection's parts that select on their own (`BoardSelectionVertices`).
        let selected = Set(selectedObjects)
        let selectablesByRef = boardSelectablesByRef()
        for ref in BoardSelectionVertices.refs(of: selectedObjects, in: board) where !selected.contains(ref) {
            for selectable in selectablesByRef[ref] ?? [] where selectable.isPoint {
                drawSelectionHandle(
                    at: selectable.center,
                    color: theme.selectableAlways,
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
        let padCentersByPackage = boardPackagePadCenters(in: board)
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
            var selectable = HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: package.id, type: .boardPackage),
                points: packagePoints,
                fallbackCenter: package.position,
                fallbackSize: 2_000_000
            )
            // The cursor snaps to the origin and the pads, as Horizon's
            // package and pad targets; not to the corners of its drawing.
            selectable.snapAnchors = [package.position] + (padCentersByPackage[normalizedID(package.id)] ?? [])
            return selectable
        }
    }

    /// Each package's pads' centres, from their copper.
    private func boardPackagePadCenters(in board: HorizontalBoard) -> [String: [HorizontalPoint]] {
        var centersByPackage = [String: [HorizontalPoint]]()
        var seen = Set<String>()
        for pad in board.packagePads where pad.layer.map(HorizontalBoardLayers.isCopper) ?? false {
            guard let packageID = packageID(forGeometryID: pad.id), !pad.vertices.isEmpty else {
                continue
            }
            let center = HorizontalRect(points: pad.vertices).center
            if seen.insert("\(packageID)@\(pointKey(center))").inserted {
                centersByPackage[packageID, default: []].append(center)
            }
        }
        return centersByPackage
    }

    private func boardPackageGeometryPoints() -> [String: [HorizontalPoint]] {
        boardPackageGeometryPoints(in: board)
    }

    /// Each package's pad vertices and bounding-box polygon points, by
    /// package id. Kept while the pads and package polygons are unchanged:
    /// the scene build, the visibility filter and the package selectables all
    /// ask, and each pass renders every package polygon's vertices.
    private func boardPackageGeometryPoints(in board: HorizontalBoard) -> [String: [HorizontalPoint]] {
        selectableCache.contentMemo.value(
            "package geometry points",
            input: BoardContentPair(board.packagePads, board.packagePolygons)
        ) {
            uncachedBoardPackageGeometryPoints(in: board)
        }
    }

    private func uncachedBoardPackageGeometryPoints(in board: HorizontalBoard) -> [String: [HorizontalPoint]] {
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
        BoardMovePlanner.packageID(forGeometryID: geometryID)
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
        selectableCache.contentMemo.value(
            "package ids with geometry",
            input: BoardContentTriple(board.packages.map(\.id), board.packagePads, board.packagePolygons)
        ) {
            let geometryPackageIDs = Set(boardPackageGeometryPoints(in: board).keys)
            return Set(board.packages.compactMap { package in
                geometryPackageIDs.contains(normalizedID(package.id)) ? package.id : nil
            })
        }
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
        case .padstackShape: "Padstack shape"
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
        case .padstackShape: "Padstack shapes"
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
    /// What its Insert Metadata menu offers.
    var textVariables: [HorizontalTextVariableItem] = []
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
            .insertMetadataMenu(textVariables)
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

/// Where "Show in Pool Manager" looks for a placed package's or symbol's pool item.
enum HorizontalPoolRevealTarget {
    /// The registered pool the item came from.
    case registeredPool
    /// The project's own pool (its cached copy).
    case projectPool
}

// MARK: - Disconnect and pool reveal

extension BoardCanvasView {
    /// The pool package uuid behind a placed package.
    private func packagePoolID(for ref: HorizontalSelectableRef) -> String? {
        guard ref.type == .boardPackage,
              let placement = board.packages.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return nil
        }
        return placement.packageID
    }

    private func selectedPackagePoolID() -> String? {
        selectedObjects.lazy.compactMap { packagePoolID(for: $0) }.first
    }

    private func revealSelectedPackage(_ target: HorizontalPoolRevealTarget) {
        guard let packageID = selectedPackagePoolID() else {
            return
        }
        onRevealPoolPackage(packageID, target)
    }

    /// The pad centres of a placed package, keyed by position.
    private func padCenterKeys(ofPackage packageRefID: String) -> Set<String> {
        let prefix = normalizedID(packageRefID) + "/"
        var keys = Set<String>()
        for (path, center) in board.packagePadPositions where normalizedID(path).hasPrefix(prefix) {
            keys.insert(pointKey(center))
        }
        return keys
    }

    private var allPadCenterKeys: Set<String> {
        Set(board.packagePadPositions.values.map(pointKey))
    }

    /// `ToolDisconnect::can_begin`: a package with tracks on its pads, or a
    /// track ending on a pad.
    private func canDisconnect(_ ref: HorizontalSelectableRef) -> Bool {
        guard modeProfile.mode == .board else {
            return false
        }
        switch ref.type {
        case .boardPackage:
            let centers = padCenterKeys(ofPackage: ref.id)
            guard !centers.isEmpty else {
                return false
            }
            return board.tracks.contains { centers.contains(pointKey($0.from)) || centers.contains(pointKey($0.to)) }
        case .track:
            guard let track = board.tracks.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return false
            }
            let centers = allPadCenterKeys
            return centers.contains(pointKey(track.from)) || centers.contains(pointKey(track.to))
        default:
            return false
        }
    }

    /// `Board::disconnect_package`: every track end on one of the package's
    /// pads is moved onto a junction at that pad's centre. The copper stays
    /// where it is; the pad reference is gone, on disk and — because a
    /// junction on a pad centre no longer counts as attached — in the
    /// connectivity pass, so the tracks go net-less until reconnected.
    private func disconnectSelection() {
        guard !isReadOnly, modeProfile.mode == .board else {
            return
        }
        var detachKeys = Set<String>()
        for ref in selectedObjects {
            switch ref.type {
            case .boardPackage:
                let centers = padCenterKeys(ofPackage: ref.id)
                for track in board.tracks {
                    for end in [track.from, track.to] where centers.contains(pointKey(end)) {
                        detachKeys.insert(pointKey(end))
                    }
                }
            case .track:
                guard let track = board.tracks.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                    continue
                }
                let centers = allPadCenterKeys
                for end in [track.from, track.to] where centers.contains(pointKey(end)) {
                    detachKeys.insert(pointKey(end))
                }
            default:
                continue
            }
        }
        guard !detachKeys.isEmpty else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        var changed = false
        for (_, center) in board.packagePadPositions where detachKeys.contains(pointKey(center)) {
            let existing = draft.junctions.values.contains { pointKey($0) == pointKey(center) }
            if !existing {
                _ = ensureBoardJunction(at: center, board: &draft)
                changed = true
            }
        }
        guard changed else {
            return
        }
        registerUndoSnapshot(previous, actionName: "Disconnect")
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
        publishCanvasCommandActions()
    }
}

// MARK: - Pool item modes (package / padstack / decal)

extension BoardCanvasView {
    // MARK: Lookup

    private func poolPad(for ref: HorizontalSelectableRef) -> HorizontalPad? {
        poolPad(for: ref, in: board)
    }

    private func poolPad(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalPad? {
        let normalized = normalizedID(ref.id)
        guard let marker = normalized.range(of: "/pad/") else {
            return nil
        }
        let padID = String(normalized[marker.upperBound...])
        return board.pads.first { normalizedID($0.id) == padID }
    }

    private func poolPadIndex(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> Int? {
        let normalized = normalizedID(ref.id)
        guard let marker = normalized.range(of: "/pad/") else {
            return nil
        }
        let padID = String(normalized[marker.upperBound...])
        return board.pads.firstIndex { normalizedID($0.id) == padID }
    }

    private func padstackShape(for ref: HorizontalSelectableRef) -> HorizontalPadstackShape? {
        padstackShape(for: ref, in: board)
    }

    private func padstackShape(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalPadstackShape? {
        board.padstackShapes.first { normalizedID($0.id) == normalizedID(ref.id) }
    }

    private func padstackShapeIndex(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> Int? {
        board.padstackShapes.firstIndex { normalizedID($0.id) == normalizedID(ref.id) }
    }

    private func bakedPadPrefix(for pad: HorizontalPad, in board: HorizontalBoard) -> String {
        board.padRefID(for: pad) + "/"
    }

    private func bakedShapePrefix(for shape: HorizontalPadstackShape, in board: HorizontalBoard) -> String {
        "pad/\(board.poolItemID ?? "padstack")/shape/\(shape.id)/".lowercased()
    }

    // MARK: Selectables

    private func poolPadSelectables(in board: HorizontalBoard) -> [HorizontalSelectable] {
        board.pads.map { pad in
            let prefix = bakedPadPrefix(for: pad, in: board)
            let polygons = board.packagePads.filter { normalizedID($0.id).hasPrefix(prefix) }
            let copper = polygons.filter { $0.layer.map(HorizontalBoardLayers.isCopper) ?? false }
            let points = (copper.isEmpty ? polygons : copper).flatMap(\.vertices)
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: board.padRefID(for: pad), type: .pad),
                points: points,
                fallbackCenter: pad.placement.shift,
                fallbackSize: 1_000_000
            )
        }
    }

    private func padstackShapeSelectables(in board: HorizontalBoard) -> [HorizontalSelectable] {
        board.padstackShapes.map { shape in
            let prefix = bakedShapePrefix(for: shape, in: board)
            let points = board.packagePads.filter { normalizedID($0.id).hasPrefix(prefix) }.flatMap(\.vertices)
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: shape.id, type: .padstackShape, layer: shape.layer),
                points: points,
                fallbackCenter: shape.placement.shift,
                fallbackSize: 500_000
            )
        }
    }

    // MARK: HUD

    private func poolPadHUDItem(for ref: HorizontalSelectableRef) -> HorizontalSelectionHUDItem {
        guard let pad = poolPad(for: ref) else {
            return genericHUDItem(for: ref)
        }
        let padstackName = poolContext?.padstackDisplayName(id: pad.padstackID) ?? shortID(pad.padstackID)
        var details = [
            detailRow("Padstack", padstackName),
            detailRow("Position", "\(lengthString(pad.placement.shift.x)), \(lengthString(pad.placement.shift.y))"),
            detailRow("Angle", "\(pad.placement.angle * 360 / 65_536)°"),
        ].compactMap { $0 }
        for (key, value) in pad.parameterSet.sorted(by: { $0.key < $1.key }) {
            if let row = detailRow(Self.parameterDisplayName(key), lengthString(Double(value))) {
                details.append(row)
            }
        }
        return HorizontalSelectionHUDItem(title: "Pad \(pad.name)", subtitle: padstackName, details: details)
    }

    private func padstackShapeHUDItem(for ref: HorizontalSelectableRef) -> HorizontalSelectionHUDItem {
        guard let shape = padstackShape(for: ref) else {
            return genericHUDItem(for: ref)
        }
        let size = shape.form == .circle
            ? diameterString(shape.params.first ?? 0)
            : "\(lengthString(shape.params.first ?? 0)) × \(lengthString(shape.params.count > 1 ? shape.params[1] : 0))"
        return HorizontalSelectionHUDItem(
            title: "\(shape.form.displayName) shape",
            subtitle: layerName(for: shape.layer) ?? "",
            details: [
                detailRow("Size", size),
                detailRow("Parameter class", shape.parameterClass),
            ].compactMap { $0 }
        )
    }

    // MARK: Inspector

    private func poolPadProperties(for ref: HorizontalSelectableRef) -> [HorizontalSelectionProperty] {
        guard let pad = poolPad(for: ref) else {
            return []
        }
        var properties = [editableTextProperty("name", "Name", pad.name)]
        let currentID = normalizedID(pad.padstackID)
        var options = (poolContext?.padstackChoices() ?? []).map {
            HorizontalSelectionPropertyOption(id: $0.id, title: $0.isPackageLocal ? "\($0.name) (package)" : $0.name)
        }
        if !options.contains(where: { $0.id == currentID }) {
            options.append(HorizontalSelectionPropertyOption(
                id: currentID,
                title: poolContext?.padstackDisplayName(id: pad.padstackID) ?? shortID(pad.padstackID)
            ))
        }
        properties.append(editableChoiceProperty("padstack", "Padstack", value: currentID, options: options))
        properties.append(contentsOf: [
            editableLengthProperty("positionX", "Position X", pad.placement.shift.x),
            editableLengthProperty("positionY", "Position Y", pad.placement.shift.y),
            editableAngleProperty("angle", "Angle", pad.placement.angle),
            editableBoolProperty("mirror", "Mirror", pad.placement.mirrored),
        ])
        properties.append(contentsOf: poolParameterProperties(
            parameterSet: pad.parameterSet,
            parametersFixed: pad.parametersFixed,
            padstackJSON: poolContext?.padstackJSON(id: pad.padstackID)
        ))
        return properties
    }

    /// Parameter rows for a pool object, resolved through the editor context
    /// (which sees package-local padstacks) rather than the pool catalog.
    private func poolParameterProperties(
        parameterSet: [String: Int],
        parametersFixed: [String],
        padstackJSON: JSONDictionary?
    ) -> [HorizontalSelectionProperty] {
        var keys = Set(parameterSet.keys)
        var required = Set<String>()
        var defaults = [String: Int]()
        if let padstackJSON {
            for case let key as String in padstackJSON["parameters_required"] as? [Any] ?? [] {
                required.insert(key)
            }
            keys.formUnion(required)
            for (key, value) in padstackJSON.dictionary("parameter_set") ?? [:] {
                defaults[key] = Int(JSONHelper.doubleValue(value))
            }
        }
        var properties = [HorizontalSelectionProperty]()
        for key in keys.sorted() {
            var property = editableLengthProperty(
                "param:\(key)",
                Self.parameterDisplayName(key),
                Double(parameterSet[key] ?? defaults[key] ?? 0)
            )
            if parameterSet[key] != nil, !required.contains(key) {
                property.removeID = "removeParam:\(key)"
            }
            properties.append(property)
            if parameterSet[key] != nil {
                properties.append(editableBoolProperty("fixed:\(key)", "Fixed: \(Self.parameterDisplayName(key))", parametersFixed.contains(key)))
            }
        }
        if let addParameter = addParameterProperty(existing: keys) {
            properties.append(addParameter)
        }
        return properties
    }

    private func padstackShapeProperties(for ref: HorizontalSelectableRef) -> [HorizontalSelectionProperty] {
        guard let shape = padstackShape(for: ref) else {
            return []
        }
        var properties = [
            editableChoiceProperty(
                "form",
                "Form",
                value: shape.form.rawValue,
                options: HorizontalPadstackShapeForm.allCases.map {
                    HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.displayName)
                }
            ),
        ]
        if shape.form == .circle {
            properties.append(editableLengthProperty("diameter", "Diameter", shape.params.first ?? 0))
        } else {
            properties.append(editableLengthProperty("width", "Width", shape.params.first ?? 0))
            properties.append(editableLengthProperty("height", "Height", shape.params.count > 1 ? shape.params[1] : 0))
        }
        properties.append(contentsOf: [
            editableLayerProperty("layer", "Layer", shape.layer, copperOnly: false),
            editableTextProperty("parameterClass", "Parameter class", shape.parameterClass),
            editableLengthProperty("positionX", "Position X", shape.placement.shift.x),
            editableLengthProperty("positionY", "Position Y", shape.placement.shift.y),
            editableAngleProperty("angle", "Angle", shape.placement.angle),
            editableBoolProperty("mirror", "Mirror", shape.placement.mirrored),
        ])
        return properties
    }

    // MARK: Pad transforms

    private func movePoolPad(ref: HorizontalSelectableRef, by delta: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = poolPadIndex(for: ref, in: board) else {
            return
        }
        let pad = board.pads[index]
        let prefix = bakedPadPrefix(for: pad, in: board)
        board.pads[index].placement.shift = pad.placement.shift + delta
        for polygonIndex in board.packagePads.indices where normalizedID(board.packagePads[polygonIndex].id).hasPrefix(prefix) {
            board.packagePads[polygonIndex] = shifted(board.packagePads[polygonIndex], by: delta)
        }
        for holeIndex in board.packageHoles.indices where normalizedID(board.packageHoles[holeIndex].id).hasPrefix(prefix) {
            board.packageHoles[holeIndex] = shifted(board.packageHoles[holeIndex], by: delta)
        }
        let positionKey = "\(board.poolItemID ?? "package")/\(pad.id)".lowercased()
        for key in board.packagePadPositions.keys where key.lowercased() == positionKey {
            board.packagePadPositions[key] = board.packagePadPositions[key].map { $0 + delta }
        }
    }

    private func mirrorPoolPad(ref: HorizontalSelectableRef, around center: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = poolPadIndex(for: ref, in: board) else {
            return
        }
        board.pads[index].placement.shift = mirrored(board.pads[index].placement.shift, around: center)
        board.pads[index].placement.angle = wrappedAngle(-board.pads[index].placement.angle)
        board.pads[index].placement.mirrored.toggle()
        rebakePad(board.pads[index], board: &board)
    }

    private func rotatePoolPad(ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int, board: inout HorizontalBoard) {
        guard let index = poolPadIndex(for: ref, in: board) else {
            return
        }
        let pad = board.pads[index]
        board.pads[index].placement.shift = rotated(pad.placement.shift, around: center, by: angleDelta)
        board.pads[index].placement.angle = wrappedAngle(pad.placement.angle + (pad.placement.mirrored ? -angleDelta : angleDelta))
        rebakePad(board.pads[index], board: &board)
    }

    private func deletePoolPad(ref: HorizontalSelectableRef, from board: inout HorizontalBoard) -> Bool {
        guard let index = poolPadIndex(for: ref, in: board) else {
            return false
        }
        let pad = board.pads.remove(at: index)
        board.removeBakedPoolPad(id: pad.id)
        return true
    }

    private func rebakePad(_ pad: HorizontalPad, board: inout HorizontalBoard) {
        guard let poolContext else {
            return
        }
        board.rebakePoolPad(id: pad.id, context: poolContext)
    }

    private func updatePoolPad(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        board: inout HorizontalBoard
    ) {
        guard let index = poolPadIndex(for: ref, in: board) else {
            return
        }
        switch (propertyID, value) {
        case ("name", .text(let name)):
            board.pads[index].name = name
            rebakePad(board.pads[index], board: &board)
        case ("padstack", .choice(let padstackID)):
            board.pads[index].padstackID = padstackID
            // Required parameters come from the new padstack's defaults, as
            // placing a pad seeds them.
            if let json = poolContext?.padstackJSON(id: padstackID) {
                let defaults = HorizontalPoolJSON.parameterSet(json.dictionary("parameter_set"))
                for case let key as String in json["parameters_required"] as? [Any] ?? []
                    where board.pads[index].parameterSet[key] == nil {
                    board.pads[index].parameterSet[key] = defaults[key] ?? 0
                }
            }
            rebakePad(board.pads[index], board: &board)
        case ("positionX", .length(let x)):
            let delta = HorizontalPoint(x: x - board.pads[index].placement.shift.x, y: 0)
            movePoolPad(ref: ref, by: delta, board: &board)
        case ("positionY", .length(let y)):
            let delta = HorizontalPoint(x: 0, y: y - board.pads[index].placement.shift.y)
            movePoolPad(ref: ref, by: delta, board: &board)
        case ("angle", .angle(let angle)):
            board.pads[index].placement.angle = wrappedAngle(angle)
            rebakePad(board.pads[index], board: &board)
        case ("mirror", .bool(let mirrored)):
            board.pads[index].placement.mirrored = mirrored
            rebakePad(board.pads[index], board: &board)
        case ("addParameter", .choice(let key)):
            guard key != "none", board.pads[index].parameterSet[key] == nil else {
                return
            }
            let defaults = poolContext?.padstackJSON(id: board.pads[index].padstackID)
                .map { HorizontalPoolJSON.parameterSet($0.dictionary("parameter_set")) } ?? [:]
            board.pads[index].parameterSet[key] = defaults[key] ?? Int(seededParameterValue(key, padstackID: nil))
            rebakePad(board.pads[index], board: &board)
        default:
            if propertyID.hasPrefix("removeParam:") {
                let key = String(propertyID.dropFirst("removeParam:".count))
                board.pads[index].parameterSet.removeValue(forKey: key)
                board.pads[index].parametersFixed.removeAll { $0 == key }
                rebakePad(board.pads[index], board: &board)
            } else if propertyID.hasPrefix("param:"), case .length(let parameter) = value {
                let key = String(propertyID.dropFirst("param:".count))
                board.pads[index].parameterSet[key] = Int(parameter.rounded())
                rebakePad(board.pads[index], board: &board)
            } else if propertyID.hasPrefix("fixed:"), case .bool(let fixed) = value {
                let key = String(propertyID.dropFirst("fixed:".count))
                board.pads[index].parametersFixed.removeAll { $0 == key }
                if fixed {
                    board.pads[index].parametersFixed.append(key)
                    board.pads[index].parametersFixed.sort()
                }
            }
        }
    }

    // MARK: Shape transforms

    private func movePadstackShape(ref: HorizontalSelectableRef, by delta: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = padstackShapeIndex(for: ref, in: board) else {
            return
        }
        let prefix = bakedShapePrefix(for: board.padstackShapes[index], in: board)
        board.padstackShapes[index].placement.shift = board.padstackShapes[index].placement.shift + delta
        for polygonIndex in board.packagePads.indices where normalizedID(board.packagePads[polygonIndex].id).hasPrefix(prefix) {
            board.packagePads[polygonIndex] = shifted(board.packagePads[polygonIndex], by: delta)
        }
    }

    private func mirrorPadstackShape(ref: HorizontalSelectableRef, around center: HorizontalPoint, board: inout HorizontalBoard) {
        guard let index = padstackShapeIndex(for: ref, in: board) else {
            return
        }
        board.padstackShapes[index].placement.shift = mirrored(board.padstackShapes[index].placement.shift, around: center)
        board.padstackShapes[index].placement.angle = wrappedAngle(-board.padstackShapes[index].placement.angle)
        board.padstackShapes[index].placement.mirrored.toggle()
        board.rebakePadstackShape(id: board.padstackShapes[index].id)
    }

    private func rotatePadstackShape(ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int, board: inout HorizontalBoard) {
        guard let index = padstackShapeIndex(for: ref, in: board) else {
            return
        }
        let shape = board.padstackShapes[index]
        board.padstackShapes[index].placement.shift = rotated(shape.placement.shift, around: center, by: angleDelta)
        board.padstackShapes[index].placement.angle = wrappedAngle(shape.placement.angle + (shape.placement.mirrored ? -angleDelta : angleDelta))
        board.rebakePadstackShape(id: shape.id)
    }

    private func deletePadstackShape(ref: HorizontalSelectableRef, from board: inout HorizontalBoard) -> Bool {
        guard let index = padstackShapeIndex(for: ref, in: board) else {
            return false
        }
        let shape = board.padstackShapes.remove(at: index)
        board.removeBakedPadstackShape(id: shape.id)
        return true
    }

    private func updatePadstackShape(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        board: inout HorizontalBoard
    ) {
        guard let index = padstackShapeIndex(for: ref, in: board) else {
            return
        }
        var shape = board.padstackShapes[index]
        switch (propertyID, value) {
        case ("form", .choice(let form)):
            guard let newForm = HorizontalPadstackShapeForm(rawValue: form) else {
                return
            }
            let width = shape.params.first ?? 1_000_000
            let height = shape.params.count > 1 ? shape.params[1] : width / 2
            shape.form = newForm
            shape.params = newForm == .circle ? [width] : [width, height]
        case ("diameter", .length(let diameter)):
            shape.params = [max(diameter, 0)]
        case ("width", .length(let width)):
            shape.params = [max(width, 0), shape.params.count > 1 ? shape.params[1] : 0]
        case ("height", .length(let height)):
            shape.params = [shape.params.first ?? 0, max(height, 0)]
        case ("layer", .layer(let layer)):
            guard let layer else {
                return
            }
            shape.layer = layer
        case ("parameterClass", .text(let parameterClass)):
            shape.parameterClass = parameterClass
        case ("positionX", .length(let x)):
            shape.placement.shift.x = x
        case ("positionY", .length(let y)):
            shape.placement.shift.y = y
        case ("angle", .angle(let angle)):
            shape.placement.angle = wrappedAngle(angle)
        case ("mirror", .bool(let mirrored)):
            shape.placement.mirrored = mirrored
        default:
            return
        }
        board.padstackShapes[index] = shape
        board.rebakePadstackShape(id: shape.id)
    }

    // MARK: Placement tools

    /// "Place Pad" starts with the padstack picker; the pad follows the cursor
    /// once one is chosen.
    private func requestPlacePad() {
        guard !isReadOnly, modeProfile.placesPads, poolContext != nil,
              moveState == nil, drawGraphicsState == nil, pastePlacementState == nil, poolPlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil else {
            return
        }
        padstackPickerPresented = true
    }

    private func beginPlacePad(padstackID: String) {
        guard !isReadOnly, let poolContext, modeProfile.placesPads else {
            return
        }
        var parameterSet = [String: Int]()
        if let json = poolContext.padstackJSON(id: padstackID) {
            let defaults = HorizontalPoolJSON.parameterSet(json.dictionary("parameter_set"))
            for case let key as String in json["parameters_required"] as? [Any] ?? [] {
                parameterSet[key] = defaults[key] ?? 0
            }
        }
        let pad = HorizontalPad(
            id: UUID().uuidString.lowercased(),
            name: HorizontalPoolPackage.nextPadName(among: board.pads),
            padstackID: padstackID,
            placement: .identity,
            parameterSet: parameterSet
        )
        armPoolPlacement(.pad(pad, geometry: bakePlacementPad(pad)))
    }

    private func beginPlaceShape(form: HorizontalPadstackShapeForm) {
        guard !isReadOnly, modeProfile.placesShapes else {
            return
        }
        let shape = HorizontalPadstackShape(
            id: UUID().uuidString.lowercased(),
            form: form,
            params: form == .circle ? [1_000_000] : [1_000_000, 500_000],
            placement: .identity,
            layer: modeProfile.allows(layer: drawingLayer) ? drawingLayer : modeProfile.defaultDrawingLayer,
            parameterClass: ""
        )
        armPoolPlacement(.shape(shape))
    }

    private func beginPlaceHole(shape: HorizontalHoleShape) {
        guard !isReadOnly, modeProfile.placesHoles else {
            return
        }
        let hole = HorizontalHole(
            id: UUID().uuidString.lowercased(),
            position: .zero,
            diameter: 500_000,
            length: shape == .slot ? 1_000_000 : 500_000,
            shape: shape,
            plated: true,
            parameterClass: "hole"
        )
        armPoolPlacement(.hole(hole))
    }

    /// Place Decal…: Horizon's decal chooser, over every decal the project
    /// pool and the pools it draws from hold; the one chosen then follows the
    /// cursor. The pools are read off the main thread, and once read again
    /// only when something writes to them.
    private func requestPlaceDecal() {
        guard canPlaceDecal, let poolURL else {
            return
        }
        Task { @MainActor in
            let index = await Task.detached(priority: .userInitiated) {
                HorizontalBoardDecalPlacement.choices(projectPoolURL: poolURL)
            }.value
            // A tool taken up while the pools were read keeps the canvas.
            guard canPlaceDecal else {
                return
            }
            decalPickerIndex = index
        }
    }

    /// Whether a placement tool can take up the board now: on a board, not a
    /// pool item, and nothing else under way.
    private var canStartBoardPlacement: Bool {
        !isReadOnly && modeProfile.mode == .board
            && moveState == nil && drawGraphicsState == nil && drawTrackState == nil && pastePlacementState == nil
            && poolPlacementState == nil && roundOffVertexState == nil && addVertexState == nil && tuneState == nil && packagePlacementState == nil
    }

    /// Whether a decal can be put on the board now, with a pool to take it
    /// from.
    private var canPlaceDecal: Bool {
        canStartBoardPlacement && poolURL != nil
    }

    /// Whether Place Via… can start: a net to put the via on.
    private var canPlaceVia: Bool {
        canStartBoardPlacement && !board.netDetails.isEmpty
    }

    /// Whether Place Board Hole… can start: a pool to take its padstack from.
    private var canPlaceBoardHole: Bool {
        canStartBoardPlacement && poolURL != nil
    }

    // MARK: Place via, place board hole, set net

    /// Place Via…: Horizon's place-via tool asks for the net first.
    private func requestPlaceVia() {
        guard canPlaceVia, netPickerPurpose == nil else {
            return
        }
        netPickerPurpose = .placeVia
    }

    /// Set Net…: the net chooser, for the selected tracks and vias whose
    /// copper can take one (`BoardSetNet`).
    private func requestSetNet() {
        guard !isReadOnly, modeProfile.mode == .board, netPickerPurpose == nil else {
            return
        }
        let refs = uniqueRefs(selectedObjects).filter { $0.type == .track || $0.type == .via }
        let availability = BoardSetNet.availability(of: refs, in: board)
        let takers = zip(refs, availability).compactMap { ref, availability -> HorizontalSelectableRef? in
            if case .available? = availability { return ref }
            return nil
        }
        guard !takers.isEmpty else {
            if let reason = availability.lazy.compactMap({ $0?.reason }).first {
                showCanvasNote(reason)
            }
            return
        }
        netPickerPurpose = .setNet(takers)
    }

    private func netPickerTitle(_ purpose: BoardNetPickerPurpose) -> String {
        switch purpose {
        case .setNet: return "Set Net"
        case .placeVia: return "Place Via"
        }
    }

    private func netPickerMessage(_ purpose: BoardNetPickerPurpose) -> String {
        switch purpose {
        case .setNet:
            return "The net is pinned on the vias the copper reaches, which give it to the tracks between them."
        case .placeVia:
            return "The vias take the shape the via rules give the net."
        }
    }

    private func netPickerConfirmTitle(_ purpose: BoardNetPickerPurpose) -> String {
        switch purpose {
        case .setNet: return "Set Net"
        case .placeVia: return "Place"
        }
    }

    /// The net chooser's Set Net or Place, for what it was opened for.
    private func chooseNet(_ netID: String) {
        guard let purpose = netPickerPurpose else {
            return
        }
        netPickerPurpose = nil
        switch purpose {
        case .setNet(let refs):
            applySetNet(netID, on: refs)
        case .placeVia:
            beginPlaceVia(netID: netID)
        }
    }

    private func applySetNet(_ netID: String, on refs: [HorizontalSelectableRef]) {
        guard !isReadOnly else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        guard BoardSetNet.setNet(netID, on: refs, in: &draft) else {
            return
        }
        registerUndoSnapshot(previous, actionName: "Set Net")
        editedBoard = draft
        invalidateSelectableCache()
        hoveredObject = nil
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previous, kind: .properties))
        publishSelectionContext()
    }

    /// Lock, Unlock and Unlock All (`BoardCopperLock`), each offered only
    /// where it would change something.
    private func installCopperLockHandlers(_ handlers: inout HorizontalCanvasCommandHandlerSet) {
        let refs = selectedObjects.filter(BoardCopperLock.isLockable)
        if BoardCopperLock.canSet(true, on: refs, in: board) {
            handlers.lockSelection = { editCopperLock("Lock") { BoardCopperLock.setLocked(true, on: refs, in: &$0) } }
        }
        if BoardCopperLock.canSet(false, on: refs, in: board) {
            handlers.unlockSelection = { editCopperLock("Unlock") { BoardCopperLock.setLocked(false, on: refs, in: &$0) } }
        }
        if BoardCopperLock.hasLocked(board) {
            handlers.unlockAllCopper = { editCopperLock("Unlock All") { BoardCopperLock.unlockAll(in: &$0) } }
        }
    }

    /// One undoable edit of the lock. It stays in the block instance it is
    /// made in: a lock is the copper's own, not the layout's.
    private func editCopperLock(_ actionName: String, _ edit: (inout HorizontalBoard) -> Bool) {
        guard !isReadOnly else {
            return
        }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        guard edit(&draft) else {
            return
        }
        registerUndoSnapshot(previous, actionName: actionName)
        editedBoard = draft
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        publishSelectionContext()
    }

    /// Vias on `netID` follow the cursor, shaped as Horizon's place-via tool
    /// shapes one: by the via rule that takes the net, opening the mask
    /// where its padstack does. With no rule for the net there is no via to
    /// place, and the tool says so rather than start.
    private func beginPlaceVia(netID: String) {
        guard canPlaceVia else {
            return
        }
        guard let via = board.routeVia(netID: netID) else {
            let name = netDisplayName(netID) ?? shortID(netID)
            showCanvasNote(board.rules.viaRules.isEmpty
                ? "Place Via: the board has no via rules"
                : "Place Via: no via rule takes \(name)")
            return
        }
        armPoolPlacement(.via(board.viaWithMaskOpenings(via, poolURL: poolURL), netID: normalizedID(netID)))
    }

    /// Place Board Hole…: Horizon's hole padstack chooser, over the hole and
    /// mechanical padstacks of the project pool and the pools it draws from,
    /// read off the main thread.
    private func requestPlaceBoardHole() {
        guard canPlaceBoardHole, holePadstackChoices == nil, let poolURL else {
            return
        }
        Task { @MainActor in
            let choices = await Task.detached(priority: .userInitiated) {
                HorizontalPoolPadstacks.padstacks(ofTypes: ["hole", "mechanical"], poolURL: poolURL)
            }.value
            // A tool taken up while the pools were read keeps the canvas.
            guard canPlaceBoardHole else {
                return
            }
            holePadstackChoices = choices
        }
    }

    private func chooseHolePadstack(_ padstackID: String) {
        guard holePadstackChoices != nil else {
            return
        }
        holePadstackChoices = nil
        beginPlaceBoardHole(padstackID: padstackID)
    }

    /// A board hole on `padstackID` follows the cursor, with the padstack's
    /// own values for the parameters it requires, as Horizon's tool gives it
    /// them. A padstack from another pool is cached into the project pool
    /// when the board is saved, which is where the loader reads it from.
    private func beginPlaceBoardHole(padstackID: String) {
        guard canPlaceBoardHole, let poolURL,
              let padstack = HorizontalPoolPadstacks.padstack(id: padstackID, poolURL: poolURL) else {
            return
        }
        let name = padstack.string("name") ?? shortID(padstackID)
        let defaults = padstack.dictionary("parameter_set") ?? [:]
        var parameterSet = JSONDictionary()
        for case let key as String in padstack["parameters_required"] as? [Any] ?? [] {
            parameterSet[key] = defaults[key] ?? 0
        }
        let holes = HorizontalBoard.boardHoles(
            id: UUID().uuidString.lowercased(),
            padstackID: padstackID,
            padstackJSON: padstack,
            placement: .identity,
            parameterSet: parameterSet,
            netID: nil
        )
        // A board hole whose padstack drills several is several holes here,
        // none of which the file can take by itself.
        guard holes.count == 1, let hole = holes.first else {
            showCanvasNote(holes.isEmpty
                ? "Place Board Hole: \(name) drills no hole"
                : "Place Board Hole: \(name) drills \(holes.count) holes; a board hole here drills one")
            return
        }
        armPoolPlacement(.hole(hole))
    }

    private func beginPlaceDecal(_ item: HorizontalPoolLibraryItem) {
        guard canPlaceDecal,
              let placement = HorizontalBoardDecalPlacement(item: item),
              let geometry = placementDecal(placement, at: .zero) else {
            return
        }
        armPoolPlacement(.decal(placement, geometry: geometry))
    }

    /// The Pools pane's Place on a decal: it follows the cursor as one chosen
    /// in Place Decal…'s chooser does. Taken up once, whether or not the
    /// board could take it then (another tool under way), so it doesn't
    /// start later on its own; the hosts drop it when the board goes.
    private func takeUpPlaceDecalRequest() {
        guard let request = placeDecalRequest, handledPlaceDecalRequestID != request.id else {
            return
        }
        handledPlaceDecalRequestID = request.id
        guard canPlaceDecal else {
            #if os(macOS)
            NSSound.beep()
            #endif
            return
        }
        beginPlaceDecal(request.item)
    }

    /// The board decal `placement` makes at `position`, drawn as the loader
    /// will draw it from the file.
    private func placementDecal(
        _ placement: HorizontalBoardDecalPlacement,
        at position: HorizontalPoint,
        id: String = "place-preview-decal"
    ) -> HorizontalBoardDecal? {
        placement.decal(id: id, at: position, nInnerLayers: boardInnerLayerCount, projectPoolURL: poolURL)
    }

    /// S while a decal follows the cursor: the scale it goes down with, as
    /// Horizon's place-decal tool takes it in its enter-scale window.
    private func enterDecalScale() {
        guard case .decal(let placement, _)? = poolPlacementState?.kind else {
            return
        }
        #if os(macOS)
        guard let scale = HorizontalTrackWidthPrompt.runNumber(
            title: "Decal Scale",
            message: "Enter the scale to place \(placement.name) at; 1 is its own size.",
            current: placement.scale,
            placeholder: "1"
        ) else {
            return
        }
        applyDecalScale(scale)
        #else
        promptRequest = HorizontalCanvasPromptRequest(
            title: "Decal Scale",
            confirmTitle: "Set",
            content: .number(seed: placement.scale, unit: "×") { scale in
                guard let scale, scale.isFinite, scale > 0 else { return }
                applyDecalScale(scale)
            }
        )
        #endif
    }

    private func applyDecalScale(_ scale: Double) {
        guard var state = poolPlacementState, case .decal(var placement, _) = state.kind else {
            return
        }
        placement.scale = scale
        guard let geometry = placementDecal(placement, at: .zero) else {
            return
        }
        state.kind = .decal(placement, geometry: geometry)
        poolPlacementState = state
    }

    private func armPoolPlacement(_ kind: PoolPlacementKind) {
        guard moveState == nil, drawGraphicsState == nil, drawTrackState == nil, pastePlacementState == nil,
              roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil else {
            return
        }
        selectedObjects = []
        hoveredObject = nil
        poolPlacementState = PoolPlacementState(kind: kind, cursor: lastCursorWorldPoint ?? board.bounds.center)
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// The pad's copper, mask, paste and holes baked at the origin, so the
    /// ghost can be translated to the cursor without re-parsing per frame.
    private func bakePlacementPad(_ pad: HorizontalPad) -> HorizontalPackageGeometry {
        guard let poolContext, let packageID = board.poolItemID else {
            return .empty
        }
        var origin = pad
        origin.placement.shift = .zero
        let packageJSON: JSONDictionary = [
            "uuid": packageID,
            "parameter_set": HorizontalPoolJSON.parameterSetJSON(board.poolParameterSet),
            "pads": [origin.id: origin.json(original: nil)] as JSONDictionary,
        ]
        return HorizontalBoard.packagePreviewGeometry(
            packageJSON: packageJSON,
            packageID: packageID,
            poolURL: poolContext.poolURL,
            boardPackageID: "place-preview",
            nInnerLayers: 1,
            runsParameterProgram: false,
            padstack: poolContext.padstackJSON(id:)
        )
    }

    private func appendPoolPlacementGhost(_ state: PoolPlacementState, into preview: inout HorizontalBoard) {
        let cursor = state.cursor
        switch state.kind {
        case .pad(_, let geometry):
            preview.packagePads.append(contentsOf: geometry.pads.map { shifted($0, by: cursor) })
            preview.packageHoles.append(contentsOf: geometry.holes.map { shifted($0, by: cursor) })
        case .shape(var shape):
            shape.placement.shift = cursor
            var polygon = HorizontalBoard.bakedShapePolygon(shape, padstackID: "place-preview")
            polygon.id = "place-preview/" + polygon.id
            preview.packagePads.append(polygon)
        case .hole(var hole):
            hole.id = "place-preview-hole"
            hole.position = cursor
            preview.packageHoles.append(hole)
        case .decal(_, let geometry):
            preview.decals.append(shifted(geometry, by: cursor))
        case .via(let template, let netID):
            let ghost = BoardTrackRouting.throughVia(
                template, id: "place-preview-via", at: cursor, netID: netID, copperLayerCount: preview.copperLayerCount)
            preview.vias.append(ghost.via)
            preview.viaHoles.append(ghost.hole)
        }
    }

    private func poolPlacementSignatureCount(_ kind: PoolPlacementKind) -> Int {
        switch kind {
        case .pad(let pad, _):
            return 1_000_000 + pad.placement.angle + (pad.placement.mirrored ? 100_000 : 0)
        case .shape(let shape):
            return 2_000_000 + shape.placement.angle + (shape.placement.mirrored ? 100_000 : 0) + shape.layer
        case .hole(let hole):
            return 3_000_000 + hole.angle + (hole.shape == .slot ? 100_000 : 0)
        case .decal(let placement, _):
            // Which decal and its scale too, which a count of its own can't
            // carry: another decal, or the same one at another scale, at the
            // same angle is another ghost.
            var hasher = Hasher()
            hasher.combine(placement.item.uuid)
            hasher.combine(placement.angle)
            hasher.combine(placement.flip)
            hasher.combine(placement.scale)
            return hasher.finalize()
        case .via:
            // One via all the tool long: its net and shape don't change.
            return 4_000_000
        }
    }

    private func rotatePoolPlacement() {
        guard var state = poolPlacementState else {
            return
        }
        switch state.kind {
        case .pad(var pad, _):
            pad.placement.angle = wrappedAngle(pad.placement.angle + (pad.placement.mirrored ? -Self.quarterTurnAngle : Self.quarterTurnAngle))
            state.kind = .pad(pad, geometry: bakePlacementPad(pad))
        case .shape(var shape):
            shape.placement.angle = wrappedAngle(shape.placement.angle + (shape.placement.mirrored ? -Self.quarterTurnAngle : Self.quarterTurnAngle))
            state.kind = .shape(shape)
        case .hole(var hole):
            hole.angle = wrappedAngle(hole.angle + Self.quarterTurnAngle)
            state.kind = .hole(hole)
        case .decal(var placement, _):
            placement.rotate()
            guard let geometry = placementDecal(placement, at: .zero) else {
                return
            }
            state.kind = .decal(placement, geometry: geometry)
        case .via:
            return
        }
        poolPlacementState = state
    }

    private func mirrorPoolPlacement() {
        guard var state = poolPlacementState else {
            return
        }
        switch state.kind {
        case .pad(var pad, _):
            pad.placement.mirrored.toggle()
            pad.placement.angle = wrappedAngle(-pad.placement.angle)
            state.kind = .pad(pad, geometry: bakePlacementPad(pad))
        case .shape(var shape):
            shape.placement.mirrored.toggle()
            shape.placement.angle = wrappedAngle(-shape.placement.angle)
            state.kind = .shape(shape)
        case .hole, .via:
            return
        case .decal(var placement, _):
            placement.toggleFlip()
            guard let geometry = placementDecal(placement, at: .zero) else {
                return
            }
            state.kind = .decal(placement, geometry: geometry)
        }
        poolPlacementState = state
    }

    /// Places the ghost at `point`, then re-arms with a fresh object of the
    /// same kind so the next click places another; a decal's tool ends there.
    private func commitPoolPlacement(at point: HorizontalPoint?) {
        guard let state = poolPlacementState else {
            return
        }
        let position = point ?? state.cursor
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        let ref: HorizontalSelectableRef
        let actionName: String
        var nextKind: PoolPlacementKind?

        switch state.kind {
        case .pad(var pad, _):
            pad.placement.shift = position
            draft.pads.append(pad)
            if let poolContext {
                draft.rebakePoolPad(id: pad.id, context: poolContext)
            }
            ref = HorizontalSelectableRef(id: draft.padRefID(for: pad), type: .pad)
            actionName = "Place Pad"
            var next = pad
            next.id = UUID().uuidString.lowercased()
            next.name = HorizontalPoolPackage.nextPadName(among: draft.pads)
            next.placement.shift = .zero
            nextKind = .pad(next, geometry: bakePlacementPad(next))
        case .shape(var shape):
            shape.placement.shift = position
            draft.padstackShapes.append(shape)
            draft.rebakePadstackShape(id: shape.id)
            ref = HorizontalSelectableRef(id: shape.id, type: .padstackShape, layer: shape.layer)
            actionName = "Place Shape"
            var next = shape
            next.id = UUID().uuidString.lowercased()
            next.placement.shift = .zero
            nextKind = .shape(next)
        case .hole(var hole):
            hole.position = position
            draft.holes.append(hole)
            ref = HorizontalSelectableRef(id: hole.id, type: .boardHole)
            actionName = "Place Hole"
            var next = hole
            next.id = UUID().uuidString.lowercased()
            next.position = .zero
            nextKind = .hole(next)
        case .decal(let placement, _):
            // On whole nanometres, as the file holds it.
            let at = HorizontalPoint(x: position.x.rounded(), y: position.y.rounded())
            guard let decal = placementDecal(placement, at: at, id: UUID().uuidString.lowercased()) else {
                return
            }
            draft.decals.append(decal)
            ref = HorizontalSelectableRef(id: decal.id, type: .boardDecal)
            actionName = "Place Decal"
            nextKind = nil
        case .via(let template, let netID):
            let at = HorizontalPoint(x: position.x.rounded(), y: position.y.rounded())
            // The via stands on a junction, and a pad with a junction on its
            // centre is cut off the copper that ends on it.
            let atPadCentre = draft.packagePadPositions.values.contains { pointKey($0) == pointKey(at) }
            guard !atPadCentre else {
                #if os(macOS)
                NSSound.beep()
                #endif
                showCanvasNote("Place Via: not on a pad's centre, which it would cut off its tracks")
                return
            }
            // It joins the copper ending where it goes, as a via the track
            // tool drops does (`BoardTrackRouting.dropVia`).
            BoardTrackRouting.dropVia(template, at: at, netID: netID, preferredJunctionID: nil, on: &draft)
            guard let via = draft.vias.last else {
                return
            }
            ref = HorizontalSelectableRef(id: via.id, type: .via)
            actionName = "Place Via"
            nextKind = .via(template, netID: netID)
        }

        registerUndoSnapshot(previous, actionName: actionName)
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        selectedObjects = [ref]
        hoveredObject = nil
        poolPlacementState = nextKind.map { PoolPlacementState(kind: $0, cursor: position) }
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    private func cancelPoolPlacement() {
        guard poolPlacementState != nil else {
            return
        }
        poolPlacementState = nil
        publishCanvasCommandActions()
    }

    // MARK: Round off vertex

    /// The one selected polygon vertex the tool would round, when exactly
    /// one is selected (other selected objects are ignored, as upstream),
    /// or with no vertex the one selected arc centre or arc, whose rounded
    /// corner it adjusts.
    private var roundOffVertexCandidate: HorizontalSelectableRef? {
        let vertexRefs = selectedObjects.filter { $0.type == .polygonVertex }
        if vertexRefs.count == 1 {
            return vertexRefs[0]
        }
        guard vertexRefs.isEmpty else {
            return nil
        }
        let arcCenterRefs = selectedObjects.filter { $0.type == .polygonArcCenter }
        if arcCenterRefs.count == 1 {
            return arcCenterRefs[0]
        }
        let edgeRefs = selectedObjects.filter { $0.type == .polygonEdge }
        guard arcCenterRefs.isEmpty, edgeRefs.count == 1 else {
            return nil
        }
        return edgeRefs[0]
    }

    /// Whether the tool would adjust a corner rounded off before rather than
    /// round a sharp one, for the menu's title.
    private var roundOffVertexAdjustsRounding: Bool {
        guard let ref = roundOffVertexCandidate else {
            return false
        }
        return roundOffVertexState(for: ref)?.adjustsRounding == true
    }

    private var canRoundOffVertex: Bool {
        guard !isReadOnly, moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, roundOffVertexState == nil && addVertexState == nil && tuneState == nil, packagePlacementState == nil,
              let ref = roundOffVertexCandidate else {
            return false
        }
        return roundOffVertexState(for: ref) != nil
    }

    /// The rounding for the corner `ref` names, or nil when it cannot be
    /// rounded: package-owned polygons, an arc that isn't a rounded corner
    /// (tangent to the straight edges either side), and collinear (or
    /// folded) edges. A vertex of a rounded corner, its arc's centre, or the
    /// arc itself where the pointer picked it, adjusts that rounding.
    private func roundOffVertexState(for ref: HorizontalSelectableRef) -> RoundOffVertexState? {
        guard [.polygonVertex, .polygonArcCenter, .polygonEdge].contains(ref.type), !normalizedID(ref.id).contains("/") else {
            return nil
        }
        let stableBoard = editedBoard ?? sourceBoard
        let polygonID = normalizedID(ref.id)
        // A plane's or a keepout's outline rounds off as any polygon does.
        guard let polygon = (stableBoard.polygons + stableBoard.outlinePolygons)
                .first(where: { normalizedID($0.id) == polygonID }),
              !polygon.id.contains("/") else {
            return nil
        }
        let rounding: HorizontalPolygonRounding?
        switch ref.type {
        case .polygonArcCenter:
            rounding = HorizontalPolygonRounding(roundedCornerOf: polygon, arcStart: ref.vertex)
        case .polygonEdge:
            rounding = pointerPicked(edge: ref.vertex, of: polygon)
                ? HorizontalPolygonRounding(roundedCornerOf: polygon, arcStart: ref.vertex)
                : nil
        default:
            rounding = HorizontalPolygonRounding(polygon: polygon, vertexIndex: ref.vertex)
                ?? HorizontalPolygonRounding.roundedCorner(of: polygon, vertexIndex: ref.vertex)
        }
        guard let rounding else {
            return nil
        }
        return RoundOffVertexState(polygonID: polygon.id, rounding: rounding, cursor: lastCursorWorldPoint ?? rounding.corner)
    }

    /// Whether the last click or right-click was on the polygon's edge at
    /// `index`, rather than inside the board, which names the polygon by its
    /// first edge as well.
    private func pointerPicked(edge index: Int, of polygon: HorizontalPolygon) -> Bool {
        guard let point = lastPointerPick.point, polygon.polygonVertices.indices.contains(index) else {
            return false
        }
        let tolerance = max(lastPointerPick.worldUnitsPerPoint, 0) * 6
        let edge = polygon.edgePolyline(at: index, arcPrecision: 24)
        return zip(edge, edge.dropFirst()).contains { from, to in
            HorizontalRouteClearanceProbe.pointSegmentDistance(point, from, to) <= tolerance
        }
    }

    // MARK: - Add vertex

    /// The polygon edge K adds vertices to: one selected edge, or the edge
    /// after one selected vertex, of a board polygon that isn't a package's.
    private var addVertexCandidate: (polygon: HorizontalPolygon, vertex: Int)? {
        let refs = uniqueRefs(selectedObjects)
        guard refs.count == 1, let ref = refs.first else {
            return nil
        }
        return addVertexTarget(ref)
    }

    /// The board polygon (or plane outline) `ref`, an edge or a vertex of
    /// it, names, and the vertex its edge starts at; nil for anything else.
    private func addVertexTarget(_ ref: HorizontalSelectableRef) -> (polygon: HorizontalPolygon, vertex: Int)? {
        guard ref.type == .polygonEdge || ref.type == .polygonVertex else {
            return nil
        }
        var board = board
        _ = board.liftPlaneOutlines()
        guard let polygon = board.polygons.first(where: { normalizedID($0.id) == normalizedID(ref.id) }),
              polygon.polygonVertices.indices.contains(ref.vertex) else {
            return nil
        }
        return (polygon, ref.vertex)
    }

    private var canAddPolygonVertex: Bool {
        guard !isReadOnly, moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, roundOffVertexState == nil, addVertexState == nil,
              tuneState == nil, packagePlacementState == nil,
              let candidate = addVertexCandidate else {
            return false
        }
        return candidate.polygon.polygonVertices[candidate.vertex].type == .line
    }

    /// K: a vertex into the edge at the cursor, or the edge's middle when the
    /// cursor isn't on the canvas, following the cursor from there.
    private func beginAddPolygonVertex() {
        guard canAddPolygonVertex, let candidate = addVertexCandidate else {
            return
        }
        let vertices = candidate.polygon.polygonVertices
        let start = vertices[candidate.vertex].position
        let end = vertices[candidate.polygon.nextVertexIndex(after: candidate.vertex)].position
        let middle = HorizontalPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        guard var state = AddVertexState(polygon: candidate.polygon, afterVertex: candidate.vertex, cursor: lastCursorWorldPoint ?? middle) else {
            return
        }
        state.selection = selectedObjects
        selectedObjects = []
        hoveredObject = nil
        addVertexState = state
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// A click: the vertex at the cursor stays at `point`, and the next one
    /// goes in after it.
    private func placeAddVertex(at point: HorizontalPoint) {
        guard var state = addVertexState else {
            return
        }
        state.update(cursor: point)
        state.place()
        addVertexState = state
    }

    /// Return, Esc or a double-click: the vertices the clicks placed go into
    /// the polygon as one step, the one at the cursor dropped, the last of
    /// them left selected. With none placed the polygon is as it was, and
    /// the edge K was pressed on selected again.
    private func commitAddVertex() {
        guard let state = addVertexState else {
            return
        }
        addVertexState = nil
        guard state.placedCount > 0 else {
            selectedObjects = state.selection
            publishSelectionContext()
            publishCanvasCommandActions()
            return
        }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        // A plane's outline takes its vertices as a polygon.
        let liftedOutlines = draft.liftPlaneOutlines()
        let placed = state.placed
        if let index = draft.polygons.firstIndex(where: { normalizedID($0.id) == normalizedID(state.polygonID) }) {
            draft.polygons[index] = placed
        }
        draft.lowerPlaneOutlines(lifted: liftedOutlines)
        registerUndoSnapshot(previous, actionName: state.placedCount == 1 ? "Add Vertex" : "Add Vertices")
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        selectedObjects = [
            HorizontalSelectableRef(id: placed.id, type: .polygonVertex, vertex: state.floatingIndex - 1, layer: placed.layer)
        ]
        hoveredObject = nil
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    private func beginRoundOffVertex() {
        guard canRoundOffVertex, let ref = roundOffVertexCandidate,
              let state = roundOffVertexState(for: ref) else {
            return
        }
        selectedObjects = []
        hoveredObject = nil
        roundOffVertexState = state
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Rounds the corner at the radius under `point` (or the last one set),
    /// leaving the new arc's start vertex selected. On a sharp corner a zero
    /// radius changes nothing and just ends the tool; on a corner rounded
    /// off before it takes the arc out, leaving the corner sharp and
    /// selected.
    private func commitRoundOffVertex(at point: HorizontalPoint?) {
        guard var state = roundOffVertexState else {
            return
        }
        if let point {
            state.update(cursor: point)
        }
        guard !state.isUnchanged else {
            cancelRoundOffVertex()
            return
        }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        // A plane's outline is rounded off as a polygon.
        let liftedOutlines = draft.liftPlaneOutlines()
        let polygonID = normalizedID(state.polygonID)
        guard let index = draft.polygons.firstIndex(where: { normalizedID($0.id) == polygonID }) else {
            cancelRoundOffVertex()
            return
        }
        draft.polygons[index] = state.polygon()
        let roundedLayer = draft.polygons[index].layer
        draft.lowerPlaneOutlines(lifted: liftedOutlines)
        roundOffVertexState = nil
        let actionName = !state.adjustsRounding ? "Round Off Vertex" : state.isSharp ? "Remove Rounding" : "Adjust Rounding"
        registerUndoSnapshot(previous, actionName: actionName)
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft)
        let vertex = state.rounding.vertexIndex(roundedAt: state.clampedRadius)
        selectedObjects = [
            HorizontalSelectableRef(id: state.polygonID, type: .polygonVertex, vertex: vertex, layer: roundedLayer)
        ]
        hoveredObject = nil
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Return during the tool: type the radius (clamped to what fits) and
    /// commit with it. On a corner rounded off before, 0 makes it sharp.
    private func enterRoundOffVertexRadius() {
        guard let state = roundOffVertexState else {
            return
        }
        let nmPerMM = 1_000_000.0
        let maxMM = String(format: "%.3f", state.rounding.maxRadius / nmPerMM)
        let allowsZero = state.adjustsRounding
        #if os(macOS)
        let sharpNote = allowsZero ? " 0 makes the corner sharp." : ""
        guard let chosen = HorizontalTrackWidthPrompt.run(
            title: "Arc Radius",
            message: "Enter the arc radius in millimeters (up to \(maxMM) mm).\(sharpNote)",
            currentWidthNM: state.clampedRadius,
            allowsZero: allowsZero
        ) else {
            return
        }
        applyRoundOffVertexRadius(chosen)
        #else
        promptRequest = HorizontalCanvasPromptRequest(
            title: allowsZero ? "Arc Radius (up to \(maxMM) mm, 0 for sharp)" : "Arc Radius (up to \(maxMM) mm)",
            confirmTitle: "Set",
            content: .number(seed: state.clampedRadius / nmPerMM, unit: "mm") { mm in
                guard let mm, mm.isFinite, mm > 0 || (allowsZero && mm == 0) else { return }
                applyRoundOffVertexRadius((mm * nmPerMM).rounded())
            }
        )
        #endif
    }

    private func applyRoundOffVertexRadius(_ radius: Double) {
        guard var state = roundOffVertexState else {
            return
        }
        state.radius = state.rounding.clamped(radius)
        roundOffVertexState = state
        commitRoundOffVertex(at: nil)
    }

    private func cancelRoundOffVertex() {
        guard roundOffVertexState != nil else {
            return
        }
        roundOffVertexState = nil
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    // MARK: - Tune track

    private struct TuneInputs: Equatable {
        var settings: HorizontalMeander.Settings
        var target: Double?
    }

    /// The tune's target: one typed, else the Length Tuning window's reference.
    private var tuneTarget: Double? {
        toolSettings.tuneTarget ?? tuningReferenceLength
    }

    private var tuneTargetSource: HorizontalTuneInspectorState.TargetSource {
        toolSettings.tuneTarget != nil ? .typed : (tuningReferenceLength != nil ? .reference : .none)
    }

    private var tuneInspectorState: HorizontalTuneInspectorState? {
        tuneState?.inspectorState(target: tuneTarget, source: tuneTargetSource)
    }

    /// D: the selected track dragged keeping its neighbours' slopes, or the
    /// selected via with its tracks' ends (`HorizontalCopperDrag`), riding
    /// the move tool: the cursor drags it, a click or Return commits it as
    /// one undo step, Esc puts it back.
    private func beginCopperDrag() {
        guard !isReadOnly, modeProfile.mode == .board, moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, roundOffVertexState == nil, addVertexState == nil,
              packagePlacementState == nil, tuneState == nil, measureState == nil else {
            return
        }
        let originalBoard = board
        switch HorizontalCopperDrag.begin(selection: selectedObjects, on: originalBoard) {
        case .failure(let refusal):
            showCanvasNote(refusal.message)
        case .success(let drag):
            let start = lastCursorWorldPoint.map(snapBoardPointToGrid) ?? drag.anchor
            moveState = MoveState(
                startPoint: start,
                lastPoint: start,
                originalBoard: originalBoard,
                tracksCursor: true,
                snapTargets: [],
                residentMovePlan: BoardResidentMovePlan(),
                copperDrag: drag
            )
            hoveredObject = nil
            publishSelectionContext()
        }
    }

    private func beginTuneTrack() {
        guard !isReadOnly, modeProfile.mode == .board, moveState == nil, drawGraphicsState == nil, drawTrackState == nil,
              pastePlacementState == nil, poolPlacementState == nil, roundOffVertexState == nil, addVertexState == nil,
              packagePlacementState == nil, tuneState == nil else {
            return
        }
        let state = BoardTuneState(board: editedBoard ?? sourceBoard)
        tuneState = state
        routeInspector?.updateTune(state.inspectorState(target: tuneTarget, source: tuneTargetSource))
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// A click during the tool: on a track, the tune starts there; once it
    /// has, the meander is laid.
    private func clickTune(at point: HorizontalPoint, worldUnitsPerPoint: Double) {
        guard var state = tuneState else { return }
        if state.hasStarted {
            commitTune()
            return
        }
        state.start(at: point, reach: max(worldUnitsPerPoint, 0) * 6, target: tuneTarget,
                    settings: toolSettings.meanderSettings)
        tuneState = state
    }

    /// Lays the meander under the cursor, one undo step, once the exact
    /// clearance check finds nothing wrong with it; the tool stays, for the
    /// next track.
    private func commitTune() {
        guard var state = tuneState, let result = state.result else { return }
        guard result.hasCells else {
            state.refusal = BoardTuneState.statusText(result).prefix(1).uppercased() + BoardTuneState.statusText(result).dropFirst() + "."
            tuneState = state
            return
        }
        let previous = editedBoard ?? sourceBoard
        var draft = previous
        let trackIDs = HorizontalMeanderTuner.lay(result, on: &draft)
        let violations = HorizontalMeanderTuner.violations(on: draft, newTrackIDs: trackIDs)
        if let first = violations.first {
            // The swept boxes should never let this through; say so rather
            // than lay it.
            state.refusal = "Not laid: \(first.first.name) and \(first.second.name) would be "
                + "\(HorizontalLengthText.millimetres(first.distance)) apart, under the \(HorizontalLengthText.millimetres(first.clearance)) clearance."
            tuneState = state
            return
        }
        registerUndoSnapshot(previous, actionName: "Tune Track")
        invalidateSelectableCache()
        publishConnectivityResolvedEdit(draft, sync: BoardLayoutSyncIntent(baseline: previous, kind: .tune))
        tuneState = BoardTuneState(board: editedBoard ?? draft)
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Esc: the meander under way goes, then the tool.
    private func cancelTune() {
        guard var state = tuneState else { return }
        if state.hasStarted || state.refusal != nil {
            state.restart()
            tuneState = state
            return
        }
        endTune()
    }

    /// The tool ends, and the inspector goes back to what it showed. Told
    /// here rather than only on the state's change, which an arm and an end
    /// in one update would never show.
    private func endTune() {
        guard tuneState != nil else { return }
        tuneState = nil
        routeInspector?.endRoute()
        publishSelectionContext()
        publishCanvasCommandActions()
    }

    /// Return during the tool: type the target length.
    private func enterTuneTarget() {
        let nmPerMM = 1_000_000.0
        let seed = tuneTarget ?? tuneState?.result?.netLength ?? 0
        #if os(macOS)
        guard let chosen = HorizontalTrackWidthPrompt.run(
            title: "Target Length",
            message: "Enter the length the tune makes its net, in millimeters. 0 takes the Length Tuning window's reference again.",
            currentWidthNM: seed,
            allowsZero: true
        ) else {
            return
        }
        toolSettings.tuneTarget = chosen > 0 ? chosen : nil
        #else
        promptRequest = HorizontalCanvasPromptRequest(
            title: "Target Length (0 for the reference)",
            confirmTitle: "Set",
            content: .number(seed: seed / nmPerMM, unit: "mm") { mm in
                guard let mm, mm.isFinite, mm >= 0 else { return }
                toolSettings.tuneTarget = mm > 0 ? (mm * nmPerMM).rounded() : nil
            }
        )
        #endif
    }
}
