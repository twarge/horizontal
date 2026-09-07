import Foundation
import HorizontalProjectIO

/// The edit vocabulary: operations as data, applied to the project files the
/// way Horizon lays them out. Every headless front end submits these, and the
/// app's live channel will take the same ones onto its undo stack.
enum HorizontalEditOperationKind: String, CaseIterable {
    case ensureComponent = "ensure_component"
    case removeComponent = "remove_component"
    case setValue = "set_value"
    case setRefdes = "set_refdes"
    case setPart = "set_part"
    case setNoPopulate = "set_no_populate"
    case setGroupTag = "set_group_tag"
    case ensureNet = "ensure_net"
    case renameNet = "rename_net"
    case setNetClass = "set_net_class"
    case retireNet = "retire_net"
    case connect = "connect"
    case disconnect = "disconnect"
    case placeComponent = "place_component"
    case removePlacement = "remove_placement"
    case copyGroupLayout = "copy_group_layout"

    var summary: String {
        switch self {
        case .ensureComponent: "Create a block component if it does not exist; returns its id."
        case .removeComponent: "Remove a component, its symbols, its board package, and the copper attached to it."
        case .setValue: "Set a component's value."
        case .setRefdes: "Set a component's reference designator."
        case .setPart: "Assign a pool part (and its entity) to a component; null clears the part."
        case .setNoPopulate: "Mark a component do-not-populate or not."
        case .setGroupTag: "Set the group and tag names Horizon uses to copy placement between identical sub-circuits."
        case .ensureNet: "Create a net if no net has that id or name; returns its id."
        case .renameNet: "Rename a net."
        case .setNetClass: "Put a net in a net class, by name or id."
        case .retireNet: "Remove a net and every connection to it."
        case .connect: "Connect a component pin to a net."
        case .disconnect: "Remove a pin's connection."
        case .placeComponent: "Place a component's package on the board, or move it if it is placed."
        case .removePlacement: "Take a component's package off the board, keeping its copper as junctions."
        case .copyGroupLayout: "Copy the placement (and by default the routing) of one group's packages onto another group whose components carry the same tags."
        }
    }

    var params: [String: String] {
        let component = "Reference designator or component id."
        switch self {
        case .ensureComponent:
            return ["id": "Component id to use (optional).", "refdes": "Reference designator (optional; defaults to the entity's prefix plus ?).", "part": "Pool part id.", "entity": "Pool entity id (when there is no part).", "value": "Value (optional).", "group": "Group name (optional).", "tag": "Tag name (optional)."]
        case .removeComponent, .removePlacement:
            return ["component": component]
        case .setValue:
            return ["component": component, "value": "New value."]
        case .setRefdes:
            return ["component": component, "refdes": "New reference designator."]
        case .setPart:
            return ["component": component, "part": "Pool part id, or null."]
        case .setNoPopulate:
            return ["component": component, "no_populate": "true or false."]
        case .setGroupTag:
            return ["component": component, "group": "Group name, or null.", "tag": "Tag name, or null."]
        case .ensureNet:
            return ["id": "Net id to use (optional).", "name": "Net name.", "net_class": "Net class name or id (optional).", "is_power": "Power net (optional)."]
        case .renameNet:
            return ["net": "Net name or id.", "name": "New name."]
        case .setNetClass:
            return ["net": "Net name or id.", "net_class": "Net class name or id."]
        case .retireNet:
            return ["net": "Net name or id."]
        case .connect:
            return ["component": component, "pin": "Pin as gate/pin names, a pin name unique across gates, or gate/pin ids.", "net": "Net name or id.", "create_net": "Create the net when it does not exist (default false)."]
        case .disconnect:
            return ["component": component, "pin": "Pin as for connect."]
        case .placeComponent:
            return ["component": component, "x_mm": "X position.", "y_mm": "Y position.", "angle_deg": "Rotation (optional, default 0 or unchanged).", "bottom": "Place on the bottom side (optional)."]
        case .copyGroupLayout:
            return [
                "source": "Group name or id whose layout to copy.",
                "target": "Group name or id to lay out.",
                "x_mm": "Where the target's anchor member goes (optional; default: where it already is, else beside the source).",
                "y_mm": "Y of the anchor (optional).",
                "angle_deg": "Rotation of the whole copy (optional; default: the anchor's current rotation, else the source's).",
                "include_routing": "Also copy the tracks and vias inside the source group (default true)."
            ]
        }
    }
}

struct HorizontalEditOperation {
    var kind: HorizontalEditOperationKind
    var params: JSONDictionary

