import Foundation
import SwiftUI

struct HorizontalCanvasSelectableScene {
    static let empty = HorizontalCanvasSelectableScene(selectables: [])

    var selectables: [HorizontalSelectable]
    var selectablesByRef: [HorizontalSelectableRef: [HorizontalSelectable]]
    /// Spatial index over `selectables` so hover hit-testing doesn't scan the
    /// whole board on every mouse-move. Built once when the scene is built.
    private let index: HorizontalSelectableSpatialIndex

    init(selectables: [HorizontalSelectable]) {
        self.selectables = selectables
        self.selectablesByRef = Dictionary(grouping: selectables, by: \.ref)
        self.index = HorizontalSelectableSpatialIndex(selectables)
    }

    func hitSelectable(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> HorizontalSelectableRef? {
        index.smallestSelectable(
            at: point,
            expand: HorizontalSelectable.minimumScreenSize * worldUnitsPerPoint
        )
    }

    func targetRefs(at point: HorizontalPoint, worldUnitsPerPoint: Double) -> [HorizontalSelectableRef] {
        HorizontalCanvasModeSupport.uniqueRefs(
            index.allSelectables(
                at: point,
                expand: HorizontalSelectable.minimumScreenSize * worldUnitsPerPoint
            )
        )
    }

    func refs() -> [HorizontalSelectableRef] {
        HorizontalCanvasModeSupport.uniqueRefs(selectables.map(\.ref))
    }

    func snapTargets(pointKey: (HorizontalPoint) -> String) -> [HorizontalPoint] {
        var seen = Set<String>()
        return selectables
            .flatMap(\.snapPoints)
            .filter { seen.insert(pointKey($0)).inserted }
    }
}

final class HorizontalCanvasSelectableSceneCache<Key: Hashable> {
    private var sceneKey: Key?
    private var sceneValue = HorizontalCanvasSelectableScene.empty
    private var snapTargetsKey: Key?
    private var snapTargetsValue = [HorizontalPoint]()

    func scene(
        key: Key,
        build: () -> [HorizontalSelectable]
    ) -> HorizontalCanvasSelectableScene {
        if sceneKey != key {
            sceneValue = HorizontalCanvasSelectableScene(selectables: build())
            sceneKey = key
            snapTargetsKey = nil
            snapTargetsValue = []
        }
        return sceneValue
    }

    func selectables(
        key: Key,
        build: () -> [HorizontalSelectable]
    ) -> [HorizontalSelectable] {
        scene(key: key, build: build).selectables
    }

    func snapTargets(
        key: Key,
        build: () -> [HorizontalPoint]
    ) -> [HorizontalPoint] {
        if snapTargetsKey != key {
            snapTargetsValue = build()
            snapTargetsKey = key
        }
        return snapTargetsValue
    }

    func invalidate() {
        sceneKey = nil
        sceneValue = .empty
        snapTargetsKey = nil
        snapTargetsValue = []
    }
}

enum HorizontalDrawingPrimitive: String, CaseIterable, Identifiable, Equatable {
    case line
    case rectangle
    case circle
    case arc
    case polygon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .polygon: "Polygon"
        }
    }
}

enum HorizontalRectanglePlacementMode: Equatable {
    case corner
    case center

    var title: String {
        switch self {
        case .corner: "Corner"
        case .center: "Center"
        }
    }

    mutating func toggle() {
        self = self == .corner ? .center : .corner
    }
}

struct HorizontalDrawingToolCommand: Equatable {
    var id = UUID()
    var primitive: HorizontalDrawingPrimitive
}

/// One-shot request (id changes each time) to start the schematic net-line
/// drawing tool from a rail button, mirroring HorizontalDrawingToolCommand.
struct HorizontalDrawNetLineCommand: Equatable {
    var id = UUID()
}

/// One-shot request (id changes each time) to start the board track-drawing
/// tool from a rail button, mirroring HorizontalDrawNetLineCommand.
struct HorizontalDrawTrackCommand: Equatable {
    var id = UUID()
}

struct HorizontalCanvasDrawGraphicsResult {
    var lines: [HorizontalSegment] = []
    var arcs: [HorizontalArc] = []
    var polygons: [HorizontalPolygon] = []

    var isEmpty: Bool {
        lines.isEmpty && arcs.isEmpty && polygons.isEmpty
    }
}

