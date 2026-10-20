import Foundation

/// The upkeep Horizon does on a sheet's wiring after a tool commits, which the
/// canvas runs after a move, a rotation, a wire drawn or a delete:
///
/// - `ToolHelperMerge::merge_and_connect`: junctions an edit put on one point
///   become one, and a junction put on a pin hands its wires to the pin, which
///   connects the pin.
/// - `ToolHelperMerge::merge_nets`: when that joins two nets, one is merged
///   into the other by Horizon's rules (`netMergeVerdict`), asking when both
///   have names. The caller resolves `netConflicts` and calls `mergeNet`.
/// - `Schematic::expand_connectivity`: whatever is joined to a net is on it.
/// - `Sheet::fix_junctions`, then `delete_duplicate_net_lines` and
///   `simplify_net_lines` (`simplifyNetLines`): a wire with a junction or pin
///   of its own net partway along it is split there, so wires laid over each
///   other heal into one and a wire ending on another's side makes a T with a
///   dot; the duplicates that leaves go, and straight runs join up again.
///
/// Horizon splits a wire only at a junction of the same net segment. This
/// splits at one of the same net, so two runs of one net that an edit laid
/// over each other become one segment too. Wires of different nets that
/// touch are left alone, as in Horizon: they cross, and the canvas draws a
/// hop where they do.
extension HorizontalSchematicSheet {
    /// A placed symbol's pin, as a wire's stored endpoint names it.
    struct SchematicPinRef: Hashable {
        var symbolID: String
        var pinID: String

        var path: String { "\(symbolID)/\(pinID)" }

        /// The pin a stem segment (`<symbol>/pin/<pin>`) draws.
        init?(stemID: String) {
            let parts = stemID.lowercased().split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[1] == "pin" else { return nil }
            self.init(symbolID: parts[0], pinID: parts[2])
        }

        init(symbolID: String, pinID: String) {
            self.symbolID = symbolID.lowercased()
            self.pinID = pinID.lowercased()
        }

        init?(path: String) {
            let parts = path.lowercased().split(separator: "/").map(String.init)
            guard parts.count == 2 else { return nil }
            self.init(symbolID: parts[0], pinID: parts[1])
        }
    }

    /// Two nets an edit joined and what Horizon does about it.
    enum NetMergeVerdict: Equatable {
        /// Merge `from` into `into`; `from` is gone afterwards.
        case merge(from: String, into: String)
        /// Both are named: the user picks which name stays (or neither).
        case ask(String, String)
        /// Horizon refuses, with the message its tool bar flashes.
        case refuse(String)
    }

    private static func key(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
    }

    // MARK: - Pins

    /// The placed pins whose connection point is at `point`.
    func schematicPins(at point: HorizontalPoint) -> [SchematicPinRef] {
        let pointKey = Self.key(point)
        return symbolPins.compactMap { segment in
            Self.key(segment.from) == pointKey ? SchematicPinRef(stemID: segment.id) : nil
        }
    }

    /// Where the block records a pin's connection: its component and the
    /// gate/pin path.
    func connectionPath(of pin: SchematicPinRef) -> (componentID: String, gatePinPath: String)? {
        guard let symbol = symbols.first(where: { $0.id.lowercased() == pin.symbolID }),
              let componentID = symbol.componentID?.lowercased(),
              let gateID = symbol.gateID?.lowercased() else {
            return nil
        }
        return (componentID, "\(gateID)/\(pin.pinID)")
    }

    /// The pin's connection: a net, not connected (Horizon's NC), or nil for
    /// a pin on no net yet.
    func connection(of pin: SchematicPinRef) -> SchematicConnectionState? {
        guard let path = connectionPath(of: pin) else { return nil }
        return componentInfo[path.componentID]?.connections[path.gatePinPath]
    }

    /// `connection(of:)` for many pins: the symbols looked up once.
    private struct PinConnections {
        private var gates: [String: (componentID: String, gateID: String)] = [:]
        private let componentInfo: [String: SchematicComponentInfo]

        init(_ sheet: HorizontalSchematicSheet) {
            componentInfo = sheet.componentInfo
            for symbol in sheet.symbols {
                guard let componentID = symbol.componentID?.lowercased(), let gateID = symbol.gateID?.lowercased() else { continue }
                gates[symbol.id.lowercased()] = (componentID, gateID)
            }
        }

        func connection(of pin: SchematicPinRef) -> SchematicConnectionState? {
            guard let gate = gates[pin.symbolID] else { return nil }
            return componentInfo[gate.componentID]?.connections["\(gate.gateID)/\(pin.pinID)"]
        }
    }

