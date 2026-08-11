import SwiftUI

struct BoardSelectableCacheKey: Hashable {
    var boardID: String
    var revision: Int
    var displayOptions: BoardDisplayOptions
    var counts: [Int]
}

struct BoardAllSelectableCacheKey: Hashable {
    var boardID: String
    var revision: Int
    var counts: [Int]
}

struct BoardMetalHighlightCacheKey: Hashable {
    var selectableKey: BoardSelectableCacheKey
    var highlightedNetIDs: [String]
    var highlightedComponentIDs: [String]
    var highlightColor: HorizontalMetalRGBA
    var backgroundColor: HorizontalMetalRGBA
    var layerOpacity: Double
    /// These batches emit generated net labels too, and cull them by zoom the
    /// same way the main build does. The threshold is part of the key so a
    /// cached batch is never reused across a zoom step that changes which
    /// labels are legible.
    var minimumLabelSize: Double
}

struct BoardMetalSelectionCacheKey: Hashable {
    var selectableKey: BoardSelectableCacheKey
    /// Non-nil while a non-patchable move is in progress, so the selection
    /// overlay rebuilds (follows the dragged object) instead of returning the
    /// cached pre-move box.
    var movePreview: BoardMovePreviewSignature? = nil
    var selectedRefs: [HorizontalSelectableRef]
    var hoveredRef: HorizontalSelectableRef?
    var selectedOuterColor: HorizontalMetalRGBA
    var selectedInnerColor: HorizontalMetalRGBA
    var selectedHandleInnerColor: HorizontalMetalRGBA
    var selectedGroupPreviewColor: HorizontalMetalRGBA
    var hoverOuterColor: HorizontalMetalRGBA
    var hoverInnerColor: HorizontalMetalRGBA
    /// See `BoardMetalHighlightCacheKey.minimumLabelSize`.
    var minimumLabelSize: Double
    var handleShape: HorizontalSelectionHandleShape
}

struct BoardMovePreviewCacheKey: Hashable {
    var boardID: String
    var revision: Int
    var counts: [Int]
    var selectedRefs: [HorizontalSelectableRef]
    var startPoint: HorizontalPoint
    var lastPoint: HorizontalPoint
}

struct BoardMovePreviewSignature: Hashable {
    var selectedRefs: [HorizontalSelectableRef]
    var startPoint: HorizontalPoint
    var lastPoint: HorizontalPoint
}

/// Render-cache key for the live paste-placement ghost: the clipboard ghost
/// follows the cursor until commit, so the metal buckets must rebuild as the
/// offset changes. Rounded to whole nm so sub-unit cursor jitter doesn't churn.
struct BoardPastePreviewSignature: Hashable {
    var itemCount: Int
    var offsetX: Int64
    var offsetY: Int64
}

struct BoardResidentSegmentMove: Hashable {
    var movesFrom = false
    var movesTo = false
    var movesCenter = false

    func isRigid(for segment: HorizontalSegment) -> Bool {
        movesFrom && movesTo && (segment.center == nil || movesCenter)
    }
}

struct BoardResidentMovePlan {
    var translatedRefs = Set<HorizontalSelectableRef>()
    var segmentMoves = [HorizontalSelectableRef: BoardResidentSegmentMove]()
    var unsupportedRefs = Set<HorizontalSelectableRef>()

    var isPatchable: Bool {
        unsupportedRefs.isEmpty
    }
}

struct BoardMovePointOwner {
    var ref: HorizontalSelectableRef
    var netID: String?
}

struct BoardMoveSegmentEndpoint {
    var ref: HorizontalSelectableRef
    var netID: String?
    var movesFrom: Bool
}

struct BoardMoveConnectionAnchor {
    var point: HorizontalPoint
    var netID: String?
}

struct BoardMoveConnectivityIndex {
    var segmentsByRef = [HorizontalSelectableRef: HorizontalSegment]()
    var segmentEndpointsByPoint = [String: [BoardMoveSegmentEndpoint]]()
    var junctionOwnersByPoint = [String: [BoardMovePointOwner]]()
    var viaOwnersByPoint = [String: [BoardMovePointOwner]]()
    var packageOwnersByPoint = [String: [BoardMovePointOwner]]()
    var packageAnchorsByID = [String: [BoardMoveConnectionAnchor]]()
}

struct BoardSelectionDetailsCacheKey: Hashable {
    var boardID: String
    var revision: Int
    var counts: [Int]
    var selectedRefs: [HorizontalSelectableRef]
    var selectedUnplacedObjectID: String?
}

struct BoardMetalPrimitiveSpan: Hashable {
    var compositeGroup: Int
    var start: Int
    var count: Int
}