struct HorizontalCanvasCommandHandlerSet {
    var isReadOnly: Bool
    var hasInteraction: Bool
    var selectAll: () -> Void
    var selectNet: (() -> Void)? = nil
    var copySelection: (() -> Void)? = nil
    var pasteSelection: (() -> Void)? = nil
    var duplicateSelection: (() -> Void)? = nil
    var deleteSelection: () -> Void
    var highlightSelection: () -> Void
    var beginMove: () -> Void
    var moveSelectionExactly: (() -> Void)? = nil
    var rotateSelection: () -> Void
    var rotateSelectionAroundCenter: (() -> Void)? = nil
    var rotateSelectionArbitrary: (() -> Void)? = nil
    var twirlSelection: () -> Void = {}
    var mirrorSelection: () -> Void
    var mirrorSelectionHorizontal: (() -> Void)? = nil
    var mirrorSelectionVertical: (() -> Void)? = nil
    var drawNetLine: (() -> Void)?
    var drawTrack: (() -> Void)? = nil
    var drawGraphics: ((HorizontalDrawingPrimitive) -> Void)? = nil
    var drawPlane: (() -> Void)? = nil
    var selectLayer: ((Int) -> Void)? = nil
    var selectBoardLayerView: ((HorizontalBoardLayerViewPreset) -> Void)? = nil
    var definePlane: (() -> Void)? = nil
    var editPlane: (() -> Void)? = nil
    var convertPolygonToLineLoop: (() -> Void)? = nil
    var convertLineLoopToPolygon: (() -> Void)? = nil
    var addText: (() -> Void)? = nil
    var editText: (() -> Void)? = nil
    var filterAirwires: (() -> Void)? = nil
    var openDatasheet: (() -> Void)? = nil
    var toggleSmash: (() -> Void)? = nil
    var smashSilkscreenGraphics: (() -> Void)? = nil
    var toggleOmitSilkscreen: (() -> Void)? = nil
    var toggleOmitOutline: (() -> Void)? = nil
    var toggleFixed: (() -> Void)? = nil
    var flipTrackPosture: (() -> Void)? = nil
    var enterTrackWidth: (() -> Void)? = nil
    var toggleVia: (() -> Void)? = nil
    var showToolSettings: (() -> Void)? = nil
    var moveNetSegmentToExistingNet: (() -> Void)? = nil
    var moveNetSegmentToNewNet: (() -> Void)? = nil
    var editSymbolPinNames: (() -> Void)?
    var toggleRectanglePlacementMode: (() -> Void)? = nil
    var moveSelectionBy: (HorizontalPoint) -> Void
    var commitInteraction: () -> Void
    var cancelInteraction: () -> Void

    func dispatch(_ command: HorizontalCanvasCommand) {
        switch command {
        case .selectAll:
            selectAll()
        case .selectNet:
            selectNet?()
        case .copySelection:
            copySelection?()
        case .pasteSelection:
            guard !isReadOnly else { return }
            pasteSelection?()
        case .duplicateSelection:
            guard !isReadOnly else { return }
            duplicateSelection?()
        case .deleteSelection:
            guard !isReadOnly else { return }
            deleteSelection()
        case .highlightNet:
            highlightSelection()
        case .moveSelection:
            guard !isReadOnly else { return }
            beginMove()
        case .moveSelectionExactly:
            guard !isReadOnly else { return }
            moveSelectionExactly?()
        case .rotateSelection:
            guard !isReadOnly else { return }
            rotateSelection()
        case .rotateSelectionAroundCenter:
            guard !isReadOnly else { return }
            rotateSelectionAroundCenter?()
        case .rotateSelectionArbitrary:
            guard !isReadOnly else { return }
            rotateSelectionArbitrary?()
        case .twirlSelection:
            guard !isReadOnly else { return }
            twirlSelection()
        case .mirrorSelection:
            guard !isReadOnly else { return }
            mirrorSelection()
        case .mirrorSelectionHorizontal:
            guard !isReadOnly else { return }
            mirrorSelectionHorizontal?()
        case .mirrorSelectionVertical:
            guard !isReadOnly else { return }
            mirrorSelectionVertical?()
        case .drawNetLine:
            guard !isReadOnly else { return }
            drawNetLine?()
        case .drawTrack:
            guard !isReadOnly else { return }
            drawTrack?()
        case .drawGraphics(let primitive):
            guard !isReadOnly else { return }
            drawGraphics?(primitive)
        case .drawPlane:
            guard !isReadOnly else { return }
            drawPlane?()
        case .selectLayer(let layer):
            // Not gated on isReadOnly: choosing which layer you are looking at
            // changes nothing on the board.
            selectLayer?(layer)
        case .selectBoardLayerView(let preset):
            selectBoardLayerView?(preset)
        case .definePlane:
            guard !isReadOnly else { return }
            definePlane?()
        case .editPlane:
            editPlane?()
        case .convertPolygonToLineLoop:
            guard !isReadOnly else { return }
            convertPolygonToLineLoop?()
        case .convertLineLoopToPolygon:
            guard !isReadOnly else { return }
            convertLineLoopToPolygon?()
        case .addText:
            guard !isReadOnly else { return }
            addText?()
        case .editText:
            guard !isReadOnly else { return }
            editText?()
        case .filterAirwires:
            filterAirwires?()
        case .openDatasheet:
            openDatasheet?()
        case .toggleSmash:
            guard !isReadOnly else { return }
            toggleSmash?()
        case .smashSilkscreenGraphics:
            guard !isReadOnly else { return }
            smashSilkscreenGraphics?()
        case .toggleOmitSilkscreen:
            guard !isReadOnly else { return }
            toggleOmitSilkscreen?()
        case .toggleOmitOutline:
            guard !isReadOnly else { return }
            toggleOmitOutline?()
        case .toggleFixed:
            guard !isReadOnly else { return }
            toggleFixed?()
        case .flipTrackPosture:
            guard !isReadOnly else { return }
            flipTrackPosture?()
        case .enterTrackWidth:
            guard !isReadOnly else { return }
            enterTrackWidth?()
        case .toggleVia:
            guard !isReadOnly else { return }
            toggleVia?()
        case .showToolSettings:
            showToolSettings?()
        case .moveNetSegmentToExistingNet:
            guard !isReadOnly else { return }
            moveNetSegmentToExistingNet?()
        case .moveNetSegmentToNewNet:
            guard !isReadOnly else { return }
            moveNetSegmentToNewNet?()
        case .editSymbolPinNames:
            guard !isReadOnly else { return }
            editSymbolPinNames?()
        case .toggleRectanglePlacementMode:
            guard !isReadOnly else { return }
            toggleRectanglePlacementMode?()
        case .moveSelectionBy(let delta):
            guard !isReadOnly else { return }
            moveSelectionBy(delta)
        case .commitInteraction:
            guard !isReadOnly else { return }
            commitInteraction()
        case .cancelInteraction:
            cancelInteraction()
        }
    }