    init(json: JSONDictionary) throws {
        guard let name = json.string("op") else {
            throw HorizontalDispatchError.invalidParams("Every operation needs an \"op\".")
        }
        guard let kind = HorizontalEditOperationKind(rawValue: name) else {
            throw HorizontalDispatchError.invalidParams("Unknown op \(name). Known: \(HorizontalEditOperationKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        self.kind = kind
        params = json
    }
}

/// Where the editor reads project files from and writes them to: the disk
/// for headless use, the open document's archive for the live channel.
protocol HorizontalProjectFileStore {
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
}

struct HorizontalDiskFileStore: HorizontalProjectFileStore {
    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

/// The document's archive: file URLs map to archive paths through the
/// manifest `completeProject` recorded, or relative to the project's base
/// for a `.horizontal` package.
final class HorizontalArchiveFileStore: HorizontalProjectFileStore {
    private(set) var archive: HorizontalProjectArchive
    private let baseURL: URL

    init(archive: HorizontalProjectArchive, baseURL: URL) {
        self.archive = archive
        self.baseURL = baseURL
    }

    func relativePath(for url: URL) -> String? {
        if let path = archive.manifest?.relativePath(for: url) {
            return path
        }
        let base = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else {
            return nil
        }
        return String(path.dropFirst(base.count + 1))
    }

    func read(_ url: URL) throws -> Data? {
        guard let path = relativePath(for: url) else {
            return nil
        }
        return archive.regularFileData(relativePath: path)
    }

    func write(_ data: Data, to url: URL) throws {
        guard let path = relativePath(for: url) else {
            throw HorizontalDispatchError.failed("Could not map \(url.lastPathComponent) into the document archive.")
        }
        try archive.replaceRegularFileData(relativePath: path, with: data)
    }
}

/// Applies edit operations to the JSON files of a loaded project and writes
/// only the files that changed, formatted the way Horizon writes them.
final class HorizontalProjectEditor {
    static let nullUUID = "00000000-0000-0000-0000-000000000000"
    /// Namespace for group and tag ids derived from their names, so the same
    /// name yields the same id in every project and every run.
    private static let groupTagNamespace = UUID(uuidString: "6e1f2b6c-5c0d-4d7e-9a3f-2b0f4a8c1d21")!

    private let project: HorizontalProject
    private let store: HorizontalProjectFileStore
    private let pool: HorizontalDispatchPoolIndex
    private let poolURL: URL?
    private var files: [String: JSONDictionary] = [:]
    private var fileURLs: [String: URL] = [:]
    private var dirty = Set<String>()
    private(set) var changes: [JSONDictionary] = []

    init(project: HorizontalProject, store: HorizontalProjectFileStore = HorizontalDiskFileStore()) throws {
        self.project = project
        self.store = store
        pool = HorizontalDispatchPoolIndex(project: project)
        poolURL = project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }
        let blockFilename = project.blocks.first(where: \.isTop)?.blockFilename ?? project.blockFilename
        guard let blockFilename, !blockFilename.isEmpty else {
            throw HorizontalDispatchError.failed("The project has no top block file to edit.")
        }
        try load("block", url: project.baseURL.appendingPathComponent(blockFilename))
        if let schematicFilename = project.blocks.first(where: \.isTop)?.schematicFilename ?? project.schematicFilename, !schematicFilename.isEmpty {
            try load("schematic", url: project.baseURL.appendingPathComponent(schematicFilename))
        }
        if let boardFilename = project.boardFilename, !boardFilename.isEmpty {
            try load("board", url: project.baseURL.appendingPathComponent(boardFilename))
        }
    }

    private func load(_ key: String, url: URL) throws {
        guard let data = try store.read(url) else {
            return
        }
        files[key] = try JSONHelper.loadDictionary(from: data)
        fileURLs[key] = url
    }

    // MARK: - Applying

    func apply(_ operations: [HorizontalEditOperation]) throws {
        for operation in operations {
            try apply(operation)
        }
    }

    private func apply(_ operation: HorizontalEditOperation) throws {
        let params = operation.params
        var change: JSONDictionary = ["op": operation.kind.rawValue]
        switch operation.kind {
        case .ensureComponent:
            let (id, created) = try ensureComponent(params)
            change["component"] = id
            change["created"] = created
        case .removeComponent:
            let id = try componentID(params)
            change["component"] = id
            change["removed"] = removeComponent(id)
        case .setValue:
            let id = try componentID(params)
            guard let value = params["value"] as? String else {
                throw HorizontalDispatchError.invalidParams("set_value needs \"value\".")
            }
            try updateComponent(id) { $0["value"] = value }
            change["component"] = id
            change["value"] = value
            // Horizon shows a part's own value over the component's, so a
            // value set on a part-backed component only matters once the
            // part is cleared or has no value of its own.
            if let partID = components()[id]?.string("part")?.lowercased(),
               let part = poolPart(partID), !part.value.isEmpty {
                change["note"] = "The part \(part.mpn) defines the value \(part.value), which Horizontal shows instead."
            }
        case .setRefdes:
            let id = try componentID(params)
            guard let refdes = params.string("refdes"), !refdes.isEmpty else {
                throw HorizontalDispatchError.invalidParams("set_refdes needs \"refdes\".")
            }
            try updateComponent(id) { $0["refdes"] = refdes }
            change["component"] = id
            change["refdes"] = refdes
        case .setPart:
            let id = try componentID(params)
            change["component"] = id
            change["cleared_connections"] = try setPart(id, partID: params["part"] as? String)
        case .setNoPopulate:
            let id = try componentID(params)
            guard let flag = params.bool("no_populate") else {
                throw HorizontalDispatchError.invalidParams("set_no_populate needs \"no_populate\".")
            }
            try updateComponent(id) { $0["nopopulate"] = flag }
            change["component"] = id
            change["no_populate"] = flag
        case .setGroupTag:
            let id = try componentID(params)
            let group = params["group"] as? String
            let tag = params["tag"] as? String
            try updateComponent(id) { component in
                component["group"] = self.nameID(group, table: "group_names")
                component["tag"] = self.nameID(tag, table: "tag_names")
            }
            change["component"] = id
            change["group"] = group ?? NSNull()
            change["tag"] = tag ?? NSNull()
        case .ensureNet:
            let (id, created) = try ensureNet(params)
            change["net"] = id
            change["created"] = created
        case .renameNet:
            let id = try netID(params)
            guard let name = params.string("name"), !name.isEmpty else {
                throw HorizontalDispatchError.invalidParams("rename_net needs \"name\".")
            }
            try updateNet(id) { $0["name"] = name }
            change["net"] = id
            change["name"] = name
        case .setNetClass:
            let id = try netID(params)
            guard let netClass = params.string("net_class") else {
                throw HorizontalDispatchError.invalidParams("set_net_class needs \"net_class\".")
            }
            let classID = try netClassID(netClass)
            try updateNet(id) { $0["net_class"] = classID }
            change["net"] = id
            change["net_class"] = classID
        case .retireNet:
            let id = try netID(params)
            change["net"] = id
            change["removed"] = retireNet(id)
        case .connect:
            let id = try componentID(params)
            let pin = try pinPath(params, componentID: id)
            let net: String
            if let existing = try? netID(params) {
                net = existing
            } else if params.bool("create_net") ?? false, let name = params.string("net") {
                net = try ensureNet(["name": name]).0
            } else {
                throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
            }
            try updateComponent(id) { component in
                var connections = component["connections"] as? JSONDictionary ?? [:]
                connections[pin] = ["net": net]
                component["connections"] = connections
            }
            change["component"] = id
            change["pin"] = pin
            change["net"] = net
        case .disconnect:
            let id = try componentID(params)
            let pin = try pinPath(params, componentID: id)
            try updateComponent(id) { component in
                var connections = component["connections"] as? JSONDictionary ?? [:]
                connections.removeValue(forKey: pin)
                component["connections"] = connections
            }
            change["component"] = id
            change["pin"] = pin
        case .placeComponent:
            let id = try componentID(params)
            change["component"] = id
            change["package"] = try placeComponent(id, params)
        case .removePlacement:
            let id = try componentID(params)
            change["component"] = id
            change["removed_packages"] = removeBoardPackages(componentID: id)
        case .copyGroupLayout:
            let result = try copyGroupLayout(params)
            change.merge(result) { _, new in new }
        }
        changes.append(change)
    }

    // MARK: - Writing

    /// Writes every changed file and returns their paths. Files are written
    /// the way Horizon writes them (four-space indent, byte-ordered keys, no
    /// trailing newline), so an edit shows up in `git diff` as the lines it
    /// touched rather than a reformatted file.
    func write() throws -> [String] {
        var written = [String]()
        for key in dirty.sorted() {
            guard let json = files[key], let url = fileURLs[key] else {
                continue
            }
            let data = try HorizontalHorizonJSONWriter.data(json)
            try store.write(data, to: url)
            written.append(url.path)
        }
        return written
    }

    var changedFiles: [String] {
        dirty.sorted().compactMap { fileURLs[$0]?.path }
    }

    // MARK: - Components

    private var block: JSONDictionary {
        get { files["block"] ?? [:] }
        set { files["block"] = newValue; dirty.insert("block") }
    }

    private func components() -> [String: JSONDictionary] {
        block.dictionaryMap("components")
    }

    private func componentID(_ params: JSONDictionary) throws -> String {
        guard let reference = params.string("component"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"component\" (a reference designator or id).")
        }
        return try componentID(reference: reference)
    }

    private func componentID(reference: String) throws -> String {
        let all = components()
        if let match = all.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byRefdes = all.filter { ($0.value.string("refdes") ?? "") == reference }
        if byRefdes.count == 1, let match = byRefdes.keys.first {
            return match
        }
        if byRefdes.count > 1 {
            throw HorizontalDispatchError.invalidParams("\(byRefdes.count) components are named \(reference); use the id.")
        }
        throw HorizontalDispatchError.notFound("No component \(reference).")
    }

    private func updateComponent(_ id: String, _ body: (inout JSONDictionary) -> Void) throws {
        var all = block["components"] as? JSONDictionary ?? [:]
        guard var component = all[id] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No component \(id).")
        }
        body(&component)
        all[id] = component
        block["components"] = all
    }