struct BoardMetalSceneMetadata {
    var lineSpansByRef: [HorizontalSelectableRef: [BoardMetalPrimitiveSpan]] = [:]
    var triangleSpansByRef: [HorizontalSelectableRef: [BoardMetalPrimitiveSpan]] = [:]
    var anchoredRectSpansByRef: [HorizontalSelectableRef: [BoardMetalPrimitiveSpan]] = [:]
    var linePrimitivesByRef: [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]] = [:]
    var trianglePrimitivesByRef: [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]] = [:]
    var anchoredRectPrimitivesByRef: [HorizontalSelectableRef: [HorizontalMetalAnchoredRectPrimitive]] = [:]
}

func boardMetalShouldRetainLinePrimitives(for owner: HorizontalSelectableRef) -> Bool {
    switch owner.type {
    case .track, .boardNetTie, .boardLine, .connectionLine:
        return true
    default:
        return false
    }
}

struct BoardMetalLineBatch {
    static let empty = BoardMetalLineBatch(
        triangleKey: 0,
        triangles: [],
        lineKey: 0,
        lines: [],
        handleKey: 0,
        handles: [],
        anchoredRectKey: 0,
        anchoredRects: [],
        metadata: BoardMetalSceneMetadata()
    )

    var triangleKey: Int
    var triangles: [HorizontalMetalTrianglePrimitive]
    var lineKey: Int
    var lines: [HorizontalMetalLinePrimitive]
    var handleKey: Int
    var handles: [HorizontalMetalHandlePrimitive]
    var anchoredRectKey: Int
    var anchoredRects: [HorizontalMetalAnchoredRectPrimitive]
    var metadata = BoardMetalSceneMetadata()

    var primitiveWeight: BoardMetalPrimitiveWeight {
        BoardMetalPrimitiveWeight(
            lines: lines.count,
            triangles: triangles.count,
            handles: handles.count,
            anchoredRects: anchoredRects.count
        )
    }
}

struct BoardMetalPrimitiveWeight {
    var lines = 0
    var triangles = 0
    var handles = 0
    var anchoredRects = 0

    var primitiveCount: Int {
        lines + triangles + handles + anchoredRects
    }

    var drawVertexCount: Int {
        lines * 6 + triangles * 3 + handles * 6 + anchoredRects * 6
    }

    mutating func add(_ other: BoardMetalPrimitiveWeight) {
        lines += other.lines
        triangles += other.triangles
        handles += other.handles
        anchoredRects += other.anchoredRects
    }
}

struct BoardMetalNamedPrimitiveWeight {
    var name: String
    var weight: BoardMetalPrimitiveWeight
}

struct BoardMetalTrianglePoints: Hashable {
    var a: HorizontalPoint
    var b: HorizontalPoint
    var c: HorizontalPoint
}

/// Identifies one poured plane fragment for the tessellation cache.
///
/// `contentHash` is what makes this a CONTENT address rather than a position:
/// two fragments with the same path and vertex counts are otherwise
/// indistinguishable, and a fill whose vertices moved would silently be served
/// another's triangles. Because the key changes whenever the geometry does, the
/// cache can survive edits that leave the planes alone — which is what stops the
/// fills blinking out on every unrelated commit while they re-tessellate.
struct BoardPlaneFragmentKey: Hashable {
    var planeID: String
    var fragmentIndex: Int
    var orphan: Bool
    var pathCount: Int
    var vertexCount: Int
    var contentHash: Int
}

struct BoardPlaneFragmentEntry {
    var key: BoardPlaneFragmentKey
    var fragment: HorizontalPlaneFragment
}

struct BoardMetalPlaneTriangleCacheKey: Hashable {
    var fragmentKey: BoardPlaneFragmentKey
    var color: HorizontalMetalRGBA
    var compositeGroup: Int
    var compositeOpacity: Float
}

struct BoardMetalPlaneOutlineCacheKey: Hashable {
    var fragmentKey: BoardPlaneFragmentKey
    var color: HorizontalMetalRGBA
    var width: Double
    var minimumWidth: Float
    var dashLength: Float
    var dashGap: Float
    var compositeGroup: Int
    var compositeOpacity: Float
}

typealias BoardPadOutlineFragmentsByLayer = Dictionary<Int?, [HorizontalPadOutlineFragment]>

// One batch per element-type bucket. Visibility flags are NOT consulted during
// the build; they only select which buckets are concatenated at draw time.
struct BoardMetalElementBatch {
    var lines: [HorizontalMetalLinePrimitive] = []
    var triangles: [HorizontalMetalTrianglePrimitive] = []
    var anchoredRects: [HorizontalMetalAnchoredRectPrimitive] = []
    var lineOwners: [HorizontalSelectableRef?] = []
    var triangleOwners: [HorizontalSelectableRef?] = []
    var anchoredRectOwners: [HorizontalSelectableRef?] = []
    /// World-space glyph height of the text each line segment was stroked from,
    /// parallel to `lines`; 0 for every non-text line. Populated by
    /// `BoardCanvasView.appendText` and consulted only by
    /// `filtered(minimumLabelSize:)`, which the concat step applies to the
    /// generated-label buckets so unreadable labels drop out when zoomed out.
    var lineLabelSizes: [Double] = []

