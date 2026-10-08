import Foundation

struct HorizontalDesignPin: Hashable {
    var gateID: String
    var pinID: String
    var gateName: String
    var gateSuffix: String
    var pinName: String
    var direction: String
    var netID: String?
    var physicalPads: [HorizontalDesignPad] = []
    var connectionState = "unconnected"
    /// What the unit offers in place of the primary name.
    var alternates: [HorizontalUnitPinAlternateName] = []
    /// What the component picked from them: its `alt_pins` entry.
    var selection: HorizontalDesignPinSelection?

    var gatePinPath: String { "\(gateID)/\(pinID)" }
}

/// A component's `alt_pins` entry for one pin, as Horizon stores it: the
/// alternates chosen by uuid, whether the primary name still shows, and a
/// custom name of the designer's own.
struct HorizontalDesignPinSelection: Hashable {
    var alternateIDs: [String]
    var usePrimaryName: Bool
    var useCustomName: Bool
    var customName: String

    init(json: JSONDictionary) {
        alternateIDs = (json["pin_names"] as? [String] ?? []).map { $0.lowercased() }
        usePrimaryName = json.bool("use_primary_name") ?? false
        useCustomName = json.bool("use_custom_name") ?? false
        customName = json.string("custom_name") ?? ""
    }

    var isEmpty: Bool { alternateIDs.isEmpty && !usePrimaryName && !(useCustomName && !customName.isEmpty) }

    /// Draws just what no entry would: the primary name. The app's pin-function
    /// dialog leaves entries like this behind, `pin_names` empty.
    var isRedundant: Bool { alternateIDs.isEmpty && !(useCustomName && !customName.isEmpty) }
}

extension HorizontalDesignPin {
    /// The name a symbol showing pins in `mode` draws for this pin: the sheet
    /// loader's `expandedPinName`, without its overline markup.
    func drawnName(mode: String) -> String {
        let names = alternates.reduce(into: [String: String]()) { $0[$1.id.lowercased()] = $1.name }
        switch mode {
        case "all":
            return (names.keys.sorted().compactMap { names[$0] } + ["(\(pinName))"]).joined(separator: " · ")
        case "alt_only":
            return names.keys.sorted().compactMap { names[$0] }.joined(separator: " · ")
        case "custom_only":
            if let customName = selection?.customName, !customName.isEmpty { return customName }
            return pinName
        default:
            guard let selection, !selection.alternateIDs.isEmpty || selection.useCustomName || selection.usePrimaryName else {
                return pinName
            }
            var shown = selection.usePrimaryName || mode == "both" ? [pinName] : []
            shown += selection.alternateIDs.compactMap { names[$0] }
            if selection.useCustomName, !selection.customName.isEmpty { shown.append(selection.customName) }
            return shown.joined(separator: " · ")
        }
    }
}

struct HorizontalDesignPad: Hashable {
    var id: String
    var name: String
}

struct HorizontalDesignSymbolPlacement: Hashable {
    var sheetIndex: Int
    var sheetName: String
    var gateID: String
    var gateSuffix: String
    var position: HorizontalPoint
    var angle: Int
    var mirrored: Bool
    var sheetID: String = ""
    var blockID: String? = nil
    var symbolID: String = ""
    /// The pool symbol that draws it, as list_symbols gives it.
    var poolSymbolID: String? = nil
    /// Which pin names the symbol draws: selected_only, custom_only, both or all.
    var pinDisplayMode: String = "selected_only"
}

struct HorizontalDesignBoardPlacement: Hashable {
    var position: HorizontalPoint
    var angle: Int
    var bottom: Bool
    var packageID: String?
    var fixed: Bool
    /// The package instance on the board — the key in the board's `packages`,
    /// which is what a track endpoint's `pad` path names. `packageID` is the
    /// pool package it draws.
    var instanceID: String = ""
}