    private func ensureComponent(_ params: JSONDictionary) throws -> (String, Bool) {
        if let id = params.string("id")?.lowercased(), components()[id] != nil {
            return (id, false)
        }
        if params.string("id") == nil, let refdes = params.string("refdes"), let existing = try? componentID(reference: refdes) {
            return (existing, false)
        }
        var entityID = params.string("entity")?.lowercased()
        let partID = params.string("part")?.lowercased()
        if let partID {
            guard let part = poolPart(partID) else {
                throw HorizontalDispatchError.notFound("No pool part \(partID).")
            }
            entityID = part.entityID?.lowercased() ?? entityID
        }
        guard let entityID else {
            throw HorizontalDispatchError.invalidParams("ensure_component needs a \"part\" or an \"entity\".")
        }
        guard let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("No pool entity \(entityID).")
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        var component: JSONDictionary = [
            "alt_pins": [String: Any](),
            "connections": [String: Any](),
            "entity": entityID,
            "group": nameID(params.string("group"), table: "group_names"),
            "pin_names": [String: Any](),
            "refdes": params.string("refdes") ?? "\(entity.prefix.isEmpty ? "X" : entity.prefix)?",
            "tag": nameID(params.string("tag"), table: "tag_names"),
            "value": params.string("value") ?? ""
        ]
        if let partID {
            component["part"] = partID
        }
        var all = block["components"] as? JSONDictionary ?? [:]
        all[id] = component
        block["components"] = all
        return (id, true)
    }

