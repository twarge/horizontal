import Foundation
import SwiftUI
struct SchematicCanvasView: View {
    // The in-canvas selection popover stays off on both platforms: macOS uses its
    // right inspector sidebar and iOS uses the right-side slide-over inspector
    // (HorizontalInspectorSidebar) instead.
    static let showsInCanvasSelectionInspector = false
    private static let junctionDotRadiusWorld = 375_000.0
    private static let terminalCrossHalfSizeWorld = 250_000.0
    private static let junctionHighlightPaddingWorld = 180_000.0
    private static let minimumJunctionDotRadius: CGFloat = 0.75
    private static let quarterTurnAngle = -16_384
    private static let noNetClassChoiceID = "none"

    private struct MoveState {
        var startPoint: HorizontalPoint
        var lastPoint: HorizontalPoint
        var originalSheet: HorizontalSchematicSheet
        var undoSheet: HorizontalSchematicSheet
        var editedSheetBeforeMove: HorizontalSchematicSheet?
        var tracksCursor: Bool
        var snapTargets: [HorizontalPoint]?
        var connectionPlan = SchematicSymbolMoveConnectionPlan()
        var connectionMovePlan = SchematicConnectionMovePlan()
        var fixedConnectionPointKeys = Set<String>()
        /// Set when this move is the place-the-text-then-edit flow (macOS "Add
        /// Text"). On commit, the canvas opens the inline text editor for this
        /// ref instead of registering a "Move" undo — the placement is one
        /// undoable step ("Add Text"), finalized only when real content is typed.
        var editTextRefOnCommit: String? = nil
    }

    #if os(macOS)
    /// In-flight inline text edit (macOS "Add Text"): a placeholder `HorizontalText`
    /// has been placed and anchored, and a popover lets the user type its content
    /// with a LIVE canvas re-render on each keystroke. `preSheet` is the sheet
    /// snapshot from *before* the text was added, so a cancelled placement (empty
    /// or untouched `"Text"`) reverts to a true no-op and the single "Add Text"
    /// undo entry is registered only when real content commits.
    private struct EditTextState {
        let ref: String
        let worldPosition: HorizontalPoint
        var content: String
        let preSheet: HorizontalSchematicSheet
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

    private enum AttachedPowerSymbolTransform {
        case translatedBy(HorizontalPoint)
        case mirroredAround(HorizontalPoint)
        case rotatedAround(HorizontalPoint, by: Int)
    }

    private struct NetSegmentSelectionState: Identifiable, Equatable {
        var id = UUID()
        var pointKeys: Set<String>
        var refs: [HorizontalSelectableRef]
        var currentNetID: String
        var currentNetName: String
        var anchor: HorizontalPoint
        var powerOnly: Bool
        var hasPowerSymbol: Bool
        var hasBusRipper: Bool
        var hasPins: Bool
    }

    private struct PlacePartState {
        var requestID: UUID
        var originalSheet: HorizontalSchematicSheet
        var symbolID: String
        var actionName: String
    }

    /// Symbol editor: a unit pin following the cursor until a click places it.
    private struct PlacePinState {
        var originalSheet: HorizontalSchematicSheet
        var pinID: String
    }

    private enum DrawNetLineBendMode {
        case xy
        case yx
    }

    private struct DrawNetLineState {
        var originalSheet: HorizontalSchematicSheet
        var anchor: HorizontalPoint?
        var anchorJunctionID: String?
        var netID: String?
        var cursor: HorizontalPoint?
        var bendMode: DrawNetLineBendMode = .xy
        var segmentCount = 0
    }

    private struct DrawGraphicsState {
        var primitive: HorizontalDrawingPrimitive
        var originalSheet: HorizontalSchematicSheet
        var points: [HorizontalPoint] = []
        var cursor: HorizontalPoint?
        var rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner
    }

    private typealias DrawGraphicsResult = HorizontalCanvasDrawGraphicsResult

    private struct MovingConnectionPoint {
        var point: HorizontalPoint
        var netID: String?
    }

    private struct PlacedSymbolPin {
        var pinID: String
        var point: HorizontalPoint
    }

    private struct DanglingNetConnection {
        var netID: String
        var junctionID: String?
        var keepsJunction: Bool
    }

    private struct SchematicConnectionMovePlan {
        var points: [HorizontalPoint] = []
        var handledRefs = Set<HorizontalSelectableRef>()
        var affectedRefs = Set<HorizontalSelectableRef>()
    }

    private enum SchematicSymbolMoveConnectionTarget: Hashable {
        case netLineFrom(String)
        case netLineTo(String)
        case junction(String)
    }

    private struct SchematicSymbolMoveConnectionPlan {
        var targetsBySymbolID = [String: [SchematicSymbolMoveConnectionTarget]]()

        var netLineRefs: Set<HorizontalSelectableRef> {
            var refs = Set<HorizontalSelectableRef>()
            for targets in targetsBySymbolID.values {
                for target in targets {
                    switch target {
                    case .netLineFrom(let id), .netLineTo(let id):
                        refs.insert(HorizontalSelectableRef(id: id, type: .lineNet))
                    case .junction:
                        break
                    }
                }
            }
            return refs
        }

        var affectedRefs: Set<HorizontalSelectableRef> {
            var refs = Set<HorizontalSelectableRef>()
            for targets in targetsBySymbolID.values {
                for target in targets {
                    switch target {
                    case .netLineFrom(let id), .netLineTo(let id):
                        refs.insert(HorizontalSelectableRef(id: id, type: .lineNet))
                    case .junction(let id):
                        refs.insert(HorizontalSelectableRef(id: id, type: .junction))
                    }
                }
            }
            return refs
        }
    }

    private var sourceSheet: HorizontalSchematicSheet
    private var sourceAllSheets: [HorizontalSchematicSheet]
    @Binding private var viewport: CanvasViewport
    var displayOptions = SchematicDisplayOptions()
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
    var onSheetChange: (HorizontalSchematicSheet) -> Void = { _ in }
    var onNetClassChange: (String, String?) -> Void = { _, _ in }
    var onComponentRefdesChange: (String, String) -> Void = { _, _ in }
    var onComponentPinNamesChange: (String, [HorizontalSymbolPinName]) -> Void = { _, _ in }
    var onSelectionDetailsChange: (HorizontalSelectionDetailState) -> Void = { _ in }
    var onNetSegmentSelectionChange: (HorizontalNetSegmentSelectionSidebarState?) -> Void = { _ in }
    var onCanvasCommandActionsChange: (HorizontalCanvasCommandActions?) -> Void = { _ in }
    var hasKeyboardFocus = true
    var onRequestKeyboardFocus: () -> Void = {}
    var selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand?
    var netSegmentSelectionCommand: HorizontalNetSegmentSelectionCommand?
    var drawingToolCommand: HorizontalDrawingToolCommand?
    var drawNetLineCommand: HorizontalDrawNetLineCommand?
    var placePartRequest: HorizontalPartPlacementRequest?
    var poolURL: URL?
    /// What the canvas edits: a sheet, or a pool symbol / frame (see
    /// `HorizontalSchematicEditorProfile`).
    var mode: HorizontalSchematicEditorMode = .sheet
    var symbolEditorContext: HorizontalSymbolEditorContext?
    /// Bumped by the host when it replaced `sheet` underneath the canvas (a
    /// header edit, an undo of one, a unit change); the draft is dropped and
    /// the new sheet adopted in place.
    var syncRevision = 0

    @State private var hoveredObject: HorizontalSelectableRef?
    @State private var selectedObjects: [HorizontalSelectableRef] = []
    @State private var selectedUnplacedObjectID: String?
    @State private var editedSheet: HorizontalSchematicSheet?
    @State private var moveState: MoveState?
    @State private var placePartState: PlacePartState?
    @State private var placePinState: PlacePinState?
    /// The orientation the next placed pin starts with — the last one used,
    /// as Horizon's map-pin tool remembers it.
    @State private var placePinOrientation = HorizontalPinOrientation.right
    @State private var handledPlacePartRequestID: UUID?
    @State private var drawNetLineState: DrawNetLineState?
    @State private var drawGraphicsState: DrawGraphicsState?
    @State private var lastCursorWorldPoint: HorizontalPoint?
    @State private var netSegmentSelection: NetSegmentSelectionState?
    @State private var selectableCacheRevision = 0
    @State private var metalCacheRevision = 0
    #if os(macOS)
    @State private var editingTextState: EditTextState?
    /// Debounces the heavy live re-render (sheet mutation + onSheetChange) while
    /// typing into the inline text editor, so keystrokes stay instant and the
    /// canvas catches up ~0.1s behind.
    @State private var textRenderDebounce: Task<Void, Never>?
    /// The transform the canvas is actually rendering with (reported by
    /// InteractiveCanvasView from its on-screen viewport). The inline editor
    /// popover anchors against this so it lands on the text at any zoom/pan.
    @State private var canvasDisplayTransform: HorizontalCanvasTransform?
    #endif
    @StateObject private var undoTarget = HorizontalUndoTarget<HorizontalSchematicSheet>()
    @StateObject private var selectableCache = SchematicSelectableCache()
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    init(
        sheet: HorizontalSchematicSheet,
        allSheets: [HorizontalSchematicSheet] = [],
        viewport: Binding<CanvasViewport>,
        displayOptions: SchematicDisplayOptions = SchematicDisplayOptions(),
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
        onSheetChange: @escaping (HorizontalSchematicSheet) -> Void = { _ in },
        onNetClassChange: @escaping (String, String?) -> Void = { _, _ in },
        onComponentRefdesChange: @escaping (String, String) -> Void = { _, _ in },
        onComponentPinNamesChange: @escaping (String, [HorizontalSymbolPinName]) -> Void = { _, _ in },
        onSelectionDetailsChange: @escaping (HorizontalSelectionDetailState) -> Void = { _ in },
        onNetSegmentSelectionChange: @escaping (HorizontalNetSegmentSelectionSidebarState?) -> Void = { _ in },
        onCanvasCommandActionsChange: @escaping (HorizontalCanvasCommandActions?) -> Void = { _ in },
        hasKeyboardFocus: Bool = true,
        onRequestKeyboardFocus: @escaping () -> Void = {},
        selectionPropertyChangeCommand: HorizontalSelectionPropertyChangeCommand? = nil,
        netSegmentSelectionCommand: HorizontalNetSegmentSelectionCommand? = nil,
        drawingToolCommand: HorizontalDrawingToolCommand? = nil,
        drawNetLineCommand: HorizontalDrawNetLineCommand? = nil,
        placePartRequest: HorizontalPartPlacementRequest? = nil,
        poolURL: URL? = nil,
        mode: HorizontalSchematicEditorMode = .sheet,
        symbolEditorContext: HorizontalSymbolEditorContext? = nil,
        syncRevision: Int = 0
    ) {
        self.sourceSheet = sheet
        self.sourceAllSheets = allSheets.isEmpty ? [sheet] : allSheets
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
        self.onSheetChange = onSheetChange
        self.onNetClassChange = onNetClassChange
        self.onComponentRefdesChange = onComponentRefdesChange
        self.onComponentPinNamesChange = onComponentPinNamesChange
        self.onSelectionDetailsChange = onSelectionDetailsChange
        self.onNetSegmentSelectionChange = onNetSegmentSelectionChange
        self.onCanvasCommandActionsChange = onCanvasCommandActionsChange
        self.hasKeyboardFocus = hasKeyboardFocus
        self.onRequestKeyboardFocus = onRequestKeyboardFocus
        self.selectionPropertyChangeCommand = selectionPropertyChangeCommand
        self.netSegmentSelectionCommand = netSegmentSelectionCommand
        self.drawingToolCommand = drawingToolCommand
        self.drawNetLineCommand = drawNetLineCommand
        self.placePartRequest = placePartRequest
        self.poolURL = poolURL
        self.mode = mode
        self.symbolEditorContext = symbolEditorContext
        self.syncRevision = syncRevision
    }

    private var sheet: HorizontalSchematicSheet {
        editedSheet ?? sourceSheet
    }

    private var editorProfile: HorizontalSchematicEditorProfile {
        .profile(for: mode)
    }

    /// Pool modes draw junctions on request (frame: always; symbol: with the
    /// "junctions and hidden names" toggle); a sheet draws them by attachment.
    private var showsEditorJunctions: Bool {
        editorProfile.showsJunctionsAlways || symbolEditorContext?.showsJunctionsAndHiddenNames == true
    }

    private var schematicSheets: [HorizontalSchematicSheet] {
        var sheets = sourceAllSheets
        if let editedSheet {
            if let index = sheets.firstIndex(where: { $0.id == editedSheet.id }) {
                sheets[index] = editedSheet
            } else {
                sheets.append(editedSheet)
            }
        }
        return sheets
    }

    private var theme: HorizontalCanvasPalette {
        appearanceSettings.palette(for: .schematic, colorScheme: colorScheme)
    }

    private var hasActiveHighlight: Bool {
        !highlightedNetIDs.isEmpty || !highlightedComponentIDs.isEmpty
    }

    private var canPatchSchematicMoveInMetal: Bool {
        guard moveState != nil,
              !selectedObjects.isEmpty,
              drawsSchematicUnderlayLinesInMetal else {
            return false
        }
        return selectedObjects.allSatisfy(isSchematicMetalMovePatchable)
    }

    private func isSchematicMetalMovePatchable(_ ref: HorizontalSelectableRef) -> Bool {
        switch ref.type {
        case .schematicSymbol,
             .lineNet,
             .drawingLine,
             .drawingArc,
             .junction,
             .netLabel,
             .busLabel,
             .busRipper,
             .powerSymbol,
             .schematicBlockSymbol,
             .schematicNetTie,
             .text:
            return true
        case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .symbolPin, .track, .via:
            return false
        }
    }

    private var schematicMovePatchDiagnostic: String {
        guard !selectedObjects.isEmpty else {
            return "patch disabled: no selection"
        }
        let counts = Dictionary(grouping: selectedObjects, by: \.type)
            .mapValues(\.count)
            .sorted { left, right in
                String(describing: left.key) < String(describing: right.key)
            }
            .map { "\(String(describing: $0.key))=\($0.value)" }
            .joined(separator: ", ")
        if selectedObjects.allSatisfy(isSchematicMetalMovePatchable) {
            return "patch eligible: \(counts)"
        }
        let blockers = Set(selectedObjects.filter { !isSchematicMetalMovePatchable($0) }.map(\.type))
            .map { String(describing: $0) }
            .sorted()
            .joined(separator: ", ")
        return "patch disabled by: \(blockers). selected: \(counts)"
    }

    private var schematic2DProfileID: String {
        [
            sourceSheet.id,
            sourceSheet.name,
            "\(sourceAllSheets.count)",
            "\(sourceSheet.symbols.count)",
            "\(sourceSheet.netLines.count)",
            "\(sourceSheet.junctions.count)",
            "\(sourceSheet.symbolPins.count)",
            "\(sourceSheet.symbolTexts.count)",
            "\(metalCacheRevision)"
        ].joined(separator: "|")
    }

    private var schematic2DProfileSummary: String {
        "\(sourceSheet.name)  sheets \(sourceAllSheets.count), symbols \(sourceSheet.symbols.count), nets \(sourceSheet.netLines.count), junctions \(sourceSheet.junctions.count), symbol pins \(sourceSheet.symbolPins.count), symbol texts \(sourceSheet.symbolTexts.count)"
    }

    private var schematicMetalPatchIndicator: some View {
        Label("Metal patch", systemImage: "bolt.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.textOverlay)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(theme.textOverlay.opacity(0.22), lineWidth: 1)
            }
            .padding(.leading, max(fitSafeAreaInsets?.leading ?? 0, CGFloat(0)) + 12)
            .padding(.top, max(fitSafeAreaInsets?.top ?? 0, CGFloat(0)) + 12)
            .help("Resident Metal range patching is active for this move")
            .allowsHitTesting(false)
    }

    private var drawsGridInMetal: Bool {
        #if canImport(MetalKit)
        displayOptions.grid && HorizontalMetalBackdropView.isSupported
        #else
        false
        #endif
    }

    private var drawsSchematicUnderlayLinesInMetal: Bool {
        #if canImport(MetalKit)
        (displayOptions.frame
            || displayOptions.drawing
            || displayOptions.origin
            || displayOptions.junctions
            || displayOptions.blockSymbols
            || displayOptions.symbols
            || displayOptions.nets
            || displayOptions.buses
            || displayOptions.netLabels
            || displayOptions.netTies
            || displayOptions.power
            || displayOptions.text)
            && HorizontalMetalBackdropView.isSupported
        #else
        false
        #endif
    }

    private var hasMetalRenderableSchematicContent: Bool {
        displayOptions.frame
            || displayOptions.drawing
            || displayOptions.origin
            || displayOptions.junctions
            || displayOptions.blockSymbols
            || displayOptions.symbols
            || displayOptions.nets
            || displayOptions.buses
            || displayOptions.netLabels
            || displayOptions.netTies
            || displayOptions.power
            || displayOptions.text
    }

    /// iOS modal prompt (text / number / option-picker) for draw tools that need input
    /// — currently AddText. macOS uses the synchronous NSAlert prompt, so this stays nil
    /// there.
    @State private var promptRequest: HorizontalCanvasPromptRequest?

    var body: some View {
        let _ = BoardLoadTimer.beginSchematic2DLoad(id: schematic2DProfileID, summary: schematic2DProfileSummary)
        let schematic2DBodyStart = BoardLoadTimer.tickBodyStart()
        defer { BoardLoadTimer.tickBodyEnd(schematic2DBodyStart) }
        func measureBody<T>(_ label: String, _ body: () -> T) -> T {
            let start = BoardLoadTimer.timingStart()
            let value = body()
            BoardLoadTimer.recordBoard2DStep(
                label,
                nanoseconds: BoardLoadTimer.elapsedNanoseconds(since: start),
                id: schematic2DProfileID
            )
            return value
        }

        let profilesMetalPatchMove = canPatchSchematicMoveInMetal
        let _ = HorizontalMoveRateDiagnostics.mark(.bodyPass, active: moveState != nil)
        let schematicRenderAnalysis = measureBody("render analysis") {
            HorizontalMoveProfiler.measure("body.renderAnalysis", enabled: profilesMetalPatchMove) {
                self.schematicRenderAnalysis()
            }
        }
        let isolatedSchematicNetLineIDs = schematicRenderAnalysis.isolatedNetLineIDs
        let schematicJunctionRenderInfo = schematicRenderAnalysis.junctionRenderInfo
        let metalLineBatch = measureBody("metal line batch") {
            HorizontalMoveProfiler.measure("body.metalLineBatch", enabled: profilesMetalPatchMove) {
                self.schematicMetalLineBatch(
                    isolatedNetLineIDs: isolatedSchematicNetLineIDs,
                    junctionRenderInfo: schematicJunctionRenderInfo
                )
            }
        }
        let metalBufferPatches = measureBody("move patches") {
            HorizontalMoveProfiler.measure("body.movePatches", enabled: profilesMetalPatchMove) {
                self.schematicMetalMovePatches(
                    metadata: metalLineBatch.metadata,
                    isolatedNetLineIDs: isolatedSchematicNetLineIDs
                )
            }
        }
        let metalHighlightBatch = measureBody("highlight batch") {
            HorizontalMoveProfiler.measure("body.highlightBatch", enabled: profilesMetalPatchMove) {
                self.schematicMetalHighlightBatch()
            }
        }
        let metalDimBatch = measureBody("dim batch") {
            HorizontalMoveProfiler.measure("body.dimBatch", enabled: profilesMetalPatchMove) {
                self.schematicMetalDimBatch(
                    hasMetalHighlight: !metalHighlightBatch.lines.isEmpty || !metalHighlightBatch.triangles.isEmpty
                )
            }
        }
        let metalSelectionBatch = measureBody("selection batch") {
            HorizontalMoveProfiler.measure("body.selectionBatch", enabled: profilesMetalPatchMove) {
                self.schematicMetalSelectionBatch()
            }
        }
        let metalPreviewBatch = measureBody("preview batch") {
            HorizontalMoveProfiler.measure("body.previewBatch", enabled: profilesMetalPatchMove) {
                self.schematicMetalPreviewBatch()
            }
        }
        let metalTopOverlayTriangles = measureBody("overlay triangles") {
            HorizontalMoveProfiler.measure("body.topOverlayTriangles", enabled: profilesMetalPatchMove) {
                metalDimBatch.triangles + metalHighlightBatch.triangles + metalSelectionBatch.triangles + metalPreviewBatch.triangles
            }
        }
        let metalTopOverlayLines = measureBody("overlay lines") {
            HorizontalMoveProfiler.measure("body.topOverlayLines", enabled: profilesMetalPatchMove) {
                metalHighlightBatch.lines + metalSelectionBatch.lines + metalPreviewBatch.lines
            }
        }
        let metalTopOverlayHandles = measureBody("overlay handles") {
            HorizontalMoveProfiler.measure("body.topOverlayHandles", enabled: profilesMetalPatchMove) {
                metalHighlightBatch.handles + metalSelectionBatch.handles + metalPreviewBatch.handles
            }
        }
        let metalTopOverlayKey = measureBody("overlay key") {
            ((metalDimBatch.triangleKey &* 31 &+ metalHighlightBatch.lineKey) &* 31 &+ metalSelectionBatch.lineKey) &* 31 &+ metalPreviewBatch.lineKey
        }
        let metalTopOverlayHandleKey = measureBody("handle key") {
            (metalHighlightBatch.handleKey &* 31 &+ metalSelectionBatch.handleKey) &* 31 &+ metalPreviewBatch.handleKey
        }
        let metalTopOverlayBufferPatches = measureBody("selection move patches") {
            HorizontalMoveProfiler.measure("body.selectionMovePatches", enabled: profilesMetalPatchMove) {
                self.schematicMetalSelectionMovePatches(
                    baseSelectionBatch: metalSelectionBatch,
                    lineStart: metalHighlightBatch.lines.count,
                    handleStart: metalHighlightBatch.handles.count
                )
            }
        }
        let measuredSnapTargets = measureBody("snap targets") {
            HorizontalMoveProfiler.measure("body.snapTargets", enabled: profilesMetalPatchMove) {
                self.schematicSnapTargets()
            }
        }
        let measuredSelectionHUD = measureBody("selection HUD") {
            HorizontalMoveProfiler.measure("body.selectionHUD", enabled: profilesMetalPatchMove) {
                selectionHUD
            }
        }
        let measuredSelectionDetails = measureBody("selection details") {
            HorizontalMoveProfiler.measure("body.selectionDetails", enabled: profilesMetalPatchMove) {
                selectionDetails
            }
        }
        let measuredSelectionSelectables = measureBody("selection selectables") {
            HorizontalMoveProfiler.measure("body.selectionSelectables", enabled: profilesMetalPatchMove) {
                self.schematicSelectables()
            }
        }

        return InteractiveCanvasView(
            bounds: sheet.bounds,
            viewport: $viewport,
            backgroundColor: theme.background,
            foregroundColor: theme.textOverlay,
            overlayBackgroundColor: theme.overlayBackground,
            showsScaleBar: false,
            showsCoordinateReadout: displayOptions.coordinates,
            grid: sheet.grid,
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
            metalTopOverlayTriangles: metalTopOverlayTriangles,
            metalTopOverlayTriangleKey: metalTopOverlayKey,
            metalTopOverlayLines: metalTopOverlayLines,
            metalTopOverlayLineKey: metalTopOverlayKey,
            metalTopOverlayHandles: metalTopOverlayHandles,
            metalTopOverlayHandleKey: metalTopOverlayHandleKey,
            metalTopOverlayBufferPatches: metalTopOverlayBufferPatches,
            metalTopOverlayBufferPatchKey: metalTopOverlayBufferPatches.hashValue,
            metalLoadProfileID: schematic2DProfileID,
            cursorSize: appearanceSettings.canvasCursorSize,
            snapTargets: measuredSnapTargets,
            fitSafeAreaInsets: fitSafeAreaInsets,
            minimumLineWidth: appearanceSettings.minimumLineWidth(for: .schematic),
            selectionHUD: measuredSelectionHUD,
            hoverStatusText: interactionStatusText ?? hoverStatusText,
            showsHoverPopover: appearanceSettings.shouldShowHoverPopover,
            selectionDetails: measuredSelectionDetails,
            showsSelectionDetails: Self.showsInCanvasSelectionInspector,
            unplacedObjects: currentUnplacedObjects,
            selectedUnplacedObjectID: selectedUnplacedObjectID,
            placesUnplacedObjectsOnTrailingEdge: appearanceSettings.shouldSwapViewControlsAndUnplacedReferences,
            selectionToolSettings: selectionToolSettings,
            selectionSelectables: measuredSelectionSelectables,
            handlesSelectionDeletion: canDeleteSelection,
            undoManager: undoManager,
            ignoresCanvasMouseEvents: ignoresCanvasMouseEvents,
            onCursorWorldPointChange: { point, worldUnitsPerPoint in
                updateCursor(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
            },
            onPrimaryClick: { point, worldUnitsPerPoint, clickAction, clickCount in
                if placePinState != nil {
                    commitPlacePin()
                    return
                }
                if placePartState != nil {
                    commitPlacePart()
                    return
                }
                if moveState != nil {
                    commitMove()
                    return
                }
                if drawGraphicsState != nil {
                    addDrawGraphicsPoint(point)
                    // Double-click ends the shape (line/polygon), matching the
                    // board and the net-line tool below. Zero-length duplicate
                    // vertices are filtered in commitDrawGraphics.
                    if clickCount >= 2 {
                        commitDrawGraphicsAtCursor()
                    }
                    return
                }
                if drawNetLineState != nil {
                    addDrawNetLinePoint(point)
                    if clickCount >= 2 {
                        commitDrawNetLine()
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
                guard placePartState == nil,
                      placePinState == nil,
                      moveState == nil,
                      drawNetLineState == nil,
                      drawGraphicsState == nil else {
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
                schematicTargetItemMenuEntries(for: ref)
            },
            onTargetMenuCommand: { ref, command in
                setSelectedObject(ref)
                dispatchCanvasCommand(command)
            },
            onUnplacedObjectSelection: { object in
                if isReadOnly {
                    selectUnplacedObject(object)
                } else if editorProfile.supportsPins {
                    beginPlacePin(pinID: object.id)
                } else {
                    beginPlaceUnplacedObject(object)
                }
            },
            onSelectionPropertyChange: applySelectionPropertyChange,
            onCommand: dispatchCanvasCommand,
            hitsSelection: { worldPoint, worldUnitsPerPoint in
                pressLandsOnSelection(at: worldPoint, worldUnitsPerPoint: worldUnitsPerPoint)
            },
            onCanvasDisplayTransformChange: { transform in
                #if os(macOS)
                // Only store while editing (no gesturing then, so it stays
                // stable); avoids per-frame @State churn during pan/zoom. The
                // report trigger guarantees a fresh value the instant editing
                // begins.
                if editingTextState != nil {
                    canvasDisplayTransform = transform
                }
                #endif
            },
            canvasDisplayTransformReportTrigger: inlineTextEditorReportTrigger,
            allowsContextMenu: placePartState == nil && placePinState == nil && moveState == nil && drawNetLineState == nil && drawGraphicsState == nil,
            handlesInteractionKeys: placePartState != nil || placePinState != nil || moveState != nil || drawNetLineState != nil || drawGraphicsState != nil,
            hasKeyboardFocus: hasKeyboardFocus,
            onRequestKeyboardFocus: onRequestKeyboardFocus,
            samplesCursorContinuously: placePartState != nil
                || placePinState != nil
                || moveState?.tracksCursor == true
                || drawNetLineState != nil
                || drawGraphicsState != nil
        )
        .overlay(alignment: .topLeading) {
            if canPatchSchematicMoveInMetal && !metalBufferPatches.isEmpty {
                schematicMetalPatchIndicator
            }
        }
        .onChange(of: sourceSheet.id) { _, _ in
            undoTarget.removeAllActions(from: undoManager)
            editedSheet = nil
            selectedObjects = []
            selectedUnplacedObjectID = nil
            hoveredObject = nil
            moveState = nil
            placePartState = nil
            placePinState = nil
            drawNetLineState = nil
            drawGraphicsState = nil
            lastCursorWorldPoint = nil
            clearNetSegmentSelection()
            invalidateSelectableCache()
            configureUndoTarget()
            publishSelectionContext()
        }
        .onChange(of: syncRevision) { _, _ in
            adoptExternallyUpdatedSheet()
        }
        .onAppear {
            configureUndoTarget()
            onSelectionDetailsChange(selectionDetails)
        }
        .onDisappear {
            onSelectionDetailsChange(.empty)
            onNetSegmentSelectionChange(nil)
        }
        .onChange(of: selectionDetails) { _, details in
            onSelectionDetailsChange(details)
        }
        .onChange(of: selectionPropertyChangeCommand?.id) { _, _ in
            if !isReadOnly, let selectionPropertyChangeCommand {
                applySelectionPropertyChange(selectionPropertyChangeCommand.change)
            }
        }
        .onChange(of: netSegmentSelectionCommand?.id) { _, _ in
            if !isReadOnly, let netSegmentSelectionCommand {
                applyNetSegmentSelectionCommand(netSegmentSelectionCommand)
            }
        }
        .onChange(of: drawingToolCommand?.id) { _, _ in
            if !isReadOnly, let drawingToolCommand {
                beginDrawGraphics(drawingToolCommand.primitive)
            }
        }
        .onChange(of: drawNetLineCommand?.id) { _, _ in
            if !isReadOnly, drawNetLineCommand != nil {
                beginDrawNetLine()
            }
        }
        .onChange(of: placePartRequest?.id) { _, _ in
            beginPlacePartIfNeeded()
        }
        .onChange(of: isReadOnly) { _, readOnly in
            if readOnly {
                cancelPlacePart()
                cancelPlacePin()
                cancelDrawGraphics()
                cancelDrawNetLine()
                cancelMove()
                clearNetSegmentSelection()
            }
        }
        .onAppear {
            beginPlacePartIfNeeded()
            publishCanvasCommandActions()
        }
        .onDisappear {
            onCanvasCommandActionsChange(nil)
        }
        .horizonCanvasPrompt($promptRequest)
        .overlay { inlineTextEditorOverlay }
        .onChange(of: canvasCommandActionsSignature) { _, _ in
            publishCanvasCommandActions()
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
                    bounds: sheet.bounds,
                    size: proxy.size,
                    fitInsets: schematicCanvasFitInsets(safeArea: proxy.safeAreaInsets),
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
    private func schematicCanvasFitInsets(safeArea proxySafeArea: EdgeInsets) -> HorizontalCanvasInsets {
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
        hasher.combine(placePartState != nil)
        hasher.combine(drawNetLineState != nil)
        hasher.combine(netSegmentSelection != nil)
        hasher.combine(drawGraphicsState?.primitive.rawValue)
        hasher.combine(drawGraphicsState?.points.count ?? 0)
        hasher.combine(drawGraphicsState?.rectanglePlacementMode == .center)
        return hasher.finalize()
    }

    private func publishCanvasCommandActions() {
        onCanvasCommandActionsChange(canvasCommandActions())
    }

    private var hasMetalHighlightCandidates: Bool {
        guard hasActiveHighlight else {
            return false
        }

        if displayOptions.nets,
           sheet.netLines.contains(where: { matchesHighlightedNet($0.netID) }) {
            return true
        }
        if displayOptions.netTies,
           sheet.netTies.contains(where: { matchesHighlightedNet($0.netIDs) }) {
            return true
        }
        if displayOptions.symbols,
           sheet.symbols.contains(where: { matchesHighlightedComponent($0.componentID) })
            || sheet.symbolPins.contains(where: { matchesHighlightedNet($0.netID) })
            || sheet.symbolPinCircles.contains(where: { matchesHighlightedNet($0.netID) }) {
            return true
        }
        if displayOptions.blockSymbols,
           sheet.blockSymbolPorts.contains(where: { matchesHighlightedNet($0.netID) }) {
            return true
        }
        if displayOptions.buses,
           sheet.busRipperLines.contains(where: { matchesHighlightedNet($0.netID) })
            || sheet.busRipperTexts.contains(where: { matchesHighlightedNet($0.netID) }) {
            return true
        }
        if displayOptions.netLabels,
           sheet.netLabels.contains(where: { matchesHighlightedNet($0.netID) }) {
            return true
        }
        if displayOptions.junctions,
           sheet.junctions.keys.contains(where: { matchesHighlightedNet(netID(forJunctionID: $0)) }) {
            return true
        }
        if displayOptions.power,
           sheet.powerSymbolLines.contains(where: { matchesHighlightedNet($0.netID) })
            || sheet.powerSymbolCircles.contains(where: { matchesHighlightedNet($0.netID) })
            || sheet.powerSymbolTexts.contains(where: { matchesHighlightedNet($0.netID) }) {
            return true
        }
        return false
    }

    private func drawSchematicBeforeMetalLines(
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        if displayOptions.grid && !drawsGridInMetal {
            drawGrid(context: context, transform: transform)
        }

        // Filled/stroked schematic polygons are emitted through the retained Metal layer.
    }

    private func drawSchematicAfterMetalLines(
        context: GraphicsContext,
        size: CGSize,
        transform: HorizontalCanvasTransform,
        junctionRenderInfo: [String: JunctionRenderInfo],
        drawsDimInMetal: Bool,
        drawsNetHighlightInMetal: Bool,
        drawsInteractionOverlay: Bool,
        drawsSelectionOutlinesInMetal: Bool,
        drawsPreviewInMetal: Bool
    ) {
        if displayOptions.symbols {
            if !drawsSchematicUnderlayLinesInMetal,
               sheet.symbolLines.isEmpty, sheet.symbolPins.isEmpty, sheet.symbolPolygons.isEmpty {
                drawSymbolPlaceholders(context: context, transform: transform)
            }
        }

        if !drawsDimInMetal && hasActiveHighlight && hasMetalHighlightCandidates {
            dimDesignForNetHighlight(context: context, size: size)
        }
        if !drawsNetHighlightInMetal {
            drawNetHighlight(context: context, transform: transform)
            drawComponentHighlight(context: context, transform: transform)
        }
        if drawsInteractionOverlay {
            drawSchematicInteractionOverlay(
                context: context,
                transform: transform,
                drawsSelectionOutlinesInMetal: drawsSelectionOutlinesInMetal,
                drawsPreviewInMetal: drawsPreviewInMetal
            )
        }
    }

    private func drawSchematicInteractionOverlay(
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        drawsSelectionOutlinesInMetal: Bool,
        drawsPreviewInMetal: Bool
    ) {
        if !drawsSelectionOutlinesInMetal {
            drawSelection(context: context, transform: transform)
        }
        if !drawsPreviewInMetal {
            drawNetLinePreview(context: context, transform: transform)
            drawGraphicsPreview(context: context, transform: transform)
        }
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
        if drawNetLineState != nil {
            return "Net: click points   Double-click or Return commits   Esc cancels"
        }
        if placePartState != nil {
            return "Place: click to place   Esc cancels"
        }
        if let state = placePinState {
            let name = sheet.placeableObjects.first { normalizedID($0.id) == normalizedID(state.pinID) }?.label ?? "pin"
            return "Place pin \(name): click places   R rotates   E mirrors   Esc ends"
        }
        if moveState != nil {
            return "Move: click or Return commits   Esc cancels"
        }
        return nil
    }

    private var selectionDetails: HorizontalSelectionDetailState {
        selectableCache.selectionDetails(
            key: SchematicSelectionDetailsCacheKey(
                selectableKey: selectableCacheKey,
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
                        type: .schematicSymbol,
                        title: "Unplaced symbol",
                        pluralTitle: "Unplaced symbols",
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
        if editorProfile.supportsPins {
            // The unit's pins the symbol has not placed yet.
            let placed = Set(sheet.editablePins.map { normalizedID($0.id) })
            return sheet.placeableObjects
                .filter { !placed.contains(normalizedID($0.id)) }
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
        let placeableObjects = sheet.placeableObjects.isEmpty ? sheet.unplacedObjects : sheet.placeableObjects
        var placedGates = Set<String>()
        var placedComponents = Set<String>()

        for schematicSheet in schematicSheets {
            for symbol in schematicSheet.symbols {
                guard let componentID = symbol.componentID.map(normalizedID) else {
                    continue
                }
                placedComponents.insert(componentID)
                if let gateID = symbol.gateID.map(normalizedID) {
                    placedGates.insert("\(componentID)/\(gateID)")
                }
            }
        }

        return placeableObjects
            .filter { object in
                guard let componentID = object.componentID.map(normalizedID) else {
                    return true
                }
                if let gateID = object.gateID.map(normalizedID) {
                    return !placedGates.contains("\(componentID)/\(gateID)")
                }
                return !placedComponents.contains(componentID)
            }
            .sorted { lhs, rhs in
                lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }

    private var canDeleteSelection: Bool {
        !isReadOnly
            && placePartState == nil
            && placePinState == nil
            && moveState == nil
            && drawNetLineState == nil
            && drawGraphicsState == nil
            && !selectedObjects.isEmpty
    }

    private func selectSymbolForPinNameEditing() {
        guard !isReadOnly,
              moveState == nil,
              let symbol = pinNameEditorTarget(),
              !symbol.symbolPinNames.isEmpty else {
            return
        }
        selectedObjects = [HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol)]
        hoveredObject = nil
        publishSelectionContext()
    }

    private func pinNameEditorTarget() -> HorizontalPlacement? {
        let refs = selectedObjects + [hoveredObject].compactMap { $0 }
        for ref in refs {
            if let target = pinNameEditorTarget(for: ref) {
                return target
            }
        }
        return nil
    }

    private func pinNameEditorTarget(for ref: HorizontalSelectableRef) -> HorizontalPlacement? {
        switch ref.type {
        case .schematicSymbol:
            return sheet.symbols.first { normalizedID($0.id) == normalizedID(ref.id) }
        case .symbolPin:
            guard let symbolID = symbolID(forGeometryID: ref.id),
                  let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(symbolID) }) else {
                return nil
            }
            return symbol
        default:
            return nil
        }
    }

    private func updateSymbolPinNameTexts(
        symbolID: String,
        pins: [HorizontalSymbolPinName],
        mode: String,
        sheet: inout HorizontalSchematicSheet
    ) {
        let normalizedSymbolID = normalizedID(symbolID)
        let pinsByID = pins.reduce(into: [String: HorizontalSymbolPinName]()) { result, pin in
            result[normalizedID(pin.id)] = pin
        }
        for index in sheet.symbolTexts.indices
            where self.symbolID(forGeometryID: sheet.symbolTexts[index].id).map(normalizedID) == normalizedSymbolID {
            guard sheet.symbolTexts[index].id.contains("/pin-name/"),
                  let pinID = pinID(forSymbolPinGeometryID: sheet.symbolTexts[index].id),
                  let pin = pinsByID[normalizedID(pinID)] else {
                continue
            }
            sheet.symbolTexts[index].text = displayedPinName(for: pin, mode: mode)
        }
    }

    private func displayedPinName(for pin: HorizontalSymbolPinName, mode: String) -> String {
        let primaryName = appendedTilde(pin.primaryName)
        if mode == HorizontalSymbolPinDisplayMode.all.rawValue {
            let alternateNames = pin.alternateNames.map { appendedTilde($0.name) }
            return (alternateNames + ["(\(primaryName))"]).joined(separator: " · ")
        }

        if mode == HorizontalSymbolPinDisplayMode.customOnly.rawValue {
            let customName = pin.state.customName.trimmingCharacters(in: .whitespacesAndNewlines)
            return customName.isEmpty ? primaryName : appendedTilde(customName)
        }

        if !pin.state.pinNames.isEmpty || pin.state.useCustomName || pin.state.usePrimaryName {
            var names = [String]()
            if pin.state.usePrimaryName || mode == HorizontalSymbolPinDisplayMode.both.rawValue {
                names.append(primaryName)
            }
            for option in pin.alternateNames where pin.state.pinNames.contains(where: { normalizedID($0) == normalizedID(option.id) }) {
                names.append(appendedTilde(option.name))
            }
            if pin.state.useCustomName {
                let customName = pin.state.customName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !customName.isEmpty {
                    names.append(appendedTilde(customName))
                }
            }
            return names.joined(separator: " · ")
        }

        return primaryName
    }

    private func appendedTilde(_ text: String) -> String {
        text.first == "~" ? "\(text)~" : text
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
            ref: HorizontalSelectableRef(id: object.id, type: .schematicSymbol),
            title: object.label,
            subtitle: object.subtitle,
            details: componentDetailRows(object.details)
                + [
                    detailRow("Gate", object.gateID.map(shortID)),
                    detailRow("Component", object.componentID.map(shortID)),
                ].compactMap { $0 },
            properties: [
                readOnlyProperty("state", "State", "Unplaced"),
                readOnlyProperty("kind", "Kind", object.subtitle),
                readOnlyProperty("component", "Component", object.componentID.map(shortID)),
                readOnlyProperty("gate", "Gate", object.gateID.map(shortID)),
            ].compactMap { $0 }
        )
    }

    private func hudItem(for ref: HorizontalSelectableRef?) -> HorizontalSelectionHUDItem? {
        guard let ref else {
            return nil
        }
        if let item = poolEditorHUDItem(for: ref) {
            return item
        }

        switch ref.type {
        case .schematicSymbol:
            guard let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: nonEmpty(symbol.label) ?? shortID(symbol.id),
                subtitle: "Schematic symbol \(shortID(symbol.id))",
                details: componentDetailRows(symbol.componentDetails)
            )
        case .lineNet:
            return segmentHUDItem(for: ref, in: sheet.netLines, title: "Net line", includesLength: true)
        case .symbolPin:
            return segmentHUDItem(for: ref, in: sheet.symbolPins, title: "Symbol pin", includesLength: false)
        case .netLabel:
            guard let label = sheet.netLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: label.text,
                subtitle: "Net label \(shortID(label.id))",
                details: netDetailRows(label.netID)
            )
        case .junction:
            guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: "Junction",
                subtitle: coordinateString(junction.value),
                details: netDetailRows(netID(forJunctionID: junction.key))
            )
        case .schematicNetTie:
            guard let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            let label = nonEmpty(tie.label) ?? shortID(tie.id)
            return HorizontalSelectionHUDItem(
                title: label,
                subtitle: "Schematic net tie \(shortID(tie.id))",
                details: tie.netIDs.sorted().flatMap(netDetailRows)
                    + [detailRow("Length", lengthString((tie.to - tie.from).length))].compactMap { $0 }
            )
        case .busLabel:
            guard let label = sheet.busLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: label.text,
                subtitle: "Bus label \(shortID(label.id))",
                details: [
                    detailRow("Orientation", label.orientation),
                ].compactMap { $0 }
            )
        case .busRipper:
            return HorizontalSelectionHUDItem(
                title: "Bus ripper",
                subtitle: shortID(ref.id),
                details: groupedNetID(
                    for: ref.id,
                    segments: sheet.busRipperLines,
                    texts: sheet.busRipperTexts,
                    separators: ["line", "text"]
                ).map(netDetailRows) ?? []
            )
        case .powerSymbol:
            return HorizontalSelectionHUDItem(
                title: "Power symbol",
                subtitle: shortID(ref.id),
                details: groupedNetID(
                    for: ref.id,
                    segments: sheet.powerSymbolLines,
                    circles: sheet.powerSymbolCircles,
                    texts: sheet.powerSymbolTexts,
                    separators: ["circle", "line", "text"]
                ).map(netDetailRows) ?? []
            )
        case .schematicBlockSymbol:
            return HorizontalSelectionHUDItem(title: "Block symbol", subtitle: shortID(ref.id))
        case .blockSymbolPort:
            return segmentHUDItem(for: ref, in: sheet.blockSymbolPorts, title: "Block symbol port", includesLength: false)
        case .text:
            guard let text = sheet.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return genericHUDItem(for: ref)
            }
            return HorizontalSelectionHUDItem(
                title: nonEmpty(text.text) ?? "Text",
                subtitle: shortID(text.id),
                details: [
                    detailRow("Size", lengthString(text.size)),
                ].compactMap { $0 }
            )
        case .drawingLine:
            return segmentHUDItem(for: ref, in: sheet.drawingLines, title: "Drawing line", includesLength: true)
        case .drawingArc:
            return arcHUDItem(for: ref, in: sheet.drawingArcs, title: "Drawing arc", includesLength: true)
        case .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .track, .via:
            return genericHUDItem(for: ref)
        }
    }

    private func segmentHUDItem(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        title: String,
        includesLength: Bool
    ) -> HorizontalSelectionHUDItem {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return genericHUDItem(for: ref)
        }

        let detail = includesLength
            ? "\(lengthString(segment.length)) - \(shortID(segment.id))"
            : shortID(segment.id)
        var details = [HorizontalSelectionHUDDetail]()
        if includesLength {
            details.append(detailRow("Length", lengthString(segment.length))!)
        }
        details.append(contentsOf: netDetailRows(segment.netID))
        return HorizontalSelectionHUDItem(title: title, subtitle: detail, details: details)
    }

    private func arcHUDItem(
        for ref: HorizontalSelectableRef,
        in arcs: [HorizontalArc],
        title: String,
        includesLength: Bool
    ) -> HorizontalSelectionHUDItem {
        guard let arc = arcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return genericHUDItem(for: ref)
        }

        let detail = includesLength
            ? "\(lengthString(arc.length)) - \(shortID(arc.id))"
            : shortID(arc.id)
        var details = [HorizontalSelectionHUDDetail]()
        if includesLength {
            details.append(detailRow("Length", lengthString(arc.length))!)
            details.append(detailRow("Radius", lengthString(arc.radius))!)
        }
        details.append(contentsOf: netDetailRows(arc.netID))
        return HorizontalSelectionHUDItem(title: title, subtitle: detail, details: details)
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

        let net = sheet.netDetails[normalizedID(netID)]
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

    private func netDisplayName(_ netID: String?) -> String? {
        guard let netID else {
            return nil
        }
        return sheet.netDetails[normalizedID(netID)]?.name ?? shortID(netID)
    }

    private func detailRow(_ label: String, _ value: String?) -> HorizontalSelectionHUDDetail? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        return HorizontalSelectionHUDDetail(label: label, value: value)
    }

    private func selectionProperties(for ref: HorizontalSelectableRef) -> [HorizontalSelectionProperty] {
        if let properties = poolEditorProperties(for: ref) {
            return properties
        }
        switch ref.type {
        case .schematicSymbol:
            guard let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableComponentRefdesProperty(for: symbol),
                editableCustomValueProperty(for: symbol),
                editableLengthProperty("positionX", "Position X", symbol.position.x),
                editableLengthProperty("positionY", "Position Y", symbol.position.y),
                editableAngleProperty("angle", "Angle", symbol.angle),
            ].compactMap { $0 } + editableSymbolPinNameProperties(for: symbol)
        case .lineNet:
            return segmentProperties(for: ref, segments: sheet.netLines, title: "Net")
        case .drawingLine:
            return segmentProperties(for: ref, segments: sheet.drawingLines, title: "Drawing line")
        case .drawingArc:
            return arcProperties(for: ref, arcs: sheet.drawingArcs, title: "Drawing arc")
        case .symbolPin:
            return segmentProperties(for: ref, segments: sheet.symbolPins, title: "Symbol pin", editable: false)
        case .blockSymbolPort:
            return segmentProperties(for: ref, segments: sheet.blockSymbolPorts, title: "Port", editable: false)
        case .netLabel:
            guard let label = sheet.netLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableTextProperty("text", "Net name", label.text),
                editableLengthProperty("size", "Size", label.size),
                editableNetClassProperty(for: label.netID),
            ].compactMap { $0 }
        case .busLabel:
            guard let label = sheet.busLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                editableTextProperty("text", "Name", label.text),
                editableLengthProperty("size", "Size", label.size),
                readOnlyProperty("orientation", "Orientation", label.orientation),
            ].compactMap { $0 }
        case .text:
            guard let text = sheet.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return textProperties(text)
        case .junction:
            guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("net", "Net", netDisplayName(netID(forJunctionID: junction.key))),
                editableNetClassProperty(for: netID(forJunctionID: junction.key)),
            ].compactMap { $0 }
        case .schematicNetTie:
            guard let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [
                readOnlyProperty("name", "Name", tie.label),
                tie.netIDs.count == 1 ? editableNetClassProperty(for: tie.netIDs.first) : nil,
                readOnlyProperty("length", "Length", lengthString((tie.to - tie.from).length)),
            ].compactMap { $0 }
        case .busRipper, .powerSymbol:
            let netID = netID(for: ref)
            return [
                readOnlyProperty("net", "Net", netDisplayName(netID)),
                editableNetClassProperty(for: netID),
            ].compactMap { $0 }
        case .schematicBlockSymbol:
            return []
        case .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .track, .via:
            return []
        }
    }

    private func segmentProperties(
        for ref: HorizontalSelectableRef,
        segments: [HorizontalSegment],
        title: String,
        editable: Bool = true
    ) -> [HorizontalSelectionProperty] {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }

        let widthProperty = editable
            ? editableLengthProperty("width", "Width", segment.width)
            : readOnlyProperty("width", "Width", segment.width > 0 ? lengthString(segment.width) : nil)
        return [
            readOnlyProperty("name", title, netDisplayName(segment.netID) ?? shortID(segment.id)),
            widthProperty,
            editableNetClassProperty(for: segment.netID),
            readOnlyProperty("length", "Length", lengthString(segment.length)),
        ].compactMap { $0 }
    }

    private func arcProperties(
        for ref: HorizontalSelectableRef,
        arcs: [HorizontalArc],
        title: String,
        editable: Bool = true
    ) -> [HorizontalSelectionProperty] {
        guard let arc = arcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }

        let widthProperty = editable
            ? editableLengthProperty("width", "Width", arc.width)
            : readOnlyProperty("width", "Width", arc.width > 0 ? lengthString(arc.width) : nil)
        return [
            readOnlyProperty("name", title, netDisplayName(arc.netID) ?? shortID(arc.id)),
            widthProperty,
            editableNetClassProperty(for: arc.netID),
            readOnlyProperty("radius", "Radius", lengthString(arc.radius)),
            readOnlyProperty("length", "Length", lengthString(arc.length)),
        ].compactMap { $0 }
    }

    private func textProperties(_ text: HorizontalText) -> [HorizontalSelectionProperty] {
        [
            editableTextProperty("text", "Text", text.text, multiline: true),
            editableLengthProperty("size", "Size", text.size),
            editableLengthProperty("width", "Width", text.width),
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

    private func editableCustomValueProperty(for placement: HorizontalPlacement) -> HorizontalSelectionProperty? {
        guard placement.componentDetails != nil else {
            return nil
        }
        return editableTextProperty("customValue", "Custom Value", placement.customValue ?? "", multiline: true)
    }

    private func editableSymbolPinNameProperties(for placement: HorizontalPlacement) -> [HorizontalSelectionProperty] {
        guard !placement.symbolPinNames.isEmpty else {
            return []
        }

        let modeOptions = HorizontalSymbolPinDisplayMode.allCases.map {
            HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.title)
        }
        var properties = [
            HorizontalSelectionProperty(
                id: "pinDisplayMode",
                label: "Pin names",
                editor: .choice(modeOptions),
                value: .choice(placement.pinDisplayMode)
            )
        ]

        for pin in placement.symbolPinNames {
            let pinTitle = nonEmpty(pin.primaryName) ?? shortID(pin.id)
            properties.append(
                HorizontalSelectionProperty(
                    id: symbolPinPropertyID(pinID: pin.id, field: "primary"),
                    label: "\(pinTitle) Primary",
                    editor: .bool,
                    value: .bool(pin.state.usePrimaryName)
                )
            )
            for option in pin.alternateNames {
                properties.append(
                    HorizontalSelectionProperty(
                        id: symbolPinPropertyID(pinID: pin.id, field: "alt", extra: option.id),
                        label: "\(pinTitle) \(option.name)",
                        editor: .bool,
                        value: .bool(pin.state.pinNames.contains { normalizedID($0) == normalizedID(option.id) })
                    )
                )
            }
            properties.append(
                HorizontalSelectionProperty(
                    id: symbolPinPropertyID(pinID: pin.id, field: "customEnabled"),
                    label: "\(pinTitle) Custom",
                    editor: .bool,
                    value: .bool(pin.state.useCustomName)
                )
            )
            properties.append(
                HorizontalSelectionProperty(
                    id: symbolPinPropertyID(pinID: pin.id, field: "customName"),
                    label: "\(pinTitle) Name",
                    editor: .text,
                    value: .text(pin.state.customName)
                )
            )
            properties.append(
                HorizontalSelectionProperty(
                    id: symbolPinPropertyID(pinID: pin.id, field: "customDirection"),
                    label: "\(pinTitle) Direction",
                    editor: .choice(pinDirectionOptions()),
                    value: .choice(pin.state.customDirection)
                )
            )
        }

        return properties
    }

    private func symbolPinPropertyID(pinID: String, field: String, extra: String? = nil) -> String {
        ["pinName", pinID, field, extra].compactMap { $0 }.joined(separator: ":")
    }

    private func pinDirectionOptions() -> [HorizontalSelectionPropertyOption] {
        [
            HorizontalSelectionPropertyOption(id: "input", title: "Input"),
            HorizontalSelectionPropertyOption(id: "output", title: "Output"),
            HorizontalSelectionPropertyOption(id: "bidirectional", title: "Bidirectional"),
            HorizontalSelectionPropertyOption(id: "passive", title: "Passive"),
            HorizontalSelectionPropertyOption(id: "power_input", title: "Power Input"),
            HorizontalSelectionPropertyOption(id: "power_output", title: "Power Output"),
            HorizontalSelectionPropertyOption(id: "open_collector", title: "Open Collector"),
            HorizontalSelectionPropertyOption(id: "not_connected", title: "Not Connected")
        ]
    }

    private func editableNetClassProperty(for netID: String?) -> HorizontalSelectionProperty? {
        guard let netID else {
            return nil
        }

        let normalizedNetID = normalizedID(netID)
        guard let net = sheet.netDetails[normalizedNetID] else {
            return nil
        }

        let options = netClassOptions()
        guard !options.isEmpty else {
            return readOnlyProperty("netClass", "Net class", net.netClassName)
        }

        let selectedID = net.netClassID.map(normalizedID) ?? Self.noNetClassChoiceID
        let optionIDs = Set(options.map(\.id))
        let value = optionIDs.contains(selectedID) ? selectedID : options[0].id
        return HorizontalSelectionProperty(
            id: "netClass",
            label: "Net class",
            editor: .choice(options),
            value: .choice(value)
        )
    }

    private func netClassOptions() -> [HorizontalSelectionPropertyOption] {
        sheet.netClasses.map { netClass in
            HorizontalSelectionPropertyOption(
                id: normalizedID(netClass.id),
                title: nonEmpty(netClass.name) ?? shortID(netClass.id)
            )
        }
    }

    private func setSelectedObject(_ ref: HorizontalSelectableRef?) {
        clearNetSegmentSelection()
        selectedObjects = ref.map { [$0] } ?? []
        selectedUnplacedObjectID = nil
        publishSelectionContext()
    }

    private func selectAllObjects() {
        guard moveState == nil else {
            return
        }
        clearNetSegmentSelection()
        selectedObjects = schematicSelectableScene().refs()
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        publishSelectionContext()
    }

    private func updateSelection(with ref: HorizontalSelectableRef?, action: HorizontalSelectionClickAction) {
        guard let updated = HorizontalCanvasModeSupport.updatedSelection(
            current: selectedObjects,
            ref: ref,
            action: action
        ) else {
            return
        }
        clearNetSegmentSelection()
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
        clearNetSegmentSelection()
        selectedObjects = updated
        selectedUnplacedObjectID = nil
        publishSelectionContext()
    }

    private func selectUnplacedObject(_ object: HorizontalUnplacedObject) {
        clearNetSegmentSelection()
        selectedObjects = []
        hoveredObject = nil
        selectedUnplacedObjectID = object.id
        publishSelectionContext()
    }

    private func beginPlaceUnplacedObject(_ object: HorizontalUnplacedObject) {
        guard !isReadOnly,
              moveState == nil,
              placePartState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil,
              let poolURL else {
            selectUnplacedObject(object)
            return
        }

        let originalSheet = sheet
        let start = lastCursorWorldPoint ?? originalSheet.bounds.center
        guard let draft = HorizontalSchematic.placingUnplacedSymbol(
            object,
            in: originalSheet,
            at: start,
            poolURL: poolURL
        ) else {
            selectUnplacedObject(object)
            return
        }

        editedSheet = draft.sheet
        placePartState = PlacePartState(
            requestID: UUID(),
            originalSheet: originalSheet,
            symbolID: draft.symbolInstanceID,
            actionName: "Place Symbol"
        )
        selectedObjects = [HorizontalSelectableRef(id: draft.symbolInstanceID, type: .schematicSymbol)]
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        invalidateSelectableCache()
    }

    private func uniqueRefs(_ refs: [HorizontalSelectableRef]) -> [HorizontalSelectableRef] {
        HorizontalCanvasModeSupport.uniqueRefs(refs)
    }

    private func beginPlacePartIfNeeded() {
        guard !isReadOnly,
              let request = placePartRequest,
              handledPlacePartRequestID != request.id,
              let poolURL else {
            return
        }
        guard moveState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil else {
            return
        }

        let originalSheet = sheet
        let start = lastCursorWorldPoint ?? originalSheet.bounds.center
        guard let draft = HorizontalSchematic.placingPart(
            request.part,
            in: originalSheet,
            at: start,
            poolURL: poolURL
        ) else {
            return
        }

        handledPlacePartRequestID = request.id
        editedSheet = draft.sheet
        placePartState = PlacePartState(
            requestID: request.id,
            originalSheet: originalSheet,
            symbolID: draft.symbolInstanceID,
            actionName: "Place Part"
        )
        selectedObjects = [HorizontalSelectableRef(id: draft.symbolInstanceID, type: .schematicSymbol)]
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        invalidateSelectableCache()
    }

    private func updatePlacePart(to point: HorizontalPoint) {
        guard !isReadOnly,
              let state = placePartState else {
            return
        }
        var draft = editedSheet ?? sourceSheet
        guard let symbol = draft.symbols.first(where: { normalizedID($0.id) == normalizedID(state.symbolID) }) else {
            return
        }

        let delta = point - symbol.position
        guard delta != .zero else {
            return
        }

        movePlacedSymbolPreview(symbolID: state.symbolID, by: delta, sheet: &draft)
        editedSheet = draft
        invalidateSelectableCache()
    }

    private func movePlacedSymbolPreview(symbolID: String, by delta: HorizontalPoint, sheet: inout HorizontalSchematicSheet) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(symbolID) }) else {
            return
        }

        sheet.symbols[index].position = sheet.symbols[index].position + delta
        shiftSchematicSymbolGeometry(symbolID: symbolID, by: delta, sheet: &sheet)
    }

    private func commitPlacePart() {
        guard !isReadOnly,
              let state = placePartState else {
            return
        }

        var draft = sheet
        autoconnectPlacedSymbol(state.symbolID, sheet: &draft)
        editedSheet = draft
        registerUndoSnapshot(state.originalSheet, actionName: state.actionName)
        placePartState = nil
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
    }

    private func autoconnectPlacedSymbol(_ symbolID: String, sheet: inout HorizontalSchematicSheet) {
        guard let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(symbolID) }),
              let componentID = symbol.componentID.map(normalizedID),
              let gateID = symbol.gateID.map(normalizedID) else {
            return
        }

        for pin in placedSymbolPins(symbolID: symbolID, sheet: sheet) {
            let gatePinPath = normalizedUUIDPath("\(gateID)/\(pin.pinID)")
            if sheet.componentInfo[componentID]?.connections[gatePinPath]?.netID != nil {
                continue
            }
            guard let connection = danglingNetConnection(at: pin.point, excludingSymbolID: symbolID, sheet: sheet) else {
                continue
            }

            sheet.componentInfo[componentID]?.connections[gatePinPath] = .connected(connection.netID)
            setPlacedSymbolPin(pin.pinID, symbolID: symbolID, netID: connection.netID, sheet: &sheet)
            if let junctionID = connection.junctionID, !connection.keepsJunction {
                sheet.junctions.removeValue(forKey: junctionID)
                sheet.junctionNetIDs.removeValue(forKey: junctionID)
                removeJunctions(at: pin.point, sheet: &sheet)
            }
        }
    }

    private func removeJunctions(at point: HorizontalPoint, sheet: inout HorizontalSchematicSheet) {
        let key = pointKey(point)
        let matchingIDs = sheet.junctions
            .filter { pointKey($0.value) == key }
            .map(\.key)
        for junctionID in matchingIDs {
            sheet.junctions.removeValue(forKey: junctionID)
            sheet.junctionNetIDs.removeValue(forKey: junctionID)
        }
    }

    private func placedSymbolPins(symbolID: String, sheet: HorizontalSchematicSheet) -> [PlacedSymbolPin] {
        let normalizedSymbolID = normalizedID(symbolID)
        return sheet.symbolPins.compactMap { segment in
            guard let pinID = exactSymbolPinID(for: segment.id, symbolID: normalizedSymbolID) else {
                return nil
            }
            return PlacedSymbolPin(pinID: pinID, point: segment.from)
        }
    }

    private func exactSymbolPinID(for geometryID: String, symbolID: String) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[0] == symbolID,
              components[1] == "pin" else {
            return nil
        }
        return components[2]
    }

    private func danglingNetConnection(
        at point: HorizontalPoint,
        excludingSymbolID symbolID: String,
        sheet: HorizontalSchematicSheet
    ) -> DanglingNetConnection? {
        let junctionID = junctionID(at: point, in: sheet)
        let hasPowerSymbol = powerSymbolIDs(in: sheet).contains { powerSymbolID in
            powerSymbolAnchorPoints(symbolID: powerSymbolID, sheet: sheet).contains { pointKey($0) == pointKey(point) }
        }
        let netID = junctionID.flatMap { sheet.junctionNetIDs[$0] }
            ?? netLineEndpointNetID(at: point, sheet: sheet)
            ?? powerSymbolNetID(at: point, sheet: sheet)
        guard let netID else {
            return nil
        }

        return DanglingNetConnection(
            netID: netID,
            junctionID: junctionID,
            keepsJunction: hasPowerSymbol
        )
    }

    private func netLineEndpointNetID(at point: HorizontalPoint, sheet: HorizontalSchematicSheet) -> String? {
        let key = pointKey(point)
        return sheet.netLines.first {
            $0.netID != nil && (pointKey($0.from) == key || pointKey($0.to) == key)
        }?.netID
    }

    private func powerSymbolNetID(at point: HorizontalPoint, sheet: HorizontalSchematicSheet) -> String? {
        let key = pointKey(point)
        return sheet.powerSymbolLines.first {
            $0.netID != nil && (pointKey($0.from) == key || pointKey($0.to) == key)
        }?.netID
            ?? sheet.powerSymbolCircles.first {
                $0.netID != nil && pointKey($0.center) == key
            }?.netID
    }

    private func setPlacedSymbolPin(
        _ targetPinID: String,
        symbolID: String,
        netID: String,
        sheet: inout HorizontalSchematicSheet
    ) {
        let normalizedSymbolID = normalizedID(symbolID)

        func isTargetPin(_ geometryID: String) -> Bool {
            guard self.symbolID(forGeometryID: geometryID).map(normalizedID) == normalizedSymbolID,
                  let geometryPinID = pinID(forSymbolPinGeometryID: geometryID) else {
                return false
            }
            return normalizedID(geometryPinID) == normalizedID(targetPinID)
        }

        for index in sheet.symbolPins.indices where isTargetPin(sheet.symbolPins[index].id) {
            sheet.symbolPins[index].netID = netID
        }
        for index in sheet.symbolPinCircles.indices where isTargetPin(sheet.symbolPinCircles[index].id) {
            sheet.symbolPinCircles[index].netID = netID
        }
        for index in sheet.symbolTexts.indices where isTargetPin(sheet.symbolTexts[index].id) {
            sheet.symbolTexts[index].netID = netID
        }
    }

    private func cancelPlacePart() {
        guard let state = placePartState else {
            return
        }

        editedSheet = state.originalSheet
        placePartState = nil
        selectedObjects = []
        hoveredObject = nil
        invalidateSelectableCache()
    }

    private func beginMove(tracksCursor: Bool = true, editTextRefOnCommit: String? = nil) {
        let originalSheet = sheet
        let moveSelection = expandedSchematicMoveSelection(selectedObjects, in: originalSheet)
        guard let start = HorizontalCanvasModeSupport.moveStartPoint(
            modeName: "schematic",
            isReadOnly: isReadOnly,
            moveIsActive: moveState != nil,
            selectedObjects: moveSelection,
            lastCursorWorldPoint: lastCursorWorldPoint,
            selectionCenter: {
                HorizontalCanvasModeSupport.selectionCenter(for: moveSelection, anchorPoints: selectionAnchorPoints)
            }
        ) else {
            return
        }
        selectedObjects = moveSelection
        let snapTargets = schematicSnapTargets(excluding: selectedObjects)
        let connectionPlan = selectedSchematicSymbolMoveConnectionPlan(in: originalSheet)
        let connectionMovePlan = selectedSchematicConnectionMovePlan(in: originalSheet)
        let fixedConnectionPointKeys = schematicFixedConnectionPointKeys(in: originalSheet)
        let snappedStart = snapSchematicPointToGrid(start)
        let initialPoints = HorizontalCanvasModeSupport.moveInitialPoints(
            startPoint: start,
            snappedCursorPoint: snappedStart,
            tracksCursor: tracksCursor
        )
        moveState = MoveState(
            startPoint: initialPoints.startPoint,
            lastPoint: initialPoints.lastPoint,
            originalSheet: originalSheet,
            undoSheet: originalSheet,
            editedSheetBeforeMove: editedSheet,
            tracksCursor: tracksCursor,
            snapTargets: snapTargets,
            connectionPlan: connectionPlan,
            connectionMovePlan: connectionMovePlan,
            fixedConnectionPointKeys: fixedConnectionPointKeys,
            editTextRefOnCommit: editTextRefOnCommit
        )
        HorizontalMoveRateDiagnostics.beginMove(
            tracksCursor: tracksCursor,
            selectedCount: selectedObjects.count,
            details: schematicMovePatchDiagnostic
        )
        hoveredObject = nil
        publishSelectionContext()
    }

    private func updateMove(to point: HorizontalPoint) {
        guard !isReadOnly,
              var state = moveState else {
            return
        }

        let profilesMetalPatchMove = canPatchSchematicMoveInMetal
        HorizontalMoveProfiler.measure("updateMove.total", enabled: profilesMetalPatchMove) {
            HorizontalMoveRateDiagnostics.mark(.moveAttempt)
            let delta = point - state.lastPoint
            guard delta != .zero else {
                HorizontalMoveRateDiagnostics.mark(.moveNoop)
                return
            }
            HorizontalMoveRateDiagnostics.mark(.moveAccepted)

            HorizontalMoveProfiler.measure("updateMove.storeState", enabled: profilesMetalPatchMove) {
                state.lastPoint = point
                moveState = state
            }
        }
    }

    private func commitMove() {
        guard !isReadOnly,
              let state = moveState else {
            return
        }
        // The place-text-then-edit flow rides the move machinery: on commit we
        // open the inline editor instead of registering a "Move" undo (the
        // placement is finalized as a single "Add Text" step, or reverted
        // entirely, by the popover).
        #if os(macOS)
        let editTextRef = state.editTextRefOnCommit
        #else
        let editTextRef: String? = nil
        #endif
        let totalDelta = state.lastPoint - state.startPoint
        var draft = state.originalSheet
        if totalDelta != .zero {
            moveSelectedObjects(
                by: totalDelta,
                sheet: &draft,
                symbolConnectionPlan: state.connectionPlan,
                connectionMovePlan: state.connectionMovePlan,
                fixedConnectionPointKeys: state.fixedConnectionPointKeys
            )
        }
        for ref in selectedObjects where ref.type == .schematicSymbol {
            autoconnectPlacedSymbol(ref.id, sheet: &draft)
        }
        editedSheet = draft
        if editTextRef == nil {
            registerUndoSnapshot(state.undoSheet, actionName: "Move")
        }
        moveState = nil
        HorizontalMoveRateDiagnostics.endMove(committed: true)
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
        #if os(macOS)
        if editTextRef != nil {
            beginEditingPlacedText()
        }
        #endif
    }

    private func cancelMove() {
        guard let state = moveState else {
            return
        }

        editedSheet = state.editedSheetBeforeMove
        invalidateSelectableCache()
        moveState = nil
        HorizontalMoveRateDiagnostics.endMove(committed: false)
        publishSelectionContext()
    }

    private func schematicMovePreviewSheet(for state: MoveState) -> HorizontalSchematicSheet {
        let totalDelta = state.lastPoint - state.startPoint
        guard totalDelta != .zero else {
            return state.originalSheet
        }

        return selectableCache.movePreview(
            key: SchematicMovePreviewCacheKey(
                selectableKey: selectableCacheKey,
                selectedRefs: selectedObjects,
                startPoint: state.startPoint,
                lastPoint: state.lastPoint
            )
        ) {
            var previewSheet = state.originalSheet
            moveSelectedObjectsForPreview(
                by: totalDelta,
                sheet: &previewSheet,
                symbolConnectionPlan: state.connectionPlan,
                connectionMovePlan: state.connectionMovePlan,
                fixedConnectionPointKeys: state.fixedConnectionPointKeys
            )
            return previewSheet
        }
    }

    private func beginDrawNetLine() {
        guard !isReadOnly,
              moveState == nil,
              drawNetLineState == nil else {
            return
        }
        drawNetLineState = DrawNetLineState(
            originalSheet: sheet,
            anchor: nil,
            anchorJunctionID: nil,
            netID: selectedNetID,
            cursor: lastCursorWorldPoint
        )
        selectedObjects = []
        hoveredObject = nil
        publishSelectionContext()
    }

    private func addDrawNetLinePoint(_ point: HorizontalPoint) {
        guard !isReadOnly,
              var state = drawNetLineState else {
            return
        }

        if state.anchor == nil {
            state.anchor = point
            state.anchorJunctionID = junctionID(at: point, in: sheet)
            state.netID = drawNetID(at: point) ?? state.netID
            state.cursor = point
            state.bendMode = drawNetLineBendMode(at: point) ?? state.bendMode
            drawNetLineState = state
            return
        }

        guard let anchor = state.anchor,
              pointKey(anchor) != pointKey(point) else {
            state.cursor = point
            drawNetLineState = state
            return
        }

        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        let endNetID = drawNetID(at: point)
        let netID = state.netID ?? endNetID
        let startJunctionID = ensureJunction(at: anchor, preferredID: state.anchorJunctionID, netID: netID, sheet: &draft)
        let endJunctionID = ensureJunction(at: point, preferredID: junctionID(at: point, in: draft), netID: netID, sheet: &draft)
        let path = drawNetLinePath(from: anchor, to: point, bendMode: state.bendMode)
        var segmentCount = 0
        var previousPoint = anchor
        for pathPoint in path.dropFirst() {
            if pointKey(pathPoint) != pointKey(point) {
                _ = ensureJunction(at: pathPoint, preferredID: junctionID(at: pathPoint, in: draft), netID: netID, sheet: &draft)
            }
            if pointKey(previousPoint) != pointKey(pathPoint) {
                draft.netLines.append(
                    HorizontalSegment(
                        id: UUID().uuidString.lowercased(),
                        from: previousPoint,
                        to: pathPoint,
                        width: 0,
                        layer: nil,
                        netID: netID
                    )
                )
                segmentCount += 1
            }
            previousPoint = pathPoint
        }
        editedSheet = draft
        invalidateSelectableCache()

        state.anchor = point
        state.anchorJunctionID = endJunctionID
        state.netID = netID
        state.cursor = point
        state.segmentCount += segmentCount
        drawNetLineState = state

        _ = startJunctionID
    }

    private func commitDrawNetLine() {
        guard !isReadOnly,
              let state = drawNetLineState else {
            return
        }
        drawNetLineState = nil
        guard state.segmentCount > 0 else {
            return
        }
        registerUndoSnapshot(state.originalSheet, actionName: "Draw Net Line")
        onSheetChange(sheet)
        publishSelectionContext()
    }

    private func cancelDrawNetLine() {
        guard let state = drawNetLineState else {
            return
        }
        editedSheet = state.originalSheet
        drawNetLineState = nil
        invalidateSelectableCache()
        publishSelectionContext()
    }

    private func beginDrawGraphics(_ primitive: HorizontalDrawingPrimitive) {
        guard !isReadOnly,
              moveState == nil else {
            return
        }
        drawNetLineState = nil
        drawGraphicsState = DrawGraphicsState(
            primitive: primitive,
            originalSheet: sheet,
            cursor: lastCursorWorldPoint
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

        if let result = finalizedGraphicsResult(for: state) {
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

        let previewPoints = state.points + [cursor]
        state.points = previewPoints
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
        editedSheet = state.originalSheet
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

    private func toggleRectanglePlacementMode() {
        guard var state = drawGraphicsState,
              state.primitive == .rectangle else {
            return
        }
        state.rectanglePlacementMode.toggle()
        drawGraphicsState = state
    }

    private func finalizedGraphicsResult(for state: DrawGraphicsState) -> DrawGraphicsResult? {
        HorizontalCanvasModeSupport.finalizedGraphicsResult(
            for: state.primitive,
            points: state.points,
            rectanglePlacementMode: state.rectanglePlacementMode,
            graphicsResult: { graphicsResult(for: $0, points: $1, rectanglePlacementMode: $2) }
        )
    }

    private func commitDrawGraphics(_ result: DrawGraphicsResult, state: DrawGraphicsState) {
        guard !isReadOnly else {
            return
        }
        let validSegments = result.lines.filter { pointKey($0.from) != pointKey($0.to) }
        let validArcs = result.arcs.filter {
            pointKey($0.from) != pointKey($0.to) && $0.radius > 0
        }
        let validPolygons = result.polygons.filter { $0.polygonVertices.count >= 3 }
        guard !validSegments.isEmpty || !validArcs.isEmpty || !validPolygons.isEmpty else {
            drawGraphicsState = state
            return
        }

        var draft = editedSheet ?? sourceSheet
        draft.drawingPolygons.append(contentsOf: validPolygons)
        for segment in validSegments {
            _ = ensureJunction(at: segment.from, preferredID: junctionID(at: segment.from, in: draft), netID: nil, sheet: &draft)
            _ = ensureJunction(at: segment.to, preferredID: junctionID(at: segment.to, in: draft), netID: nil, sheet: &draft)
            draft.drawingLines.append(segment)
        }
        for arc in validArcs {
            _ = ensureJunction(at: arc.from, preferredID: junctionID(at: arc.from, in: draft), netID: nil, sheet: &draft)
            _ = ensureJunction(at: arc.to, preferredID: junctionID(at: arc.to, in: draft), netID: nil, sheet: &draft)
            _ = ensureJunction(at: arc.center, preferredID: junctionID(at: arc.center, in: draft), netID: nil, sheet: &draft)
            draft.drawingArcs.append(arc)
        }
        editedSheet = draft
        drawGraphicsState = nil
        invalidateSelectableCache()
        registerUndoSnapshot(state.originalSheet, actionName: "Draw \(state.primitive.title)")
        onSheetChange(sheet)
        publishSelectionContext()
    }

    private func drawGraphicsResultHasDrawableGeometry(_ result: DrawGraphicsResult) -> Bool {
        result.lines.contains { pointKey($0.from) != pointKey($0.to) }
            || result.arcs.contains { pointKey($0.from) != pointKey($0.to) && $0.radius > 0 }
            || result.polygons.contains { $0.vertices.count >= 3 }
    }

    private func graphicsResult(
        for primitive: HorizontalDrawingPrimitive,
        points: [HorizontalPoint],
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner
    ) -> DrawGraphicsResult {
        HorizontalCanvasModeSupport.graphicsResult(
            for: primitive,
            points: points,
            rectanglePlacementMode: rectanglePlacementMode,
            pointKey: pointKey,
            makeSegment: { drawingSegment(from: $0, to: $1) },
            makeArc: { drawingArc(from: $0, to: $1, center: $2) },
            makePolygonResult: { points in
                editorProfile.supportsPolygons
                    ? DrawGraphicsResult(polygons: [drawingPolygon(points: points)])
                    : DrawGraphicsResult(lines: closedDrawingSegments(points: points))
            }
        )
    }

    private func drawingSegment(from: HorizontalPoint, to: HorizontalPoint) -> HorizontalSegment {
        HorizontalSegment(
            id: "sheet/line/\(UUID().uuidString.lowercased())",
            from: from,
            to: to,
            width: 0,
            layer: 0
        )
    }

    private func closedDrawingSegments(points: [HorizontalPoint]) -> [HorizontalSegment] {
        HorizontalCanvasModeSupport.closedSegmentPairs(points: points).map {
            drawingSegment(from: $0.0, to: $0.1)
        }
    }

    private func drawingArc(from: HorizontalPoint, to: HorizontalPoint, center: HorizontalPoint) -> HorizontalArc {
        HorizontalArc(
            id: "sheet/arc/\(UUID().uuidString.lowercased())",
            from: from,
            to: to,
            center: center,
            width: 0,
            layer: 0
        )
    }

    private func moveSelectionByGrid(_ delta: HorizontalPoint) {
        guard !isReadOnly,
              !selectedObjects.isEmpty,
              delta != .zero else {
            return
        }
        HorizontalMoveRateDiagnostics.mark(.keyMove, active: moveState != nil)

        if moveState == nil {
            beginMove(tracksCursor: false)
            HorizontalMoveRateDiagnostics.mark(.keyMove)
        }

        guard let state = moveState else {
            return
        }

        updateMove(to: state.lastPoint + delta)
    }

    /// "Add Text" (menu bar / rail): prompt for a string, create a sheet text at
    /// the cursor, then enter an interactive move so it follows the cursor until a
    /// click places it (mirrors the board flow).
    private func addText() {
        guard !isReadOnly,
              moveState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil,
              placePartState == nil else {
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
        let position = lastCursorWorldPoint ?? sheet.bounds.center
        let text = HorizontalText(
            id: UUID().uuidString.lowercased(),
            text: content,
            position: position,
            size: 1_500_000,
            layer: nil
        )
        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        draft.texts.append(text)
        #if os(macOS)
        if editAfterCommit {
            // Defer the undo: the whole add-place-edit is ONE undo step,
            // registered at finalize only if real content is typed (cancel =
            // no-op). Stash the pre-add sheet so a cancel can revert cleanly.
            editingTextState = EditTextState(
                ref: text.id,
                worldPosition: position,
                content: content,
                preSheet: previousSheet,
                isNewPlacement: true,
                originalContent: content
            )
            editedSheet = draft
            selectedObjects = [HorizontalSelectableRef(id: text.id, type: .text)]
            hoveredObject = nil
            invalidateSelectableCache()
            onSheetChange(draft)
            publishSelectionContext()
            beginMove(tracksCursor: true, editTextRefOnCommit: text.id)
            return
        }
        #endif
        registerUndoSnapshot(previousSheet, actionName: "Add Text")
        editedSheet = draft
        selectedObjects = [HorizontalSelectableRef(id: text.id, type: .text)]
        hoveredObject = nil
        invalidateSelectableCache()
        onSheetChange(draft)
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
        let placed = (editedSheet ?? sourceSheet).texts.first(where: { normalizedID($0.id) == normalizedID(state.ref) })
        editingTextState = EditTextState(
            ref: state.ref,
            worldPosition: placed?.position ?? state.worldPosition,
            content: placed?.text ?? state.content,
            preSheet: state.preSheet,
            isEditing: true,
            isNewPlacement: state.isNewPlacement,
            originalContent: state.originalContent
        )
    }

    /// Reopen the inline editor on an already-placed text (double-click / "Edit…").
    /// No placeholder phase: the popover appears immediately, anchored at the text.
    /// `preSheet` is the CURRENT sheet so a no-op/empty dismiss restores the
    /// original content; a real change commits one "Edit Text" undo.
    private func beginEditingExistingText(_ ref: HorizontalSelectableRef) {
        guard !isReadOnly,
              moveState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil,
              placePartState == nil,
              editingTextState == nil else {
            return
        }
        let current = editedSheet ?? sourceSheet
        guard let text = current.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        selectedObjects = [HorizontalSelectableRef(id: text.id, type: .text)]
        hoveredObject = nil
        publishSelectionContext()
        editingTextState = EditTextState(
            ref: text.id,
            worldPosition: text.position,
            content: text.text,
            preSheet: current,
            isEditing: true,
            isNewPlacement: false,
            originalContent: text.text
        )
    }

    /// Live update of the text as the user types. The cheap part — the
    /// `editingTextState.content` source of truth `finalizeTextEdit` reads — runs
    /// immediately so the TextField stays responsive; the expensive sheet mutation
    /// + onSheetChange re-render is debounced (~0.1s) so keystrokes never block on
    /// rendering. Registers NO undo (deferred to finalizeTextEdit).
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
    /// content into the sheet draft and re-render through the same onSheetChange
    /// path placeText uses (no undo).
    private func renderEditingTextLive() {
        guard !isReadOnly, let state = editingTextState else { return }
        var draft = editedSheet ?? sourceSheet
        guard let index = draft.texts.firstIndex(where: { normalizedID($0.id) == normalizedID(state.ref) }) else {
            return
        }
        guard draft.texts[index].text != state.content else { return }
        draft.texts[index].text = state.content
        editedSheet = draft
        invalidateSelectableCache()
        onSheetChange(draft)
    }

    /// Dismiss/Return/Esc: finalize new-placement OR existing-edit uniformly.
    /// Empty or unchanged content (`== originalContent`) is a no-op: revert to
    /// `preSheet` — which for a new placement has no text (deletes it) and for an
    /// existing edit holds the original (restores it). A real change commits one
    /// undo step ("Add Text" / "Edit Text").
    private func finalizeTextEdit() {
        guard let state = editingTextState else { return }
        textRenderDebounce?.cancel()
        textRenderDebounce = nil
        editingTextState = nil
        let trimmed = state.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || state.content == state.originalContent {
            editedSheet = state.preSheet
            if state.isNewPlacement {
                selectedObjects = []
                hoveredObject = nil
            }
            invalidateSelectableCache()
            onSheetChange(state.preSheet)
            publishSelectionContext()
            return
        }
        // Commit one undo step with the final content. A pending debounce may
        // never have fired, so apply state.content to the sheet here explicitly.
        var draft = editedSheet ?? sourceSheet
        if let index = draft.texts.firstIndex(where: { normalizedID($0.id) == normalizedID(state.ref) }) {
            draft.texts[index].text = state.content
        }
        editedSheet = draft
        registerUndoSnapshot(state.preSheet, actionName: state.isNewPlacement ? "Add Text" : "Edit Text")
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
    }
    #endif

    private func deleteSelection() {
        guard !isReadOnly,
              moveState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil,
              !selectedObjects.isEmpty else {
            return
        }

        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        guard deleteSelectedObjects(from: &draft) else {
            return
        }

        registerUndoSnapshot(previousSheet, actionName: "Delete")
        editedSheet = draft
        selectedObjects = []
        hoveredObject = nil
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
    }

    private func deleteSelectedObjects(from sheet: inout HorizontalSchematicSheet) -> Bool {
        var changed = false
        let refs = expandedSchematicDeleteRefs(from: uniqueRefs(selectedObjects), in: sheet)

        for ref in refs {
            switch ref.type {
            case .schematicSymbol:
                disconnectSchematicSymbol(ref.id, in: &sheet)
            case .schematicBlockSymbol:
                disconnectSchematicBlockSymbol(ref.id, in: &sheet)
            case .powerSymbol:
                disconnectPowerSymbol(ref.id, in: &sheet)
            case .busRipper:
                replaceBusRipperWithJunctions(ref.id, in: &sheet)
            default:
                break
            }
        }

        for ref in refs {
            if editorProfile.isPoolMode, ref.type == .symbolPin {
                changed = sheet.removeEditablePin(id: ref.id) || changed
                continue
            }
            if editorProfile.isPoolMode, ref.type == .polygonEdge {
                changed = removeElement(from: &sheet.drawingPolygons, matching: ref) || changed
                continue
            }
            switch ref.type {
            case .schematicSymbol:
                changed = deleteSchematicSymbol(ref.id, from: &sheet) || changed
            case .lineNet:
                changed = removeElement(from: &sheet.netLines, matching: ref) || changed
            case .drawingLine:
                changed = removeElement(from: &sheet.drawingLines, matching: ref) || changed
            case .drawingArc:
                changed = removeElement(from: &sheet.drawingArcs, matching: ref) || changed
            case .netLabel:
                changed = removeElement(from: &sheet.netLabels, matching: ref) || changed
            case .busLabel:
                changed = removeElement(from: &sheet.busLabels, matching: ref) || changed
            case .text:
                changed = removeElement(from: &sheet.texts, matching: ref) || changed
            case .schematicNetTie:
                changed = removeElement(from: &sheet.netTies, matching: ref) || changed
            case .powerSymbol:
                changed = deletePowerSymbol(ref.id, from: &sheet) || changed
            case .busRipper:
                changed = deleteBusRipper(ref.id, from: &sheet) || changed
            case .schematicBlockSymbol:
                changed = deleteSchematicBlockSymbol(ref.id, from: &sheet) || changed
            case .junction:
                changed = deleteSchematicJunction(ref.id, from: &sheet) || changed
            case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .symbolPin, .track, .via:
                break
            }
        }

        if changed {
            changed = vacuumUnusedSchematicJunctions(in: &sheet) || changed
        }

        return changed
    }

    private func expandedSchematicDeleteRefs(
        from refs: [HorizontalSelectableRef],
        in sheet: HorizontalSchematicSheet
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
            guard ref.type == .junction,
                  let point = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) })?.value else {
                continue
            }

            let key = pointKey(point)
            for line in sheet.drawingLines where pointKey(line.from) == key || pointKey(line.to) == key {
                append(HorizontalSelectableRef(id: line.id, type: .drawingLine, layer: line.layer))
            }
            for arc in sheet.drawingArcs where pointKey(arc.from) == key || pointKey(arc.to) == key || pointKey(arc.center) == key {
                append(HorizontalSelectableRef(id: arc.id, type: .drawingArc, layer: arc.layer))
            }
            for line in sheet.netLines where pointKey(line.from) == key || pointKey(line.to) == key {
                append(HorizontalSelectableRef(id: line.id, type: .lineNet, layer: line.layer))
            }
            for tie in sheet.netTies where pointKey(tie.from) == key || pointKey(tie.to) == key {
                append(HorizontalSelectableRef(id: tie.id, type: .schematicNetTie))
            }
            for label in sheet.netLabels where pointKey(label.position) == key {
                append(HorizontalSelectableRef(id: label.id, type: .netLabel))
            }
            for label in sheet.busLabels where pointKey(label.position) == key {
                append(HorizontalSelectableRef(id: label.id, type: .busLabel))
            }
            for symbolID in powerSymbolIDs(in: sheet) where powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet).contains(where: { pointKey($0) == key }) {
                append(HorizontalSelectableRef(id: symbolID, type: .powerSymbol))
            }
            for ripperID in busRipperIDs(in: sheet) where busRipperConnectionPoints(ripperID: ripperID, sheet: sheet).contains(where: { pointKey($0) == key }) {
                append(HorizontalSelectableRef(id: ripperID, type: .busRipper))
            }
        }

        return expanded
    }

    private func disconnectSchematicSymbol(_ symbolID: String, in sheet: inout HorizontalSchematicSheet) {
        for connection in schematicSymbolConnectionPoints(symbolID: symbolID, sheet: sheet) {
            guard hasNetLineEndpoint(at: connection.point, netID: connection.netID, in: sheet) else {
                continue
            }
            _ = ensureJunction(at: connection.point, preferredID: nil, netID: connection.netID, sheet: &sheet)
        }
    }

    private func disconnectSchematicBlockSymbol(_ blockSymbolID: String, in sheet: inout HorizontalSchematicSheet) {
        for port in sheet.blockSymbolPorts where geometryID(port.id, belongsTo: blockSymbolID, separators: ["block-port", "port"]) {
            for point in [port.from, port.to] where hasNetLineEndpoint(at: point, netID: port.netID, in: sheet) {
                _ = ensureJunction(at: point, preferredID: nil, netID: port.netID, sheet: &sheet)
            }
        }
    }

    private func disconnectPowerSymbol(_ symbolID: String, in sheet: inout HorizontalSchematicSheet) {
        for point in powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet) {
            let netID = netID(at: point, in: sheet)
            guard hasNetLineEndpoint(at: point, netID: netID, in: sheet) else {
                continue
            }
            _ = ensureJunction(at: point, preferredID: nil, netID: netID, sheet: &sheet)
        }
    }

    private func replaceBusRipperWithJunctions(_ ripperID: String, in sheet: inout HorizontalSchematicSheet) {
        for point in busRipperConnectionPoints(ripperID: ripperID, sheet: sheet) {
            let netID = netID(at: point, in: sheet)
            guard hasNetLineEndpoint(at: point, netID: netID, in: sheet) else {
                continue
            }
            _ = ensureJunction(at: point, preferredID: nil, netID: netID, sheet: &sheet)
        }
    }

    private func netID(at point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> String? {
        let key = pointKey(point)
        if let junctionID = junctionID(at: point, in: sheet),
           let netID = sheet.junctionNetIDs[junctionID] {
            return netID
        }

        for label in sheet.netLabels where pointKey(label.position) == key {
            return label.netID
        }

        let netBearingSegments = sheet.netLines
            + sheet.symbolPins
            + sheet.blockSymbolPorts
            + sheet.busRipperLines
            + sheet.powerSymbolLines
        for segment in netBearingSegments where segment.netID != nil {
            if pointKey(segment.from) == key || pointKey(segment.to) == key || pointLiesOnSegment(point, segment) {
                return segment.netID
            }
        }

        for circle in sheet.symbolPinCircles + sheet.powerSymbolCircles
            where circle.netID != nil && pointKey(circle.center) == key {
            return circle.netID
        }

        return nil
    }

    private func hasNetLineEndpoint(at point: HorizontalPoint, netID: String?, in sheet: HorizontalSchematicSheet) -> Bool {
        let key = pointKey(point)
        return sheet.netLines.contains { line in
            (pointKey(line.from) == key || pointKey(line.to) == key) && netsMatch(line.netID, netID)
        }
    }

    private func deleteSchematicSymbol(_ symbolID: String, from sheet: inout HorizontalSchematicSheet) -> Bool {
        let normalizedSymbolID = normalizedID(symbolID)
        var changed = removeAll(from: &sheet.symbols) { normalizedID($0.id) == normalizedSymbolID }

        func belongsToSymbol(_ geometryID: String) -> Bool {
            self.symbolID(forGeometryID: geometryID).map(normalizedID) == normalizedSymbolID
        }

        changed = removeAll(from: &sheet.symbolLines) { belongsToSymbol($0.id) } || changed
        changed = removeAll(from: &sheet.symbolPins) { belongsToSymbol($0.id) } || changed
        changed = removeAll(from: &sheet.symbolPinCircles) { belongsToSymbol($0.id) } || changed
        changed = removeAll(from: &sheet.symbolPolygons) { belongsToSymbol($0.id) } || changed
        changed = removeAll(from: &sheet.symbolTexts) { belongsToSymbol($0.id) } || changed
        changed = removeAll(from: &sheet.noPopulateMarks) { normalizedID($0.symbolID) == normalizedSymbolID } || changed
        return changed
    }

    private func deleteSchematicBlockSymbol(_ blockSymbolID: String, from sheet: inout HorizontalSchematicSheet) -> Bool {
        let separators: Set<String> = ["block-line", "block-port", "block-text", "line", "port", "text"]
        var changed = removeAll(from: &sheet.blockSymbolLines) {
            geometryID($0.id, belongsTo: blockSymbolID, separators: separators)
        }
        changed = removeAll(from: &sheet.blockSymbolPorts) {
            geometryID($0.id, belongsTo: blockSymbolID, separators: separators)
        } || changed
        changed = removeAll(from: &sheet.blockSymbolTexts) {
            geometryID($0.id, belongsTo: blockSymbolID, separators: separators)
        } || changed
        return changed
    }

    private func deletePowerSymbol(_ symbolID: String, from sheet: inout HorizontalSchematicSheet) -> Bool {
        let separators: Set<String> = ["circle", "line", "text"]
        var changed = removeAll(from: &sheet.powerSymbolLines) {
            geometryID($0.id, belongsTo: symbolID, separators: separators)
        }
        changed = removeAll(from: &sheet.powerSymbolCircles) {
            geometryID($0.id, belongsTo: symbolID, separators: separators)
        } || changed
        changed = removeAll(from: &sheet.powerSymbolTexts) {
            geometryID($0.id, belongsTo: symbolID, separators: separators)
        } || changed
        changed = removeAll(from: &sheet.powerSymbols) {
            normalizedID($0.id) == normalizedID(symbolID)
        } || changed
        return changed
    }

    private func deleteBusRipper(_ ripperID: String, from sheet: inout HorizontalSchematicSheet) -> Bool {
        let separators: Set<String> = ["bus-ripper", "line", "text"]
        var changed = removeAll(from: &sheet.busRipperLines) {
            geometryID($0.id, belongsTo: ripperID, separators: separators)
        }
        changed = removeAll(from: &sheet.busRipperTexts) {
            geometryID($0.id, belongsTo: ripperID, separators: separators)
        } || changed
        return changed
    }

    private func deleteSchematicJunction(_ junctionID: String, from sheet: inout HorizontalSchematicSheet) -> Bool {
        guard let key = sheet.junctions.keys.first(where: { normalizedID($0) == normalizedID(junctionID) }) else {
            return false
        }
        sheet.junctions.removeValue(forKey: key)
        sheet.junctionNetIDs.removeValue(forKey: key)
        return true
    }

    private func vacuumUnusedSchematicJunctions(in sheet: inout HorizontalSchematicSheet) -> Bool {
        var attachedKeys = Set<String>()

        func mark(_ point: HorizontalPoint) {
            attachedKeys.insert(pointKey(point))
        }

        for segment in sheet.netLines {
            mark(segment.from)
            mark(segment.to)
        }

        for segment in sheet.drawingLines {
            mark(segment.from)
            mark(segment.to)
        }

        for arc in sheet.drawingArcs {
            mark(arc.from)
            mark(arc.to)
            mark(arc.center)
        }

        for label in sheet.netLabels {
            mark(label.position)
        }

        for label in sheet.busLabels {
            mark(label.position)
        }

        for tie in sheet.netTies {
            mark(tie.from)
            mark(tie.to)
        }

        for symbolID in powerSymbolIDs(in: sheet) {
            for point in powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet) {
                mark(point)
            }
        }

        for ripperID in busRipperIDs(in: sheet) {
            for point in busRipperConnectionPoints(ripperID: ripperID, sheet: sheet) {
                mark(point)
            }
        }

        let unusedJunctionIDs = sheet.junctions.compactMap { junctionID, point in
            attachedKeys.contains(pointKey(point)) ? nil : junctionID
        }
        guard !unusedJunctionIDs.isEmpty else {
            return false
        }

        for junctionID in unusedJunctionIDs {
            sheet.junctions.removeValue(forKey: junctionID)
            sheet.junctionNetIDs.removeValue(forKey: junctionID)
        }
        return true
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
        if placePinState != nil {
            mirrorPlacingPin()
            return
        }
        let cursor = lastCursorWorldPoint
        transformSelection(actionName: "Mirror") { center, draft in
            mirrorSelectedObjects(around: cursor ?? center, sheet: &draft)
        }
    }

    private func rotateSelection() {
        if placePinState != nil {
            rotatePlacingPin()
            return
        }
        let cursor = lastCursorWorldPoint
        transformSelection(actionName: "Rotate") { center, draft in
            rotateSelectedObjects(around: cursor ?? center, by: Self.quarterTurnAngle, sheet: &draft)
        }
    }

    private func twirlSelection() {
        let cursor = lastCursorWorldPoint
        transformSelection(actionName: "Twirl") { center, draft in
            rotateSelectedObjects(around: cursor ?? center, by: Self.quarterTurnAngle, sheet: &draft)
        }
    }

    private func transformSelection(
        actionName: String,
        _ transform: (HorizontalPoint, inout HorizontalSchematicSheet) -> Void
    ) {
        guard !isReadOnly,
              !selectedObjects.isEmpty else {
            return
        }

        if var state = moveState {
            let currentPreview = schematicMovePreviewSheet(for: state)
            guard let center = schematicSelectionCenter(in: currentPreview) else {
                return
            }

            var transformedPreview = currentPreview
            transform(center, &transformedPreview)
            state.originalSheet = transformedPreview
            state.startPoint = state.lastPoint
            state.connectionPlan = selectedSchematicSymbolMoveConnectionPlan(in: transformedPreview)
            state.connectionMovePlan = selectedSchematicConnectionMovePlan(in: transformedPreview)
            state.fixedConnectionPointKeys = schematicFixedConnectionPointKeys(in: transformedPreview)
            moveState = state
            editedSheet = transformedPreview
            invalidateSelectableCache()
            hoveredObject = nil
            publishSelectionContext()
            return
        }

        guard let center = schematicSelectionCenter() else {
            return
        }

        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        transform(center, &draft)
        editedSheet = draft
        invalidateSelectableCache()
        hoveredObject = nil
        registerUndoSnapshot(previousSheet, actionName: actionName)
        onSheetChange(draft)
        publishSelectionContext()
    }

    private func schematicSelectionCenter() -> HorizontalPoint? {
        schematicSelectionCenter(in: sheet)
    }

    private func schematicSelectionCenter(in sheet: HorizontalSchematicSheet) -> HorizontalPoint? {
        HorizontalCanvasModeSupport.selectionCenter(for: selectedObjects) { ref in
            selectionAnchorPoints(for: ref, in: sheet)
        }
    }

    private func selectionAnchorPoints(for ref: HorizontalSelectableRef) -> [HorizontalPoint] {
        selectionAnchorPoints(for: ref, in: sheet)
    }

    private func selectionAnchorPoints(for ref: HorizontalSelectableRef, in sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        if editorProfile.isPoolMode {
            if ref.type == .symbolPin {
                return sheet.editablePin(id: ref.id).map { [$0.position] } ?? []
            }
            if ref.type == .polygonEdge {
                return drawingPolygon(for: ref, in: sheet)?.vertices ?? []
            }
        }
        switch ref.type {
        case .schematicSymbol:
            return sheet.symbols.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        case .lineNet:
            return lineSelectionAnchorPoints(for: ref, in: sheet.netLines)
        case .drawingLine:
            return lineSelectionAnchorPoints(for: ref, in: sheet.drawingLines)
        case .drawingArc:
            return sheet.drawingArcs.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.from, $0.to, $0.center] } ?? []
        case .junction:
            return sheet.junctions.first { normalizedID($0.key) == normalizedID(ref.id) }.map { [$0.value] } ?? []
        case .netLabel:
            return sheet.netLabels.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        case .busLabel:
            return sheet.busLabels.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        case .powerSymbol:
            return powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet)
        case .busRipper:
            return busRipperConnectionPoints(ripperID: ref.id, sheet: sheet)
        case .schematicBlockSymbol:
            return schematicBlockSymbolConnectionPoints(blockSymbolID: ref.id, sheet: sheet)
                + groupedSchematicGeometryPoints(
                    objectID: ref.id,
                    segments: sheet.blockSymbolLines,
                    texts: sheet.blockSymbolTexts,
                    separators: ["line", "port", "text"]
                )
        case .schematicNetTie:
            return sheet.netTies.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.from, $0.to] } ?? []
        case .text:
            return sheet.texts.first { normalizedID($0.id) == normalizedID(ref.id) }.map { [$0.position] } ?? []
        default:
            return []
        }
    }

    private func rotationVertex(for ref: HorizontalSelectableRef, in sheet: HorizontalSchematicSheet) -> HorizontalPoint? {
        switch ref.type {
        case .drawingArc:
            return sheet.drawingArcs.first { normalizedID($0.id) == normalizedID(ref.id) }?.center
                ?? selectionAnchorPoints(for: ref, in: sheet).first
        default:
            return selectionAnchorPoints(for: ref, in: sheet).first
        }
    }

    private func lineSelectionAnchorPoints(for ref: HorizontalSelectableRef, in segments: [HorizontalSegment]) -> [HorizontalPoint] {
        HorizontalCanvasModeSupport.lineSelectionAnchorPoints(for: ref, in: segments)
    }

    private func expandedSchematicMoveSelection(
        _ refs: [HorizontalSelectableRef],
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalSelectableRef] {
        var expanded = [HorizontalSelectableRef]()
        for ref in refs {
            switch ref.type {
            case .lineNet:
                expanded.append(ref)
                expanded.append(contentsOf: schematicSegmentEndpointJunctionRefs(for: ref, in: sheet.netLines, sheet: sheet))
            case .drawingLine:
                expanded.append(ref)
                expanded.append(contentsOf: schematicSegmentEndpointJunctionRefs(for: ref, in: sheet.drawingLines, sheet: sheet))
            case .drawingArc:
                expanded.append(ref)
                expanded.append(contentsOf: schematicArcJunctionRefs(for: ref, in: sheet))
            case .powerSymbol:
                let junctionRefs = schematicPowerSymbolOwningJunctionRefs(for: ref, in: sheet)
                if junctionRefs.isEmpty {
                    expanded.append(ref)
                } else {
                    expanded.append(contentsOf: junctionRefs)
                }
            default:
                expanded.append(ref)
            }
        }
        return uniqueRefs(expanded)
    }

    private func schematicSegmentEndpointJunctionRefs(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        sheet: HorizontalSchematicSheet
    ) -> [HorizontalSelectableRef] {
        guard let line = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }

        return [line.from, line.to].compactMap { point in
            junctionID(at: point, in: sheet).map {
                HorizontalSelectableRef(id: $0, type: .junction)
            }
        }
    }

    private func schematicArcJunctionRefs(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalSelectableRef] {
        guard let arc = sheet.drawingArcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }

        return [arc.from, arc.to, arc.center].compactMap { point in
            junctionID(at: point, in: sheet).map {
                HorizontalSelectableRef(id: $0, type: .junction)
            }
        }
    }

    private func schematicPowerSymbolOwningJunctionRefs(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalSelectableRef] {
        powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet).compactMap { point in
            junctionID(at: point, in: sheet).map {
                HorizontalSelectableRef(id: $0, type: .junction)
            }
        }
    }

    private func moveSelectedObjects(
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        symbolConnectionPlan: SchematicSymbolMoveConnectionPlan? = nil,
        connectionMovePlan cachedConnectionMovePlan: SchematicConnectionMovePlan? = nil,
        fixedConnectionPointKeys: Set<String>? = nil
    ) {
        var movedJunctionKeys = Set<String>()
        var movedDrawingVertexKeys = Set<String>()
        var movedSymbolConnectionTargets = Set<SchematicSymbolMoveConnectionTarget>()
        let connectionMovePlan = cachedConnectionMovePlan ?? selectedSchematicConnectionMovePlan(in: sheet)
        let selectedJunctionIDs = selectedSchematicJunctionIDs()
        let fixedConnectionPointKeys = fixedConnectionPointKeys ?? schematicFixedConnectionPointKeys(in: sheet)

        for point in connectionMovePlan.points {
            moveSelectedSchematicConnectionPoint(
                at: point,
                by: delta,
                sheet: &sheet,
                movedKeys: &movedJunctionKeys,
                fixedConnectionPointKeys: fixedConnectionPointKeys
            )
        }

        for ref in selectedObjects {
            if connectionMovePlan.handledRefs.contains(ref) {
                continue
            }
            if editorProfile.isPoolMode, movePoolEditorObject(ref: ref, by: delta, sheet: &sheet) {
                continue
            }

            switch ref.type {
            case .schematicSymbol:
                moveSchematicSymbol(
                    ref: ref,
                    by: delta,
                    sheet: &sheet,
                    movedKeys: &movedJunctionKeys,
                    connectionPlan: filteredSchematicSymbolConnectionPlan(
                        symbolConnectionPlan,
                        for: ref,
                        excludingJunctionIDs: selectedJunctionIDs
                    ),
                    movedConnectionTargets: &movedSymbolConnectionTargets
                )
            case .lineNet:
                break
            case .drawingLine:
                moveDrawingSegmentSelection(&sheet.drawingLines, ref: ref, by: delta, movedKeys: &movedDrawingVertexKeys)
            case .drawingArc:
                moveArc(&sheet.drawingArcs, ref: ref, by: delta)
            case .junction:
                moveSchematicJunction(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .netLabel:
                moveNetLabel(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .busLabel:
                moveBusLabel(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .text:
                moveText(&sheet.texts, ref: ref, by: delta)
            case .schematicNetTie:
                moveNetTie(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .powerSymbol:
                movePowerSymbol(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .busRipper:
                moveBusRipper(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .schematicBlockSymbol:
                moveSchematicBlockSymbol(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .symbolPin, .track, .via:
                break
            }
        }
    }

    private func moveSelectedObjectsGeometrically(
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        excluding handledRefs: Set<HorizontalSelectableRef> = []
    ) {
        guard delta != .zero else {
            return
        }

        var movedJunctionKeys = Set<String>()
        var movedDrawingVertexKeys = Set<String>()
        let movingSymbolIDs = Set(
            selectedObjects
                .filter { $0.type == .schematicSymbol && !handledRefs.contains($0) }
                .map { normalizedID($0.id) }
        )
        if !movingSymbolIDs.isEmpty {
            for index in sheet.symbols.indices where movingSymbolIDs.contains(normalizedID(sheet.symbols[index].id)) {
                sheet.symbols[index].position = sheet.symbols[index].position + delta
            }
            shiftSchematicSymbolsGeometry(symbolIDs: movingSymbolIDs, by: delta, sheet: &sheet)
        }

        for ref in selectedObjects {
            if handledRefs.contains(ref) {
                continue
            }
            if editorProfile.isPoolMode, movePoolEditorObject(ref: ref, by: delta, sheet: &sheet) {
                continue
            }
            switch ref.type {
            case .schematicSymbol:
                break
            case .lineNet:
                break
            case .drawingLine:
                moveDrawingSegmentSelection(&sheet.drawingLines, ref: ref, by: delta, movedKeys: &movedDrawingVertexKeys)
            case .drawingArc:
                moveArc(&sheet.drawingArcs, ref: ref, by: delta)
            case .junction:
                moveSchematicJunctionGeometry(ref: ref, by: delta, sheet: &sheet)
            case .netLabel:
                moveNetLabelGeometry(ref: ref, by: delta, sheet: &sheet)
            case .busLabel:
                moveBusLabelGeometry(ref: ref, by: delta, sheet: &sheet)
            case .text:
                moveText(&sheet.texts, ref: ref, by: delta)
            case .schematicNetTie:
                moveNetTieGeometry(ref: ref, by: delta, sheet: &sheet)
            case .powerSymbol:
                movePowerSymbol(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .busRipper:
                moveBusRipper(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .schematicBlockSymbol:
                moveSchematicBlockSymbol(ref: ref, by: delta, sheet: &sheet, movedKeys: &movedJunctionKeys)
            case .blockSymbolPort:
                moveSegment(&sheet.blockSymbolPorts, ref: ref, by: delta)
            case .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .symbolPin, .track, .via:
                break
            }
        }
    }

    private func moveSelectedObjectsForPreview(
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        symbolConnectionPlan: SchematicSymbolMoveConnectionPlan,
        connectionMovePlan: SchematicConnectionMovePlan,
        fixedConnectionPointKeys: Set<String>
    ) {
        guard delta != .zero else {
            return
        }

        var movedJunctionKeys = Set<String>()
        var movedConnectionTargets = Set<SchematicSymbolMoveConnectionTarget>()
        let selectedJunctionIDs = selectedSchematicJunctionIDs()

        for ref in selectedObjects where ref.type == .schematicSymbol {
            let targets = symbolConnectionPlan.targetsBySymbolID[normalizedID(ref.id)] ?? []
            let previewTargets = targets.filter { target in
                switch target {
                case .netLineFrom, .netLineTo:
                    return true
                case .junction(let junctionID):
                    return !selectedJunctionIDs.contains(normalizedID(junctionID))
                }
            }
            movePlannedSchematicSymbolConnections(
                previewTargets,
                by: delta,
                sheet: &sheet,
                movedKeys: &movedJunctionKeys,
                movedConnectionTargets: &movedConnectionTargets
            )
        }

        for point in connectionMovePlan.points {
            moveSelectedSchematicConnectionPoint(
                at: point,
                by: delta,
                sheet: &sheet,
                movedKeys: &movedJunctionKeys,
                fixedConnectionPointKeys: fixedConnectionPointKeys
            )
        }

        moveSelectedObjectsGeometrically(
            by: delta,
            sheet: &sheet,
            excluding: connectionMovePlan.handledRefs
        )
    }

    private func selectedSchematicJunctionIDs() -> Set<String> {
        Set(
            selectedObjects
                .filter { $0.type == .junction }
                .map { normalizedID($0.id) }
        )
    }

    private func filteredSchematicSymbolConnectionPlan(
        _ plan: SchematicSymbolMoveConnectionPlan?,
        for ref: HorizontalSelectableRef,
        excludingJunctionIDs selectedJunctionIDs: Set<String>
    ) -> SchematicSymbolMoveConnectionPlan? {
        guard let plan,
              let targets = plan.targetsBySymbolID[normalizedID(ref.id)] else {
            return plan
        }

        var filteredPlan = SchematicSymbolMoveConnectionPlan()
        filteredPlan.targetsBySymbolID[normalizedID(ref.id)] = targets.filter { target in
            switch target {
            case .netLineFrom, .netLineTo:
                return true
            case .junction(let junctionID):
                return !selectedJunctionIDs.contains(normalizedID(junctionID))
            }
        }
        return filteredPlan
    }

    private func selectedSchematicConnectionMovePlan(in sheet: HorizontalSchematicSheet) -> SchematicConnectionMovePlan {
        var plan = SchematicConnectionMovePlan()

        func appendConnectionPoint(_ point: HorizontalPoint, for ref: HorizontalSelectableRef) -> Bool {
            plan.points.append(point)
            plan.handledRefs.insert(ref)
            plan.affectedRefs.insert(ref)
            plan.affectedRefs.formUnion(schematicConnectionAffectedRefs(at: point, in: sheet))
            return true
        }

        for ref in selectedObjects {
            switch ref.type {
            case .lineNet:
                plan.handledRefs.insert(ref)
                plan.affectedRefs.insert(ref)
            case .drawingLine:
                let junctionRefs = schematicSegmentEndpointJunctionRefs(for: ref, in: sheet.drawingLines, sheet: sheet)
                if !junctionRefs.isEmpty {
                    plan.handledRefs.insert(ref)
                    plan.affectedRefs.insert(ref)
                }
            case .drawingArc:
                let junctionRefs = schematicArcJunctionRefs(for: ref, in: sheet)
                if !junctionRefs.isEmpty {
                    plan.handledRefs.insert(ref)
                    plan.affectedRefs.insert(ref)
                }
            case .junction:
                guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
                    continue
                }
                _ = appendConnectionPoint(junction.value, for: ref)
            case .netLabel:
                guard let label = sheet.netLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                    continue
                }
                _ = appendConnectionPoint(label.position, for: ref)
            case .busLabel:
                guard let label = sheet.busLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                    continue
                }
                _ = appendConnectionPoint(label.position, for: ref)
            case .schematicNetTie:
                guard let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                    continue
                }
                _ = appendConnectionPoint(tie.from, for: ref)
                _ = appendConnectionPoint(tie.to, for: ref)
                plan.handledRefs.insert(ref)
            case .schematicSymbol, .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .busRipper, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .symbolPin, .text, .track, .via:
                break
            }
        }

        return plan
    }

    private func schematicConnectionAffectedRefs(
        at point: HorizontalPoint,
        in sheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        let powerSymbolAnchors = Dictionary(
            powerSymbolIDs(in: sheet).map { symbolID in
                (symbolID, powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return SchematicMovePlanner.connectionAffectedRefs(
            at: point,
            netLines: sheet.netLines,
            drawingLines: sheet.drawingLines,
            drawingArcs: sheet.drawingArcs,
            busRipperLines: sheet.busRipperLines,
            netTies: sheet.netTies,
            netLabels: sheet.netLabels,
            busLabels: sheet.busLabels,
            junctions: sheet.junctions,
            powerSymbolAnchors: powerSymbolAnchors
        )
    }

    private func selectedSchematicSymbolMoveConnectionPlan(in sheet: HorizontalSchematicSheet) -> SchematicSymbolMoveConnectionPlan {
        var plan = SchematicSymbolMoveConnectionPlan()
        for ref in selectedObjects where ref.type == .schematicSymbol {
            let targets = schematicSymbolMoveConnectionTargets(symbolID: ref.id, sheet: sheet)
            plan.targetsBySymbolID[normalizedID(ref.id)] = targets
        }
        return plan
    }

    private func schematicSymbolMoveConnectionTargets(
        symbolID: String,
        sheet: HorizontalSchematicSheet
    ) -> [SchematicSymbolMoveConnectionTarget] {
        let connectionPoints = schematicSymbolConnectionPoints(symbolID: symbolID, sheet: sheet)
        guard !connectionPoints.isEmpty else {
            return []
        }

        let connectedKeys = Set(connectionPoints.map { pointKey($0.point) })
        let wildcardConnectionKeys = Set(connectionPoints.compactMap { point -> String? in
            point.netID == nil ? pointKey(point.point) : nil
        })
        let netConnectionKeys = Set(connectionPoints.compactMap { point -> String? in
            guard let netID = point.netID else {
                return nil
            }
            return "\(pointKey(point.point)):\(normalizedID(netID))"
        })

        func isSymbolConnection(at point: HorizontalPoint, netID: String?) -> Bool {
            let key = pointKey(point)
            guard connectedKeys.contains(key) else {
                return false
            }
            guard let netID else {
                return true
            }
            return wildcardConnectionKeys.contains(key) || netConnectionKeys.contains("\(key):\(normalizedID(netID))")
        }

        var targets = Set<SchematicSymbolMoveConnectionTarget>()
        for line in sheet.netLines {
            let lineID = normalizedID(line.id)
            if isSymbolConnection(at: line.from, netID: line.netID) {
                targets.insert(.netLineFrom(lineID))
            }
            if isSymbolConnection(at: line.to, netID: line.netID) {
                targets.insert(.netLineTo(lineID))
            }
        }

        for (junctionID, point) in sheet.junctions where connectedKeys.contains(pointKey(point)) {
            targets.insert(.junction(junctionID))
        }

        return Array(targets)
    }

    private func mirrorSelectedObjects(around center: HorizontalPoint, sheet: inout HorizontalSchematicSheet) {
        var transformedJunctionKeys = Set<String>()
        let selectedPowerSymbolAnchorKeys = selectedPowerSymbolAnchorKeys(in: sheet)

        for ref in uniqueSelectedObjectRefs() {
            if editorProfile.isPoolMode, mirrorPoolEditorObject(ref: ref, around: center, sheet: &sheet) {
                continue
            }
            switch ref.type {
            case .schematicSymbol:
                mirrorSchematicSymbol(ref: ref, around: center, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .lineNet:
                mirrorSchematicNetLine(ref: ref, around: center, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .drawingLine:
                mirrorSegment(&sheet.drawingLines, ref: ref, around: center)
            case .drawingArc:
                mirrorArc(&sheet.drawingArcs, ref: ref, around: center)
            case .junction:
                guard !junction(ref, isInAnchorKeys: selectedPowerSymbolAnchorKeys, sheet: sheet) else {
                    continue
                }
                mirrorSchematicJunction(ref: ref, around: center, sheet: &sheet, transformedKeys: &transformedJunctionKeys)
            case .netLabel:
                mirrorNetLabel(ref: ref, around: center, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .busLabel:
                mirrorBusLabel(ref: ref, around: center, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .text:
                mirrorText(&sheet.texts, ref: ref, around: center)
            case .schematicNetTie:
                mirrorNetTie(ref: ref, around: center, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .powerSymbol:
                mirrorPowerSymbol(ref: ref, around: center, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .busRipper, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .schematicBlockSymbol, .symbolPin, .track, .via:
                break
            }
        }
    }

    private func rotateSelectedObjects(around center: HorizontalPoint, by angleDelta: Int, sheet: inout HorizontalSchematicSheet) {
        rotateSelectedObjects(by: angleDelta, sheet: &sheet) { _ in center }
    }

    private func rotateSelectedObjectsAroundVertices(by angleDelta: Int, sheet: inout HorizontalSchematicSheet) {
        let origins = uniqueSelectedObjectRefs().reduce(into: [HorizontalSelectableRef: HorizontalPoint]()) { result, ref in
            result[ref] = rotationVertex(for: ref, in: sheet)
        }
        rotateSelectedObjects(by: angleDelta, sheet: &sheet) { ref in
            origins[ref]
        }
    }

    private func rotateSelectedObjects(
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        originFor refOrigin: (HorizontalSelectableRef) -> HorizontalPoint?
    ) {
        var transformedJunctionKeys = Set<String>()
        let selectedPowerSymbolAnchorKeys = selectedPowerSymbolAnchorKeys(in: sheet)

        for ref in uniqueSelectedObjectRefs() {
            guard let center = refOrigin(ref) else {
                continue
            }
            if editorProfile.isPoolMode, rotatePoolEditorObject(ref: ref, around: center, by: angleDelta, sheet: &sheet) {
                continue
            }
            switch ref.type {
            case .schematicSymbol:
                rotateSchematicSymbol(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .lineNet:
                rotateSchematicNetLine(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .drawingLine:
                rotateSegment(&sheet.drawingLines, ref: ref, around: center, by: angleDelta)
            case .drawingArc:
                rotateArc(&sheet.drawingArcs, ref: ref, around: center, by: angleDelta)
            case .junction:
                guard !junction(ref, isInAnchorKeys: selectedPowerSymbolAnchorKeys, sheet: sheet) else {
                    continue
                }
                rotateSchematicJunction(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedKeys: &transformedJunctionKeys)
            case .netLabel:
                rotateNetLabel(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .busLabel:
                rotateBusLabel(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .text:
                rotateText(&sheet.texts, ref: ref, around: center, by: angleDelta)
            case .schematicNetTie:
                rotateNetTie(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .powerSymbol:
                rotatePowerSymbol(ref: ref, around: center, by: angleDelta, sheet: &sheet, transformedJunctionKeys: &transformedJunctionKeys)
            case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .busRipper, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .schematicBlockSymbol, .symbolPin, .track, .via:
                break
            }
        }
    }

    private func uniqueSelectedObjectRefs() -> [HorizontalSelectableRef] {
        var seen = Set<String>()
        var refs = [HorizontalSelectableRef]()
        for ref in selectedObjects {
            let key = [
                ref.type.rawValue,
                normalizedID(ref.id),
                String(ref.vertex),
                ref.layer.map(String.init) ?? "nil",
            ].joined(separator: ":")
            guard seen.insert(key).inserted else {
                continue
            }
            refs.append(ref)
        }
        return refs
    }

    private func selectedPowerSymbolAnchorKeys(in sheet: HorizontalSchematicSheet) -> Set<String> {
        selectedObjects.reduce(into: Set<String>()) { result, ref in
            guard ref.type == .powerSymbol else {
                return
            }
            for point in powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet) {
                result.insert(pointKey(point))
            }
        }
    }

    private func junction(
        _ ref: HorizontalSelectableRef,
        isInAnchorKeys anchorKeys: Set<String>,
        sheet: HorizontalSchematicSheet
    ) -> Bool {
        guard ref.type == .junction,
              let point = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) })?.value else {
            return false
        }
        return anchorKeys.contains(pointKey(point))
    }

    private func mirrorSchematicSymbol(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let connections = schematicSymbolConnectionPoints(symbolID: ref.id, sheet: sheet)
        mirrorSchematicSymbolGeometry(symbolID: ref.id, around: center, sheet: &sheet)
        sheet.symbols[index].position = mirrored(sheet.symbols[index].position, around: center)
        sheet.symbols[index].mirrored.toggle()

        for connection in connections {
            let mirroredPoint = mirrored(connection.point, around: center)
            moveSchematicConnectionPoint(
                at: connection.point,
                to: mirroredPoint,
                netID: connection.netID,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .mirroredAround(center)
            )
        }
    }

    private func rotateSchematicSymbol(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.symbols[index]
        let connections = schematicSymbolConnectionPoints(symbolID: ref.id, sheet: sheet)
        rotateSchematicSymbolGeometry(symbolID: ref.id, around: center, by: angleDelta, sheet: &sheet)
        sheet.symbols[index].position = rotated(original.position, around: center, by: angleDelta)
        sheet.symbols[index].angle = wrappedAngle(original.angle + (original.mirrored ? -angleDelta : angleDelta))

        for connection in connections {
            let rotatedPoint = rotated(connection.point, around: center, by: angleDelta)
            moveSchematicConnectionPoint(
                at: connection.point,
                to: rotatedPoint,
                netID: connection.netID,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
            )
        }
    }

    private func mirrorSchematicNetLine(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.netLines.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.netLines[index]
        if hasSchematicJunction(at: original.from, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.from,
                to: mirrored(original.from, around: center),
                netID: original.netID,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .mirroredAround(center)
            )
        } else {
            sheet.netLines[index].from = mirrored(original.from, around: center)
        }

        if hasSchematicJunction(at: original.to, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.to,
                to: mirrored(original.to, around: center),
                netID: original.netID,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .mirroredAround(center)
            )
        } else if let updatedIndex = sheet.netLines.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netLines[updatedIndex].to = mirrored(original.to, around: center)
        }
    }

    private func rotateSchematicNetLine(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.netLines.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.netLines[index]
        if hasSchematicJunction(at: original.from, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.from,
                to: rotated(original.from, around: center, by: angleDelta),
                netID: original.netID,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
            )
        } else {
            sheet.netLines[index].from = rotated(original.from, around: center, by: angleDelta)
        }

        if hasSchematicJunction(at: original.to, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.to,
                to: rotated(original.to, around: center, by: angleDelta),
                netID: original.netID,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
            )
        } else if let updatedIndex = sheet.netLines.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netLines[updatedIndex].to = rotated(original.to, around: center, by: angleDelta)
        }
    }

    private func mirrorSchematicJunction(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedKeys: inout Set<String>
    ) {
        guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
            return
        }

        mirrorPowerSymbolsAttached(
            at: junction.value,
            around: center,
            sheet: &sheet,
            transformedKeys: &transformedKeys
        )
        moveSchematicConnectionPoint(
            at: junction.value,
            to: mirrored(junction.value, around: center),
            netID: netID(forJunctionID: junction.key),
            sheet: &sheet,
            movedKeys: &transformedKeys,
            attachedPowerSymbolTransform: .mirroredAround(center)
        )
    }

    private func rotateSchematicJunction(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedKeys: inout Set<String>
    ) {
        guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
            return
        }

        rotatePowerSymbolsAttached(
            at: junction.value,
            around: center,
            by: angleDelta,
            sheet: &sheet,
            transformedKeys: &transformedKeys
        )
        moveSchematicConnectionPoint(
            at: junction.value,
            to: rotated(junction.value, around: center, by: angleDelta),
            netID: netID(forJunctionID: junction.key),
            sheet: &sheet,
            movedKeys: &transformedKeys,
            attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
        )
    }

    private func powerSymbolIDs(attachedAt point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> [String] {
        let key = pointKey(point)
        return powerSymbolIDs(in: sheet).filter { symbolID in
            powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet).contains {
                pointKey($0) == key
            }
        }
    }

    private func mirrorPowerSymbolsAttached(
        at point: HorizontalPoint,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedKeys: inout Set<String>
    ) {
        for symbolID in powerSymbolIDs(attachedAt: point, in: sheet) {
            let key = "power-symbol:\(normalizedID(symbolID))"
            guard transformedKeys.insert(key).inserted else {
                continue
            }
            mirrorPowerSymbolGeometry(symbolID: symbolID, around: center, sheet: &sheet)
        }
    }

    private func rotatePowerSymbolsAttached(
        at point: HorizontalPoint,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedKeys: inout Set<String>
    ) {
        for symbolID in powerSymbolIDs(attachedAt: point, in: sheet) {
            let key = "power-symbol:\(normalizedID(symbolID))"
            guard transformedKeys.insert(key).inserted else {
                continue
            }
            rotatePowerSymbolGeometry(symbolID: symbolID, around: center, by: angleDelta, sheet: &sheet)
        }
    }

    private func mirrorPowerSymbol(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        let transformedKey = "power-symbol:\(normalizedID(ref.id))"
        guard transformedJunctionKeys.insert(transformedKey).inserted else {
            return
        }
        let anchors = powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet)
        guard !anchors.isEmpty else {
            mirrorPowerSymbolGeometry(symbolID: ref.id, around: center, sheet: &sheet)
            return
        }

        mirrorPowerSymbolGeometry(symbolID: ref.id, around: center, sheet: &sheet)
        for anchor in anchors {
            moveSchematicConnectionPoint(
                at: anchor,
                to: mirrored(anchor, around: center),
                netID: netID(at: anchor, in: sheet),
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .mirroredAround(center)
            )
        }
    }

    private func rotatePowerSymbol(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        let transformedKey = "power-symbol:\(normalizedID(ref.id))"
        guard transformedJunctionKeys.insert(transformedKey).inserted else {
            return
        }
        let anchors = powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet)
        guard !anchors.isEmpty else {
            rotatePowerSymbolGeometry(symbolID: ref.id, around: center, by: angleDelta, sheet: &sheet)
            return
        }

        rotatePowerSymbolGeometry(symbolID: ref.id, around: center, by: angleDelta, sheet: &sheet)
        for anchor in anchors {
            moveSchematicConnectionPoint(
                at: anchor,
                to: rotated(anchor, around: center, by: angleDelta),
                netID: netID(at: anchor, in: sheet),
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
            )
        }
    }

    private func mirrorNetLabel(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.netLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.netLabels[index]
        moveSchematicConnectionPoint(
            at: original.position,
            to: mirrored(original.position, around: center),
            netID: original.netID,
            sheet: &sheet,
            movedKeys: &transformedJunctionKeys,
            attachedPowerSymbolTransform: .mirroredAround(center)
        )
        if let updatedIndex = sheet.netLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netLabels[updatedIndex].orientation = mirroredOrientation(original.orientation)
        }
    }

    private func rotateNetLabel(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.netLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.netLabels[index]
        moveSchematicConnectionPoint(
            at: original.position,
            to: rotated(original.position, around: center, by: angleDelta),
            netID: original.netID,
            sheet: &sheet,
            movedKeys: &transformedJunctionKeys,
            attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
        )
        if let updatedIndex = sheet.netLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netLabels[updatedIndex].orientation = rotatedOrientation(original.orientation, by: angleDelta)
        }
    }

    private func mirrorBusLabel(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.busLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.busLabels[index]
        moveSchematicConnectionPoint(
            at: original.position,
            to: mirrored(original.position, around: center),
            netID: original.netID,
            sheet: &sheet,
            movedKeys: &transformedJunctionKeys,
            attachedPowerSymbolTransform: .mirroredAround(center)
        )
        if let updatedIndex = sheet.busLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.busLabels[updatedIndex].orientation = mirroredOrientation(original.orientation)
        }
    }

    private func rotateBusLabel(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.busLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.busLabels[index]
        moveSchematicConnectionPoint(
            at: original.position,
            to: rotated(original.position, around: center, by: angleDelta),
            netID: original.netID,
            sheet: &sheet,
            movedKeys: &transformedJunctionKeys,
            attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
        )
        if let updatedIndex = sheet.busLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.busLabels[updatedIndex].orientation = rotatedOrientation(original.orientation, by: angleDelta)
        }
    }

    private func mirrorNetTie(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.netTies[index]
        if hasSchematicJunction(at: original.from, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.from,
                to: mirrored(original.from, around: center),
                netID: nil,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .mirroredAround(center)
            )
        } else {
            sheet.netTies[index].from = mirrored(original.from, around: center)
        }

        if hasSchematicJunction(at: original.to, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.to,
                to: mirrored(original.to, around: center),
                netID: nil,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .mirroredAround(center)
            )
        } else if let updatedIndex = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netTies[updatedIndex].to = mirrored(original.to, around: center)
        }
    }

    private func rotateNetTie(
        ref: HorizontalSelectableRef,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet,
        transformedJunctionKeys: inout Set<String>
    ) {
        guard let index = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let original = sheet.netTies[index]
        if hasSchematicJunction(at: original.from, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.from,
                to: rotated(original.from, around: center, by: angleDelta),
                netID: nil,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
            )
        } else {
            sheet.netTies[index].from = rotated(original.from, around: center, by: angleDelta)
        }

        if hasSchematicJunction(at: original.to, in: sheet) {
            moveSchematicConnectionPoint(
                at: original.to,
                to: rotated(original.to, around: center, by: angleDelta),
                netID: nil,
                sheet: &sheet,
                movedKeys: &transformedJunctionKeys,
                attachedPowerSymbolTransform: .rotatedAround(center, by: angleDelta)
            )
        } else if let updatedIndex = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netTies[updatedIndex].to = rotated(original.to, around: center, by: angleDelta)
        }
    }

    private func moveSchematicSymbol(ref: HorizontalSelectableRef, by delta: HorizontalPoint, sheet: inout HorizontalSchematicSheet) {
        var movedKeys = Set<String>()
        var movedConnectionTargets = Set<SchematicSymbolMoveConnectionTarget>()
        moveSchematicSymbol(
            ref: ref,
            by: delta,
            sheet: &sheet,
            movedKeys: &movedKeys,
            movedConnectionTargets: &movedConnectionTargets
        )
    }

    private func moveSchematicSymbolGeometry(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        sheet.symbols[index].position = sheet.symbols[index].position + delta
        shiftSchematicSymbolGeometry(symbolID: ref.id, by: delta, sheet: &sheet)
    }

    private func moveSchematicSymbol(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>,
        connectionPlan: SchematicSymbolMoveConnectionPlan? = nil,
        movedConnectionTargets: inout Set<SchematicSymbolMoveConnectionTarget>
    ) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        keepSchematicNetsConnectedToMovingSymbol(
            symbolID: ref.id,
            delta: delta,
            sheet: &sheet,
            movedKeys: &movedKeys,
            connectionPlan: connectionPlan,
            movedConnectionTargets: &movedConnectionTargets
        )
        sheet.symbols[index].position = sheet.symbols[index].position + delta
        shiftSchematicSymbolGeometry(symbolID: ref.id, by: delta, sheet: &sheet)
    }

    private func moveSchematicJunctionGeometry(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let key = sheet.junctions.keys.first(where: { normalizedID($0) == normalizedID(ref.id) }),
              let point = sheet.junctions[key] else {
            return
        }
        mergeJunctions(
            at: point + delta,
            preferredID: key,
            netID: sheet.junctionNetIDs[key],
            sheet: &sheet
        )
    }

    private func moveNetLabelGeometry(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let index = sheet.netLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        sheet.netLabels[index].position = sheet.netLabels[index].position + delta
    }

    private func moveBusLabelGeometry(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let index = sheet.busLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        sheet.busLabels[index].position = sheet.busLabels[index].position + delta
    }

    private func moveNetTieGeometry(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let index = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        sheet.netTies[index].from = sheet.netTies[index].from + delta
        sheet.netTies[index].to = sheet.netTies[index].to + delta
    }

    private func keepSchematicNetsConnectedToMovingSymbol(
        symbolID: String,
        delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>,
        connectionPlan: SchematicSymbolMoveConnectionPlan? = nil,
        movedConnectionTargets: inout Set<SchematicSymbolMoveConnectionTarget>
    ) {
        if let plannedTargets = connectionPlan?.targetsBySymbolID[normalizedID(symbolID)] {
            movePlannedSchematicSymbolConnections(
                plannedTargets,
                by: delta,
                sheet: &sheet,
                movedKeys: &movedKeys,
                movedConnectionTargets: &movedConnectionTargets
            )
            return
        }

        let connectionPoints = schematicSymbolConnectionPoints(symbolID: symbolID, sheet: sheet)
        guard !connectionPoints.isEmpty else {
            return
        }

        let connectedKeys = Set(connectionPoints.map { pointKey($0.point) })
        let wildcardConnectionKeys = Set(connectionPoints.compactMap { point -> String? in
            point.netID == nil ? pointKey(point.point) : nil
        })
        let netConnectionKeys = Set(connectionPoints.compactMap { point -> String? in
            guard let netID = point.netID else {
                return nil
            }
            return "\(pointKey(point.point)):\(normalizedID(netID))"
        })

        func isSymbolConnection(at point: HorizontalPoint, netID: String?) -> Bool {
            let key = pointKey(point)
            guard connectedKeys.contains(key) else {
                return false
            }
            guard let netID else {
                return true
            }
            return wildcardConnectionKeys.contains(key) || netConnectionKeys.contains("\(key):\(normalizedID(netID))")
        }

        for index in sheet.netLines.indices {
            let original = sheet.netLines[index]
            if isSymbolConnection(at: original.from, netID: original.netID) {
                sheet.netLines[index].from = original.from + delta
            }
            if isSymbolConnection(at: original.to, netID: original.netID) {
                sheet.netLines[index].to = original.to + delta
            }
        }

        var movedJunctionIDs = [String]()
        for junctionID in sheet.junctions.keys {
            guard let point = sheet.junctions[junctionID],
                  connectedKeys.contains(pointKey(point)),
                  movedKeys.insert(pointKey(point)).inserted
            else {
                continue
            }
            sheet.junctions[junctionID] = point + delta
            movedJunctionIDs.append(junctionID)
        }
        for junctionID in movedJunctionIDs {
            guard let point = sheet.junctions[junctionID] else {
                continue
            }
            mergeJunctions(
                at: point,
                preferredID: junctionID,
                netID: sheet.junctionNetIDs[junctionID],
                sheet: &sheet
            )
        }
    }

    private func movePlannedSchematicSymbolConnections(
        _ targets: [SchematicSymbolMoveConnectionTarget],
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>,
        movedConnectionTargets: inout Set<SchematicSymbolMoveConnectionTarget>
    ) {
        guard delta != .zero else {
            return
        }

        for target in targets where movedConnectionTargets.insert(target).inserted {
            switch target {
            case .netLineFrom(let lineID):
                guard let index = sheet.netLines.firstIndex(where: { normalizedID($0.id) == lineID }) else {
                    continue
                }
                sheet.netLines[index].from = sheet.netLines[index].from + delta
            case .netLineTo(let lineID):
                guard let index = sheet.netLines.firstIndex(where: { normalizedID($0.id) == lineID }) else {
                    continue
                }
                sheet.netLines[index].to = sheet.netLines[index].to + delta
            case .junction(let junctionID):
                guard let point = sheet.junctions[junctionID] else {
                    continue
                }
                guard movedKeys.insert(pointKey(point)).inserted else {
                    continue
                }
                sheet.junctions[junctionID] = point + delta
                mergeJunctions(
                    at: point + delta,
                    preferredID: junctionID,
                    netID: sheet.junctionNetIDs[junctionID],
                    sheet: &sheet
                )
            }
        }
    }

    private func schematicSymbolConnectionPoints(
        symbolID: String,
        sheet: HorizontalSchematicSheet
    ) -> [MovingConnectionPoint] {
        let normalizedSymbolID = normalizedID(symbolID)
        var points = [MovingConnectionPoint]()

        func belongsToSymbol(_ geometryID: String) -> Bool {
            geometryIDHasOwnerPrefix(geometryID, ownerID: normalizedSymbolID)
        }

        for pin in sheet.symbolPins where belongsToSymbol(pin.id) {
            points.append(MovingConnectionPoint(point: pin.from, netID: pin.netID))
            points.append(MovingConnectionPoint(point: pin.to, netID: pin.netID))
        }
        for circle in sheet.symbolPinCircles where belongsToSymbol(circle.id) {
            points.append(MovingConnectionPoint(point: circle.center, netID: circle.netID))
        }
        return points
    }

    private func moveSchematicJunction(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
            return
        }
        moveSchematicConnectionPoint(at: junction.value, by: delta, sheet: &sheet, movedKeys: &movedKeys)
    }

    private func hasSchematicJunction(at point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> Bool {
        let key = pointKey(point)
        return sheet.junctions.values.contains { pointKey($0) == key }
    }

    private func junctionID(at point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> String? {
        let key = pointKey(point)
        return sheet.junctions.first { pointKey($0.value) == key }?.key
    }

    private func existingJunctionID(matching id: String, in sheet: HorizontalSchematicSheet) -> String? {
        sheet.junctions.keys.first { normalizedID($0) == normalizedID(id) }
    }

    @discardableResult
    private func mergeJunctions(
        at point: HorizontalPoint,
        preferredID: String?,
        netID: String?,
        sheet: inout HorizontalSchematicSheet
    ) -> String {
        let key = pointKey(point)
        let matchingIDs = sheet.junctions
            .filter { pointKey($0.value) == key }
            .map(\.key)
        let existingPreferredID = preferredID.flatMap { existingJunctionID(matching: $0, in: sheet) }
        let keepID = existingPreferredID ?? matchingIDs.first ?? preferredID ?? UUID().uuidString.lowercased()
        let removedIDs = matchingIDs.filter { normalizedID($0) != normalizedID(keepID) }
        let keepNetID = sheet.junctionNetIDs[keepID]
            ?? netID
            ?? matchingIDs.compactMap { sheet.junctionNetIDs[$0] }.first

        sheet.junctions[keepID] = point
        if let keepNetID {
            sheet.junctionNetIDs[keepID] = keepNetID
        } else {
            sheet.junctionNetIDs.removeValue(forKey: keepID)
        }

        for junctionID in matchingIDs where normalizedID(junctionID) != normalizedID(keepID) {
            sheet.junctions.removeValue(forKey: junctionID)
            sheet.junctionNetIDs.removeValue(forKey: junctionID)
        }
        let removedIDSet = Set(removedIDs.map(normalizedID))
        for index in sheet.powerSymbols.indices
            where removedIDSet.contains(normalizedID(sheet.powerSymbols[index].junctionID)) {
            sheet.powerSymbols[index].junctionID = keepID
        }

        return keepID
    }

    private func ensureJunction(
        at point: HorizontalPoint,
        preferredID: String?,
        netID: String?,
        sheet: inout HorizontalSchematicSheet
    ) -> String {
        mergeJunctions(at: point, preferredID: preferredID, netID: netID, sheet: &sheet)
    }

    private func drawNetLineBendMode(at point: HorizontalPoint) -> DrawNetLineBendMode? {
        let key = pointKey(point)
        let segments = sheet.symbolPins + sheet.blockSymbolPorts + sheet.powerSymbolLines
        for segment in segments where pointKey(segment.from) == key || pointKey(segment.to) == key {
            let vector = segment.to - segment.from
            return abs(vector.y) >= abs(vector.x) ? .yx : .xy
        }
        return nil
    }

    private func drawNetLinePath(
        from anchor: HorizontalPoint,
        to point: HorizontalPoint,
        bendMode: DrawNetLineBendMode
    ) -> [HorizontalPoint] {
        let bend: HorizontalPoint
        switch bendMode {
        case .xy:
            bend = HorizontalPoint(x: point.x, y: anchor.y)
        case .yx:
            bend = HorizontalPoint(x: anchor.x, y: point.y)
        }

        if pointKey(bend) == pointKey(anchor) || pointKey(bend) == pointKey(point) {
            return [anchor, point]
        }
        return [anchor, bend, point]
    }

    private func drawNetID(at point: HorizontalPoint) -> String? {
        let key = pointKey(point)
        if let junctionID = junctionID(at: point, in: sheet),
           let netID = sheet.junctionNetIDs[junctionID] {
            return netID
        }

        for label in sheet.netLabels where pointKey(label.position) == key {
            return label.netID
        }

        let netBearingSegments = sheet.netLines
            + sheet.symbolPins
            + sheet.blockSymbolPorts
            + sheet.busRipperLines
            + sheet.powerSymbolLines
        for segment in netBearingSegments where segment.netID != nil {
            if pointKey(segment.from) == key || pointKey(segment.to) == key || pointLiesOnSegment(point, segment) {
                return segment.netID
            }
        }

        for circle in sheet.symbolPinCircles + sheet.powerSymbolCircles
            where circle.netID != nil && pointKey(circle.center) == key {
            return circle.netID
        }

        return nil
    }

    private func pointLiesOnSegment(_ point: HorizontalPoint, _ segment: HorizontalSegment) -> Bool {
        let minX = min(segment.from.x, segment.to.x)
        let maxX = max(segment.from.x, segment.to.x)
        let minY = min(segment.from.y, segment.to.y)
        let maxY = max(segment.from.y, segment.to.y)
        guard point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY else {
            return false
        }

        let line = segment.to - segment.from
        let candidate = point - segment.from
        let cross = line.x * candidate.y - line.y * candidate.x
        return abs(cross) < 1
    }

    private func moveSchematicConnectionPoint(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        var movedKeys = Set<String>()
        moveSchematicConnectionPoint(at: point, by: delta, sheet: &sheet, movedKeys: &movedKeys)
    }

    private func moveSelectedSchematicConnectionPoint(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>,
        fixedConnectionPointKeys: Set<String>
    ) {
        guard !fixedConnectionPointKeys.contains(pointKey(point)) else {
            return
        }
        moveSchematicConnectionPoint(at: point, by: delta, sheet: &sheet, movedKeys: &movedKeys)
    }

    private func moveSchematicConnectionPoint(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>,
        attachedPowerSymbolTransform: AttachedPowerSymbolTransform? = nil
    ) {
        guard delta != .zero else {
            return
        }

        let key = pointKey(point)
        guard movedKeys.insert(key).inserted else {
            return
        }

        transformPowerSymbolsAttached(
            at: key,
            transform: attachedPowerSymbolTransform ?? .translatedBy(delta),
            sheet: &sheet,
            movedKeys: &movedKeys
        )

        var movedJunctionIDs = [String]()
        for junctionID in sheet.junctions.keys where pointKey(sheet.junctions[junctionID] ?? .zero) == key {
            guard movedKeys.insert("junction:\(normalizedID(junctionID))").inserted else {
                continue
            }
            sheet.junctions[junctionID] = (sheet.junctions[junctionID] ?? .zero) + delta
            movedJunctionIDs.append(junctionID)
        }
        moveEndpoints(at: key, by: delta, in: &sheet.netLines, identityPrefix: "net-line", movedKeys: &movedKeys)
        moveEndpoints(at: key, by: delta, in: &sheet.drawingLines, identityPrefix: "drawing-line", movedKeys: &movedKeys)
        moveArcPoints(at: key, by: delta, in: &sheet.drawingArcs, identityPrefix: "drawing-arc", movedKeys: &movedKeys)
        moveEndpoints(at: key, by: delta, in: &sheet.busRipperLines, identityPrefix: "bus-ripper-line", movedKeys: &movedKeys)
        for index in sheet.netTies.indices {
            if pointKey(sheet.netTies[index].from) == key,
               movedKeys.insert("net-tie:\(normalizedID(sheet.netTies[index].id)):from").inserted {
                sheet.netTies[index].from = sheet.netTies[index].from + delta
            }
            if pointKey(sheet.netTies[index].to) == key,
               movedKeys.insert("net-tie:\(normalizedID(sheet.netTies[index].id)):to").inserted {
                sheet.netTies[index].to = sheet.netTies[index].to + delta
            }
        }
        for index in sheet.netLabels.indices where pointKey(sheet.netLabels[index].position) == key {
            guard movedKeys.insert("net-label:\(normalizedID(sheet.netLabels[index].id))").inserted else {
                continue
            }
            sheet.netLabels[index].position = sheet.netLabels[index].position + delta
        }
        for index in sheet.busLabels.indices where pointKey(sheet.busLabels[index].position) == key {
            guard movedKeys.insert("bus-label:\(normalizedID(sheet.busLabels[index].id))").inserted else {
                continue
            }
            sheet.busLabels[index].position = sheet.busLabels[index].position + delta
        }
        if let preferredID = movedJunctionIDs.first {
            mergeJunctions(
                at: point + delta,
                preferredID: preferredID,
                netID: sheet.junctionNetIDs[preferredID],
                sheet: &sheet
            )
        }
    }

    private func shiftPowerSymbolsAttached(
        at key: String,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        transformPowerSymbolsAttached(
            at: key,
            transform: .translatedBy(delta),
            sheet: &sheet,
            movedKeys: &movedKeys
        )
    }

    private func transformPowerSymbolsAttached(
        at key: String,
        transform: AttachedPowerSymbolTransform,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        for symbolID in powerSymbolIDs(in: sheet)
            where powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet).contains(where: { pointKey($0) == key }) {
            guard movedKeys.insert("power-symbol:\(normalizedID(symbolID))").inserted else {
                continue
            }
            switch transform {
            case .translatedBy(let delta):
                shiftPowerSymbolGeometry(symbolID: symbolID, by: delta, sheet: &sheet)
            case .mirroredAround(let center):
                mirrorPowerSymbolGeometry(symbolID: symbolID, around: center, sheet: &sheet)
            case .rotatedAround(let center, by: let angleDelta):
                rotatePowerSymbolGeometry(symbolID: symbolID, around: center, by: angleDelta, sheet: &sheet)
            }
        }
    }

    private func schematicFixedConnectionPointKeys(in sheet: HorizontalSchematicSheet) -> Set<String> {
        let selectedSymbols = selectedSchematicOwnerIDs(type: .schematicSymbol)
        let selectedBlockSymbols = selectedSchematicOwnerIDs(type: .schematicBlockSymbol)
        let selectedPowerSymbols = selectedSchematicOwnerIDs(type: .powerSymbol)
        let selectedBusRippers = selectedSchematicOwnerIDs(type: .busRipper)
        let selectedJunctions = selectedSchematicJunctionIDs()
        var keys = Set<String>()

        func add(_ point: HorizontalPoint) {
            keys.insert(pointKey(point))
        }

        for pin in sheet.symbolPins {
            guard let symbolID = symbolID(forGeometryID: pin.id),
                  !selectedSymbols.contains(normalizedID(symbolID)) else {
                continue
            }
            add(pin.from)
            add(pin.to)
        }

        for circle in sheet.symbolPinCircles {
            guard let symbolID = symbolID(forGeometryID: circle.id),
                  !selectedSymbols.contains(normalizedID(symbolID)) else {
                continue
            }
            add(circle.center)
        }

        for port in sheet.blockSymbolPorts {
            let blockSymbolID = objectIDPrefix(
                in: port.id,
                separators: ["block-port", "line", "port", "text"]
            )
            guard let blockSymbolID,
                  !selectedBlockSymbols.contains(normalizedID(blockSymbolID)) else {
                continue
            }
            add(port.from)
            add(port.to)
        }

        for symbolID in powerSymbolIDs(in: sheet) where !selectedPowerSymbols.contains(normalizedID(symbolID)) {
            for point in powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet) {
                if let junctionID = junctionID(at: point, in: sheet),
                   selectedJunctions.contains(normalizedID(junctionID)) {
                    continue
                }
                add(point)
            }
        }

        for ripperID in busRipperIDs(in: sheet) where !selectedBusRippers.contains(normalizedID(ripperID)) {
            for point in busRipperConnectionPoints(ripperID: ripperID, sheet: sheet) {
                add(point)
            }
        }

        return keys
    }

    private func selectedSchematicOwnerIDs(type: HorizontalObjectType) -> Set<String> {
        Set(
            selectedObjects
                .filter { $0.type == type }
                .map { normalizedID($0.id) }
        )
    }

    private func moveSchematicConnectionPoint(
        at point: HorizontalPoint,
        to newPoint: HorizontalPoint,
        netID _: String?,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>,
        attachedPowerSymbolTransform: AttachedPowerSymbolTransform? = nil
    ) {
        moveSchematicConnectionPoint(
            at: point,
            by: newPoint - point,
            sheet: &sheet,
            movedKeys: &movedKeys,
            attachedPowerSymbolTransform: attachedPowerSymbolTransform
        )
    }

    private func moveEndpoints(
        at pointKey: String,
        by delta: HorizontalPoint,
        in segments: inout [HorizontalSegment],
        identityPrefix: String,
        movedKeys: inout Set<String>
    ) {
        for index in segments.indices {
            if self.pointKey(segments[index].from) == pointKey,
               movedKeys.insert("\(identityPrefix):\(normalizedID(segments[index].id)):from").inserted {
                segments[index].from = segments[index].from + delta
            }
            if self.pointKey(segments[index].to) == pointKey,
               movedKeys.insert("\(identityPrefix):\(normalizedID(segments[index].id)):to").inserted {
                segments[index].to = segments[index].to + delta
            }
        }
    }

    private func moveArcPoints(
        at pointKey: String,
        by delta: HorizontalPoint,
        in arcs: inout [HorizontalArc],
        identityPrefix: String,
        movedKeys: inout Set<String>
    ) {
        for index in arcs.indices {
            if self.pointKey(arcs[index].from) == pointKey,
               movedKeys.insert("\(identityPrefix):\(normalizedID(arcs[index].id)):from").inserted {
                arcs[index].from = arcs[index].from + delta
            }
            if self.pointKey(arcs[index].to) == pointKey,
               movedKeys.insert("\(identityPrefix):\(normalizedID(arcs[index].id)):to").inserted {
                arcs[index].to = arcs[index].to + delta
            }
            if self.pointKey(arcs[index].center) == pointKey,
               movedKeys.insert("\(identityPrefix):\(normalizedID(arcs[index].id)):center").inserted {
                arcs[index].center = arcs[index].center + delta
            }
        }
    }

    private func moveDrawingSegmentSelection(
        _ segments: inout [HorizontalSegment],
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        movedKeys: inout Set<String>
    ) {
        moveSegment(&segments, ref: ref, by: delta)
    }

    private func moveDrawingEndpoints(
        at point: HorizontalPoint,
        layer: Int?,
        by delta: HorizontalPoint,
        in segments: inout [HorizontalSegment],
        movedKeys: inout Set<String>
    ) {
        let moveKey = "\(pointKey(point)):\(layer.map(String.init) ?? "nil")"
        guard movedKeys.insert(moveKey).inserted else {
            return
        }
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

    private func moveNetLabel(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        guard let index = sheet.netLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        let position = sheet.netLabels[index].position
        if hasSchematicJunction(at: position, in: sheet) {
            moveSchematicConnectionPoint(at: position, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        } else {
            sheet.netLabels[index].position = position + delta
        }
    }

    private func moveBusLabel(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        guard let index = sheet.busLabels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        let position = sheet.busLabels[index].position
        if hasSchematicJunction(at: position, in: sheet) {
            moveSchematicConnectionPoint(at: position, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        } else {
            sheet.busLabels[index].position = position + delta
        }
    }

    private func moveText(_ texts: inout [HorizontalText], ref: HorizontalSelectableRef, by delta: HorizontalPoint) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        texts[index] = shifted(texts[index], by: delta)
    }

    private func mirrorSegment(_ segments: inout [HorizontalSegment], ref: HorizontalSelectableRef, around center: HorizontalPoint) {
        guard let index = segments.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        segments[index] = mirrored(segments[index], around: center)
    }

    private func mirrorArc(_ arcs: inout [HorizontalArc], ref: HorizontalSelectableRef, around center: HorizontalPoint) {
        guard let index = arcs.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        arcs[index] = mirrored(arcs[index], around: center)
    }

    private func mirrorText(_ texts: inout [HorizontalText], ref: HorizontalSelectableRef, around center: HorizontalPoint) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        texts[index] = mirrored(texts[index], around: center)
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

    private func rotateText(_ texts: inout [HorizontalText], ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int) {
        guard let index = texts.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        texts[index] = rotated(texts[index], around: center, by: angleDelta)
    }

    private func moveNetTie(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        guard let index = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }
        let original = sheet.netTies[index]
        if hasSchematicJunction(at: original.from, in: sheet) {
            moveSchematicConnectionPoint(at: original.from, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        } else {
            sheet.netTies[index].from = sheet.netTies[index].from + delta
        }
        if hasSchematicJunction(at: original.to, in: sheet) {
            moveSchematicConnectionPoint(at: original.to, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        } else if let updatedIndex = sheet.netTies.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
            sheet.netTies[updatedIndex].to = sheet.netTies[updatedIndex].to + delta
        }
    }

    private func movePowerSymbol(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        let anchors = powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet)
        guard !anchors.isEmpty else {
            shiftPowerSymbolGeometry(symbolID: ref.id, by: delta, sheet: &sheet)
            return
        }
        for anchor in anchors {
            moveSchematicConnectionPoint(at: anchor, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        }
    }

    private func moveBusRipper(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        let connectionPoints = busRipperConnectionPoints(ripperID: ref.id, sheet: sheet)
        guard !connectionPoints.isEmpty else {
            shiftBusRipperGeometry(ripperID: ref.id, by: delta, sheet: &sheet)
            return
        }

        for point in connectionPoints {
            moveSchematicConnectionPoint(at: point, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        }
        shiftBusRipperTexts(ripperID: ref.id, by: delta, sheet: &sheet)
    }

    private func moveSchematicBlockSymbol(
        ref: HorizontalSelectableRef,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet,
        movedKeys: inout Set<String>
    ) {
        for point in schematicBlockSymbolConnectionPoints(blockSymbolID: ref.id, sheet: sheet) {
            moveSchematicConnectionPoint(at: point, by: delta, sheet: &sheet, movedKeys: &movedKeys)
        }
        shiftSchematicBlockSymbolGeometry(blockSymbolID: ref.id, by: delta, sheet: &sheet)
    }

    private func powerSymbolAnchorPoints(symbolID: String, sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        if let symbol = sheet.powerSymbols.first(where: { normalizedID($0.id) == normalizedID(symbolID) }),
           let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(symbol.junctionID) }) {
            return [junction.value]
        }

        let pinPoints = powerSymbolPinPoints(symbolID: symbolID, sheet: sheet)
        let pinKeys = Set(pinPoints.map(pointKey))
        let junctions = uniquePoints(sheet.junctions.values.filter { pinKeys.contains(pointKey($0)) })
        if !junctions.isEmpty {
            return junctions
        }
        if !pinPoints.isEmpty {
            return Array(uniquePoints(pinPoints).prefix(1))
        }

        return powerSymbolShapePoints(symbolID: symbolID, sheet: sheet).prefix(1).map { $0 }
    }

    private func uniquePoints<S: Sequence>(_ points: S) -> [HorizontalPoint] where S.Element == HorizontalPoint {
        var seen = Set<String>()
        var result = [HorizontalPoint]()
        for point in points where seen.insert(pointKey(point)).inserted {
            result.append(point)
        }
        return result
    }

    private func powerSymbolPinPoints(symbolID: String, sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        let separators: Set<String> = ["circle", "line", "text"]
        return sheet.powerSymbolLines
            .filter { geometryID($0.id, belongsTo: symbolID, separators: separators) }
            .filter { normalizedID($0.id).contains("/stem") }
            .map(\.from)
    }

    private func schematicBlockSymbolConnectionPoints(blockSymbolID: String, sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        let separators: Set<String> = ["line", "port", "text"]
        return sheet.blockSymbolPorts
            .filter { geometryID($0.id, belongsTo: blockSymbolID, separators: separators) }
            .flatMap { [$0.from, $0.to] }
    }

    private func powerSymbolShapePoints(symbolID: String, sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        let separators: Set<String> = ["circle", "line", "text"]
        let linePoints = sheet.powerSymbolLines
            .filter { geometryID($0.id, belongsTo: symbolID, separators: separators) }
            .flatMap { [$0.from, $0.to] }
        let circlePoints = sheet.powerSymbolCircles
            .filter { geometryID($0.id, belongsTo: symbolID, separators: separators) }
            .flatMap(circleBounds)
        return linePoints + circlePoints
    }

    private func powerSymbolIDs(in sheet: HorizontalSchematicSheet) -> [String] {
        if !sheet.powerSymbols.isEmpty {
            return sheet.powerSymbols.map(\.id)
        }
        return groupedObjectIDs(
            geometryIDs: sheet.powerSymbolLines.map(\.id)
                + sheet.powerSymbolCircles.map(\.id)
                + sheet.powerSymbolTexts.map(\.id),
            separators: schematicPowerSymbolGeometrySeparators
        )
    }

    private func mirrorPowerSymbolState(symbolID: String, sheet: inout HorizontalSchematicSheet) {
        guard let index = sheet.powerSymbols.firstIndex(where: { normalizedID($0.id) == normalizedID(symbolID) }) else {
            return
        }

        switch sheet.powerSymbols[index].orientation {
        case "left":
            sheet.powerSymbols[index].orientation = "right"
        case "right":
            sheet.powerSymbols[index].orientation = "left"
        default:
            sheet.powerSymbols[index].mirrored.toggle()
        }
    }

    private func rotatePowerSymbolState(symbolID: String, by angleDelta: Int, sheet: inout HorizontalSchematicSheet) {
        guard let index = sheet.powerSymbols.firstIndex(where: { normalizedID($0.id) == normalizedID(symbolID) }) else {
            return
        }
        sheet.powerSymbols[index].orientation = rotatedOrientation(sheet.powerSymbols[index].orientation, by: angleDelta)
    }

    private func busRipperIDs(in sheet: HorizontalSchematicSheet) -> [String] {
        groupedObjectIDs(
            geometryIDs: sheet.busRipperLines.map(\.id) + sheet.busRipperTexts.map(\.id),
            separators: ["bus-ripper", "line", "text"]
        )
    }

    private func busRipperConnectionPoints(ripperID: String, sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        let separators: Set<String> = ["bus-ripper", "line", "text"]
        return sheet.busRipperLines
            .filter { geometryID($0.id, belongsTo: ripperID, separators: separators) }
            .flatMap { [$0.from, $0.to] }
    }

    private func groupedSchematicGeometryPoints(
        objectID: String,
        segments: [HorizontalSegment],
        circles: [HorizontalCircle] = [],
        texts: [HorizontalText] = [],
        separators: Set<String>
    ) -> [HorizontalPoint] {
        var points = [HorizontalPoint]()
        for segment in segments where geometryID(segment.id, belongsTo: objectID, separators: separators) {
            points.append(contentsOf: [segment.from, segment.to])
        }
        for circle in circles where geometryID(circle.id, belongsTo: objectID, separators: separators) {
            points.append(circle.center)
        }
        for text in texts where geometryID(text.id, belongsTo: objectID, separators: separators) {
            points.append(text.position)
        }
        return points
    }

    private func groupedObjectIDs(geometryIDs: [String], separators: Set<String>) -> [String] {
        var ids = Set<String>()
        for geometryID in geometryIDs {
            if let objectID = objectIDPrefix(in: geometryID, separators: separators)
                ?? normalizedID(geometryID).split(separator: "/").first.map(String.init) {
                ids.insert(objectID)
            }
        }
        return Array(ids)
    }

    private func shiftPowerSymbolGeometry(
        symbolID: String,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero else {
            return
        }

        let separators: Set<String> = ["circle", "line", "text"]
        for index in sheet.powerSymbolLines.indices
            where geometryID(sheet.powerSymbolLines[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolLines[index] = shifted(sheet.powerSymbolLines[index], by: delta)
        }
        for index in sheet.powerSymbolCircles.indices
            where geometryID(sheet.powerSymbolCircles[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolCircles[index] = shifted(sheet.powerSymbolCircles[index], by: delta)
        }
        for index in sheet.powerSymbolTexts.indices
            where geometryID(sheet.powerSymbolTexts[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolTexts[index] = shifted(sheet.powerSymbolTexts[index], by: delta)
        }
    }

    private func mirrorPowerSymbolGeometry(
        symbolID: String,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        mirrorPowerSymbolState(symbolID: symbolID, sheet: &sheet)
        let separators: Set<String> = ["circle", "line", "text"]
        for index in sheet.powerSymbolLines.indices
            where geometryID(sheet.powerSymbolLines[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolLines[index] = mirrored(sheet.powerSymbolLines[index], around: center)
        }
        for index in sheet.powerSymbolCircles.indices
            where geometryID(sheet.powerSymbolCircles[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolCircles[index] = mirrored(sheet.powerSymbolCircles[index], around: center)
        }
        for index in sheet.powerSymbolTexts.indices
            where geometryID(sheet.powerSymbolTexts[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolTexts[index] = mirrored(sheet.powerSymbolTexts[index], around: center)
        }
    }

    private func rotatePowerSymbolGeometry(
        symbolID: String,
        around center: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet
    ) {
        rotatePowerSymbolState(symbolID: symbolID, by: angleDelta, sheet: &sheet)
        let separators: Set<String> = ["circle", "line", "text"]
        for index in sheet.powerSymbolLines.indices
            where geometryID(sheet.powerSymbolLines[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolLines[index] = rotated(sheet.powerSymbolLines[index], around: center, by: angleDelta)
        }
        for index in sheet.powerSymbolCircles.indices
            where geometryID(sheet.powerSymbolCircles[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolCircles[index] = rotated(sheet.powerSymbolCircles[index], around: center, by: angleDelta)
        }
        for index in sheet.powerSymbolTexts.indices
            where geometryID(sheet.powerSymbolTexts[index].id, belongsTo: symbolID, separators: separators) {
            sheet.powerSymbolTexts[index] = rotated(sheet.powerSymbolTexts[index], around: center, by: angleDelta)
        }
    }

    private func shiftBusRipperGeometry(
        ripperID: String,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero else {
            return
        }

        let separators: Set<String> = ["bus-ripper", "line", "text"]
        for index in sheet.busRipperLines.indices
            where geometryID(sheet.busRipperLines[index].id, belongsTo: ripperID, separators: separators) {
            sheet.busRipperLines[index] = shifted(sheet.busRipperLines[index], by: delta)
        }
        shiftBusRipperTexts(ripperID: ripperID, by: delta, sheet: &sheet)
    }

    private func shiftBusRipperTexts(
        ripperID: String,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero else {
            return
        }

        let separators: Set<String> = ["bus-ripper", "line", "text"]
        for index in sheet.busRipperTexts.indices
            where geometryID(sheet.busRipperTexts[index].id, belongsTo: ripperID, separators: separators) {
            sheet.busRipperTexts[index] = shifted(sheet.busRipperTexts[index], by: delta)
        }
    }

    private func shiftSchematicBlockSymbolGeometry(
        blockSymbolID: String,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero else {
            return
        }

        let separators: Set<String> = ["line", "port", "text"]
        for index in sheet.blockSymbolLines.indices
            where geometryID(sheet.blockSymbolLines[index].id, belongsTo: blockSymbolID, separators: separators) {
            sheet.blockSymbolLines[index] = shifted(sheet.blockSymbolLines[index], by: delta)
        }
        for index in sheet.blockSymbolPorts.indices
            where geometryID(sheet.blockSymbolPorts[index].id, belongsTo: blockSymbolID, separators: separators) {
            sheet.blockSymbolPorts[index] = shifted(sheet.blockSymbolPorts[index], by: delta)
        }
        for index in sheet.blockSymbolTexts.indices
            where geometryID(sheet.blockSymbolTexts[index].id, belongsTo: blockSymbolID, separators: separators) {
            sheet.blockSymbolTexts[index] = shifted(sheet.blockSymbolTexts[index], by: delta)
        }
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
        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        let refs = change.applyToAll
            ? selectedObjects.filter { $0.type == change.type }
            : [change.ref]

        guard !refs.isEmpty else {
            return
        }

        var changedNetClasses = [(netID: String, netClassID: String?)]()
        var changedComponentRefdes = [(componentID: String, refdes: String)]()
        var changedComponentPinNames = [(componentID: String, pins: [HorizontalSymbolPinName])]()
        for ref in refs {
            apply(
                change.value,
                propertyID: change.propertyID,
                to: ref,
                sheet: &draft,
                changedNetClasses: &changedNetClasses,
                changedComponentRefdes: &changedComponentRefdes,
                changedComponentPinNames: &changedComponentPinNames
            )
        }
        registerUndoSnapshot(previousSheet, actionName: "Edit Properties")
        editedSheet = draft
        invalidateSelectableCache()
        onSheetChange(draft)
        for change in changedNetClasses {
            onNetClassChange(change.netID, change.netClassID)
        }
        for change in changedComponentRefdes {
            onComponentRefdesChange(change.componentID, change.refdes)
        }
        for change in changedComponentPinNames {
            onComponentPinNamesChange(change.componentID, change.pins)
        }
        publishSelectionContext()
    }

    private func configureUndoTarget() {
        undoTarget.configure(
            currentValue: { sheet },
            restoreValue: { value in
                let previousSymbols = sheet.symbols
                let previousDetails = sheet.netDetails
                editedSheet = value
                invalidateSelectableCache()
                moveState = nil
                hoveredObject = nil
                onSheetChange(value)
                reportNetClassDifferences(from: previousDetails, to: value.netDetails)
                reportComponentRefdesDifferences(from: previousSymbols, to: value.symbols)
            }
        )
    }

    private func registerUndoSnapshot(_ previousSheet: HorizontalSchematicSheet, actionName: String) {
        configureUndoTarget()
        undoTarget.registerUndo(
            from: previousSheet,
            actionName: actionName,
            undoManager: undoManager
        )
    }

    private func apply(
        _ value: HorizontalSelectionPropertyValue,
        propertyID: String,
        to ref: HorizontalSelectableRef,
        sheet: inout HorizontalSchematicSheet,
        changedNetClasses: inout [(netID: String, netClassID: String?)],
        changedComponentRefdes: inout [(componentID: String, refdes: String)],
        changedComponentPinNames: inout [(componentID: String, pins: [HorizontalSymbolPinName])]
    ) {
        if editorProfile.supportsPins, ref.type == .symbolPin {
            updateEditablePin(ref: ref, propertyID: propertyID, value: value, sheet: &sheet)
            return
        }
        if propertyID == "netClass", case .choice(let classID) = value {
            updateNetClass(for: netID(for: ref), classID: classID, sheet: &sheet, changedNetClasses: &changedNetClasses)
            return
        }

        switch ref.type {
        case .schematicSymbol:
            updateSchematicSymbol(
                ref: ref,
                propertyID: propertyID,
                value: value,
                sheet: &sheet,
                changedComponentRefdes: &changedComponentRefdes,
                changedComponentPinNames: &changedComponentPinNames
            )
        case .lineNet:
            updateSegment(&sheet.netLines, ref: ref, propertyID: propertyID, value: value)
        case .drawingLine:
            updateSegment(&sheet.drawingLines, ref: ref, propertyID: propertyID, value: value)
        case .drawingArc:
            updateArc(&sheet.drawingArcs, ref: ref, propertyID: propertyID, value: value)
        case .netLabel:
            updateNetLabel(&sheet.netLabels, ref: ref, propertyID: propertyID, value: value)
        case .busLabel:
            updateBusLabel(&sheet.busLabels, ref: ref, propertyID: propertyID, value: value)
        case .text:
            updateText(&sheet.texts, ref: ref, propertyID: propertyID, value: value)
        case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .busRipper, .connectionLine, .dimension, .junction, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .symbolPin, .track, .via:
            break
        }
    }

    private func updateNetClass(
        for netID: String?,
        classID: String,
        sheet: inout HorizontalSchematicSheet,
        changedNetClasses: inout [(netID: String, netClassID: String?)]
    ) {
        guard let netID else {
            return
        }

        let normalizedNetID = normalizedID(netID)
        let normalizedClassID = classID == Self.noNetClassChoiceID ? nil : normalizedID(classID)
        var detail = sheet.netDetails[normalizedNetID] ?? HorizontalNetDetails(
            id: normalizedNetID,
            name: shortID(netID),
            netClassID: nil,
            netClassName: nil
        )
        detail.netClassID = normalizedClassID
        detail.netClassName = normalizedClassID.flatMap { classID in
            sheet.netClasses.first { normalizedID($0.id) == classID }?.name
        }
        sheet.netDetails[normalizedNetID] = detail
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

    private func updateSchematicSymbol(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        sheet: inout HorizontalSchematicSheet,
        changedComponentRefdes: inout [(componentID: String, refdes: String)],
        changedComponentPinNames: inout [(componentID: String, pins: [HorizontalSymbolPinName])]
    ) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        if updateSymbolPinNameProperty(
            propertyID: propertyID,
            value: value,
            symbolIndex: index,
            sheet: &sheet,
            changedComponentPinNames: &changedComponentPinNames
        ) {
            return
        }

        switch (propertyID, value) {
        case ("refdes", .text(let refdes)):
            updateComponentRefdes(
                componentID: sheet.symbols[index].componentID,
                refdes: refdes,
                sheet: &sheet,
                changedComponentRefdes: &changedComponentRefdes
            )
        case ("customValue", .text(let customValue)):
            updateCustomValue(ref: ref, customValue: customValue, sheet: &sheet)
        case ("positionX", .length(let x)):
            let delta = HorizontalPoint(x: x - sheet.symbols[index].position.x, y: 0)
            moveSchematicSymbol(ref: ref, by: delta, sheet: &sheet)
        case ("positionY", .length(let y)):
            let delta = HorizontalPoint(x: 0, y: y - sheet.symbols[index].position.y)
            moveSchematicSymbol(ref: ref, by: delta, sheet: &sheet)
        case ("angle", .angle(let angle)):
            let newAngle = wrappedAngle(angle)
            let angleDelta = newAngle - wrappedAngle(sheet.symbols[index].angle)
            let origin = sheet.symbols[index].position
            sheet.symbols[index].angle = newAngle
            rotateSchematicSymbolGeometry(symbolID: ref.id, around: origin, by: angleDelta, sheet: &sheet)
        default:
            break
        }
    }

    private func updateSymbolPinNameProperty(
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        symbolIndex: Int,
        sheet: inout HorizontalSchematicSheet,
        changedComponentPinNames: inout [(componentID: String, pins: [HorizontalSymbolPinName])]
    ) -> Bool {
        if propertyID == "pinDisplayMode", case .choice(let mode) = value {
            guard HorizontalSymbolPinDisplayMode(rawValue: mode) != nil else {
                return true
            }
            sheet.symbols[symbolIndex].pinDisplayMode = mode
            updateSymbolPinNameTexts(
                symbolID: sheet.symbols[symbolIndex].id,
                pins: sheet.symbols[symbolIndex].symbolPinNames,
                mode: mode,
                sheet: &sheet
            )
            return true
        }

        guard propertyID.hasPrefix("pinName:") else {
            return false
        }

        let parts = propertyID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let pinIndex = sheet.symbols[symbolIndex].symbolPinNames.firstIndex(where: {
                  normalizedID($0.id) == normalizedID(parts[1])
              }) else {
            return true
        }

        let field = parts[2]
        switch (field, value) {
        case ("primary", .bool(let enabled)):
            sheet.symbols[symbolIndex].symbolPinNames[pinIndex].state.usePrimaryName = enabled
        case ("alt", .bool(let enabled)):
            guard parts.count >= 4 else {
                return true
            }
            let optionID = parts[3]
            sheet.symbols[symbolIndex].symbolPinNames[pinIndex].state.pinNames.removeAll {
                normalizedID($0) == normalizedID(optionID)
            }
            if enabled {
                sheet.symbols[symbolIndex].symbolPinNames[pinIndex].state.pinNames.append(optionID)
            }
        case ("customEnabled", .bool(let enabled)):
            sheet.symbols[symbolIndex].symbolPinNames[pinIndex].state.useCustomName = enabled
        case ("customName", .text(let customName)):
            sheet.symbols[symbolIndex].symbolPinNames[pinIndex].state.customName = customName
        case ("customDirection", .choice(let direction)):
            sheet.symbols[symbolIndex].symbolPinNames[pinIndex].state.customDirection = direction
        default:
            return true
        }

        updateSymbolPinNameTexts(
            symbolID: sheet.symbols[symbolIndex].id,
            pins: sheet.symbols[symbolIndex].symbolPinNames,
            mode: sheet.symbols[symbolIndex].pinDisplayMode,
            sheet: &sheet
        )
        if let componentID = sheet.symbols[symbolIndex].componentID {
            changedComponentPinNames.append((componentID, sheet.symbols[symbolIndex].symbolPinNames))
        }
        return true
    }

    private func updateCustomValue(
        ref: HorizontalSelectableRef,
        customValue: String,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let index = sheet.symbols.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        let trimmedValue = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextValue = trimmedValue.isEmpty ? nil : trimmedValue
        guard sheet.symbols[index].customValue != nextValue else {
            return
        }

        let oldDisplayValue = displayedValue(for: sheet.symbols[index])
        sheet.symbols[index].customValue = nextValue
        let newDisplayValue = displayedValue(for: sheet.symbols[index])
        updateSymbolValueText(
            symbolID: sheet.symbols[index].id,
            oldValue: oldDisplayValue,
            newValue: newDisplayValue,
            sheet: &sheet
        )
    }

    private func displayedValue(for symbol: HorizontalPlacement) -> String {
        if let customValue = nonEmpty(symbol.customValue),
           let component = symbol.componentDetails {
            return interpolatedCustomValue(customValue, component: component)
        }
        return symbol.componentDetails?.value ?? ""
    }

    private func interpolatedCustomValue(_ customValue: String, component: HorizontalComponentDetails) -> String {
        var result = customValue
        for variable in customValueVariables(in: customValue).sorted(by: { $0.count > $1.count }) {
            guard let value = customValueSubstitution(for: variable, component: component) else {
                continue
            }
            result = result
                .replacingOccurrences(of: "${\(variable)}", with: value)
                .replacingOccurrences(of: "$\(variable)", with: value)
        }
        return result
    }

    private func customValueVariables(in text: String) -> Set<String> {
        var variables = Set<String>()
        let pattern = #"\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_:]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return variables
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            for index in 1..<match.numberOfRanges {
                let matchRange = match.range(at: index)
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: text) else {
                    continue
                }
                variables.insert(String(text[range]))
            }
        }
        return variables
    }

    private func customValueSubstitution(for variable: String, component: HorizontalComponentDetails) -> String? {
        let key = variable.lowercased()
        switch key {
        case "value":
            return component.value
        case "pkg":
            return component.packageName ?? "None"
        case "mpn":
            return component.mpn ?? "None"
        case "mfr":
            return component.manufacturer ?? "None"
        case "desc":
            return component.description ?? "None"
        default:
            guard key.hasPrefix("p:") else {
                return nil
            }
            let parameterKey = String(key.dropFirst(2))
            return component.parametricValues.first { $0.key.lowercased() == parameterKey }?.value
        }
    }

    private func updateSymbolValueText(
        symbolID: String,
        oldValue: String,
        newValue: String,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard !oldValue.isEmpty, oldValue != newValue else {
            return
        }
        let normalizedSymbolID = normalizedID(symbolID)
        for index in sheet.symbolTexts.indices
            where self.symbolID(forGeometryID: sheet.symbolTexts[index].id).map(normalizedID) == normalizedSymbolID
                && sheet.symbolTexts[index].text == oldValue {
            sheet.symbolTexts[index].text = newValue
        }
    }

    private func updateComponentRefdes(
        componentID: String?,
        refdes: String,
        sheet: inout HorizontalSchematicSheet,
        changedComponentRefdes: inout [(componentID: String, refdes: String)]
    ) {
        guard let componentID else {
            return
        }

        let normalizedComponentID = normalizedID(componentID)
        for index in sheet.symbols.indices
            where sheet.symbols[index].componentID.map(normalizedID) == normalizedComponentID {
            let oldRefdes = sheet.symbols[index].componentDetails?.refdes
            guard oldRefdes != refdes else {
                continue
            }

            if var details = sheet.symbols[index].componentDetails {
                details.refdes = refdes
                sheet.symbols[index].componentDetails = details
                sheet.symbols[index].label = details.displayLabel
            }
            updateSymbolTextRefdes(
                symbolID: sheet.symbols[index].id,
                oldRefdes: oldRefdes,
                newRefdes: refdes,
                sheet: &sheet
            )
        }
        changedComponentRefdes.append((normalizedComponentID, refdes))
    }

    private func updateSymbolTextRefdes(
        symbolID: String,
        oldRefdes: String?,
        newRefdes: String,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let oldRefdes = nonEmpty(oldRefdes), oldRefdes != newRefdes else {
            return
        }
        let normalizedSymbolID = normalizedID(symbolID)
        for index in sheet.symbolTexts.indices
            where self.symbolID(forGeometryID: sheet.symbolTexts[index].id).map(normalizedID) == normalizedSymbolID {
            sheet.symbolTexts[index].text = sheet.symbolTexts[index].text.replacingOccurrences(of: oldRefdes, with: newRefdes)
        }
    }

    private func reportComponentRefdesDifferences(
        from previousSymbols: [HorizontalPlacement],
        to currentSymbols: [HorizontalPlacement]
    ) {
        let previousByComponentID = componentRefdesByID(in: previousSymbols)
        let currentByComponentID = componentRefdesByID(in: currentSymbols)
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

    private func shiftSchematicSymbolGeometry(
        symbolID: String,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero else {
            return
        }

        let normalizedSymbolID = normalizedID(symbolID)
        func belongsToSymbol(_ geometryID: String) -> Bool {
            geometryIDHasOwnerPrefix(geometryID, ownerID: normalizedSymbolID)
        }

        for index in sheet.symbolLines.indices where belongsToSymbol(sheet.symbolLines[index].id) {
            sheet.symbolLines[index] = shifted(sheet.symbolLines[index], by: delta)
        }
        for index in sheet.symbolPins.indices where belongsToSymbol(sheet.symbolPins[index].id) {
            sheet.symbolPins[index] = shifted(sheet.symbolPins[index], by: delta)
        }
        for index in sheet.symbolPinCircles.indices where belongsToSymbol(sheet.symbolPinCircles[index].id) {
            sheet.symbolPinCircles[index] = shifted(sheet.symbolPinCircles[index], by: delta)
        }
        for index in sheet.symbolPolygons.indices where belongsToSymbol(sheet.symbolPolygons[index].id) {
            sheet.symbolPolygons[index] = shifted(sheet.symbolPolygons[index], by: delta)
        }
        for index in sheet.symbolTexts.indices where belongsToSymbol(sheet.symbolTexts[index].id) {
            sheet.symbolTexts[index] = shifted(sheet.symbolTexts[index], by: delta)
        }
        for index in sheet.noPopulateMarks.indices where normalizedID(sheet.noPopulateMarks[index].symbolID) == normalizedSymbolID {
            sheet.noPopulateMarks[index].firstLine = shifted(sheet.noPopulateMarks[index].firstLine, by: delta)
            sheet.noPopulateMarks[index].secondLine = shifted(sheet.noPopulateMarks[index].secondLine, by: delta)
        }
    }

    private func shiftSchematicSymbolsGeometry(
        symbolIDs: Set<String>,
        by delta: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero, !symbolIDs.isEmpty else {
            return
        }

        func belongsToMovingSymbol(_ geometryID: String) -> Bool {
            guard let symbolID = symbolID(forGeometryID: geometryID).map(normalizedID) else {
                return false
            }
            return symbolIDs.contains(symbolID)
        }

        for index in sheet.symbolLines.indices where belongsToMovingSymbol(sheet.symbolLines[index].id) {
            sheet.symbolLines[index] = shifted(sheet.symbolLines[index], by: delta)
        }
        for index in sheet.symbolPins.indices where belongsToMovingSymbol(sheet.symbolPins[index].id) {
            sheet.symbolPins[index] = shifted(sheet.symbolPins[index], by: delta)
        }
        for index in sheet.symbolPinCircles.indices where belongsToMovingSymbol(sheet.symbolPinCircles[index].id) {
            sheet.symbolPinCircles[index] = shifted(sheet.symbolPinCircles[index], by: delta)
        }
        for index in sheet.symbolPolygons.indices where belongsToMovingSymbol(sheet.symbolPolygons[index].id) {
            sheet.symbolPolygons[index] = shifted(sheet.symbolPolygons[index], by: delta)
        }
        for index in sheet.symbolTexts.indices where belongsToMovingSymbol(sheet.symbolTexts[index].id) {
            sheet.symbolTexts[index] = shifted(sheet.symbolTexts[index], by: delta)
        }
        for index in sheet.noPopulateMarks.indices where symbolIDs.contains(normalizedID(sheet.noPopulateMarks[index].symbolID)) {
            sheet.noPopulateMarks[index].firstLine = shifted(sheet.noPopulateMarks[index].firstLine, by: delta)
            sheet.noPopulateMarks[index].secondLine = shifted(sheet.noPopulateMarks[index].secondLine, by: delta)
        }
    }

    private func mirrorSchematicSymbolGeometry(
        symbolID: String,
        around center: HorizontalPoint,
        sheet: inout HorizontalSchematicSheet
    ) {
        let normalizedSymbolID = normalizedID(symbolID)
        func belongsToSymbol(_ geometryID: String) -> Bool {
            self.symbolID(forGeometryID: geometryID).map(normalizedID) == normalizedSymbolID
        }

        for index in sheet.symbolLines.indices where belongsToSymbol(sheet.symbolLines[index].id) {
            sheet.symbolLines[index] = mirrored(sheet.symbolLines[index], around: center)
        }
        for index in sheet.symbolPins.indices where belongsToSymbol(sheet.symbolPins[index].id) {
            sheet.symbolPins[index] = mirrored(sheet.symbolPins[index], around: center)
        }
        for index in sheet.symbolPinCircles.indices where belongsToSymbol(sheet.symbolPinCircles[index].id) {
            sheet.symbolPinCircles[index] = mirrored(sheet.symbolPinCircles[index], around: center)
        }
        for index in sheet.symbolPolygons.indices where belongsToSymbol(sheet.symbolPolygons[index].id) {
            sheet.symbolPolygons[index] = mirrored(sheet.symbolPolygons[index], around: center)
        }
        for index in sheet.symbolTexts.indices where belongsToSymbol(sheet.symbolTexts[index].id) {
            sheet.symbolTexts[index] = mirrored(sheet.symbolTexts[index], around: center)
        }
        for index in sheet.noPopulateMarks.indices where normalizedID(sheet.noPopulateMarks[index].symbolID) == normalizedSymbolID {
            sheet.noPopulateMarks[index].firstLine = mirrored(sheet.noPopulateMarks[index].firstLine, around: center)
            sheet.noPopulateMarks[index].secondLine = mirrored(sheet.noPopulateMarks[index].secondLine, around: center)
        }
    }

    private func rotateSchematicSymbolGeometry(
        symbolID: String,
        around origin: HorizontalPoint,
        by angleDelta: Int,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard wrappedAngle(angleDelta) != 0 else {
            return
        }

        let normalizedSymbolID = normalizedID(symbolID)
        func belongsToSymbol(_ geometryID: String) -> Bool {
            self.symbolID(forGeometryID: geometryID).map(normalizedID) == normalizedSymbolID
        }

        for index in sheet.symbolLines.indices where belongsToSymbol(sheet.symbolLines[index].id) {
            sheet.symbolLines[index] = rotated(sheet.symbolLines[index], around: origin, by: angleDelta)
        }
        for index in sheet.symbolPins.indices where belongsToSymbol(sheet.symbolPins[index].id) {
            sheet.symbolPins[index] = rotated(sheet.symbolPins[index], around: origin, by: angleDelta)
        }
        for index in sheet.symbolPinCircles.indices where belongsToSymbol(sheet.symbolPinCircles[index].id) {
            sheet.symbolPinCircles[index] = rotated(sheet.symbolPinCircles[index], around: origin, by: angleDelta)
        }
        for index in sheet.symbolPolygons.indices where belongsToSymbol(sheet.symbolPolygons[index].id) {
            sheet.symbolPolygons[index] = rotated(sheet.symbolPolygons[index], around: origin, by: angleDelta)
        }
        for index in sheet.symbolTexts.indices where belongsToSymbol(sheet.symbolTexts[index].id) {
            sheet.symbolTexts[index] = rotated(sheet.symbolTexts[index], around: origin, by: angleDelta)
        }
        for index in sheet.noPopulateMarks.indices where normalizedID(sheet.noPopulateMarks[index].symbolID) == normalizedSymbolID {
            sheet.noPopulateMarks[index].firstLine = rotated(sheet.noPopulateMarks[index].firstLine, around: origin, by: angleDelta)
            sheet.noPopulateMarks[index].secondLine = rotated(sheet.noPopulateMarks[index].secondLine, around: origin, by: angleDelta)
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
        default:
            break
        }
    }

    private func updateNetLabel(
        _ labels: inout [HorizontalSchematicNetLabel],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = labels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("text", .text(let text)):
            labels[index].text = text
        case ("size", .length(let size)):
            labels[index].size = max(size, 0)
        default:
            break
        }
    }

    private func updateBusLabel(
        _ labels: inout [HorizontalBusLabel],
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue
    ) {
        guard let index = labels.firstIndex(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return
        }

        switch (propertyID, value) {
        case ("text", .text(let text)):
            labels[index].text = text
        case ("size", .length(let size)):
            labels[index].size = max(size, 0)
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

    private func shifted(_ segment: HorizontalSegment, by delta: HorizontalPoint) -> HorizontalSegment {
        HorizontalCanvasModeSupport.shifted(segment, by: delta)
    }

    private func shifted(_ arc: HorizontalArc, by delta: HorizontalPoint) -> HorizontalArc {
        HorizontalCanvasModeSupport.shifted(arc, by: delta)
    }

    private func shifted(_ circle: HorizontalCircle, by delta: HorizontalPoint) -> HorizontalCircle {
        HorizontalCanvasModeSupport.shifted(circle, by: delta)
    }

    private func shifted(_ polygon: HorizontalPolygon, by delta: HorizontalPoint) -> HorizontalPolygon {
        HorizontalCanvasModeSupport.shifted(polygon, by: delta)
    }

    private func shifted(_ text: HorizontalText, by delta: HorizontalPoint) -> HorizontalText {
        HorizontalCanvasModeSupport.shifted(text, by: delta)
    }

    private func geometryIDHasOwnerPrefix(_ geometryID: String, ownerID: String) -> Bool {
        let geometryID = normalizedID(geometryID)
        let ownerID = normalizedID(ownerID)
        return geometryID == ownerID || geometryID.hasPrefix("\(ownerID)/")
    }

    private func mirrored(_ segment: HorizontalSegment, around center: HorizontalPoint) -> HorizontalSegment {
        var segment = segment
        segment.from = mirrored(segment.from, around: center)
        segment.to = mirrored(segment.to, around: center)
        return segment
    }

    private func mirrored(_ arc: HorizontalArc, around center: HorizontalPoint) -> HorizontalArc {
        var arc = arc
        let mirroredFrom = mirrored(arc.from, around: center)
        let mirroredTo = mirrored(arc.to, around: center)
        arc.from = mirroredTo
        arc.to = mirroredFrom
        arc.center = mirrored(arc.center, around: center)
        return arc
    }

    private func mirrored(_ circle: HorizontalCircle, around center: HorizontalPoint) -> HorizontalCircle {
        var circle = circle
        circle.center = mirrored(circle.center, around: center)
        return circle
    }

    private func mirrored(_ polygon: HorizontalPolygon, around center: HorizontalPoint) -> HorizontalPolygon {
        var polygon = polygon
        polygon.vertices = polygon.vertices.map { mirrored($0, around: center) }
        return polygon
    }

    private func mirrored(_ text: HorizontalText, around center: HorizontalPoint) -> HorizontalText {
        var text = text
        text.position = mirrored(text.position, around: center)
        setTextMirror(!text.mirrored, for: &text)
        return text
    }

    private func rotated(_ segment: HorizontalSegment, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalSegment {
        HorizontalCanvasModeSupport.rotated(segment, around: origin, by: angleDelta)
    }

    private func rotated(_ arc: HorizontalArc, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalArc {
        HorizontalCanvasModeSupport.rotated(arc, around: origin, by: angleDelta)
    }

    private func rotated(_ circle: HorizontalCircle, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalCircle {
        HorizontalCanvasModeSupport.rotated(circle, around: origin, by: angleDelta)
    }

    private func rotated(_ polygon: HorizontalPolygon, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalPolygon {
        HorizontalCanvasModeSupport.rotated(polygon, around: origin, by: angleDelta)
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

    private func mirroredOrientation(_ orientation: String) -> String {
        switch orientation {
        case "left":
            return "right"
        case "right":
            return "left"
        default:
            return orientation
        }
    }

    private func rotatedOrientation(_ orientation: String, by angleDelta: Int) -> String {
        let clockwise = wrappedAngle(angleDelta) == wrappedAngle(Self.quarterTurnAngle)
        switch orientation {
        case "up":
            return clockwise ? "right" : "left"
        case "down":
            return clockwise ? "left" : "right"
        case "left":
            return clockwise ? "up" : "down"
        case "right":
            return clockwise ? "down" : "up"
        default:
            return orientation
        }
    }

    private func wrappedAngle(_ angle: Int) -> Int {
        HorizontalCanvasModeSupport.wrappedAngle(angle)
    }

    private func netID(for ref: HorizontalSelectableRef?) -> String? {
        guard let ref else {
            return nil
        }

        switch ref.type {
        case .lineNet:
            return sheet.netLines.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .netLabel:
            return sheet.netLabels.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .junction:
            return netID(forJunctionID: ref.id)
        case .symbolPin:
            return sheet.symbolPins.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
                ?? sheet.symbolPinCircles.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .blockSymbolPort:
            return sheet.blockSymbolPorts.first { normalizedID($0.id) == normalizedID(ref.id) }?.netID
        case .powerSymbol:
            return groupedNetID(
                for: ref.id,
                segments: sheet.powerSymbolLines,
                circles: sheet.powerSymbolCircles,
                texts: sheet.powerSymbolTexts,
                separators: ["circle", "line", "text"]
            )
        case .busRipper:
            return groupedNetID(
                for: ref.id,
                segments: sheet.busRipperLines,
                texts: sheet.busRipperTexts,
                separators: ["line", "text"]
            )
        case .schematicNetTie:
            guard let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }),
                  tie.netIDs.count == 1 else {
                return nil
            }
            return tie.netIDs.first
        case .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .busLabel, .connectionLine, .dimension, .drawingArc, .drawingLine, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .schematicBlockSymbol, .schematicSymbol, .text, .track, .via:
            return nil
        }
    }

    private func componentID(for ref: HorizontalSelectableRef?) -> String? {
        guard let ref else {
            return nil
        }

        switch ref.type {
        case .schematicSymbol:
            return sheet.symbols.first { normalizedID($0.id) == normalizedID(ref.id) }?.componentID
        case .symbolPin:
            guard let symbolID = symbolID(forGeometryID: ref.id) else {
                return nil
            }
            return sheet.symbols.first { normalizedID($0.id) == normalizedID(symbolID) }?.componentID
        default:
            return nil
        }
    }

    private func netID(forJunctionID junctionID: String) -> String? {
        if let netID = sheet.junctionNetIDs[junctionID] {
            return netID
        }

        let normalized = normalizedID(junctionID)
        return sheet.junctionNetIDs.first { normalizedID($0.key) == normalized }?.value
    }

    private func groupedNetID(
        for objectID: String,
        segments: [HorizontalSegment] = [],
        circles: [HorizontalCircle] = [],
        texts: [HorizontalText] = [],
        separators: Set<String>
    ) -> String? {
        for segment in segments where geometryID(segment.id, belongsTo: objectID, separators: separators) {
            if let netID = segment.netID {
                return netID
            }
        }
        for circle in circles where geometryID(circle.id, belongsTo: objectID, separators: separators) {
            if let netID = circle.netID {
                return netID
            }
        }
        for text in texts where geometryID(text.id, belongsTo: objectID, separators: separators) {
            if let netID = text.netID {
                return netID
            }
        }

        return nil
    }

    private func beginMoveNetSegmentToExistingNet() {
        guard !isReadOnly,
              let segment = selectedSchematicNetSegment(in: sheet),
              !segment.hasBusRipper else {
            return
        }

        selectedObjects = segment.refs
        selectedUnplacedObjectID = nil
        netSegmentSelection = segment
        onNetSegmentSelectionChange(sidebarState(for: segment))
        publishSelectionContext()
    }

    private func moveSelectedNetSegmentToNewNet() {
        guard !isReadOnly,
              let segment = selectedSchematicNetSegment(in: sheet),
              segment.hasPins,
              !segment.hasPowerSymbol,
              !segment.hasBusRipper else {
            return
        }

        let netID = UUID().uuidString.lowercased()
        assignNetSegment(
            segment,
            toNetID: netID,
            creating: HorizontalNetDetails(
                id: netID,
                name: "",
                netClassID: sheet.netClasses.first?.id,
                netClassName: sheet.netClasses.first?.name
            )
        )
    }

    private func applyNetSegmentSelectionCommand(_ command: HorizontalNetSegmentSelectionCommand) {
        guard let segment = netSegmentSelection,
              segment.id == command.selectionID else {
            return
        }

        switch command.action {
        case .selectExisting(let netID):
            assignNetSegment(segment, toNetID: netID)
        case .createNew:
            guard segment.hasPins, !segment.hasPowerSymbol, !segment.hasBusRipper else {
                return
            }
            let netID = UUID().uuidString.lowercased()
            assignNetSegment(
                segment,
                toNetID: netID,
                creating: HorizontalNetDetails(
                    id: netID,
                    name: "",
                    netClassID: sheet.netClasses.first?.id,
                    netClassName: sheet.netClasses.first?.name
                )
            )
        case .cancel:
            clearNetSegmentSelection()
        }
    }

    private func clearNetSegmentSelection() {
        guard netSegmentSelection != nil else {
            return
        }
        netSegmentSelection = nil
        onNetSegmentSelectionChange(nil)
    }

    private func sidebarState(for segment: NetSegmentSelectionState) -> HorizontalNetSegmentSelectionSidebarState {
        HorizontalNetSegmentSelectionSidebarState(
            id: segment.id,
            currentNetName: segment.currentNetName,
            options: selectableNamedNets(powerOnly: segment.powerOnly).map { detail in
                HorizontalNetSegmentSelectionOption(
                    id: normalizedID(detail.id),
                    name: detail.name,
                    netClassName: detail.netClassName,
                    isPower: detail.isPower
                )
            },
            canCreateNewNet: segment.hasPins && !segment.hasPowerSymbol && !segment.hasBusRipper
        )
    }

    private func assignNetSegment(
        _ segment: NetSegmentSelectionState,
        toNetID netID: String,
        creating netDetail: HorizontalNetDetails? = nil
    ) {
        guard !isReadOnly else {
            return
        }

        let previousSheet = sheet
        var draft = sheet
        let normalizedNetID = normalizedID(netID)
        if draft.netDetails[normalizedNetID] == nil {
            draft.netDetails[normalizedNetID] = netDetail ?? HorizontalNetDetails(
                id: normalizedNetID,
                name: "",
                netClassID: draft.netClasses.first?.id,
                netClassName: draft.netClasses.first?.name
            )
        }

        applyNetID(normalizedNetID, to: segment, in: &draft)
        selectedObjects = segment.refs
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        clearNetSegmentSelection()
        editedSheet = draft
        registerUndoSnapshot(previousSheet, actionName: "Move Net Segment")
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
    }

    private func applyNetID(
        _ netID: String,
        to segment: NetSegmentSelectionState,
        in sheet: inout HorizontalSchematicSheet
    ) {
        func contains(_ point: HorizontalPoint) -> Bool {
            segment.pointKeys.contains(pointKey(point))
        }

        for index in sheet.netLines.indices
            where contains(sheet.netLines[index].from) || contains(sheet.netLines[index].to) {
            sheet.netLines[index].netID = netID
        }

        for (junctionID, point) in sheet.junctions where contains(point) {
            sheet.junctionNetIDs[junctionID] = netID
        }

        for index in sheet.netLabels.indices where contains(sheet.netLabels[index].position) {
            sheet.netLabels[index].netID = netID
            sheet.netLabels[index].text = schematicNetLabelText(forNetID: netID, in: sheet)
        }

        for index in sheet.busLabels.indices where contains(sheet.busLabels[index].position) {
            sheet.busLabels[index].netID = netID
        }

        updatePowerSymbols(in: &sheet, pointKeys: segment.pointKeys, netID: netID)
        updateSymbolPins(in: &sheet, pointKeys: segment.pointKeys, netID: netID)

        for index in sheet.blockSymbolPorts.indices
            where contains(sheet.blockSymbolPorts[index].from) || contains(sheet.blockSymbolPorts[index].to) {
            sheet.blockSymbolPorts[index].netID = netID
        }

        for index in sheet.netTies.indices {
            if contains(sheet.netTies[index].from) || contains(sheet.netTies[index].to) {
                sheet.netTies[index].netIDs = [netID]
            }
        }
    }

    private func updatePowerSymbols(
        in sheet: inout HorizontalSchematicSheet,
        pointKeys: Set<String>,
        netID: String
    ) {
        let powerSymbolIDs = powerSymbolIDs(in: sheet).filter { symbolID in
            powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet).contains {
                pointKeys.contains(pointKey($0))
            }
        }
        guard !powerSymbolIDs.isEmpty else {
            return
        }

        let symbolIDSet = Set(powerSymbolIDs.map(normalizedID))
        let separators: Set<String> = ["circle", "line", "text"]
        for index in sheet.powerSymbols.indices where symbolIDSet.contains(normalizedID(sheet.powerSymbols[index].id)) {
            sheet.powerSymbols[index].netID = netID
        }
        for index in sheet.powerSymbolLines.indices
            where powerSymbolIDs.contains(where: { geometryID(sheet.powerSymbolLines[index].id, belongsTo: $0, separators: separators) }) {
            sheet.powerSymbolLines[index].netID = netID
        }
        for index in sheet.powerSymbolCircles.indices
            where powerSymbolIDs.contains(where: { geometryID(sheet.powerSymbolCircles[index].id, belongsTo: $0, separators: separators) }) {
            sheet.powerSymbolCircles[index].netID = netID
        }
        for index in sheet.powerSymbolTexts.indices
            where powerSymbolIDs.contains(where: { geometryID(sheet.powerSymbolTexts[index].id, belongsTo: $0, separators: separators) }) {
            sheet.powerSymbolTexts[index].netID = netID
            sheet.powerSymbolTexts[index].text = schematicNetLabelText(forNetID: netID, in: sheet)
        }
    }

    private func updateSymbolPins(
        in sheet: inout HorizontalSchematicSheet,
        pointKeys: Set<String>,
        netID: String
    ) {
        var updatedGatePins = Set<String>()

        func updateComponentConnection(for geometryID: String) {
            guard let symbolID = symbolID(forGeometryID: geometryID).map(normalizedID),
                  let pinID = pinID(forSymbolPinGeometryID: geometryID).map(normalizedID),
                  let symbol = sheet.symbols.first(where: { normalizedID($0.id) == symbolID }),
                  let componentID = symbol.componentID.map(normalizedID),
                  let gateID = symbol.gateID.map(normalizedID) else {
                return
            }

            let gatePinPath = normalizedUUIDPath("\(gateID)/\(pinID)")
            guard updatedGatePins.insert("\(componentID):\(gatePinPath)").inserted else {
                return
            }
            sheet.componentInfo[componentID]?.connections[gatePinPath] = .connected(netID)
        }

        for index in sheet.symbolPins.indices
            where pointKeys.contains(pointKey(sheet.symbolPins[index].from))
                || pointKeys.contains(pointKey(sheet.symbolPins[index].to)) {
            sheet.symbolPins[index].netID = netID
            updateComponentConnection(for: sheet.symbolPins[index].id)
        }

        for index in sheet.symbolPinCircles.indices
            where pointKeys.contains(pointKey(sheet.symbolPinCircles[index].center)) {
            sheet.symbolPinCircles[index].netID = netID
            updateComponentConnection(for: sheet.symbolPinCircles[index].id)
        }
    }

    private func selectedSchematicNetSegment(in sheet: HorizontalSchematicSheet) -> NetSegmentSelectionState? {
        guard !selectedObjects.isEmpty else {
            return nil
        }

        let componentByPoint = schematicNetLineComponents(in: sheet)
        var selectedComponent: Set<String>?
        for ref in selectedObjects {
            guard let component = netSegmentComponent(for: ref, in: sheet, componentByPoint: componentByPoint) else {
                return nil
            }
            if let existing = selectedComponent, existing != component {
                return nil
            }
            selectedComponent = component
        }

        guard let pointKeys = selectedComponent, !pointKeys.isEmpty else {
            return nil
        }

        var refs = [HorizontalSelectableRef]()
        var netIDs = Set<String>()
        var anchorPoints = [HorizontalPoint]()
        var hasPins = false
        var hasPowerSymbol = false
        var hasBusRipper = false

        func contains(_ point: HorizontalPoint) -> Bool {
            pointKeys.contains(pointKey(point))
        }
        func addNet(_ netID: String?) {
            if let netID {
                netIDs.insert(normalizedID(netID))
            }
        }

        for line in sheet.netLines where contains(line.from) || contains(line.to) {
            refs.append(HorizontalSelectableRef(id: line.id, type: .lineNet))
            anchorPoints.append(contentsOf: [line.from, line.to])
            addNet(line.netID)
        }

        for (junctionID, point) in sheet.junctions where contains(point) {
            refs.append(HorizontalSelectableRef(id: junctionID, type: .junction))
            anchorPoints.append(point)
            addNet(sheet.junctionNetIDs[junctionID])
        }

        for label in sheet.netLabels where contains(label.position) {
            refs.append(HorizontalSelectableRef(id: label.id, type: .netLabel))
            anchorPoints.append(label.position)
            addNet(label.netID)
        }

        for label in sheet.busLabels where contains(label.position) {
            refs.append(HorizontalSelectableRef(id: label.id, type: .busLabel))
            anchorPoints.append(label.position)
            addNet(label.netID)
        }

        for symbolID in powerSymbolIDs(in: sheet) {
            let anchors = powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet)
            guard anchors.contains(where: contains) else {
                continue
            }
            refs.append(HorizontalSelectableRef(id: symbolID, type: .powerSymbol))
            anchorPoints.append(contentsOf: anchors)
            hasPowerSymbol = true
            addNet(
                sheet.powerSymbols.first { normalizedID($0.id) == normalizedID(symbolID) }?.netID
                    ?? groupedNetID(
                        for: symbolID,
                        segments: sheet.powerSymbolLines,
                        circles: sheet.powerSymbolCircles,
                        texts: sheet.powerSymbolTexts,
                        separators: ["circle", "line", "text"]
                    )
            )
        }

        for ripperID in busRipperIDs(in: sheet) {
            let points = busRipperConnectionPoints(ripperID: ripperID, sheet: sheet)
            guard points.contains(where: contains) else {
                continue
            }
            refs.append(HorizontalSelectableRef(id: ripperID, type: .busRipper))
            anchorPoints.append(contentsOf: points)
            hasBusRipper = true
            addNet(
                groupedNetID(
                    for: ripperID,
                    segments: sheet.busRipperLines,
                    texts: sheet.busRipperTexts,
                    separators: ["bus-ripper", "line", "text"]
                )
            )
        }

        for tie in sheet.netTies where contains(tie.from) || contains(tie.to) {
            refs.append(HorizontalSelectableRef(id: tie.id, type: .schematicNetTie))
            anchorPoints.append(contentsOf: [tie.from, tie.to])
            tie.netIDs.forEach { addNet($0) }
        }

        for pin in sheet.symbolPins where contains(pin.from) || contains(pin.to) {
            hasPins = true
            addNet(pin.netID)
        }
        for circle in sheet.symbolPinCircles where contains(circle.center) {
            hasPins = true
            addNet(circle.netID)
        }
        for port in sheet.blockSymbolPorts where contains(port.from) || contains(port.to) {
            hasPins = true
            addNet(port.netID)
        }

        guard netIDs.count == 1,
              let netID = netIDs.first,
              !refs.isEmpty else {
            return nil
        }

        refs = Array(Set(refs)).sorted {
            if $0.type.rawValue != $1.type.rawValue {
                return $0.type.rawValue < $1.type.rawValue
            }
            return normalizedID($0.id) < normalizedID($1.id)
        }

        let detail = sheet.netDetails[netID]
        return NetSegmentSelectionState(
            pointKeys: pointKeys,
            refs: refs,
            currentNetID: netID,
            currentNetName: nonEmpty(detail?.name) ?? shortID(netID),
            anchor: HorizontalRect(points: anchorPoints).center,
            powerOnly: detail?.isPower == true,
            hasPowerSymbol: hasPowerSymbol,
            hasBusRipper: hasBusRipper,
            hasPins: hasPins
        )
    }

    private func schematicNetLineComponents(in sheet: HorizontalSchematicSheet) -> [String: Set<String>] {
        var parent = [String: String]()

        func root(_ key: String) -> String {
            if parent[key] == nil {
                parent[key] = key
                return key
            }

            var current = key
            var path = [String]()
            while let next = parent[current], next != current {
                path.append(current)
                current = next
            }
            for item in path {
                parent[item] = current
            }
            return current
        }

        func union(_ lhs: String, _ rhs: String) {
            let lhsRoot = root(lhs)
            let rhsRoot = root(rhs)
            if lhsRoot != rhsRoot {
                parent[rhsRoot] = lhsRoot
            }
        }

        for line in sheet.netLines {
            union(pointKey(line.from), pointKey(line.to))
        }

        var componentsByRoot = [String: Set<String>]()
        for key in Array(parent.keys) {
            componentsByRoot[root(key), default: []].insert(key)
        }

        var componentByPoint = [String: Set<String>]()
        for component in componentsByRoot.values {
            for key in component {
                componentByPoint[key] = component
            }
        }
        return componentByPoint
    }

    private func netSegmentComponent(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet,
        componentByPoint: [String: Set<String>]
    ) -> Set<String>? {
        let points = netSegmentReferencePoints(for: ref, in: sheet)
        guard !points.isEmpty else {
            return nil
        }

        var component: Set<String>?
        for point in points {
            let key = pointKey(point)
            let pointComponent = componentByPoint[key] ?? Set([key])
            if let existing = component, existing != pointComponent {
                return nil
            }
            component = pointComponent
        }
        return component
    }

    private func netSegmentReferencePoints(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalPoint] {
        switch ref.type {
        case .lineNet:
            guard let line = sheet.netLines.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [line.from, line.to]
        case .junction:
            return sheet.junctions
                .filter { normalizedID($0.key) == normalizedID(ref.id) }
                .map(\.value)
        case .netLabel:
            return sheet.netLabels
                .filter { normalizedID($0.id) == normalizedID(ref.id) }
                .map(\.position)
        case .busLabel:
            return sheet.busLabels
                .filter { normalizedID($0.id) == normalizedID(ref.id) }
                .map(\.position)
        case .powerSymbol:
            return powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet)
        case .busRipper:
            return busRipperConnectionPoints(ripperID: ref.id, sheet: sheet)
        case .schematicNetTie:
            guard let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return []
            }
            return [tie.from, tie.to]
        case .blockSymbolPort:
            return sheet.blockSymbolPorts
                .filter { normalizedID($0.id) == normalizedID(ref.id) }
                .flatMap { [$0.from, $0.to] }
        default:
            return []
        }
    }

    private func selectableNamedNets(powerOnly: Bool) -> [HorizontalNetDetails] {
        sheet.netDetails.values
            .filter { detail in
                nonEmpty(detail.name) != nil && (!powerOnly || detail.isPower)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func schematicNetLabelText(forNetID netID: String?, in sheet: HorizontalSchematicSheet) -> String {
        guard let netID else {
            return "? plz fix"
        }

        let detail = sheet.netDetails[normalizedID(netID)]
        let base = nonEmpty(detail?.name) ?? "? plz fix"
        if detail?.isPort == true {
            return "\(schematicPortPrefix(for: detail?.portDirection)): \(base)"
        }
        return base
    }

    private func schematicPortPrefix(for direction: String?) -> String {
        switch direction {
        case "input":
            return "IN"
        case "output":
            return "OUT"
        case "open_collector":
            return "OC"
        case "power_input":
            return "PIN"
        case "power_output":
            return "POUT"
        case "passive":
            return "PASV"
        case "not_connected":
            return "NC"
        default:
            return "BIDI"
        }
    }

    private func geometryID(_ geometryID: String, belongsTo objectID: String, separators: Set<String>) -> Bool {
        let geometryID = normalizedID(geometryID)
        let objectID = normalizedID(objectID)
        if geometryID == objectID || geometryID.hasPrefix("\(objectID)/") {
            return true
        }

        let prefix = objectIDPrefix(in: geometryID, separators: separators)
            ?? geometryID.split(separator: "/").first.map(String.init)
        return prefix == objectID
    }

    private func dispatchCanvasCommand(_ command: HorizontalCanvasCommand) {
        canvasCommandHandlers().dispatch(command)
    }

    private func canvasCommandActions() -> HorizontalCanvasCommandActions {
        canvasCommandHandlers().actions()
    }

    private func canvasCommandHandlers() -> HorizontalCanvasCommandHandlerSet {
        var handlers = HorizontalCanvasCommandHandlerSet(
            isReadOnly: isReadOnly,
            hasInteraction: placePartState != nil || placePinState != nil || drawGraphicsState != nil
                || drawNetLineState != nil || moveState != nil,
            selectAll: selectAllObjects,
            deleteSelection: deleteSelection,
            highlightSelection: {
                onHighlightNetCommand(selectedNetIDs)
                onHighlightComponentCommand(selectedComponentIDs)
            },
            beginMove: { beginMove() },
            rotateSelection: rotateSelection,
            twirlSelection: twirlSelection,
            mirrorSelection: mirrorSelection,
            drawNetLine: beginDrawNetLine,
            drawGraphics: { beginDrawGraphics($0) },
            addText: { addText() },
            editText: { editSelectedText() },
            moveNetSegmentToExistingNet: beginMoveNetSegmentToExistingNet,
            moveNetSegmentToNewNet: moveSelectedNetSegmentToNewNet,
            editSymbolPinNames: selectSymbolForPinNameEditing,
            toggleRectanglePlacementMode: toggleRectanglePlacementMode,
            moveSelectionBy: moveSelectionByGrid,
            hasPlacementInteraction: placePinState != nil,
            commitInteraction: {
                if placePinState != nil {
                    commitPlacePin()
                } else if placePartState != nil {
                    commitPlacePart()
                } else if drawGraphicsState != nil {
                    commitDrawGraphicsAtCursor()
                } else if drawNetLineState != nil {
                    commitDrawNetLine()
                } else {
                    commitMove()
                }
            },
            cancelInteraction: {
                if placePinState != nil {
                    cancelPlacePin()
                } else if placePartState != nil {
                    cancelPlacePart()
                } else if drawGraphicsState != nil {
                    endDrawGraphicsInteraction()
                } else if drawNetLineState != nil {
                    cancelDrawNetLine()
                } else {
                    cancelMove()
                }
            }
        )
        if editorProfile.isPoolMode {
            // No nets in a symbol or frame: the net tools and the pin-name
            // editor (which edits a placed component) do not apply.
            handlers.drawNetLine = nil
            handlers.moveNetSegmentToExistingNet = nil
            handlers.moveNetSegmentToNewNet = nil
            handlers.editSymbolPinNames = nil
        }
        if editorProfile.supportsPins {
            handlers.placePin = { beginPlaceNextPin() }
            // The board's "p" reaches the canvas as placePad; here it places a pin.
            handlers.placePad = { beginPlaceNextPin() }
            handlers.placeRefdesAndValue = { placeRefdesAndValue() }
            handlers.placeDot = { placeDot() }
        }
        return handlers
    }

    private func updateCursor(at point: HorizontalPoint?, worldUnitsPerPoint: Double) {
        if moveState?.tracksCursor == true {
            HorizontalMoveRateDiagnostics.mark(point == nil ? .cursorNil : .cursorEvent)
        }
        if lastCursorWorldPoint != point {
            lastCursorWorldPoint = point
        }

        guard let point else {
            hoveredObject = nil
            return
        }

        if placePartState != nil {
            updatePlacePart(to: point)
            hoveredObject = nil
            return
        }

        if placePinState != nil {
            updatePlacePin(to: point)
            hoveredObject = nil
            return
        }

        if let moveState {
            if moveState.tracksCursor {
                updateMove(to: point)
            }
            hoveredObject = nil
            return
        }

        if var state = drawNetLineState {
            state.cursor = point
            drawNetLineState = state
            hoveredObject = nil
            return
        }

        if var state = drawGraphicsState {
            state.cursor = point
            drawGraphicsState = state
            hoveredObject = nil
            return
        }

        hoveredObject = hitSelectable(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
    }

    private func hitSelectable(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> HorizontalSelectableRef? {
        schematicSelectableScene().hitSelectable(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
    }

    /// Whether a primary-drag press lands on the current selection — the drag
    /// then moves the selection instead of rubber-banding. Never during another
    /// interaction or read-only: those own the pointer already.
    private func pressLandsOnSelection(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> Bool {
        guard !isReadOnly,
              moveState == nil,
              placePartState == nil,
              placePinState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil,
              !selectedObjects.isEmpty else {
            return false
        }
        let refs = schematicSelectableScene().targetRefs(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
        return !Set(selectedObjects).isDisjoint(with: refs)
    }

    private func targetMenuItems(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> [HorizontalSelectionTargetItem] {
        HorizontalCanvasModeSupport.targetMenuItems(
            scene: schematicSelectableScene(),
            at: point,
            worldUnitsPerPoint: worldUnitsPerPoint,
            itemForRef: { hudItem(for: $0) },
            extraItemsForRef: { ref in
                guard ref.type == .schematicSymbol,
                      let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                    return []
                }
                return symbolContextMenuItems(for: symbol, ref: ref)
            }
        )
    }

    /// Per-object right-click action menu (macOS). Only text gets a rich menu
    /// (Select + "Edit…"); every other ref returns empty so it keeps the existing
    /// plain disambiguation/select menu (driven by `targetMenuItems`). The macOS
    /// `showContextMenu` path uses a non-empty result here to build the submenu and
    /// routes "Edit…" through `onTargetMenuCommand` (which selects then dispatches).
    private func schematicTargetItemMenuEntries(for ref: HorizontalSelectableRef) -> [HorizontalTargetItemMenuEntry] {
        #if os(macOS)
        guard !isReadOnly, ref.type == .text else { return [] }
        return [
            .select(title: "Select"),
            .command(title: "Edit…", .editText),
        ]
        #else
        return []
        #endif
    }

    private func symbolContextMenuItems(for symbol: HorizontalPlacement, ref: HorizontalSelectableRef) -> [HorizontalSelectionTargetItem] {
        guard let component = symbol.componentDetails else {
            return []
        }

        var items = [HorizontalSelectionTargetItem]()
        let prefix = HorizontalSelectionTargetItem.identifier(for: ref, suffix: "symbol-action")

        if let value = nonEmpty(displayedValue(for: symbol)) {
            items.append(
                HorizontalSelectionTargetItem(
                    id: "\(prefix):value",
                    title: "Value: \(value)",
                    action: .copyText(value)
                )
            )
        }

        if let mpn = nonEmpty(component.mpn) {
            items.append(
                HorizontalSelectionTargetItem(
                    id: "\(prefix):mpn",
                    title: "MPN: \(mpn)",
                    action: .copyText(mpn)
                )
            )
        }

        if let datasheet = nonEmpty(component.datasheet),
           let url = datasheetURL(datasheet) {
            items.append(
                HorizontalSelectionTargetItem(
                    id: "\(prefix):datasheet",
                    title: "Open Datasheet",
                    action: .openURL(url)
                )
            )
        }

        return items
    }

    private func datasheetURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return nil
    }

    private var selectableCacheKey: SchematicSelectableCacheKey {
        SchematicSelectableCacheKey(
            sheetID: sheet.id,
            revision: selectableCacheRevision,
            displayOptions: displayOptions,
            counts: [
                sheet.junctions.count,
                sheet.netLines.count,
                sheet.drawingLines.count,
                sheet.drawingArcs.count,
                sheet.busLabels.count,
                sheet.busRipperLines.count,
                sheet.busRipperTexts.count,
                sheet.blockSymbolLines.count,
                sheet.blockSymbolPorts.count,
                sheet.blockSymbolTexts.count,
                sheet.netTies.count,
                sheet.symbols.count,
                sheet.symbolLines.count,
                sheet.symbolPins.count,
                sheet.symbolPinCircles.count,
                sheet.symbolPolygons.count,
                sheet.symbolTexts.count,
                sheet.noPopulateMarks.count,
                sheet.texts.count,
                sheet.netLabels.count,
                sheet.powerSymbolLines.count,
                sheet.powerSymbolCircles.count,
                sheet.powerSymbolTexts.count,
                sheet.drawingPolygons.count,
                sheet.editablePins.count,
                showsEditorJunctions ? 1 : 0
            ]
        )
    }

    private func invalidateSelectableCache() {
        selectableCacheRevision &+= 1
        metalCacheRevision &+= 1
        selectableCache.invalidate()
    }

    private func invalidateSchematicInteractionCache() {
        selectableCacheRevision &+= 1
        selectableCache.invalidateInteraction()
    }

    private func schematicSelectableScene() -> HorizontalCanvasSelectableScene {
        selectableCache.selectableScene(key: selectableCacheKey) {
            buildSchematicSelectables()
        }
    }

    private func schematicSelectables() -> [HorizontalSelectable] {
        schematicSelectableScene().selectables
    }

    private func schematicSelectablesByRef() -> [HorizontalSelectableRef: [HorizontalSelectable]] {
        schematicSelectableScene().selectablesByRef
    }

    private func schematicRenderAnalysis() -> SchematicRenderAnalysis {
        selectableCache.renderAnalysis(key: selectableCacheKey) {
            let isolatedNetLineIDs = isolatedNetLineIDs()
            return SchematicRenderAnalysis(
                isolatedNetLineIDs: isolatedNetLineIDs,
                junctionRenderInfo: junctionRenderInfo(isolatedNetLineIDs: isolatedNetLineIDs)
            )
        }
    }

    private func schematicMetalLineBatch(
        isolatedNetLineIDs: Set<String>,
        junctionRenderInfo: [String: JunctionRenderInfo]
    ) -> SchematicMetalLineBatch {
        guard drawsSchematicUnderlayLinesInMetal else {
            return .empty
        }

        let symbolColor = HorizontalMetalRGBA(theme.pin)
        let frameColor = HorizontalMetalRGBA(theme.frame)
        let drawingColor = symbolColor
        let pinColor = HorizontalMetalRGBA(theme.pin.opacity(0.82))
        let pinAnnotationColor = HorizontalMetalRGBA(theme.pinAnnotation)
        let hiddenPinTextColor = HorizontalMetalRGBA(theme.pin.opacity(0.4))
        let netColor = HorizontalMetalRGBA(theme.net)
        let netTieColor = HorizontalMetalRGBA(theme.netTie)
        let isolatedColor = HorizontalMetalRGBA(theme.error)
        let busColor = HorizontalMetalRGBA(theme.bus)
        let junctionColor = HorizontalMetalRGBA(theme.junction)
        let errorColor = HorizontalMetalRGBA(theme.error)
        let originColor = HorizontalMetalRGBA(theme.origin)
        let noPopulateColor = HorizontalMetalRGBA(theme.noPopulate.opacity(0.95))
        let generalTextColor = symbolColor
        let fillsNetLabelBackground = appearanceSettings.shouldFillNetLabelBackground
        let key = SchematicMetalLineCacheKey(
            sheetID: sheet.id,
            revision: metalCacheRevision,
            displayOptions: displayOptions,
            counts: selectableCacheKey.counts,
            frameColor: frameColor,
            drawingColor: drawingColor,
            symbolColor: symbolColor,
            pinColor: pinColor,
            pinAnnotationColor: pinAnnotationColor,
            netColor: netColor,
            netTieColor: netTieColor,
            isolatedColor: isolatedColor,
            busColor: busColor,
            junctionColor: junctionColor,
            errorColor: errorColor,
            originColor: originColor,
            noPopulateColor: noPopulateColor,
            generalTextColor: generalTextColor,
            fillsNetLabelBackground: fillsNetLabelBackground
        )
        let symbolOwnerIDByNormalizedID = sheet.symbols.reduce(into: [String: String]()) { result, symbol in
            result[symbol.id.lowercased()] = symbol.id
        }
        let powerSymbolOwnerIDByNormalizedID = powerSymbolIDs(in: sheet).reduce(into: [String: String]()) { result, symbolID in
            result[normalizedID(symbolID)] = symbolID
        }
        let lineScene = selectableCache.metalLines(key: key) {
            var primitives = [HorizontalMetalLinePrimitive]()
            var spansByRef = [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]]()
            var primitivesByRef = [HorizontalSelectableRef: [HorizontalMetalLinePrimitive]]()
            var primitiveCountsByGroup = [Int: Int]()
            var currentGroup: Int = 0
            var currentOpacity: Float = 1

            func appendPrimitive(
                _ primitive: HorizontalMetalLinePrimitive,
                owner: HorizontalSelectableRef? = nil
            ) {
                let start = primitiveCountsByGroup[currentGroup, default: 0]
                primitiveCountsByGroup[currentGroup] = start + 1
                primitives.append(primitive)
                if let owner {
                    spansByRef[owner, default: []].append(
                        SchematicMetalPrimitiveSpan(
                            compositeGroup: currentGroup,
                            start: start,
                            count: 1
                        )
                    )
                    primitivesByRef[owner, default: []].append(primitive)
                }
            }

            func symbolOwnerRef(for geometryID: String) -> HorizontalSelectableRef? {
                if editorProfile.supportsPins,
                   let pinID = HorizontalSchematicSheet.editorPinID(forGeometryID: geometryID) {
                    return HorizontalSelectableRef(id: pinID, type: .symbolPin)
                }
                guard let symbolID = schematicMetalSymbolID(forGeometryID: geometryID) else {
                    return nil
                }
                let ownerID = symbolOwnerIDByNormalizedID[symbolID] ?? symbolID
                return HorizontalSelectableRef(id: ownerID, type: .schematicSymbol)
            }

            func groupedOwnerRef(
                for geometryID: String,
                type: HorizontalObjectType,
                separators: Set<String>
            ) -> HorizontalSelectableRef? {
                let objectID = schematicMetalObjectIDPrefix(in: geometryID, separators: separators)
                    ?? geometryID.lowercased().split(separator: "/").first.map(String.init)
                return objectID.map { HorizontalSelectableRef(id: $0, type: type) }
            }

            func powerSymbolOwnerRef(for geometryID: String) -> HorizontalSelectableRef? {
                let normalizedGeometryID = HorizontalCanvasModeSupport.normalizedID(geometryID)
                if let ownerID = powerSymbolOwnerIDByNormalizedID
                    .filter({ ownerKey, _ in
                        normalizedGeometryID == ownerKey || normalizedGeometryID.hasPrefix("\(ownerKey)/")
                    })
                    .max(by: { lhs, rhs in lhs.key.count < rhs.key.count })?
                    .value {
                    return HorizontalSelectableRef(id: ownerID, type: .powerSymbol)
                }

                let objectID = schematicMetalObjectIDPrefix(
                    in: geometryID,
                    separators: schematicPowerSymbolGeometrySeparators
                ) ?? geometryID.lowercased().split(separator: "/").first.map(String.init)
                return objectID.map { HorizontalSelectableRef(id: $0, type: .powerSymbol) }
            }

            func appendSegment(
                _ segment: HorizontalSegment,
                color: HorizontalMetalRGBA,
                minimumWidth: Float,
                owner: HorizontalSelectableRef? = nil
            ) {
                appendPrimitive(
                    HorizontalMetalLinePrimitive(
                        from: segment.from,
                        to: segment.to,
                        color: color,
                        width: segment.width,
                        minimumWidth: minimumWidth,
                        compositeGroup: currentGroup,
                        compositeOpacity: currentOpacity
                    ),
                    owner: owner
                )
            }

            func appendPolyline(
                _ points: [HorizontalPoint],
                color: HorizontalMetalRGBA,
                width: Double,
                minimumWidth: Float,
                owner: HorizontalSelectableRef? = nil
            ) {
                guard points.count >= 2 else {
                    return
                }
                for pair in zip(points, points.dropFirst()) {
                    appendPrimitive(
                        HorizontalMetalLinePrimitive(
                            from: pair.0,
                            to: pair.1,
                            color: color,
                            width: width,
                            minimumWidth: minimumWidth,
                            compositeGroup: currentGroup,
                            compositeOpacity: currentOpacity
                        ),
                        owner: owner
                    )
                }
            }

            func appendWorldLine(
                from: HorizontalPoint,
                to: HorizontalPoint,
                color: HorizontalMetalRGBA,
                width: Double = 0,
                minimumWidth: Float = 1,
                owner: HorizontalSelectableRef? = nil
            ) {
                appendPrimitive(
                    HorizontalMetalLinePrimitive(
                        from: from,
                        to: to,
                        color: color,
                        width: width,
                        minimumWidth: minimumWidth,
                        compositeGroup: currentGroup,
                        compositeOpacity: currentOpacity
                    ),
                    owner: owner
                )
            }

            func appendQuadraticCurve(
                from: HorizontalPoint,
                to: HorizontalPoint,
                control: HorizontalPoint,
                color: HorizontalMetalRGBA,
                minimumWidth: Float,
                owner: HorizontalSelectableRef? = nil
            ) {
                let steps = 32
                let points = (0...steps).map { index in
                    let t = Double(index) / Double(steps)
                    let oneMinusT = 1 - t
                    return from * (oneMinusT * oneMinusT)
                        + control * (2 * oneMinusT * t)
                        + to * (t * t)
                }
                appendPolyline(points, color: color, width: 0, minimumWidth: minimumWidth, owner: owner)
            }

            func appendArc(
                _ arc: HorizontalArc,
                color: HorizontalMetalRGBA,
                minimumWidth: Float,
                owner: HorizontalSelectableRef? = nil
            ) {
                appendPolyline(
                    arc.polyline(precision: 48),
                    color: color,
                    width: arc.width,
                    minimumWidth: minimumWidth,
                    owner: owner
                )
            }

            func appendCircle(
                _ circle: HorizontalCircle,
                color: HorizontalMetalRGBA,
                minimumWidth: Float,
                owner: HorizontalSelectableRef? = nil
            ) {
                let segments = 64
                let points = (0...segments).map { index in
                    let angle = Double(index) / Double(segments) * Double.pi * 2
                    return HorizontalPoint(
                        x: circle.center.x + cos(angle) * circle.radius,
                        y: circle.center.y + sin(angle) * circle.radius
                    )
                }
                appendPolyline(points, color: color, width: 0, minimumWidth: minimumWidth, owner: owner)
            }

            func appendText(
                _ text: HorizontalText,
                color: HorizontalMetalRGBA,
                minimumWidth: Float = 0.75,
                owner: HorizontalSelectableRef? = nil
            ) {
                for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                    appendPrimitive(
                        HorizontalMetalLinePrimitive(
                            from: segment.0,
                            to: segment.1,
                            color: color,
                            width: text.width,
                            minimumWidth: minimumWidth,
                            compositeGroup: currentGroup,
                            compositeOpacity: currentOpacity
                        ),
                        owner: owner
                    )
                }
            }

            func appendClosedPolyline(
                _ points: [HorizontalPoint],
                color: HorizontalMetalRGBA,
                width: Double = 0,
                minimumWidth: Float = 1,
                owner: HorizontalSelectableRef? = nil
            ) {
                guard let first = points.first else {
                    return
                }
                appendPolyline(points + [first], color: color, width: width, minimumWidth: minimumWidth, owner: owner)
            }

            func junctionMetalColor(for info: JunctionRenderInfo) -> HorizontalMetalRGBA {
                if info.isIsolated {
                    return isolatedColor
                }
                if info.netID != nil {
                    return netColor
                }
                return junctionColor
            }

            if displayOptions.origin {
                let length = 5_080_000.0
                appendWorldLine(
                    from: HorizontalPoint(x: -length, y: 0),
                    to: HorizontalPoint(x: length, y: 0),
                    color: HorizontalMetalRGBA(theme.error.opacity(0.34)),
                    minimumWidth: 0.8
                )
                appendWorldLine(
                    from: HorizontalPoint(x: 0, y: -length),
                    to: HorizontalPoint(x: 0, y: length),
                    color: HorizontalMetalRGBA(theme.origin.opacity(0.34)),
                    minimumWidth: 0.8
                )
                appendText(schematicOriginText("X", at: HorizontalPoint(x: length, y: 0)), color: HorizontalMetalRGBA(theme.error.opacity(0.52)), minimumWidth: 0.8)
                appendText(schematicOriginText("Y", at: HorizontalPoint(x: 0, y: length)), color: HorizontalMetalRGBA(theme.origin.opacity(0.52)), minimumWidth: 0.8)
            }

            if displayOptions.frame {
                currentGroup = 1; currentOpacity = 0.72
                for line in sheet.frameLines {
                    appendSegment(line, color: frameColor, minimumWidth: 1)
                }
                for polygon in sheet.framePolygons {
                    appendClosedPolyline(polygon.vertices, color: frameColor)
                }
                for text in sheet.frameTexts {
                    appendText(text, color: frameColor)
                }
            }

            if displayOptions.drawing {
                currentGroup = 2; currentOpacity = 0.68
                for line in sheet.drawingLines {
                    appendSegment(
                        line,
                        color: drawingColor,
                        minimumWidth: 1,
                        owner: HorizontalSelectableRef(id: line.id, type: .drawingLine)
                    )
                }
                for arc in sheet.drawingArcs {
                    appendArc(
                        arc,
                        color: drawingColor,
                        minimumWidth: 1,
                        owner: HorizontalSelectableRef(id: arc.id, type: .drawingArc)
                    )
                }
                for polygon in sheet.drawingPolygons {
                    appendClosedPolyline(
                        polygon.renderVertices(arcPrecision: 16),
                        color: drawingColor,
                        owner: HorizontalSelectableRef(id: polygon.id, type: .polygonEdge)
                    )
                }
            }

            if displayOptions.blockSymbols {
                currentGroup = 3; currentOpacity = 0.78
                for line in sheet.blockSymbolLines {
                    appendSegment(
                        line,
                        color: symbolColor,
                        minimumWidth: 1,
                        owner: groupedOwnerRef(
                            for: line.id,
                            type: .schematicBlockSymbol,
                            separators: ["line", "port", "text"]
                        )
                    )
                }

                for port in sheet.blockSymbolPorts {
                    appendSegment(
                        port,
                        color: isBlockSymbolPortAnnotationSegmentID(port.id) ? pinAnnotationColor : pinColor,
                        minimumWidth: 1,
                        owner: groupedOwnerRef(
                            for: port.id,
                            type: .schematicBlockSymbol,
                            separators: ["line", "port", "text"]
                        )
                    )
                }
                for text in sheet.blockSymbolTexts {
                    appendText(
                        text,
                        color: isBlockSymbolPortAnnotationTextID(text.id) ? pinAnnotationColor : symbolColor,
                        owner: groupedOwnerRef(
                            for: text.id,
                            type: .schematicBlockSymbol,
                            separators: ["line", "port", "text"]
                        )
                    )
                }
            }

            if displayOptions.symbols {
                currentGroup = 4; currentOpacity = 0.78
                for polygon in sheet.symbolPolygons {
                    appendClosedPolyline(
                        polygon.vertices,
                        color: symbolColor,
                        owner: symbolOwnerRef(for: polygon.id)
                    )
                }
                for line in sheet.symbolLines {
                    appendSegment(
                        line,
                        color: symbolColor,
                        minimumWidth: 1,
                        owner: symbolOwnerRef(for: line.id)
                    )
                }

                for pin in sheet.symbolPins {
                    appendSegment(
                        pin,
                        color: isPinAnnotationSegmentID(pin.id) ? pinAnnotationColor : pinColor,
                        minimumWidth: 1,
                        owner: symbolOwnerRef(for: pin.id)
                    )
                }

                for circle in sheet.symbolPinCircles {
                    appendCircle(
                        circle,
                        color: pinColor,
                        minimumWidth: 1,
                        owner: symbolOwnerRef(for: circle.id)
                    )
                }
                if displayOptions.text {
                    for text in sheet.symbolTexts {
                        appendText(
                            text,
                            color: isHiddenPinTextID(text.id)
                                ? hiddenPinTextColor
                                : (isPinAnnotationTextID(text.id) ? pinAnnotationColor : symbolColor),
                            owner: symbolOwnerRef(for: text.id)
                        )
                    }
                }
            }

            if displayOptions.nets {
                currentGroup = 5; currentOpacity = 0.75
                for segment in sheet.netLines {
                    appendSegment(
                        segment,
                        color: isolatedNetLineIDs.contains(normalizedID(segment.id)) ? isolatedColor : netColor,
                        minimumWidth: 1.4,
                        owner: HorizontalSelectableRef(id: segment.id, type: .lineNet)
                    )
                }
            }

            if displayOptions.buses {
                currentGroup = 6; currentOpacity = 0.82
                for line in sheet.busRipperLines {
                    appendSegment(
                        line,
                        color: busColor,
                        minimumWidth: 1.4,
                        owner: groupedOwnerRef(
                            for: line.id,
                            type: .busRipper,
                            separators: ["line", "text"]
                        )
                    )
                }
                for text in sheet.busRipperTexts {
                    appendText(
                        text,
                        color: busColor,
                        minimumWidth: 0.85,
                        owner: groupedOwnerRef(
                            for: text.id,
                            type: .busRipper,
                            separators: ["line", "text"]
                        )
                    )
                }
                for label in sheet.busLabels {
                    let text = busLabelText(for: label)
                    let owner = HorizontalSelectableRef(id: label.id, type: .busLabel)
                    appendClosedPolyline(busLabelOutlinePoints(for: label, text: text), color: busColor, owner: owner)
                    appendText(text, color: busColor, minimumWidth: 0.85, owner: owner)
                }
            }

            if displayOptions.netTies {
                currentGroup = 7; currentOpacity = 0.82
                for tie in sheet.netTies {
                    let owner = HorizontalSelectableRef(id: tie.id, type: .schematicNetTie)
                    let from = tie.from
                    let to = tie.to
                    let vector = to - from
                    let normal = HorizontalPoint(x: vector.y, y: -vector.x).normalized
                    let center = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                    let controlOffset = normal * 1_000_000
                    appendQuadraticCurve(from: from, to: to, control: center + controlOffset, color: netTieColor, minimumWidth: 1, owner: owner)
                    appendQuadraticCurve(from: to, to: from, control: center - controlOffset, color: netTieColor, minimumWidth: 1, owner: owner)
                    appendText(netTieText(for: tie), color: netTieColor, minimumWidth: 0.85, owner: owner)
                }
            }

            if displayOptions.netLabels {
                currentGroup = 8; currentOpacity = 0.78
                let labelColor = netColor
                for label in sheet.netLabels {
                    let text = netLabelText(for: label)
                    let owner = HorizontalSelectableRef(id: label.id, type: .netLabel)
                    appendClosedPolyline(netLabelOutlinePoints(for: label, text: text), color: labelColor, owner: owner)
                    appendText(text, color: labelColor, minimumWidth: 0.85, owner: owner)
                }
            }

            currentGroup = 0; currentOpacity = 1
            if displayOptions.junctions, !editorProfile.isPoolMode || showsEditorJunctions {
                for (junctionID, junction) in sheet.junctions {
                    let key = pointKey(junction)
                    var info = junctionRenderInfo[key] ?? JunctionRenderInfo()
                    if info.netID == nil {
                        info.netID = netID(forJunctionID: junctionID)
                    }
                    // A symbol or frame shows every junction it has (there
                    // are no nets to imply them); a sheet only the free ones.
                    if !editorProfile.isPoolMode {
                        guard info.connectionCount < 3,
                              info.connectionCount != 2,
                              !info.hasAttachment else {
                            continue
                        }
                    }

                    let color = junctionMetalColor(for: info)
                    let size = Self.terminalCrossHalfSizeWorld
                    appendWorldLine(
                        from: HorizontalPoint(x: junction.x - size, y: junction.y + size),
                        to: HorizontalPoint(x: junction.x + size, y: junction.y - size),
                        color: color,
                        minimumWidth: 1.2,
                        owner: HorizontalSelectableRef(id: junctionID, type: .junction)
                    )
                    appendWorldLine(
                        from: HorizontalPoint(x: junction.x - size, y: junction.y - size),
                        to: HorizontalPoint(x: junction.x + size, y: junction.y + size),
                        color: color,
                        minimumWidth: 1.2,
                        owner: HorizontalSelectableRef(id: junctionID, type: .junction)
                    )
                }
            }

            if displayOptions.power {
                currentGroup = 9; currentOpacity = 0.78
                for line in sheet.powerSymbolLines {
                    appendSegment(
                        line,
                        color: symbolColor,
                        minimumWidth: 1,
                        owner: powerSymbolOwnerRef(for: line.id)
                    )
                }
                for circle in sheet.powerSymbolCircles {
                    appendCircle(
                        circle,
                        color: pinColor,
                        minimumWidth: 1,
                        owner: powerSymbolOwnerRef(for: circle.id)
                    )
                }
                for text in sheet.powerSymbolTexts {
                    appendText(
                        text,
                        color: symbolColor,
                        owner: powerSymbolOwnerRef(for: text.id)
                    )
                }
            }

            currentGroup = 0; currentOpacity = 1
            if displayOptions.text {
                for text in sheet.texts {
                    appendText(
                        text,
                        color: generalTextColor,
                        owner: HorizontalSelectableRef(id: text.id, type: .text)
                    )
                }
            }

            if displayOptions.symbols {
                for mark in sheet.noPopulateMarks {
                    appendSegment(
                        mark.firstLine,
                        color: noPopulateColor,
                        minimumWidth: 1.6,
                        owner: symbolOwnerRef(for: mark.firstLine.id)
                    )
                    appendSegment(
                        mark.secondLine,
                        color: noPopulateColor,
                        minimumWidth: 1.6,
                        owner: symbolOwnerRef(for: mark.secondLine.id)
                    )
                }
            }

            return (primitives, spansByRef, primitivesByRef)
        }
        let lines = lineScene.0
        let lineSpansByRef = lineScene.1
        let linePrimitivesByRef = lineScene.2

        let symbolFillColor = HorizontalMetalRGBA(theme.pin.opacity(0.13))
        let triangleScene = selectableCache.metalTriangles(key: key) {
            var primitives = [HorizontalMetalTrianglePrimitive]()
            var spansByRef = [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]]()
            var primitivesByRef = [HorizontalSelectableRef: [HorizontalMetalTrianglePrimitive]]()
            var primitiveCountsByGroup = [Int: Int]()

            func symbolOwnerRef(for geometryID: String) -> HorizontalSelectableRef? {
                if editorProfile.supportsPins,
                   let pinID = HorizontalSchematicSheet.editorPinID(forGeometryID: geometryID) {
                    return HorizontalSelectableRef(id: pinID, type: .symbolPin)
                }
                guard let symbolID = schematicMetalSymbolID(forGeometryID: geometryID) else {
                    return nil
                }
                let ownerID = symbolOwnerIDByNormalizedID[symbolID] ?? symbolID
                return HorizontalSelectableRef(id: ownerID, type: .schematicSymbol)
            }

            func appendPrimitive(
                _ primitive: HorizontalMetalTrianglePrimitive,
                owner: HorizontalSelectableRef? = nil
            ) {
                let group = primitive.compositeGroup
                let start = primitiveCountsByGroup[group, default: 0]
                primitiveCountsByGroup[group] = start + 1
                primitives.append(primitive)
                if let owner {
                    spansByRef[owner, default: []].append(
                        SchematicMetalPrimitiveSpan(
                            compositeGroup: group,
                            start: start,
                            count: 1
                        )
                    )
                    primitivesByRef[owner, default: []].append(primitive)
                }
            }

            func appendFilledPolygon(
                _ vertices: [HorizontalPoint],
                color: HorizontalMetalRGBA,
                compositeGroup: Int = 0,
                compositeOpacity: Float = 1,
                owner: HorizontalSelectableRef? = nil
            ) {
                for var triangle in HorizontalMetalTessellator.triangles(for: vertices, color: color) {
                    triangle.compositeGroup = compositeGroup
                    triangle.compositeOpacity = compositeOpacity
                    appendPrimitive(triangle, owner: owner)
                }
            }

            func appendFilledCircle(
                center: HorizontalPoint,
                radius: Double,
                color: HorizontalMetalRGBA,
                owner: HorizontalSelectableRef? = nil
            ) {
                for triangle in HorizontalMetalTessellator.circle(center: center, radius: radius, color: color, segments: 32) {
                    appendPrimitive(triangle, owner: owner)
                }
            }

            func junctionMetalColor(for info: JunctionRenderInfo) -> HorizontalMetalRGBA {
                if info.isIsolated {
                    return isolatedColor
                }
                if info.netID != nil {
                    return netColor
                }
                return junctionColor
            }

            if displayOptions.symbols {
                for polygon in sheet.symbolPolygons {
                    appendFilledPolygon(
                        polygon.vertices,
                        color: symbolFillColor,
                        compositeGroup: 4,
                        compositeOpacity: 0.78,
                        owner: symbolOwnerRef(for: polygon.id)
                    )
                }
            }
            if displayOptions.drawing {
                for polygon in sheet.drawingPolygons {
                    appendFilledPolygon(
                        polygon.renderVertices(arcPrecision: 16),
                        color: symbolFillColor,
                        compositeGroup: 2,
                        compositeOpacity: 0.68,
                        owner: HorizontalSelectableRef(id: polygon.id, type: .polygonEdge)
                    )
                }
            }

            if displayOptions.buses {
                for label in sheet.busLabels {
                    let text = busLabelText(for: label)
                    appendFilledPolygon(
                        busLabelOutlinePoints(for: label, text: text),
                        color: HorizontalMetalRGBA(theme.bus.opacity(0.1)),
                        compositeGroup: 6,
                        compositeOpacity: 0.82,
                        owner: HorizontalSelectableRef(id: label.id, type: .busLabel)
                    )
                }
            }

            if displayOptions.netLabels, fillsNetLabelBackground {
                for label in sheet.netLabels {
                    let text = netLabelText(for: label)
                    appendFilledPolygon(
                        netLabelOutlinePoints(for: label, text: text),
                        color: HorizontalMetalRGBA(theme.net.opacity(0.1)),
                        compositeGroup: 8,
                        compositeOpacity: 0.78,
                        owner: HorizontalSelectableRef(id: label.id, type: .netLabel)
                    )
                }
            }

            if displayOptions.junctions {
                for (junctionID, junction) in sheet.junctions {
                    let key = pointKey(junction)
                    var info = junctionRenderInfo[key] ?? JunctionRenderInfo()
                    if info.netID == nil {
                        info.netID = netID(forJunctionID: junctionID)
                    }
                    if info.connectionCount >= 3 {
                        appendFilledCircle(
                            center: junction,
                            radius: Self.junctionDotRadiusWorld,
                            color: junctionMetalColor(for: info),
                            owner: HorizontalSelectableRef(id: junctionID, type: .junction)
                        )
                    }
                }
            }
            return (primitives, spansByRef, primitivesByRef)
        }
        let triangles = triangleScene.0
        let triangleSpansByRef = triangleScene.1
        let trianglePrimitivesByRef = triangleScene.2

        let anchoredRectScene: (
            [HorizontalMetalAnchoredRectPrimitive],
            [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]],
            [HorizontalSelectableRef: [HorizontalMetalAnchoredRectPrimitive]]
        ) = {
            guard displayOptions.symbols,
                  sheet.symbolLines.isEmpty,
                  sheet.symbolPins.isEmpty,
                  sheet.symbolPolygons.isEmpty else {
                return ([], [:], [:])
            }
            let borderColor = HorizontalMetalRGBA(theme.symbolBoundingBox.opacity(0.8))
            let fillColor = HorizontalMetalRGBA(theme.symbolBoundingBox.opacity(0.22))
            var primitives = [HorizontalMetalAnchoredRectPrimitive]()
            var spansByRef = [HorizontalSelectableRef: [SchematicMetalPrimitiveSpan]]()
            var primitivesByRef = [HorizontalSelectableRef: [HorizontalMetalAnchoredRectPrimitive]]()
            var primitiveCountsByGroup = [Int: Int]()

            func append(_ primitive: HorizontalMetalAnchoredRectPrimitive, owner: HorizontalSelectableRef) {
                let group = primitive.compositeGroup
                let start = primitiveCountsByGroup[group, default: 0]
                primitiveCountsByGroup[group] = start + 1
                primitives.append(primitive)
                spansByRef[owner, default: []].append(
                    SchematicMetalPrimitiveSpan(
                        compositeGroup: group,
                        start: start,
                        count: 1
                    )
                )
                primitivesByRef[owner, default: []].append(primitive)
            }

            for symbol in sheet.symbols {
                let owner = HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol)
                for primitive in [
                    HorizontalMetalAnchoredRectPrimitive(
                        center: symbol.position,
                        color: borderColor,
                        width: 24,
                        height: 16
                    ),
                    HorizontalMetalAnchoredRectPrimitive(
                        center: symbol.position,
                        color: fillColor,
                        width: 22,
                        height: 14
                    )
                ] {
                    append(primitive, owner: owner)
                }
            }
            return (primitives, spansByRef, primitivesByRef)
        }()
        let anchoredRects = anchoredRectScene.0

        return SchematicMetalLineBatch(
            triangleKey: key.hashValue,
            triangles: triangles,
            lineKey: key.hashValue,
            lines: lines,
            handleKey: 0,
            handles: [],
            anchoredRectKey: key.hashValue,
            anchoredRects: anchoredRects,
            metadata: SchematicMetalSceneMetadata(
                lineSpansByRef: lineSpansByRef,
                triangleSpansByRef: triangleSpansByRef,
                anchoredRectSpansByRef: anchoredRectScene.1,
                linePrimitivesByRef: linePrimitivesByRef,
                trianglePrimitivesByRef: trianglePrimitivesByRef,
                anchoredRectPrimitivesByRef: anchoredRectScene.2
            )
        )
    }

    private func schematicMetalMovePatches(
        metadata: SchematicMetalSceneMetadata,
        isolatedNetLineIDs: Set<String>
    ) -> HorizontalMetalBufferPatches {
        guard canPatchSchematicMoveInMetal,
              let moveState else {
            return .empty
        }

        let previewSheet = schematicMovePreviewSheet(for: moveState)
        var refs = Set(selectedObjects.map(schematicMetalPatchOwnerRef))
        refs.formUnion(moveState.connectionPlan.affectedRefs)
        refs.formUnion(moveState.connectionMovePlan.affectedRefs)
        let changedNetLineRefs = HorizontalMoveProfiler.measure("patch.changedNetLineRefs") {
            changedSchematicNetLineRefs(from: moveState.originalSheet, to: previewSheet)
        }
        let changedDrawingLineRefs = changedSchematicDrawingLineRefs(from: moveState.originalSheet, to: previewSheet)
        let changedDrawingArcRefs = changedSchematicDrawingArcRefs(from: moveState.originalSheet, to: previewSheet)
        let changedNetTieRefs = changedSchematicNetTieRefs(from: moveState.originalSheet, to: previewSheet)
        let changedBusRipperRefs = changedSchematicBusRipperRefs(from: moveState.originalSheet, to: previewSheet)
        let shapeChangedRefs = changedNetLineRefs
            .union(changedDrawingLineRefs)
            .union(changedDrawingArcRefs)
            .union(changedNetTieRefs)
            .union(changedBusRipperRefs)
        refs.formUnion(changedNetLineRefs)
        refs.formUnion(changedDrawingLineRefs)
        refs.formUnion(changedDrawingArcRefs)
        refs.formUnion(changedNetTieRefs)
        refs.formUnion(changedBusRipperRefs)
        refs.formUnion(changedSchematicJunctionRefs(from: moveState.originalSheet, to: previewSheet))
        refs.formUnion(changedSchematicNetLabelRefs(from: moveState.originalSheet, to: previewSheet))
        refs.formUnion(changedSchematicBusLabelRefs(from: moveState.originalSheet, to: previewSheet))
        guard !refs.isEmpty else {
            return .empty
        }

        var patches = HorizontalMetalBufferPatches()
        for ref in refs {
            if let spans = metadata.lineSpansByRef[ref] {
                let primitives = HorizontalMoveProfiler.measure("patch.linePrimitives") {
                    if !shapeChangedRefs.contains(ref),
                       let delta = movedSchematicRefDelta(ref: ref, from: moveState.originalSheet, to: previewSheet),
                       let retainedPrimitives = metadata.linePrimitivesByRef[ref] {
                        return retainedPrimitives.map { translated($0, by: delta) }
                    }
                    return schematicMetalLinePrimitives(for: ref, in: previewSheet, isolatedNetLineIDs: isolatedNetLineIDs)
                }
                HorizontalMoveProfiler.measure("patch.linePatchRanges") {
                    patches.linePatches.append(contentsOf: metalLinePatches(spans: spans, primitives: primitives))
                }
            }
            if let spans = metadata.triangleSpansByRef[ref] {
                let primitives = HorizontalMoveProfiler.measure("patch.trianglePrimitives") {
                    if !shapeChangedRefs.contains(ref),
                       let delta = movedSchematicRefDelta(ref: ref, from: moveState.originalSheet, to: previewSheet),
                       let retainedPrimitives = metadata.trianglePrimitivesByRef[ref] {
                        return retainedPrimitives.map { translated($0, by: delta) }
                    }
                    return schematicMetalTrianglePrimitives(for: ref, in: previewSheet)
                }
                HorizontalMoveProfiler.measure("patch.trianglePatchRanges") {
                    patches.trianglePatches.append(contentsOf: metalTrianglePatches(spans: spans, primitives: primitives))
                }
            }
            if let spans = metadata.anchoredRectSpansByRef[ref] {
                let primitives: [HorizontalMetalAnchoredRectPrimitive]
                if let delta = movedSchematicRefDelta(ref: ref, from: moveState.originalSheet, to: previewSheet),
                   let retainedPrimitives = metadata.anchoredRectPrimitivesByRef[ref] {
                    primitives = retainedPrimitives.map { translated($0, by: delta) }
                } else {
                    primitives = metadata.anchoredRectPrimitivesByRef[ref] ?? []
                }
                patches.anchoredRectPatches.append(contentsOf: metalAnchoredRectPatches(spans: spans, primitives: primitives))
            }
        }
        return patches
    }

    private func schematicMetalPatchOwnerRef(for ref: HorizontalSelectableRef) -> HorizontalSelectableRef {
        guard ref.type == .lineNet || ref.type == .drawingLine || ref.type == .drawingArc else {
            return ref
        }
        return HorizontalSelectableRef(id: ref.id, type: ref.type)
    }

    private func movedSchematicRefDelta(
        ref: HorizontalSelectableRef,
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> HorizontalPoint? {
        guard let original = schematicPatchReferencePoint(for: ref, in: originalSheet),
              let current = schematicPatchReferencePoint(for: ref, in: currentSheet) else {
            return nil
        }
        return current - original
    }

    private func schematicPatchReferencePoint(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet
    ) -> HorizontalPoint? {
        let id = normalizedID(ref.id)
        switch ref.type {
        case .schematicSymbol:
            return sheet.symbols.first { normalizedID($0.id) == id }?.position
        case .lineNet:
            return sheet.netLines.first { normalizedID($0.id) == id }?.from
        case .drawingLine:
            return sheet.drawingLines.first { normalizedID($0.id) == id }?.from
        case .drawingArc:
            return sheet.drawingArcs.first { normalizedID($0.id) == id }?.center
        case .junction:
            return sheet.junctions.first { normalizedID($0.key) == id }?.value
        case .netLabel:
            return sheet.netLabels.first { normalizedID($0.id) == id }?.position
        case .busLabel:
            return sheet.busLabels.first { normalizedID($0.id) == id }?.position
        case .busRipper:
            return busRipperConnectionPoints(ripperID: ref.id, sheet: sheet).first
                ?? groupedSchematicReferencePoint(
                    objectID: ref.id,
                    segments: sheet.busRipperLines,
                    texts: sheet.busRipperTexts,
                    separators: ["line", "text"]
                )
        case .powerSymbol:
            return powerSymbolAnchorPoints(symbolID: ref.id, sheet: sheet).first
                ?? groupedSchematicReferencePoint(
                    objectID: ref.id,
                    segments: sheet.powerSymbolLines,
                    circles: sheet.powerSymbolCircles,
                    texts: sheet.powerSymbolTexts,
                    separators: ["circle", "line", "text"]
                )
        case .schematicBlockSymbol:
            return groupedSchematicReferencePoint(
                objectID: ref.id,
                segments: sheet.blockSymbolLines + sheet.blockSymbolPorts,
                texts: sheet.blockSymbolTexts,
                separators: ["line", "port", "text"]
            )
        case .schematicNetTie:
            return sheet.netTies.first { normalizedID($0.id) == id }?.from
        case .text:
            return sheet.texts.first { normalizedID($0.id) == id }?.position
        case .blockSymbolPort:
            return sheet.blockSymbolPorts.first { normalizedID($0.id) == id }?.from
        case .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .symbolPin, .track, .via:
            return nil
        }
    }

    private func groupedSchematicReferencePoint(
        objectID: String,
        segments: [HorizontalSegment],
        circles: [HorizontalCircle] = [],
        texts: [HorizontalText] = [],
        separators: Set<String>
    ) -> HorizontalPoint? {
        groupedSchematicGeometryPoints(
            objectID: objectID,
            segments: segments,
            circles: circles,
            texts: texts,
            separators: separators
        ).first
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

    private func translated(_ primitive: HorizontalMetalAnchoredRectPrimitive, by delta: HorizontalPoint) -> HorizontalMetalAnchoredRectPrimitive {
        var primitive = primitive
        primitive.center = primitive.center + delta
        return primitive
    }

    private func translated(_ selectable: HorizontalSelectable, by delta: HorizontalPoint) -> HorizontalSelectable {
        HorizontalSelectable(
            ref: selectable.ref,
            center: selectable.center + delta,
            boxCenter: selectable.boxCenter + delta,
            boxSize: selectable.boxSize,
            angle: selectable.angle,
            handlePoints: selectable.handlePoints.map { $0 + delta }
        )
    }

    private func changedSchematicNetLineRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        changedSchematicSegmentRefs(
            from: originalSheet.netLines,
            to: currentSheet.netLines,
            type: .lineNet
        )
    }

    private func changedSchematicDrawingLineRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        changedSchematicSegmentRefs(
            from: originalSheet.drawingLines,
            to: currentSheet.drawingLines,
            type: .drawingLine
        )
    }

    private func changedSchematicDrawingArcRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSheet.drawingArcs.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for arc in currentSheet.drawingArcs {
            guard let original = originalByID[normalizedID(arc.id)] else {
                continue
            }
            if original != arc {
                refs.insert(HorizontalSelectableRef(id: arc.id, type: .drawingArc))
            }
        }
        return refs
    }

    private func changedSchematicNetTieRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSheet.netTies.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for tie in currentSheet.netTies {
            guard let original = originalByID[normalizedID(tie.id)] else {
                continue
            }
            if original != tie {
                refs.insert(HorizontalSelectableRef(id: tie.id, type: .schematicNetTie))
            }
        }
        return refs
    }

    private func changedSchematicBusRipperRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        changedSchematicGroupedGeometryRefs(
            fromSegments: originalSheet.busRipperLines,
            fromTexts: originalSheet.busRipperTexts,
            toSegments: currentSheet.busRipperLines,
            toTexts: currentSheet.busRipperTexts,
            type: .busRipper,
            separators: ["line", "text"]
        )
    }

    private func changedSchematicGroupedGeometryRefs(
        fromSegments originalSegments: [HorizontalSegment],
        fromTexts originalTexts: [HorizontalText],
        toSegments currentSegments: [HorizontalSegment],
        toTexts currentTexts: [HorizontalText],
        type: HorizontalObjectType,
        separators: Set<String>
    ) -> Set<HorizontalSelectableRef> {
        var refs = Set<HorizontalSelectableRef>()
        let originalSegmentsByID = Dictionary(uniqueKeysWithValues: originalSegments.map { (normalizedID($0.id), $0) })
        for segment in currentSegments {
            guard let original = originalSegmentsByID[normalizedID(segment.id)],
                  original != segment,
                  let objectID = schematicMetalObjectIDPrefix(in: segment.id, separators: separators)
                    ?? segment.id.lowercased().split(separator: "/").first.map(String.init) else {
                continue
            }
            refs.insert(HorizontalSelectableRef(id: objectID, type: type))
        }

        let originalTextsByID = Dictionary(uniqueKeysWithValues: originalTexts.map { (normalizedID($0.id), $0) })
        for text in currentTexts {
            guard let original = originalTextsByID[normalizedID(text.id)],
                  original != text,
                  let objectID = schematicMetalObjectIDPrefix(in: text.id, separators: separators)
                    ?? text.id.lowercased().split(separator: "/").first.map(String.init) else {
                continue
            }
            refs.insert(HorizontalSelectableRef(id: objectID, type: type))
        }
        return refs
    }

    private func changedSchematicSegmentRefs(
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
                refs.insert(HorizontalSelectableRef(id: segment.id, type: type))
            }
        }
        return refs
    }

    private func changedSchematicJunctionRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSheet.junctions.map { (normalizedID($0.key), $0.value) })
        var refs = Set<HorizontalSelectableRef>()
        for (id, point) in currentSheet.junctions {
            guard let original = originalByID[normalizedID(id)] else {
                continue
            }
            if original != point {
                refs.insert(HorizontalSelectableRef(id: id, type: .junction))
            }
        }
        return refs
    }

    private func changedSchematicNetLabelRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSheet.netLabels.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for label in currentSheet.netLabels {
            guard let original = originalByID[normalizedID(label.id)] else {
                continue
            }
            if original != label {
                refs.insert(HorizontalSelectableRef(id: label.id, type: .netLabel))
            }
        }
        return refs
    }

    private func changedSchematicBusLabelRefs(
        from originalSheet: HorizontalSchematicSheet,
        to currentSheet: HorizontalSchematicSheet
    ) -> Set<HorizontalSelectableRef> {
        let originalByID = Dictionary(uniqueKeysWithValues: originalSheet.busLabels.map { (normalizedID($0.id), $0) })
        var refs = Set<HorizontalSelectableRef>()
        for label in currentSheet.busLabels {
            guard let original = originalByID[normalizedID(label.id)] else {
                continue
            }
            if original != label {
                refs.insert(HorizontalSelectableRef(id: label.id, type: .busLabel))
            }
        }
        return refs
    }

    private func schematicMetalLinePrimitives(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet,
        isolatedNetLineIDs: Set<String>
    ) -> [HorizontalMetalLinePrimitive] {
        let symbolColor = HorizontalMetalRGBA(theme.pin)
        let pinColor = HorizontalMetalRGBA(theme.pin.opacity(0.82))
        let pinAnnotationColor = HorizontalMetalRGBA(theme.pinAnnotation)
        let netColor = HorizontalMetalRGBA(theme.net)
        let netTieColor = HorizontalMetalRGBA(theme.netTie)
        let busColor = HorizontalMetalRGBA(theme.bus)
        let isolatedColor = HorizontalMetalRGBA(theme.error)
        let drawingColor = symbolColor
        let noPopulateColor = HorizontalMetalRGBA(theme.noPopulate.opacity(0.95))
        var primitives = [HorizontalMetalLinePrimitive]()

        func appendLine(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float,
            group: Int,
            opacity: Float
        ) {
            primitives.append(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    compositeGroup: group,
                    compositeOpacity: opacity
                )
            )
        }

        func appendPolyline(
            _ points: [HorizontalPoint],
            color: HorizontalMetalRGBA,
            width: Double = 0,
            minimumWidth: Float,
            group: Int,
            opacity: Float
        ) {
            guard points.count >= 2 else {
                return
            }
            for pair in zip(points, points.dropFirst()) {
                appendLine(
                    from: pair.0,
                    to: pair.1,
                    color: color,
                    width: width,
                    minimumWidth: minimumWidth,
                    group: group,
                    opacity: opacity
                )
            }
        }

        func appendClosedPolyline(_ points: [HorizontalPoint], color: HorizontalMetalRGBA) {
            guard let first = points.first else {
                return
            }
            appendPolyline(points + [first], color: color, minimumWidth: 1, group: 4, opacity: 0.78)
        }

        func appendQuadraticCurve(
            from: HorizontalPoint,
            to: HorizontalPoint,
            control: HorizontalPoint,
            color: HorizontalMetalRGBA,
            minimumWidth: Float,
            group: Int,
            opacity: Float
        ) {
            let steps = 32
            let points = (0...steps).map { index in
                let t = Double(index) / Double(steps)
                let oneMinusT = 1 - t
                return from * (oneMinusT * oneMinusT)
                    + control * (2 * oneMinusT * t)
                    + to * (t * t)
            }
            appendPolyline(points, color: color, minimumWidth: minimumWidth, group: group, opacity: opacity)
        }

        func appendCircle(_ circle: HorizontalCircle, color: HorizontalMetalRGBA) {
            let segments = 64
            let points = (0...segments).map { index in
                let angle = Double(index) / Double(segments) * Double.pi * 2
                return HorizontalPoint(
                    x: circle.center.x + cos(angle) * circle.radius,
                    y: circle.center.y + sin(angle) * circle.radius
                )
            }
            appendPolyline(points, color: color, minimumWidth: 1, group: 4, opacity: 0.78)
        }

        func appendText(
            _ text: HorizontalText,
            color: HorizontalMetalRGBA,
            minimumWidth: Float = 0.75,
            group: Int = 4,
            opacity: Float = 0.78
        ) {
            for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                appendLine(
                    from: segment.0,
                    to: segment.1,
                    color: color,
                    width: text.width,
                    minimumWidth: minimumWidth,
                    group: group,
                    opacity: opacity
                )
            }
        }

        switch ref.type {
        case .schematicSymbol:
            let normalizedSymbolID = normalizedID(ref.id)
            func belongsToSymbol(_ id: String) -> Bool {
                symbolID(forGeometryID: id).map(normalizedID) == normalizedSymbolID
            }

            for polygon in sheet.symbolPolygons where belongsToSymbol(polygon.id) {
                appendClosedPolyline(polygon.vertices, color: symbolColor)
            }
            for line in sheet.symbolLines where belongsToSymbol(line.id) {
                appendLine(from: line.from, to: line.to, color: symbolColor, width: line.width, minimumWidth: 1, group: 4, opacity: 0.78)
            }
            for pin in sheet.symbolPins where belongsToSymbol(pin.id) {
                appendLine(
                    from: pin.from,
                    to: pin.to,
                    color: isPinAnnotationSegmentID(pin.id) ? pinAnnotationColor : pinColor,
                    width: pin.width,
                    minimumWidth: 1,
                    group: 4,
                    opacity: 0.78
                )
            }
            for circle in sheet.symbolPinCircles where belongsToSymbol(circle.id) {
                appendCircle(circle, color: pinColor)
            }
            if displayOptions.text {
                for text in sheet.symbolTexts where belongsToSymbol(text.id) {
                    appendText(text, color: isPinAnnotationTextID(text.id) ? pinAnnotationColor : symbolColor)
                }
            }
            for mark in sheet.noPopulateMarks {
                if belongsToSymbol(mark.firstLine.id) {
                    appendLine(from: mark.firstLine.from, to: mark.firstLine.to, color: noPopulateColor, width: mark.firstLine.width, minimumWidth: 1.6, group: 0, opacity: 1)
                }
                if belongsToSymbol(mark.secondLine.id) {
                    appendLine(from: mark.secondLine.from, to: mark.secondLine.to, color: noPopulateColor, width: mark.secondLine.width, minimumWidth: 1.6, group: 0, opacity: 1)
                }
            }
        case .lineNet:
            if let line = sheet.netLines.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendLine(
                    from: line.from,
                    to: line.to,
                    color: isolatedNetLineIDs.contains(normalizedID(line.id)) ? isolatedColor : netColor,
                    width: line.width,
                    minimumWidth: 1.4,
                    group: 5,
                    opacity: 0.75
                )
            }
        case .drawingLine:
            if let line = sheet.drawingLines.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendLine(
                    from: line.from,
                    to: line.to,
                    color: drawingColor,
                    width: line.width,
                    minimumWidth: 1,
                    group: 2,
                    opacity: 0.68
                )
            }
        case .drawingArc:
            if let arc = sheet.drawingArcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendPolyline(
                    arc.polyline(precision: 64),
                    color: drawingColor,
                    width: arc.width,
                    minimumWidth: 1,
                    group: 2,
                    opacity: 0.68
                )
            }
        case .text:
            if let text = sheet.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                appendText(
                    text,
                    color: symbolColor,
                    group: 0,
                    opacity: 1
                )
            }
        case .schematicNetTie:
            if let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) {
                let from = tie.from
                let to = tie.to
                let vector = to - from
                let normal = HorizontalPoint(x: vector.y, y: -vector.x).normalized
                let center = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                let controlOffset = normal * 1_000_000
                appendQuadraticCurve(
                    from: from,
                    to: to,
                    control: center + controlOffset,
                    color: netTieColor,
                    minimumWidth: 1,
                    group: 7,
                    opacity: 0.82
                )
                appendQuadraticCurve(
                    from: to,
                    to: from,
                    control: center - controlOffset,
                    color: netTieColor,
                    minimumWidth: 1,
                    group: 7,
                    opacity: 0.82
                )
                appendText(netTieText(for: tie), color: netTieColor, minimumWidth: 0.85, group: 7, opacity: 0.82)
            }
        case .busRipper:
            let normalizedRipperID = normalizedID(ref.id)
            func belongsToBusRipper(_ id: String) -> Bool {
                let objectID = schematicMetalObjectIDPrefix(in: id, separators: ["line", "text"])
                    ?? id.lowercased().split(separator: "/").first.map(String.init)
                return objectID.map(normalizedID) == normalizedRipperID
            }

            for line in sheet.busRipperLines where belongsToBusRipper(line.id) {
                appendLine(
                    from: line.from,
                    to: line.to,
                    color: busColor,
                    width: line.width,
                    minimumWidth: 1,
                    group: 6,
                    opacity: 0.82
                )
            }
            for text in sheet.busRipperTexts where belongsToBusRipper(text.id) {
                appendText(text, color: busColor, minimumWidth: 0.85, group: 6, opacity: 0.82)
            }
        case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .busLabel, .connectionLine, .dimension, .junction, .keepout, .netLabel, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .powerSymbol, .schematicBlockSymbol, .symbolPin, .track, .via:
            break
        }

        return primitives
    }

    private func schematicMetalTrianglePrimitives(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalMetalTrianglePrimitive] {
        guard ref.type == .schematicSymbol else {
            return []
        }

        let symbolFillColor = HorizontalMetalRGBA(theme.pin.opacity(0.13))
        let normalizedSymbolID = normalizedID(ref.id)
        func belongsToSymbol(_ id: String) -> Bool {
            symbolID(forGeometryID: id).map(normalizedID) == normalizedSymbolID
        }

        var primitives = [HorizontalMetalTrianglePrimitive]()
        for polygon in sheet.symbolPolygons where belongsToSymbol(polygon.id) {
            for var triangle in HorizontalMetalTessellator.triangles(for: polygon.vertices, color: symbolFillColor) {
                triangle.compositeGroup = 4
                triangle.compositeOpacity = 0.78
                primitives.append(triangle)
            }
        }
        return primitives
    }

    private func metalLinePatches(
        spans: [SchematicMetalPrimitiveSpan],
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

    private func metalTrianglePatches(
        spans: [SchematicMetalPrimitiveSpan],
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

    private func metalAnchoredRectPatches(
        spans: [SchematicMetalPrimitiveSpan],
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

    private func schematicMetalHighlightBatch() -> SchematicMetalLineBatch {
        guard drawsSchematicUnderlayLinesInMetal, hasActiveHighlight else {
            return .empty
        }

        let highlightColor = HorizontalMetalRGBA(theme.junction.opacity(0.95))
        let highlightFillColor = HorizontalMetalRGBA(theme.junction.opacity(0.08))
        let highlightedJunctionFillColor = HorizontalMetalRGBA(theme.junction.opacity(0.5))
        let highlightedJunctionStrokeColor = HorizontalMetalRGBA(theme.junction.opacity(0.98))
        let symbolColor = HorizontalMetalRGBA(theme.pin.opacity(0.92))
        let pinColor = HorizontalMetalRGBA(theme.pin.opacity(0.86))
        let pinAnnotationColor = HorizontalMetalRGBA(theme.pinAnnotation.opacity(0.9))
        let backgroundColor = HorizontalMetalRGBA(theme.background.opacity(0.55))
        let highlightedIDs = Set(highlightedNetIDs.map { $0.lowercased() })
        let highlightedComponentIDSet = Set(highlightedComponentIDs.map { $0.lowercased() })
        let junctionNetIDs = Dictionary(uniqueKeysWithValues: sheet.junctionNetIDs.map { ($0.key.lowercased(), $0.value) })
        let sheetSnapshot = sheet
        let displayOptionsSnapshot = displayOptions
        let key = SchematicMetalHighlightCacheKey(
            selectableKey: selectableCacheKey,
            highlightedNetIDs: highlightedIDs.sorted(),
            highlightedComponentIDs: highlightedComponentIDSet.sorted(),
            highlightColor: highlightColor,
            symbolColor: symbolColor,
            pinColor: pinColor,
            pinAnnotationColor: pinAnnotationColor,
            backgroundColor: backgroundColor
        )

        return selectableCache.metalHighlight(key: key) {
            var lines = [HorizontalMetalLinePrimitive]()
            var triangles = [HorizontalMetalTrianglePrimitive]()

            func appendLine(
                from: HorizontalPoint,
                to: HorizontalPoint,
                color: HorizontalMetalRGBA,
                width: Double = 0,
                minimumWidth: Float
            ) {
                lines.append(
                    HorizontalMetalLinePrimitive(
                        from: from,
                        to: to,
                        color: color,
                        width: width,
                        minimumWidth: minimumWidth
                    )
                )
            }

            func appendSegment(_ segment: HorizontalSegment, color: HorizontalMetalRGBA, minimumWidth: Float) {
                appendLine(
                    from: segment.from,
                    to: segment.to,
                    color: color,
                    width: segment.width,
                    minimumWidth: minimumWidth
                )
            }

            func appendPolyline(_ points: [HorizontalPoint], color: HorizontalMetalRGBA, width: Double = 0, minimumWidth: Float) {
                guard points.count >= 2 else {
                    return
                }
                for pair in zip(points, points.dropFirst()) {
                    appendLine(from: pair.0, to: pair.1, color: color, width: width, minimumWidth: minimumWidth)
                }
            }

            func appendClosedPolyline(_ points: [HorizontalPoint], color: HorizontalMetalRGBA, minimumWidth: Float) {
                guard let first = points.first else {
                    return
                }
                appendPolyline(points + [first], color: color, minimumWidth: minimumWidth)
            }

            func appendQuadraticCurve(from: HorizontalPoint, to: HorizontalPoint, control: HorizontalPoint, color: HorizontalMetalRGBA, minimumWidth: Float) {
                let steps = 32
                let points = (0...steps).map { index in
                    let t = Double(index) / Double(steps)
                    let oneMinusT = 1 - t
                    return from * (oneMinusT * oneMinusT)
                        + control * (2 * oneMinusT * t)
                        + to * (t * t)
                }
                appendPolyline(points, color: color, minimumWidth: minimumWidth)
            }

            func appendCircle(center: HorizontalPoint, radius: Double, color: HorizontalMetalRGBA, minimumWidth: Float) {
                let segments = 64
                let points = (0...segments).map { index in
                    let angle = Double(index) / Double(segments) * Double.pi * 2
                    return HorizontalPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                }
                appendPolyline(points, color: color, minimumWidth: minimumWidth)
            }

            func appendText(_ text: HorizontalText, color: HorizontalMetalRGBA, minimumWidth: Float) {
                for segment in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                    appendLine(from: segment.0, to: segment.1, color: color, width: text.width, minimumWidth: minimumWidth)
                }
            }

            func angleUnits(from: HorizontalPoint, to: HorizontalPoint) -> Int {
                let radians = atan2(to.y - from.y, to.x - from.x)
                return Int((radians / (2 * Double.pi) * 65_536).rounded())
            }

            func matches(_ netID: String?) -> Bool {
                guard let netID else {
                    return false
                }
                return highlightedIDs.contains(netID.lowercased())
            }

            func matches(_ netIDs: Set<String>) -> Bool {
                netIDs.contains { matches($0) }
            }

            func junctionNetID(_ junctionID: String) -> String? {
                junctionNetIDs[junctionID.lowercased()]
            }

            func angleForOrientation(_ orientation: String) -> Int {
                switch orientation {
                case "left":
                    return 32_768
                case "up":
                    return 16_384
                case "down":
                    return 49_152
                default:
                    return 0
                }
            }

            func labelTextShift(size: Double, orientation: String) -> HorizontalPoint {
                switch orientation {
                case "left":
                    return HorizontalPoint(x: -size, y: 0)
                case "up":
                    return HorizontalPoint(x: 0, y: size)
                case "down":
                    return HorizontalPoint(x: 0, y: -size)
                default:
                    return HorizontalPoint(x: size, y: 0)
                }
            }

            func highlightedNetLabelText(for label: HorizontalSchematicNetLabel) -> HorizontalText {
                HorizontalText(
                    id: "\(label.id)/net-label-text",
                    text: label.text,
                    position: label.position + labelTextShift(size: label.size, orientation: label.orientation),
                    size: label.size,
                    layer: nil,
                    angle: angleForOrientation(label.orientation),
                    origin: .center
                )
            }

            func labelBounds(for text: HorizontalText) -> (HorizontalPoint, HorizontalPoint) {
                let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
                let points = [text.position] + segments.flatMap { [$0.0, $0.1] }
                let xs = points.map(\.x)
                let ys = points.map(\.y)
                let enlarge = text.size / 4
                return (
                    HorizontalPoint(
                        x: (xs.min() ?? text.position.x) - enlarge,
                        y: (ys.min() ?? text.position.y) - enlarge
                    ),
                    HorizontalPoint(
                        x: (xs.max() ?? text.position.x) + enlarge,
                        y: (ys.max() ?? text.position.y) + enlarge
                    )
                )
            }

            func flagOutlinePoints(position: HorizontalPoint, min: HorizontalPoint, max: HorizontalPoint, orientation: String) -> [HorizontalPoint] {
                let topLeft = HorizontalPoint(x: min.x, y: max.y)
                let bottomRight = HorizontalPoint(x: max.x, y: min.y)

                switch orientation {
                case "left":
                    return [min, topLeft, max, position, bottomRight]
                case "up":
                    return [position, min, topLeft, max, bottomRight]
                case "down":
                    return [position, max, bottomRight, min, topLeft]
                default:
                    return [max, bottomRight, min, position, topLeft]
                }
            }

            func highlightedNetLabelOutlinePoints(for label: HorizontalSchematicNetLabel, text: HorizontalText) -> [HorizontalPoint] {
                let bounds = labelBounds(for: text)
                return flagOutlinePoints(
                    position: label.position,
                    min: bounds.0,
                    max: bounds.1,
                    orientation: label.orientation
                )
            }

            func appendNetTie(_ tie: HorizontalSchematicNetTie) {
                let from = tie.from
                let to = tie.to
                let vector = to - from
                let normal = HorizontalPoint(x: vector.y, y: -vector.x).normalized
                let center = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                let controlOffset = normal * 1_000_000
                appendQuadraticCurve(from: from, to: to, control: center + controlOffset, color: highlightColor, minimumWidth: 2.8)
                appendQuadraticCurve(from: to, to: from, control: center - controlOffset, color: highlightColor, minimumWidth: 2.8)
                appendText(
                    HorizontalText(
                        id: "\(tie.id)/net-tie-label",
                        text: tie.label,
                        position: center + normal * 1_500_000,
                        size: 1_500_000,
                        layer: nil,
                        angle: angleUnits(from: from, to: to),
                        origin: .center,
                        centered: true
                    ),
                    color: highlightColor,
                    minimumWidth: 1.1
                )
            }

            func isPinAnnotationSegmentIDLocal(_ id: String) -> Bool {
                id.contains("/pin-direction/")
                    || (id.contains("/pin-connector/") && id.contains("/nc/"))
            }

            func isPinAnnotationTextIDLocal(_ id: String) -> Bool {
                id.contains("/pin-name/")
                    || id.contains("/pin-pad/")
                    || id.contains("/pin-connector-text/")
            }

            func isBlockSymbolPortAnnotationSegmentIDLocal(_ id: String) -> Bool {
                id.contains("/block-port-direction/")
                    || (id.contains("/block-port-connector/") && id.contains("/nc/"))
            }

            func annotationColor(for segmentID: String) -> HorizontalMetalRGBA {
                isPinAnnotationSegmentIDLocal(segmentID) || isBlockSymbolPortAnnotationSegmentIDLocal(segmentID)
                    ? pinAnnotationColor
                    : pinColor
            }

            func symbolTextColor(for textID: String) -> HorizontalMetalRGBA {
                isPinAnnotationTextIDLocal(textID) ? pinAnnotationColor : symbolColor
            }

            func matchesComponent(_ componentID: String?) -> Bool {
                guard let componentID else {
                    return false
                }
                return highlightedComponentIDSet.contains(componentID.lowercased())
            }

            func symbolIDPrefix(for geometryID: String) -> String? {
                schematicMetalSymbolID(forGeometryID: geometryID)
            }

            func belongsToSymbol(_ geometryID: String, symbolID: String) -> Bool {
                symbolIDPrefix(for: geometryID).map { $0 == symbolID } ?? false
            }

            let pointsBySymbol = schematicSymbolGeometryPoints()

            func appendHighlightedSymbol(_ symbol: HorizontalPlacement) {
                let symbolID = symbol.id.lowercased()
                let symbolPoints = pointsBySymbol[symbolID] ?? []
                let selectable = HorizontalSelectable.bounds(
                    ref: HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol),
                    points: symbolPoints,
                    fallbackCenter: symbol.position,
                    fallbackSize: 2_540_000
                )
                triangles.append(contentsOf: HorizontalMetalTessellator.triangles(for: selectable.corners, color: highlightFillColor))
                appendClosedPolyline(selectable.corners, color: highlightColor, minimumWidth: 1.4)

                for polygon in sheetSnapshot.symbolPolygons where belongsToSymbol(polygon.id, symbolID: symbolID) {
                    appendClosedPolyline(polygon.vertices, color: symbolColor, minimumWidth: 2.4)
                }
                for line in sheetSnapshot.symbolLines where belongsToSymbol(line.id, symbolID: symbolID) {
                    appendSegment(line, color: symbolColor, minimumWidth: 2.4)
                }
                for pin in sheetSnapshot.symbolPins where belongsToSymbol(pin.id, symbolID: symbolID) {
                    appendSegment(pin, color: annotationColor(for: pin.id), minimumWidth: 2.4)
                }
                for circle in sheetSnapshot.symbolPinCircles where belongsToSymbol(circle.id, symbolID: symbolID) {
                    appendCircle(center: circle.center, radius: circle.radius, color: pinColor, minimumWidth: 2.2)
                }
                if displayOptionsSnapshot.text {
                    for text in sheetSnapshot.symbolTexts where belongsToSymbol(text.id, symbolID: symbolID) {
                        appendText(text, color: symbolTextColor(for: text.id), minimumWidth: 1.1)
                    }
                }
            }

            if displayOptions.symbols {
                for symbol in sheet.symbols where matchesComponent(symbol.componentID) {
                    appendHighlightedSymbol(symbol)
                }
            }

            if displayOptions.nets {
                for segment in sheet.netLines where matches(segment.netID) {
                    appendSegment(segment, color: highlightColor, minimumWidth: 3.2)
                }
            }

            if displayOptions.netTies {
                for tie in sheet.netTies where matches(tie.netIDs) {
                    appendNetTie(tie)
                }
            }

            if displayOptions.symbols {
                for segment in sheet.symbolPins where matches(segment.netID) {
                    appendSegment(segment, color: annotationColor(for: segment.id), minimumWidth: 2.4)
                }
                for circle in sheet.symbolPinCircles where matches(circle.netID) {
                    appendCircle(center: circle.center, radius: circle.radius, color: pinColor, minimumWidth: 2.2)
                }
            }

            if displayOptions.blockSymbols {
                for segment in sheet.blockSymbolPorts where matches(segment.netID) {
                    appendSegment(segment, color: annotationColor(for: segment.id), minimumWidth: 2.4)
                }
            }

            if displayOptions.buses {
                for segment in sheet.busRipperLines where matches(segment.netID) {
                    appendSegment(segment, color: highlightColor, minimumWidth: 2.6)
                }
                for text in sheet.busRipperTexts where matches(text.netID) {
                    appendText(text, color: highlightColor, minimumWidth: 1.1)
                }
            }

            if displayOptions.netLabels {
                for label in sheet.netLabels where matches(label.netID) {
                    let text = highlightedNetLabelText(for: label)
                    let outline = highlightedNetLabelOutlinePoints(for: label, text: text)
                    triangles.append(contentsOf: HorizontalMetalTessellator.triangles(
                        for: outline,
                        color: highlightFillColor
                    ))
                    appendClosedPolyline(outline, color: highlightColor, minimumWidth: 1.0)
                    appendText(text, color: highlightColor, minimumWidth: 1.1)
                }
            }

            if displayOptions.junctions {
                for (junctionID, junction) in sheet.junctions where matches(junctionNetID(junctionID)) {
                    let radius = Self.junctionDotRadiusWorld + Self.junctionHighlightPaddingWorld
                    triangles.append(contentsOf: HorizontalMetalTessellator.circle(
                        center: junction,
                        radius: radius,
                        color: highlightedJunctionFillColor,
                        segments: 32
                    ))
                    appendCircle(center: junction, radius: radius, color: highlightedJunctionStrokeColor, minimumWidth: 1.2)
                }
            }

            if displayOptions.power {
                for line in sheet.powerSymbolLines where matches(line.netID) {
                    appendSegment(line, color: pinColor, minimumWidth: 2.4)
                }
                for circle in sheet.powerSymbolCircles where matches(circle.netID) {
                    appendCircle(center: circle.center, radius: circle.radius, color: pinColor, minimumWidth: 2.2)
                }
                for text in sheet.powerSymbolTexts where matches(text.netID) {
                    appendText(text, color: pinColor, minimumWidth: 1.1)
                }
            }

            let batchKey = key.hashValue
            return SchematicMetalLineBatch(
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

    private func schematicMetalDimBatch(hasMetalHighlight: Bool) -> SchematicMetalLineBatch {
        guard drawsSchematicUnderlayLinesInMetal,
              hasMetalHighlight,
              hasActiveHighlight,
              !sheet.bounds.isEmpty else {
            return .empty
        }

        let vertices = [
            HorizontalPoint(x: sheet.bounds.minX, y: sheet.bounds.minY),
            HorizontalPoint(x: sheet.bounds.maxX, y: sheet.bounds.minY),
            HorizontalPoint(x: sheet.bounds.maxX, y: sheet.bounds.maxY),
            HorizontalPoint(x: sheet.bounds.minX, y: sheet.bounds.maxY)
        ]
        let triangles = HorizontalMetalTessellator.triangles(
            for: vertices,
            color: HorizontalMetalRGBA(theme.background.opacity(0.54))
        )
        let key = highlightedNetIDs.hashValue
            &* 31
            &+ highlightedComponentIDs.hashValue
            &* 31
            &+ sheet.bounds.minX.hashValue
            &+ sheet.bounds.minY.hashValue
            &+ sheet.bounds.maxX.hashValue
            &+ sheet.bounds.maxY.hashValue
        return SchematicMetalLineBatch(
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

    private func schematicMetalSelectionBatch() -> SchematicMetalLineBatch {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported,
              (!selectedObjects.isEmpty || hoveredObject != nil) else {
            return .empty
        }

        let selectedOuterColor = HorizontalMetalRGBA(theme.selectableOuter.opacity(0.95))
        let selectedInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.62))
        let selectedHandleInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.82))
        let hoverOuterColor = HorizontalMetalRGBA(theme.selectablePrelight.opacity(0.78))
        let hoverInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.38))
        let handleShape = appearanceSettings.canvasSelectionHandleShape
        let key = SchematicMetalSelectionCacheKey(
            selectableKey: selectableCacheKey,
            selectedRefs: selectedObjects,
            hoveredRef: hoveredObject,
            selectedOuterColor: selectedOuterColor,
            selectedInnerColor: selectedInnerColor,
            selectedHandleInnerColor: selectedHandleInnerColor,
            hoverOuterColor: hoverOuterColor,
            hoverInnerColor: hoverInnerColor,
            handleShape: handleShape
        )

        return selectableCache.metalSelection(key: key) {
            let selectionSheet = moveState?.originalSheet ?? sheet
            let selectablesByRef = schematicSelectablesByRef()
            let style = HorizontalCanvasSelectionOverlayStyle(
                selectedOuterColor: selectedOuterColor,
                selectedInnerColor: selectedInnerColor,
                selectedHandleInnerColor: selectedHandleInnerColor,
                hoverOuterColor: hoverOuterColor,
                hoverInnerColor: hoverInnerColor,
                handleShape: handleShape
            )
            let overlay = schematicMetalSelectionOverlay(
                selectablesByRef: selectablesByRef,
                selectedRefs: selectedObjects,
                hoveredRef: hoveredObject,
                style: style,
                selectionSheet: selectionSheet
            )

            let batchKey = key.hashValue
            return SchematicMetalLineBatch(
                triangleKey: batchKey,
                triangles: [],
                lineKey: batchKey,
                lines: overlay.lines,
                handleKey: batchKey,
                handles: overlay.handles,
                anchoredRectKey: 0,
                anchoredRects: []
            )
        }
        #else
        return .empty
        #endif
    }

    private func schematicMetalSelectionMovePatches(
        baseSelectionBatch: SchematicMetalLineBatch,
        lineStart: Int,
        handleStart: Int
    ) -> HorizontalMetalBufferPatches {
        guard canPatchSchematicMoveInMetal,
              let moveState,
              (!baseSelectionBatch.lines.isEmpty || !baseSelectionBatch.handles.isEmpty) else {
            return .empty
        }

        let previewSheet = schematicMovePreviewSheet(for: moveState)
        let shapeChangedRefs = changedSchematicNetLineRefs(from: moveState.originalSheet, to: previewSheet)
            .union(changedSchematicDrawingLineRefs(from: moveState.originalSheet, to: previewSheet))
            .union(changedSchematicDrawingArcRefs(from: moveState.originalSheet, to: previewSheet))
            .union(changedSchematicNetTieRefs(from: moveState.originalSheet, to: previewSheet))
            .union(changedSchematicBusRipperRefs(from: moveState.originalSheet, to: previewSheet))
        let selectablesByRef = schematicMovePreviewSelectablesByRef(
            previewSheet: previewSheet,
            shapeChangedRefs: shapeChangedRefs
        )
        let selectedOuterColor = HorizontalMetalRGBA(theme.selectableOuter.opacity(0.95))
        let selectedInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.62))
        let selectedHandleInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.82))
        let hoverOuterColor = HorizontalMetalRGBA(theme.selectablePrelight.opacity(0.78))
        let hoverInnerColor = HorizontalMetalRGBA(theme.selectableInner.opacity(0.38))
        let style = HorizontalCanvasSelectionOverlayStyle(
            selectedOuterColor: selectedOuterColor,
            selectedInnerColor: selectedInnerColor,
            selectedHandleInnerColor: selectedHandleInnerColor,
            hoverOuterColor: hoverOuterColor,
            hoverInnerColor: hoverInnerColor,
            handleShape: appearanceSettings.canvasSelectionHandleShape
        )
        let overlay = schematicMetalSelectionOverlay(
            selectablesByRef: selectablesByRef,
            selectedRefs: selectedObjects,
            hoveredRef: nil,
            style: style,
            selectionSheet: previewSheet
        )
        guard overlay.lines.count == baseSelectionBatch.lines.count,
              overlay.handles.count == baseSelectionBatch.handles.count else {
            return .empty
        }

        var patches = HorizontalMetalBufferPatches()
        if !overlay.lines.isEmpty {
            patches.linePatches.append(
                HorizontalMetalLineBufferPatch(
                    compositeGroup: 0,
                    start: lineStart,
                    primitives: overlay.lines
                )
            )
        }
        if !overlay.handles.isEmpty {
            patches.handlePatches.append(
                HorizontalMetalHandleBufferPatch(
                    start: handleStart,
                    primitives: overlay.handles
                )
            )
        }
        return patches
    }

    private func schematicMetalSelectionOverlay(
        selectablesByRef: [HorizontalSelectableRef: [HorizontalSelectable]],
        selectedRefs: [HorizontalSelectableRef],
        hoveredRef: HorizontalSelectableRef?,
        style: HorizontalCanvasSelectionOverlayStyle,
        selectionSheet: HorizontalSchematicSheet
    ) -> HorizontalCanvasMetalSelectionOverlay {
        HorizontalCanvasModeSupport.metalSelectionOverlay(
            selectablesForRef: { ref in
                selectablesByRef[ref].map { Array($0.prefix(1)) } ?? []
            },
            selectedRefs: selectedRefs,
            hoveredRef: hoveredRef,
            style: style,
            outlineForSelectable: { selectable in
                guard selectable.ref.type == .drawingArc,
                      let arc = selectionSheet.drawingArcs.first(where: { normalizedID($0.id) == normalizedID(selectable.ref.id) }) else {
                    return nil
                }
                return HorizontalCanvasSelectionOutline(
                    points: arc.polyline(precision: 48),
                    closesPath: false,
                    normalOffset: 0,
                    handlePoints: [arc.from, arc.to, arc.center]
                )
            }
        )
    }

    private func schematicMovePreviewSelectablesByRef(
        previewSheet: HorizontalSchematicSheet,
        shapeChangedRefs: Set<HorizontalSelectableRef>
    ) -> [HorizontalSelectableRef: [HorizontalSelectable]] {
        let baseSelectablesByRef = schematicSelectablesByRef()
        var result = [HorizontalSelectableRef: [HorizontalSelectable]]()
        for ref in HorizontalCanvasModeSupport.uniqueRefs(selectedObjects) {
            if shapeChangedRefs.contains(ref),
               let selectable = schematicSelectable(for: ref, in: previewSheet) {
                result[ref] = [selectable]
                continue
            }
            if let delta = movedSchematicRefDelta(ref: ref, from: moveState?.originalSheet ?? sheet, to: previewSheet),
               let baseSelectables = baseSelectablesByRef[ref] {
                result[ref] = baseSelectables.map { translated($0, by: delta) }
                continue
            }
            if let selectable = schematicSelectable(for: ref, in: previewSheet) {
                result[ref] = [selectable]
            }
        }
        return result
    }

    private func schematicMetalPreviewBatch() -> SchematicMetalLineBatch {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported else {
            return .empty
        }

        var lines = [HorizontalMetalLinePrimitive]()

        func appendSegment(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
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
                color: HorizontalMetalRGBA(theme.pin.opacity(opacity))
            )
        }

        func appendArc(_ arc: HorizontalArc, opacity: Double = 0.82) {
            let color = HorizontalMetalRGBA(theme.pin.opacity(opacity))
            let points = arc.polyline(precision: 48)
            for pair in zip(points, points.dropFirst()) {
                appendSegment(from: pair.0, to: pair.1, color: color)
            }
        }

        if let state = drawNetLineState,
           let anchor = state.anchor,
           let cursor = state.cursor,
           pointKey(anchor) != pointKey(cursor) {
            let color = HorizontalMetalRGBA(theme.net.opacity(0.82))
            let points = drawNetLinePath(from: anchor, to: cursor, bendMode: state.bendMode)
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
                rectanglePlacementMode: state.rectanglePlacementMode
            )
            for segment in result.lines {
                appendSegment(segment)
            }
            for arc in result.arcs {
                appendArc(arc)
            }

            if state.primitive == .arc, let center = state.points.first, let cursor = state.cursor {
                appendSegment(
                    HorizontalSegment(id: "arc-radius-preview", from: center, to: cursor, width: 0, layer: nil),
                    opacity: 0.35
                )
            }
        }

        guard !lines.isEmpty else {
            return .empty
        }
        let key = lines.hashValue
        return SchematicMetalLineBatch(
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

    private func buildSchematicSelectables() -> [HorizontalSelectable] {
        var selectables = [HorizontalSelectable]()

        if displayOptions.nets {
            selectables.append(contentsOf: segmentSelectables(sheet.netLines, type: .lineNet))
        }

        if displayOptions.netTies {
            selectables.append(contentsOf: sheet.netTies.map { tie in
                HorizontalSelectable.bounds(
                    ref: HorizontalSelectableRef(id: tie.id, type: .schematicNetTie),
                    points: tie.points,
                    fallbackCenter: (tie.from + tie.to) * 0.5,
                    fallbackSize: 1_000_000
                )
            })
        }

        if displayOptions.buses {
            selectables.append(contentsOf: busLabelSelectables())
            selectables.append(contentsOf: groupedSchematicSelectables(
                type: .busRipper,
                segments: sheet.busRipperLines,
                texts: sheet.busRipperTexts,
                separators: ["line", "text"]
            ))
        }

        if displayOptions.blockSymbols {
            selectables.append(contentsOf: groupedSchematicSelectables(
                type: .schematicBlockSymbol,
                segments: sheet.blockSymbolLines,
                texts: sheet.blockSymbolTexts,
                separators: ["line", "port", "text"]
            ))
            selectables.append(contentsOf: segmentSelectables(sheet.blockSymbolPorts, type: .blockSymbolPort))
        }

        if displayOptions.power {
            selectables.append(contentsOf: powerSymbolSelectables(in: sheet))
        }

        if displayOptions.symbols {
            if editorProfile.supportsPins {
                selectables.append(contentsOf: editorPinSelectables())
            } else {
                selectables.append(contentsOf: schematicSymbolSelectables())
            }
        }

        if displayOptions.junctions, !editorProfile.isPoolMode || showsEditorJunctions {
            selectables.append(contentsOf: junctionSelectables())
        }

        if displayOptions.netLabels {
            selectables.append(contentsOf: netLabelSelectables())
        }

        if displayOptions.drawing {
            selectables.append(contentsOf: segmentSelectables(sheet.drawingLines, type: .drawingLine))
            selectables.append(contentsOf: arcSelectables(sheet.drawingArcs, type: .drawingArc))
            if editorProfile.isPoolMode {
                selectables.append(contentsOf: drawingPolygonSelectables())
            }
        }

        if displayOptions.text {
            selectables.append(contentsOf: textSelectables(sheet.texts, type: .text))
        }

        return selectables
    }

    private func schematicSnapTargets() -> [HorizontalPoint] {
        if let moveSnapTargets = moveState?.snapTargets {
            return moveSnapTargets
        }
        return schematicSnapTargets(excluding: [])
    }

    private func schematicSnapTargets(excluding refs: [HorizontalSelectableRef]) -> [HorizontalPoint] {
        let targets = selectableCache.snapTargets(key: selectableCacheKey) {
            var seen = Set<String>()
            return (schematicSelectableScene().snapTargets(pointKey: pointKey) + schematicConnectionSnapTargets())
                .filter { seen.insert(pointKey($0)).inserted }
        }

        let excludedTargetKeys = schematicSnapTargetKeysExcludedByActiveInteraction(additionalRefs: refs)
        guard !excludedTargetKeys.isEmpty else {
            return targets
        }

        return targets.filter { !excludedTargetKeys.contains(pointKey($0)) }
    }

    private func schematicSnapTargetKeysExcludedByActiveInteraction(additionalRefs: [HorizontalSelectableRef] = []) -> Set<String> {
        var keys = Set<String>()

        if let placedSymbolID = placePartState?.symbolID {
            keys.formUnion(schematicSymbolSnapTargetKeys(symbolID: placedSymbolID))
        }

        if moveState != nil {
            keys.formUnion(schematicSnapTargetKeys(for: selectedObjects))
        }
        if !additionalRefs.isEmpty {
            keys.formUnion(schematicSnapTargetKeys(for: additionalRefs))
        }

        return keys
    }

    private func schematicSnapTargetKeys(for refs: [HorizontalSelectableRef]) -> Set<String> {
        let refSet = Set(refs)
        guard !refSet.isEmpty else {
            return []
        }

        var keys = Set<String>()
        var points = [HorizontalPoint]()
        points.append(contentsOf: schematicSelectables()
            .filter { refSet.contains($0.ref) }
            .flatMap(\.snapPoints))

        for ref in refSet {
            switch ref.type {
            case .schematicSymbol:
                keys.formUnion(schematicSymbolSnapTargetKeys(symbolID: ref.id))
            case .lineNet, .drawingLine, .drawingArc, .junction, .netLabel, .busLabel, .powerSymbol, .schematicNetTie, .text:
                points.append(contentsOf: selectionAnchorPoints(for: ref))
            case .busRipper:
                points.append(contentsOf: busRipperConnectionPoints(ripperID: ref.id, sheet: sheet))
            case .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .schematicBlockSymbol, .symbolPin, .track, .via:
                break
            }
        }

        keys.formUnion(points.map(pointKey))
        return keys
    }

    private func snapSchematicPointToGrid(_ point: HorizontalPoint) -> HorizontalPoint {
        snapPointToGrid(point, grid: sheet.grid, divisor: 1)
    }

    private func snapPointToGrid(_ point: HorizontalPoint, grid: HorizontalGridSettings, divisor: Int) -> HorizontalPoint {
        let safeDivisor = max(divisor, 1)
        let originX = Int64(grid.origin.x)
        let originY = Int64(grid.origin.y)
        let spacingX = max(Int64(grid.spacing.x) / Int64(safeDivisor), 1)
        let spacingY = max(Int64(grid.spacing.y) / Int64(safeDivisor), 1)
        let x = roundGridMultiple(Int64(point.x) - originX, spacingX) + originX
        let y = roundGridMultiple(Int64(point.y) - originY, spacingY) + originY
        return HorizontalPoint(x: Double(x), y: Double(y))
    }

    private func roundGridMultiple(_ value: Int64, _ multiple: Int64) -> Int64 {
        let sign: Int64
        if value > 0 {
            sign = 1
        } else if value < 0 {
            sign = -1
        } else {
            sign = 0
        }

        return ((value + sign * multiple / 2) / multiple) * multiple
    }

    private func schematicSymbolSnapTargetKeys(symbolID: String) -> Set<String> {
        let normalizedSymbolID = normalizedID(symbolID)
        var points = [HorizontalPoint]()

        points.append(contentsOf: schematicSymbolSelectables()
            .filter { normalizedID($0.ref.id) == normalizedSymbolID }
            .flatMap(\.snapPoints))

        func belongsToSymbol(_ geometryID: String) -> Bool {
            self.symbolID(forGeometryID: geometryID).map(normalizedID) == normalizedSymbolID
        }

        for pin in sheet.symbolPins where belongsToSymbol(pin.id) {
            points.append(contentsOf: [pin.from, pin.to])
        }
        for circle in sheet.symbolPinCircles where belongsToSymbol(circle.id) {
            points.append(circle.center)
        }

        return Set(points.map(pointKey))
    }

    private func schematicConnectionSnapTargets() -> [HorizontalPoint] {
        sheet.netLines.flatMap { [$0.from, $0.to] }
            + sheet.drawingArcs.flatMap { [$0.from, $0.to, $0.center] }
            + sheet.symbolPins.flatMap { [$0.from, $0.to] }
            + sheet.symbolPinCircles.map(\.center)
            + sheet.blockSymbolPorts.flatMap { [$0.from, $0.to] }
            + sheet.busRipperLines.flatMap { [$0.from, $0.to] }
            + sheet.powerSymbolLines.flatMap { [$0.from, $0.to] }
            + sheet.powerSymbolCircles.map(\.center)
    }

    private func segmentSelectables(_ segments: [HorizontalSegment], type: HorizontalObjectType) -> [HorizontalSelectable] {
        HorizontalCanvasModeSupport.segmentSelectables(segments, type: type)
    }

    private func segmentSelectable(for ref: HorizontalSelectableRef, in segments: [HorizontalSegment]) -> HorizontalSelectable? {
        HorizontalCanvasModeSupport.segmentSelectable(for: ref, in: segments)
    }

    private func arcSelectables(_ arcs: [HorizontalArc], type: HorizontalObjectType) -> [HorizontalSelectable] {
        HorizontalCanvasModeSupport.arcSelectables(arcs, type: type)
    }

    private func symbolPinSelectables() -> [HorizontalSelectable] {
        var selectables = segmentSelectables(sheet.symbolPins, type: .symbolPin)
        selectables.append(contentsOf: sheet.symbolPinCircles.map { circle in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: circle.id, type: .symbolPin, layer: circle.layer),
                points: circleBounds(circle),
                fallbackCenter: circle.center,
                fallbackSize: circle.radius * 2
            )
        })
        return selectables
    }

    private func junctionSelectables() -> [HorizontalSelectable] {
        var seen = Set<String>()
        return sheet.junctions.compactMap { id, point in
            guard seen.insert(pointKey(point)).inserted else {
                return nil
            }
            return HorizontalSelectable.point(ref: HorizontalSelectableRef(id: id, type: .junction), at: point)
        }
    }

    private func netLabelSelectables() -> [HorizontalSelectable] {
        sheet.netLabels.map { label in
            let points = netLabelBoundsPoints(for: label)
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: label.id, type: .netLabel),
                points: points,
                fallbackCenter: label.position,
                fallbackSize: label.size * 2
            )
        }
    }

    private func busLabelSelectables() -> [HorizontalSelectable] {
        sheet.busLabels.map { label in
            let points = busLabelBoundsPoints(for: label)
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: label.id, type: .busLabel),
                points: points,
                fallbackCenter: label.position,
                fallbackSize: label.size * 2
            )
        }
    }

    private func textSelectables(_ texts: [HorizontalText], type: HorizontalObjectType) -> [HorizontalSelectable] {
        HorizontalCanvasModeSupport.textSelectables(texts, type: type)
    }

    private func groupedSchematicSelectables(
        type: HorizontalObjectType,
        segments: [HorizontalSegment] = [],
        circles: [HorizontalCircle] = [],
        texts: [HorizontalText] = [],
        separators: Set<String>
    ) -> [HorizontalSelectable] {
        var pointsByObject = [String: [HorizontalPoint]]()

        func append(id: String, points: [HorizontalPoint]) {
            let objectID = objectIDPrefix(in: id, separators: separators)
                ?? normalizedID(id).split(separator: "/").first.map(String.init)
                ?? id
            pointsByObject[objectID, default: []].append(contentsOf: points)
        }

        for segment in segments {
            append(id: segment.id, points: [segment.from, segment.to])
        }
        for circle in circles {
            append(id: circle.id, points: circleBounds(circle))
        }
        for text in texts {
            append(id: text.id, points: text.renderBoundsPoints)
        }

        return pointsByObject.map { id, points in
            let fallbackCenter: HorizontalPoint
            if type == .powerSymbol,
               let anchor = powerSymbolAnchorPoints(symbolID: id, sheet: sheet).first {
                fallbackCenter = anchor
            } else {
                fallbackCenter = HorizontalRect(points: points).center
            }
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: id, type: type),
                points: points,
                fallbackCenter: fallbackCenter,
                fallbackSize: 1_000_000
            )
        }
    }

    private func drawGrid(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        HorizontalGridRenderer.drawCrossGrid(
            context: context,
            transform: transform,
            baseSpacing: sheet.grid.spacing,
            origin: sheet.grid.origin,
            color: theme.grid,
            lineWidth: appearanceSettings.gridMarkLineWidth
        )
    }

    private func drawSelection(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        var drawnRefs = Set<HorizontalSelectableRef>()
        for selectable in schematicSelectables() {
            let isSelected = selectedObjects.contains(selectable.ref)
            let isHovered = selectable.ref == hoveredObject
            guard isSelected || isHovered else {
                continue
            }
            guard drawnRefs.insert(selectable.ref).inserted else {
                continue
            }

            if selectable.ref.type == .drawingArc,
               let arc = sheet.drawingArcs.first(where: { normalizedID($0.id) == normalizedID(selectable.ref.id) }) {
                drawArcSelectable(arc, selected: isSelected, context: context, transform: transform)
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
        var drawnRefs = Set<HorizontalSelectableRef>()
        for selectable in schematicSelectables() where selectedObjects.contains(selectable.ref) {
            guard drawnRefs.insert(selectable.ref).inserted else {
                continue
            }

            let outerColor = theme.selectableOuter
            if selectable.ref.type == .drawingArc,
               let arc = sheet.drawingArcs.first(where: { normalizedID($0.id) == normalizedID(selectable.ref.id) }) {
                drawSelectionHandle(at: arc.from, color: outerColor, context: context, transform: transform)
                drawSelectionHandle(at: arc.to, color: outerColor, context: context, transform: transform)
                drawSelectionHandle(at: arc.center, color: outerColor, context: context, transform: transform)
            } else {
                for point in HorizontalCanvasModeSupport.selectionHandlePoints(for: selectable) {
                    drawSelectionHandle(at: point, color: outerColor, context: context, transform: transform)
                }
            }
        }
    }

    private func drawNetLinePreview(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard let state = drawNetLineState,
              let anchor = state.anchor,
              let cursor = state.cursor,
              pointKey(anchor) != pointKey(cursor) else {
            return
        }

        let points = drawNetLinePath(from: anchor, to: cursor, bendMode: state.bendMode)
        var path = Path()
        path.move(to: transform.point(points[0]))
        for point in points.dropFirst() {
            path.addLine(to: transform.point(point))
        }
        context.stroke(
            path,
            with: .color(theme.net.opacity(0.82)),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(0, minimum: 1.6),
                lineCap: .round,
                lineJoin: .round,
                dash: [5, 4]
            )
        )
    }

    private func drawGraphicsPreview(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard let state = drawGraphicsState else {
            return
        }

        var points = state.points
        if let cursor = state.cursor {
            if points.isEmpty || pointKey(points.last ?? cursor) != pointKey(cursor) {
                points.append(cursor)
            }
        }

        let result = previewGraphicsResult(
            for: state.primitive,
            points: points,
            rectanglePlacementMode: state.rectanglePlacementMode
        )
        for segment in result.lines {
            drawPreviewSegment(segment, context: context, transform: transform)
        }
        for arc in result.arcs {
            drawPreviewArc(arc, context: context, transform: transform)
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
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner
    ) -> DrawGraphicsResult {
        HorizontalCanvasModeSupport.previewGraphicsResult(
            for: primitive,
            points: points,
            rectanglePlacementMode: rectanglePlacementMode,
            pointKey: pointKey,
            makeSegment: { drawingSegment(from: $0, to: $1) },
            makeArc: { drawingArc(from: $0, to: $1, center: $2) },
            finalizedResult: { graphicsResult(for: $0, points: $1, rectanglePlacementMode: $2) }
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
            with: .color(theme.pin.opacity(opacity)),
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
        drawArc(arc, transform: transform, context: context, color: theme.pin.opacity(opacity), minimumWidth: 1.6)
    }

    private func drawNetHighlight(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard !highlightedNetIDs.isEmpty else {
            return
        }

        let color = theme.junction
        let pinColor = theme.pin

        for segment in sheet.netLines where matchesHighlightedNet(segment.netID) {
            drawSegment(segment, transform: transform, context: context, color: color.opacity(0.95), minimumWidth: 3.2)
        }

        for tie in sheet.netTies where matchesHighlightedNet(tie.netIDs) {
            drawNetTie(tie, transform: transform, context: context, color: color.opacity(0.92))
        }

        for segment in sheet.symbolPins where matchesHighlightedNet(segment.netID) {
            drawSegment(segment, transform: transform, context: context, color: symbolPinSegmentColor(for: segment), minimumWidth: 2.4)
        }

        for circle in sheet.symbolPinCircles where matchesHighlightedNet(circle.netID) {
            drawCircle(circle, transform: transform, context: context, color: pinColor.opacity(0.64), minimumWidth: 2.2)
        }

        for segment in sheet.blockSymbolPorts where matchesHighlightedNet(segment.netID) {
            drawSegment(segment, transform: transform, context: context, color: blockSymbolPortSegmentColor(for: segment), minimumWidth: 2.4)
        }

        for segment in sheet.busRipperLines where matchesHighlightedNet(segment.netID) {
            drawSegment(segment, transform: transform, context: context, color: color.opacity(0.9), minimumWidth: 2.6)
        }

        for text in sheet.busRipperTexts where matchesHighlightedNet(text.netID) {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: color.opacity(0.9),
                context: context,
                transform: transform,
                minimumLineWidth: 1.1
            )
        }

        for label in sheet.netLabels where matchesHighlightedNet(label.netID) {
            drawNetLabel(label, transform: transform, context: context, color: color.opacity(0.96))
        }

        for (junctionID, junction) in sheet.junctions where matchesHighlightedNet(netID(forJunctionID: junctionID)) {
            drawHighlightedJunction(junction, context: context, transform: transform, color: color)
        }

        for line in sheet.powerSymbolLines where matchesHighlightedNet(line.netID) {
            drawSegment(line, transform: transform, context: context, color: pinColor.opacity(0.78), minimumWidth: 2.4)
        }

        for circle in sheet.powerSymbolCircles where matchesHighlightedNet(circle.netID) {
            drawCircle(circle, transform: transform, context: context, color: pinColor.opacity(0.64), minimumWidth: 2.2)
        }

        for text in sheet.powerSymbolTexts where matchesHighlightedNet(text.netID) {
            HorizontalOutlineTextRenderer.draw(
                text,
                color: pinColor.opacity(0.86),
                context: context,
                transform: transform,
                minimumLineWidth: 1.1
            )
        }
    }

    private func drawComponentHighlight(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        guard !highlightedComponentIDs.isEmpty,
              displayOptions.symbols else {
            return
        }

        let color = theme.junction
        for selectable in schematicSymbolSelectables() {
            guard let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(selectable.ref.id) }),
                  matchesHighlightedComponent(symbol.componentID) else {
                continue
            }
            let path = selectablePath(selectable, transform: transform)
            context.fill(path, with: .color(color.opacity(0.08)))
            context.stroke(
                path,
                with: .color(color.opacity(0.95)),
                style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)
            )
        }
    }

    private func dimDesignForNetHighlight(context: GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(theme.background.opacity(0.54))
        )
    }

    private func drawNoPopulateMark(
        _ mark: HorizontalSchematicNoPopulateMark,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext
    ) {
        let color = theme.noPopulate.opacity(0.95)
        drawSegment(mark.firstLine, transform: transform, context: context, color: color, minimumWidth: 1.6)
        drawSegment(mark.secondLine, transform: transform, context: context, color: color, minimumWidth: 1.6)
    }

    private func matchesHighlightedNet(_ netID: String?) -> Bool {
        guard let netID else {
            return false
        }
        return highlightedNetIDs.contains(normalizedID(netID))
    }

    private func matchesHighlightedNet(_ netIDs: Set<String>) -> Bool {
        netIDs.contains { matchesHighlightedNet($0) }
    }

    private func matchesHighlightedComponent(_ componentID: String?) -> Bool {
        guard let componentID else {
            return false
        }
        return highlightedComponentIDs.contains(normalizedID(componentID))
    }

    private func drawHighlightedJunction(
        _ junction: HorizontalPoint,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        color: Color
    ) {
        let point = transform.point(junction)
        let radius = max(
            junctionDotRadius(transform: transform) + transform.length(Self.junctionHighlightPaddingWorld),
            Self.minimumJunctionDotRadius
        )
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.5)))
        context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.98)), lineWidth: transform.strokeWidth(0, minimum: 1.2))
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

    private func drawArcSelectable(
        _ arc: HorizontalArc,
        selected: Bool,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform
    ) {
        let outerColor = selected ? theme.selectableOuter : theme.selectablePrelight
        var path = Path()
        let points = arc.polyline(precision: 48)
        if let first = points.first {
            path.move(to: transform.point(first))
            for point in points.dropFirst() {
                path.addLine(to: transform.point(point))
            }
        }

        context.stroke(
            path,
            with: .color(outerColor.opacity(selected ? 0.95 : 0.78)),
            style: StrokeStyle(lineWidth: selected ? 2.4 : 1.8, lineCap: .round, lineJoin: .round, dash: [5, 4])
        )

        if selected {
            drawSelectionHandle(at: arc.from, color: outerColor, context: context, transform: transform)
            drawSelectionHandle(at: arc.to, color: outerColor, context: context, transform: transform)
            drawSelectionHandle(at: arc.center, color: outerColor, context: context, transform: transform)
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

    private func schematicSymbolSelectables() -> [HorizontalSelectable] {
        let pointsBySymbol = schematicSymbolGeometryPoints()
        return sheet.symbols.map { symbol in
            let symbolPoints = pointsBySymbol[normalizedID(symbol.id)] ?? []
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol),
                points: symbolPoints,
                fallbackCenter: symbol.position,
                fallbackSize: 2_540_000
            )
        }
    }

    private func schematicSelectable(for ref: HorizontalSelectableRef) -> HorizontalSelectable? {
        schematicSelectable(for: ref, in: sheet)
    }

    private func schematicSelectable(
        for ref: HorizontalSelectableRef,
        in sheet: HorizontalSchematicSheet
    ) -> HorizontalSelectable? {
        if editorProfile.isPoolMode, let selectable = poolEditorSelectable(for: ref, in: sheet) {
            return selectable
        }
        switch ref.type {
        case .schematicSymbol:
            guard let symbol = sheet.symbols.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol),
                points: schematicSymbolGeometryPoints(symbolID: symbol.id, in: sheet),
                fallbackCenter: symbol.position,
                fallbackSize: 2_540_000
            )
        case .lineNet:
            return segmentSelectable(for: ref, in: sheet.netLines)
        case .drawingLine:
            return segmentSelectable(for: ref, in: sheet.drawingLines)
        case .text:
            guard let text = sheet.texts.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return HorizontalSelectable.point(ref: ref, at: text.position)
        case .junction:
            guard let junction = sheet.junctions.first(where: { normalizedID($0.key) == normalizedID(ref.id) }) else {
                return nil
            }
            return HorizontalSelectable.point(ref: ref, at: junction.value)
        case .netLabel:
            guard let label = sheet.netLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return HorizontalSelectable.point(ref: ref, at: label.position)
        case .busLabel:
            guard let label = sheet.busLabels.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return HorizontalSelectable.point(ref: ref, at: label.position)
        case .schematicNetTie:
            guard let tie = sheet.netTies.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            return HorizontalSelectable.bounds(
                ref: ref,
                points: tie.points,
                fallbackCenter: (tie.from + tie.to) * 0.5,
                fallbackSize: 1_000_000
            )
        case .drawingArc:
            guard let arc = sheet.drawingArcs.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
                return nil
            }
            let points = arc.polyline(precision: 24)
            return HorizontalSelectable.bounds(
                ref: ref,
                points: points,
                fallbackCenter: arc.center,
                fallbackSize: max(arc.radius * 2, 1_000_000)
            )
        case .powerSymbol:
            return powerSymbolSelectable(symbolID: ref.id, in: sheet)
        case .schematicBlockSymbol, .busRipper, .blockSymbolPort, .boardPackage, .boardDecal, .boardHole, .boardArc, .boardLine, .boardNetTie, .boardPanel, .connectionLine, .dimension, .keepout, .pad, .padstackShape, .plane, .polygonArcCenter, .polygonEdge, .polygonVertex, .symbolPin, .track, .via:
            return nil
        }
    }

    private func powerSymbolSelectables(in sheet: HorizontalSchematicSheet) -> [HorizontalSelectable] {
        powerSymbolIDs(in: sheet).compactMap { powerSymbolSelectable(symbolID: $0, in: sheet) }
    }

    private func powerSymbolSelectable(symbolID: String, in sheet: HorizontalSchematicSheet) -> HorizontalSelectable? {
        let points = powerSymbolShapePoints(symbolID: symbolID, sheet: sheet)
        guard !points.isEmpty else {
            return nil
        }
        let fallbackCenter = powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet).first
            ?? HorizontalRect(points: points).center
        return HorizontalSelectable.bounds(
            ref: HorizontalSelectableRef(id: symbolID, type: .powerSymbol),
            points: points,
            fallbackCenter: fallbackCenter,
            fallbackSize: 1_000_000
        )
    }

    private func schematicSymbolGeometryPoints() -> [String: [HorizontalPoint]] {
        var pointsBySymbol = [String: [HorizontalPoint]]()

        func append(id: String, points: [HorizontalPoint]) {
            guard let symbolID = symbolID(forGeometryID: id) else {
                return
            }
            pointsBySymbol[symbolID, default: []].append(contentsOf: points)
        }

        for polygon in sheet.symbolPolygons {
            append(id: polygon.id, points: polygon.vertices)
        }
        for line in sheet.symbolLines {
            append(id: line.id, points: [line.from, line.to])
        }
        for pin in sheet.symbolPins {
            append(id: pin.id, points: [pin.from, pin.to])
        }
        for circle in sheet.symbolPinCircles {
            append(id: circle.id, points: circleBounds(circle))
        }

        return pointsBySymbol
    }

    private func schematicSymbolGeometryPoints(symbolID: String) -> [HorizontalPoint] {
        schematicSymbolGeometryPoints(symbolID: symbolID, in: sheet)
    }

    private func schematicSymbolGeometryPoints(
        symbolID: String,
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalPoint] {
        let normalizedSymbolID = normalizedID(symbolID)
        var points = [HorizontalPoint]()

        func belongsToSymbol(_ geometryID: String) -> Bool {
            geometryIDHasOwnerPrefix(geometryID, ownerID: normalizedSymbolID)
        }

        for polygon in sheet.symbolPolygons where belongsToSymbol(polygon.id) {
            points.append(contentsOf: polygon.vertices)
        }
        for line in sheet.symbolLines where belongsToSymbol(line.id) {
            points.append(contentsOf: [line.from, line.to])
        }
        for pin in sheet.symbolPins where belongsToSymbol(pin.id) {
            points.append(contentsOf: [pin.from, pin.to])
        }
        for circle in sheet.symbolPinCircles where belongsToSymbol(circle.id) {
            points.append(contentsOf: circleBounds(circle))
        }

        return points
    }

    private func symbolID(forGeometryID geometryID: String) -> String? {
        schematicMetalSymbolID(forGeometryID: geometryID)
    }

    private func pinID(forSymbolPinGeometryID geometryID: String) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        let separators = HorizontalSchematicSheet.editorPinSeparators
        guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }) else {
            return nil
        }
        let pinIndex = components.index(after: separatorIndex)
        guard pinIndex < components.endIndex else {
            return nil
        }
        return components[pinIndex]
    }

    private func circleBounds(_ circle: HorizontalCircle) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius),
            HorizontalPoint(x: circle.center.x + circle.radius, y: circle.center.y + circle.radius)
        ]
    }

    private func schematicOriginText(_ label: String, at position: HorizontalPoint) -> HorizontalText {
        HorizontalText(
            id: "schematic-origin-\(label)",
            text: label,
            position: position,
            size: 1_000_000,
            layer: nil,
            origin: .center,
            centered: true
        )
    }

    private func drawSymbolPlaceholders(context: GraphicsContext, transform: HorizontalCanvasTransform) {
        for symbol in sheet.symbols {
            let center = transform.point(symbol.position)
            let rect = CGRect(x: center.x - 12, y: center.y - 8, width: 24, height: 16)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(theme.symbolBoundingBox.opacity(0.22)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(theme.symbolBoundingBox.opacity(0.8)), lineWidth: transform.strokeWidth(0, minimum: 1))
        }
    }

    private func symbolPinSegmentColor(for segment: HorizontalSegment) -> Color {
        if isPinAnnotationSegmentID(segment.id) {
            return theme.pinAnnotation.opacity(0.86)
        }
        return theme.pin.opacity(0.64)
    }

    private func blockSymbolPortSegmentColor(for segment: HorizontalSegment) -> Color {
        if isBlockSymbolPortAnnotationSegmentID(segment.id) {
            return theme.pinAnnotation.opacity(0.86)
        }
        return theme.pin.opacity(0.64)
    }

    private func isPinAnnotationTextID(_ id: String) -> Bool {
        id.contains("/pin-name/")
            || id.contains("/pin-pad/")
            || id.contains("/pin-connector-text/")
            || isHiddenPinTextID(id)
    }

    /// The symbol editor's greyed name / pad texts of pins that hide them.
    private func isHiddenPinTextID(_ id: String) -> Bool {
        id.contains("/pin-name-hidden/") || id.contains("/pin-pad-hidden/")
    }

    private func isBlockSymbolPortAnnotationTextID(_ id: String) -> Bool {
        id.contains("/block-port-name/")
            || id.contains("/block-port-connector-text/")
    }

    private func isPinAnnotationSegmentID(_ id: String) -> Bool {
        id.contains("/pin-direction/")
            || (id.contains("/pin-connector/") && id.contains("/nc/"))
    }

    private func isBlockSymbolPortAnnotationSegmentID(_ id: String) -> Bool {
        id.contains("/block-port-direction/")
            || (id.contains("/block-port-connector/") && id.contains("/nc/"))
    }

    private func junctionDotRadius(transform: HorizontalCanvasTransform) -> CGFloat {
        max(transform.length(Self.junctionDotRadiusWorld), Self.minimumJunctionDotRadius)
    }

    private func junctionRenderInfo(isolatedNetLineIDs: Set<String>) -> [String: JunctionRenderInfo] {
        var infoByKey: [String: JunctionRenderInfo] = [:]

        func update(
            _ point: HorizontalPoint,
            connectionCount: Int = 0,
            connectionKey: String? = nil,
            isAttachment: Bool = false,
            isIsolated: Bool = false,
            netID: String? = nil
        ) {
            var info = infoByKey[pointKey(point)] ?? JunctionRenderInfo()
            info.addConnections(connectionCount, key: connectionKey)
            info.hasAttachment = info.hasAttachment || isAttachment
            info.isIsolated = info.isIsolated || isIsolated
            if info.netID == nil {
                info.netID = netID
            }
            infoByKey[pointKey(point)] = info
        }

        for segment in sheet.netLines {
            let isIsolated = isolatedNetLineIDs.contains(normalizedID(segment.id)) || segment.netID == nil
            let connectionKey = "net-line:\(normalizedID(segment.id))"
            update(segment.from, connectionCount: 1, connectionKey: connectionKey, isIsolated: isIsolated, netID: segment.netID)
            update(segment.to, connectionCount: 1, connectionKey: connectionKey, isIsolated: isIsolated, netID: segment.netID)
        }

        for symbolID in powerSymbolIDs(in: sheet) {
            for point in powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet) {
                update(
                    point,
                    connectionCount: 1,
                    connectionKey: "power-symbol:\(normalizedID(symbolID))",
                    netID: netID(at: point, in: sheet)
                )
            }
        }

        for pin in sheet.symbolPins where pin.netID != nil {
            update(pin.from, isAttachment: true, netID: pin.netID)
        }

        for circle in sheet.symbolPinCircles where circle.netID != nil {
            update(circle.center, isAttachment: true, netID: circle.netID)
        }

        for port in sheet.blockSymbolPorts where port.netID != nil {
            update(port.from, isAttachment: true, netID: port.netID)
            update(port.to, isAttachment: true, netID: port.netID)
        }

        for tie in sheet.netTies {
            let connectionKey = "net-tie:\(normalizedID(tie.id))"
            update(tie.from, connectionCount: 1, connectionKey: connectionKey, isAttachment: true, netID: tie.netIDs.first)
            update(tie.to, connectionCount: 1, connectionKey: connectionKey, isAttachment: true, netID: tie.netIDs.first)
        }

        for label in sheet.netLabels {
            update(label.position, isAttachment: true, netID: label.netID)
        }

        for label in sheet.busLabels {
            update(label.position, isAttachment: true, netID: label.netID)
        }

        for segment in sheet.busRipperLines {
            update(segment.from, isAttachment: true, netID: segment.netID)
            update(segment.to, isAttachment: true, netID: segment.netID)
        }

        for segment in sheet.drawingLines {
            update(segment.from, isAttachment: true)
            update(segment.to, isAttachment: true)
        }

        for arc in sheet.drawingArcs {
            update(arc.from, isAttachment: true)
            update(arc.to, isAttachment: true)
            update(arc.center, isAttachment: true)
        }

        for (junctionID, point) in sheet.junctions {
            if let netID = netID(forJunctionID: junctionID) {
                update(point, netID: netID)
            }
        }

        return infoByKey
    }

    private func isolatedNetLineIDs() -> Set<String> {
        guard !sheet.netLines.isEmpty else {
            return []
        }

        var parent: [String: String] = [:]
        var endpointCounts: [String: Int] = [:]
        var unresolvedLineIDs = Set<String>()

        func root(_ key: String) -> String {
            if parent[key] == nil {
                parent[key] = key
                return key
            }

            var current = key
            var path: [String] = []
            while let next = parent[current], next != current {
                path.append(current)
                current = next
            }
            for item in path {
                parent[item] = current
            }
            return current
        }

        func union(_ lhs: String, _ rhs: String) {
            let lhsRoot = root(lhs)
            let rhsRoot = root(rhs)
            if lhsRoot != rhsRoot {
                parent[rhsRoot] = lhsRoot
            }
        }

        for line in sheet.netLines {
            let fromKey = pointKey(line.from)
            let toKey = pointKey(line.to)
            union(fromKey, toKey)
            endpointCounts[fromKey, default: 0] += 1
            endpointCounts[toKey, default: 0] += 1
            if line.netID == nil {
                unresolvedLineIDs.insert(normalizedID(line.id))
            }
        }

        var lineIDsByRoot: [String: Set<String>] = [:]
        for line in sheet.netLines {
            lineIDsByRoot[root(pointKey(line.from)), default: []].insert(normalizedID(line.id))
        }

        var attachedRoots = Set<String>()
        func markAttached(_ point: HorizontalPoint) {
            let key = pointKey(point)
            if parent[key] != nil {
                attachedRoots.insert(root(key))
                return
            }

            for line in sheet.netLines where pointLiesOnSegment(point, line) {
                attachedRoots.insert(root(pointKey(line.from)))
            }
        }

        for label in sheet.netLabels {
            markAttached(label.position)
        }
        for segment in sheet.symbolPins {
            markAttached(segment.from)
            markAttached(segment.to)
        }
        for circle in sheet.symbolPinCircles {
            markAttached(circle.center)
        }
        for segment in sheet.blockSymbolPorts {
            markAttached(segment.from)
            markAttached(segment.to)
        }
        for symbolID in powerSymbolIDs(in: sheet) {
            for point in powerSymbolAnchorPoints(symbolID: symbolID, sheet: sheet) {
                markAttached(point)
            }
        }
        for ripperID in busRipperIDs(in: sheet) {
            for point in busRipperConnectionPoints(ripperID: ripperID, sheet: sheet) {
                markAttached(point)
            }
        }
        for tie in sheet.netTies {
            markAttached(tie.from)
            markAttached(tie.to)
        }

        var terminalRoots = Set<String>()
        for (key, count) in endpointCounts where count <= 1 {
            terminalRoots.insert(root(key))
        }

        var isolated = unresolvedLineIDs
        for (componentRoot, lineIDs) in lineIDsByRoot
            where terminalRoots.contains(componentRoot) && !attachedRoots.contains(componentRoot) {
            isolated.formUnion(lineIDs)
        }

        return isolated
    }

    private func drawSegment(
        _ segment: HorizontalSegment,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color,
        minimumWidth: CGFloat
    ) {
        var path = Path()
        path.move(to: transform.point(segment.from))
        path.addLine(to: transform.point(segment.to))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(segment.width, minimum: minimumWidth),
                lineCap: .round,
                lineJoin: .round
            )
        )
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

    private func drawCircle(
        _ circle: HorizontalCircle,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color,
        minimumWidth: CGFloat
    ) {
        let center = transform.point(circle.center)
        let radius = transform.length(circle.radius)
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: transform.strokeWidth(0, minimum: minimumWidth))
    }

    private func drawNetTie(
        _ tie: HorizontalSchematicNetTie,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color
    ) {
        drawNetTieShape(tie, transform: transform, context: context, color: color)
        HorizontalOutlineTextRenderer.draw(
            netTieText(for: tie),
            color: color,
            context: context,
            transform: transform,
            minimumLineWidth: 0.85
        )
    }

    private func drawNetTieShape(
        _ tie: HorizontalSchematicNetTie,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color
    ) {
        let from = tie.from
        let to = tie.to
        let vector = to - from
        let normal = HorizontalPoint(x: vector.y, y: -vector.x).normalized
        let center = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let controlOffset = normal * 1_000_000

        var path = Path()
        path.move(to: transform.point(from))
        path.addQuadCurve(to: transform.point(to), control: transform.point(center + controlOffset))
        path.move(to: transform.point(to))
        path.addQuadCurve(to: transform.point(from), control: transform.point(center - controlOffset))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(0, minimum: 1.0),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func netTieText(for tie: HorizontalSchematicNetTie) -> HorizontalText {
        let from = tie.from
        let to = tie.to
        let vector = to - from
        let normal = HorizontalPoint(x: vector.y, y: -vector.x).normalized
        let center = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        return HorizontalText(
            id: "\(tie.id)/net-tie-label",
            text: tie.label,
            position: center + normal * 1_500_000,
            size: 1_500_000,
            layer: nil,
            angle: angle(from: from, to: to),
            origin: .center,
            centered: true
        )
    }

    private func drawNetLabel(
        _ label: HorizontalSchematicNetLabel,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color,
        fillBackground: Bool = false
    ) {
        let text = netLabelText(for: label)
        guard HorizontalOutlineTextRenderer.shouldDraw(text, transform: transform) else {
            return
        }

        let flagPath = netLabelPath(for: label, text: text, transform: transform)
        if fillBackground {
            context.fill(flagPath, with: .color(theme.background))
            context.fill(flagPath, with: .color(color.opacity(0.08)))
        }
        context.stroke(
            flagPath,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(0, minimum: 1.0),
                lineCap: .round,
                lineJoin: .round
            )
        )
        HorizontalOutlineTextRenderer.draw(
            text,
            color: color,
            context: context,
            transform: transform,
            minimumLineWidth: 0.85
        )
    }

    private func drawNetLabelFill(
        _ label: HorizontalSchematicNetLabel,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color
    ) {
        let text = netLabelText(for: label)
        let flagPath = netLabelPath(for: label, text: text, transform: transform)
        context.fill(flagPath, with: .color(color.opacity(0.08)))
    }

    private func netLabelText(for label: HorizontalSchematicNetLabel) -> HorizontalText {
        HorizontalText(
            id: "\(label.id)/net-label-text",
            text: label.text,
            position: label.position + busLabelTextShift(size: label.size, orientation: label.orientation),
            size: label.size,
            layer: nil,
            angle: angle(forOrientation: label.orientation),
            origin: .center
        )
    }

    private func drawBusLabel(
        _ label: HorizontalBusLabel,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color
    ) {
        let text = busLabelText(for: label)
        guard HorizontalOutlineTextRenderer.shouldDraw(text, transform: transform) else {
            return
        }

        let flagPath = busLabelPath(for: label, text: text, transform: transform)
        context.fill(flagPath, with: .color(color.opacity(0.08)))
        context.stroke(
            flagPath,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(0, minimum: 1.0),
                lineCap: .round,
                lineJoin: .round
            )
        )
        HorizontalOutlineTextRenderer.draw(
            text,
            color: color,
            context: context,
            transform: transform,
            minimumLineWidth: 0.85
        )
    }

    private func drawBusLabelFill(
        _ label: HorizontalBusLabel,
        transform: HorizontalCanvasTransform,
        context: GraphicsContext,
        color: Color
    ) {
        let text = busLabelText(for: label)
        let flagPath = busLabelPath(for: label, text: text, transform: transform)
        context.fill(flagPath, with: .color(color.opacity(0.08)))
    }

    private func busLabelText(for label: HorizontalBusLabel) -> HorizontalText {
        HorizontalText(
            id: "\(label.id)/bus-label-text",
            text: label.text,
            position: label.position + busLabelTextShift(size: label.size, orientation: label.orientation),
            size: label.size,
            layer: nil,
            angle: angle(forOrientation: label.orientation),
            origin: .center
        )
    }

    private func netLabelPath(
        for label: HorizontalSchematicNetLabel,
        text: HorizontalText,
        transform: HorizontalCanvasTransform
    ) -> Path {
        flagPath(points: netLabelOutlinePoints(for: label, text: text), transform: transform)
    }

    private func busLabelPath(
        for label: HorizontalBusLabel,
        text: HorizontalText,
        transform: HorizontalCanvasTransform
    ) -> Path {
        flagPath(points: busLabelOutlinePoints(for: label, text: text), transform: transform)
    }

    private func netLabelOutlinePoints(for label: HorizontalSchematicNetLabel, text: HorizontalText) -> [HorizontalPoint] {
        let (min, max) = labelBounds(for: text)
        return flagOutlinePoints(
            position: label.position,
            min: min,
            max: max,
            orientation: label.orientation
        )
    }

    private func busLabelOutlinePoints(for label: HorizontalBusLabel, text: HorizontalText) -> [HorizontalPoint] {
        let (min, max) = labelBounds(for: text)
        return flagOutlinePoints(
            position: label.position,
            min: min,
            max: max,
            orientation: label.orientation
        )
    }

    private func netLabelBoundsPoints(for label: HorizontalSchematicNetLabel) -> [HorizontalPoint] {
        let text = HorizontalText(
            id: "\(label.id)/net-label-text",
            text: label.text,
            position: label.position + busLabelTextShift(size: label.size, orientation: label.orientation),
            size: label.size,
            layer: nil,
            angle: angle(forOrientation: label.orientation),
            origin: .center
        )
        let (min, max) = labelBounds(for: text)
        return flagBoundsPoints(position: label.position, min: min, max: max)
    }

    private func busLabelBoundsPoints(for label: HorizontalBusLabel) -> [HorizontalPoint] {
        let text = HorizontalText(
            id: "\(label.id)/bus-label-text",
            text: label.text,
            position: label.position + busLabelTextShift(size: label.size, orientation: label.orientation),
            size: label.size,
            layer: nil,
            angle: angle(forOrientation: label.orientation),
            origin: .center
        )
        let (min, max) = labelBounds(for: text)
        return flagBoundsPoints(position: label.position, min: min, max: max)
    }

    private func flagBoundsPoints(position: HorizontalPoint, min: HorizontalPoint, max: HorizontalPoint) -> [HorizontalPoint] {
        [
            position,
            min,
            max,
            HorizontalPoint(x: min.x, y: max.y),
            HorizontalPoint(x: max.x, y: min.y)
        ]
    }

    private func flagOutlinePoints(
        position: HorizontalPoint,
        min: HorizontalPoint,
        max: HorizontalPoint,
        orientation: String
    ) -> [HorizontalPoint] {
        let topLeft = HorizontalPoint(x: min.x, y: max.y)
        let bottomRight = HorizontalPoint(x: max.x, y: min.y)

        switch orientation {
        case "left":
            return [min, topLeft, max, position, bottomRight]
        case "up":
            return [position, min, topLeft, max, bottomRight]
        case "down":
            return [position, max, bottomRight, min, topLeft]
        default:
            return [max, bottomRight, min, position, topLeft]
        }
    }

    private func flagPath(points: [HorizontalPoint], transform: HorizontalCanvasTransform) -> Path {
        var path = Path()
        guard let first = points.first else {
            return path
        }

        path.move(to: transform.point(first))
        for point in points.dropFirst() {
            path.addLine(to: transform.point(point))
        }
        path.closeSubpath()
        return path
    }

    private func labelBounds(for text: HorizontalText) -> (HorizontalPoint, HorizontalPoint) {
        let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
        let points = [text.position] + segments.flatMap { [$0.0, $0.1] }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let enlarge = text.size / 4
        return (
            HorizontalPoint(
                x: (xs.min() ?? text.position.x) - enlarge,
                y: (ys.min() ?? text.position.y) - enlarge
            ),
            HorizontalPoint(
                x: (xs.max() ?? text.position.x) + enlarge,
                y: (ys.max() ?? text.position.y) + enlarge
            )
        )
    }

    private func busLabelTextShift(size: Double, orientation: String) -> HorizontalPoint {
        switch orientation {
        case "left":
            return HorizontalPoint(x: -size, y: 0)
        case "up":
            return HorizontalPoint(x: 0, y: size)
        case "down":
            return HorizontalPoint(x: 0, y: -size)
        default:
            return HorizontalPoint(x: size, y: 0)
        }
    }

    private func angle(forOrientation orientation: String) -> Int {
        switch orientation {
        case "left":
            return 32_768
        case "up":
            return 16_384
        case "down":
            return 49_152
        default:
            return 0
        }
    }

    private func rotate(_ point: HorizontalPoint, angle: Int) -> HorizontalPoint {
        switch angle {
        case 16_384:
            return HorizontalPoint(x: -point.y, y: point.x)
        case 32_768:
            return HorizontalPoint(x: -point.x, y: -point.y)
        case 49_152:
            return HorizontalPoint(x: point.y, y: -point.x)
        default:
            return point
        }
    }

    private func angle(from: HorizontalPoint, to: HorizontalPoint) -> Int {
        let radians = atan2(to.y - from.y, to.x - from.x)
        return Int((radians / (Double.pi * 2)) * 65_536)
    }

    private func pointKey(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
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

    private func objectIDPrefix(in geometryID: String, separators: Set<String>) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
              separatorIndex > components.startIndex else {
            return nil
        }
        return components[..<separatorIndex].joined(separator: "/")
    }

    private func displayName(for type: HorizontalObjectType) -> String {
        switch type {
        case .schematicSymbol: "Schematic symbol"
        case .lineNet: "Net line"
        case .symbolPin: "Symbol pin"
        case .netLabel: "Net label"
        case .junction: "Junction"
        case .schematicNetTie: "Schematic net tie"
        case .busLabel: "Bus label"
        case .busRipper: "Bus ripper"
        case .powerSymbol: "Power symbol"
        case .schematicBlockSymbol: "Block symbol"
        case .blockSymbolPort: "Block symbol port"
        case .drawingArc: "Drawing arc"
        case .drawingLine: "Drawing line"
        case .text: "Text"
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
        case .padstackShape: "Padstack shape"
        case .plane: "Plane"
        case .polygonArcCenter: "Polygon arc center"
        case .polygonEdge: "Polygon edge"
        case .polygonVertex: "Polygon vertex"
        case .track: "Track"
        case .via: "Via"
        }
    }

    private func pluralDisplayName(for type: HorizontalObjectType) -> String {
        switch type {
        case .schematicSymbol: "Schematic symbols"
        case .lineNet: "Net lines"
        case .symbolPin: "Symbol pins"
        case .netLabel: "Net labels"
        case .junction: "Junctions"
        case .schematicNetTie: "Schematic net ties"
        case .busLabel: "Bus labels"
        case .busRipper: "Bus rippers"
        case .powerSymbol: "Power symbols"
        case .schematicBlockSymbol: "Block symbols"
        case .blockSymbolPort: "Block symbol ports"
        case .drawingArc: "Drawing arcs"
        case .drawingLine: "Drawing lines"
        case .text: "Texts"
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
        case .padstackShape: "Padstack shapes"
        case .plane: "Planes"
        case .polygonArcCenter: "Polygon arc centers"
        case .polygonEdge: "Polygon edges"
        case .polygonVertex: "Polygon vertices"
        case .track: "Tracks"
        case .via: "Vias"
        }
    }

    private func lengthString(_ length: Double) -> String {
        let millimeters = length / 1_000_000
        if millimeters >= 1 {
            return millimeters.formatted(.number.precision(.fractionLength(2))) + " mm"
        }
        return (millimeters * 1_000).formatted(.number.precision(.fractionLength(0))) + " um"
    }

    private func coordinateString(_ point: HorizontalPoint) -> String {
        "\(lengthString(point.x)), \(lengthString(point.y))"
    }

    private func angleString(_ angle: Int) -> String {
        let degrees = Double(angle) / 65_536.0 * 360.0
        return degrees.formatted(.number.precision(.fractionLength(0))) + " deg"
    }

    private func normalizedID(_ id: String) -> String {
        HorizontalCanvasModeSupport.normalizedID(id)
    }

    private func normalizedUUIDPath(_ path: String) -> String {
        path.split(separator: "/").map { normalizedID(String($0)) }.joined(separator: "/")
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

// MARK: - Pool item modes (symbol / frame)

extension SchematicCanvasView {
    // MARK: Lookup

    private func drawingPolygon(for ref: HorizontalSelectableRef, in sheet: HorizontalSchematicSheet) -> HorizontalPolygon? {
        sheet.drawingPolygons.first { normalizedID($0.id) == normalizedID(ref.id) }
    }

    private func drawingPolygonIndex(for ref: HorizontalSelectableRef, in sheet: HorizontalSchematicSheet) -> Int? {
        sheet.drawingPolygons.firstIndex { normalizedID($0.id) == normalizedID(ref.id) }
    }

    /// The unit pin behind an editable pin: its primary name and direction,
    /// straight from the context's unit JSON.
    private func unitPinInfo(for pinID: String) -> (name: String, direction: String)? {
        guard let unitJSON = symbolEditorContext?.unitJSON?.dictionary else {
            return nil
        }
        let normalized = normalizedID(pinID)
        guard let pin = unitJSON.dictionaryMap("pins").first(where: { normalizedID($0.key) == normalized })?.value else {
            return nil
        }
        return (pin.string("primary_name") ?? "", pin.string("direction") ?? "bidirectional")
    }

    private func pinOrientationChoiceOptions() -> [HorizontalSelectionPropertyOption] {
        HorizontalPinOrientation.allCases.map {
            HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.rawValue.capitalized)
        }
    }

    // MARK: HUD and inspector

    private func poolEditorHUDItem(for ref: HorizontalSelectableRef) -> HorizontalSelectionHUDItem? {
        guard editorProfile.isPoolMode else {
            return nil
        }
        switch ref.type {
        case .symbolPin:
            guard editorProfile.supportsPins, let pin = sheet.editablePin(id: ref.id) else {
                return nil
            }
            let info = unitPinInfo(for: pin.id)
            return HorizontalSelectionHUDItem(
                title: nonEmpty(info?.name) ?? "Pin",
                subtitle: "Pin \(shortID(pin.id))",
                details: [
                    detailRow("Direction", info?.direction.replacingOccurrences(of: "_", with: " ").capitalized),
                    detailRow("Position", coordinateString(pin.position)),
                    detailRow("Orientation", pin.orientation.rawValue.capitalized),
                    detailRow("Length", lengthString(pin.length)),
                ].compactMap { $0 }
            )
        case .polygonEdge:
            guard let polygon = drawingPolygon(for: ref, in: sheet) else {
                return nil
            }
            return HorizontalSelectionHUDItem(
                title: "Polygon",
                subtitle: "Polygon \(shortID(String(ref.id.split(separator: "/").last ?? "")))",
                details: [detailRow("Vertices", "\(polygon.polygonVertices.count)")].compactMap { $0 }
            )
        default:
            return nil
        }
    }

    private func poolEditorProperties(for ref: HorizontalSelectableRef) -> [HorizontalSelectionProperty]? {
        guard editorProfile.isPoolMode else {
            return nil
        }
        switch ref.type {
        case .symbolPin:
            guard editorProfile.supportsPins, let pin = sheet.editablePin(id: ref.id) else {
                return []
            }
            let info = unitPinInfo(for: pin.id)
            return [
                readOnlyProperty("name", "Name", info?.name),
                readOnlyProperty("direction", "Direction", info?.direction.replacingOccurrences(of: "_", with: " ").capitalized),
                editableLengthProperty("positionX", "Position X", pin.position.x),
                editableLengthProperty("positionY", "Position Y", pin.position.y),
                editableLengthProperty("length", "Length", pin.length),
                HorizontalSelectionProperty(
                    id: "orientation",
                    label: "Orientation",
                    editor: .choice(pinOrientationChoiceOptions()),
                    value: .choice(pin.orientation.rawValue)
                ),
                editableBoolProperty("nameVisible", "Name visible", pin.nameVisible),
                editableBoolProperty("padVisible", "Pad visible", pin.padVisible),
                HorizontalSelectionProperty(
                    id: "nameOrientation",
                    label: "Name orientation",
                    editor: .choice(HorizontalPinNameOrientation.allCases.map {
                        HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.displayName)
                    }),
                    value: .choice(pin.nameOrientation.rawValue)
                ),
                editableBoolProperty("dot", "Dot", pin.decoration.dot),
                editableBoolProperty("clock", "Clock", pin.decoration.clock),
                editableBoolProperty("schmitt", "Schmitt", pin.decoration.schmitt),
                HorizontalSelectionProperty(
                    id: "driver",
                    label: "Driver",
                    editor: .choice(HorizontalPinDriver.allCases.map {
                        HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.displayName)
                    }),
                    value: .choice(pin.decoration.driver.rawValue)
                ),
            ].compactMap { $0 }
        case .polygonEdge:
            return []
        default:
            return nil
        }
    }

    private func updateEditablePin(
        ref: HorizontalSelectableRef,
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        sheet: inout HorizontalSchematicSheet
    ) {
        guard let index = sheet.editablePinIndex(id: ref.id), let context = symbolEditorContext else {
            return
        }
        var pin = sheet.editablePins[index]
        switch (propertyID, value) {
        case ("positionX", .length(let x)):
            pin.position.x = x
        case ("positionY", .length(let y)):
            pin.position.y = y
        case ("length", .length(let length)):
            pin.length = max(length, 0)
        case ("orientation", .choice(let raw)):
            guard let orientation = HorizontalPinOrientation(rawValue: raw) else {
                return
            }
            pin.orientation = orientation
        case ("nameVisible", .bool(let visible)):
            pin.nameVisible = visible
        case ("padVisible", .bool(let visible)):
            pin.padVisible = visible
        case ("nameOrientation", .choice(let raw)):
            guard let orientation = HorizontalPinNameOrientation(rawValue: raw) else {
                return
            }
            pin.nameOrientation = orientation
        case ("dot", .bool(let flag)):
            pin.decoration.dot = flag
        case ("clock", .bool(let flag)):
            pin.decoration.clock = flag
        case ("schmitt", .bool(let flag)):
            pin.decoration.schmitt = flag
        case ("driver", .choice(let raw)):
            guard let driver = HorizontalPinDriver(rawValue: raw) else {
                return
            }
            pin.decoration.driver = driver
        default:
            return
        }
        sheet.editablePins[index] = pin
        sheet.rebakeEditablePin(id: pin.id, context: context)
    }

    // MARK: Selectables

    private func editorPinSelectables() -> [HorizontalSelectable] {
        sheet.editablePins.map { pin in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: pin.id, type: .symbolPin),
                points: sheet.editablePinGeometryPoints(id: pin.id),
                fallbackCenter: pin.position,
                fallbackSize: pin.length
            )
        }
    }

    private func drawingPolygonSelectables() -> [HorizontalSelectable] {
        sheet.drawingPolygons.map { polygon in
            let points = polygon.renderVertices(arcPrecision: 16)
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: polygon.id, type: .polygonEdge),
                points: points,
                fallbackCenter: points.first ?? .zero,
                fallbackSize: 1_000_000
            )
        }
    }

    private func poolEditorSelectable(for ref: HorizontalSelectableRef, in sheet: HorizontalSchematicSheet) -> HorizontalSelectable? {
        switch ref.type {
        case .symbolPin:
            guard editorProfile.supportsPins, let pin = sheet.editablePin(id: ref.id) else {
                return nil
            }
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: pin.id, type: .symbolPin),
                points: sheet.editablePinGeometryPoints(id: pin.id),
                fallbackCenter: pin.position,
                fallbackSize: pin.length
            )
        case .polygonEdge:
            guard let polygon = drawingPolygon(for: ref, in: sheet) else {
                return nil
            }
            let points = polygon.renderVertices(arcPrecision: 16)
            return HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: polygon.id, type: .polygonEdge),
                points: points,
                fallbackCenter: points.first ?? .zero,
                fallbackSize: 1_000_000
            )
        default:
            return nil
        }
    }

    // MARK: Transforms

    /// Pool-mode objects the sheet's own arms do not know: returns true when
    /// `ref` was handled.
    private func movePoolEditorObject(ref: HorizontalSelectableRef, by delta: HorizontalPoint, sheet: inout HorizontalSchematicSheet) -> Bool {
        switch ref.type {
        case .symbolPin:
            guard editorProfile.supportsPins, sheet.editablePin(id: ref.id) != nil else {
                return false
            }
            sheet.shiftEditablePin(id: ref.id, by: delta)
            return true
        case .polygonEdge:
            guard let index = drawingPolygonIndex(for: ref, in: sheet) else {
                return false
            }
            sheet.drawingPolygons[index] = sheet.drawingPolygons[index].transformed { $0 + delta }
            return true
        default:
            return false
        }
    }

    private func mirrorPoolEditorObject(ref: HorizontalSelectableRef, around center: HorizontalPoint, sheet: inout HorizontalSchematicSheet) -> Bool {
        switch ref.type {
        case .symbolPin:
            guard editorProfile.supportsPins,
                  let index = sheet.editablePinIndex(id: ref.id),
                  let context = symbolEditorContext else {
                return false
            }
            sheet.editablePins[index].position = mirrored(sheet.editablePins[index].position, around: center)
            sheet.editablePins[index].orientation = sheet.editablePins[index].orientation.mirrored
            sheet.rebakeEditablePin(id: ref.id, context: context)
            return true
        case .polygonEdge:
            guard let index = drawingPolygonIndex(for: ref, in: sheet) else {
                return false
            }
            sheet.drawingPolygons[index] = sheet.drawingPolygons[index]
                .transformed({ mirrored($0, around: center) }, flipsArcReverse: true)
            return true
        default:
            return false
        }
    }

    private func rotatePoolEditorObject(ref: HorizontalSelectableRef, around center: HorizontalPoint, by angleDelta: Int, sheet: inout HorizontalSchematicSheet) -> Bool {
        switch ref.type {
        case .symbolPin:
            guard editorProfile.supportsPins,
                  let index = sheet.editablePinIndex(id: ref.id),
                  let context = symbolEditorContext else {
                return false
            }
            let clockwise = wrappedAngle(angleDelta) == wrappedAngle(Self.quarterTurnAngle)
            sheet.editablePins[index].position = rotated(sheet.editablePins[index].position, around: center, by: angleDelta)
            sheet.editablePins[index].orientation = sheet.editablePins[index].orientation.rotated(clockwise: clockwise)
            sheet.rebakeEditablePin(id: ref.id, context: context)
            return true
        case .polygonEdge:
            guard let index = drawingPolygonIndex(for: ref, in: sheet) else {
                return false
            }
            sheet.drawingPolygons[index] = sheet.drawingPolygons[index].transformed { rotated($0, around: center, by: angleDelta) }
            return true
        default:
            return false
        }
    }

    // MARK: Place pin (Horizon's map-pin tool)

    /// "Place Pin" with nothing chosen: the first unplaced pin in name order.
    private func beginPlaceNextPin() {
        guard let next = currentUnplacedObjects.first else {
            return
        }
        beginPlacePin(pinID: next.id)
    }

    private func beginPlacePin(pinID: String) {
        guard !isReadOnly,
              editorProfile.supportsPins,
              let context = symbolEditorContext,
              moveState == nil,
              placePartState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil,
              sheet.editablePin(id: pinID) == nil else {
            return
        }
        let originalSheet = placePinState?.originalSheet ?? sheet
        var draft = sheet
        let pin = HorizontalSymbolPin(
            id: pinID,
            position: lastCursorWorldPoint ?? draft.bounds.center,
            orientation: placePinOrientation
        )
        draft.editablePins.append(pin)
        draft.rebakeEditablePin(id: pinID, context: context)
        editedSheet = draft
        placePinState = PlacePinState(originalSheet: originalSheet, pinID: pinID)
        selectedObjects = [HorizontalSelectableRef(id: pinID, type: .symbolPin)]
        selectedUnplacedObjectID = nil
        hoveredObject = nil
        invalidateSelectableCache()
        publishSelectionContext()
    }

    private func updatePlacePin(to point: HorizontalPoint) {
        guard let state = placePinState,
              var draft = editedSheet,
              let pin = draft.editablePin(id: state.pinID) else {
            return
        }
        let delta = point - pin.position
        guard delta != .zero else {
            return
        }
        draft.shiftEditablePin(id: state.pinID, by: delta)
        editedSheet = draft
        invalidateSelectableCache()
    }

    private func rotatePlacingPin() {
        guard let state = placePinState,
              var draft = editedSheet,
              let index = draft.editablePinIndex(id: state.pinID),
              let context = symbolEditorContext else {
            return
        }
        draft.editablePins[index].orientation = draft.editablePins[index].orientation.rotated(clockwise: true)
        placePinOrientation = draft.editablePins[index].orientation
        draft.rebakeEditablePin(id: state.pinID, context: context)
        editedSheet = draft
        invalidateSelectableCache()
    }

    private func mirrorPlacingPin() {
        guard let state = placePinState,
              var draft = editedSheet,
              let index = draft.editablePinIndex(id: state.pinID),
              let context = symbolEditorContext else {
            return
        }
        draft.editablePins[index].orientation = draft.editablePins[index].orientation.mirrored
        placePinOrientation = draft.editablePins[index].orientation
        draft.rebakeEditablePin(id: state.pinID, context: context)
        editedSheet = draft
        invalidateSelectableCache()
    }

    /// Places the pin under the cursor, then carries on with the next
    /// unplaced pin (upstream advances the same way); Esc ends the run.
    private func commitPlacePin() {
        guard !isReadOnly, let state = placePinState else {
            return
        }
        let placed = sheet
        registerUndoSnapshot(state.originalSheet, actionName: "Place Pin")
        placePinState = nil
        invalidateSelectableCache()
        onSheetChange(placed)
        publishSelectionContext()
        if let next = currentUnplacedObjects.first {
            beginPlacePin(pinID: next.id)
        }
    }

    /// Drops the pin still following the cursor; pins already placed stay.
    private func cancelPlacePin() {
        guard let state = placePinState else {
            return
        }
        var draft = sheet
        _ = draft.removeEditablePin(id: state.pinID)
        editedSheet = draft
        placePinState = nil
        selectedObjects = []
        hoveredObject = nil
        invalidateSelectableCache()
        publishSelectionContext()
    }

    // MARK: Refdes / value and dot

    /// Upstream's place-refdes-and-value: `$REFDES` above and `$VALUE` below
    /// the cursor, then both follow the cursor until a click anchors them.
    private func placeRefdesAndValue() {
        guard !isReadOnly,
              editorProfile.supportsPins,
              moveState == nil,
              placePartState == nil,
              placePinState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil else {
            return
        }
        let cursor = lastCursorWorldPoint ?? sheet.bounds.center
        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        let refdes = HorizontalText(
            id: UUID().uuidString.lowercased(),
            text: "$REFDES",
            position: HorizontalPoint(x: cursor.x, y: abs(cursor.y)),
            size: 1_500_000,
            layer: nil
        )
        let value = HorizontalText(
            id: UUID().uuidString.lowercased(),
            text: "$VALUE",
            position: HorizontalPoint(x: cursor.x, y: -abs(cursor.y)),
            size: 1_500_000,
            layer: nil
        )
        draft.texts.append(contentsOf: [refdes, value])
        registerUndoSnapshot(previousSheet, actionName: "Place Reference and Value")
        editedSheet = draft
        selectedObjects = [
            HorizontalSelectableRef(id: refdes.id, type: .text),
            HorizontalSelectableRef(id: value.id, type: .text),
        ]
        hoveredObject = nil
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
        beginMove(tracksCursor: true)
    }

    /// Upstream's place-dot: a 0.35 mm filled circle as a two-vertex arc
    /// polygon, following the cursor until a click anchors it.
    private func placeDot() {
        guard !isReadOnly,
              editorProfile.supportsPolygons,
              moveState == nil,
              placePartState == nil,
              placePinState == nil,
              drawNetLineState == nil,
              drawGraphicsState == nil else {
            return
        }
        let center = lastCursorWorldPoint ?? sheet.bounds.center
        let previousSheet = editedSheet ?? sourceSheet
        var draft = previousSheet
        let rim = HorizontalPoint(x: center.x + 175_000, y: center.y)
        let polygon = HorizontalPolygon(
            id: HorizontalSchematicSheet.editorPolygonPrefix + UUID().uuidString.lowercased(),
            polygonVertices: [
                HorizontalPolygonVertex(type: .line, position: rim),
                HorizontalPolygonVertex(type: .arc, position: rim, arcCenter: center, arcReverse: true),
            ],
            layer: 0
        )
        draft.drawingPolygons.append(polygon)
        registerUndoSnapshot(previousSheet, actionName: "Place Dot")
        editedSheet = draft
        selectedObjects = [HorizontalSelectableRef(id: polygon.id, type: .polygonEdge)]
        hoveredObject = nil
        invalidateSelectableCache()
        onSheetChange(draft)
        publishSelectionContext()
        beginMove(tracksCursor: true)
    }

    /// A polygon from the drawing tool's points (symbol / frame modes).
    private func drawingPolygon(points: [HorizontalPoint]) -> HorizontalPolygon {
        HorizontalPolygon(
            id: HorizontalSchematicSheet.editorPolygonPrefix + UUID().uuidString.lowercased(),
            polygonVertices: points.map { HorizontalPolygonVertex(position: $0) },
            layer: 0
        )
    }

    // MARK: External sheet replacement

    /// Takes on a sheet the host replaced underneath us (a header edit, an
    /// undo of one, a unit change) without tearing the canvas down: the draft
    /// and any in-flight interaction are dropped; selection and viewport stay.
    private func adoptExternallyUpdatedSheet() {
        editedSheet = nil
        moveState = nil
        placePartState = nil
        placePinState = nil
        drawNetLineState = nil
        drawGraphicsState = nil
        invalidateSelectableCache()
        publishSelectionContext()
    }
}