    mutating func appendLine(
        _ primitive: HorizontalMetalLinePrimitive,
        owner: HorizontalSelectableRef? = nil,
        labelSize: Double = 0
    ) {
        lines.append(primitive)
        lineOwners.append(owner)
        lineLabelSizes.append(labelSize)
    }

    mutating func appendLines(
        _ primitives: [HorizontalMetalLinePrimitive],
        owner: HorizontalSelectableRef? = nil,
        labelSize: Double = 0
    ) {
        lines.append(contentsOf: primitives)
        lineOwners.append(contentsOf: Array(repeating: owner, count: primitives.count))
        lineLabelSizes.append(contentsOf: Array(repeating: labelSize, count: primitives.count))
    }

    /// Drops the label segments whose glyphs would render smaller than
    /// `minimumLabelSize` (world units) — per-primitive text LOD
    /// (`Canvas::set_lod_size` + the `lod_size_px` test in
    /// `triangle-glyph-geometry.glsl`), applied as a hard cull because our
    /// labels are stroked polylines drawn opaque; fading them per-label the way
    /// the GL canvas does would compound alpha where strokes overlap.
    /// Segments with a recorded size of 0 (everything that isn't generated
    /// label text) are never dropped.
    func filtered(minimumLabelSize: Double) -> BoardMetalElementBatch {
        guard minimumLabelSize > 0,
              lineLabelSizes.contains(where: { $0 > 0 && $0 < minimumLabelSize }) else {
            return self
        }

        var result = self
        result.lines = []
        result.lineOwners = []
        result.lineLabelSizes = []
        result.lines.reserveCapacity(lines.count)
        result.lineOwners.reserveCapacity(lines.count)
        result.lineLabelSizes.reserveCapacity(lines.count)

        for index in lines.indices {
            let labelSize = index < lineLabelSizes.count ? lineLabelSizes[index] : 0
            if labelSize > 0 && labelSize < minimumLabelSize {
                continue
            }
            result.lines.append(lines[index])
            result.lineOwners.append(index < lineOwners.count ? lineOwners[index] : nil)
            result.lineLabelSizes.append(labelSize)
        }
        return result
    }

    mutating func appendTriangle(_ primitive: HorizontalMetalTrianglePrimitive, owner: HorizontalSelectableRef? = nil) {
        triangles.append(primitive)
        triangleOwners.append(owner)
    }

    mutating func appendTriangles(_ primitives: [HorizontalMetalTrianglePrimitive], owner: HorizontalSelectableRef? = nil) {
        triangles.append(contentsOf: primitives)
        triangleOwners.append(contentsOf: Array(repeating: owner, count: primitives.count))
    }

    mutating func appendAnchoredRect(_ primitive: HorizontalMetalAnchoredRectPrimitive, owner: HorizontalSelectableRef? = nil) {
        anchoredRects.append(primitive)
        anchoredRectOwners.append(owner)
    }

    var primitiveWeight: BoardMetalPrimitiveWeight {
        BoardMetalPrimitiveWeight(
            lines: lines.count,
            triangles: triangles.count,
            anchoredRects: anchoredRects.count
        )
    }
}

// Element-type buckets. The build emits every primitive into one of these,
// and `boardMetalLineBatch` concatenates the visible ones based on the live
// displayOptions. Reference-typed so helper functions can mutate from nested
// closures without inout threading.
final class BoardMetalElementBuckets {
    var panels = BoardMetalElementBatch()
    var panelLabels = BoardMetalElementBatch()
    var origin = BoardMetalElementBatch()
    var bodyOutlineHigh = BoardMetalElementBatch()    // body polygon outlines, drawn when outline is on
    var bodyOutlineLow = BoardMetalElementBatch()     // body polygon outlines, drawn when only boardBody is on
    var bodyFill = BoardMetalElementBatch()           // body polygon fills (boardBody)
    var keepoutsAllCopper = BoardMetalElementBatch()  // gated additionally by !visibleCopperLayers().isEmpty
    var keepoutsPerLayer = BoardMetalElementBatch()
    var planes = BoardMetalElementBatch()
    var packagesGeometry = BoardMetalElementBatch()
    var packagesText = BoardMetalElementBatch()
    var packagesFallback = BoardMetalElementBatch()   // fallback labels + anchored rects for packages with no resolved geometry
    var decals = BoardMetalElementBatch()
    var alwaysOnLayered = BoardMetalElementBatch()    // per-layer board polygons (non-body), lines, arcs, tracks, netTies
    var pads = BoardMetalElementBatch()
    var padLabels = BoardMetalElementBatch()
    var vias = BoardMetalElementBatch()
    var viaLabels = BoardMetalElementBatch()
    var holesNone = BoardMetalElementBatch()          // outlines + fills for board.holes
    var holesPad = BoardMetalElementBatch()           // outlines + fills for packageHoles (gated by holes && pads)
    var holesVia = BoardMetalElementBatch()           // outlines + fills for viaHoles (gated by holes && vias)
    var text = BoardMetalElementBatch()
    var textPackagesAsText = BoardMetalElementBatch() // packageTexts when text is on but packages is off
    var trackLabels = BoardMetalElementBatch()
    var dimensions = BoardMetalElementBatch()
    var connectionLines = BoardMetalElementBatch()
    var connectionLabels = BoardMetalElementBatch()

