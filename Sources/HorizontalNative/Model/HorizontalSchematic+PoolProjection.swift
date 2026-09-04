import Foundation

/// Symbols and frames as synthetic schematic sheets the schematic canvas can
/// edit, and the way back. Junction-referenced lines and arcs become
/// positioned segments (ids prefixed the way the sheet's own drawing is), texts
/// keep the sheet's angle convention, pins are carried as `editablePins` with
/// their artwork baked per pin so an edit re-bakes only that pin.
extension HorizontalSchematicSheet {
    static let editorLinePrefix = "sheet/line/"
    static let editorArcPrefix = "sheet/arc/"
    static let editorPolygonPrefix = "sheet/polygon/"

    /// An empty sheet standing in for a pool item.
    static func poolEditorSheet(id: String, name: String, gridSpacing: Double) -> HorizontalSchematicSheet {
        HorizontalSchematicSheet(
            id: id,
            name: name,
            index: 0,
            grid: HorizontalGridSettings(
                name: "symbol",
                mode: "square",
                spacing: HorizontalPoint(x: gridSpacing, y: gridSpacing),
                origin: .zero
            ),
            netClasses: [],
            junctions: [:],
            junctionNetIDs: [:],
            netDetails: [:],
            netLines: [],
            drawingLines: [],
            drawingArcs: [],
            busLabels: [],
            busRipperLines: [],
            busRipperTexts: [],
            blockSymbolLines: [],
            blockSymbolPorts: [],
            blockSymbolTexts: [],
            netTies: [],
            symbols: [],
            symbolLines: [],
            symbolPins: [],
            symbolPinCircles: [],
            symbolPolygons: [],
            symbolTexts: [],
            noPopulateMarks: [],
            frameLines: [],
            framePolygons: [],
            frameTexts: [],
            texts: [],
            netLabels: [],
            powerSymbols: [],
            powerSymbolLines: [],
            powerSymbolCircles: [],
            powerSymbolTexts: [],
            bounds: HorizontalRect.emptyContentCanvasRegion
        )
    }

    /// The pool drawing as sheet geometry: lines, arcs and polygons with the
    /// sheet's `sheet/…/` ids, texts through the shared angle convention.
    /// With a `transform` (a text-placement view) everything is placed as a
    /// symbol in that orientation would be, texts taking the view's own
    /// placements where the symbol has them.
    mutating func loadPoolDrawing(
        _ drawing: HorizontalPoolDrawing,
        transform: HorizontalPlacementTransform = .identity,
        textPlacements: [String: HorizontalPlacementTransform] = [:]
    ) {
        let isIdentity = transform == .identity
        junctions = drawing.junctions.mapValues(transform.applying)
        drawingLines = drawing.boardLines().map { segment in
            var segment = segment
            segment.id = Self.editorLinePrefix + segment.id
            segment.from = transform.applying(to: segment.from)
            segment.to = transform.applying(to: segment.to)
            return segment
        }
        drawingArcs = drawing.boardArcs().map { arc in
            var arc = arc
            arc.id = Self.editorArcPrefix + arc.id
            // A mirrored arc sweeps the other way round: swap its ends.
            let from = transform.applying(to: transform.mirrored ? arc.to : arc.from)
            let to = transform.applying(to: transform.mirrored ? arc.from : arc.to)
            arc.from = from
            arc.to = to
            arc.center = transform.applying(to: arc.center)
            return arc
        }
        drawingPolygons = drawing.boardPolygons().map { polygon in
            var polygon = isIdentity ? polygon : polygon.transformed(transform.applying, flipsArcReverse: transform.mirrored)
            polygon.id = Self.editorPolygonPrefix + polygon.id
            return polygon
        }
        texts = drawing.texts.values.map { text in
            let placement = textPlacements[text.id] ?? text.placement
            let placed = transform.accumulatedText(with: placement)
            return HorizontalText(
                id: text.id,
                text: text.text,
                position: placed.shift,
                size: text.size,
                layer: text.layer,
                angle: placed.angle,
                mirrored: placed.mirrored,
                width: text.width,
                origin: text.origin,
                font: text.font,
                allowUpsideDown: text.allowUpsideDown,
                fromSmash: text.fromSmash
            )
        }
    }