    /// Puts a pin on `netID` as Horizon records it: the component's
    /// connection, the net on the pin's artwork, and the connector mark
    /// redrawn (no open box any more).
    mutating func connectPin(_ pin: SchematicPinRef, toNet netID: String) {
        guard let path = connectionPath(of: pin), componentInfo[path.componentID] != nil else { return }
        componentInfo[path.componentID]?.connections[path.gatePinPath] = .connected(netID)
        if var removed = removedConnections[path.componentID], removed.remove(path.gatePinPath) != nil {
            removedConnections[path.componentID] = removed.isEmpty ? nil : removed
        }
        func isPinGeometry(_ id: String) -> Bool {
            schematicMetalSymbolID(forGeometryID: id) == pin.symbolID
                && Self.editorPinID(forGeometryID: id) == pin.pinID
        }
        for index in symbolPins.indices where isPinGeometry(symbolPins[index].id) {
            symbolPins[index].netID = netID
        }
        for index in symbolPinCircles.indices where isPinGeometry(symbolPinCircles[index].id) {
            symbolPinCircles[index].netID = netID
        }
        for index in symbolTexts.indices where isPinGeometry(symbolTexts[index].id) {
            symbolTexts[index].netID = netID
        }
        rebakePinConnector(symbolID: pin.symbolID, pinID: pin.pinID)
    }

    /// A new net with no name, as Horizon's `Block::insert_net` makes one.
    mutating func insertUnnamedNet() -> String {
        let netID = UUID().uuidString.lowercased()
        netDetails[netID] = HorizontalNetDetails(
            id: netID,
            name: "",
            netClassID: netClasses.first?.id,
            netClassName: netClasses.first?.name
        )
        return netID
    }

    // MARK: - Merging nets

    /// A net is bussed when a bus carries it.
    private func isBussed(_ netID: String) -> Bool {
        busDetails.contains { bus in bus.members.contains { $0.netID?.lowercased() == netID } }
    }