    private func setPart(_ id: String, partID: String?) throws -> Bool {
        var clearedConnections = false
        if let partID {
            guard let part = poolPart(partID.lowercased()) else {
                throw HorizontalDispatchError.notFound("No pool part \(partID).")
            }
            try updateComponent(id) { component in
                let previousEntity = component.string("entity")?.lowercased()
                component["part"] = partID.lowercased()
                if let entityID = part.entityID?.lowercased() {
                    if let previousEntity, previousEntity != entityID {
                        component["connections"] = [String: Any]()
                        component["alt_pins"] = [String: Any]()
                        clearedConnections = true
                    }
                    component["entity"] = entityID
                }
            }
        } else {
            try updateComponent(id) { $0.removeValue(forKey: "part") }
        }
        return clearedConnections
    }

    private func removeComponent(_ id: String) -> JSONDictionary {
        var all = block["components"] as? JSONDictionary ?? [:]
        all.removeValue(forKey: id)
        block["components"] = all
        let symbols = removeSchematicSymbols(componentID: id)
        let packages = removeBoardPackages(componentID: id)
        return ["symbols": symbols, "packages": packages]
    }

    private func poolPart(_ id: String) -> HorizontalPoolPart? {
        if let part = project.poolParts.first(where: { $0.id.lowercased() == id }) {
            return part
        }
        guard let poolURL else {
            return nil
        }
        return HorizontalPoolPart.loadCached(id: id, from: poolURL)
    }

    // MARK: - Nets

    private func nets() -> [String: JSONDictionary] {
        block.dictionaryMap("nets")
    }