    func actions() -> HorizontalCanvasCommandActions {
        let writable = !isReadOnly
        return HorizontalCanvasCommandActions(
            canDeleteSelection: writable,
            canMoveSelection: writable,
            canRotateSelection: writable,
            canMirrorSelection: writable,
            canDrawNetLine: writable && drawNetLine != nil,
            canDrawTrack: writable && drawTrack != nil,
            canDrawGraphics: writable && drawGraphics != nil,
            canDrawPlane: writable && drawPlane != nil,
            canAddText: writable && addText != nil,
            canFilterAirwires: filterAirwires != nil,
            canFlipTrackPosture: writable && flipTrackPosture != nil,
            canEnterTrackWidth: writable && enterTrackWidth != nil,
            canToggleVia: writable && toggleVia != nil,
            canShowToolSettings: showToolSettings != nil,
            canMoveNetSegmentToExistingNet: writable && moveNetSegmentToExistingNet != nil,
            canMoveNetSegmentToNewNet: writable && moveNetSegmentToNewNet != nil,
            canEditSymbolPinNames: writable && editSymbolPinNames != nil,
            canHighlightNet: true,
            canSelectAll: true,
            canSelectNet: selectNet != nil,
            canCopySelection: copySelection != nil,        // copy is non-mutating; enabled even read-only
            canPasteSelection: writable && pasteSelection != nil,
            canDuplicateSelection: writable && duplicateSelection != nil,
            canCommitInteraction: writable && hasInteraction,
            canCancelInteraction: hasInteraction,
            dispatch: dispatch
        )
    }
}

struct HorizontalCanvasSelectionOutline {
    var points: [HorizontalPoint]
    var closesPath: Bool = true
    var normalOffset: Float = -HorizontalSelectable.selectionOutlineScreenMargin
    var handlePoints: [HorizontalPoint] = []
    var dashesWhenSelected = true
    var drawsInnerStroke = false
}

struct HorizontalCanvasSelectionOverlayStyle {
    var selectedOuterColor: HorizontalMetalRGBA
    var selectedInnerColor: HorizontalMetalRGBA
    var selectedHandleInnerColor: HorizontalMetalRGBA
    var hoverOuterColor: HorizontalMetalRGBA
    var hoverInnerColor: HorizontalMetalRGBA
    var handleShape: HorizontalSelectionHandleShape
}

struct HorizontalCanvasMetalSelectionOverlay {
    var lines = [HorizontalMetalLinePrimitive]()
    var handles = [HorizontalMetalHandlePrimitive]()
}

enum HorizontalCanvasModeSupport {
    static let fullTurnAngle = 65_536