struct HorizontalDesignComponent {
    var id: String
    var refdes: String
    var value: String
    var partID: String?
    var entityID: String?
    var entityName: String?
    var noPopulate: Bool
    var details: HorizontalComponentDetails?
    var pins: [HorizontalDesignPin]
    var symbolPlacements: [HorizontalDesignSymbolPlacement]
    var boardPlacement: HorizontalDesignBoardPlacement?
    var group: String?
    var tag: String?
    var rawValue: String = ""
    var partValue: String = ""
    var blockID: String? = nil
    var physicalTerminals: [JSONDictionary] = []

    var connectedPins: [HorizontalDesignPin] { pins.filter { $0.netID != nil } }
}

struct HorizontalDesignNetPin: Hashable {
    var componentID: String
    var refdes: String
    var gateName: String
    var gateSuffix: String
    var pinName: String
    var direction: String
    var gateID: String = ""
    var pinID: String = ""
    var physicalPads: [HorizontalDesignPad] = []
}

struct HorizontalDesignNet {
    var id: String
    var name: String
    var netClassName: String?
    var isPower: Bool
    var isPort: Bool
    var pins: [HorizontalDesignNetPin]
}

struct HorizontalDesignSheet {
    var id: String
    var index: Int
    var name: String
    var symbolCount: Int
    var blockName: String
    /// Nil when the schematic stands alone (no blocks file).
    var blockID: String?
    var isTopBlock: Bool
}

/// Everything the netlist-shaped dispatch methods answer from, built once per
/// loaded project: components with their pins resolved to names and nets,
/// nets with their pins, and where each component sits on the schematic and
/// the board. Pin names come from the placed symbols where a gate is placed,
/// and from the project pool's units otherwise.
struct HorizontalDesignIndex {
    private(set) var components: [String: HorizontalDesignComponent] = [:]
    private(set) var componentIDsByRefdes: [String: String] = [:]
    private(set) var nets: [String: HorizontalDesignNet] = [:]
    private(set) var netIDsByName: [String: String] = [:]
    private(set) var sheets: [HorizontalDesignSheet] = []
    /// Horizon's group and tag names by id (the block's `group_names` and
    /// `tag_names`).
    private(set) var groupNames: [String: String] = [:]
    private(set) var tagNames: [String: String] = [:]

