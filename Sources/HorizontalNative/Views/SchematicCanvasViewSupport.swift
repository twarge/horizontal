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
        "pin",
        "pin-connector",
        "pin-connector-text",
        "pin-decoration",
        "pin-direction",
        "pin-name",
        "pin-pad",
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

final class SchematicSelectableCache: ObservableObject {
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