    func namedBatches() -> [BoardMetalNamedPrimitiveWeight] {
        [
            .init(name: "panels", weight: panels.primitiveWeight),
            .init(name: "panel labels", weight: panelLabels.primitiveWeight),
            .init(name: "origin", weight: origin.primitiveWeight),
            .init(name: "body outline high", weight: bodyOutlineHigh.primitiveWeight),
            .init(name: "body outline low", weight: bodyOutlineLow.primitiveWeight),
            .init(name: "body fill", weight: bodyFill.primitiveWeight),
            .init(name: "all-copper keepouts", weight: keepoutsAllCopper.primitiveWeight),
            .init(name: "per-layer keepouts", weight: keepoutsPerLayer.primitiveWeight),
            .init(name: "planes", weight: planes.primitiveWeight),
            .init(name: "package geometry", weight: packagesGeometry.primitiveWeight),
            .init(name: "package text", weight: packagesText.primitiveWeight),
            .init(name: "package fallback", weight: packagesFallback.primitiveWeight),
            .init(name: "decals", weight: decals.primitiveWeight),
            .init(name: "layer polygons/lines/tracks", weight: alwaysOnLayered.primitiveWeight),
            .init(name: "pads", weight: pads.primitiveWeight),
            .init(name: "pad labels", weight: padLabels.primitiveWeight),
            .init(name: "vias", weight: vias.primitiveWeight),
            .init(name: "via labels", weight: viaLabels.primitiveWeight),
            .init(name: "board holes", weight: holesNone.primitiveWeight),
            .init(name: "package holes", weight: holesPad.primitiveWeight),
            .init(name: "via holes", weight: holesVia.primitiveWeight),
            .init(name: "board text", weight: text.primitiveWeight),
            .init(name: "package text as text", weight: textPackagesAsText.primitiveWeight),
            .init(name: "track labels", weight: trackLabels.primitiveWeight),
            .init(name: "dimensions", weight: dimensions.primitiveWeight),
            .init(name: "connection lines", weight: connectionLines.primitiveWeight),
            .init(name: "connection labels", weight: connectionLabels.primitiveWeight),
        ]
    }
}

struct BoardMetalElementBucketsCacheKey: Hashable {
    var boardID: String
    var revision: Int
    var tessellationVersion: Int
    var counts: [Int]
    var movePreview: BoardMovePreviewSignature?
    /// Non-nil while the clipboard ghost is being placed; rebuilds the buckets as
    /// the ghost follows the cursor.
    var pastePreview: BoardPastePreviewSignature? = nil
    /// Tracks hidden from the render while an autorouter route previews their
    /// removal (track repair / shove). Sorted ids; empty when not routing.
    var routePreviewRemoved: [String] = []
    var renderLayers: [Int]
    var layerColors: [HorizontalMetalRGBA]
    // NOTE: `layerOpacity` is intentionally NOT in this key. It is applied as a
    // live uniform at composite time so the slider drags don't rebuild the
    // primitive buckets. See HorizontalMetalBackdropView's composite pass.
    var layerFillModes: [Bool]
    var bodyOutlineHighColor: HorizontalMetalRGBA
    var bodyOutlineLowColor: HorizontalMetalRGBA
    var bodyFillColor: HorizontalMetalRGBA
    var panelColor: HorizontalMetalRGBA
    var keepoutStrokeColor: HorizontalMetalRGBA
    var keepoutFillColor: HorizontalMetalRGBA
    var originXColor: HorizontalMetalRGBA
    var originYColor: HorizontalMetalRGBA
    var originXLabelColor: HorizontalMetalRGBA
    var originYLabelColor: HorizontalMetalRGBA
    var panelLabelColor: HorizontalMetalRGBA
    var textOverlayColor: HorizontalMetalRGBA
    var dimensionColor: HorizontalMetalRGBA
    var connectionLineColor: HorizontalMetalRGBA
    var connectionLineDashColor: HorizontalMetalRGBA
    var airwireColor: HorizontalMetalRGBA
    var holeFillColor: HorizontalMetalRGBA
    var platedHoleStrokeColor: HorizontalMetalRGBA
    var unplatedHoleStrokeColor: HorizontalMetalRGBA
    var junctionColor: HorizontalMetalRGBA
    var topFallbackColor: HorizontalMetalRGBA
    var bottomFallbackColor: HorizontalMetalRGBA
}

