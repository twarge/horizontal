import Foundation

/// Horizon's wire tidy-up after an edit (`Sheet::delete_duplicate_net_lines`
/// then `Sheet::simplify_net_lines`, which `Schematic::expand` runs after
/// every tool): a wire whose two ends are the same connection goes, a second
/// wire between the same two connections goes, and two collinear wires that
/// meet at a junction holding nothing else become one wire. Straightening a
/// jog by moving a label onto the corner therefore leaves no zero-length
/// wire behind. A zero-length wire between two different connections stays,
/// like the pin-to-junction wire Horizon keeps under a label sitting on a pin.
extension HorizontalSchematicSheet {
    struct NetLineCleanup: Equatable {
        var removedNetLineIDs: Set<String> = []
        var removedJunctionIDs: Set<String> = []
        var isEmpty: Bool { removedNetLineIDs.isEmpty && removedJunctionIDs.isEmpty }
    }

    @discardableResult
    mutating func simplifyNetLines() -> NetLineCleanup {
        var cleanup = NetLineCleanup()
        deleteDuplicateNetLines(&cleanup)
        mergeCollinearNetLines(&cleanup)
        return cleanup
    }

    /// What a wire end is connected to, resolved the way the project writer
    /// resolves it: the stored endpoint while it still sits at the end's
    /// coordinates, else the junction there, else the pin there.
    private enum NetLineConnection: Hashable {
        case endpoint(HorizontalSchematicEndpoint)
        case point(String)

        var junctionID: String? {
            if case .endpoint(.junction(let id)) = self { return id }
            return nil
        }
    }

    private struct NetLineConnectionPair: Hashable {
        var from: NetLineConnection
        var to: NetLineConnection
    }

    private static func key(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
    }

    private static func pinPath(_ pin: HorizontalSegment) -> String? {
        let parts = pin.id.lowercased().split(separator: "/")
        guard parts.count >= 3, parts[1] == "pin" else { return nil }
        return "\(parts[0])/\(parts[2])"
    }

    private struct NetLineResolver {
        var junctionsByID: [String: HorizontalPoint] = [:]
        var junctionIDByPoint: [String: String] = [:]
        var pinPointsByPath: [String: Set<String>] = [:]
        var pinPathByPoint: [String: String] = [:]

        init(_ sheet: HorizontalSchematicSheet) {
            for id in sheet.junctions.keys.sorted() {
                guard let point = sheet.junctions[id] else { continue }
                let normalized = id.lowercased()
                junctionsByID[normalized] = point
                if junctionIDByPoint[HorizontalSchematicSheet.key(point)] == nil {
                    junctionIDByPoint[HorizontalSchematicSheet.key(point)] = normalized
                }
            }
            for pin in sheet.symbolPins {
                guard let path = HorizontalSchematicSheet.pinPath(pin) else { continue }
                let point = HorizontalSchematicSheet.key(pin.from)
                pinPointsByPath[path, default: []].insert(point)
                if pinPathByPoint[point] == nil { pinPathByPoint[point] = path }
            }
        }

        func connection(at point: HorizontalPoint, stored: HorizontalSchematicEndpoint?) -> NetLineConnection {
            let pointKey = HorizontalSchematicSheet.key(point)
            switch stored {
            case .junction(let id):
                let normalized = id.lowercased()
                if let position = junctionsByID[normalized], HorizontalSchematicSheet.key(position) == pointKey {
                    return .endpoint(.junction(normalized))
                }
            case .pin(let path):
                if pinPointsByPath[path.lowercased()]?.contains(pointKey) == true {
                    return .endpoint(.pin(path.lowercased()))
                }
            case .port(let id):
                return .endpoint(.port(id.lowercased()))
            case .busRipper(let id):
                return .endpoint(.busRipper(id.lowercased()))
            case nil:
                break
            }
            if let id = junctionIDByPoint[pointKey] { return .endpoint(.junction(id)) }
            if let path = pinPathByPoint[pointKey] { return .endpoint(.pin(path)) }
            return .point(pointKey)
        }

        func connections(_ line: HorizontalSegment) -> NetLineConnectionPair {
            .init(from: connection(at: line.from, stored: line.schematicFrom),
                  to: connection(at: line.to, stored: line.schematicTo))
        }
    }