    private func netID(_ params: JSONDictionary) throws -> String {
        guard let reference = params.string("net"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"net\" (a name or id).")
        }
        return try netID(reference: reference)
    }

    private func netID(reference: String) throws -> String {
        let all = nets()
        if let match = all.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byName = all.filter { ($0.value.string("name") ?? "") == reference }
        if byName.count == 1, let match = byName.keys.first {
            return match
        }
        if byName.count > 1 {
            throw HorizontalDispatchError.invalidParams("\(byName.count) nets are named \(reference); use the id.")
        }
        throw HorizontalDispatchError.notFound("No net \(reference).")
    }

    private func updateNet(_ id: String, _ body: (inout JSONDictionary) -> Void) throws {
        var all = block["nets"] as? JSONDictionary ?? [:]
        guard var net = all[id] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No net \(id).")
        }
        body(&net)
        all[id] = net
        block["nets"] = all
    }

    private func ensureNet(_ params: JSONDictionary) throws -> (String, Bool) {
        if let id = params.string("id")?.lowercased(), nets()[id] != nil {
            return (id, false)
        }
        guard let name = params.string("name"), !name.isEmpty else {
            throw HorizontalDispatchError.invalidParams("ensure_net needs a \"name\".")
        }
        if params.string("id") == nil, let existing = try? netID(reference: name) {
            return (existing, false)
        }
        let classID = try params.string("net_class").map(netClassID) ?? (block.string("net_class_default") ?? Self.nullUUID)
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        let net: JSONDictionary = [
            "is_port": false,
            "is_power": params.bool("is_power") ?? false,
            "name": name,
            "net_class": classID,
            "port_direction": "bidirectional",
            "power_symbol_name_visible": true,
            "power_symbol_style": "gnd"
        ]
        var all = block["nets"] as? JSONDictionary ?? [:]
        all[id] = net
        block["nets"] = all
        return (id, true)
    }

    private func netClassID(_ reference: String) throws -> String {
        let classes = block.dictionaryMap("net_classes")
        if let match = classes.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        if let match = classes.first(where: { ($0.value.string("name") ?? "").caseInsensitiveCompare(reference) == .orderedSame }) {
            return match.key
        }
        throw HorizontalDispatchError.notFound("No net class \(reference). Known: \(classes.values.compactMap { $0.string("name") }.sorted().joined(separator: ", ")).")
    }

    private func retireNet(_ id: String) -> JSONDictionary {
        var all = block["nets"] as? JSONDictionary ?? [:]
        all.removeValue(forKey: id)
        block["nets"] = all

        var disconnected = 0
        var componentsMap = block["components"] as? JSONDictionary ?? [:]
        for (componentID, value) in componentsMap {
            guard var component = value as? JSONDictionary,
                  var connections = component["connections"] as? JSONDictionary else {
                continue
            }
            let before = connections.count
            connections = connections.filter { ($0.value as? JSONDictionary)?.string("net")?.lowercased() != id }
            guard connections.count != before else {
                continue
            }
            disconnected += before - connections.count
            component["connections"] = connections
            componentsMap[componentID] = component
        }
        block["components"] = componentsMap

        var powerSymbols = 0
        if var schematic = files["schematic"] {
            var sheets = schematic["sheets"] as? JSONDictionary ?? [:]
            for (sheetID, value) in sheets {
                guard var sheet = value as? JSONDictionary else {
                    continue
                }
                var symbols = sheet["power_symbols"] as? JSONDictionary ?? [:]
                let before = symbols.count
                symbols = symbols.filter { ($0.value as? JSONDictionary)?.string("net")?.lowercased() != id }
                if symbols.count != before {
                    powerSymbols += before - symbols.count
                    sheet["power_symbols"] = symbols
                    sheets[sheetID] = sheet
                }
            }
            if powerSymbols > 0 {
                schematic["sheets"] = sheets
                files["schematic"] = schematic
                dirty.insert("schematic")
            }
        }
        return ["connections": disconnected, "power_symbols": powerSymbols]
    }

    // MARK: - Pins

    /// Resolves the `pin` parameter to Horizon's `gate uuid/pin uuid` key.
    private func pinPath(_ params: JSONDictionary, componentID: String) throws -> String {
        guard let reference = params.string("pin"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"pin\".")
        }
        guard let component = components()[componentID], let entityID = component.string("entity")?.lowercased() else {
            throw HorizontalDispatchError.notFound("Component \(componentID) has no entity.")
        }
        guard let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("Pool entity \(entityID) for \(componentID) is not in the project pool.")
        }
        let pieces = reference.split(separator: "/", maxSplits: 1).map(String.init)
        if pieces.count == 2 {
            let gateReference = pieces[0]
            let pinReference = pieces[1]
            let gateMatches = entity.gates.filter { gateID, gate in
                gateID.caseInsensitiveCompare(gateReference) == .orderedSame
                    || gate.name.caseInsensitiveCompare(gateReference) == .orderedSame
                    || (!gate.suffix.isEmpty && gate.suffix.caseInsensitiveCompare(gateReference) == .orderedSame)
            }
            guard gateMatches.count == 1, let (gateID, gate) = gateMatches.first else {
                throw HorizontalDispatchError.notFound("No gate \(gateReference) on \(entity.name). Gates: \(entity.gates.values.map(\.name).sorted().joined(separator: ", ")).")
            }
            guard let unitID = gate.unitID, let unit = pool.unit(unitID) else {
                throw HorizontalDispatchError.notFound("Gate \(gate.name) has no unit in the project pool.")
            }
            guard let pinID = pinID(pinReference, in: unit) else {
                throw HorizontalDispatchError.notFound("No pin \(pinReference) on gate \(gate.name). Pins: \(unit.pins.values.map(\.name).sorted().joined(separator: ", ")).")
            }
            return "\(gateID)/\(pinID)"
        }
        var matches = [String]()
        for (gateID, gate) in entity.gates {
            guard let unitID = gate.unitID, let unit = pool.unit(unitID), let pinID = pinID(reference, in: unit) else {
                continue
            }
            matches.append("\(gateID)/\(pinID)")
        }
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty {
                throw HorizontalDispatchError.notFound("No pin \(reference) on \(entity.name).")
            }
            throw HorizontalDispatchError.invalidParams("Pin \(reference) is on \(matches.count) gates of \(entity.name); name the gate as gate/pin.")
        }
        return match
    }

    private func pinID(_ reference: String, in unit: HorizontalDispatchPoolIndex.Unit) -> String? {
        if let match = unit.pins.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byName = unit.pins.filter { $0.value.name.caseInsensitiveCompare(reference) == .orderedSame }
        return byName.count == 1 ? byName.keys.first : nil
    }

    // MARK: - Groups and tags

    private func nameID(_ name: String?, table: String) -> String {
        guard let name, !name.isEmpty else {
            return Self.nullUUID
        }
        var names = block[table] as? JSONDictionary ?? [:]
        if let existing = names.first(where: { ($0.value as? String) == name }) {
            return existing.key
        }
        let id = UUID.horizonUUID5(namespace: Self.groupTagNamespace, name: Array("\(table):\(name)".utf8)).uuidString.lowercased()
        names[id] = name
        block[table] = names
        return id
    }

    // MARK: - Schematic

    private func removeSchematicSymbols(componentID: String) -> Int {
        guard var schematic = files["schematic"] else {
            return 0
        }
        var removed = 0
        var sheets = schematic["sheets"] as? JSONDictionary ?? [:]
        for (sheetID, value) in sheets {
            guard var sheet = value as? JSONDictionary else {
                continue
            }
            var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
            let doomed = symbols.filter { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == componentID }
            guard !doomed.isEmpty else {
                continue
            }
            let doomedIDs = Set(doomed.keys.map { $0.lowercased() })
            var doomedTextIDs = Set<String>()
            for (id, symbol) in doomed {
                symbols.removeValue(forKey: id)
                for textID in (symbol as? JSONDictionary)?["texts"] as? [String] ?? [] {
                    doomedTextIDs.insert(textID.lowercased())
                }
            }
            removed += doomed.count
            sheet["symbols"] = symbols
            var lines = sheet["net_lines"] as? JSONDictionary ?? [:]
            lines = lines.filter { _, value in
                guard let line = value as? JSONDictionary else {
                    return true
                }
                for end in ["from", "to"] {
                    if let pin = line.dictionary(end)?.string("pin"), let symbolID = pin.split(separator: "/").first, doomedIDs.contains(String(symbolID).lowercased()) {
                        return false
                    }
                }
                return true
            }
            sheet["net_lines"] = lines
            if !doomedTextIDs.isEmpty {
                var texts = sheet["texts"] as? JSONDictionary ?? [:]
                texts = texts.filter { !doomedTextIDs.contains($0.key.lowercased()) }
                sheet["texts"] = texts
            }
            sheets[sheetID] = sheet
        }
        if removed > 0 {
            schematic["sheets"] = sheets
            files["schematic"] = schematic
            dirty.insert("schematic")
        }
        return removed
    }

    // MARK: - Board

    private func placeComponent(_ id: String, _ params: JSONDictionary) throws -> String {
        guard var board = files["board"] else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        var packages = board["packages"] as? JSONDictionary ?? [:]
        let existing = packages.first { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == id }
        var package = existing?.value as? JSONDictionary ?? [
            "component": id,
            "fixed": false,
            "flip": false,
            "omit_silkscreen": false,
            "smashed": false,
            "texts": [String]()
        ]
        var placement = package["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Int((x * 1_000_000).rounded()), Int((y * 1_000_000).rounded())]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_component needs \"x_mm\" and \"y_mm\" for a package that is not on the board yet.")
        }
        if let degrees = params.double("angle_deg") {
            var angle = Int((degrees / 360 * 65_536).rounded()) % 65_536
            if angle < 0 {
                angle += 65_536
            }
            placement["angle"] = angle
        }
        if let bottom = params.bool("bottom") {
            placement["mirror"] = bottom
            package["flip"] = bottom
        }
        package["placement"] = placement
        let packageID = existing?.key ?? UUID().uuidString.lowercased()
        packages[packageID] = package
        board["packages"] = packages
        files["board"] = board
        dirty.insert("board")
        return packageID
    }

    // MARK: - Group layout copy

    private func groupID(_ reference: String) throws -> String {
        let names = block["group_names"] as? [String: String] ?? [:]
        if let match = names.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byName = names.filter { $0.value == reference }
        if byName.count == 1, let match = byName.keys.first {
            return match
        }
        if byName.count > 1 {
            throw HorizontalDispatchError.invalidParams("\(byName.count) groups are named \(reference); use the id.")
        }
        throw HorizontalDispatchError.notFound("No group \(reference). Known: \(names.values.sorted().joined(separator: ", ")).")
    }

    private struct GroupMember {
        var componentID: String
        var tagID: String
        var partID: String?
        var packageID: String?
        var placement: JSONDictionary?
        var flip: Bool
    }

    private func members(ofGroup groupID: String) -> [String: GroupMember] {
        let packages = (files["board"] ?? [:]).dictionaryMap("packages")
        var result = [String: GroupMember]()
        for (componentID, component) in components() where component.string("group")?.lowercased() == groupID.lowercased() {
            let tagID = component.string("tag")?.lowercased() ?? Self.nullUUID
            guard tagID != Self.nullUUID else {
                continue
            }
            let package = packages.first { ($0.value.string("component") ?? "").lowercased() == componentID.lowercased() }
            result[tagID] = GroupMember(
                componentID: componentID,
                tagID: tagID,
                partID: component.string("part")?.lowercased(),
                packageID: package?.key,
                placement: package?.value.dictionary("placement"),
                flip: package?.value.bool("flip") ?? false
            )
        }
        return result
    }

    private static func rotate(_ x: Double, _ y: Double, angle: Int) -> (Double, Double) {
        let radians = Double(angle) / 65_536 * 2 * Double.pi
        return (x * cos(radians) - y * sin(radians), x * sin(radians) + y * cos(radians))
    }

    private static func shift(_ placement: JSONDictionary?) -> (Double, Double) {
        guard let shift = placement?["shift"] as? [Any], shift.count == 2 else {
            return (0, 0)
        }
        return (JSONHelper.doubleValue(shift[0]), JSONHelper.doubleValue(shift[1]))
    }

    private func copyGroupLayout(_ params: JSONDictionary) throws -> JSONDictionary {
        guard files["board"] != nil else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        guard let sourceReference = params.string("source"), let targetReference = params.string("target") else {
            throw HorizontalDispatchError.invalidParams("copy_group_layout needs \"source\" and \"target\".")
        }
        let sourceID = try groupID(sourceReference)
        let targetID = try groupID(targetReference)
        guard sourceID.lowercased() != targetID.lowercased() else {
            throw HorizontalDispatchError.invalidParams("Source and target are the same group.")
        }
        let source = members(ofGroup: sourceID)
        let target = members(ofGroup: targetID)
        let tagNames = block["tag_names"] as? [String: String] ?? [:]
        let shared = source.keys.filter { target[$0] != nil && source[$0]?.placement != nil }
            .sorted { (tagNames[$0] ?? $0).localizedStandardCompare(tagNames[$1] ?? $1) == .orderedAscending }
        guard let anchorTag = shared.first, let sourceAnchor = source[anchorTag], let targetAnchor = target[anchorTag] else {
            throw HorizontalDispatchError.notFound("The groups share no placed member with a common tag.")
        }

        // Where the copy goes: the target anchor's own placement, an explicit
        // position, or beside the source.
        let (sourceAnchorX, sourceAnchorY) = Self.shift(sourceAnchor.placement)
        let sourceAnchorAngle = sourceAnchor.placement?.int("angle") ?? 0
        var targetX: Double
        var targetY: Double
        var targetAngle: Int
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            targetX = (x * 1_000_000).rounded()
            targetY = (y * 1_000_000).rounded()
            targetAngle = params.double("angle_deg").map { Int(($0 / 360 * 65_536).rounded()) % 65_536 } ?? sourceAnchorAngle
        } else if let placement = targetAnchor.placement {
            (targetX, targetY) = Self.shift(placement)
            targetAngle = params.double("angle_deg").map { Int(($0 / 360 * 65_536).rounded()) % 65_536 } ?? (placement.int("angle") ?? sourceAnchorAngle)
        } else {
            let xs = source.values.compactMap { $0.placement.map { Self.shift($0).0 } }
            let width = (xs.max() ?? sourceAnchorX) - (xs.min() ?? sourceAnchorX)
            targetX = sourceAnchorX + width + 5_000_000
            targetY = sourceAnchorY
            targetAngle = sourceAnchorAngle
        }
        if targetAngle < 0 {
            targetAngle += 65_536
        }
        let deltaAngle = (targetAngle - sourceAnchorAngle + 65_536) % 65_536
        let flip = targetAnchor.placement != nil ? targetAnchor.flip : sourceAnchor.flip
        let mirrorX = flip != sourceAnchor.flip

        var board = files["board"]!
        var packages = board["packages"] as? JSONDictionary ?? [:]
        var packageMap = [String: String]()   // source board package id -> target board package id
        var placed = 0
        for tag in shared {
            guard let member = source[tag], let placement = member.placement, let counterpart = target[tag] else {
                continue
            }
            let (x, y) = Self.shift(placement)
            var (dx, dy) = (x - sourceAnchorX, y - sourceAnchorY)
            var angle = placement.int("angle") ?? 0
            if mirrorX {
                dx = -dx
                angle = (65_536 - angle) % 65_536
            }
            let (rx, ry) = Self.rotate(dx, dy, angle: mirrorX ? (65_536 - deltaAngle) % 65_536 : deltaAngle)
            let newAngle = mirrorX
                ? ((angle - sourceAnchorAngle + targetAngle) % 65_536 + 65_536) % 65_536
                : (angle + deltaAngle) % 65_536
            let targetPackageID = counterpart.packageID ?? UUID().uuidString.lowercased()
            var package = packages[targetPackageID] as? JSONDictionary ?? [
                "component": counterpart.componentID,
                "fixed": false,
                "omit_silkscreen": false,
                "smashed": false,
                "texts": [String]()
            ]
            package["flip"] = flip
            package["placement"] = [
                "angle": newAngle,
                "mirror": flip,
                "shift": [Int((targetX + rx).rounded()), Int((targetY + ry).rounded())]
            ]
            packages[targetPackageID] = package
            if let sourcePackageID = member.packageID, member.partID == counterpart.partID {
                packageMap[sourcePackageID.lowercased()] = targetPackageID
            }
            placed += 1
        }
        board["packages"] = packages

        var copiedTracks = 0
        var copiedVias = 0
        var copiedJunctions = 0
        if params.bool("include_routing") ?? true {
            let transform: (Double, Double) -> (Int, Int) = { x, y in
                var dx = x - sourceAnchorX
                let dy = y - sourceAnchorY
                if mirrorX {
                    dx = -dx
                }
                let (rx, ry) = Self.rotate(dx, dy, angle: mirrorX ? (65_536 - deltaAngle) % 65_536 : deltaAngle)
                return (Int((targetX + rx).rounded()), Int((targetY + ry).rounded()))
            }
            let mapLayer: (Int) -> Int = { layer in
                guard mirrorX else {
                    return layer
                }
                if layer == 0 {
                    return -100
                }
                if layer == -100 {
                    return 0
                }
                return layer
            }
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            var junctions = board["junctions"] as? JSONDictionary ?? [:]
            var vias = board["vias"] as? JSONDictionary ?? [:]
            let sourcePackageIDs = Set(packageMap.keys)

            func padPackage(_ endpoint: JSONDictionary?) -> String? {
                guard let pad = endpoint?.string("pad") else {
                    return nil
                }
                return pad.split(separator: "/").first.map { String($0).lowercased() }
            }
            // The group's routing: tracks on its pads, and every track and
            // via reachable from those through junctions, as long as no end
            // touches a pad outside the group.
            var groupJunctions = Set<String>()
            var groupTracks = Set<String>()
            var frontier = true
            while frontier {
                frontier = false
                for (trackID, value) in tracks where !groupTracks.contains(trackID) {
                    guard let track = value as? JSONDictionary else {
                        continue
                    }
                    let ends = [track.dictionary("from"), track.dictionary("to")]
                    var touchesGroup = false
                    var leavesGroup = false
                    for end in ends {
                        if let package = padPackage(end) {
                            if sourcePackageIDs.contains(package) {
                                touchesGroup = true
                            } else {
                                leavesGroup = true
                            }
                        } else if let junction = end?.string("junc")?.lowercased(), groupJunctions.contains(junction) {
                            touchesGroup = true
                        }
                    }
                    guard touchesGroup, !leavesGroup else {
                        continue
                    }
                    groupTracks.insert(trackID)
                    frontier = true
                    for end in ends {
                        if let junction = end?.string("junc")?.lowercased() {
                            groupJunctions.insert(junction)
                        }
                    }
                }
            }
            var junctionMap = [String: String]()
            for junctionID in groupJunctions {
                guard let junction = junctions.first(where: { $0.key.lowercased() == junctionID })?.value as? JSONDictionary else {
                    continue
                }
                let (x, y) = Self.shift(["shift": junction["position"] as Any])
                let (nx, ny) = transform(x, y)
                let newID = UUID().uuidString.lowercased()
                junctions[newID] = ["position": [nx, ny]]
                junctionMap[junctionID] = newID
                copiedJunctions += 1
            }
            for trackID in groupTracks {
                guard var track = tracks[trackID] as? JSONDictionary else {
                    continue
                }
                var valid = true
                for end in ["from", "to"] {
                    guard var endpoint = track.dictionary(end) else {
                        valid = false
                        break
                    }
                    if let pad = endpoint.string("pad") {
                        let pieces = pad.split(separator: "/", maxSplits: 1).map(String.init)
                        guard pieces.count == 2, let mapped = packageMap[pieces[0].lowercased()] else {
                            valid = false
                            break
                        }
                        endpoint["pad"] = "\(mapped)/\(pieces[1])"
                        endpoint["junc"] = NSNull()
                    } else if let junction = endpoint.string("junc")?.lowercased(), let mapped = junctionMap[junction] {
                        endpoint["junc"] = mapped
                    } else {
                        valid = false
                        break
                    }
                    track[end] = endpoint
                }
                guard valid else {
                    continue
                }
                if let layer = track.int("layer") {
                    track["layer"] = mapLayer(layer)
                }
                tracks[UUID().uuidString.lowercased()] = track
                copiedTracks += 1
            }
            for (_, value) in vias {
                guard var via = value as? JSONDictionary, let junction = via.string("junction")?.lowercased(), let mapped = junctionMap[junction] else {
                    continue
                }
                via["junction"] = mapped
                via.removeValue(forKey: "net_set")
                vias[UUID().uuidString.lowercased()] = via
                copiedVias += 1
            }
            board["tracks"] = tracks
            board["junctions"] = junctions
            board["vias"] = vias
        }
        files["board"] = board
        dirty.insert("board")
        return [
            "source": sourceID,
            "target": targetID,
            "anchor_tag": tagNames[anchorTag] ?? anchorTag,
            "placed": placed,
            "tracks": copiedTracks,
            "vias": copiedVias,
            "junctions": copiedJunctions,
            "mirrored": mirrorX
        ]
    }

    /// Removes the board packages of a component. Tracks that ended on one of
    /// its pads keep their copper: the pad end becomes a junction at the pad's
    /// position, the way Horizon's delete leaves a track when its pad goes.
    private func removeBoardPackages(componentID: String) -> Int {
        guard var board = files["board"] else {
            return 0
        }
        var packages = board["packages"] as? JSONDictionary ?? [:]
        let doomed = packages.filter { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == componentID }
        guard !doomed.isEmpty else {
            return 0
        }
        let doomedIDs = Set(doomed.keys.map { $0.lowercased() })
        var doomedTextIDs = Set<String>()
        for (id, package) in doomed {
            packages.removeValue(forKey: id)
            for textID in (package as? JSONDictionary)?["texts"] as? [String] ?? [] {
                doomedTextIDs.insert(textID.lowercased())
            }
        }
        board["packages"] = packages

        var junctions = board["junctions"] as? JSONDictionary ?? [:]
        var tracks = board["tracks"] as? JSONDictionary ?? [:]
        let padPositions = project.board?.packagePadPositions ?? [:]
        for (trackID, value) in tracks {
            guard var track = value as? JSONDictionary else {
                continue
            }
            var changed = false
            var drop = false
            for end in ["from", "to"] {
                guard var endpoint = track.dictionary(end), let pad = endpoint.string("pad") else {
                    continue
                }
                let pieces = pad.split(separator: "/", maxSplits: 1).map { String($0).lowercased() }
                guard pieces.count == 2, doomedIDs.contains(pieces[0]) else {
                    continue
                }
                guard let position = padPositions[pad.lowercased()] ?? padPositions["\(pieces[0])/\(pieces[1])"] else {
                    drop = true
                    break
                }
                let junctionID = UUID().uuidString.lowercased()
                junctions[junctionID] = ["position": [Int(position.x.rounded()), Int(position.y.rounded())]]
                endpoint["pad"] = NSNull()
                endpoint["junc"] = junctionID
                track[end] = endpoint
                changed = true
            }
            if drop {
                tracks.removeValue(forKey: trackID)
            } else if changed {
                tracks[trackID] = track
            }
        }
        board["tracks"] = tracks
        board["junctions"] = junctions
        if !doomedTextIDs.isEmpty {
            var texts = board["texts"] as? JSONDictionary ?? [:]
            texts = texts.filter { !doomedTextIDs.contains($0.key.lowercased()) }
            board["texts"] = texts
        }
        files["board"] = board
        dirty.insert("board")
        return doomed.count
    }
}