struct BoardMetalLineBatchConcatKey: Hashable {
    var bucketsKey: BoardMetalElementBucketsCacheKey
    var visibilitySignature: BoardMetalVisibilitySignature
    var includesResidentMoveMetadata: Bool
}

func boardPlaneFragmentKey(
    planeID: String,
    fragmentIndex: Int,
    fragment: HorizontalPlaneFragment
) -> BoardPlaneFragmentKey {
    var hasher = Hasher()
    for path in fragment.paths {
        hasher.combine(path.count)
        for point in path {
            hasher.combine(point.x)
            hasher.combine(point.y)
        }
    }
    return BoardPlaneFragmentKey(
        planeID: planeID.lowercased(),
        fragmentIndex: fragmentIndex,
        orphan: fragment.orphan,
        pathCount: fragment.paths.count,
        vertexCount: fragment.paths.reduce(0) { $0 + $1.count },
        contentHash: hasher.finalize()
    )
}

// The subset of displayOptions and runtime state that determines which buckets
// participate in the concatenated batch. Layer-override visibility is handled
// separately via composite-group masking in the renderer, so it's not included.
struct BoardMetalVisibilitySignature: Hashable {
    var outline: Bool
    var panelLabels: Bool
    var origin: Bool
    var boardBody: Bool
    var keepouts: Bool
    var hasVisibleCopper: Bool
    var packages: Bool
    var decals: Bool
    var pads: Bool
    var padLabels: Bool
    var vias: Bool
    var viaLabels: Bool
    var holes: Bool
    var text: Bool
    var trackLabels: Bool
    var dimensions: Bool
    var connectionLines: Bool
    var connectionLabels: Bool
    /// Smallest world-space glyph height still legible at the current zoom;
    /// generated labels below it are culled from the pad/via/track buckets at
    /// concat time. Quantized (see `BoardCanvasView.minimumLegibleLabelSize`) so
    /// live zooming only re-concatenates when a step boundary is crossed, and
    /// carried in the signature so it is both the cache key and the value the
    /// filter uses — the two can never disagree. 0 disables culling.
    var minimumLabelSize: Double = 0
}

// Marked @unchecked Sendable so a detached Task can capture `self` to hop back
// to MainActor.run for cache writes. All mutations happen on the main thread —
// either directly from BoardCanvasView's body or inside MainActor.run after
// background tessellation finishes.
/// Defers the generated-label zoom cull until zooming stops.
///
/// The cull threshold has to be sampled from the LIVE canvas transform, which
/// changes every frame of a pinch. Applying it writes BoardCanvasView @State,
/// and that re-runs the (large) board body and re-concatenates the Metal
/// buckets — doing that mid-gesture is what made zooming lag.
///
/// So every field here is a plain stored property on a reference type:
/// mutating them invalidates no SwiftUI view, and the one @State write happens
/// after the transform has held still for `quietPeriod`. `schedule` is called
/// once per frame during a gesture, so it stays allocation-light — a single
/// waiter task is reused and its deadline pushed out rather than being
/// cancelled and respawned each frame.
///
/// ObservableObject only so a @StateObject can own it; it never publishes.
final class BoardLabelLODDebouncer: ObservableObject, @unchecked Sendable {
    private var task: Task<Void, Never>?
    private var pendingValue: Double?
    private var apply: ((Double) -> Void)?
    private var deadline: ContinuousClock.Instant?

    /// How long the transform must hold still before the new threshold lands.
    /// Long enough to sit out a pinch's frame-to-frame jitter, short enough that
    /// labels reappear promptly once the gesture ends.
    ///
    /// Injectable so tests can state their intent instead of racing the clock.
    /// A test for "nothing applies mid-gesture" that sleeps between frames is
    /// really asserting the machine schedules those sleeps promptly — which a
    /// loaded CI runner does not, and this test failed there for exactly that
    /// reason. With the period as a parameter, such a test asks for one long
    /// enough that no scheduling delay can reach it.
    private let quietPeriod: Duration

    init(quietPeriod: Duration = .milliseconds(160)) {
        self.quietPeriod = quietPeriod
    }

