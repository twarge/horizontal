import Foundation

/// Horizon's place-net-label tool (`ToolPlaceNetLabel`) as a model pass the
/// canvas runs on its draft. The label in hand stands on a junction of its
/// own that follows the cursor; a click hangs it on what is under it:
///
/// - a junction: the label goes onto that junction (not a bus's);
/// - an unconnected pin: a wire from the pin to the label, which stands
///   1.25 mm out from the pin in the way it reads, on a new net;
/// - a wire: the wire is split there and the label is on its net (not on a
///   bus line);
/// - anything else: the label is left where it is, on no net, for a wire to
///   reach later.
///
/// The canvas then runs the same wiring upkeep the wire tool does, which
/// merges the label's junction into the one it was put on, gives a pin its
/// new net and spreads the net to the label.
extension HorizontalSchematicSheet {
    /// Horizon's `ToolHelperDrawNetSetting` default label size.
    static let netLabelDefaultSize: Double = 1_500_000
    /// How far out from a pin `ToolPlaceNetLabel` stands a label it wires.
    static let netLabelPinOffset: Double = 1_250_000

    /// What a click with the tool lands on.
    enum NetLabelTarget: Equatable {
        case junction(id: String, point: HorizontalPoint)
        case pin(SchematicPinRef, point: HorizontalPoint)
        case netLine(index: Int)
        case nothing
        /// Nothing is placed, for this reason.
        case refused(String)
    }

    /// Puts the label in hand on the sheet: a junction on no net at `point`
    /// and the label standing on it.
    mutating func addNetLabelInHand(
        labelID: String,
        junctionID: String,
        at point: HorizontalPoint,
        orientation: String,
        size: Double = netLabelDefaultSize
    ) {
        junctions[junctionID] = point
        junctionNetIDs.removeValue(forKey: junctionID)
        netLabels.append(HorizontalSchematicNetLabel(
            id: labelID,
            text: netLabelText(forNet: nil, showsPort: false),
            position: point,
            size: size,
            orientation: orientation,
            netID: nil,
            junctionID: junctionID
        ))
    }

    /// Moves the label in hand to `point`. It reads the net it would be put
    /// on there, so the cursor shows what a click would label.
    mutating func moveNetLabelInHand(labelID: String, junctionID: String, to point: HorizontalPoint, tolerance: Double) {
        guard let index = netLabels.firstIndex(where: { $0.id == labelID }) else { return }
        junctions[junctionID] = point
        netLabels[index].position = point
        netLabels[index].text = netLabelText(
            forNet: netLabelTargetNet(netLabelTarget(at: point, tolerance: tolerance, excludingJunction: junctionID)),
            showsPort: false
        )
    }

    /// What is under `point`, nearest kind first as Horizon's hover target
    /// would be: a junction, a pin, then a wire running through the point.
    func netLabelTarget(at point: HorizontalPoint, tolerance: Double, excludingJunction ownJunctionID: String) -> NetLabelTarget {
        var nearest: (id: String, point: HorizontalPoint, distance: Double)?
        for (id, position) in junctions where id != ownJunctionID {
            let distance = (position - point).length
            guard distance <= tolerance, nearest.map({ distance < $0.distance }) ?? true else { continue }
            nearest = (id, position, distance)
        }
        if let nearest {
            if isBusJunction(nearest.id, at: nearest.point) {
                return .refused("Can't label a bus junction; a bus label names a bus")
            }
            return .junction(id: nearest.id, point: nearest.point)
        }

        var nearestPin: (pin: SchematicPinRef, point: HorizontalPoint, distance: Double)?
        for stem in symbolPins {
            guard let pin = SchematicPinRef(stemID: stem.id), stem.id.split(separator: "/").count == 3 else { continue }
            let distance = (stem.from - point).length
            guard distance <= tolerance, nearestPin.map({ distance < $0.distance }) ?? true else { continue }
            nearestPin = (pin, stem.from, distance)
        }
        if let nearestPin {
            if connection(of: nearestPin.pin) != nil {
                return .refused("Pin is already connected; label its wire instead")
            }
            return .pin(nearestPin.pin, point: nearestPin.point)
        }

        if let index = netLines.firstIndex(where: { Self.lies(point, inside: $0) }) {
            if isBusLine(netLines[index]) {
                return .refused("Can't put a net label on a bus line")
            }
            return .netLine(index: index)
        }
        return .nothing
    }

    /// The net a label put on `target` would show, as far as the sheet
    /// knows before the wiring upkeep runs.
    func netLabelTargetNet(_ target: NetLabelTarget) -> String? {
        switch target {
        case .junction(let id, _):
            return junctionNetIDs[id] ?? netLines.first { line in
                line.schematicFrom == .junction(id.lowercased()) || line.schematicTo == .junction(id.lowercased())
            }?.netID
        case .netLine(let index):
            return netLines[index].netID
        case .pin, .nothing, .refused:
            return nil
        }
    }

