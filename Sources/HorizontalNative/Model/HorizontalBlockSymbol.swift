import Foundation

/// Horizon's `BlockSymbol` as the block symbol editor edits it: the box a
/// block is drawn with wherever it is used, and its ports, one for each of
/// the block's port nets that the symbol draws.
///
/// The editor is the pool symbol editor in its block flavour, so the symbol
/// goes through a `HorizontalPoolSymbol` whose pins are the ports, keyed by
/// port uuid, and whose unit is made up of the block's port nets — which is
/// what lets the symbol editor's unplaced column offer the ports still to
/// draw, and its Place Pin tool draw them (Horizon's Place Port).
struct HorizontalBlockSymbol: Equatable {
    /// One of the block's port nets, as a port of its symbol.
    struct PortNet: Equatable {
        var netID: String
        var name: String
        var direction: String
    }

    var blockID: String
    var name: String
    var symbol: HorizontalPoolSymbol
    /// The block's port nets, by the uuid of the port each would be.
    var portNets: [String: PortNet]
    var sourceJSON: HorizontalPreservedJSON

    /// `symbolJSON` is the block's symbol file; `blockJSON` its block file,
    /// which names the ports.
    init(symbolJSON: JSONDictionary, blockJSON: JSONDictionary?, name: String) throws {
        blockID = symbolJSON.string("block")?.lowercased() ?? blockJSON?.string("uuid")?.lowercased() ?? ""
        self.name = blockJSON?.string("name") ?? name
        sourceJSON = HorizontalPreservedJSON(symbolJSON)
        var portNets = [String: PortNet]()
        for (netID, net) in blockJSON?.dictionaryMap("nets") ?? [:] where net.bool("is_port") == true {
            guard let portID = HorizontalBlockSymbolPortID.uuid(forNet: netID) else { continue }
            portNets[portID] = PortNet(netID: netID.lowercased(), name: net.string("name") ?? "",
                                       direction: net.string("port_direction") ?? "bidirectional")
        }
        self.portNets = portNets

        var pins = JSONDictionary()
        for (portID, port) in symbolJSON.dictionaryMap("ports") {
            pins[portID.lowercased()] = [
                "position": port["position"] ?? [0, 0],
                "length": port["length"] ?? 2_500_000,
                "orientation": port.string("orientation") ?? "right",
                "name_orientation": port.string("name_orientation") ?? "in_line",
                "name_visible": true,
                "pad_visible": false,
            ]
        }
        var poolJSON: JSONDictionary = [
            "type": "symbol",
            "uuid": symbolJSON.string("uuid") ?? UUID().uuidString.lowercased(),
            "name": self.name,
            "unit": Self.unitID(blockID),
            "pins": pins,
            "polygons": JSONDictionary(),
        ]
        for key in ["junctions", "lines", "arcs", "texts"] {
            poolJSON[key] = symbolJSON[key] ?? JSONDictionary()
        }
        symbol = try HorizontalPoolSymbol(json: poolJSON)
    }

    private static func unitID(_ blockID: String) -> String {
        "block-ports-\(blockID)"
    }

    /// The unit the ports are pins of: one pin per port net, named and
    /// directed as the net is.
    var unitJSON: JSONDictionary {
        var pins = JSONDictionary()
        for (portID, net) in portNets {
            pins[portID] = ["primary_name": net.name, "direction": net.direction, "swap_group": 0, "names": [String]()]
        }
        return ["type": "unit", "uuid": Self.unitID(blockID), "name": name, "manufacturer": "", "pins": pins]
    }

    var unit: HorizontalPoolUnit? {
        try? HorizontalPoolUnit(json: unitJSON)
    }

    func context(poolURL: URL) -> HorizontalSymbolEditorContext {
        HorizontalSymbolEditorContext(
            symbolID: symbol.uuid,
            unitID: Self.unitID(blockID),
            unitJSON: HorizontalPreservedJSON(unitJSON),
            poolURL: poolURL
        )
    }

    func makeSheet(poolURL: URL) -> HorizontalSchematicSheet {
        symbol.makeSheet(context: context(poolURL: poolURL), unit: unit)
    }

    func applying(sheet: HorizontalSchematicSheet) -> HorizontalBlockSymbol {
        var edited = self
        edited.symbol = symbol.applying(sheet: sheet)
        return edited
    }

    /// The port nets the symbol doesn't draw yet, by name.
    var unplacedPortNames: [String] {
        portNets.filter { symbol.pins[$0.key] == nil }.values.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// What the editor's checks find. Horizon checks nothing in a block
    /// symbol; these are its symbol rules as they apply to one: a `$REFDES`
    /// for the instance's name, ports on the 1.25 mm grid, apart, on the
    /// rectangle they span and pointing out of it, every port net drawn, and
    /// no junction joined to nothing.
    func validationIssues() -> [HorizontalPoolCheckIssue] {
        var issues = [HorizontalPoolCheckIssue]()
        let refdes = symbol.drawing.texts.values.filter { $0.text == "$REFDES" }.count
        if refdes != 1 {
            issues.append(.warning("Symbol has \(refdes) reference designators, need 1"))
        }
        return issues + symbol.pinIssues(unit: unit, noun: "Port")
    }

    /// The symbol file: the drawing and the ports as Horizon writes them,
    /// over what the file held, so its pictures and the rest survive.
    func json() -> JSONDictionary {
        let edited = symbol.json()
        var result = sourceJSON.dictionary
        result["type"] = "block_symbol"
        result["block"] = sourceJSON.dictionary["block"] ?? blockID
        for key in ["junctions", "lines", "arcs", "texts"] {
            result[key] = edited[key] ?? JSONDictionary()
        }
        let originalPorts = sourceJSON.dictionary.dictionaryMap("ports").reduce(into: [String: JSONDictionary]()) {
            $0[$1.key.lowercased()] = $1.value
        }
        var ports = JSONDictionary()
        for (portID, pin) in symbol.pins {
            // A port whose net stopped being one keeps the net it drew.
            guard let net = portNets[portID]?.netID ?? originalPorts[portID]?.string("net") else { continue }
            var port = originalPorts[portID] ?? [:]
            port["net"] = net
            port["position"] = HorizontalPoolJSON.point(pin.position)
            port["length"] = HorizontalPoolJSON.int(pin.length)
            port["orientation"] = pin.orientation.rawValue
            port["name_orientation"] = pin.nameOrientation.rawValue
            ports[portID] = port
        }
        result["ports"] = ports
        return result
    }

    static func == (lhs: HorizontalBlockSymbol, rhs: HorizontalBlockSymbol) -> Bool {
        lhs.blockID == rhs.blockID && lhs.name == rhs.name && lhs.symbol == rhs.symbol
            && lhs.portNets == rhs.portNets && lhs.sourceJSON == rhs.sourceJSON
    }
}