    init(project: HorizontalProject, snapshot: HorizontalDispatchSnapshot? = nil) {
        let pool = HorizontalDispatchPoolIndex(project: project, snapshot: snapshot)
        let block = Self.loadTopBlockJSON(project: project, snapshot: snapshot)
        var blockComponents = Self.lowercasedKeys(block?.dictionaryMap("components") ?? [:])
        var componentBlocks = [String: String]()
        for definition in project.blocks {
            guard let filename = definition.blockFilename else { continue }
            let url = project.baseURL.appendingPathComponent(filename)
            let json = snapshot.map { $0.json(at: url) } ?? (try? JSONHelper.loadDictionary(from: url))
            for (id, component) in json?.dictionaryMap("components") ?? [:] {
                blockComponents[id.lowercased()] = component
                componentBlocks[id.lowercased()] = definition.uuid
            }
        }
        for (id, name) in block?["group_names"] as? [String: String] ?? [:] {
            groupNames[id.lowercased()] = name
        }
        for (id, name) in block?["tag_names"] as? [String: String] ?? [:] {
            tagNames[id.lowercased()] = name
        }
        let partsByID = Dictionary(
            project.poolParts.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var componentInfo = [String: SchematicComponentInfo]()
        var symbolPlacements = [String: [HorizontalDesignSymbolPlacement]]()
        var symbolPinNames = [String: [String: (name: String, direction: String)]]()
        var netDetails = [String: HorizontalNetDetails]()

        for entry in Self.schematics(of: project) {
            for sheet in entry.schematic.sheets {
                sheets.append(HorizontalDesignSheet(
                    id: sheet.id,
                    index: sheet.index,
                    name: sheet.name,
                    symbolCount: sheet.symbols.count,
                    blockName: entry.block.displayName,
                    blockID: project.schematics.isEmpty ? nil : entry.block.uuid,
                    isTopBlock: entry.block.isTop
                ))
                for (componentID, info) in sheet.componentInfo {
                    componentInfo[componentID.lowercased()] = info
                }
                for (netID, details) in sheet.netDetails where netDetails[netID.lowercased()] == nil {
                    netDetails[netID.lowercased()] = details
                }
                for symbol in sheet.symbols {
                    guard let componentID = symbol.componentID?.lowercased() else {
                        continue
                    }
                    symbolPlacements[componentID, default: []].append(HorizontalDesignSymbolPlacement(
                        sheetIndex: sheet.index,
                        sheetName: sheet.name,
                        gateID: symbol.gateID?.lowercased() ?? "",
                        gateSuffix: "",
                        position: symbol.position,
                        angle: symbol.angle,
                        mirrored: symbol.mirrored,
                        sheetID: sheet.id,
                        blockID: project.schematics.isEmpty ? nil : entry.block.uuid,
                        symbolID: symbol.id,
                        poolSymbolID: symbol.symbolID,
                        pinDisplayMode: symbol.pinDisplayMode
                    ))
                    for pin in symbol.symbolPinNames {
                        symbolPinNames[componentID, default: [:]][pin.gatePinPath.lowercased()] = (pin.primaryName, pin.primaryDirection)
                    }
                }
            }
        }
        sheets.sort { lhs, rhs in
            if lhs.isTopBlock != rhs.isTopBlock {
                return lhs.isTopBlock
            }
            return (lhs.index, lhs.blockID ?? "", lhs.id) < (rhs.index, rhs.blockID ?? "", rhs.id)
        }

        var boardPlacements = [String: HorizontalDesignBoardPlacement]()
        if let board = project.board {
            for package in board.packages {
                guard let componentID = package.componentID?.lowercased() else {
                    continue
                }
                boardPlacements[componentID] = HorizontalDesignBoardPlacement(
                    position: package.position,
                    angle: package.angle,
                    bottom: package.mirrored,
                    packageID: package.packageID,
                    fixed: package.fixed,
                    instanceID: package.id
                )
            }
            for (netID, details) in board.netDetails where netDetails[netID.lowercased()] == nil {
                netDetails[netID.lowercased()] = details
            }
        }

        for (componentID, info) in componentInfo {
            let blockEntry = blockComponents[componentID]
            let partID = (info.partID ?? info.details?.partID)?.lowercased()
            let part = partID.flatMap { partsByID[$0] }
            let entityID = (blockEntry?.string("entity") ?? part?.entityID)?.lowercased()
            let entity = entityID.flatMap { pool.entity($0) }

            var gates = [String: (name: String, suffix: String, unitID: String?)]()
            if let entity {
                for (gateID, gate) in entity.gates {
                    gates[gateID] = (gate.name, gate.suffix, gate.unitID)
                }
            }
            if let part {
                for gate in part.gates {
                    let gateID = gate.id.lowercased()
                    let existing = gates[gateID]
                    gates[gateID] = (
                        existing?.name ?? "",
                        gate.suffix.isEmpty ? (existing?.suffix ?? "") : gate.suffix,
                        gate.unitID.isEmpty ? existing?.unitID : gate.unitID.lowercased()
                    )
                }
            }
            for (gateID, suffix) in info.gateSuffixes where gates[gateID.lowercased()] == nil {
                gates[gateID.lowercased()] = ("", suffix, nil)
            }

            var pins = [String: HorizontalDesignPin]()
            for (gateID, gate) in gates {
                guard let unitID = gate.unitID, let unit = pool.unit(unitID) else {
                    continue
                }
                for (pinID, pin) in unit.pins {
                    pins["\(gateID)/\(pinID)"] = HorizontalDesignPin(
                        gateID: gateID,
                        pinID: pinID,
                        gateName: gate.name,
                        gateSuffix: gate.suffix,
                        pinName: pin.name,
                        direction: pin.direction,
                        netID: nil,
                        alternates: pin.alternates
                    )
                }
            }
            for (path, value) in blockEntry?.dictionary("alt_pins") ?? [:] {
                guard let json = value as? JSONDictionary else { continue }
                let selection = HorizontalDesignPinSelection(json: json)
                // Kept even when it draws nothing new, so get_component can say so.
                pins[path.lowercased()]?.selection = selection
            }
            let namesFromSymbols = symbolPinNames[componentID] ?? [:]
            for (path, state) in info.connections {
                let key = path.lowercased()
                let pieces = key.split(separator: "/", maxSplits: 1).map(String.init)
                let gateID = pieces.first ?? ""
                let pinID = pieces.count > 1 ? pieces[1] : ""
                var pin = pins[key] ?? HorizontalDesignPin(
                    gateID: gateID,
                    pinID: pinID,
                    gateName: gates[gateID]?.name ?? "",
                    gateSuffix: gates[gateID]?.suffix ?? "",
                    pinName: "",
                    direction: "",
                    netID: nil
                )
                if pin.pinName.isEmpty, let symbolPin = namesFromSymbols[key] {
                    pin.pinName = symbolPin.name
                    pin.direction = symbolPin.direction
                }
                if pin.pinName.isEmpty {
                    pin.pinName = String(pinID.prefix(8))
                }
                pin.netID = state.netID?.lowercased()
                switch state {
                case .notConnected: pin.connectionState = "no_connect"
                default: pin.connectionState = pin.netID == nil ? "unconnected" : "connected"
                }
                pins[key] = pin
            }
            for (key, names) in namesFromSymbols where pins[key]?.pinName.isEmpty ?? false {
                pins[key]?.pinName = names.name
                pins[key]?.direction = names.direction
            }

            if let partID {
                for key in pins.keys { pins[key]?.physicalPads = pool.pads(partID: partID, gatePinPath: key) }
            }
            let sortedPins = pins.values.sorted { lhs, rhs in
                if lhs.gateSuffix != rhs.gateSuffix {
                    return lhs.gateSuffix < rhs.gateSuffix
                }
                // As a person reads them: PA2 before PA10.
                switch lhs.pinName.localizedStandardCompare(rhs.pinName) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.gatePinPath < rhs.gatePinPath
                }
            }
            var placements = symbolPlacements[componentID] ?? []
            for index in placements.indices {
                placements[index].gateSuffix = gates[placements[index].gateID]?.suffix ?? ""
            }
            placements.sort { ($0.sheetIndex, $0.gateSuffix, $0.symbolID) < ($1.sheetIndex, $1.gateSuffix, $1.symbolID) }

            let component = HorizontalDesignComponent(
                id: componentID,
                refdes: info.refdes,
                value: info.value,
                partID: partID,
                entityID: entityID,
                entityName: entity?.name,
                noPopulate: info.noPopulate,
                details: info.details,
                pins: sortedPins,
                symbolPlacements: placements,
                boardPlacement: boardPlacements[componentID],
                group: blockEntry?.string("group")?.lowercased(),
                tag: blockEntry?.string("tag")?.lowercased(),
                rawValue: blockEntry?.string("value") ?? info.value,
                partValue: partID.flatMap { pool.partValue($0) } ?? "",
                blockID: componentBlocks[componentID],
                physicalTerminals: partID.map { pool.terminals(partID: $0) } ?? []
            )
            components[componentID] = component
            if !info.refdes.isEmpty {
                componentIDsByRefdes[info.refdes] = componentID
            }
        }

        for (netID, details) in netDetails {
            nets[netID] = HorizontalDesignNet(
                id: netID,
                name: details.name,
                netClassName: details.netClassName,
                isPower: details.isPower,
                isPort: details.isPort,
                pins: []
            )
        }
        for component in components.values {
            for pin in component.pins {
                guard let netID = pin.netID else {
                    continue
                }
                if nets[netID] == nil {
                    nets[netID] = HorizontalDesignNet(id: netID, name: "", netClassName: nil, isPower: false, isPort: false, pins: [])
                }
                nets[netID]?.pins.append(HorizontalDesignNetPin(
                    componentID: component.id,
                    refdes: component.refdes,
                    gateName: pin.gateName,
                    gateSuffix: pin.gateSuffix,
                    pinName: pin.pinName,
                    direction: pin.direction,
                    gateID: pin.gateID,
                    pinID: pin.pinID,
                    physicalPads: pin.physicalPads
                ))
            }
        }
        for netID in nets.keys {
            nets[netID]?.pins.sort { lhs, rhs in
                (lhs.refdes, lhs.componentID, lhs.gateID, lhs.pinID) < (rhs.refdes, rhs.componentID, rhs.gateID, rhs.pinID)
            }
        }
        for net in nets.values where !net.name.isEmpty {
            netIDsByName[net.name] = net.id
        }
    }