    /// `deletePolygonVertices` as the board does it: an arc centre becomes a
    /// straight edge, an edge takes both its vertices, a vertex itself; a
    /// polygon left with fewer than three vertices (or no area) goes away.
    mutating func deleteDrawingPolygonVertices(_ ref: HorizontalSelectableRef) -> Bool {
        guard let polygonIndex = drawingPolygons.firstIndex(where: { $0.id.lowercased() == ref.id.lowercased() }),
              drawingPolygons[polygonIndex].polygonVertices.indices.contains(ref.vertex) else {
            return false
        }
        if ref.type == .polygonArcCenter {
            drawingPolygons[polygonIndex].polygonVertices[ref.vertex].type = .line
            return true
        }
        let indices: [Int]
        if ref.type == .polygonEdge {
            let next = drawingPolygons[polygonIndex].nextVertexIndex(after: ref.vertex)
            indices = Array(Set([ref.vertex, next])).sorted(by: >)
        } else {
            indices = [ref.vertex]
        }
        for index in indices where drawingPolygons[polygonIndex].polygonVertices.indices.contains(index) {
            drawingPolygons[polygonIndex].polygonVertices.remove(at: index)
        }
        if drawingPolygons[polygonIndex].polygonVertices.count < 2 {
            drawingPolygons.remove(at: polygonIndex)
        }
        return true
    }

    /// The drawing taken back from the sheet: prefixes stripped, junctions
    /// regenerated by position (existing ids kept), texts back to file angles.
    func poolDrawing(original: HorizontalPoolDrawing) -> HorizontalPoolDrawing {
        func stripped(_ id: String, _ prefix: String) -> String {
            id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        }
        let lines = drawingLines.map { segment -> HorizontalSegment in
            var segment = segment
            segment.id = stripped(segment.id, Self.editorLinePrefix)
            return segment
        }
        let arcs = drawingArcs.map { arc -> HorizontalArc in
            var arc = arc
            arc.id = stripped(arc.id, Self.editorArcPrefix)
            return arc
        }
        let polygons = drawingPolygons.map { polygon -> HorizontalPolygon in
            var polygon = polygon
            polygon.id = stripped(polygon.id, Self.editorPolygonPrefix)
            return polygon
        }
        let texts = self.texts.map { text -> HorizontalText in
            var text = text
            text.id = stripped(text.id, "sheet/text/")
            return text
        }
        return HorizontalPoolDrawing.from(
            junctions: junctions,
            lines: lines,
            arcs: arcs,
            polygons: polygons,
            texts: texts,
            original: original
        )
    }

    /// Recomputes the canvas bounds from everything the synthetic sheet holds.
    mutating func recomputePoolEditorBounds() {
        var points = [HorizontalPoint]()
        points.append(contentsOf: junctions.values)
        points.append(contentsOf: drawingLines.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: drawingArcs.flatMap { $0.polyline(precision: 24) })
        points.append(contentsOf: drawingPolygons.flatMap(\.vertices))
        points.append(contentsOf: texts.flatMap(\.renderBoundsPoints))
        points.append(contentsOf: symbolPins.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: symbolTexts.flatMap(\.renderBoundsPoints))
        points.append(contentsOf: frameLines.flatMap { [$0.from, $0.to] })
        bounds = HorizontalRect(points: points).padded().orEmptyContentCanvasRegion()
    }

    // MARK: Editable pins

    /// The id separators pin geometry carries (`<symbol>/pin-name/<pin>`…).
    static let editorPinSeparators: Set<String> = [
        "pin", "pin-connector", "pin-connector-text", "pin-decoration", "pin-direction",
        "pin-name", "pin-pad", "pin-name-hidden", "pin-pad-hidden",
    ]

    /// The pin a baked geometry id belongs to.
    static func editorPinID(forGeometryID id: String) -> String? {
        let components = id.lowercased().split(separator: "/").map(String.init)
        guard let separatorIndex = components.firstIndex(where: { editorPinSeparators.contains($0) }) else {
            return nil
        }
        let pinIndex = components.index(after: separatorIndex)
        guard pinIndex < components.endIndex else {
            return nil
        }
        return components[pinIndex]
    }

    func editablePin(id: String) -> HorizontalSymbolPin? {
        let normalized = id.lowercased()
        return editablePins.first { $0.id.lowercased() == normalized }
    }

    func editablePinIndex(id: String) -> Int? {
        let normalized = id.lowercased()
        return editablePins.firstIndex { $0.id.lowercased() == normalized }
    }

    mutating func removeEditablePinGeometry(pinID: String) {
        let normalized = pinID.lowercased()
        symbolPins.removeAll { Self.editorPinID(forGeometryID: $0.id) == normalized }
        symbolPinCircles.removeAll { Self.editorPinID(forGeometryID: $0.id) == normalized }
        symbolTexts.removeAll { Self.editorPinID(forGeometryID: $0.id) == normalized }
    }

