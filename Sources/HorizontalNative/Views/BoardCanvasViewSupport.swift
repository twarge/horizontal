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

/// The highlight is the board's own scene build over just what is
/// highlighted, so it is keyed as the scene is: by the buckets' key and the
/// visibility signature (which carries the label cull's threshold), and by
/// the layers shown.
struct BoardMetalHighlightCacheKey: Hashable {
    /// The scene the highlight is drawn from: the board scene's composite
    /// group keys when it has them, which change only with what it draws (so
    /// a move's preview that changes nothing highlighted keeps the batch),
    /// else its bucket key.
    var bucketsKey: BoardMetalElementBucketsCacheKey?
    var sceneGroupKeys: [Int: Int]?
    var renderLayers: [Int]
    var visibilitySignature: BoardMetalVisibilitySignature
    var visibleCompositeGroups: Set<Int>
    var highlightedNetIDs: [String]
    var highlightedComponentIDs: [String]
    /// "As is": nothing dims, so what is highlighted is drawn lighter.
    var lightens: Bool
}

/// What a highlight draws again over the dimmed board: everything on the
/// highlighted nets, and the highlighted components' packages whole, as a
/// board of its own that the scene build draws as it draws the board. So a
/// highlight changes nothing it shows, as Horizon's Dim other doesn't; it
/// dims the rest. The board outline, panels, dimensions and decals are left
/// out, carrying no net. Ids are compared lowercased.
enum BoardHighlightSubset {
    static func board(
        _ board: HorizontalBoard,
        netIDs: Set<String>,
        componentIDs: Set<String>
    ) -> HorizontalBoard {
        func onNet(_ netID: String?) -> Bool {
            guard let netID else {
                return false
            }
            return netIDs.contains(netID.lowercased())
        }

        var subset = board
        subset.packages = board.packages.filter { package in
            package.componentID.map { componentIDs.contains($0.lowercased()) } ?? false
        }
        let packageIDs = Set(subset.packages.map { $0.id.lowercased() })
        func inPackage(_ geometryID: String) -> Bool {
            guard !packageIDs.isEmpty,
                  let packageID = BoardMovePlanner.packageID(forGeometryID: geometryID) else {
                return false
            }
            return packageIDs.contains(packageID)
        }

        subset.packagePads = board.packagePads.filter { onNet($0.netID) || inPackage($0.id) }
        subset.packageHoles = board.packageHoles.filter { onNet($0.netID) || inPackage($0.id) }
        subset.packagePolygons = board.packagePolygons.filter { inPackage($0.id) }
        subset.packageLines = board.packageLines.filter { inPackage($0.id) }
        subset.packageArcs = board.packageArcs.filter { inPackage($0.id) }
        subset.packageTexts = board.packageTexts.filter { onNet($0.netID) || inPackage($0.id) }
        subset.keepouts = board.keepouts.filter { inPackage($0.id) }
        subset.tracks = board.tracks.filter { onNet($0.netID) }
        subset.netTies = board.netTies.filter { onNet($0.netID) }
        subset.lines = board.lines.filter { onNet($0.netID) }
        subset.arcs = board.arcs.filter { onNet($0.netID) }
        subset.connectionLines = board.connectionLines.filter { onNet($0.netID) }
        subset.airwires = board.airwires.filter { onNet($0.netID) }
        subset.polygons = board.polygons.filter {
            onNet($0.netID) && !($0.layer.map(HorizontalBoardLayers.isOutline) ?? false)
        }
        subset.planes = board.planes.filter { onNet($0.netID) }
        subset.vias = board.vias.filter { onNet($0.netID) }
        // A via's drill goes with the via (`HorizontalBoard.viaHoleID(ofVia:)`).
        let viaIDs = Set(subset.vias.map { $0.id.lowercased() })
        subset.viaHoles = board.viaHoles.filter {
            onNet($0.netID) || HorizontalBoard.viaID(ofViaHole: $0.id).map { viaIDs.contains($0.lowercased()) } == true
        }
        subset.holes = board.holes.filter { onNet($0.netID) }
        subset.texts = board.texts.filter { onNet($0.netID) }
        subset.dimensions = []
        subset.decals = []
        subset.boardPanels = []
        subset.pads = []
        subset.padstackShapes = []
        return subset
    }
}

/// Horizon's text owner annotation (ImpBoard::update_text_owner_annotation):
/// a line from each selected smashed text's origin to its package's origin,
/// and from a selected package's origin to each of its smashed texts that
/// shows, so a text dragged away from its part still says whose it is.
enum BoardTextOwnerLines {
    struct Line: Hashable {
        var text: HorizontalPoint
        var package: HorizontalPoint
    }

