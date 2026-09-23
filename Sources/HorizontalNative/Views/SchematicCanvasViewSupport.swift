import Foundation
import SwiftUI

struct SchematicSelectableCacheKey: Hashable {
    var sheetID: String
    var revision: Int
    var displayOptions: SchematicDisplayOptions
    var counts: [Int]
}

struct JunctionRenderInfo {
    var connectionCount = 0
    var connectionKeys = Set<String>()
    var hasAttachment = false
    var isIsolated = false
    var netID: String?

    mutating func addConnections(_ count: Int, key: String?) {
        guard count > 0 else {
            return
        }
        if let key {
            if connectionKeys.insert(key).inserted {
                connectionCount += count
            }
        } else {
            connectionCount += count
        }
    }
}

struct SchematicRenderAnalysis {
    var isolatedNetLineIDs: Set<String>
    var junctionRenderInfo: [String: JunctionRenderInfo]
}

struct SchematicMetalLineCacheKey: Hashable {
    var sheetID: String
    var revision: Int
    var displayOptions: SchematicDisplayOptions
    var counts: [Int]
    var frameColor: HorizontalMetalRGBA
    var drawingColor: HorizontalMetalRGBA
    var symbolColor: HorizontalMetalRGBA
    var pinColor: HorizontalMetalRGBA
    var pinAnnotationColor: HorizontalMetalRGBA
    var netColor: HorizontalMetalRGBA
    var netTieColor: HorizontalMetalRGBA
    var isolatedColor: HorizontalMetalRGBA
    var busColor: HorizontalMetalRGBA
    var junctionColor: HorizontalMetalRGBA
    var errorColor: HorizontalMetalRGBA
    var originColor: HorizontalMetalRGBA
    var noPopulateColor: HorizontalMetalRGBA
    var generalTextColor: HorizontalMetalRGBA
    var fillsNetLabelBackground: Bool
    var fillsClosedSymbolBackground: Bool
}

struct SchematicMetalPrimitiveSpan: Hashable {
    var compositeGroup: Int
    var start: Int
    var count: Int
}

struct SchematicMetalSceneMetadata {
    var lineSpansByRef: [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]] = [:]
    var triangleSpansByRef: [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]] = [:]
    var anchoredRectSpansByRef: [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]] = [:]
    var linePrimitivesByRef: [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]] = [:]
    var trianglePrimitivesByRef: [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]] = [:]
    var anchoredRectPrimitivesByRef: [HorizontalSelectableRef: [HorizontalMetalAnchoredRectPrimitive]] = [:]
}

func schematicMetalSymbolID(forGeometryID geometryID: String) -> String? {
    let separators: Set<String> = [
        "arc",
        "line",
        "nopopulate",
        "pin",
        "pin-connector",
        "pin-connector-text",
        "pin-decoration",
        "pin-direction",
        "pin-name",
        "pin-name-hidden",
        "pin-pad",
        "pin-pad-hidden",
        "polygon",
        "text"
    ]
    let components = geometryID.lowercased().split(separator: "/").map(String.init)
    guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
          separatorIndex > components.startIndex else {
        return nil
    }
    return components[..<separatorIndex].joined(separator: "/")
}

func schematicMetalObjectIDPrefix(in geometryID: String, separators: Set<String>) -> String? {
    let components = geometryID.lowercased().split(separator: "/").map(String.init)
    guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
          separatorIndex > components.startIndex else {
        return nil
    }
    return components[..<separatorIndex].joined(separator: "/")
}

let schematicPowerSymbolGeometrySeparators: Set<String> = [
    "antenna",
    "circle",
    "dot",
    "earth",
    "gnd",
    "line",
    "power-name",
    "text"
]

struct SchematicMetalHighlightCacheKey: Hashable {
    var selectableKey: SchematicSelectableCacheKey
    var highlightedNetIDs: [String]
    var highlightedComponentIDs: [String]
    var highlightColor: HorizontalMetalRGBA
    var symbolColor: HorizontalMetalRGBA
    var pinColor: HorizontalMetalRGBA
    var pinAnnotationColor: HorizontalMetalRGBA
    var backgroundColor: HorizontalMetalRGBA
}

