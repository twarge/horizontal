import Foundation

/// Horizon's `SchematicBlockSymbol`: one instance of another block, drawn on
/// a sheet with the symbol that block draws itself with. The sheet bakes it
/// into `blockSymbolLines`, `blockSymbolPorts` and `blockSymbolTexts` like
/// any other artwork; this is what that artwork was baked from, so an edit
/// can say where the symbol now sits and what its ports are wired to, and
/// bake it again.
///
/// Sendable by hand: the symbol's JSON is parsed once at load and only ever
/// replaced whole, never mutated in place, like every other value a sheet
/// holds.
struct HorizontalSchematicBlockSymbol: Identifiable, @unchecked Sendable {
    /// The `block_symbols` entry's uuid, lowercased: the owner prefix of
    /// every piece of its artwork.
    var id: String
    /// The block instance it draws, in the sheet's own block.
    var instanceID: String
    /// The block that instance uses.
    var blockID: String
    var refdes: String
    var placement: HorizontalPlacementTransform
    /// The instance's `connections`, by the used block's port net: a net of
    /// the sheet's block, or `.notConnected` for a port marked NC. A port
    /// with no entry is on no net yet.
    var connections: [String: SchematicConnectionState]
    /// The used block's name and nets, which name its ports.
    var resource: HorizontalSchematicBlockResource
    /// The used block's symbol, as its file holds it.
    var symbolJSON: JSONDictionary

    /// The ports the symbol draws, by port uuid: each one's port net in the
    /// used block.
    var portNets: [String: String] {
        symbolJSON.dictionaryMap("ports").reduce(into: [String: String]()) { result, item in
            if let net = item.value.string("net") {
                result[item.key.lowercased()] = net.lowercased()
            }
        }
    }

    func connection(ofPort portID: String) -> SchematicConnectionState? {
        portNets[portID.lowercased()].flatMap { connections[$0] }
    }

    /// The JSON the block instance holds for its connections.
    var connectionsJSON: JSONDictionary {
        connections.reduce(into: JSONDictionary()) { result, item in
            switch item.value {
            case .connected(let netID):
                result[item.key] = ["net": netID]
            case .notConnected:
                result[item.key] = ["net": NSNull()]
            }
        }
    }
}

/// Horizon's `BlockSymbolPort` ids. A block symbol's port is keyed by the
/// port net it draws, through a fixed namespace, so the same net names the
/// same port in every project and every program.
enum HorizontalBlockSymbolPortID {
    /// `BlockSymbolPort::get_uuid_for_net`'s namespace.
    static let namespace = UUID(uuidString: "8fd9cbab-73f6-4778-befe-a9a3369e7f0d")!

    /// The port uuid for `netID`, lowercased; nil when `netID` isn't a uuid.
    static func uuid(forNet netID: String) -> String? {
        guard let net = UUID(uuidString: netID) else {
            return nil
        }
        let bytes = withUnsafeBytes(of: net.uuid) { Array($0) }
        return UUID.horizonUUID5(namespace: namespace, name: bytes).uuidString.lowercased()
    }
}

/// What one block symbol bakes into on its sheet; see
/// `HorizontalSchematic.blockSymbolArtwork(for:)`.
struct HorizontalBlockSymbolArtwork {
    var lines: [HorizontalSegment] = []
    var ports: [HorizontalSegment] = []
    var texts: [HorizontalText] = []
    /// Where each port takes a wire, by `<block symbol>/<port>`.
    var portPositions: [String: HorizontalPoint] = [:]
    /// The used block's ports the symbol doesn't draw, by name.
    var missingPorts: [String] = []
}

extension HorizontalSchematicSheet {
    func blockSymbol(_ id: String) -> HorizontalSchematicBlockSymbol? {
        let id = id.lowercased()
        return blockSymbols.first { $0.id == id }
    }

    /// The block symbol drawing the instance `instanceID`, if this sheet has it.
    func blockSymbol(forInstance instanceID: String) -> HorizontalSchematicBlockSymbol? {
        let id = instanceID.lowercased()
        return blockSymbols.first { $0.instanceID == id }
    }

    /// Where each of a block symbol's ports takes a wire, by port uuid, with
    /// the net it is on.
    func blockSymbolPortEnds(_ id: String) -> [String: (point: HorizontalPoint, netID: String?)] {
        let prefix = id.lowercased() + "/block-port/"
        return blockSymbolPorts.reduce(into: [:]) { result, segment in
            let segmentID = segment.id.lowercased()
            guard segmentID.hasPrefix(prefix) else { return }
            let portID = String(segmentID.dropFirst(prefix.count))
            guard !portID.contains("/") else { return }
            result[portID] = (segment.from, segment.netID)
        }
    }

    /// Bakes a block symbol's artwork again from what it was baked from,
    /// in place of what it has: after its placement or its ports' nets
    /// changed.
    mutating func rebakeBlockSymbol(_ id: String) {
        guard let blockSymbol = blockSymbol(id) else {
            return
        }
        let prefix = blockSymbol.id + "/"
        blockSymbolLines.removeAll { $0.id.lowercased().hasPrefix(prefix) }
        blockSymbolPorts.removeAll { $0.id.lowercased().hasPrefix(prefix) }
        blockSymbolTexts.removeAll { $0.id.lowercased().hasPrefix(prefix) }
        let artwork = HorizontalSchematic.blockSymbolArtwork(for: blockSymbol)
        blockSymbolLines.append(contentsOf: artwork.lines)
        blockSymbolPorts.append(contentsOf: artwork.ports)
        blockSymbolTexts.append(contentsOf: artwork.texts)
        warningContext.missingPorts[blockSymbol.id] = artwork.missingPorts.isEmpty ? nil : artwork.missingPorts
    }