    static func lines(
        in board: HorizontalBoard,
        selectedRefs: [HorizontalSelectableRef],
        showsText: (HorizontalText) -> Bool
    ) -> [Line] {
        var textIDs = Set<String>()
        var packageIDs = Set<String>()
        for ref in selectedRefs {
            switch ref.type {
            case .text:
                textIDs.insert(ref.id.lowercased())
            case .boardPackage:
                packageIDs.insert(ref.id.lowercased())
            default:
                break
            }
        }
        guard !textIDs.isEmpty || !packageIDs.isEmpty else {
            return []
        }

        // Only a smashed text is board text with a package: the package's own
        // texts go with it and are never selected alone.
        var owned = [(text: HorizontalText, packageID: String)]()
        for text in board.packageTexts where text.fromSmash {
            guard let packageID = BoardMovePlanner.packageID(forGeometryID: text.id) else {
                continue
            }
            if textIDs.contains(text.id.lowercased())
                || (packageIDs.contains(packageID) && showsText(text)) {
                owned.append((text, packageID))
            }
        }
        guard !owned.isEmpty else {
            return []
        }

        let ownerIDs = Set(owned.map(\.packageID))
        var origins = [String: HorizontalPoint]()
        for package in board.packages {
            let id = package.id.lowercased()
            if ownerIDs.contains(id) {
                origins[id] = package.position
            }
        }
        return owned.compactMap { text, packageID in
            guard let origin = origins[packageID], origin != text.position else {
                return nil
            }
            return Line(text: text.position, package: origin)
        }
    }
}

struct BoardMetalSelectionCacheKey: Hashable {
    var selectableKey: BoardSelectableCacheKey
    /// Non-nil while a non-patchable move is in progress, so the selection
    /// overlay rebuilds (follows the dragged object) instead of returning the
    /// cached pre-move box.
    var movePreview: BoardMovePreviewSignature? = nil
    /// True while a move that is patched in Metal is under way, whose batch
    /// keeps the tracks it reshapes apart (`BoardMetalMovingTrackOutlines`).
    var patchesMove = false
    var selectedRefs: [HorizontalSelectableRef]
    var hoveredRef: HorizontalSelectableRef?
    var selectedOuterColor: HorizontalMetalRGBA
    var selectedInnerColor: HorizontalMetalRGBA
    var selectedHandleInnerColor: HorizontalMetalRGBA
    var selectedGroupPreviewColor: HorizontalMetalRGBA
    var hoverOuterColor: HorizontalMetalRGBA
    var hoverInnerColor: HorizontalMetalRGBA
    /// These batches emit generated net labels too, and cull them by zoom the
    /// same way the main build does. The threshold is part of the key so a
    /// cached batch is never reused across a zoom step that changes which
    /// labels are legible.
    var minimumLabelSize: Double
    var handleShape: HorizontalSelectionHandleShape
    /// Settings' width for a smashed text's line to its package.
    var smashedConnectionLineMinimumWidth: Float
}

struct BoardMovePreviewCacheKey: Hashable {
    var boardID: String
    var revision: Int
    var counts: [Int]
    var selectedRefs: [HorizontalSelectableRef]
    var startPoint: HorizontalPoint
    var lastPoint: HorizontalPoint
    /// How many times R or T has turned the move (122): each turn restarts the
    /// points, so they alone could name a preview from before it.
    var turns = 0
}

struct BoardMovePreviewSignature: Hashable {
    var selectedRefs: [HorizontalSelectableRef]
    var startPoint: HorizontalPoint
    var lastPoint: HorizontalPoint
    /// As `BoardMovePreviewCacheKey.turns`.
    var turns = 0
}

/// Names the texts a turn during a move redraws: the scene whose lines they
/// replace, and the turn (122).
struct BoardTurnedMoveTextsKey: Hashable {
    var lineKey: Int
    var turns: Int
    var placement: HorizontalPlacementTransform
}

/// Where one text's strokes sit in the resident scene, so a turn during a move
/// can redraw them as a rebuilt scene would (122): a quarter turn can carry a
/// text into or out of the angles it is drawn the other way round at, and pad
/// labels settle on their own readable angle, so turning the strokes with
/// the rest of the part is not always what the scene would show.
struct BoardMetalTextSpan: Hashable {
    /// The `HorizontalText.id` the strokes were drawn from.
    var textID: String
    var compositeGroup: Int
    var start: Int
    var count: Int
    /// The first stroke's index in the scene's `lines`, whose style the
    /// redrawn strokes keep.
    var lineIndex: Int
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

/// What the selection marks (`BoardSelectionVertices`) is looked up on every
/// hover, so it is kept per scene and selection.
struct BoardSelectionVerticesCacheKey: Hashable {
    var selectableKey: BoardSelectableCacheKey
    var selectedRefs: [HorizontalSelectableRef]
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
    /// The texts among each owner's line spans, one entry per text.
    var textSpansByRef: [HorizontalSelectableRef: [BoardMetalTextSpan]] = [:]
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
    /// A selection batch's outlines of the tracks a move redraws rather than
    /// shifts, last among its lines and handles.
    var movingTrackOutlines: BoardMetalMovingTrackOutlines?
    /// Per composite group, a key that changes only when the group's
    /// primitives do; nil when the scene can't tell (every group uploads).
    var groupKeys: [Int: Int]?