struct SchematicMetalSelectionCacheKey: Hashable {
    var selectableKey: SchematicSelectableCacheKey
    var selectedRefs: [HorizontalSelectableRef]
    var hoveredRef: HorizontalSelectableRef?
    var selectedOuterColor: HorizontalMetalRGBA
    var selectedInnerColor: HorizontalMetalRGBA
    var selectedHandleInnerColor: HorizontalMetalRGBA
    var hoverOuterColor: HorizontalMetalRGBA
    var hoverInnerColor: HorizontalMetalRGBA
    var handleShape: HorizontalSelectionHandleShape
}

struct SchematicMovePreviewCacheKey: Hashable {
    var selectableKey: SchematicSelectableCacheKey
    var selectedRefs: [HorizontalSelectableRef]
    var startPoint: HorizontalPoint
    var lastPoint: HorizontalPoint
}

struct SchematicSelectionDetailsCacheKey: Hashable {
    var selectableKey: SchematicSelectableCacheKey
    var selectedRefs: [HorizontalSelectableRef]
    var selectedUnplacedObjectID: String?
}

struct SchematicMetalLineBatch {
    static let empty = SchematicMetalLineBatch(
        triangleKey: 0,
        triangles: [],
        lineKey: 0,
        lines: [],
        handleKey: 0,
        handles: [],
        anchoredRectKey: 0,
        anchoredRects: []
    )

    var triangleKey: Int
    var triangles: [HorizontalMetalTrianglePrimitive]
    var lineKey: Int
    var lines: [HorizontalMetalLinePrimitive]
    var handleKey: Int
    var handles: [HorizontalMetalHandlePrimitive]
    var anchoredRectKey: Int
    var anchoredRects: [HorizontalMetalAnchoredRectPrimitive]
    var metadata = SchematicMetalSceneMetadata()
}

