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
    /// The symbol's custom value as stored, nil when it has none.
    var customValue: String? = nil
    /// What its `$VALUE` text draws: the custom value filled in, or the
    /// component's value.
    var drawnValue: String = ""
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
    /// The value the component's part stores, empty when it has none.
    var partValue: String = ""
    /// What the part makes the component show: its value, or its MPN.
    var partDisplayValue: String = ""
    var blockID: String? = nil
    var physicalTerminals: [JSONDictionary] = []
    /// For one use of a sub-block's component, read through its instance: the
    /// component of the block it is, and the instance path ("ADC1") it is in.
    /// Its id is then the flat uuid the board names it by, its refdes, board
    /// placement and pins' nets the instance's.
    var instanceOf: String? = nil
    var instancePath: String? = nil

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
    /// The flat uuid of the instance whose pin this is, when the component is
    /// a sub-block's used through an instance (refdes is then the instance's).
    var instanceID: String? = nil
}

/// A block instance's port wired to a net of the block that uses it: how a
/// net reaches the inside of a sub-block.
struct HorizontalDesignNetPort: Hashable {
    /// The instance, by uuid and refdes.
    var instanceID: String
    var instanceRefdes: String
    /// The block it is an instance of, and the port: its net in that block.
    var blockID: String
    var blockName: String
    var portNetID: String
    var portName: String
}

/// One use of a component: the component itself in the top block, or a
/// sub-block's component in one instance of that block, as the flattened
/// block has it — with the refdes and no-populate that instance gives it and
/// the board package placed for it.
struct HorizontalDesignInstance {
    /// The flat uuid Horizon's board names it by.
    var id: String
    /// The component of its block it is.
    var componentID: String
    var refdes: String
    var noPopulate: Bool
    /// The instances it is in, by refdes from the top: "I1/I2". Empty for a
    /// top block component.
    var instancePath: String
    var boardPlacement: HorizontalDesignBoardPlacement?
}

struct HorizontalDesignNet {
    var id: String
    var name: String
    var netClassName: String?
    var isPower: Bool
    var isPort: Bool
    /// In a design whose top block uses others, a top block net's pins are
    /// the flattened design's: its own components' and every instance's
    /// that reaches it through a port or as a power net, under the instance's
    /// refdes. A sub-block's own net has that block's components' pins.
    var pins: [HorizontalDesignNetPin]
    /// The sub-block the net is a net of; nil for the top block's (power nets
    /// among them, which every block shares).
    var blockID: String? = nil
    var blockName: String? = nil
    /// The block instances in the net's own block whose ports are wired to it.
    var ports: [HorizontalDesignNetPort] = []
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
    /// The pool frame the sheet draws its title block with, and its name
    /// when the project pool has it.
    var frameID: String? = nil
    var frameName: String? = nil
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
    /// Every use of a component the flattened block has, for a design whose
    /// top block uses others; empty otherwise, when each component is used
    /// once, as itself.
    private(set) var instances: [HorizontalDesignInstance] = []
    /// The flattened block's own nets, an instance's `I1/Out`, by id: the
    /// board's, named here though no block has them.
    private(set) var flattenedNetNames: [String: String] = [:]
    /// Horizon's group and tag names by id (the block's `group_names` and
    /// `tag_names`).
    private(set) var groupNames: [String: String] = [:]
    private(set) var tagNames: [String: String] = [:]
    /// The top block's uuid, nil for a schematic that stands alone.
    private(set) var topBlockID: String?
    /// Each instance's pins as the flattened block wires them, by flat
    /// component uuid and gate/pin path: the flat net, or no-connect.
    private(set) var instanceNets: [String: [String: String]] = [:]
    private(set) var instanceNoConnects: [String: Set<String>] = [:]