    static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    static func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }

    static func uniqueRefs(_ refs: [HorizontalSelectableRef]) -> [HorizontalSelectableRef] {
        var seen = Set<HorizontalSelectableRef>()
        var result = [HorizontalSelectableRef]()
        for ref in refs where seen.insert(ref).inserted {
            result.append(ref)
        }
        return result
    }

    static func updatedSelection(
        current: [HorizontalSelectableRef],
        ref: HorizontalSelectableRef?,
        action: HorizontalSelectionClickAction
    ) -> [HorizontalSelectableRef]? {
        guard let ref else {
            return action == .replace ? [] : nil
        }
        return updatedSelection(current: current, refs: [ref], action: action)
    }

    static func updatedSelection(
        current: [HorizontalSelectableRef],
        refs: [HorizontalSelectableRef],
        action: HorizontalSelectionClickAction
    ) -> [HorizontalSelectableRef]? {
        let refs = uniqueRefs(refs)
        guard !refs.isEmpty else {
            return action == .replace ? [] : nil
        }

        var selection = current
        switch action {
        case .replace:
            selection = refs
        case .add:
            for ref in refs where !selection.contains(ref) {
                selection.append(ref)
            }
        case .toggle:
            for ref in refs {
                if selection.contains(ref) {
                    selection.removeAll { $0 == ref }
                } else {
                    selection.append(ref)
                }
            }
        case .remove:
            let refSet = Set(refs)
            selection.removeAll { refSet.contains($0) }
        }
        return selection
    }

    static func moveStartPoint(
        modeName: String,
        isReadOnly: Bool,
        moveIsActive: Bool,
        selectedObjects: [HorizontalSelectableRef],
        lastCursorWorldPoint: HorizontalPoint?,
        selectionCenter: () -> HorizontalPoint?
    ) -> HorizontalPoint? {
        guard !isReadOnly else {
            print("Horizontal candidate beep: \(modeName) Move command ignored; reason=read-only selected=\(selectedObjects.count)")
            return nil
        }
        guard !moveIsActive else {
            print("Horizontal candidate beep: \(modeName) Move command ignored; reason=move-already-active selected=\(selectedObjects.count)")
            return nil
        }
        guard !selectedObjects.isEmpty else {
            print("Horizontal candidate beep: \(modeName) Move command ignored; reason=no-selection")
            return nil
        }
        guard let start = lastCursorWorldPoint ?? selectionCenter() else {
            print("Horizontal candidate beep: \(modeName) Move command ignored; reason=no-start-point selected=\(selectedObjects.count)")
            return nil
        }
        return start
    }

    /// Keeps the point grabbed from the selection as the drag origin while a
    /// cursor-tracked move starts at the cursor's snapped position. This makes
    /// an off-grid vertex move onto the grid instead of carrying its offset
    /// through the entire drag.
    static func moveInitialPoints(
        startPoint: HorizontalPoint,
        snappedCursorPoint: HorizontalPoint,
        tracksCursor: Bool
    ) -> (startPoint: HorizontalPoint, lastPoint: HorizontalPoint) {
        (
            startPoint: startPoint,
            lastPoint: tracksCursor ? snappedCursorPoint : startPoint
        )
    }

    static func hitSelectable(
        at point: HorizontalPoint,
        in selectables: [HorizontalSelectable],
        worldUnitsPerPoint: Double
    ) -> HorizontalSelectableRef? {
        HorizontalSelectableHitTest.smallestSelectable(
            at: point,
            in: selectables,
            expand: HorizontalSelectable.minimumScreenSize * worldUnitsPerPoint
        )
    }

    static func targetRefs(
        at point: HorizontalPoint,
        in selectables: [HorizontalSelectable],
        worldUnitsPerPoint: Double
    ) -> [HorizontalSelectableRef] {
        uniqueRefs(
            HorizontalSelectableHitTest.allSelectables(
                at: point,
                in: selectables,
                expand: HorizontalSelectable.minimumScreenSize * worldUnitsPerPoint
            )
        )
    }

    static func targetMenuItems(
        scene: HorizontalCanvasSelectableScene,
        at point: HorizontalPoint,
        worldUnitsPerPoint: Double,
        itemForRef: (HorizontalSelectableRef) -> HorizontalSelectionHUDItem?,
        extraItemsForRef: (HorizontalSelectableRef) -> [HorizontalSelectionTargetItem] = { _ in [] }
    ) -> [HorizontalSelectionTargetItem] {
        scene
            .targetRefs(at: point, worldUnitsPerPoint: worldUnitsPerPoint)
            .flatMap { ref -> [HorizontalSelectionTargetItem] in
                guard let item = itemForRef(ref) else {
                    return []
                }
                return [HorizontalSelectionTargetItem(ref: ref, title: item.title, subtitle: item.subtitle)]
                    + extraItemsForRef(ref)
            }
    }

    static func selectionCenter(
        for refs: [HorizontalSelectableRef],
        anchorPoints: (HorizontalSelectableRef) -> [HorizontalPoint]
    ) -> HorizontalPoint? {
        let points = refs.flatMap(anchorPoints)
        guard !points.isEmpty else {
            return nil
        }
        return HorizontalRect(points: points).center
    }

    static func lineSelectionAnchorPoints(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        includesArcCenter: Bool = false
    ) -> [HorizontalPoint] {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return []
        }
        if includesArcCenter, let center = segment.center {
            return [segment.from, segment.to, center]
        }
        return [segment.from, segment.to]
    }

    static func selectionHandlePoints(for selectable: HorizontalSelectable) -> [HorizontalPoint] {
        [selectable.center]
    }

    static func selectionHandlePath(center: CGPoint, radius: CGFloat, shape: HorizontalSelectionHandleShape) -> Path {
        if shape == .round {
            return Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.closeSubpath()
        return path
    }

    static func selectablePath(
        for selectable: HorizontalSelectable,
        transform: HorizontalCanvasTransform,
        screenMargin: CGFloat = 0
    ) -> Path {
        var path = Path()
        let worldMargin = Double(screenMargin) * transform.worldUnitsPerPoint
        let corners = selectable.corners(expandedByWorld: worldMargin)
        guard let first = corners.first else {
            return path
        }

        path.move(to: transform.point(first))
        for corner in corners.dropFirst() {
            path.addLine(to: transform.point(corner))
        }
        path.closeSubpath()
        return path
    }

    static func drawSelectionHandle(
        at point: HorizontalPoint,
        outerColor: Color,
        innerColor: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        shape: HorizontalSelectionHandleShape
    ) {
        let center = transform.point(point)
        context.fill(
            selectionHandlePath(center: center, radius: shape.outerRadius, shape: shape),
            with: .color(outerColor)
        )
        context.fill(
            selectionHandlePath(center: center, radius: shape.innerRadius, shape: shape),
            with: .color(innerColor)
        )
    }

    static func metalSelectionOverlay(
        selectablesForRef: (HorizontalSelectableRef) -> [HorizontalSelectable],
        selectedRefs: [HorizontalSelectableRef],
        hoveredRef: HorizontalSelectableRef?,
        style: HorizontalCanvasSelectionOverlayStyle,
        outlineForSelectable: (HorizontalSelectable) -> HorizontalCanvasSelectionOutline? = { _ in nil }
    ) -> HorizontalCanvasMetalSelectionOverlay {
        var overlay = HorizontalCanvasMetalSelectionOverlay()
        var drawnRefs = Set<HorizontalSelectableRef>()

        func appendLine(
            from: HorizontalPoint,
            to: HorizontalPoint,
            color: HorizontalMetalRGBA,
            minimumWidth: Float,
            dash: (Float, Float)?,
            normalOffset: Float
        ) {
            overlay.lines.append(
                HorizontalMetalLinePrimitive(
                    from: from,
                    to: to,
                    color: color,
                    minimumWidth: minimumWidth,
                    dashLength: dash?.0 ?? 0,
                    dashGap: dash?.1 ?? 0,
                    normalOffset: normalOffset
                )
            )
        }

        func appendPolyline(
            _ points: [HorizontalPoint],
            closesPath: Bool,
            color: HorizontalMetalRGBA,
            minimumWidth: Float,
            dash: (Float, Float)?,
            normalOffset: Float
        ) {
            let pathPoints: [HorizontalPoint]
            if closesPath, let first = points.first {
                pathPoints = points + [first]
            } else {
                pathPoints = points
            }
            guard pathPoints.count >= 2 else {
                return
            }
            for pair in zip(pathPoints, pathPoints.dropFirst()) {
                appendLine(
                    from: pair.0,
                    to: pair.1,
                    color: color,
                    minimumWidth: minimumWidth,
                    dash: dash,
                    normalOffset: normalOffset
                )
            }
        }

        func appendSelectable(_ selectable: HorizontalSelectable, selected: Bool) {
            let outline = outlineForSelectable(selectable) ?? selectionOutline(for: selectable)
            let outerColor = selected ? style.selectedOuterColor : style.hoverOuterColor
            let innerColor = selected ? style.selectedInnerColor : style.hoverInnerColor
            let dash: (Float, Float)? = selected && !outline.dashesWhenSelected ? nil : (5, 4)

            appendPolyline(
                outline.points,
                closesPath: outline.closesPath,
                color: outerColor,
                minimumWidth: selected ? 2.4 : 1.8,
                dash: dash,
                normalOffset: outline.normalOffset
            )
            if outline.drawsInnerStroke {
                appendPolyline(
                    outline.points,
                    closesPath: outline.closesPath,
                    color: innerColor,
                    minimumWidth: 0.8,
                    dash: dash,
                    normalOffset: outline.normalOffset
                )
            }
            if selected {
                let points = outline.handlePoints.isEmpty
                    ? selectionHandlePoints(for: selectable)
                    : outline.handlePoints
                for point in points {
                    overlay.handles.append(
                        HorizontalMetalHandlePrimitive(
                            center: point,
                            outerColor: style.selectedOuterColor,
                            innerColor: style.selectedHandleInnerColor,
                            shape: style.handleShape
                        )
                    )
                }
            }
        }

        func emit(ref: HorizontalSelectableRef, selected: Bool) {
            guard drawnRefs.insert(ref).inserted else {
                return
            }
            for selectable in selectablesForRef(ref) {
                appendSelectable(selectable, selected: selected)
            }
        }

        for ref in uniqueRefs(selectedRefs) {
            emit(ref: ref, selected: true)
        }
        if let hoveredRef, !drawnRefs.contains(hoveredRef) {
            emit(ref: hoveredRef, selected: false)
        }

        return overlay
    }

    static func selectionOutline(for selectable: HorizontalSelectable) -> HorizontalCanvasSelectionOutline {
        if selectable.ref.type.hasLineCenterHandle,
           selectable.handlePoints.count >= 2 {
            return HorizontalCanvasSelectionOutline(
                points: Array(selectable.handlePoints.prefix(2)),
                closesPath: false,
                normalOffset: 0,
                handlePoints: selectionHandlePoints(for: selectable),
                dashesWhenSelected: true,
                drawsInnerStroke: false
            )
        }

        return HorizontalCanvasSelectionOutline(
            points: selectable.corners,
            handlePoints: selectionHandlePoints(for: selectable)
        )
    }

    static func rectangleCorners(
        from p0: HorizontalPoint,
        to p1: HorizontalPoint,
        placementMode: HorizontalRectanglePlacementMode = .corner
    ) -> [HorizontalPoint] {
        let minPoint: HorizontalPoint
        let maxPoint: HorizontalPoint
        switch placementMode {
        case .corner:
            minPoint = HorizontalPoint(x: min(p0.x, p1.x), y: min(p0.y, p1.y))
            maxPoint = HorizontalPoint(x: max(p0.x, p1.x), y: max(p0.y, p1.y))
        case .center:
            let halfWidth = abs(p1.x - p0.x)
            let halfHeight = abs(p1.y - p0.y)
            minPoint = HorizontalPoint(x: p0.x - halfWidth, y: p0.y - halfHeight)
            maxPoint = HorizontalPoint(x: p0.x + halfWidth, y: p0.y + halfHeight)
        }
        return [
            minPoint,
            HorizontalPoint(x: minPoint.x, y: maxPoint.y),
            maxPoint,
            HorizontalPoint(x: maxPoint.x, y: minPoint.y)
        ]
    }

    static func closedSegmentPairs(points: [HorizontalPoint]) -> [(HorizontalPoint, HorizontalPoint)] {
        guard points.count >= 2 else {
            return []
        }
        return zip(points, Array(points.dropFirst()) + [points[0]]).map { ($0.0, $0.1) }
    }

    static func point(onCircleWithCenter center: HorizontalPoint, radius: Double, toward point: HorizontalPoint) -> HorizontalPoint {
        let direction = (point - center).normalized
        guard direction != .zero else {
            return HorizontalPoint(x: center.x + radius, y: center.y)
        }
        return center + direction * radius
    }

    static func graphicsResult(
        for primitive: HorizontalDrawingPrimitive,
        points: [HorizontalPoint],
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner,
        pointKey: (HorizontalPoint) -> String,
        makeSegment: (HorizontalPoint, HorizontalPoint) -> HorizontalSegment,
        makeArc: (HorizontalPoint, HorizontalPoint, HorizontalPoint) -> HorizontalArc,
        makePolygonResult: ([HorizontalPoint]) -> HorizontalCanvasDrawGraphicsResult
    ) -> HorizontalCanvasDrawGraphicsResult {
        switch primitive {
        case .line:
            guard points.count >= 2 else { return HorizontalCanvasDrawGraphicsResult() }
            return HorizontalCanvasDrawGraphicsResult(lines: zip(points, points.dropFirst()).map {
                makeSegment($0.0, $0.1)
            })
        case .rectangle:
            guard points.count >= 2 else { return HorizontalCanvasDrawGraphicsResult() }
            let corners = rectangleCorners(from: points[0], to: points[1], placementMode: rectanglePlacementMode)
            let lines = closedSegmentPairs(points: corners).map { makeSegment($0.0, $0.1) }
            return HorizontalCanvasDrawGraphicsResult(lines: lines)
        case .circle:
            guard points.count >= 2 else { return HorizontalCanvasDrawGraphicsResult() }
            let center = points[0]
            let radiusPoint = points[1]
            guard pointKey(center) != pointKey(radiusPoint) else {
                return HorizontalCanvasDrawGraphicsResult()
            }
            let opposite = center - (radiusPoint - center)
            return HorizontalCanvasDrawGraphicsResult(arcs: [
                makeArc(radiusPoint, opposite, center),
                makeArc(opposite, radiusPoint, center),
            ])
        case .arc:
            guard points.count >= 4,
                  let endpoints = arcEndpointsFromCenterRadiusAngles(points, pointKey: pointKey) else {
                return HorizontalCanvasDrawGraphicsResult()
            }
            return HorizontalCanvasDrawGraphicsResult(arcs: [
                makeArc(endpoints.from, endpoints.to, endpoints.center)
            ])
        case .polygon:
            guard points.count >= 3 else { return HorizontalCanvasDrawGraphicsResult() }
            return makePolygonResult(points)
        }
    }

    static func previewGraphicsResult(
        for primitive: HorizontalDrawingPrimitive,
        points: [HorizontalPoint],
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner,
        pointKey: (HorizontalPoint) -> String,
        makeSegment: (HorizontalPoint, HorizontalPoint) -> HorizontalSegment,
        makeArc: (HorizontalPoint, HorizontalPoint, HorizontalPoint) -> HorizontalArc,
        finalizedResult: (HorizontalDrawingPrimitive, [HorizontalPoint], HorizontalRectanglePlacementMode) -> HorizontalCanvasDrawGraphicsResult
    ) -> HorizontalCanvasDrawGraphicsResult {
        switch primitive {
        case .line:
            guard points.count >= 2 else {
                return HorizontalCanvasDrawGraphicsResult()
            }
            return finalizedResult(primitive, points, rectanglePlacementMode)
        case .rectangle, .circle:
            guard points.count >= 2 else {
                return HorizontalCanvasDrawGraphicsResult()
            }
            return finalizedResult(primitive, Array(points.prefix(2)), rectanglePlacementMode)
        case .polygon:
            guard points.count >= 2 else {
                return HorizontalCanvasDrawGraphicsResult()
            }
            return HorizontalCanvasDrawGraphicsResult(lines: zip(points, points.dropFirst()).map {
                makeSegment($0.0, $0.1)
            })
        case .arc:
            if points.count >= 4 {
                return finalizedResult(primitive, Array(points.prefix(4)), rectanglePlacementMode)
            }
            if points.count == 3 {
                let center = points[0]
                let radius = (points[1] - center).length
                guard radius > 0 else {
                    return HorizontalCanvasDrawGraphicsResult()
                }
                let start = point(onCircleWithCenter: center, radius: radius, toward: points[2])
                return HorizontalCanvasDrawGraphicsResult(lines: [makeSegment(center, start)])
            }
            if points.count == 2 {
                let center = points[0]
                let radiusPoint = points[1]
                let radius = (radiusPoint - center).length
                guard radius > 0 else {
                    return HorizontalCanvasDrawGraphicsResult()
                }
                return HorizontalCanvasDrawGraphicsResult(arcs: [
                    makeArc(radiusPoint, center - (radiusPoint - center), center),
                    makeArc(center - (radiusPoint - center), radiusPoint, center),
                ])
            }
            return HorizontalCanvasDrawGraphicsResult()
        }
    }

    static func finalizedGraphicsResult(
        for primitive: HorizontalDrawingPrimitive,
        points: [HorizontalPoint],
        rectanglePlacementMode: HorizontalRectanglePlacementMode = .corner,
        graphicsResult: (HorizontalDrawingPrimitive, [HorizontalPoint], HorizontalRectanglePlacementMode) -> HorizontalCanvasDrawGraphicsResult
    ) -> HorizontalCanvasDrawGraphicsResult? {
        switch primitive {
        case .line:
            guard points.count >= 2 else {
                return nil
            }
            return graphicsResult(primitive, points, rectanglePlacementMode)
        case .rectangle, .circle:
            guard points.count >= 2 else {
                return nil
            }
            return graphicsResult(primitive, Array(points.prefix(2)), rectanglePlacementMode)
        case .polygon:
            guard points.count >= 3 else {
                return nil
            }
            return graphicsResult(primitive, points, rectanglePlacementMode)
        case .arc:
            guard points.count >= 4 else {
                return nil
            }
            return graphicsResult(primitive, Array(points.prefix(4)), rectanglePlacementMode)
        }
    }

    static func drawingToolStatusText(
        for primitive: HorizontalDrawingPrimitive,
        rectanglePlacementMode: HorizontalRectanglePlacementMode
    ) -> String {
        switch primitive {
        case .line:
            return "Line: click vertices   Return, Esc, or right-click ends"
        case .rectangle:
            return "Rectangle: \(rectanglePlacementMode.title) first point   C toggles   Return commits   Esc cancels"
        case .circle:
            return "Circle: click center and radius   Return commits   Esc cancels"
        case .arc:
            return "Arc: center, radius, start, end   Return commits   Esc cancels"
        case .polygon:
            return "Polygon: click vertices   Double-click or Return commits   Esc cancels"
        }
    }

    static func arcEndpointsFromCenterRadiusAngles(
        _ points: [HorizontalPoint],
        pointKey: (HorizontalPoint) -> String
    ) -> (from: HorizontalPoint, to: HorizontalPoint, center: HorizontalPoint)? {
        guard points.count >= 4 else {
            return nil
        }
        let center = points[0]
        let radius = (points[1] - center).length
        guard radius > 0 else {
            return nil
        }
        let start = point(onCircleWithCenter: center, radius: radius, toward: points[2])
        let end = point(onCircleWithCenter: center, radius: radius, toward: points[3])
        guard pointKey(start) != pointKey(end) else {
            return nil
        }
        return (start, end, center)
    }

    static func segmentSelectables(
        _ segments: [HorizontalSegment],
        type: HorizontalObjectType,
        convertsArcSegments: Bool = false
    ) -> [HorizontalSelectable] {
        segments.flatMap { segment in
            if convertsArcSegments, let arc = segment.arc {
                return arcSelectables([arc], type: type)
            }

            let ref = HorizontalSelectableRef(id: segment.id, type: type, layer: segment.layer)
            var selectables = [
                HorizontalSelectable.line(
                    ref: ref,
                    from: segment.from,
                    to: segment.to,
                    width: segment.width,
                    layer: segment.layer
                )
            ]
            if type.hasLineCenterHandle {
                selectables.append(
                    HorizontalSelectable.point(
                        ref: ref,
                        at: (segment.from + segment.to) * 0.5
                    )
                )
            }
            return selectables
        }
    }

    static func segmentSelectable(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment]
    ) -> HorizontalSelectable? {
        guard let segment = segments.first(where: { normalizedID($0.id) == normalizedID(ref.id) }) else {
            return nil
        }
        return HorizontalSelectable.line(
            ref: HorizontalSelectableRef(id: segment.id, type: ref.type, layer: segment.layer),
            from: segment.from,
            to: segment.to,
            width: segment.width,
            layer: segment.layer
        )
    }

    static func arcSelectables(_ arcs: [HorizontalArc], type: HorizontalObjectType) -> [HorizontalSelectable] {
        arcs.map { arc in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: arc.id, type: type, layer: arc.layer),
                points: arc.polyline(precision: 24),
                fallbackCenter: arc.projectedCenter,
                fallbackSize: max(arc.width, 1_000_000)
            )
        }
    }

    static func textSelectables(_ texts: [HorizontalText], type: HorizontalObjectType = .text) -> [HorizontalSelectable] {
        texts.map { text in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: text.id, type: type, layer: text.layer),
                points: text.renderBoundsPoints,
                fallbackCenter: text.position,
                fallbackSize: text.size
            )
        }
    }

    static func shifted(_ segment: HorizontalSegment, by delta: HorizontalPoint) -> HorizontalSegment {
        var segment = segment
        segment.from = segment.from + delta
        segment.to = segment.to + delta
        segment.center = segment.center.map { $0 + delta }
        return segment
    }

    static func shifted(_ arc: HorizontalArc, by delta: HorizontalPoint) -> HorizontalArc {
        var arc = arc
        arc.from = arc.from + delta
        arc.to = arc.to + delta
        arc.center = arc.center + delta
        return arc
    }

    static func shifted(_ circle: HorizontalCircle, by delta: HorizontalPoint) -> HorizontalCircle {
        var circle = circle
        circle.center = circle.center + delta
        return circle
    }

    /// Moving a pad has to move its label frame with it.
    ///
    /// The frame records where the label sits in BOARD-WORLD coordinates rather
    /// than an offset from the pad, and nothing re-derives it from the moved
    /// shape, so leaving it behind puts the label at the part's old position
    /// while its copper moves.
    static func shifted(_ polygon: HorizontalPolygon, by delta: HorizontalPoint) -> HorizontalPolygon {
        var result = polygon.transformed { $0 + delta }
        result.padLabelFrame = polygon.padLabelFrame.map { frame in
            var moved = frame
            moved.center = frame.center + delta
            return moved
        }
        return result
    }

    static func shifted(_ hole: HorizontalHole, by delta: HorizontalPoint) -> HorizontalHole {
        var hole = hole
        hole.position = hole.position + delta
        return hole
    }

    static func shifted(_ text: HorizontalText, by delta: HorizontalPoint) -> HorizontalText {
        var text = text
        text.position = text.position + delta
        return text
    }

    static func rotated(_ point: HorizontalPoint, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalPoint {
        let radians = Double(angleDelta) / Double(fullTurnAngle) * Double.pi * 2
        let translated = point - origin
        return HorizontalPoint(
            x: translated.x * cos(radians) - translated.y * sin(radians),
            y: translated.x * sin(radians) + translated.y * cos(radians)
        ) + origin
    }

    static func rotated(_ segment: HorizontalSegment, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalSegment {
        var segment = segment
        segment.from = rotated(segment.from, around: origin, by: angleDelta)
        segment.to = rotated(segment.to, around: origin, by: angleDelta)
        segment.center = segment.center.map { rotated($0, around: origin, by: angleDelta) }
        return segment
    }

    static func rotated(_ arc: HorizontalArc, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalArc {
        var arc = arc
        arc.from = rotated(arc.from, around: origin, by: angleDelta)
        arc.to = rotated(arc.to, around: origin, by: angleDelta)
        arc.center = rotated(arc.center, around: origin, by: angleDelta)
        return arc
    }

    static func rotated(_ circle: HorizontalCircle, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalCircle {
        var circle = circle
        circle.center = rotated(circle.center, around: origin, by: angleDelta)
        return circle
    }

    /// As `shifted`, plus the turn itself: a rotated label must orbit AND face
    /// the new direction. Same treatment a hole's own angle gets.
    static func rotated(_ polygon: HorizontalPolygon, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalPolygon {
        var result = polygon.transformed { rotated($0, around: origin, by: angleDelta) }
        result.padLabelFrame = polygon.padLabelFrame.map { frame in
            var turned = frame
            turned.center = rotated(frame.center, around: origin, by: angleDelta)
            turned.angle = wrappedAngle(frame.angle + angleDelta)
            return turned
        }
        return result
    }

    static func rotated(_ hole: HorizontalHole, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalHole {
        var hole = hole
        hole.position = rotated(hole.position, around: origin, by: angleDelta)
        hole.angle = wrappedAngle(hole.angle + angleDelta)
        return hole
    }

    static func rotated(_ text: HorizontalText, around origin: HorizontalPoint, by angleDelta: Int) -> HorizontalText {
        var text = text
        text.position = rotated(text.position, around: origin, by: angleDelta)
        text.angle = wrappedAngle(text.angle + (text.mirrored ? -angleDelta : angleDelta))
        return text
    }

    static func mirrored(_ point: HorizontalPoint, around center: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(x: center.x - (point.x - center.x), y: point.y)
    }

    static func wrappedAngle(_ angle: Int) -> Int {
        let wrapped = angle % fullTurnAngle
        return wrapped < 0 ? wrapped + fullTurnAngle : wrapped
    }
}