    /// Records the threshold for the current transform and (re)arms the quiet
    /// timer. Superseding `pendingValue` is also how a threshold that wanders
    /// away and comes back collapses into no work at all.
    func schedule(_ value: Double, apply: @escaping (Double) -> Void) {
        pendingValue = value
        self.apply = apply
        deadline = ContinuousClock().now.advanced(by: quietPeriod)

        guard task == nil else {
            return // the running waiter will observe the extended deadline
        }

        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while true {
                guard let self, let deadline = self.deadline else { break }
                if clock.now >= deadline { break }
                do {
                    try await Task.sleep(until: deadline, clock: clock)
                } catch {
                    self.task = nil
                    return
                }
            }
            self?.flush()
        }
    }

    private func flush() {
        task = nil
        deadline = nil
        guard let value = pendingValue, let apply else {
            return
        }
        pendingValue = nil
        apply(value)
    }
}

final class BoardSelectableCache: ObservableObject, @unchecked Sendable {
    private var allSelectablesKey: BoardAllSelectableCacheKey?
    private var allSelectablesValue = [HorizontalSelectable]()
    private let selectableSceneCache = HorizontalCanvasSelectableSceneCache<BoardSelectableCacheKey>()
    private var metalHighlightKey: BoardMetalHighlightCacheKey?
    private var metalHighlightValue = BoardMetalLineBatch.empty
    private var metalSelectionKey: BoardMetalSelectionCacheKey?
    private var metalSelectionValue = BoardMetalLineBatch.empty
    private var movePreviewKey: BoardMovePreviewCacheKey?
    private var movePreviewValue: HorizontalBoard?
    private var selectionDetailsKey: BoardSelectionDetailsCacheKey?
    private var selectionDetailsValue = HorizontalSelectionDetailState.empty
    private var planeFragmentTrianglePoints = [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]]()
    private var planeFragmentTriangles = [BoardMetalPlaneTriangleCacheKey: [HorizontalMetalTrianglePrimitive]]()
    private var planeFragmentOutlines = [BoardMetalPlaneOutlineCacheKey: [HorizontalMetalLinePrimitive]]()
    private var padOutlineFragmentsKey: BoardAllSelectableCacheKey?
    private var padOutlineFragmentsValue = BoardPadOutlineFragmentsByLayer()
    private var padLabelTextsKey: BoardAllSelectableCacheKey?
    private var padLabelTextsValue = [Int: [HorizontalText]]()
    private var visibleRenderLayersKey: BoardSelectableCacheKey?
    private var visibleRenderLayersValue = [Int]()
    private var metalRenderLayersKey: BoardAllSelectableCacheKey?
    private var metalRenderLayersValue = [Int]()
    private var elementBucketsKey: BoardMetalElementBucketsCacheKey?
    private var elementBucketsValue = BoardMetalElementBuckets()
    private var concatenatedLineBatchKey: BoardMetalLineBatchConcatKey?
    private var concatenatedLineBatchValue = BoardMetalLineBatch.empty
    /// Increments after a background tessellation pass completes. Body observes
    /// this via @Published, which invalidates the bucket cache (key includes the
    /// version) and triggers a SwiftUI re-render with the freshly-tessellated
    /// plane fills.
    @Published private(set) var tessellationVersion: Int = 0
    private var tessellationInProgress = false

    func allSelectables(
        key: BoardAllSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> [HorizontalSelectable] {
        if allSelectablesKey != key {
            allSelectablesValue = build()
            allSelectablesKey = key
        }
        return allSelectablesValue
    }

    func selectables(
        key: BoardSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> [HorizontalSelectable] {
        selectableSceneCache.selectables(key: key, build: build)
    }

    func selectableScene(
        key: BoardSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> HorizontalCanvasSelectableScene {
        selectableSceneCache.scene(key: key, build: build)
    }

    func snapTargets(
        key: BoardSelectableCacheKey,
        build: () -> [HorizontalPoint]
    ) -> [HorizontalPoint] {
        selectableSceneCache.snapTargets(key: key, build: build)
    }

    func metalHighlight(
        key: BoardMetalHighlightCacheKey,
        build: () -> BoardMetalLineBatch
    ) -> BoardMetalLineBatch {
        if metalHighlightKey != key {
            metalHighlightValue = build()
            metalHighlightKey = key
        }
        return metalHighlightValue
    }

    func metalSelection(
        key: BoardMetalSelectionCacheKey,
        build: () -> BoardMetalLineBatch
    ) -> BoardMetalLineBatch {
        if metalSelectionKey != key {
            metalSelectionValue = build()
            metalSelectionKey = key
        }
        return metalSelectionValue
    }

    func movePreview(
        key: BoardMovePreviewCacheKey,
        build: () -> HorizontalBoard
    ) -> HorizontalBoard {
        if movePreviewKey != key || movePreviewValue == nil {
            movePreviewValue = build()
            movePreviewKey = key
        }
        return movePreviewValue ?? build()
    }

    func selectionDetails(
        key: BoardSelectionDetailsCacheKey,
        build: () -> HorizontalSelectionDetailState
    ) -> HorizontalSelectionDetailState {
        if selectionDetailsKey != key {
            selectionDetailsValue = build()
            selectionDetailsKey = key
        }
        return selectionDetailsValue
    }

    func planeFragmentTrianglePoints(
        _ fragmentKey: BoardPlaneFragmentKey,
        build: () -> [BoardMetalTrianglePoints]
    ) -> [BoardMetalTrianglePoints] {
        if let cached = planeFragmentTrianglePoints[fragmentKey] {
            return cached
        }
        let value = build()
        planeFragmentTrianglePoints[fragmentKey] = value
        return value
    }

    func hasPlaneFragmentTrianglePoints(_ fragmentKey: BoardPlaneFragmentKey) -> Bool {
        planeFragmentTrianglePoints[fragmentKey] != nil
    }

    func setPlaneFragmentTrianglePoints(_ fragmentKey: BoardPlaneFragmentKey, _ value: [BoardMetalTrianglePoints]) {
        planeFragmentTrianglePoints[fragmentKey] = value
    }

    /// Kicks off a background pass that tessellates any plane fragments not yet
    /// in the cache. While that pass runs, `metalTrianglePoints(for:)` returns []
    /// for missing fragments — meaning the board paints right away without plane
    /// fills. When the pass completes, `tessellationVersion` increments, which
    /// invalidates the bucket cache (its key includes the version) and triggers
    /// a re-render that paints the fills. Subsequent calls during a pass are no-ops.
    func startBackgroundTessellation(planes: [HorizontalPlane]) {
        guard !tessellationInProgress else { return }
        var entries = [BoardPlaneFragmentEntry]()
        var seenKeys = Set<BoardPlaneFragmentKey>()
        for plane in planes {
            for (fragmentIndex, fragment) in plane.renderFragments.enumerated() {
                let key = boardPlaneFragmentKey(planeID: plane.id, fragmentIndex: fragmentIndex, fragment: fragment)
                seenKeys.insert(key)
                guard planeFragmentTrianglePoints[key] == nil else {
                    continue
                }
                if entries.contains(where: { $0.key == key }) {
                    continue
                }
                entries.append(BoardPlaneFragmentEntry(key: key, fragment: fragment))
            }
        }
        // Now that tessellation outlives an invalidate, a re-pour would otherwise
        // leave every previous fill's triangles in memory for good.
        retainPlaneFragments(keys: seenKeys)
        guard !entries.isEmpty else { return }

        // Sort biggest-first so heavy fragments occupy workers from the start
        // and lighter ones backfill — improves load balancing under
        // DispatchQueue.concurrentPerform.
        let fragments = entries.sorted { lhs, rhs in
            lhs.key.vertexCount > rhs.key.vertexCount
        }
        tessellationInProgress = true
        let count = fragments.count

        Task.detached(priority: .userInitiated) {
            // Give body #1 + the first Metal buffer upload a clean CPU window
            // before launching workers. Without this, the tessellation Task
            // contends with main-thread work on the perf cores during initial
            // paint, which roughly doubles body #1's wall time. 80 ms is enough
            // for body #1 to finish on most boards we've measured.
            try? await Task.sleep(nanoseconds: 80_000_000)
            let results = await withTaskGroup(of: (Int, [BoardMetalTrianglePoints]).self) { group -> [[BoardMetalTrianglePoints]] in
                for index in 0..<count {
                    let entry = fragments[index]
                    group.addTask {
                        let clear = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 0)
                        let points = HorizontalMetalTessellator.triangles(for: entry.fragment.paths, color: clear).map {
                            BoardMetalTrianglePoints(a: $0.a, b: $0.b, c: $0.c)
                        }
                        return (index, points)
                    }
                }
                var collected = Array<[BoardMetalTrianglePoints]>(repeating: [], count: count)
                for await (index, points) in group {
                    collected[index] = points
                }
                return collected
            }

            await MainActor.run {
                for index in fragments.indices {
                    self.planeFragmentTrianglePoints[fragments[index].key] = results[index]
                }
                // Bust the per-(fragment, color) caches: prior to tessellation
                // they were populated with [] because metalTrianglePoints returned
                // empty. Without clearing, the bucket rebuild after the version
                // bump would still hit those stale empty entries.
                self.planeFragmentTriangles.removeAll(keepingCapacity: true)
                self.planeFragmentOutlines.removeAll(keepingCapacity: true)
                self.tessellationInProgress = false
                self.tessellationVersion &+= 1
            }
        }
    }

    func planeFragmentTriangles(
        key: BoardMetalPlaneTriangleCacheKey,
        build: () -> [HorizontalMetalTrianglePrimitive]
    ) -> [HorizontalMetalTrianglePrimitive] {
        if let cached = planeFragmentTriangles[key] {
            return cached
        }
        let value = build()
        planeFragmentTriangles[key] = value
        return value
    }

    func planeFragmentOutlines(
        key: BoardMetalPlaneOutlineCacheKey,
        build: () -> [HorizontalMetalLinePrimitive]
    ) -> [HorizontalMetalLinePrimitive] {
        if let cached = planeFragmentOutlines[key] {
            return cached
        }
        let value = build()
        planeFragmentOutlines[key] = value
        return value
    }

    func padOutlineFragments(
        key: BoardAllSelectableCacheKey,
        build: () -> BoardPadOutlineFragmentsByLayer
    ) -> BoardPadOutlineFragmentsByLayer {
        if padOutlineFragmentsKey != key {
            padOutlineFragmentsValue = build()
            padOutlineFragmentsKey = key
        }
        return padOutlineFragmentsValue
    }

    func padLabelTexts(
        key: BoardAllSelectableCacheKey,
        build: () -> [Int: [HorizontalText]]
    ) -> [Int: [HorizontalText]] {
        if padLabelTextsKey != key {
            padLabelTextsValue = build()
            padLabelTextsKey = key
        }
        return padLabelTextsValue
    }

    func visibleRenderLayers(
        key: BoardSelectableCacheKey,
        build: () -> [Int]
    ) -> [Int] {
        if visibleRenderLayersKey != key {
            visibleRenderLayersValue = build()
            visibleRenderLayersKey = key
        }
        return visibleRenderLayersValue
    }

    func metalRenderLayers(
        key: BoardAllSelectableCacheKey,
        build: () -> [Int]
    ) -> [Int] {
        if metalRenderLayersKey != key {
            metalRenderLayersValue = build()
            metalRenderLayersKey = key
        }
        return metalRenderLayersValue
    }

    func elementBuckets(
        key: BoardMetalElementBucketsCacheKey,
        build: () -> BoardMetalElementBuckets
    ) -> BoardMetalElementBuckets {
        if elementBucketsKey != key {
            elementBucketsValue = build()
            elementBucketsKey = key
            concatenatedLineBatchKey = nil
            concatenatedLineBatchValue = .empty
        }
        return elementBucketsValue
    }

    func concatenatedLineBatch(
        key: BoardMetalLineBatchConcatKey,
        build: () -> BoardMetalLineBatch
    ) -> BoardMetalLineBatch {
        if concatenatedLineBatchKey != key {
            concatenatedLineBatchValue = build()
            concatenatedLineBatchKey = key
        }
        return concatenatedLineBatchValue
    }

    /// Drops tessellated fills for fragments the board no longer has.
    private func retainPlaneFragments(keys: Set<BoardPlaneFragmentKey>) {
        guard !keys.isEmpty else { return }
        planeFragmentTrianglePoints = planeFragmentTrianglePoints.filter { keys.contains($0.key) }
        // These two are keyed by the fragment PLUS its styling, so filter on the
        // fragment they belong to.
        planeFragmentTriangles = planeFragmentTriangles.filter { keys.contains($0.key.fragmentKey) }
        planeFragmentOutlines = planeFragmentOutlines.filter { keys.contains($0.key.fragmentKey) }
    }

    func invalidate(preservesMetalScene: Bool = false) {
        allSelectablesKey = nil
        allSelectablesValue = []
        selectableSceneCache.invalidate()
        metalHighlightKey = nil
        metalHighlightValue = .empty
        metalSelectionKey = nil
        metalSelectionValue = .empty
        movePreviewKey = nil
        movePreviewValue = nil
        selectionDetailsKey = nil
        selectionDetailsValue = .empty
        padOutlineFragmentsKey = nil
        padOutlineFragmentsValue = BoardPadOutlineFragmentsByLayer()
        padLabelTextsKey = nil
        padLabelTextsValue = [:]
        visibleRenderLayersKey = nil
        visibleRenderLayersValue = []
        metalRenderLayersKey = nil
        metalRenderLayersValue = []
        if !preservesMetalScene {
            // Plane tessellation deliberately survives: its keys are content
            // addresses, so a fill that changed cannot be served a stale
            // triangulation, and one that did not change should not have to be
            // re-tessellated. Dropping it here is what made the planes blink out
            // on every commit — a move does not touch a single fragment, but the
            // fills rendered empty until the background pass caught up.
            // `retainPlaneFragments` evicts what is genuinely gone.
            elementBucketsKey = nil
            elementBucketsValue = BoardMetalElementBuckets()
            concatenatedLineBatchKey = nil
            concatenatedLineBatchValue = .empty
        }
    }
}