    private mutating func deleteDuplicateNetLines(_ cleanup: inout NetLineCleanup) {
        let resolver = NetLineResolver(self)
        var seen = Set<NetLineConnectionPair>()
        var touchedJunctionIDs = Set<String>()
        netLines.removeAll { line in
            let pair = resolver.connections(line)
            let reversed = NetLineConnectionPair(from: pair.to, to: pair.from)
            guard pair.from == pair.to || seen.contains(pair) else {
                seen.insert(pair)
                seen.insert(reversed)
                return false
            }
            cleanup.removedNetLineIDs.insert(line.id)
            touchedJunctionIDs.formUnion([pair.from.junctionID, pair.to.junctionID].compactMap { $0 })
            return true
        }
        // Horizon vacuums junctions left holding nothing; only sweep the ones
        // this pass emptied so an untouched sheet keeps its stray junctions.
        guard !touchedJunctionIDs.isEmpty else { return }
        let remaining = NetLineResolver(self)
        let referenced = Set(netLines.flatMap { line -> [String] in
            let pair = remaining.connections(line)
            return [pair.from.junctionID, pair.to.junctionID].compactMap { $0 }
        })
        for junctionID in touchedJunctionIDs.subtracting(referenced) {
            guard let key = junctions.keys.first(where: { $0.lowercased() == junctionID }),
                  let point = junctions[key],
                  junctionHoldsOnlyNetLines(key, at: point) else { continue }
            removeJunction(key, &cleanup)
        }
    }

    private mutating func mergeCollinearNetLines(_ cleanup: inout NetLineCleanup) {
        while mergeOneCollinearPair(&cleanup) {}
    }

    private mutating func mergeOneCollinearPair(_ cleanup: inout NetLineCleanup) -> Bool {
        let resolver = NetLineResolver(self)
        let pairs = netLines.map(resolver.connections)
        var endsByJunction: [String: [(line: Int, isFrom: Bool)]] = [:]
        for (index, pair) in pairs.enumerated() {
            if let id = pair.from.junctionID { endsByJunction[id, default: []].append((index, true)) }
            if let id = pair.to.junctionID { endsByJunction[id, default: []].append((index, false)) }
        }
        for junctionID in endsByJunction.keys.sorted() {
            guard let ends = endsByJunction[junctionID], ends.count == 2, ends[0].line != ends[1].line,
                  let key = junctions.keys.first(where: { $0.lowercased() == junctionID }),
                  let point = junctions[key],
                  junctionHoldsOnlyNetLines(key, at: point) else { continue }
            let a = netLines[ends[0].line]
            let b = netLines[ends[1].line]
            guard Self.isCollinear(a.to - a.from, b.to - b.from) else { continue }

            // `a` takes over `b`'s far end, then `b` and the junction go.
            let farPoint = ends[1].isFrom ? b.to : b.from
            let farEndpoint = ends[1].isFrom ? b.schematicTo : b.schematicFrom
            var merged = a
            if ends[0].isFrom {
                merged.from = farPoint
                merged.schematicFrom = farEndpoint
            } else {
                merged.to = farPoint
                merged.schematicTo = farEndpoint
            }
            merged.netID = a.netID ?? b.netID
            netLines[ends[0].line] = merged
            netLines.remove(at: ends[1].line)
            cleanup.removedNetLineIDs.insert(b.id)
            removeJunction(key, &cleanup)

            let mergedPair = NetLineResolver(self).connections(merged)
            if mergedPair.from == mergedPair.to {
                netLines.removeAll { $0.id == merged.id }
                cleanup.removedNetLineIDs.insert(merged.id)
            }
            return true
        }
        return false
    }

    private static func isCollinear(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Bool {
        let (ax, ay) = (Int64(a.x.rounded()), Int64(a.y.rounded()))
        let (bx, by) = (Int64(b.x.rounded()), Int64(b.y.rounded()))
        let (left, leftOverflow) = ax.multipliedReportingOverflow(by: by)
        let (right, rightOverflow) = ay.multipliedReportingOverflow(by: bx)
        return !leftOverflow && !rightOverflow && left == right
    }

    /// Horizon's `only_net_lines_connected`. Net labels and power symbols
    /// hold their junction by id. Bus labels, ties, rippers, graphics and
    /// unanchored labels hold whichever junction sits at their position, so
    /// they only keep this one while no other junction shares its point.
    private func junctionHoldsOnlyNetLines(_ junctionID: String, at point: HorizontalPoint) -> Bool {
        let id = junctionID.lowercased()
        if netLabels.contains(where: { $0.junctionID?.lowercased() == id }) { return false }
        if powerSymbols.contains(where: { $0.junctionID.lowercased() == id }) { return false }
        let pointKey = Self.key(point)
        if junctions.contains(where: { $0.key.lowercased() != id && Self.key($0.value) == pointKey }) { return true }
        func at(_ other: HorizontalPoint) -> Bool { Self.key(other) == pointKey }
        return !netLabels.contains(where: { $0.junctionID == nil && at($0.position) })
            && !busLabels.contains(where: { at($0.position) })
            && !netTies.contains(where: { at($0.from) || at($0.to) })
            && !busRipperLines.contains(where: { at($0.from) || at($0.to) })
            && !drawingLines.contains(where: { at($0.from) || at($0.to) })
            && !drawingArcs.contains(where: { at($0.from) || at($0.to) || at($0.center) })
    }

    private mutating func removeJunction(_ key: String, _ cleanup: inout NetLineCleanup) {
        junctions.removeValue(forKey: key)
        junctionNetIDs.removeValue(forKey: key)
        warningContext.junctionBusIDs.removeValue(forKey: key)
        cleanup.removedJunctionIDs.insert(key)
    }
}