    private func isNamed(_ netID: String) -> Bool {
        !(netDetails[netID]?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The name a message gives a net.
    func displayName(ofNet netID: String) -> String {
        let name = netDetails[netID.lowercased()]?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "unnamed net" : name
    }

    /// `ToolHelperMerge::merge_nets(net, into)`: whether `net` can merge into
    /// `into`, and which way round. A bussed, power or port net survives the
    /// merge; two of a kind cannot merge; a named net survives an unnamed one,
    /// and two named ones are the user's call. `preferring` names nets the
    /// edit made itself, which give way to an existing net when neither has
    /// a name, so that net needs no rewriting elsewhere.
    func netMergeVerdict(_ rawNet: String, into rawInto: String, preferring newNetIDs: Set<String> = []) -> NetMergeVerdict {
        var net = rawNet.lowercased()
        var into = rawInto.lowercased()
        let netDetail = netDetails[net]
        let intoDetail = netDetails[into]
        let netPower = netDetail?.isPower == true, intoPower = intoDetail?.isPower == true
        let netPort = netDetail?.isPort == true, intoPort = intoDetail?.isPort == true
        let netBussed = isBussed(net), intoBussed = isBussed(into)

        if netBussed || intoBussed {
            if netPower || intoPower { return .refuse("Can't merge a power net and a bussed net") }
            if netBussed && intoBussed { return .refuse("Can't merge bussed nets") }
            if netPort || intoPort { return .refuse("Can't merge a port net and a bussed net") }
            if netBussed { swap(&net, &into) }
        } else if netPower || intoPower {
            if netPower && intoPower { return .refuse("Can't merge power nets") }
            if netPort || intoPort { return .refuse("Can't merge a port net and a power net") }
            if netPower { swap(&net, &into) }
        } else if netPort || intoPort {
            if netPort && intoPort { return .refuse("Can't merge port nets") }
            if netPort { swap(&net, &into) }
        } else if isNamed(net) && isNamed(into) {
            return .ask(net, into)
        } else if isNamed(net) {
            swap(&net, &into)
        } else if !isNamed(into), newNetIDs.contains(into), !newNetIDs.contains(net) {
            swap(&net, &into)
        }
        return .merge(from: net, into: into)
    }

    /// Horizon's `Block::merge_nets` as far as a sheet carries the block:
    /// everything this sheet draws on `from` moves to `into`, every
    /// component's connections with it, and `from` is gone from the block
    /// when the sheet is saved. Other sheets are the caller's to rewrite.
    mutating func mergeNet(_ rawFrom: String, into rawInto: String) {
        let from = rawFrom.lowercased()
        let into = rawInto.lowercased()
        guard from != into else { return }
        func moved(_ netID: String?) -> String? {
            netID?.lowercased() == from ? into : netID
        }
        for index in netLines.indices { netLines[index].netID = moved(netLines[index].netID) }
        for (junctionID, netID) in junctionNetIDs where netID.lowercased() == from {
            junctionNetIDs[junctionID] = into
        }
        for index in powerSymbols.indices { powerSymbols[index].netID = moved(powerSymbols[index].netID) }
        for index in powerSymbolLines.indices { powerSymbolLines[index].netID = moved(powerSymbolLines[index].netID) }
        for index in powerSymbolCircles.indices { powerSymbolCircles[index].netID = moved(powerSymbolCircles[index].netID) }
        for index in powerSymbolTexts.indices { powerSymbolTexts[index].netID = moved(powerSymbolTexts[index].netID) }
        for index in symbolPins.indices { symbolPins[index].netID = moved(symbolPins[index].netID) }
        for index in symbolPinCircles.indices { symbolPinCircles[index].netID = moved(symbolPinCircles[index].netID) }
        for index in symbolTexts.indices { symbolTexts[index].netID = moved(symbolTexts[index].netID) }
        for index in blockSymbolPorts.indices { blockSymbolPorts[index].netID = moved(blockSymbolPorts[index].netID) }
        for index in blockSymbolLines.indices { blockSymbolLines[index].netID = moved(blockSymbolLines[index].netID) }
        for index in blockSymbolTexts.indices { blockSymbolTexts[index].netID = moved(blockSymbolTexts[index].netID) }
        for index in blockSymbols.indices {
            for (port, state) in blockSymbols[index].connections where state.netID?.lowercased() == from {
                blockSymbols[index].connections[port] = .connected(into)
            }
        }
        for index in busRipperLines.indices { busRipperLines[index].netID = moved(busRipperLines[index].netID) }
        for index in busRipperTexts.indices { busRipperTexts[index].netID = moved(busRipperTexts[index].netID) }
        for index in busLabels.indices { busLabels[index].netID = moved(busLabels[index].netID) }
        for index in netTies.indices where netTies[index].netIDs.contains(where: { $0.lowercased() == from }) {
            netTies[index].netIDs = Set(netTies[index].netIDs.map { $0.lowercased() == from ? into : $0 })
        }
        for busIndex in busDetails.indices {
            for memberIndex in busDetails[busIndex].members.indices {
                busDetails[busIndex].members[memberIndex].netID = moved(busDetails[busIndex].members[memberIndex].netID)
            }
        }
        for tieIndex in netTieDetails.indices {
            netTieDetails[tieIndex].primaryID = moved(netTieDetails[tieIndex].primaryID)
            netTieDetails[tieIndex].secondaryID = moved(netTieDetails[tieIndex].secondaryID)
        }
        for (componentID, var info) in componentInfo {
            var changed = false
            for (path, state) in info.connections where state.netID?.lowercased() == from {
                info.connections[path] = .connected(into)
                changed = true
            }
            if changed { componentInfo[componentID] = info }
        }
        for index in netLabels.indices where netLabels[index].netID?.lowercased() == from {
            netLabels[index].netID = into
            netLabels[index].text = netLabelText(forNet: into, showsPort: netLabels[index].showsPort)
        }
        netDetails.removeValue(forKey: from)
        removedNetIDs.insert(from)
        removedNetIDs.remove(into)
    }

    /// What a net label reads: the net's name, "? plz fix" without one, and
    /// the port direction in front when the label shows it. The off-sheet
    /// references come back with the next load.
    func netLabelText(forNet netID: String?, showsPort: Bool) -> String {
        let detail = netID.flatMap { netDetails[$0.lowercased()] }
        var text = detail?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { text = "? plz fix" }
        if showsPort, let detail, detail.isPort {
            text = "\(Self.portPrefix(for: detail.portDirection)): \(text)"
        }
        return text
    }

    private static func portPrefix(for direction: String?) -> String {
        switch direction {
        case "input": "IN"
        case "output": "OUT"
        case "open_collector": "OC"
        case "power_input": "PIN"
        case "power_output": "POUT"
        case "passive": "PASV"
        case "not_connected": "NC"
        default: "BIDI"
        }
    }

    // MARK: - Islands

    /// What wires join: a junction, a pin, a block port, a bus ripper, or a
    /// wire end on nothing.
    private enum Node: Hashable {
        case junction(String)
        case pin(String)
        case port(String)
        case busRipper(String)
        case free(String)
    }

    /// Resolves a wire's ends the way the project writer does: the stored
    /// endpoint while it is still where the end is, else the junction there,
    /// else the pin there.
    private struct Resolver {
        var junctionPositions: [String: HorizontalPoint] = [:]
        var junctionKeys: [String: String] = [:]
        var junctionAtPoint: [String: String] = [:]
        var pinPoint: [String: String] = [:]
        var pinAtPoint: [String: String] = [:]

        init(_ sheet: HorizontalSchematicSheet) {
            for id in sheet.junctions.keys.sorted() {
                guard let point = sheet.junctions[id] else { continue }
                let normalized = id.lowercased()
                junctionPositions[normalized] = point
                junctionKeys[normalized] = id
                let pointKey = HorizontalSchematicSheet.key(point)
                if junctionAtPoint[pointKey] == nil { junctionAtPoint[pointKey] = normalized }
            }
            for pin in sheet.symbolPins {
                guard let ref = SchematicPinRef(stemID: pin.id) else { continue }
                let pointKey = HorizontalSchematicSheet.key(pin.from)
                pinPoint[ref.path] = pointKey
                if pinAtPoint[pointKey] == nil { pinAtPoint[pointKey] = ref.path }
            }
        }

        func node(at point: HorizontalPoint, stored: HorizontalSchematicEndpoint?) -> Node {
            let pointKey = HorizontalSchematicSheet.key(point)
            switch stored {
            case .junction(let id):
                let normalized = id.lowercased()
                if let position = junctionPositions[normalized], HorizontalSchematicSheet.key(position) == pointKey {
                    return .junction(normalized)
                }
            case .pin(let path):
                if pinPoint[path.lowercased()] == pointKey { return .pin(path.lowercased()) }
            case .port(let path):
                return .port(path.lowercased())
            case .busRipper(let id):
                return .busRipper(id.lowercased())
            case nil:
                break
            }
            if let id = junctionAtPoint[pointKey] { return .junction(id) }
            if let path = pinAtPoint[pointKey] { return .pin(path) }
            return .free(pointKey)
        }

        /// The junction a label or power symbol hangs from.
        func junctionNode(id: String?, at point: HorizontalPoint) -> Node {
            if let id, junctionPositions[id.lowercased()] != nil { return .junction(id.lowercased()) }
            let pointKey = HorizontalSchematicSheet.key(point)
            if let id = junctionAtPoint[pointKey] { return .junction(id) }
            return .free(pointKey)
        }
    }

    /// One connected piece of wiring: what is in it and the nets they name.
    struct NetIsland {
        var nets: Set<String> = []
        var pointKeys: Set<String> = []
        var lineIndices: [Int] = []
        var junctionIDs: [String] = []
        var labelIndices: [Int] = []
        var pins: [SchematicPinRef] = []
        /// Block symbol ports, as `<block symbol>/<port>`.
        var ports: [String] = []
    }

    /// The sheet's wiring split into connected pieces, as Horizon's net
    /// segments: wires joined end to end through junctions, pins, ports and
    /// rippers, with the labels and power symbols on those junctions. Every
    /// net named anywhere in a piece is in its `nets`, so a piece naming two
    /// is one an edit joined and that still needs a merge.
    func netIslands() -> [NetIsland] {
        let resolver = Resolver(self)
        var parent = [Node: Node]()
        func root(_ node: Node) -> Node {
            var current = node
            while let next = parent[current], next != current { current = next }
            var walk = node
            while let next = parent[walk], next != current {
                parent[walk] = current
                walk = next
            }
            return current
        }
        func add(_ node: Node) {
            if parent[node] == nil { parent[node] = node }
        }
        func union(_ lhs: Node, _ rhs: Node) {
            add(lhs)
            add(rhs)
            let (a, b) = (root(lhs), root(rhs))
            if a != b { parent[b] = a }
        }

        var lineNodes = [Node]()
        for line in netLines {
            let from = resolver.node(at: line.from, stored: line.schematicFrom)
            let to = resolver.node(at: line.to, stored: line.schematicTo)
            union(from, to)
            lineNodes.append(from)
        }
        for id in junctions.keys { add(.junction(id.lowercased())) }
        var labelNodes = [Node]()
        for label in netLabels {
            let node = resolver.junctionNode(id: label.junctionID, at: label.position)
            add(node)
            labelNodes.append(node)
        }
        var powerNodes = [Node]()
        for symbol in powerSymbols {
            let point = junctions[symbol.junctionID] ?? junctions.first { $0.key.lowercased() == symbol.junctionID.lowercased() }?.value
            let node = point.map { resolver.junctionNode(id: symbol.junctionID, at: $0) } ?? .junction(symbol.junctionID.lowercased())
            add(node)
            powerNodes.append(node)
        }

        var islandIndex = [Node: Int]()
        var islands = [NetIsland]()
        func island(for node: Node) -> Int {
            let top = root(node)
            if let index = islandIndex[top] { return index }
            islandIndex[top] = islands.count
            islands.append(NetIsland())
            return islands.count - 1
        }
        func addNet(_ netID: String?, to index: Int) {
            if let netID, !netID.isEmpty { islands[index].nets.insert(netID.lowercased()) }
        }

        let pinConnections = PinConnections(self)
        var pinNets = [String: String]()
        for (index, line) in netLines.enumerated() {
            let islandID = island(for: lineNodes[index])
            islands[islandID].lineIndices.append(index)
            islands[islandID].pointKeys.insert(Self.key(line.from))
            islands[islandID].pointKeys.insert(Self.key(line.to))
            addNet(line.netID, to: islandID)
        }
        for node in Array(parent.keys) {
            let islandID = island(for: node)
            switch node {
            case .junction(let id):
                guard let key = resolver.junctionKeys[id] else { continue }
                islands[islandID].junctionIDs.append(key)
                if let point = junctions[key] { islands[islandID].pointKeys.insert(Self.key(point)) }
                addNet(junctionNetIDs[key], to: islandID)
            case .pin(let path):
                guard let pin = SchematicPinRef(path: path) else { continue }
                islands[islandID].pins.append(pin)
                if let point = resolver.pinPoint[path] { islands[islandID].pointKeys.insert(point) }
                if pinNets[path] == nil { pinNets[path] = pinConnections.connection(of: pin)?.netID ?? "" }
                addNet(pinNets[path], to: islandID)
            case .port(let path):
                islands[islandID].ports.append(path)
                addNet(portNetID(path), to: islandID)
            case .busRipper(let id):
                addNet(busRipperLines.first { schematicMetalGroupID($0.id) == id }?.netID, to: islandID)
            case .free(let pointKey):
                islands[islandID].pointKeys.insert(pointKey)
            }
        }
        for (index, label) in netLabels.enumerated() {
            let islandID = island(for: labelNodes[index])
            islands[islandID].labelIndices.append(index)
            addNet(label.netID, to: islandID)
        }
        for (index, symbol) in powerSymbols.enumerated() {
            addNet(symbol.netID, to: island(for: powerNodes[index]))
        }
        return islands
    }

    private func portNetID(_ path: String) -> String? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return blockSymbolPorts.first { $0.id.lowercased() == "\(parts[0])/block-port/\(parts[1])" }?.netID
    }

    private func schematicMetalGroupID(_ id: String) -> String {
        id.lowercased().split(separator: "/").first.map(String.init) ?? id.lowercased()
    }

    /// The nets each piece of wiring through `pointKeys` joins, where it
    /// joins more than one: the merges an edit needs before it can commit.
    func netConflicts(touching pointKeys: Set<String>) -> [Set<String>] {
        netIslands()
            .filter { $0.nets.count > 1 && !$0.pointKeys.isDisjoint(with: pointKeys) }
            .map(\.nets)
    }

    // MARK: - Connecting what an edit put down

    /// `ToolHelperMerge::merge_and_connect` at the points an edit touched:
    /// junctions there become one, and a junction on a pin that is not
    /// marked no-connect hands its wires to the pin (`replace_junction`), or
    /// gets a wire of no length to it when a label or power symbol holds it
    /// (`replace_junction_or_create_line`). Nets are left as they are; the
    /// pieces that now join two are `netConflicts`.
    mutating func connectCoincident(at pointKeys: Set<String>) {
        for pointKey in pointKeys.sorted() {
            mergeCoincidentJunctions(at: pointKey)
            handJunctionToPin(at: pointKey)
            handJunctionToPort(at: pointKey)
        }
    }

    /// `handJunctionToPin` for a block symbol's port: a junction on a port
    /// not marked NC hands its wires to the port, as Horizon's merge after a
    /// move replaces a junction with the port it lands on.
    private mutating func handJunctionToPort(at pointKey: String) {
        guard let junction = junctions.first(where: { Self.key($0.value) == pointKey }) else {
            return
        }
        var portPath: String?
        for segment in blockSymbolPorts where Self.key(segment.from) == pointKey {
            let parts = segment.id.lowercased().split(separator: "/").map(String.init)
            if parts.count == 3, parts[1] == "block-port" {
                portPath = "\(parts[0])/\(parts[2])"
                break
            }
        }
        guard let portPath else { return }
        if case .notConnected? = blockPortConnection(path: portPath) { return }
        let junctionID = junction.key.lowercased()
        func isOnJunction(_ endpoint: HorizontalSchematicEndpoint?, _ point: HorizontalPoint) -> Bool {
            if case .junction(let id) = endpoint { return id.lowercased() == junctionID }
            return endpoint == nil && Self.key(point) == pointKey
        }
        for index in netLines.indices {
            if isOnJunction(netLines[index].schematicFrom, netLines[index].from) {
                netLines[index].schematicFrom = .port(portPath)
            }
            if isOnJunction(netLines[index].schematicTo, netLines[index].to) {
                netLines[index].schematicTo = .port(portPath)
            }
        }
        netLines.removeAll { $0.schematicFrom == .port(portPath) && $0.schematicTo == .port(portPath) }
        if junctionIsHeld(junction.key) {
            netLines.append(HorizontalSegment(
                id: UUID().uuidString.lowercased(),
                from: junction.value,
                to: junction.value,
                width: 0,
                layer: nil,
                netID: junctionNetIDs[junction.key],
                schematicFrom: .junction(junction.key),
                schematicTo: .port(portPath)
            ))
        } else if !junctionHoldsAnything(junction.key, at: junction.value) {
            junctions.removeValue(forKey: junction.key)
            junctionNetIDs.removeValue(forKey: junction.key)
            warningContext.junctionBusIDs.removeValue(forKey: junction.key)
        }
    }

    private func junctionIsHeld(_ junctionID: String) -> Bool {
        let id = junctionID.lowercased()
        return netLabels.contains { $0.junctionID?.lowercased() == id }
            || powerSymbols.contains { $0.junctionID.lowercased() == id }
    }

    private mutating func mergeCoincidentJunctions(at pointKey: String) {
        let ids = junctions.filter { Self.key($0.value) == pointKey }.map(\.key).sorted()
        guard ids.count > 1 else { return }
        let keep = ids.first(where: junctionIsHeld) ?? ids.first(where: { junctionNetIDs[$0] != nil }) ?? ids[0]
        let removed = Set(ids.filter { $0 != keep }.map { $0.lowercased() })
        for index in netLines.indices {
            if case .junction(let id) = netLines[index].schematicFrom, removed.contains(id.lowercased()) {
                netLines[index].schematicFrom = .junction(keep)
            }
            if case .junction(let id) = netLines[index].schematicTo, removed.contains(id.lowercased()) {
                netLines[index].schematicTo = .junction(keep)
            }
        }
        for index in netLabels.indices where netLabels[index].junctionID.map({ removed.contains($0.lowercased()) }) == true {
            netLabels[index].junctionID = keep
        }
        for index in powerSymbols.indices where removed.contains(powerSymbols[index].junctionID.lowercased()) {
            powerSymbols[index].junctionID = keep
        }
        if junctionNetIDs[keep] == nil {
            junctionNetIDs[keep] = ids.compactMap { junctionNetIDs[$0] }.first
        }
        for id in ids where id != keep {
            junctions.removeValue(forKey: id)
            junctionNetIDs.removeValue(forKey: id)
            warningContext.junctionBusIDs.removeValue(forKey: id)
        }
    }

    private mutating func handJunctionToPin(at pointKey: String) {
        guard let junction = junctions.first(where: { Self.key($0.value) == pointKey }),
              let pinSegment = symbolPins.first(where: { Self.key($0.from) == pointKey && SchematicPinRef(stemID: $0.id) != nil }),
              let pin = SchematicPinRef(stemID: pinSegment.id),
              !isNoConnect(pin) else {
            return
        }
        let junctionID = junction.key.lowercased()
        func isOnJunction(_ endpoint: HorizontalSchematicEndpoint?, _ point: HorizontalPoint) -> Bool {
            if case .junction(let id) = endpoint { return id.lowercased() == junctionID }
            return endpoint == nil && Self.key(point) == pointKey
        }
        for index in netLines.indices {
            if isOnJunction(netLines[index].schematicFrom, netLines[index].from) {
                netLines[index].schematicFrom = .pin(pin.path)
            }
            if isOnJunction(netLines[index].schematicTo, netLines[index].to) {
                netLines[index].schematicTo = .pin(pin.path)
            }
        }
        // A wire whose both ends went to the pin is a loop on it.
        netLines.removeAll { $0.schematicFrom == .pin(pin.path) && $0.schematicTo == .pin(pin.path) }
        if junctionIsHeld(junction.key) {
            netLines.append(HorizontalSegment(
                id: UUID().uuidString.lowercased(),
                from: junction.value,
                to: junction.value,
                width: 0,
                layer: nil,
                netID: junctionNetIDs[junction.key],
                schematicFrom: .junction(junction.key),
                schematicTo: .pin(pin.path)
            ))
        } else if !junctionHoldsAnything(junction.key, at: junction.value) {
            junctions.removeValue(forKey: junction.key)
            junctionNetIDs.removeValue(forKey: junction.key)
            warningContext.junctionBusIDs.removeValue(forKey: junction.key)
        }
    }

    private func isNoConnect(_ pin: SchematicPinRef) -> Bool {
        if case .notConnected = connection(of: pin) { return true }
        return false
    }

    /// Whether anything other than wires uses a junction: graphics, bus
    /// labels and ties hold whichever junction sits under them.
    private func junctionHoldsAnything(_ junctionID: String, at point: HorizontalPoint) -> Bool {
        if junctionIsHeld(junctionID) { return true }
        let pointKey = Self.key(point)
        func at(_ other: HorizontalPoint) -> Bool { Self.key(other) == pointKey }
        return busLabels.contains { at($0.position) }
            || netTies.contains { at($0.from) || at($0.to) }
            || busRipperLines.contains { at($0.from) || at($0.to) }
            || drawingLines.contains { at($0.from) || at($0.to) }
            || drawingArcs.contains { at($0.from) || at($0.to) || at($0.center) }
    }

    // MARK: - Spreading nets

    /// `Schematic::expand_connectivity`: each piece of wiring naming exactly
    /// one net puts everything in it on that net — wires, junctions and
    /// labels, and, among the points an edit touched (`pointKeys`), pins
    /// wired in that are on no net yet. A touched piece that wires such a pin
    /// but names no net gets a new one, as Horizon gives a pin a net when a
    /// wire first reaches it. Pieces naming two nets are left alone; resolve
    /// them first. Nil `pointKeys` spreads nets over the whole sheet and
    /// connects no pins.
    mutating func spreadNets(touching pointKeys: Set<String>?) {
        for island in netIslands() {
            let touched = pointKeys.map { !island.pointKeys.isDisjoint(with: $0) } ?? false
            guard pointKeys == nil || touched, island.nets.count <= 1 else { continue }
            let unwiredPins = touched ? island.pins.filter { connection(of: $0) == nil && connectionPath(of: $0) != nil } : []
            // A port on no net is wired as a pin is (`ToolDrawLineNet`
            // gives the instance a connection); one marked NC never is.
            let unwiredPorts = touched ? island.ports.filter { blockPortConnection(path: $0) == nil } : []
            let netID: String
            if let existing = island.nets.first {
                netID = existing
            } else if !unwiredPins.isEmpty || !unwiredPorts.isEmpty {
                netID = insertUnnamedNet()
            } else {
                continue
            }
            for index in island.lineIndices where netLines[index].netID?.lowercased() != netID {
                netLines[index].netID = netID
            }
            for junctionID in island.junctionIDs where junctionNetIDs[junctionID]?.lowercased() != netID {
                junctionNetIDs[junctionID] = netID
            }
            for index in island.labelIndices where netLabels[index].netID?.lowercased() != netID {
                netLabels[index].netID = netID
                netLabels[index].text = netLabelText(forNet: netID, showsPort: netLabels[index].showsPort)
            }
            for pin in unwiredPins {
                connectPin(pin, toNet: netID)
            }
            for port in unwiredPorts {
                connectPort(port, toNet: netID)
            }
        }
    }

    /// Puts a block symbol's port, `<block symbol>/<port>`, on `netID`: the
    /// instance's connection, and the port's artwork drawn on it.
    mutating func connectPort(_ path: String, toNet netID: String) {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        setBlockPortConnection(.connected(netID.lowercased()), blockSymbol: parts[0], port: parts[1])
    }

    // MARK: - Healing wires

    /// Horizon's `fix_junctions`, then `simplifyNetLines`: a wire with a
    /// junction, pin or block port of its own net partway along it is split
    /// there, the duplicates that leaves are removed, and runs that are
    /// straight through a junction holding nothing else join up again.
    @discardableResult
    mutating func healNetLines() -> NetLineCleanup {
        let added = splitNetLinesAtOwnNetPoints()
        var cleanup = simplifyNetLines()
        cleanup.removedNetLineIDs.subtract(added)
        return cleanup
    }

    private struct SplitPoint {
        var point: HorizontalPoint
        var endpoint: HorizontalSchematicEndpoint
    }

    /// Splits each wire at the junctions, pins and ports of its net that lie
    /// inside it. Returns the ids of the wires it added.
    @discardableResult
    mutating func splitNetLinesAtOwnNetPoints() -> Set<String> {
        let resolver = Resolver(self)
        var junctionNet = [String: String]()
        for (id, netID) in junctionNetIDs { junctionNet[id.lowercased()] = netID.lowercased() }
        for line in netLines {
            guard let netID = line.netID?.lowercased() else { continue }
            for node in [resolver.node(at: line.from, stored: line.schematicFrom), resolver.node(at: line.to, stored: line.schematicTo)] {
                if case .junction(let id) = node, junctionNet[id] == nil { junctionNet[id] = netID }
            }
        }

        var pointsByNet = [String: [SplitPoint]]()
        for id in junctions.keys.sorted() {
            guard let point = junctions[id], let netID = junctionNet[id.lowercased()] else { continue }
            pointsByNet[netID, default: []].append(SplitPoint(point: point, endpoint: .junction(id)))
        }
        let pinConnections = PinConnections(self)
        for segment in symbolPins {
            guard let pin = SchematicPinRef(stemID: segment.id),
                  let netID = pinConnections.connection(of: pin)?.netID?.lowercased() else { continue }
            pointsByNet[netID, default: []].append(SplitPoint(point: segment.from, endpoint: .pin(pin.path)))
        }
        for port in blockSymbolPorts {
            let parts = port.id.lowercased().split(separator: "/").map(String.init)
            guard parts.count == 3, parts[1] == "block-port", let netID = port.netID?.lowercased() else { continue }
            pointsByNet[netID, default: []].append(SplitPoint(point: port.from, endpoint: .port("\(parts[0])/\(parts[2])")))
        }
        guard !pointsByNet.isEmpty else { return [] }

        var added = Set<String>()
        var result = [HorizontalSegment]()
        result.reserveCapacity(netLines.count)
        for line in netLines {
            guard let netID = line.netID?.lowercased(), let candidates = pointsByNet[netID] else {
                result.append(line)
                continue
            }
            var inside = [(t: Double, split: SplitPoint)]()
            var seen = Set<String>()
            for candidate in candidates {
                guard let t = Self.interiorParameter(of: candidate.point, on: line),
                      seen.insert(Self.key(candidate.point)).inserted else { continue }
                inside.append((t, candidate))
            }
            guard !inside.isEmpty else {
                result.append(line)
                continue
            }
            inside.sort { $0.t < $1.t }
            var start = line.from
            var startEndpoint = line.schematicFrom
            for (offset, entry) in inside.enumerated() {
                var piece = line
                if offset > 0 {
                    piece.id = UUID().uuidString.lowercased()
                    added.insert(piece.id)
                }
                piece.from = start
                piece.schematicFrom = startEndpoint
                piece.to = entry.split.point
                piece.schematicTo = entry.split.endpoint
                result.append(piece)
                start = entry.split.point
                startEndpoint = entry.split.endpoint
            }
            var last = line
            last.id = UUID().uuidString.lowercased()
            added.insert(last.id)
            last.from = start
            last.schematicFrom = startEndpoint
            result.append(last)
        }
        if !added.isEmpty { netLines = result }
        return added
    }

    /// Where `point` lies strictly inside `line`, as a fraction of its
    /// length, in whole nanometres like Horizon's `coord_on_line`.
    private static func interiorParameter(of point: HorizontalPoint, on line: HorizontalSegment) -> Double? {
        let (ax, ay) = (Int64(line.from.x.rounded()), Int64(line.from.y.rounded()))
        let (bx, by) = (Int64(line.to.x.rounded()), Int64(line.to.y.rounded()))
        let (px, py) = (Int64(point.x.rounded()), Int64(point.y.rounded()))
        guard px >= min(ax, bx), px <= max(ax, bx), py >= min(ay, by), py <= max(ay, by) else { return nil }
        guard !(px == ax && py == ay), !(px == bx && py == by) else { return nil }
        let (dx, dy) = (bx - ax, by - ay)
        let (ex, ey) = (px - ax, py - ay)
        let (left, leftOverflow) = dx.multipliedReportingOverflow(by: ey)
        let (right, rightOverflow) = dy.multipliedReportingOverflow(by: ex)
        guard !leftOverflow, !rightOverflow, left == right else { return nil }
        let length = Double(dx) * Double(dx) + Double(dy) * Double(dy)
        guard length > 0 else { return nil }
        return (Double(dx) * Double(ex) + Double(dy) * Double(ey)) / length
    }

    // MARK: - What an edit touched

    /// The points where `self` differs from `original` in its wiring: both
    /// ends of every wire added or changed, every junction added or moved,
    /// the pins of every symbol placed, moved or turned, and every label
    /// added or moved. The pass above looks no further, so wiring the edit
    /// left alone is not rewired.
    func touchedPointKeys(since original: HorizontalSchematicSheet) -> Set<String> {
        var keys = Set<String>()
        var originalLines = [String: HorizontalSegment]()
        for line in original.netLines { originalLines[line.id.lowercased()] = line }
        for line in netLines {
            let before = originalLines[line.id.lowercased()]
            if before?.from != line.from || before?.to != line.to
                || before?.schematicFrom != line.schematicFrom || before?.schematicTo != line.schematicTo {
                keys.insert(Self.key(line.from))
                keys.insert(Self.key(line.to))
            }
        }
        var originalJunctions = [String: HorizontalPoint]()
        for (id, point) in original.junctions { originalJunctions[id.lowercased()] = point }
        for (id, point) in junctions where originalJunctions[id.lowercased()] != point {
            keys.insert(Self.key(point))
        }
        var originalSymbols = [String: HorizontalPlacement]()
        for symbol in original.symbols { originalSymbols[symbol.id.lowercased()] = symbol }
        let changedSymbols = Set(symbols.filter { symbol in
            let before = originalSymbols[symbol.id.lowercased()]
            return before?.position != symbol.position || before?.angle != symbol.angle || before?.mirrored != symbol.mirrored
        }.map { $0.id.lowercased() })
        if !changedSymbols.isEmpty {
            for pin in symbolPins {
                guard let ref = SchematicPinRef(stemID: pin.id), changedSymbols.contains(ref.symbolID) else { continue }
                keys.insert(Self.key(pin.from))
            }
        }
        var originalLabels = [String: HorizontalPoint]()
        for label in original.netLabels { originalLabels[label.id.lowercased()] = label.position }
        for label in netLabels where originalLabels[label.id.lowercased()] != label.position {
            keys.insert(Self.key(label.position))
        }
        return keys
    }
}