/// One sheet's render and hit-test caches. Every entry is single-slot: the
/// key names the sheet, revision and display state it was built for.
final class SchematicSheetRenderCache {
    private let selectableSceneCache = HorizontalCanvasSelectableSceneCache<SchematicSelectableCacheKey>()
    private var renderAnalysisKey: SchematicSelectableCacheKey?
    private var renderAnalysisValue: SchematicRenderAnalysis?
    private var metalLinesKey: SchematicMetalLineCacheKey?
    private var metalLinesValue = [HorizontalMetalLinePrimitive]()
    private var metalLineSpansValue = [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]]()
    private var metalLinePrimitivesByRefValue = [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]]()
    private var metalTrianglesKey: SchematicMetalLineCacheKey?
    private var metalTrianglesValue = [HorizontalMetalTrianglePrimitive]()
    private var metalTriangleSpansValue = [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]]()
    private var metalTrianglePrimitivesByRefValue = [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]]()
    private var metalHighlightKey: SchematicMetalHighlightCacheKey?
    private var metalHighlightValue = SchematicMetalLineBatch.empty
    private var metalSelectionKey: SchematicMetalSelectionCacheKey?
    private var metalSelectionValue = SchematicMetalLineBatch.empty
    private var movePreviewKey: SchematicMovePreviewCacheKey?
    private var movePreviewValue: HorizontalSchematicSheet?
    private var selectionDetailsKey: SchematicSelectionDetailsCacheKey?
    private var selectionDetailsValue = HorizontalSelectionDetailState.empty

    func selectableScene(
        key: SchematicSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> HorizontalCanvasSelectableScene {
        selectableSceneCache.scene(key: key, build: build)
    }

    func selectables(
        key: SchematicSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> [HorizontalSelectable] {
        selectableSceneCache.selectables(key: key, build: build)
    }

    func snapTargets(
        key: SchematicSelectableCacheKey,
        build: () -> [HorizontalPoint]
    ) -> [HorizontalPoint] {
        selectableSceneCache.snapTargets(key: key, build: build)
    }

    func renderAnalysis(
        key: SchematicSelectableCacheKey,
        build: () -> SchematicRenderAnalysis
    ) -> SchematicRenderAnalysis {
        if renderAnalysisKey != key || renderAnalysisValue == nil {
            renderAnalysisValue = build()
            renderAnalysisKey = key
        }
        return renderAnalysisValue ?? build()
    }

    func metalLines(
        key: SchematicMetalLineCacheKey,
        build: () -> ([HorizontalMetalLinePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]])
    ) -> ([HorizontalMetalLinePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]]) {
        if metalLinesKey != key {
            let result = build()
            metalLinesValue = result.0
            metalLineSpansValue = result.1
            metalLinePrimitivesByRefValue = result.2
            metalLinesKey = key
        }
        return (metalLinesValue, metalLineSpansValue, metalLinePrimitivesByRefValue)
    }

    func metalTriangles(
        key: SchematicMetalLineCacheKey,
        build: () -> ([HorizontalMetalTrianglePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]])
    ) -> ([HorizontalMetalTrianglePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]]) {
        if metalTrianglesKey != key {
            let result = build()
            metalTrianglesValue = result.0
            metalTriangleSpansValue = result.1
            metalTrianglePrimitivesByRefValue = result.2
            metalTrianglesKey = key
        }
        return (metalTrianglesValue, metalTriangleSpansValue, metalTrianglePrimitivesByRefValue)
    }

    func metalHighlight(
        key: SchematicMetalHighlightCacheKey,
        build: () -> SchematicMetalLineBatch
    ) -> SchematicMetalLineBatch {
        if metalHighlightKey != key {
            metalHighlightValue = build()
            metalHighlightKey = key
        }
        return metalHighlightValue
    }

    func metalSelection(
        key: SchematicMetalSelectionCacheKey,
        build: () -> SchematicMetalLineBatch
    ) -> SchematicMetalLineBatch {
        if metalSelectionKey != key {
            metalSelectionValue = build()
            metalSelectionKey = key
        }
        return metalSelectionValue
    }

    func movePreview(
        key: SchematicMovePreviewCacheKey,
        build: () -> HorizontalSchematicSheet
    ) -> HorizontalSchematicSheet {
        if movePreviewKey != key || movePreviewValue == nil {
            movePreviewValue = build()
            movePreviewKey = key
        }
        return movePreviewValue ?? build()
    }

    func selectionDetails(
        key: SchematicSelectionDetailsCacheKey,
        build: () -> HorizontalSelectionDetailState
    ) -> HorizontalSelectionDetailState {
        if selectionDetailsKey != key {
            selectionDetailsValue = build()
            selectionDetailsKey = key
        }
        return selectionDetailsValue
    }

    func invalidate() {
        selectableSceneCache.invalidate()
        renderAnalysisKey = nil
        renderAnalysisValue = nil
        metalLinesKey = nil
        metalLinesValue = []
        metalLineSpansValue = [:]
        metalLinePrimitivesByRefValue = [:]
        metalTrianglesKey = nil
        metalTrianglesValue = []
        metalTriangleSpansValue = [:]
        metalTrianglePrimitivesByRefValue = [:]
        metalHighlightKey = nil
        metalHighlightValue = .empty
        metalSelectionKey = nil
        metalSelectionValue = .empty
        movePreviewKey = nil
        movePreviewValue = nil
        selectionDetailsKey = nil
        selectionDetailsValue = .empty
    }

    func invalidateInteraction() {
        selectableSceneCache.invalidate()
        renderAnalysisKey = nil
        renderAnalysisValue = nil
        metalHighlightKey = nil
        metalHighlightValue = .empty
        metalSelectionKey = nil
        metalSelectionValue = .empty
        movePreviewKey = nil
        movePreviewValue = nil
        selectionDetailsKey = nil
        selectionDetailsValue = .empty
    }
}

/// The render and hit-test caches of every sheet this canvas has shown, so
/// flipping back to a page reuses its scene rather than rebuilding it. A page
/// that changed while it was away (an undo, the live channel, a reload) is
/// told apart by its content fingerprint and built again.
final class SchematicSelectableCache: ObservableObject {
    private struct Entry {
        var cache = SchematicSheetRenderCache()
        /// The content the caches were built from, taken when the canvas
        /// left the sheet; nil while it is the one being drawn.
        var fingerprint: Int?
        var selectableRevision: Int
        var metalRevision: Int
    }

    /// Sheets kept warm. A page's scene is a few megabytes at most.
    private static let capacity = 32

    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var activeSheet: HorizontalSchematicSheet?
    /// Revisions are unique across sheets, so a cache key (and the Metal
    /// buffer key hashed from it) never repeats for different content.
    private var nextRevision = 1

    /// Called at the top of every body pass with the sheet being drawn.
    func activate(_ sheet: HorizontalSchematicSheet) {
        defer { activeSheet = sheet }
        guard sheet.id != activeSheet?.id else {
            return
        }
        if let previous = activeSheet, entries[previous.id] != nil {
            entries[previous.id]?.fingerprint = previous.renderFingerprint
        }
        if let entry = entries[sheet.id], let fingerprint = entry.fingerprint {
            if fingerprint != sheet.renderFingerprint {
                entries[sheet.id] = nil
            } else {
                entries[sheet.id]?.fingerprint = nil
            }
        }
        touch(sheet.id)
    }