    var primitiveWeight: BoardMetalPrimitiveWeight {
        BoardMetalPrimitiveWeight(
            lines: lines.count,
            triangles: triangles.count,
            handles: handles.count,
            anchoredRects: anchoredRects.count
        )
    }
}

/// The tail of a selection batch that a move draws afresh at each step, from
/// where it has taken the tracks' ends (`BoardMovingTrackOutlines`), in the
/// style the batch drew them with: its last `lineCount` lines and
/// `handleCount` handles.
struct BoardMetalMovingTrackOutlines {
    var outlines: BoardMovingTrackOutlines
    var style: HorizontalCanvasSelectionOverlayStyle
    var lineCount: Int
    var handleCount: Int
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

/// One text's strokes in a `BoardMetalElementBatch`: its id, and the lines it
/// was stroked into.
struct BoardMetalTextRun: Equatable {
    var textID: String
    var lineStart: Int
    var lineCount: Int
}

// One batch per element-type bucket. Visibility flags are NOT consulted during
// the build; they only select which buckets are concatenated at draw time.
struct BoardMetalElementBatch: Equatable {
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
    /// Each text stroked into `lines` by `BoardCanvasView.appendText`, in
    /// order, so the concat step can tell a move which of an owner's lines
    /// are which text (122).
    var textRuns: [BoardMetalTextRun] = []

    mutating func appendLine(
        _ primitive: HorizontalMetalLinePrimitive,
        owner: HorizontalSelectableRef? = nil,
        labelSize: Double = 0
    ) {
        lines.append(primitive)
        lineOwners.append(owner)
        lineLabelSizes.append(labelSize)
    }

    mutating func append(contentsOf other: BoardMetalElementBatch) {
        let lineOffset = lines.count
        textRuns.append(contentsOf: other.textRuns.map { run in
            var run = run
            run.lineStart += lineOffset
            return run
        })
        lines.append(contentsOf: other.lines)
        triangles.append(contentsOf: other.triangles)
        anchoredRects.append(contentsOf: other.anchoredRects)
        lineOwners.append(contentsOf: other.lineOwners)
        triangleOwners.append(contentsOf: other.triangleOwners)
        anchoredRectOwners.append(contentsOf: other.anchoredRectOwners)
        lineLabelSizes.append(contentsOf: other.lineLabelSizes)
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
        result.textRuns = []
        result.lines.reserveCapacity(lines.count)
        result.lineOwners.reserveCapacity(lines.count)
        result.lineLabelSizes.reserveCapacity(lines.count)

        // A text's strokes share its size, so a run is kept or dropped whole.
        var runIndex = 0
        for index in lines.indices {
            let labelSize = index < lineLabelSizes.count ? lineLabelSizes[index] : 0
            while runIndex < textRuns.count, textRuns[runIndex].lineStart < index {
                runIndex += 1
            }
            if labelSize > 0 && labelSize < minimumLabelSize {
                continue
            }
            if runIndex < textRuns.count, textRuns[runIndex].lineStart == index {
                var run = textRuns[runIndex]
                run.lineStart = result.lines.count
                result.textRuns.append(run)
            }
            result.lines.append(lines[index])
            result.lineOwners.append(index < lineOwners.count ? lineOwners[index] : nil)
            result.lineLabelSizes.append(labelSize)
        }
        return result
    }