    func groupName(_ id: String?) -> String? {
        guard let id, id != HorizontalProjectEditor.nullUUID else {
            return nil
        }
        return groupNames[id.lowercased()]
    }

    func tagName(_ id: String?) -> String? {
        guard let id, id != HorizontalProjectEditor.nullUUID else {
            return nil
        }
        return tagNames[id.lowercased()]
    }

    var sortedComponents: [HorizontalDesignComponent] {
        components.values.sorted { ($0.refdes, $0.id) < ($1.refdes, $1.id) }
    }

    var sortedNets: [HorizontalDesignNet] {
        nets.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func component(refdes: String) -> HorizontalDesignComponent? {
        if let id = componentIDsByRefdes[refdes], let component = components[id] {
            return component
        }
        return components.values.first { $0.refdes.caseInsensitiveCompare(refdes) == .orderedSame }
    }

    func component(id: String) -> HorizontalDesignComponent? {
        components[id.lowercased()]
    }

    func net(named name: String) -> HorizontalDesignNet? {
        if let id = netIDsByName[name], let net = nets[id] {
            return net
        }
        return nets.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func net(id: String) -> HorizontalDesignNet? {
        nets[id.lowercased()]
    }

    /// The schematics the PDF exporter walks, in its page order.
    static func schematics(of project: HorizontalProject) -> [HorizontalProjectSchematic] {
        if !project.schematics.isEmpty {
            return project.schematics
        }
        guard let schematic = project.schematic else {
            return []
        }
        let block = HorizontalProjectBlock(
            uuid: schematic.uuid,
            blockFilename: nil,
            schematicFilename: schematic.url.lastPathComponent,
            symbolFilename: nil,
            isTop: true
        )
        return [HorizontalProjectSchematic(block: block, schematicFilename: schematic.url.lastPathComponent, schematic: schematic)]
    }

    static func loadTopBlockJSON(project: HorizontalProject, snapshot: HorizontalDispatchSnapshot? = nil) -> JSONDictionary? {
        let filename = project.blocks.first(where: \.isTop)?.blockFilename ?? project.blockFilename
        guard let filename, !filename.isEmpty else {
            return nil
        }
        let url = project.baseURL.appendingPathComponent(filename)
        if let snapshot { return snapshot.json(at: url) }
        return try? JSONHelper.loadDictionary(from: url)
    }

    private static func lowercasedKeys(_ map: [String: JSONDictionary]) -> [String: JSONDictionary] {
        Dictionary(map.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Entities and units from the project pool, indexed by uuid, so pins can be
/// named for gates that have no symbol placed on any sheet.
final class HorizontalDispatchPoolIndex {
    struct Gate {
        var name: String
        var suffix: String
        var unitID: String?
    }

    struct Entity {
        var name: String
        var prefix: String
        var gates: [String: Gate]
    }

    struct Pin {
        var name: String
        var direction: String
        /// The functions a component can pick for this pin instead of its
        /// primary name, as the unit lists them (legacy `names` included).
        var alternates: [HorizontalUnitPinAlternateName] = []
    }

    struct Unit {
        var name: String
        var pins: [String: Pin]
    }

    /// Where a symbol draws a pin: the connection point, in symbol
    /// coordinates, and the way the pin points out of the body.
    struct SymbolPinGeometry {
        var position: HorizontalPoint
        var length: Double
        var orientation: String
    }

    private var entities: [String: Entity] = [:]
    private var units: [String: Unit] = [:]
    /// Symbol uuids per unit, sorted, so a gate can be drawn without the
    /// caller naming the symbol that draws its unit.
    private var symbolsByUnit: [String: [String]] = [:]
    private var symbolPins: [String: Set<String>] = [:]
    private var symbolPinGeometry: [String: [String: SymbolPinGeometry]] = [:]
    private var parts: [String: JSONDictionary] = [:]
    private var packages: [String: JSONDictionary] = [:]
    private var padstacks: [String: JSONDictionary] = [:]

    init(project: HorizontalProject, snapshot: HorizontalDispatchSnapshot? = nil) {
        guard let poolDirectory = project.poolDirectory else {
            return
        }
        let poolURL = project.baseURL.appendingPathComponent(poolDirectory)
        func files(_ category: String) -> [URL] {
            let url = poolURL.appendingPathComponent(category)
            return snapshot?.jsonFiles(under: url) ?? Self.jsonFiles(under: url)
        }
        func read(_ url: URL) -> JSONDictionary? {
            if let snapshot { return snapshot.json(at: url) }
            return try? JSONHelper.loadDictionary(from: url)
        }
        for category in ["parts", "packages", "padstacks"] {
            for url in files(category) {
                guard let json = read(url), let id = json.string("uuid")?.lowercased() else { continue }
                if category == "parts" { parts[id] = json }
                else if category == "packages" { packages[id] = json }
                else { padstacks[id] = json }
            }
        }
        for url in files("entities") {
            guard let json = read(url),
                  json.string("type") == "entity",
                  let uuid = json.string("uuid")?.lowercased() else {
                continue
            }
            var gates = [String: Gate]()
            for (gateID, gate) in json.dictionaryMap("gates") {
                gates[gateID.lowercased()] = Gate(
                    name: gate.string("name") ?? "",
                    suffix: gate.string("suffix") ?? "",
                    unitID: gate.string("unit")?.lowercased()
                )
            }
            entities[uuid] = Entity(name: json.string("name") ?? "", prefix: json.string("prefix") ?? "", gates: gates)
        }
        for url in files("units") {
            guard let json = read(url),
                  json.string("type") == "unit",
                  let uuid = json.string("uuid")?.lowercased() else {
                continue
            }
            var pins = [String: Pin]()
            for (pinID, pin) in json.dictionaryMap("pins") {
                pins[pinID.lowercased()] = Pin(
                    name: pin.string("primary_name") ?? "",
                    direction: pin.string("direction") ?? "",
                    alternates: (try? HorizontalUnitPin(id: pinID, json: pin))?.alternateNames ?? []
                )
            }
            units[uuid] = Unit(name: json.string("name") ?? "", pins: pins)
        }
        for url in files("symbols") {
            guard let json = read(url),
                  json.string("type") == "symbol",
                  let uuid = json.string("uuid")?.lowercased(),
                  let unitID = json.string("unit")?.lowercased() else {
                continue
            }
            symbolsByUnit[unitID, default: []].append(uuid)
            symbolPins[uuid] = Set(json.dictionaryMap("pins").keys.map { $0.lowercased() })
            for (pinID, pin) in json.dictionaryMap("pins") {
                guard let position = pin["position"] as? [Any], position.count == 2,
                      let x = (position[0] as? NSNumber)?.doubleValue, let y = (position[1] as? NSNumber)?.doubleValue else { continue }
                symbolPinGeometry[uuid, default: [:]][pinID.lowercased()] = SymbolPinGeometry(
                    position: HorizontalPoint(x: x, y: y), length: pin.double("length") ?? 0,
                    orientation: pin.string("orientation") ?? "right")
            }
        }
        for unitID in symbolsByUnit.keys {
            symbolsByUnit[unitID]?.sort()
        }
    }

    func symbolPins(_ symbol: String) -> [String: SymbolPinGeometry] {
        symbolPinGeometry[symbol.lowercased()] ?? [:]
    }

    func symbolPin(_ symbol: String, pin: String) -> SymbolPinGeometry? {
        symbolPinGeometry[symbol.lowercased()]?[pin.lowercased()]
    }

    func symbolHasPin(_ symbol: String, pin: String) -> Bool {
        symbolPins[symbol.lowercased()]?.contains(pin.lowercased()) == true
    }

    /// The symbols in the project pool that draw `unitID`.
    func symbols(forUnit unitID: String) -> [String] {
        symbolsByUnit[unitID.lowercased()] ?? []
    }

    func entity(_ id: String) -> Entity? {
        entities[id.lowercased()]
    }

    private func resolvedPart(_ id: String, visited: Set<String> = []) -> JSONDictionary? {
        let id = id.lowercased()
        guard !visited.contains(id), let part = parts[id] else { return nil }
        guard let base = part.string("base") else { return part }
        guard var resolved = resolvedPart(base, visited: visited.union([id])) else { return nil }
        for (key, value) in part where !["entity", "package", "pad_map"].contains(key) {
            if let pair = value as? [Any], pair.count == 2, pair[0] as? Bool == true { continue }
            resolved[key] = value
        }
        return resolved
    }

    func partValue(_ id: String) -> String? {
        guard let value = resolvedPart(id)?["value"] as? [Any], value.count == 2 else { return nil }
        return value[1] as? String
    }

    func pads(partID: String, gatePinPath: String) -> [HorizontalDesignPad] {
        guard let part = resolvedPart(partID), let packageID = part.string("package"),
              let package = packages[packageID.lowercased()] else { return [] }
        let pads = package.dictionaryMap("pads")
        return part.dictionaryMap("pad_map").compactMap { id, mapping in
            guard let gate = mapping.string("gate"), let pin = mapping.string("pin"),
                  "\(gate)/\(pin)".lowercased() == gatePinPath.lowercased() else { return nil }
            let padID = mapping.string("pad") ?? id
            guard let pad = pads.first(where: { $0.key.lowercased() == padID.lowercased() }) else { return nil }
            return HorizontalDesignPad(id: pad.key, name: pad.value.string("name") ?? "")
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func terminals(partID: String) -> [JSONDictionary] {
        guard let part = resolvedPart(partID), let packageID = part.string("package"), let package = packages[packageID.lowercased()] else { return [] }
        let mappings = part.dictionaryMap("pad_map")
        return package.dictionaryMap("pads").map { id, pad -> JSONDictionary in
            let mapping = mappings.first { ($0.value.string("pad") ?? $0.key).caseInsensitiveCompare(id) == .orderedSame }?.value
            let type = pad.string("padstack").flatMap { padstacks[$0.lowercased()]?.string("padstack_type") }
            var result: JSONDictionary = ["id": id, "name": pad.string("name") ?? "",
                                           "role": ["hole", "mechanical"].contains(type ?? "") ? "mechanical" : mapping == nil ? "unmapped" : "electrical"]
            if let mapping, let gate = mapping.string("gate"), let pin = mapping.string("pin") {
                result["gate_id"] = gate
                result["pin_id"] = pin
                result["gate_pin_path"] = "\(gate)/\(pin)"
            }
            return result
        }.sorted { ($0.string("name") ?? "", $0.string("id") ?? "") < ($1.string("name") ?? "", $1.string("id") ?? "") }
    }

    /// A padstack's own JSON, for checking what it actually defines.
    func padstack(_ id: String) -> JSONDictionary? {
        padstacks[id.lowercased()]
    }

    func unit(_ id: String) -> Unit? {
        units[id.lowercased()]
    }

    private static func jsonFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }
}