    func selectableRevision(for sheetID: String) -> Int {
        entry(for: sheetID).selectableRevision
    }

    func metalRevision(for sheetID: String) -> Int {
        entry(for: sheetID).metalRevision
    }

    func selectableScene(
        key: SchematicSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> HorizontalCanvasSelectableScene {
        cache(for: key.sheetID).selectableScene(key: key, build: build)
    }

    func selectables(
        key: SchematicSelectableCacheKey,
        build: () -> [HorizontalSelectable]
    ) -> [HorizontalSelectable] {
        cache(for: key.sheetID).selectables(key: key, build: build)
    }

    func snapTargets(
        key: SchematicSelectableCacheKey,
        build: () -> [HorizontalPoint]
    ) -> [HorizontalPoint] {
        cache(for: key.sheetID).snapTargets(key: key, build: build)
    }

    func renderAnalysis(
        key: SchematicSelectableCacheKey,
        build: () -> SchematicRenderAnalysis
    ) -> SchematicRenderAnalysis {
        cache(for: key.sheetID).renderAnalysis(key: key, build: build)
    }

    func metalLines(
        key: SchematicMetalLineCacheKey,
        build: () -> ([HorizontalMetalLinePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]])
    ) -> ([HorizontalMetalLinePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]]) {
        cache(for: key.sheetID).metalLines(key: key, build: build)
    }

    func metalTriangles(
        key: SchematicMetalLineCacheKey,
        build: () -> ([HorizontalMetalTrianglePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]])
    ) -> ([HorizontalMetalTrianglePrimitive], [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]], [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]]) {
        cache(for: key.sheetID).metalTriangles(key: key, build: build)
    }

    func metalHighlight(
        key: SchematicMetalHighlightCacheKey,
        build: () -> SchematicMetalLineBatch
    ) -> SchematicMetalLineBatch {
        cache(for: key.selectableKey.sheetID).metalHighlight(key: key, build: build)
    }

    func metalSelection(
        key: SchematicMetalSelectionCacheKey,
        build: () -> SchematicMetalLineBatch
    ) -> SchematicMetalLineBatch {
        cache(for: key.selectableKey.sheetID).metalSelection(key: key, build: build)
    }

    func movePreview(
        key: SchematicMovePreviewCacheKey,
        build: () -> HorizontalSchematicSheet
    ) -> HorizontalSchematicSheet {
        cache(for: key.selectableKey.sheetID).movePreview(key: key, build: build)
    }

    func selectionDetails(
        key: SchematicSelectionDetailsCacheKey,
        build: () -> HorizontalSelectionDetailState
    ) -> HorizontalSelectionDetailState {
        cache(for: key.selectableKey.sheetID).selectionDetails(key: key, build: build)
    }

    /// The sheet was edited: everything built for it goes.
    func invalidate(sheetID: String) {
        var entry = entry(for: sheetID)
        entry.cache.invalidate()
        entry.selectableRevision = takeRevision()
        entry.metalRevision = takeRevision()
        entries[sheetID] = entry
    }

    /// An interaction changed hit-testing but not the drawn scene.
    func invalidateInteraction(sheetID: String) {
        var entry = entry(for: sheetID)
        entry.cache.invalidateInteraction()
        entry.selectableRevision = takeRevision()
        entries[sheetID] = entry
    }

    private func cache(for sheetID: String) -> SchematicSheetRenderCache {
        entry(for: sheetID).cache
    }

    private func entry(for sheetID: String) -> Entry {
        if let entry = entries[sheetID] {
            return entry
        }
        let entry = Entry(selectableRevision: takeRevision(), metalRevision: takeRevision())
        entries[sheetID] = entry
        touch(sheetID)
        return entry
    }

    private func takeRevision() -> Int {
        defer { nextRevision &+= 1 }
        return nextRevision
    }

    private func touch(_ sheetID: String) {
        recency.removeAll { $0 == sheetID }
        recency.append(sheetID)
        while recency.count > Self.capacity {
            let evicted = recency.removeFirst()
            if evicted == activeSheet?.id {
                recency.append(evicted)
                continue
            }
            entries[evicted] = nil
        }
    }
}