    /// Replaces one pin's artwork with a fresh bake.
    mutating func rebakeEditablePin(id: String, context: HorizontalSymbolEditorContext) {
        removeEditablePinGeometry(pinID: id)
        guard let pin = editablePin(id: id) else {
            return
        }
        let artwork = HorizontalSchematic.symbolEditorPinArtwork(pins: [pin], context: context)
        symbolPins.append(contentsOf: artwork.pins)
        symbolPinCircles.append(contentsOf: artwork.circles)
        symbolTexts.append(contentsOf: artwork.texts)
    }

    mutating func rebakeAllEditablePins(context: HorizontalSymbolEditorContext) {
        let artwork = HorizontalSchematic.symbolEditorPinArtwork(pins: editablePins, context: context)
        symbolPins = artwork.pins
        symbolPinCircles = artwork.circles
        symbolTexts = artwork.texts
    }

    /// Translates a pin and its artwork without re-baking.
    mutating func shiftEditablePin(id: String, by delta: HorizontalPoint) {
        guard let index = editablePinIndex(id: id) else {
            return
        }
        editablePins[index].position = editablePins[index].position + delta
        let normalized = id.lowercased()
        for pinIndex in symbolPins.indices where Self.editorPinID(forGeometryID: symbolPins[pinIndex].id) == normalized {
            symbolPins[pinIndex].from = symbolPins[pinIndex].from + delta
            symbolPins[pinIndex].to = symbolPins[pinIndex].to + delta
        }
        for circleIndex in symbolPinCircles.indices where Self.editorPinID(forGeometryID: symbolPinCircles[circleIndex].id) == normalized {
            symbolPinCircles[circleIndex].center = symbolPinCircles[circleIndex].center + delta
        }
        for textIndex in symbolTexts.indices where Self.editorPinID(forGeometryID: symbolTexts[textIndex].id) == normalized {
            symbolTexts[textIndex].position = symbolTexts[textIndex].position + delta
        }
    }

    mutating func removeEditablePin(id: String) -> Bool {
        guard let index = editablePinIndex(id: id) else {
            return false
        }
        editablePins.remove(at: index)
        removeEditablePinGeometry(pinID: id)
        return true
    }

    /// Every point a pin's artwork covers, for its selectable bounds.
    func editablePinGeometryPoints(id: String) -> [HorizontalPoint] {
        let normalized = id.lowercased()
        var points = [HorizontalPoint]()
        for segment in symbolPins where Self.editorPinID(forGeometryID: segment.id) == normalized {
            points.append(segment.from)
            points.append(segment.to)
        }
        for circle in symbolPinCircles where Self.editorPinID(forGeometryID: circle.id) == normalized {
            points.append(HorizontalPoint(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius))
            points.append(HorizontalPoint(x: circle.center.x + circle.radius, y: circle.center.y + circle.radius))
        }
        for text in symbolTexts where Self.editorPinID(forGeometryID: text.id) == normalized {
            points.append(contentsOf: text.renderBoundsPoints)
        }
        return points
    }
}

// MARK: - Symbol

extension HorizontalPoolSymbol {
    /// The unit's pins the symbol may still place, in natural name order.
    func unplacedPinObjects(unit: HorizontalPoolUnit?) -> [HorizontalUnplacedObject] {
        guard let unit else {
            return []
        }
        let placed = Set(pins.keys.map { $0.lowercased() })
        return unit.sortedPins
            .filter { !placed.contains($0.id.lowercased()) }
            .map { pin in
                HorizontalUnplacedObject(
                    id: pin.id,
                    label: pin.primaryName,
                    subtitle: pin.direction.displayName,
                    componentID: nil,
                    gateID: nil
                )
            }
    }