    /// The click: hangs the label in hand on `target`. Returns why nothing
    /// was placed, or nil when the label was placed.
    mutating func dropNetLabel(labelID: String, junctionID: String, on target: NetLabelTarget) -> String? {
        guard let index = netLabels.firstIndex(where: { $0.id == labelID }),
              let point = junctions[junctionID] else {
            return "Nothing to place"
        }
        switch target {
        case .refused(let reason):
            return reason
        case .nothing:
            break
        case .junction(_, let at):
            // Onto the junction's point: the upkeep merges the two junctions
            // into the one the label holds, with the other's net and wires.
            junctions[junctionID] = at
            netLabels[index].position = at
        case .pin(let pin, let pinPoint):
            let at = pinPoint + Self.netLabelOffset(for: netLabels[index].orientation)
            junctions[junctionID] = at
            netLabels[index].position = at
            netLines.append(HorizontalSegment(
                id: UUID().uuidString.lowercased(),
                from: pinPoint,
                to: at,
                width: 0,
                layer: nil,
                schematicFrom: .pin(pin.path),
                schematicTo: .junction(junctionID)
            ))
        case .netLine(let lineIndex):
            let line = netLines[lineIndex]
            var first = line
            first.to = point
            first.schematicTo = .junction(junctionID)
            var second = line
            second.id = UUID().uuidString.lowercased()
            second.from = point
            second.schematicFrom = .junction(junctionID)
            netLines[lineIndex] = first
            netLines.insert(second, at: lineIndex + 1)
            if let netID = line.netID {
                junctionNetIDs[junctionID] = netID
                netLabels[index].netID = netID
                netLabels[index].text = netLabelText(forNet: netID, showsPort: false)
            }
        }
        return nil
    }

    /// The bus ripper tool's mark in hand, drawn as a placed ripper is: its
    /// foot at `point`, the member's name over its connector. Replaces the
    /// drawing of the one with this id, so it moves and turns.
    mutating func setBusRipperInHand(id: String, memberName: String, at point: HorizontalPoint, orientation: String) {
        let drawn = HorizontalSchematic.busRipperArtwork(id: id, junction: point, orientation: orientation, memberName: memberName)
        busRipperLines.removeAll { $0.id == drawn.line.id }
        busRipperTexts.removeAll { $0.id == "\(id)/bus-ripper-text" }
        busRipperLines.append(drawn.line)
        if let text = drawn.text {
            busRipperTexts.append(text)
        }
    }

    /// Where `ToolPlaceNetLabel` stands a label off a pin: out the way the
    /// label reads.
    static func netLabelOffset(for orientation: String) -> HorizontalPoint {
        switch orientation {
        case "left": HorizontalPoint(x: -netLabelPinOffset, y: 0)
        case "up": HorizontalPoint(x: 0, y: netLabelPinOffset)
        case "down": HorizontalPoint(x: 0, y: -netLabelPinOffset)
        default: HorizontalPoint(x: netLabelPinOffset, y: 0)
        }
    }

    /// A bus's junction: one the bus is drawn through, or a bus label or
    /// ripper stands on.
    private func isBusJunction(_ id: String, at point: HorizontalPoint) -> Bool {
        if warningContext.junctionBusIDs[id] != nil || warningContext.junctionBusIDs[id.lowercased()] != nil {
            return true
        }
        let key = HorizontalCanvasModeSupport.pointKey(point)
        return busLabels.contains { HorizontalCanvasModeSupport.pointKey($0.position) == key }
            || busRipperLines.contains { HorizontalCanvasModeSupport.pointKey($0.from) == key }
    }

    /// A bus line: a wire on no net between a bus's junctions.
    private func isBusLine(_ line: HorizontalSegment) -> Bool {
        guard line.netID == nil else { return false }
        for (endpoint, point) in [(line.schematicFrom, line.from), (line.schematicTo, line.to)] {
            if case .junction(let id)? = endpoint, isBusJunction(id, at: point) { return true }
        }
        return false
    }

    /// Whether `point` lies on `line` short of its ends, in whole nanometres
    /// as Horizon's `coord_on_line` tests it.
    static func lies(_ point: HorizontalPoint, inside line: HorizontalSegment) -> Bool {
        let (ax, ay) = (Int64(line.from.x.rounded()), Int64(line.from.y.rounded()))
        let (bx, by) = (Int64(line.to.x.rounded()), Int64(line.to.y.rounded()))
        let (px, py) = (Int64(point.x.rounded()), Int64(point.y.rounded()))
        guard px >= min(ax, bx), px <= max(ax, bx), py >= min(ay, by), py <= max(ay, by),
              !(px == ax && py == ay), !(px == bx && py == by) else { return false }
        let (left, leftOverflow) = (bx - ax).multipliedReportingOverflow(by: py - ay)
        let (right, rightOverflow) = (by - ay).multipliedReportingOverflow(by: px - ax)
        return !leftOverflow && !rightOverflow && left == right
    }
}
