import Foundation

/// Pure schematic move/connectivity logic extracted from `SchematicCanvasView`.
/// Stateless queries and edits shared by previews and committed moves.
/// Uses the shared `HorizontalCanvasModeSupport.pointKey` so point
/// bucketing matches the rest of the canvas.
enum SchematicMovePlanner {
    /// Give a pin-mounted label its own junction and a real pin-to-junction wire.
    /// Keeping both endpoint identities matters even when their coordinates coincide.
    static func preparePinLabels(
        selected: [HorizontalSelectableRef],
        fixedPointKeys: Set<String>,
        sheet: inout HorizontalSchematicSheet
    ) {
        let selectedIDs = Set(selected.filter { $0.type == .netLabel }.map { $0.id.lowercased() })
        func key(_ point: HorizontalPoint) -> String { HorizontalCanvasModeSupport.pointKey(point) }
        for index in sheet.netLabels.indices where selectedIDs.contains(sheet.netLabels[index].id.lowercased()) {
            let label = sheet.netLabels[index]
            let anchorKey = key(label.position)
            guard fixedPointKeys.contains(anchorKey),
                  let pin = sheet.symbolPins.first(where: {
                      key($0.from) == anchorKey && ($0.netID == nil || $0.netID?.lowercased() == label.netID?.lowercased())
                  }) else { continue }
            let parts = pin.id.lowercased().split(separator: "/")
            guard parts.count >= 3, parts[1] == "pin" else { continue }
            let pinEndpoint = HorizontalSchematicEndpoint.pin("\(parts[0])/\(parts[2])")
            let junctionID = label.junctionID ?? sheet.junctions.first { key($0.value) == anchorKey }?.key
            if let junctionID,
               !sheet.netLabels.contains(where: { $0.id != label.id && !selectedIDs.contains($0.id.lowercased()) && $0.junctionID == junctionID }),
               !sheet.powerSymbols.contains(where: { $0.junctionID == junctionID }),
               !sheet.busLabels.contains(where: { key($0.position) == anchorKey }),
               !sheet.busRipperLines.contains(where: { key($0.from) == anchorKey || key($0.to) == anchorKey }),
               !sheet.netTies.contains(where: { key($0.from) == anchorKey || key($0.to) == anchorKey }),
               !sheet.drawingLines.contains(where: { key($0.from) == anchorKey || key($0.to) == anchorKey }),
               !sheet.drawingArcs.contains(where: { key($0.from) == anchorKey || key($0.to) == anchorKey || key($0.center) == anchorKey }),
               let lineIndex = sheet.netLines.firstIndex(where: {
                   ($0.schematicFrom == pinEndpoint && $0.schematicTo == .junction(junctionID))
                       || ($0.schematicTo == pinEndpoint && $0.schematicFrom == .junction(junctionID))
                       || ($0.schematicFrom == nil && $0.schematicTo == nil && key($0.from) == anchorKey && key($0.to) == anchorKey && $0.netID == label.netID)
               }) {
                sheet.netLabels[index].junctionID = junctionID
                if sheet.netLines[lineIndex].schematicFrom == nil {
                    sheet.netLines[lineIndex].schematicFrom = pinEndpoint
                    sheet.netLines[lineIndex].schematicTo = .junction(junctionID)
                }
                continue
            }
            let canReuseJunction = junctionID != nil
                && !sheet.netLines.contains { key($0.from) == anchorKey || key($0.to) == anchorKey }
                && !sheet.netLabels.contains { $0.id != label.id && key($0.position) == anchorKey }
                && !sheet.busLabels.contains { key($0.position) == anchorKey }
                && !sheet.powerSymbols.contains { $0.junctionID == junctionID }
                && !sheet.drawingLines.contains { key($0.from) == anchorKey || key($0.to) == anchorKey }
                && !sheet.drawingArcs.contains { key($0.from) == anchorKey || key($0.to) == anchorKey || key($0.center) == anchorKey }
                && !sheet.netTies.contains { key($0.from) == anchorKey || key($0.to) == anchorKey }
                && !sheet.busRipperLines.contains { key($0.from) == anchorKey || key($0.to) == anchorKey }
            let newJunctionID = (canReuseJunction ? junctionID : nil) ?? UUID().uuidString.lowercased()
            sheet.junctions[newJunctionID] = label.position
            sheet.junctionNetIDs[newJunctionID] = label.netID
            sheet.netLabels[index].junctionID = newJunctionID
            sheet.netLines.append(.init(id: UUID().uuidString.lowercased(), from: label.position, to: label.position,
                                       width: 0, layer: nil, netID: label.netID,
                                       schematicFrom: pinEndpoint, schematicTo: .junction(newJunctionID)))
        }
    }

    static func movePinLabels(
        at point: HorizontalPoint,
        by delta: HorizontalPoint,
        selected: [HorizontalSelectableRef],
        sheet: inout HorizontalSchematicSheet
    ) {
        guard delta != .zero else { return }
        let selectedIDs = Set(selected.filter { $0.type == .netLabel }.map { $0.id.lowercased() })
        let key = HorizontalCanvasModeSupport.pointKey(point)
        let junctionIDs = Set(sheet.netLabels.compactMap { label -> String? in
            guard selectedIDs.contains(label.id.lowercased()),
                  HorizontalCanvasModeSupport.pointKey(label.position) == key,
                  let id = label.junctionID,
                  sheet.netLines.contains(where: {
                      ($0.schematicFrom == .junction(id) && $0.schematicTo?.isPin == true)
                          || ($0.schematicTo == .junction(id) && $0.schematicFrom?.isPin == true)
                  }) else { return nil }
            return id
        })
        for id in junctionIDs { sheet.junctions[id] = point + delta }
        for index in sheet.netLabels.indices where sheet.netLabels[index].junctionID.map(junctionIDs.contains) == true {
            sheet.netLabels[index].position = point + delta
        }
        for index in sheet.netLines.indices {
            if case .junction(let id) = sheet.netLines[index].schematicFrom, junctionIDs.contains(id) {
                sheet.netLines[index].from = point + delta
            }
            if case .junction(let id) = sheet.netLines[index].schematicTo, junctionIDs.contains(id) {
                sheet.netLines[index].to = point + delta
            }
        }
    }

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
