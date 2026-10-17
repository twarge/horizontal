import Foundation

struct HorizontalCanvasWarning: Identifiable, Hashable {
    var position: HorizontalPoint
    var messages: [String]
    var id: String { HorizontalCanvasModeSupport.pointKey(position) }
}

struct HorizontalSchematicWarningContext: Hashable {
    struct BusRipper: Hashable {
        var junctionID: String
        var busID: String
    }
    var junctionBusIDs: [String: String] = [:]
    var busRippers: [String: BusRipper] = [:]
    var missingPorts: [String: [String]] = [:]
}

/// One of Horizon's sheet warnings where the canvas draws it, with what it is
/// about: `check` reports these one by one.
struct HorizontalSchematicWarningFinding: Hashable {
    var position: HorizontalPoint
    /// What the canvas says, e.g. "Pin connected to net: VDD".
    var message: String
    /// The message without what it names ("Pin connected to net"), which
    /// findings of one kind share.
    var title: String
    /// The net a warning about a net is about.
    var netID: String? = nil
    /// The component whose pin or symbol it is about.
    var componentID: String? = nil
    /// The pin's primary name, for a warning about a pin.
    var pinName: String? = nil
}

/// Horizon's sheet warnings, derived from electrical endpoints rather than artwork overlap.
enum HorizontalSchematicWarnings {
    /// The warnings as the canvas draws them: one marker per point, carrying
    /// every message found there.
    static func evaluate(_ sheet: HorizontalSchematicSheet, allSheets: [HorizontalSchematicSheet] = []) -> [HorizontalCanvasWarning] {
        var warnings: [String: HorizontalCanvasWarning] = [:]
        for finding in findings(sheet, allSheets: allSheets) {
            let id = HorizontalCanvasModeSupport.pointKey(finding.position)
            if warnings[id] == nil { warnings[id] = .init(position: finding.position, messages: []) }
            warnings[id]?.messages.append(finding.message)
        }
        return warnings.values.sorted { $0.id < $1.id }.map { warning in
            var result = warning
            result.messages.sort()
            return result
        }
    }