    /// Drops the airwires of `netIDs` (lowercased net uuids) for the airwire
    /// filter: the lines drawn under a net's `airwire/<net>` owner, which the
    /// scene gives its airwires and nothing else. Applied at concat time, as
    /// the label cull is, so a change to the filter rebuilds no buckets.
    func filtered(hidingAirwiresOf netIDs: Set<String>) -> BoardMetalElementBatch {
        let prefix = "airwire/"
        func hides(_ owner: HorizontalSelectableRef?) -> Bool {
            guard let owner, owner.type == .connectionLine, owner.id.hasPrefix(prefix) else {
                return false
            }
            return netIDs.contains(String(owner.id.dropFirst(prefix.count)))
        }
        guard !netIDs.isEmpty, lineOwners.contains(where: hides) else {
            return self
        }

        var result = self
        result.lines = []
        result.lineOwners = []
        result.lineLabelSizes = []
        result.textRuns = []
        result.lines.reserveCapacity(lines.count)
        result.lineOwners.reserveCapacity(lines.count)
        result.lineLabelSizes.reserveCapacity(lines.count)

        var runIndex = 0
        for index in lines.indices {
            let owner = index < lineOwners.count ? lineOwners[index] : nil
            while runIndex < textRuns.count, textRuns[runIndex].lineStart < index {
                runIndex += 1
            }
            if hides(owner) {
                continue
            }
            if runIndex < textRuns.count, textRuns[runIndex].lineStart == index {
                var run = textRuns[runIndex]
                run.lineStart = result.lines.count
                result.textRuns.append(run)
            }
            result.lines.append(lines[index])
            result.lineOwners.append(owner)
            result.lineLabelSizes.append(index < lineLabelSizes.count ? lineLabelSizes[index] : 0)
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
    /// The airwires `connectionLines` was drawn from, so the scene can say
    /// which it shows without reading its primitives back.
    var airwires: [HorizontalSegment] = []
    /// For a full build, per bucket and composite group, a stamp of what the
    /// group's primitives in it were drawn from, which changes when they do
    /// (`BoardSceneObjectCache`). Nil for a partial build (a highlight's
    /// subset) or a verifying one, which don't use the cache.
    var groupStamps: [BoardSceneBucket: [Int: Int]]?

    /// Every batch, for whole-scene operations. `namedBatches()` lists the
    /// same batches; a test keeps the two the same length.
    static var batchKeyPaths: [ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>] {
        [
            \.panels, \.panelLabels, \.origin, \.bodyOutlineHigh, \.bodyOutlineLow, \.bodyFill,
            \.keepoutsAllCopper, \.keepoutsPerLayer, \.planes, \.packagesGeometry, \.packagesText,
            \.packagesFallback, \.decals, \.alwaysOnLayered, \.pads, \.padLabels, \.vias, \.viaLabels,
            \.holesNone, \.holesPad, \.holesVia, \.text, \.textPackagesAsText, \.trackLabels,
            \.dimensions, \.connectionLines, \.connectionLabels,
        ]
    }

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

/// When the board canvas re-clips its silkscreen: a new board, the mode
/// switched, a changed clearance in the board's silkscreen rule, or a plane
/// pour (Q). Edits in between leave the clip alone.
struct BoardSilkscreenClipTrigger: Equatable {
    var boardID: String
    var clipping: HorizontalSilkscreenClipping?
    /// The rule the clearance comes from, nil while the mode is off.
    var rule: HorizontalRuleClearanceSilkscreenExposedCopper?
    var planePourRevision: Int
}

struct BoardTrackSnapTargetsKey: Hashable {
    var selectables: BoardSelectableCacheKey
    var layer: Int
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
    /// The clip-silkscreen-to-mask mode in force when the buckets were built.
    var silkscreenClipping: HorizontalSilkscreenClipping? = nil
    /// `BoardSelectableCache.silkscreenClipVersion`: a refreshed clip rebuilds.
    var silkscreenClipVersion: Int = 0
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
    /// Settings' width for airwires and connection lines, baked into their
    /// primitives, so a change rebuilds.
    var connectionLineMinimumWidth: Float
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
    BoardPlaneFragmentKey(
        planeID: planeID.lowercased(),
        fragmentIndex: fragmentIndex,
        orphan: fragment.orphan,
        pathCount: fragment.paths.count,
        vertexCount: fragment.paths.reduce(0) { $0 + $1.count },
        contentHash: fragment.contentHash
    )
}

/// One plane fragment as the triangles its fill is drawn with, uncoloured.
/// What the canvas's background tessellation makes, and what a pour makes
/// ahead of handing its fills over, so the two always agree.
func boardPlaneFragmentTrianglePoints(_ fragment: HorizontalPlaneFragment) -> [BoardMetalTrianglePoints] {
    let clear = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 0)
    return HorizontalMetalTessellator.triangles(for: fragment.paths, color: clear).map {
        BoardMetalTrianglePoints(a: $0.a, b: $0.b, c: $0.c)
    }
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
    /// The nets the airwire filter hides (`BoardDisplayOptions.hiddenAirwireNetIDs`),
    /// taken out of the connection lines at concat time; a change to it makes
    /// a new scene key, and so a new upload and composite.
    var hiddenAirwireNetIDs: Set<String> = []
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

    /// Set while the canvas has no area, from `canvasHasNoArea` until the next
    /// `schedule`.
    private var isWithoutArea = false

    init(quietPeriod: Duration = .milliseconds(160)) {
        self.quietPeriod = quietPeriod
    }

    /// The canvas has no area, as a pane kept mounted while hidden has none.
    /// Its transform then fits the board into the one point its clamped fit
    /// leaves, a threshold past which every label would be culled, so it
    /// schedules nothing: the threshold stays the one it was shown at, and the
    /// labels stay built for when it is shown again.
    func canvasHasNoArea() {
        isWithoutArea = true
    }

    /// Records the threshold for the current transform and (re)arms the quiet
    /// timer. Superseding `pendingValue` is also how a threshold that wanders
    /// away and comes back collapses into no work at all.
    ///
    /// The first threshold after the canvas had no area lands at once: being
    /// shown is no gesture to sit out, and the labels come up with the pane.
    func schedule(_ value: Double, apply: @escaping (Double) -> Void) {
        self.apply = apply
        if isWithoutArea {
            isWithoutArea = false
            // A waiter still running finds no deadline and applies nothing.
            pendingValue = nil
            deadline = nil
            apply(value)
            return
        }
        pendingValue = value
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

    /// Pushes pending LOD work back as soon as a new viewport event arrives.
    /// This closes the short gap before the throttled live transform reaches
    /// SwiftUI and calls `schedule` with its next sampled threshold.
    func postponeForViewportMovement() {
        guard pendingValue != nil else {
            return
        }
        deadline = ContinuousClock().now.advanced(by: quietPeriod)
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
    private var selectionVerticesKey: BoardSelectionVerticesCacheKey?
    private var selectionVerticesValue = HorizontalSelectableSpatialIndex([])
    private var planeFragmentTrianglePoints = [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]]()
    private var planeFragmentTriangles = [BoardMetalPlaneTriangleCacheKey: [HorizontalMetalTrianglePrimitive]]()
    private var planeFragmentOutlines = [BoardMetalPlaneOutlineCacheKey: [HorizontalMetalLinePrimitive]]()
    /// Survives `invalidate`: its entries are keyed by pad shape, so an edit
    /// re-merges only the pads it touched.
    let padOutlineUnionCache = HorizontalPadOutlineUnionCache()
    /// What the scene build works out from the board's content (the pads'
    /// outlines and labels, the packages with geometry), kept while that
    /// content is unchanged. Survives `invalidate`, as its inputs are the
    /// content itself rather than a revision.
    let contentMemo = BoardContentMemo()
    /// What each object of the last scene build drew, which the next build
    /// replays for what is unchanged. Survives `invalidate`: it compares
    /// content, not revisions.
    let sceneObjects = BoardSceneObjectCache()
    private var legibleLabelBatches = [String: (key: Int, batch: BoardMetalElementBatch)]()
    private var trackSnapTargetsKey: BoardTrackSnapTargetsKey?
    private var trackSnapTargetsValue = [HorizontalPoint]()
    private var visibleRenderLayersKey: BoardSelectableCacheKey?
    private var visibleRenderLayersValue = [Int]()
    private var metalRenderLayersKey: BoardAllSelectableCacheKey?
    private var metalRenderLayersValue = [Int]()
    private var elementBucketsKey: BoardMetalElementBucketsCacheKey?
    private var elementBucketsValue = BoardMetalElementBuckets()
    private var concatenatedLineBatchKey: BoardMetalLineBatchConcatKey?
    private var concatenatedLineBatchValue = BoardMetalLineBatch.empty
    /// What each of these held before its last rebuild or `invalidate`. After
    /// an edit SwiftUI can still render once with the state from before it,
    /// its transaction not yet applied. With one slot, that pass threw away
    /// the scene built for the edit and rebuilt the old board, and the next
    /// pass rebuilt the new one: two whole-board builds per placement click.
    /// The keys carry the scene revision, so an old key only ever matches what
    /// was built for it.
    private var previousElementBuckets: (key: BoardMetalElementBucketsCacheKey, value: BoardMetalElementBuckets)?
    private var previousConcatenatedLineBatch: (key: BoardMetalLineBatchConcatKey, value: BoardMetalLineBatch)?
    private var previousAllSelectables: (key: BoardAllSelectableCacheKey, value: [HorizontalSelectable])?
    /// Increments after a background tessellation pass completes. Body observes
    /// this via @Published, which invalidates the bucket cache (key includes the
    /// version) and triggers a SwiftUI re-render with the freshly-tessellated
    /// plane fills.
    @Published private(set) var tessellationVersion: Int = 0
    private var tessellationInProgress = false
    /// What the clip-silkscreen-to-mask mode draws from on the board. Clipping
    /// every silkscreen object against every mask opening was the heaviest
    /// part of a scene build, and redoing it per edit made each cursor step of
    /// a package placement cost seconds. So, like the plane fills beside it, it
    /// is refreshed only when asked (on load, when the clearance changes, when
    /// the planes are poured), on a background task. In between, an object
    /// whose own geometry changed draws unclipped (its stored fragments are no
    /// longer where it is); the rest keep their last clip until the next
    /// refresh.
    private var silkscreenClipsValue = [Int: HorizontalClippedSilkscreenLayer]()
    private var silkscreenClipsClipping: HorizontalSilkscreenClipping?
    private var silkscreenClipRequest = 0
    /// Increments when a refresh lands; the bucket cache key carries it, so the
    /// scene is rebuilt once with the new clip.
    @Published private(set) var silkscreenClipVersion: Int = 0
    /// The live rats' nest of the move in progress
    /// (`HorizontalBoard.MovingAirwires`), made off the main thread when the
    /// move starts; until it lands the move shows the airwires as they were.
    private var movingAirwiresRequest = 0
    private var movingAirwiresValue: (request: Int, airwires: HorizontalBoard.MovingAirwires)?
    private var movingAirwireSegmentsRequest: Int?
    private var movingAirwireSegmentsPlacement = HorizontalPlacementTransform.identity
    private var movingAirwireSegmentsValue = [HorizontalSegment]()
    /// The texts a turn during a move redraws (122), for the scene and turn
    /// they were made for; the move then only shifts them.
    private var turnedMoveTextsKey: BoardTurnedMoveTextsKey?
    private var turnedMoveTextsValue = [HorizontalMetalLineBufferPatch]()
    /// Increments when a move's live rats' nest lands, so the canvas redraws.
    @Published private(set) var movingAirwiresVersion: Int = 0

    func allSelectables(
        key: BoardAllSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> [HorizontalSelectable] {
        if allSelectablesKey != key {
            let replaced = allSelectablesKey.map { (key: $0, value: allSelectablesValue) }
            if let previousAllSelectables, previousAllSelectables.key == key {
                allSelectablesValue = previousAllSelectables.value
            } else {
                allSelectablesValue = build()
            }
            allSelectablesKey = key
            previousAllSelectables = replaced ?? previousAllSelectables
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

    func selectableScene(
        key: BoardSelectableCacheKey,
        buildScene: () -> HorizontalCanvasSelectableScene
    ) -> HorizontalCanvasSelectableScene {
        selectableSceneCache.scene(key: key, buildScene: buildScene)
    }

    func snapTargets(
        key: BoardSelectableCacheKey,
        build: () -> [HorizontalPoint]
    ) -> [HorizontalPoint] {
        selectableSceneCache.snapTargets(key: key, build: build)
    }

    /// The track tool's snap targets, the copper on the layer it routes on
    /// (`BoardTrackRouting.snapTargets`), built once per board and layer.
    func trackSnapTargets(
        key: BoardTrackSnapTargetsKey,
        build: () -> [HorizontalPoint]
    ) -> [HorizontalPoint] {
        if trackSnapTargetsKey != key {
            trackSnapTargetsValue = build()
            trackSnapTargetsKey = key
        }
        return trackSnapTargetsValue
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

    /// A label bucket culled to the zoom's legible size, under a key of the
    /// bucket's stamps and the size.
    func legibleLabels(_ name: String, key: Int, build: () -> BoardMetalElementBatch) -> BoardMetalElementBatch {
        if let stored = legibleLabelBatches[name], stored.key == key {
            return stored.batch
        }
        let batch = build()
        legibleLabelBatches[name] = (key, batch)
        return batch
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

    func selectionVertices(
        key: BoardSelectionVerticesCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> HorizontalSelectableSpatialIndex {
        if selectionVerticesKey != key {
            selectionVerticesValue = HorizontalSelectableSpatialIndex(build())
            selectionVerticesKey = key
        }
        return selectionVerticesValue
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
                        (index, boardPlaneFragmentTrianglePoints(entry.fragment))
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

    /// Starts making a move's live rats' nest and returns the request the
    /// move keeps, to find it with once it lands.
    func requestMovingAirwires(_ make: @escaping @Sendable () -> HorizontalBoard.MovingAirwires) -> Int {
        movingAirwiresRequest &+= 1
        let request = movingAirwiresRequest
        movingAirwiresValue = nil
        movingAirwireSegmentsRequest = nil
        movingAirwireSegmentsValue = []
        Task.detached(priority: .userInitiated) {
            let airwires = make()
            await MainActor.run {
                guard request == self.movingAirwiresRequest else {
                    return
                }
                self.movingAirwiresValue = (request, airwires)
                self.movingAirwiresVersion &+= 1
            }
        }
        return request
    }

    /// The live rats' nest for `request`, once it has landed.
    func movingAirwires(for request: Int) -> HorizontalBoard.MovingAirwires? {
        guard let movingAirwiresValue, movingAirwiresValue.request == request else {
            return nil
        }
        return movingAirwiresValue.airwires
    }

    /// The live airwires with the moving copper where `placement` puts it —
    /// the move's offset from its start, and any turn made on the way —
    /// remembered for the placement last asked about, since several body
    /// passes see each one.
    func movingAirwireSegments(for request: Int, placement: HorizontalPlacementTransform) -> [HorizontalSegment]? {
        guard let airwires = movingAirwires(for: request) else {
            return nil
        }
        if movingAirwireSegmentsRequest != request || movingAirwireSegmentsPlacement != placement {
            movingAirwireSegmentsValue = airwires.airwires(placement: placement)
            movingAirwireSegmentsRequest = request
            movingAirwireSegmentsPlacement = placement
        }
        return movingAirwireSegmentsValue
    }

    /// The redrawn texts of a turn during a move, made once per turn and
    /// scene rather than on every body pass.
    func turnedMoveTexts(
        key: BoardTurnedMoveTextsKey,
        build: () -> [HorizontalMetalLineBufferPatch]
    ) -> [HorizontalMetalLineBufferPatch] {
        if turnedMoveTextsKey != key {
            turnedMoveTextsValue = build()
            turnedMoveTextsKey = key
        }
        return turnedMoveTextsValue
    }

    /// The last refreshed clip, if it was made with `clipping`. After the
    /// board's rule changes its clearance, the clip at the old one is served
    /// until its replacement is computed.
    func silkscreenClips(for clipping: HorizontalSilkscreenClipping) -> [Int: HorizontalClippedSilkscreenLayer] {
        silkscreenClipsClipping == clipping ? silkscreenClipsValue : [:]
    }

    /// Clips `board`'s silkscreen off the main thread and publishes the result.
    /// A newer request supersedes one still running.
    func refreshSilkscreenClips(board: HorizontalBoard, clipping: HorizontalSilkscreenClipping?) {
        silkscreenClipRequest &+= 1
        let request = silkscreenClipRequest
        guard let clipping else {
            if silkscreenClipsClipping != nil || !silkscreenClipsValue.isEmpty {
                silkscreenClipsValue = [:]
                silkscreenClipsClipping = nil
                silkscreenClipVersion &+= 1
            }
            return
        }
        Task.detached(priority: .userInitiated) {
            let clips = HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
            await MainActor.run {
                guard request == self.silkscreenClipRequest else {
                    return
                }
                self.silkscreenClipsValue = clips
                self.silkscreenClipsClipping = clipping
                self.silkscreenClipVersion &+= 1
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
            let replaced = elementBucketsKey.map { (key: $0, value: elementBucketsValue) }
            if let previousElementBuckets, previousElementBuckets.key == key {
                elementBucketsValue = previousElementBuckets.value
            } else {
                elementBucketsValue = build()
            }
            elementBucketsKey = key
            previousElementBuckets = replaced ?? previousElementBuckets
        }
        return elementBucketsValue
    }

    func concatenatedLineBatch(
        key: BoardMetalLineBatchConcatKey,
        build: () -> BoardMetalLineBatch
    ) -> BoardMetalLineBatch {
        if concatenatedLineBatchKey != key {
            let replaced = concatenatedLineBatchKey.map { (key: $0, value: concatenatedLineBatchValue) }
            if let previousConcatenatedLineBatch, previousConcatenatedLineBatch.key == key {
                concatenatedLineBatchValue = previousConcatenatedLineBatch.value
            } else {
                concatenatedLineBatchValue = build()
            }
            concatenatedLineBatchKey = key
            previousConcatenatedLineBatch = replaced ?? previousConcatenatedLineBatch
        }
        return concatenatedLineBatchValue
    }

    /// Drops tessellated fills for fragments the board no longer has.
    /// Takes a pour's fills without a rebuild of the scene: their triangles
    /// join the tessellation cache, the triangles of fills no longer on the
    /// board leave it, and the overlays drawn from the fills (net highlight,
    /// selection) are made again on their next use.
    func takePlaneFills(triangles: [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]], keeping keys: Set<BoardPlaneFragmentKey>) {
        for (key, points) in triangles {
            planeFragmentTrianglePoints[key] = points
        }
        retainPlaneFragments(keys: keys)
        metalHighlightKey = nil
        metalHighlightValue = .empty
        metalSelectionKey = nil
        metalSelectionValue = .empty
    }

    private func retainPlaneFragments(keys: Set<BoardPlaneFragmentKey>) {
        guard !keys.isEmpty else { return }
        planeFragmentTrianglePoints = planeFragmentTrianglePoints.filter { keys.contains($0.key) }
        // These two are keyed by the fragment PLUS its styling, so filter on the
        // fragment they belong to.
        planeFragmentTriangles = planeFragmentTriangles.filter { keys.contains($0.key.fragmentKey) }
        planeFragmentOutlines = planeFragmentOutlines.filter { keys.contains($0.key.fragmentKey) }
    }

    func invalidate() {
        if let allSelectablesKey {
            previousAllSelectables = (allSelectablesKey, allSelectablesValue)
        }
        allSelectablesKey = nil
        allSelectablesValue = []
        selectableSceneCache.invalidate()
        metalHighlightKey = nil
        metalHighlightValue = .empty
        metalSelectionKey = nil
        metalSelectionValue = .empty
        movePreviewKey = nil
        movePreviewValue = nil
        turnedMoveTextsKey = nil
        turnedMoveTextsValue = []
        selectionDetailsKey = nil
        selectionDetailsValue = .empty
        selectionVerticesKey = nil
        selectionVerticesValue = HorizontalSelectableSpatialIndex([])
        visibleRenderLayersKey = nil
        visibleRenderLayersValue = []
        metalRenderLayersKey = nil
        metalRenderLayersValue = []
        // Plane tessellation deliberately survives: its keys are content
        // addresses, so a fill that changed cannot be served a stale
        // triangulation, and one that did not change should not have to be
        // re-tessellated. Dropping it here is what made the planes blink out
        // on every commit — a move does not touch a single fragment, but the
        // fills rendered empty until the background pass caught up.
        // `retainPlaneFragments` evicts what is genuinely gone.
        if let elementBucketsKey {
            previousElementBuckets = (elementBucketsKey, elementBucketsValue)
        }
        if let concatenatedLineBatchKey {
            previousConcatenatedLineBatch = (concatenatedLineBatchKey, concatenatedLineBatchValue)
        }
        elementBucketsKey = nil
        elementBucketsValue = BoardMetalElementBuckets()
        concatenatedLineBatchKey = nil
        concatenatedLineBatchValue = .empty
    }
}


/// Values worked out from board content, each kept under a name with the
/// content it came from and handed back while the content is `==` to it.
/// Arrays and strings compare in constant time when their storage is the
/// same, which it is for content an edit didn't touch, so a hit costs little
/// more than the lookup; content that did change is compared element by
/// element, still far cheaper than what is derived from it.
final class BoardContentMemo {
    private var slots = [String: (input: Any, value: Any)]()

    func value<Input: Equatable, Value>(_ name: String, input: Input, build: () -> Value) -> Value {
        if let slot = slots[name], let stored = slot.input as? Input, stored == input, let value = slot.value as? Value {
            return value
        }
        let value = build()
        slots[name] = (input, value)
        return value
    }

    func removeAll() {
        slots.removeAll()
    }
}

/// Two pieces of content a memo or a scene section is derived from.
struct BoardContentPair<First: Equatable, Second: Equatable>: Equatable {
    var first: First
    var second: Second

    init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}

/// Three pieces of content.
struct BoardContentTriple<First: Equatable, Second: Equatable, Third: Equatable>: Equatable {
    var first: First
    var second: Second
    var third: Third

    init(_ first: First, _ second: Second, _ third: Third) {
        self.first = first
        self.second = second
        self.third = third
    }
}


/// Checks a scene built with the caches against one built without them, so a
/// dependency a cache missed shows up as a difference rather than as stale
/// drawing. Off unless `HORIZONTAL_VERIFY_SCENE=1` or a test turns it on; each
/// build it checks costs a second, uncached build.
enum BoardSceneVerifier {
    nonisolated(unsafe) static var isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["HORIZONTAL_VERIFY_SCENE"] == "1"
        #else
        false
        #endif
    }()
    /// Each difference found, described; a test reads and clears it.
    nonisolated(unsafe) static var mismatches = [String]()
    /// How many builds were checked.
    nonisolated(unsafe) static var comparisons = 0

    static func compare(_ cached: BoardMetalElementBuckets, with fresh: BoardMetalElementBuckets) {
        comparisons += 1
        let names = cached.namedBatches().map(\.name)
        for (index, keyPath) in BoardMetalElementBuckets.batchKeyPaths.enumerated() {
            let lhs = cached[keyPath: keyPath]
            let rhs = fresh[keyPath: keyPath]
            guard lhs != rhs else {
                continue
            }
            let description = "\(names[index]): \(difference(lhs, rhs))"
            mismatches.append(description)
            print("Horizontal scene verifier: \(description)")
        }
        if cached.airwires != fresh.airwires {
            let description = "airwires: \(cached.airwires.count) cached, \(fresh.airwires.count) fresh"
            mismatches.append(description)
            print("Horizontal scene verifier: \(description)")
        }
    }

    /// A reshape drag's preview, made by editing just the reshaped
    /// polygons, against `moveSelectedObjects`' whole-board one.
    static func compareReshapePreview(_ reshaped: HorizontalBoard, with moved: HorizontalBoard) {
        comparisons += 1
        for (name, same) in [
            ("polygons", reshaped.polygons == moved.polygons),
            ("planes", reshaped.planes == moved.planes),
            ("keepouts", reshaped.keepouts == moved.keepouts),
            ("tracks", reshaped.tracks == moved.tracks),
            ("junctions", reshaped.junctions == moved.junctions),
        ] where !same {
            let description = "reshape preview: \(name) differ from a whole-board move"
            mismatches.append(description)
            print("Horizontal scene verifier: \(description)")
        }
    }

    private static func difference(_ lhs: BoardMetalElementBatch, _ rhs: BoardMetalElementBatch) -> String {
        func first<T: Equatable>(_ name: String, _ a: [T], _ b: [T], owners: [HorizontalSelectableRef?]? = nil) -> String? {
            guard a != b else {
                return nil
            }
            let index = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            let owner = owners.flatMap { index < $0.count ? $0[index] : nil }.map { " (\($0.type) \($0.id))" } ?? ""
            return "\(name) differ at \(index) of \(a.count) cached / \(b.count) fresh\(owner)"
        }
        return first("lines", lhs.lines, rhs.lines, owners: lhs.lineOwners)
            ?? first("line owners", lhs.lineOwners, rhs.lineOwners, owners: lhs.lineOwners)
            ?? first("triangles", lhs.triangles, rhs.triangles, owners: lhs.triangleOwners)
            ?? first("triangle owners", lhs.triangleOwners, rhs.triangleOwners, owners: lhs.triangleOwners)
            ?? first("anchored rects", lhs.anchoredRects, rhs.anchoredRects, owners: lhs.anchoredRectOwners)
            ?? first("anchored rect owners", lhs.anchoredRectOwners, rhs.anchoredRectOwners)
            ?? first("label sizes", lhs.lineLabelSizes, rhs.lineLabelSizes)
            ?? first("text runs", lhs.textRuns, rhs.textRuns)
            ?? "differ"
    }
}


/// What decides whether a board selectable shows, beyond its ref
/// (`BoardCanvasView.selectableVisibility`).
struct BoardSelectableVisibility: Equatable {
    var keepoutAllCopperByID: [String: Bool]
    var keepoutAllCopperByPolygonID: [String: Bool]
    var planePolygonIDs: Set<String>
    var visibleCopperLayers: Set<Int>
    var visibleDecalIDs: Set<String>
    var visibleViaIDs: Set<String>
    var visiblePackageIDs: Set<String>
    var hiddenJunctionIDs: Set<String>
}

/// One kind of board selectable: all of them, the visible ones, and those by
/// ref (`BoardCanvasView.boardSelectableCategories`).
struct BoardSelectableCategory {
    var all: [HorizontalSelectable]
    var visible: [HorizontalSelectable]
    var byRef: [HorizontalSelectableRef: [HorizontalSelectable]]
    /// The hit-test index over `visible`, built when first asked for and kept
    /// with the category.
    var index: () -> HorizontalSelectableSpatialIndex
}
