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

/// Horizon's sheet warnings, derived from electrical endpoints rather than artwork overlap.
enum HorizontalSchematicWarnings {
    static func evaluate(_ sheet: HorizontalSchematicSheet, allSheets: [HorizontalSchematicSheet] = []) -> [HorizontalCanvasWarning] {
        func key(_ point: HorizontalPoint) -> String { HorizontalCanvasModeSupport.pointKey(point) }
        var warnings: [String: HorizontalCanvasWarning] = [:]
        func warn(_ point: HorizontalPoint, _ message: String) {
            let id = key(point)
            if warnings[id] == nil { warnings[id] = .init(position: point, messages: []) }
            if warnings[id]?.messages.contains(message) == false { warnings[id]?.messages.append(message) }
        }
        func contains(_ point: HorizontalPoint, _ line: HorizontalSegment) -> Bool {
            let vector = line.to - line.from
            let offset = point - line.from
            return point.x >= min(line.from.x, line.to.x) && point.x <= max(line.from.x, line.to.x)
                && point.y >= min(line.from.y, line.to.y) && point.y <= max(line.from.y, line.to.y)
                && abs(vector.x * offset.y - vector.y * offset.x) < 1
        }
        func pinEndpoint(_ pin: HorizontalSegment) -> HorizontalSchematicEndpoint? {
            let parts = pin.id.lowercased().split(separator: "/")
            guard parts.count >= 3, parts[1] == "pin" else { return nil }
            return .pin("\(parts[0])/\(parts[2])")
        }
        func connected(_ pin: HorizontalSegment, _ line: HorizontalSegment) -> Bool {
            guard let endpoint = pinEndpoint(pin) else { return false }
            if line.schematicFrom == endpoint || line.schematicTo == endpoint { return true }
            // Newly drawn wires have coordinates until the next save/reload.
            return (line.schematicFrom == nil && key(line.from) == key(pin.from))
                || (line.schematicTo == nil && key(line.to) == key(pin.from))
        }
        let junctionKeys = Set(sheet.junctions.values.map(key))
        var pinKeys = Set<String>()
        for pin in sheet.symbolPins {
            guard pinEndpoint(pin) != nil else { continue }
            if !pinKeys.insert(key(pin.from)).inserted { warn(pin.from, "Pin on pin") }
            if junctionKeys.contains(key(pin.from)) { warn(pin.from, "Pin on junction") }
            let lines = sheet.netLines.filter { connected(pin, $0) }
            if lines.isEmpty, let netID = pin.netID {
                warn(pin.from, "Pin connected to net: \(sheet.netDetails[netID]?.name ?? netID)")
            }
            if sheet.netLines.contains(where: { contains(pin.from, $0) && !connected(pin, $0) }) {
                warn(pin.from, "Pin on line")
            }
        }
        for port in sheet.blockSymbolPorts {
            let parts = port.id.lowercased().split(separator: "/")
            guard parts.count >= 3, parts[1] == "block-port", let netID = port.netID else { continue }
            let endpoint = HorizontalSchematicEndpoint.port("\(parts[0])/\(parts[2])")
            if !sheet.netLines.contains(where: {
                $0.schematicFrom == endpoint || $0.schematicTo == endpoint
                    || ($0.schematicFrom == nil && key($0.from) == key(port.from))
                    || ($0.schematicTo == nil && key($0.to) == key(port.from))
            }) { warn(port.from, "Port connected to net: \(sheet.netDetails[netID]?.name ?? netID)") }
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
            let fromNet = sheet.junctions.first { key($0.value) == key(tie.from) }.flatMap { sheet.junctionNetIDs[$0.key] }
            let toNet = sheet.junctions.first { key($0.value) == key(tie.to) }.flatMap { sheet.junctionNetIDs[$0.key] }
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
            if !points.isEmpty { warn(HorizontalRect(points: points).center, "Missing ports: " + names.joined(separator: " ")) }
        }

        // Connected components retain distinct coincident pin and junction nodes.
        var neighbors: [HorizontalSchematicEndpoint: Set<HorizontalSchematicEndpoint>] = [:]
        var positions: [HorizontalSchematicEndpoint: HorizontalPoint] = [:]
        var netIDs: [HorizontalSchematicEndpoint: String] = [:]
        func endpoint(_ stored: HorizontalSchematicEndpoint?, at point: HorizontalPoint) -> HorizontalSchematicEndpoint {
            stored ?? sheet.junctions.first { key($0.value) == key(point) }.map { .junction($0.key) }
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
        for root in positions.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            guard !visited.contains(root) else { continue }
            var pending = [root]
            var nodes = Set<HorizontalSchematicEndpoint>()
            while let node = pending.popLast() {
                guard nodes.insert(node).inserted else { continue }
                pending.append(contentsOf: neighbors[node] ?? [])
            }
            visited.formUnion(nodes)
            guard let netID = nodes.compactMap({ netIDs[$0] }).sorted().first else { continue }
            let labels = sheet.netLabels.filter { nodes.contains(endpoint($0.junctionID.map { .junction($0) }, at: $0.position)) }
            let power = sheet.powerSymbols.contains { nodes.contains(.junction($0.junctionID)) }
            let ripper = nodes.contains { if case .busRipper = $0 { return true }; return false }
            segments.append(.init(position: positions[root] ?? .zero, netID: netID,
                                  hasLabel: !labels.isEmpty || power || ripper, hasPower: power))
        }
        let duplicateNames = Set(Dictionary(grouping: sheet.netDetails.values.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, by: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }).values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        let segmentsByNet = Dictionary(grouping: segments, by: \.netID)
        let portLabelNetIDs = Set((allSheets.isEmpty ? [sheet] : allSheets).flatMap { $0.netLabels }
            .filter { $0.showsPort }.compactMap(\.netID))
        for segment in segments {
            guard let net = sheet.netDetails[segment.netID] else { continue }
            if !net.name.isEmpty && !segment.hasLabel { warn(segment.position, "Label missing") }
            if net.isPower && !segment.hasPower { warn(segment.position, "Power sym missing") }
            if net.name.isEmpty && (segmentsByNet[net.id]?.count ?? 0) > 1 && !segment.hasLabel {
                warn(segment.position, "Ambiguous nets")
            }
            if duplicateNames.contains(net.id) { warn(segment.position, "Duplicate net name") }
            if net.isPort && !portLabelNetIDs.contains(net.id) {
                warn(segment.position, "Need 'show port' net label")
            }
        }
        let duplicateRefdes = Set(Dictionary(grouping: sheet.componentInfo.values.filter {
            !$0.refdes.isEmpty && !$0.refdes.hasSuffix("?")
        }, by: \.refdes).filter { $0.value.count > 1 }.keys)
        for symbol in sheet.symbols {
            if let componentID = symbol.componentID, let refdes = sheet.componentInfo[componentID]?.refdes,
               duplicateRefdes.contains(refdes) { warn(symbol.position, "Duplicate refdes \(refdes)") }
        }
        return warnings.values.sorted { $0.id < $1.id }.map { warning in
            var result = warning
            result.messages.sort()
            return result
        }
    }
}