    /// The symbol as a sheet the symbol editor can drive. In a text-placement
    /// view the symbol is shown as placed in that orientation, with no pins
    /// to place.
    func makeSheet(context: HorizontalSymbolEditorContext, unit: HorizontalPoolUnit?) -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(
            id: uuid,
            name: name,
            gridSpacing: HorizontalSchematicEditorProfile.symbol.gridSpacing ?? 1_250_000
        )
        if let view = context.view {
            sheet.loadPoolDrawing(
                drawing,
                transform: view.transform,
                textPlacements: correctedTextPlacements[view.key] ?? [:]
            )
        } else {
            sheet.loadPoolDrawing(drawing)
        }
        sheet.editablePins = pins.values.sorted { $0.id < $1.id }
        sheet.rebakeAllEditablePins(context: context)
        sheet.placeableObjects = context.view == nil ? unplacedPinObjects(unit: unit) : []
        sheet.recomputePoolEditorBounds()
        return sheet
    }

    /// The symbol with its drawing and pins taken back from the sheet; in a
    /// text-placement view only that view's text placements change.
    func applying(sheet: HorizontalSchematicSheet, view: HorizontalSymbolTextPlacementView? = nil) -> HorizontalPoolSymbol {
        var symbol = self
        if let view {
            var placements = correctedTextPlacements
            var viewPlacements = placements[view.key] ?? [:]
            for text in sheet.texts where drawing.texts[text.id] != nil {
                let placed = HorizontalPlacementTransform(shift: text.position, angle: text.angle, mirrored: text.mirrored)
                viewPlacements[text.id] = view.transform.textPlacement(undoing: placed)
            }
            placements[view.key] = viewPlacements
            symbol.textPlacements = placements
            symbol.textPlacementsAreLegacy = false
            return symbol
        }
        symbol.drawing = sheet.poolDrawing(original: drawing)
        symbol.pins = Dictionary(uniqueKeysWithValues: sheet.editablePins.map { ($0.id, $0) })
        return symbol
    }

    /// The symbol without any orientation-specific placements for `view`.
    func clearingTextPlacements(for view: HorizontalSymbolTextPlacementView) -> HorizontalPoolSymbol {
        var symbol = self
        var placements = correctedTextPlacements
        placements.removeValue(forKey: view.key)
        symbol.textPlacements = placements
        symbol.textPlacementsAreLegacy = false
        return symbol
    }

    /// `ToolChangeUnit`: keep pins whose primary name exists in the new unit,
    /// under the new unit's pin ids; drop the rest.
    func changingUnit(to unit: HorizontalPoolUnit, from oldUnit: HorizontalPoolUnit?) -> HorizontalPoolSymbol {
        var symbol = self
        symbol.unitID = unit.uuid
        var remapped = [String: HorizontalSymbolPin]()
        let newPinsByName = Dictionary(unit.pins.values.map { ($0.primaryName, $0.id) }, uniquingKeysWith: { first, _ in first })
        for (pinID, pin) in pins {
            let name = oldUnit?.pins.values.first { $0.id.lowercased() == pinID.lowercased() }?.primaryName
            guard let name, let newID = newPinsByName[name] else {
                continue
            }
            var moved = pin
            moved.id = newID
            remapped[newID] = moved
        }
        symbol.pins = remapped
        return symbol
    }
}

// MARK: - Frame

extension HorizontalPoolFrame {
    /// The frame as a sheet: its drawing plus the page border the width and
    /// height imply, drawn as frame lines so it cannot be selected.
    func makeSheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(
            id: uuid,
            name: name,
            gridSpacing: HorizontalSchematicEditorProfile.frame.gridSpacing ?? 1_250_000
        )
        sheet.loadPoolDrawing(drawing)
        sheet.frameLines = Self.borderLines(width: width, height: height)
        sheet.recomputePoolEditorBounds()
        return sheet
    }

    static func borderLines(width: Double, height: Double) -> [HorizontalSegment] {
        [
            HorizontalSegment(id: "frame/border/bottom", from: .zero, to: HorizontalPoint(x: width, y: 0), width: 0, layer: 0),
            HorizontalSegment(id: "frame/border/right", from: HorizontalPoint(x: width, y: 0), to: HorizontalPoint(x: width, y: height), width: 0, layer: 0),
            HorizontalSegment(id: "frame/border/top", from: HorizontalPoint(x: width, y: height), to: HorizontalPoint(x: 0, y: height), width: 0, layer: 0),
            HorizontalSegment(id: "frame/border/left", from: HorizontalPoint(x: 0, y: height), to: .zero, width: 0, layer: 0),
        ]
    }

    func applying(sheet: HorizontalSchematicSheet) -> HorizontalPoolFrame {
        var frame = self
        frame.drawing = sheet.poolDrawing(original: drawing)
        return frame
    }
}

extension HorizontalPlacementTransform {
    /// The child placement that `accumulatedText(with:)` turned into
    /// `result` under this parent transform — the inverse the text-placement
    /// editor needs to store what the user dragged.
    func textPlacement(undoing result: HorizontalPlacementTransform) -> HorizontalPlacementTransform {
        // accumulatedText: anchor = mirrorX(rotate(child.shift, angle)) + shift
        var point = result.shift - shift
        if mirrored {
            point.x = -point.x
        }
        let unrotated = HorizontalPlacementTransform(shift: .zero, angle: -angle, mirrored: false).applying(to: point)
        let childMirrored = result.mirrored != mirrored
        let parentTerm = mirrored ? -angle : angle
        var childAngle = result.angle - parentTerm
        if result.mirrored {
            childAngle = 32_768 - childAngle
        }
        childAngle = ((childAngle % 65_536) + 65_536) % 65_536
        return HorizontalPlacementTransform(
            shift: HorizontalPoint(x: unrotated.x.rounded(), y: unrotated.y.rounded()),
            angle: childAngle,
            mirrored: childMirrored
        )
    }
}
