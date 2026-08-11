import Foundation

/// Pure schematic move/connectivity logic extracted from `SchematicCanvasView`.
/// Stateless and dependency-minimal — takes the sheet collections it needs (not
/// the 53-field `HorizontalSchematicSheet`), so it's unit-testable without a sheet
/// fixture. `SchematicCanvasView` delegates via thin wrappers, so behavior is
/// unchanged. Uses the shared `HorizontalCanvasModeSupport.pointKey` so point
/// bucketing matches the rest of the canvas.
enum SchematicMovePlanner {
    /// All selectable refs whose geometry touches `point` (so they move together
    /// when a connected object is dragged). Power-symbol anchors are pre-resolved
    /// by the caller (symbolID → anchor points) to keep this dependency-minimal.
    /// Mirrors the former `SchematicCanvasView.schematicConnectionAffectedRefs`.
    static func connectionAffectedRefs(
        at point: HorizontalPoint,
        netLines: [HorizontalSegment],
        drawingLines: [HorizontalSegment],
        drawingArcs: [HorizontalArc],
        busRipperLines: [HorizontalSegment],
        netTies: [HorizontalSchematicNetTie],
        netLabels: [HorizontalSchematicNetLabel],
        busLabels: [HorizontalBusLabel],
        junctions: [String: HorizontalPoint],
        powerSymbolAnchors: [String: [HorizontalPoint]]
    ) -> Set<HorizontalSelectableRef> {
        func key(_ p: HorizontalPoint) -> String { HorizontalCanvasModeSupport.pointKey(p) }
        let target = key(point)
        var refs = Set<HorizontalSelectableRef>()

        for line in netLines where key(line.from) == target || key(line.to) == target {
            refs.insert(HorizontalSelectableRef(id: line.id, type: .lineNet))
        }
        for line in drawingLines where key(line.from) == target || key(line.to) == target {
            refs.insert(HorizontalSelectableRef(id: line.id, type: .drawingLine))
        }
        for arc in drawingArcs where key(arc.from) == target || key(arc.to) == target || key(arc.center) == target {
            refs.insert(HorizontalSelectableRef(id: arc.id, type: .drawingArc))
        }
        for line in busRipperLines where key(line.from) == target || key(line.to) == target {
            if let ripperID = schematicMetalObjectIDPrefix(in: line.id, separators: ["line", "text"])
                ?? line.id.lowercased().split(separator: "/").first.map(String.init) {
                refs.insert(HorizontalSelectableRef(id: ripperID, type: .busRipper))
            }
        }
        for tie in netTies where key(tie.from) == target || key(tie.to) == target {
            refs.insert(HorizontalSelectableRef(id: tie.id, type: .schematicNetTie))
        }
        for label in netLabels where key(label.position) == target {
            refs.insert(HorizontalSelectableRef(id: label.id, type: .netLabel))
        }
        for label in busLabels where key(label.position) == target {
            refs.insert(HorizontalSelectableRef(id: label.id, type: .busLabel))
        }
        for (junctionID, junction) in junctions where key(junction) == target {
            refs.insert(HorizontalSelectableRef(id: junctionID, type: .junction))
        }
        for (symbolID, anchors) in powerSymbolAnchors where anchors.contains(where: { key($0) == target }) {
            refs.insert(HorizontalSelectableRef(id: symbolID, type: .powerSymbol))
        }

        return refs
    }
}