    init(project: HorizontalProject, snapshot: HorizontalDispatchSnapshot? = nil) {
        let pool = HorizontalDispatchPoolIndex(project: project, snapshot: snapshot)
        let block = Self.loadTopBlockJSON(project: project, snapshot: snapshot)
        var blockComponents = Self.lowercasedKeys(block?.dictionaryMap("components") ?? [:])
        var componentBlocks = [String: String]()
        var blockFiles = [String: JSONDictionary]()
        topBlockID = project.blocks.first(where: \.isTop)?.uuid.lowercased()
        for definition in project.blocks {
            guard let filename = definition.blockFilename else { continue }
            let url = project.baseURL.appendingPathComponent(filename)
            let json = snapshot.map { $0.json(at: url) } ?? (try? JSONHelper.loadDictionary(from: url))
            blockFiles[definition.uuid.lowercased()] = json
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
                    isTopBlock: entry.block.isTop,
                    frameID: sheet.frameID,
                    frameName: sheet.frameName
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
                        pinDisplayMode: symbol.pinDisplayMode,
                        customValue: symbol.customValue,
                        drawnValue: HorizontalSymbolCustomValue.drawnValue(customValue: symbol.customValue, details: symbol.componentDetails)
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
            let flattenedNets = Set(project.flattenedBlock?.netPaths.filter { $0.value.allSatisfy { $0.count > 1 } }.keys.map { $0.lowercased() } ?? [])
            for (netID, details) in board.netDetails where netDetails[netID.lowercased()] == nil {
                // An instance's own net is the board's alone; the blocks name
                // its pins by the net of their own it stands for.
                if flattenedNets.contains(netID.lowercased()) {
                    flattenedNetNames[netID.lowercased()] = details.name
                    continue
                }
                netDetails[netID.lowercased()] = details
            }
        }
        if let flattened = project.flattenedBlock {
            let topJSON = block ?? [:]
            func pathName(_ path: [String]) -> String {
                var names = [String](), current = topJSON
                for id in path.dropLast() {
                    guard let instance = current.dictionaryMap("block_instances").first(where: { $0.key.lowercased() == id })?.value else { break }
                    names.append(instance.string("refdes") ?? "")
                    let child = instance.string("block")?.lowercased()
                    let filename = project.blocks.first { $0.uuid.lowercased() == child }?.blockFilename
                    current = filename.flatMap { name in
                        let url = project.baseURL.appendingPathComponent(name)
                        return snapshot.map { $0.json(at: url) } ?? (try? JSONHelper.loadDictionary(from: url))
                    } ?? [:]
                }
                return names.joined(separator: "/")
            }
            instances = flattened.instances.map { instance in
                HorizontalDesignInstance(
                    id: instance.flatID,
                    componentID: instance.componentID,
                    refdes: instance.refdes,
                    noPopulate: instance.noPopulate,
                    instancePath: pathName(flattened.componentPaths[instance.flatID] ?? []),
                    boardPlacement: boardPlacements[instance.flatID]
                )
            }
            .sorted { ($0.refdes, $0.id) < ($1.refdes, $1.id) }
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
                // The board's own answer, else the part's: a part written into
                // the pool since the board was read names a package the
                // board's placement doesn't know yet.
                boardPlacement: boardPlacements[componentID].map { placement in
                    var placement = placement
                    if placement.packageID == nil {
                        placement.packageID = part?.packageID ?? partID.flatMap { pool.poolPart($0)?.packageID }
                    }
                    return placement
                },
                group: blockEntry?.string("group")?.lowercased(),
                tag: blockEntry?.string("tag")?.lowercased(),
                rawValue: blockEntry?.string("value") ?? info.value,
                partValue: partID.flatMap { pool.partValue($0) } ?? "",
                partDisplayValue: partID.flatMap { pool.partDisplayValue($0) } ?? "",
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
        assignBlocks(project: project, top: block ?? [:], blockFiles: blockFiles)
        if let flattened = project.flattenedBlock, flattened.isHierarchical {
            addInstancePins(flattened, templates: Set(componentBlocks.filter { $0.value.lowercased() != topBlockID }.keys))
        }
        for netID in nets.keys {
            nets[netID]?.pins.sort { lhs, rhs in
                (lhs.refdes, lhs.componentID, lhs.gateID, lhs.pinID) < (rhs.refdes, rhs.componentID, rhs.gateID, rhs.pinID)
            }
        }
        // A name both a sub-block and the top block use is the top block's.
        for net in nets.values.sorted(by: { ($0.blockID == nil ? 1 : 0, $0.id) < ($1.blockID == nil ? 1 : 0, $1.id) }) where !net.name.isEmpty {
            netIDsByName[net.name] = net.id
        }
    }

    /// Which block each net is a net of, and the block instances wired to it.
    /// A power net is every block's, and so the top block's.
    private mutating func assignBlocks(project: HorizontalProject, top: JSONDictionary, blockFiles: [String: JSONDictionary]) {
        let topNets = top.dictionaryMap("nets").reduce(into: [String: JSONDictionary]()) { $0[$1.key.lowercased()] = $1.value }
        let name = { (id: String) in project.blocks.first { $0.uuid.lowercased() == id }?.displayName ?? id }
        var owners = [String: (id: String, name: String)]()
        var ports = [String: [HorizontalDesignNetPort]]()
        for (blockID, json) in blockFiles {
            let blockNets = json.dictionaryMap("nets")
            if blockID != topBlockID {
                for netID in blockNets.keys.map({ $0.lowercased() }) where topNets[netID] == nil {
                    owners[netID] = (blockID, name(blockID))
                }
            }
            for (instanceID, instance) in json.dictionaryMap("block_instances") {
                guard let used = instance.string("block")?.lowercased() else { continue }
                let usedNets = blockFiles[used]?.dictionaryMap("nets") ?? [:]
                for (port, connection) in instance.dictionaryMap("connections") {
                    guard let netID = connection.string("net")?.lowercased() else { continue }
                    let portName = usedNets.first { $0.key.lowercased() == port.lowercased() }?.value.string("name") ?? port
                    ports[netID, default: []].append(HorizontalDesignNetPort(
                        instanceID: instanceID.lowercased(), instanceRefdes: instance.string("refdes") ?? "",
                        blockID: used, blockName: name(used), portNetID: port.lowercased(), portName: portName))
                }
                // A net that nothing but a port reaches is still the block's net.
                for netID in Set(instance.dictionaryMap("connections").values.compactMap { $0.string("net")?.lowercased() })
                    where nets[netID] == nil {
                    let net = json.dictionaryMap("nets").first { $0.key.lowercased() == netID }?.value
                    nets[netID] = HorizontalDesignNet(id: netID, name: net?.string("name") ?? "", netClassName: nil,
                                                      isPower: net?.bool("is_power") ?? false, isPort: net?.bool("is_port") ?? false, pins: [])
                }
            }
        }
        for netID in nets.keys {
            if let owner = owners[netID] {
                nets[netID]?.blockID = owner.id
                nets[netID]?.blockName = owner.name
            }
            nets[netID]?.ports = (ports[netID] ?? []).sorted { ($0.instanceRefdes, $0.portName) < ($1.instanceRefdes, $1.portName) }
        }
    }

    /// The flattened design on the top block's nets: every instance's pins,
    /// under its refdes, on the net its port is wired to or the power net it
    /// shares. A sub-block's own components are no part of the design but
    /// through their instances, so they leave the top block's power nets.
    private mutating func addInstancePins(_ flattened: HorizontalFlattenedBlock, templates: Set<String>) {
        for netID in nets.keys where nets[netID]?.blockID == nil {
            nets[netID]?.pins.removeAll { templates.contains($0.componentID) }
        }
        for (flatID, flat) in flattened.json.dictionaryMap("components") {
            let id = flatID.lowercased()
            guard let path = flattened.componentPaths[id], path.count > 1, let templateID = path.last,
                  let template = components[templateID] else { continue }
            var connected = [String: String]()
            var noConnect = Set<String>()
            for (pinPath, connection) in flat.dictionaryMap("connections") {
                if let netID = connection.string("net")?.lowercased() { connected[pinPath.lowercased()] = netID }
                else { noConnect.insert(pinPath.lowercased()) }
            }
            instanceNets[id] = connected
            instanceNoConnects[id] = noConnect
            let refdes = flat.string("refdes") ?? template.refdes
            for pin in template.pins {
                guard let netID = connected[pin.gatePinPath.lowercased()], nets[netID] != nil, nets[netID]?.blockID == nil else { continue }
                nets[netID]?.pins.append(HorizontalDesignNetPin(
                    componentID: templateID, refdes: refdes, gateName: pin.gateName, gateSuffix: pin.gateSuffix,
                    pinName: pin.pinName, direction: pin.direction, gateID: pin.gateID, pinID: pin.pinID,
                    physicalPads: pin.physicalPads, instanceID: id))
            }
        }
    }

    /// The nets a name selects. A sub-block's port net can share a name with
    /// the top block net its instances are wired to; `block`'s own net is
    /// chosen when that block has one, else the top block's, and only names
    /// still shared by two nets of one standing come back as several.
    func nets(named name: String, block: String? = nil) -> [HorizontalDesignNet] {
        let all = sortedNets.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard all.count > 1 else { return all }
        if let block = block?.lowercased() {
            let own = all.filter { ($0.blockID?.lowercased() ?? topBlockID) == block }
            if own.count == 1 { return own }
        }
        let top = all.filter { $0.blockID == nil }
        return top.count == 1 ? top : all
    }

    /// One use of a sub-block's component, read through its instance: the
    /// block's component under the instance's flat uuid, refdes, no-populate
    /// and board package, its pins on the flattened design's nets.
    func component(instance: HorizontalDesignInstance) -> HorizontalDesignComponent? {
        guard !instance.instancePath.isEmpty, var view = components[instance.componentID] else { return nil }
        let connected = instanceNets[instance.id] ?? [:]
        let noConnect = instanceNoConnects[instance.id] ?? []
        view.instanceOf = view.id
        view.instancePath = instance.instancePath
        view.id = instance.id
        view.refdes = instance.refdes
        view.noPopulate = instance.noPopulate
        view.boardPlacement = instance.boardPlacement
        view.pins = view.pins.map { pin in
            var pin = pin
            let key = pin.gatePinPath.lowercased()
            pin.netID = connected[key]
            pin.connectionState = noConnect.contains(key) ? "no_connect" : (pin.netID == nil ? "unconnected" : "connected")
            return pin
        }
        return view
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

    /// A component by refdes: the top block's, else the one instance of a
    /// sub-block's component that has it (read through that instance), else
    /// a sub-block's own component — the refdes its instances show unless
    /// their mapping gives them another.
    func component(refdes: String) -> HorizontalDesignComponent? {
        let named = components.values.filter { $0.refdes.caseInsensitiveCompare(refdes) == .orderedSame }
        let isTop = { (component: HorizontalDesignComponent) in component.blockID == nil || component.blockID?.lowercased() == topBlockID }
        if let id = componentIDsByRefdes[refdes], let component = components[id], isTop(component) {
            return component
        }
        if let component = named.first(where: isTop) {
            return component
        }
        let uses = instances.filter { !$0.instancePath.isEmpty && $0.refdes.caseInsensitiveCompare(refdes) == .orderedSame }
        if uses.count == 1, let view = component(instance: uses[0]) {
            return view
        }
        return componentIDsByRefdes[refdes].flatMap { components[$0] } ?? named.first
    }

    /// A component by uuid, an instance's flat uuid among them.
    func component(id: String) -> HorizontalDesignComponent? {
        let id = id.lowercased()
        if let component = components[id] {
            return component
        }
        return instances.first { $0.id == id }.flatMap { component(instance: $0) }
    }

    func net(named name: String) -> HorizontalDesignNet? {
        if let id = netIDsByName[name], let net = nets[id] {
            return net
        }
        let found = nets(named: name)
        return found.count == 1 ? found[0] : found.first
    }

    func net(id: String) -> HorizontalDesignNet? {
        nets[id.lowercased()]
    }

    /// A net's name, a flattened instance net's among them.
    func netName(id: String) -> String? {
        nets[id.lowercased()]?.name ?? flattenedNetNames[id.lowercased()]
    }

    /// The uses of a sub-block's component, one per instance.
    func instances(of componentID: String) -> [HorizontalDesignInstance] {
        let id = componentID.lowercased()
        return instances.filter { $0.componentID == id && !$0.instancePath.isEmpty }
    }

    /// A component by its id, or by eight or more of the id's leading digits
    /// when only one id begins that way: an unnamed net or a part copied from
    /// a reply's "33b623e6…" is named the way it was shown.
    func component(idOrPrefix reference: String) throws -> HorizontalDesignComponent? {
        if let component = component(id: reference) { return component }
        let ids = Array(components.keys) + instances.filter { !$0.instancePath.isEmpty }.map(\.id)
        return try HorizontalDispatchValidation.id(matchingPrefix: reference, in: ids, kind: "component").flatMap { component(id: $0) }
    }

    func net(idOrPrefix reference: String) throws -> HorizontalDesignNet? {
        if let net = net(id: reference) { return net }
        return try HorizontalDispatchValidation.id(matchingPrefix: reference, in: nets.keys, kind: "net").flatMap { nets[$0] }
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
    private var symbolJSONs: [String: JSONDictionary] = [:]
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
            symbolJSONs[uuid] = json
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

    /// A pool symbol's own JSON: what Smash takes its texts from.
    func symbol(_ id: String) -> JSONDictionary? {
        symbolJSONs[id.lowercased()]
    }

    /// The package a part draws on the board, through its base.
    func package(forPart partID: String) -> JSONDictionary? {
        resolvedPart(partID)?.string("package").flatMap { packages[$0.lowercased()] }
    }

    func package(_ id: String) -> JSONDictionary? {
        packages[id.lowercased()]
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

    /// A project-pool part as `HorizontalPoolPart` gives it, read from this
    /// index — so from the snapshot, staged pool items included. The
    /// project's part list leaves out a part another derives from, and a
    /// `.horizontal` package's pool can't be read off disk, so this is how an
    /// edit names such a part.
    func poolPart(_ id: String) -> HorizontalPoolPart? {
        let id = id.lowercased()
        guard let json = parts[id] else { return nil }
        let part = HorizontalPartRecord.resolve(json) { parts[$0] }
        let entity = part.entityID.flatMap { entities[$0] }
        let packageName = part.packageID.flatMap { packages[$0]?.string("name") }.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = part.prefix.flatMap { $0.isEmpty ? nil : $0 }
        let gates = (entity?.gates ?? [:]).map { gateID, gate in
            HorizontalPoolPartGate(id: gateID, suffix: gate.suffix, unitID: gate.unitID ?? "",
                                   symbolID: gate.unitID.flatMap { symbolsByUnit[$0]?.first })
        }.sorted { $0.suffix.localizedStandardCompare($1.suffix) == .orderedAscending }
        return HorizontalPoolPart(
            id: id,
            mpn: part.mpn.isEmpty ? String(id.prefix(8)) : part.mpn,
            manufacturer: part.manufacturer,
            partDescription: part.description,
            packageName: packageName ?? part.packageID.map { String($0.prefix(8)) } ?? "",
            tags: part.tags,
            value: part.value,
            displayValue: part.displayValue,
            entityID: part.entityID,
            refdesPrefix: prefix ?? entity.map { $0.prefix.isEmpty ? "U" : $0.prefix } ?? "U",
            gates: gates,
            packageID: part.packageID,
            prefixOverride: prefix,
            isBasePart: part.isBasePart,
            excludeFromBOM: part.excludeFromBOM,
            excludeFromPnP: part.excludeFromPnP
        )
    }

    /// The value the part stores, through its base: empty when it has none.
    func partValue(_ id: String) -> String? {
        guard let part = parts[id.lowercased()] else { return nil }
        return HorizontalPartRecord.resolve(part) { parts[$0] }.value
    }

    /// What Horizon shows as the part's value (`Part::get_value`): its value
    /// attribute through its base, or its MPN when it has none.
    func partDisplayValue(_ id: String) -> String? {
        guard let part = parts[id.lowercased()] else { return nil }
        return HorizontalPartRecord.resolve(part) { parts[$0] }.displayValue
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