    /// Moves a block symbol's artwork and placement by `delta`. What is wired
    /// to its ports is the caller's to drag.
    mutating func shiftBlockSymbol(_ id: String, by delta: HorizontalPoint) {
        guard delta != .zero else {
            return
        }
        let id = id.lowercased()
        if let index = blockSymbols.firstIndex(where: { $0.id == id }) {
            blockSymbols[index].placement.shift = blockSymbols[index].placement.shift + delta
        }
        let prefix = id + "/"
        for i in blockSymbolLines.indices where blockSymbolLines[i].id.lowercased().hasPrefix(prefix) {
            blockSymbolLines[i] = HorizontalCanvasModeSupport.shifted(blockSymbolLines[i], by: delta)
        }
        for i in blockSymbolPorts.indices where blockSymbolPorts[i].id.lowercased().hasPrefix(prefix) {
            blockSymbolPorts[i] = HorizontalCanvasModeSupport.shifted(blockSymbolPorts[i], by: delta)
        }
        for i in blockSymbolTexts.indices where blockSymbolTexts[i].id.lowercased().hasPrefix(prefix) {
            blockSymbolTexts[i] = HorizontalCanvasModeSupport.shifted(blockSymbolTexts[i], by: delta)
        }
    }

    /// Places a block symbol as `placement` says and bakes it there. Returns
    /// where each port's wire end was and is now, for the caller to drag
    /// what is wired to it along.
    @discardableResult
    mutating func placeBlockSymbol(_ id: String, at placement: HorizontalPlacementTransform)
        -> [(from: HorizontalPoint, to: HorizontalPoint, netID: String?)] {
        guard let index = blockSymbols.firstIndex(where: { $0.id == id.lowercased() }) else {
            return []
        }
        let before = blockSymbolPortEnds(id)
        blockSymbols[index].placement = placement
        rebakeBlockSymbol(id)
        let after = blockSymbolPortEnds(id)
        return before.keys.sorted().compactMap { port in
            guard let old = before[port], let new = after[port] else { return nil }
            return (old.point, new.point, old.netID)
        }
    }

    /// Wires (or unwires) one port of a block symbol: `connection` nil takes
    /// the instance's connection away, as deleting the port's last wire
    /// does in Horizon. Every block symbol of the instance on this sheet
    /// follows.
    mutating func setBlockPortConnection(_ connection: SchematicConnectionState?, blockSymbol id: String, port portID: String) {
        guard let symbol = blockSymbol(id), let portNet = symbol.portNets[portID.lowercased()] else {
            return
        }
        for index in blockSymbols.indices where blockSymbols[index].instanceID == symbol.instanceID {
            blockSymbols[index].connections[portNet] = connection
            rebakeBlockSymbol(blockSymbols[index].id)
        }
    }

    /// Horizon's `Schematic::delete_net_line` for ports, as
    /// `disconnectPinsLeftWithoutWires` is for pins: a port whose last wire
    /// was deleted leaves its net, and the instance's connection goes.
    /// `netLinesBefore` is the sheet's wires before the delete.
    mutating func disconnectPortsLeftWithoutWires(netLinesBefore: [HorizontalSegment]) {
        let remainingIDs = Set(netLines.map { $0.id.lowercased() })
        let removedLines = netLinesBefore.filter { !remainingIDs.contains($0.id.lowercased()) }
        guard !removedLines.isEmpty, !blockSymbols.isEmpty else {
            return
        }
        let key = HorizontalCanvasModeSupport.pointKey
        var portAtPoint = [String: String]()
        for segment in blockSymbolPorts {
            let parts = segment.id.lowercased().split(separator: "/").map(String.init)
            if parts.count == 3, parts[1] == "block-port", portAtPoint[key(segment.from)] == nil {
                portAtPoint[key(segment.from)] = "\(parts[0])/\(parts[2])"
            }
        }
        func port(at endpoint: HorizontalSchematicEndpoint?, point: HorizontalPoint) -> String? {
            switch endpoint {
            case .port(let path):
                return path.lowercased()
            case nil:
                // A wire drawn since the last load has only coordinates.
                return portAtPoint[key(point)]
            default:
                return nil
            }
        }
        var ports = Set<String>()
        for line in removedLines {
            if let from = port(at: line.schematicFrom, point: line.from) { ports.insert(from) }
            if let to = port(at: line.schematicTo, point: line.to) { ports.insert(to) }
        }
        for path in ports.sorted() {
            let stillWired = netLines.contains {
                port(at: $0.schematicFrom, point: $0.from) == path || port(at: $0.schematicTo, point: $0.to) == path
            }
            let parts = path.split(separator: "/").map(String.init)
            guard !stillWired, parts.count == 2, case .connected? = blockPortConnection(path: path) else {
                continue
            }
            setBlockPortConnection(nil, blockSymbol: parts[0], port: parts[1])
        }
    }

    /// A port's connection by its wire endpoint path, `<block symbol>/<port>`.
    func blockPortConnection(path: String) -> SchematicConnectionState? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return blockSymbol(parts[0])?.connection(ofPort: parts[1])
    }
}