    /// Every warning on the sheet, once per point and message, in the order
    /// found. `allSheets` is the block's sheets, for the warnings that look
    /// across them (a port net's "show port" label may be on another page).
    static func findings(_ sheet: HorizontalSchematicSheet, allSheets: [HorizontalSchematicSheet] = []) -> [HorizontalSchematicWarningFinding] {
        func key(_ point: HorizontalPoint) -> String { HorizontalCanvasModeSupport.pointKey(point) }
        var found: [HorizontalSchematicWarningFinding] = []
        var seen = Set<String>()
        func warn(_ point: HorizontalPoint, _ message: String, title: String? = nil, net: String? = nil, component: String? = nil,
                  pin: String? = nil) {
            guard seen.insert(key(point) + "|" + message).inserted else { return }
            found.append(.init(position: point, message: message, title: title ?? message, netID: net, componentID: component, pinName: pin))
        }
        let symbolsByID = Dictionary(sheet.symbols.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func symbol(of pin: HorizontalSegment) -> HorizontalPlacement? {
            pin.id.lowercased().split(separator: "/").first.flatMap { symbolsByID[String($0)] }
        }
        func component(of pin: HorizontalSegment) -> String? { symbol(of: pin)?.componentID }
        func name(of pin: HorizontalSegment) -> String? {
            let parts = pin.id.lowercased().split(separator: "/")
            guard parts.count >= 3 else { return nil }
            let pinID = String(parts[2])
            return symbol(of: pin)?.symbolPinNames.first { $0.id.lowercased() == pinID }?.primaryName
        }
        /// Horizon's `LineNet::coord_on_line`: on the wire but not at either
        /// end, so a wire ending at a junction on a pin is "Pin on junction"
        /// alone.
        func liesWithin(_ point: HorizontalPoint, _ line: HorizontalSegment) -> Bool {
            let vector = line.to - line.from
            let offset = point - line.from
            return key(point) != key(line.from) && key(point) != key(line.to)
                && point.x >= min(line.from.x, line.to.x) && point.x <= max(line.from.x, line.to.x)
                && point.y >= min(line.from.y, line.to.y) && point.y <= max(line.from.y, line.to.y)
                && abs(vector.x * offset.y - vector.y * offset.x) < 1
        }
        func pinEndpoint(_ pin: HorizontalSegment) -> HorizontalSchematicEndpoint? {
            let parts = pin.id.lowercased().split(separator: "/")
            guard parts.count >= 3, parts[1] == "pin" else { return nil }
            return .pin("\(parts[0])/\(parts[2])")
        }
        var junctionKeyByID = [String: String]()
        for (id, point) in sheet.junctions { junctionKeyByID[id.lowercased()] = key(point) }
        /// The end as the writer will store it: an end naming a junction that
        /// is no longer at that point is bare, and goes by its coordinates.
        func storedEnd(_ endpoint: HorizontalSchematicEndpoint?, at point: HorizontalPoint) -> HorizontalSchematicEndpoint? {
            if case .junction(let id) = endpoint, junctionKeyByID[id.lowercased()] != key(point) { return nil }
            return endpoint
        }
        /// Whether `line` ends on the pin at `endpoint`, whose point is `pointKey`.
        func connected(_ endpoint: HorizontalSchematicEndpoint, _ pointKey: String, _ line: HorizontalSegment) -> Bool {
            let from = storedEnd(line.schematicFrom, at: line.from), to = storedEnd(line.schematicTo, at: line.to)
            if from == endpoint || to == endpoint { return true }
            // Newly drawn wires have coordinates until the next save/reload.
            return (from == nil && key(line.from) == pointKey)
                || (to == nil && key(line.to) == pointKey)
        }
        // Every wire end at once, so whether any wire ends on a pin or port is
        // a lookup rather than a pass over the wires for each one.
        var storedEnds = Set<HorizontalSchematicEndpoint>()
        var bareEndKeys = Set<String>()
        for line in sheet.netLines {
            if let from = storedEnd(line.schematicFrom, at: line.from) { storedEnds.insert(from) } else { bareEndKeys.insert(key(line.from)) }
            if let to = storedEnd(line.schematicTo, at: line.to) { storedEnds.insert(to) } else { bareEndKeys.insert(key(line.to)) }
        }
        func anyWireEnds(on endpoint: HorizontalSchematicEndpoint, at pointKey: String) -> Bool {
            storedEnds.contains(endpoint) || bareEndKeys.contains(pointKey)
        }
        let junctionKeys = Set(sheet.junctions.values.map(key))
        // The junction at a point, the first `junctions` gives where several
        // share one, as a scan of it would find.
        var junctionAt = [String: String]()
        for (id, point) in sheet.junctions where junctionAt[key(point)] == nil {
            junctionAt[key(point)] = id
        }
        var pinKeys = Set<String>()
        for pin in sheet.symbolPins {
            guard let endpoint = pinEndpoint(pin) else { continue }
            let pointKey = key(pin.from)
            if !pinKeys.insert(pointKey).inserted { warn(pin.from, "Pin on pin", component: component(of: pin), pin: name(of: pin)) }
            if junctionKeys.contains(pointKey) { warn(pin.from, "Pin on junction", component: component(of: pin), pin: name(of: pin)) }
            if !anyWireEnds(on: endpoint, at: pointKey), let netID = pin.netID {
                warn(pin.from, "Pin connected to net: \(sheet.netDetails[netID]?.name ?? netID)", title: "Pin connected to net",
                     net: netID, component: component(of: pin), pin: name(of: pin))
            }
            if sheet.netLines.contains(where: { liesWithin(pin.from, $0) && !connected(endpoint, pointKey, $0) }) {
                warn(pin.from, "Pin on Line", component: component(of: pin), pin: name(of: pin))
            }
        }
        for port in sheet.blockSymbolPorts {
            let parts = port.id.lowercased().split(separator: "/")
            guard parts.count >= 3, parts[1] == "block-port", let netID = port.netID else { continue }
            let endpoint = HorizontalSchematicEndpoint.port("\(parts[0])/\(parts[2])")
            if !anyWireEnds(on: endpoint, at: key(port.from)) {
                warn(port.from, "Port connected to net: \(sheet.netDetails[netID]?.name ?? netID)", title: "Port connected to net", net: netID)
            }
        }
        for line in sheet.netLines where key(line.from) == key(line.to) { warn(line.from, "Zero length line") }

        let electricalKeys = Set(sheet.netLines.flatMap { [key($0.from), key($0.to)] }
            + sheet.netLabels.map { key($0.position) } + sheet.busLabels.map { key($0.position) }
            + sheet.busRipperLines.flatMap { [key($0.from), key($0.to)] }
            + sheet.powerSymbols.compactMap { sheet.junctions[$0.junctionID].map(key) })
        for line in sheet.drawingLines {
            for point in [line.from, line.to] where electricalKeys.contains(key(point)) {
                warn(point, "Graphic line connected to junction with net/bus")
            }
        }
        for arc in sheet.drawingArcs {
            for point in [arc.from, arc.to] where electricalKeys.contains(key(point)) {
                warn(point, "Arc connected to junction with net/bus")
            }
        }
        for tie in sheet.netTies {
            let center = (tie.from + tie.to) * 0.5
            if key(tie.from) == key(tie.to) { warn(center, "Zero length net tie") }
            let fromNet = junctionAt[key(tie.from)].flatMap { sheet.junctionNetIDs[$0] }
            let toNet = junctionAt[key(tie.to)].flatMap { sheet.junctionNetIDs[$0] }
            if !tie.netIDs.isEmpty && (fromNet == toNet || Set([fromNet, toNet].compactMap { $0 }) != tie.netIDs) {
                warn(center, "Net tie connected to incorrect net")
            }
        }
        for ripper in sheet.warningContext.busRippers.values {
            if sheet.warningContext.junctionBusIDs[ripper.junctionID] != ripper.busID,
               let point = sheet.junctions[ripper.junctionID] { warn(point, "Bus ripper connected to wrong net line") }
        }
        for (id, names) in sheet.warningContext.missingPorts {
            let points = sheet.blockSymbolLines.filter { $0.id.hasPrefix("\(id)/") }.flatMap { [$0.from, $0.to] }
                + sheet.blockSymbolPorts.filter { $0.id.hasPrefix("\(id)/") }.map(\.from)
                + sheet.blockSymbolTexts.filter { $0.id.hasPrefix("\(id)/") }.map(\.position)
            if !points.isEmpty { warn(HorizontalRect(points: points).center, "Missing ports: " + names.joined(separator: " "), title: "Missing ports") }
        }

        // Connected components retain distinct coincident pin and junction nodes.
        var neighbors: [HorizontalSchematicEndpoint: Set<HorizontalSchematicEndpoint>] = [:]
        var positions: [HorizontalSchematicEndpoint: HorizontalPoint] = [:]
        var netIDs: [HorizontalSchematicEndpoint: String] = [:]
        func endpoint(_ stored: HorizontalSchematicEndpoint?, at point: HorizontalPoint) -> HorizontalSchematicEndpoint {
            stored ?? junctionAt[key(point)].map { .junction($0) }
                ?? .junction("coordinate:\(key(point))")
        }
        for (id, point) in sheet.junctions {
            let node = HorizontalSchematicEndpoint.junction(id)
            positions[node] = point
            netIDs[node] = sheet.junctionNetIDs[id]
        }
        for line in sheet.netLines {
            let from = endpoint(line.schematicFrom, at: line.from)
            let to = endpoint(line.schematicTo, at: line.to)
            neighbors[from, default: []].insert(to)
            neighbors[to, default: []].insert(from)
            positions[from] = line.from
            positions[to] = line.to
            if let netID = line.netID { netIDs[from] = netID; netIDs[to] = netID }
        }
        struct Segment {
            var position: HorizontalPoint
            var netID: String
            var hasLabel: Bool
            var hasPower: Bool
        }
        var segments: [Segment] = []
        var visited = Set<HorizontalSchematicEndpoint>()
        let labelNodes = Set(sheet.netLabels.map { endpoint($0.junctionID.map { .junction($0) }, at: $0.position) })
        let powerNodes = Set(sheet.powerSymbols.map { HorizontalSchematicEndpoint.junction($0.junctionID) })
        // Each node's description once, rather than twice per comparison.
        let roots = positions.keys.map { (String(describing: $0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        for root in roots {
            guard !visited.contains(root) else { continue }
            var pending = [root]
            var nodes = Set<HorizontalSchematicEndpoint>()
            while let node = pending.popLast() {
                guard nodes.insert(node).inserted else { continue }
                pending.append(contentsOf: neighbors[node] ?? [])
            }
            visited.formUnion(nodes)
            guard let netID = nodes.compactMap({ netIDs[$0] }).sorted().first else { continue }
            let labelled = !nodes.isDisjoint(with: labelNodes)
            let power = !nodes.isDisjoint(with: powerNodes)
            let ripper = nodes.contains { if case .busRipper = $0 { return true }; return false }
            segments.append(.init(position: positions[root] ?? .zero, netID: netID,
                                  hasLabel: labelled || power || ripper, hasPower: power))
        }
        let duplicateNames = Set(Dictionary(grouping: sheet.netDetails.values.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, by: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }).values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        let segmentsByNet = Dictionary(grouping: segments, by: \.netID)
        let portLabelNetIDs = Set((allSheets.isEmpty ? [sheet] : allSheets).flatMap { $0.netLabels }
            .filter { $0.showsPort }.compactMap(\.netID))
        for segment in segments {
            guard let net = sheet.netDetails[segment.netID] else { continue }
            if !net.name.isEmpty && !segment.hasLabel { warn(segment.position, "Label missing", net: net.id) }
            if net.isPower && !segment.hasPower { warn(segment.position, "Power sym missing", net: net.id) }
            if net.name.isEmpty && (segmentsByNet[net.id]?.count ?? 0) > 1 && !segment.hasLabel {
                warn(segment.position, "Ambiguous nets", net: net.id)
            }
            if duplicateNames.contains(net.id) { warn(segment.position, "Duplicate net name", net: net.id) }
            if net.isPort && !portLabelNetIDs.contains(net.id) {
                warn(segment.position, "Need 'show port' net label", net: net.id)
            }
        }
        let duplicateRefdes = Set(Dictionary(grouping: sheet.componentInfo.values.filter {
            !$0.refdes.isEmpty && !$0.refdes.hasSuffix("?")
        }, by: \.refdes).filter { $0.value.count > 1 }.keys)
        for symbol in sheet.symbols {
            if let componentID = symbol.componentID, let refdes = sheet.componentInfo[componentID]?.refdes,
               duplicateRefdes.contains(refdes) { warn(symbol.position, "Duplicate refdes \(refdes)", title: "Duplicate refdes", component: componentID) }
        }
        return found
    }
}
