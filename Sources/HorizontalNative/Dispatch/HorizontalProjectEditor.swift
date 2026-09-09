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
    case addNetClass = "add_net_class"
    case renameNetClass = "rename_net_class"
    case renameNet = "rename_net"
    case setNetClass = "set_net_class"
    case retireNet = "retire_net"
    case connect = "connect"
    case disconnect = "disconnect"
    case placeSymbol = "place_symbol"
    case removeSymbol = "remove_symbol"
    case drawNetLine = "draw_net_line"
    case placeText = "place_text"
    case removeText = "remove_text"
    case placePowerSymbol = "place_power_symbol"
    case removePowerSymbol = "remove_power_symbol"
    case placeNetLabel = "place_net_label"
    case removeNetLabel = "remove_net_label"
    case addBlockInstance = "add_block_instance"
    case removeBlockInstance = "remove_block_instance"
    case connectBlockPort = "connect_block_port"
    case placeBlockSymbol = "place_block_symbol"
    case removeBlockSymbol = "remove_block_symbol"
    case setStackup = "set_stackup"
    case addSheet = "add_sheet"
    case renameSheet = "rename_sheet"
    case removeSheet = "remove_sheet"
    case placeTrack = "place_track"
    case removeTrack = "remove_track"
    case setTrackWidth = "set_track_width"
    case placeVia = "place_via"
    case removeVia = "remove_via"
    case placePolygon = "place_polygon"
    case removePolygon = "remove_polygon"
    case placePlane = "place_plane"
    case removePlane = "remove_plane"
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
        case .addNetClass: "Create a net class. Its electrical parameters live in the board rules; board_rules shows them."
        case .renameNetClass: "Rename a net class."
        case .renameNet: "Rename a net."
        case .setNetClass: "Put a net in a net class, by name or id."
        case .retireNet: "Remove a net and every connection to it."
        case .connect: "Connect a component pin to a net."
        case .disconnect: "Remove a pin's connection."
        case .placeSymbol: "Draw a component's gate on a schematic sheet, or move it if it is already drawn. A component connected without this is in the netlist but on no sheet."
        case .removeSymbol: "Take a component's gate off its sheet, with the net lines that ended on it. The component and its connections stay."
        case .drawNetLine: "Draw the wire between two pins that the block already connects to one net. It records what connect already decided; it does not change connectivity."
        case .placeText: "Write a text on a schematic sheet, or change one that is already there. Free text only: a symbol's own texts belong to the symbol."
        case .removeText: "Remove a text from a schematic sheet."
        case .placePowerSymbol: "Draw a power symbol on a sheet: the ground or supply marker that says a point is on that net. Marks the net as a power net, since that is what one means."
        case .removePowerSymbol: "Remove a power symbol from its sheet."
        case .placeNetLabel: "Label a net on a sheet. A label is how a net is named on the page, and how one net spans several sheets."
        case .removeNetLabel: "Remove a net label from its sheet."
        case .addBlockInstance: "Use another block inside this one: one instance of it, with its own reference designator."
        case .removeBlockInstance: "Remove a block instance and every symbol drawn for it."
        case .connectBlockPort: "Connect a block instance's port to a net in the block that uses it. Ports are how a sub-block reaches the design around it."
        case .placeBlockSymbol: "Draw a block instance on a sheet, using the symbol that block defines for itself."
        case .removeBlockSymbol: "Take a block instance's symbol off its sheet. The instance stays."
        case .setStackup: "Set how many inner copper layers the board has, and the copper and dielectric thicknesses."
        case .addSheet: "Add a schematic sheet."
        case .renameSheet: "Rename a schematic sheet."
        case .removeSheet: "Remove an empty schematic sheet. A sheet with anything drawn on it is refused."
        case .placeTrack: "Route one straight copper segment on a layer between two points, pads or junctions. Manual routing: it draws what it is told and does not find a path."
        case .removeTrack: "Remove a copper segment, and any junction it leaves holding nothing."
        case .setTrackWidth: "Set a copper segment's width."
        case .placeVia: "Put a via at a point, on a net, joining the layers its padstack spans."
        case .removeVia: "Remove a via, and the junction it sat on when nothing else needs it."
        case .placePolygon: "Draw a closed polygon on a board layer. Layer 100 is the board outline, which is what gives a board its shape."
        case .removePolygon: "Remove a board polygon. A polygon a plane pours into belongs to that plane."
        case .placePlane: "Define a copper pour: a polygon on a copper layer, filled with one net. Defining it does not fill it — pour_planes does that."
        case .removePlane: "Remove a plane and the polygon it pours into."
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
        case .addNetClass:
            return ["name": "Net class name.", "id": "Net class id to use (optional)."]
        case .renameNetClass:
            return ["net_class": "Net class name or id.", "name": "New name."]
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
        case .placeSymbol:
            return ["component": component, "gate": "Gate name, suffix or id; optional when the entity has one gate.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "symbol": "Pool symbol uuid to draw the gate with (optional; default the one symbol in the project pool for its unit).",
                    "x_mm": "X position.", "y_mm": "Y position.", "angle_deg": "Rotation (optional, default 0 or unchanged).",
                    "mirror": "Mirror the symbol (optional)."]
        case .removeSymbol:
            return ["component": component, "gate": "Gate name, suffix or id; optional when the entity has one gate.",
                    "sheet": "Sheet index, name or uuid (optional; default every sheet)."]
        case .drawNetLine:
            return ["component": component, "pin": "Pin as for connect.", "to_component": "The other end's component.",
                    "to_pin": "The other end's pin.", "sheet": "Sheet index, name or uuid (optional; the sheet both gates are on)."]
        case .placeText:
            return ["text": "The text to write. Optional when changing an existing text's placement only.",
                    "id": "Text id to change (optional; a new text otherwise). list_texts returns them.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "angle_deg": "Rotation (optional, default 0 or unchanged).", "mirror": "Mirror the text (optional).",
                    "size_mm": "Cap height (optional; default 1.5).", "width_mm": "Stroke width (optional; default 0, which is Horizon's automatic width).",
                    "origin": "baseline, center or bottom (optional; default center).",
                    "font": "simplex, complex, complex_italic, complex_small, complex_small_italic, duplex, triplex or triplex_italic (optional; default simplex)."]
        case .removeText:
            return ["id": "Text id, from list_texts.", "sheet": "Sheet index, name or uuid (optional; default every sheet)."]
        case .placePowerSymbol:
            return ["net": "Net name or id.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "up, down, left or right (optional; default up).",
                    "mirror": "Mirror the symbol (optional).",
                    "style": "gnd, dot, antenna or earth (optional). The style belongs to the net, so this sets it for every symbol on that net."]
        case .removePowerSymbol:
            return ["id": "Power symbol id, from list_power_symbols."]
        case .placeNetLabel:
            return ["net": "Net name or id.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "right, left, up or down (optional; default right).",
                    "size_mm": "Cap height (optional; default 1.5).",
                    "offsheet_refs": "Show the other sheets this net appears on (optional; default true)."]
        case .removeNetLabel:
            return ["id": "Net label id, from list_net_labels."]
        case .addBlockInstance:
            return ["block": "The block to use, by uuid or name.", "refdes": "Reference designator for this use of it (optional).",
                    "id": "Instance id to use (optional)."]
        case .removeBlockInstance:
            return ["instance": "Block instance id or refdes."]
        case .connectBlockPort:
            return ["instance": "Block instance id or refdes.", "port": "Port uuid on the used block, or the net name it carries there.",
                    "net": "Net name or id in this block.", "create_net": "Create the net when it does not exist (default false)."]
        case .placeBlockSymbol:
            return ["instance": "Block instance id or refdes.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "angle_deg": "Rotation (optional).", "mirror": "Mirror the symbol (optional)."]
        case .removeBlockSymbol:
            return ["instance": "Block instance id or refdes.", "sheet": "Sheet index, name or uuid (optional; default every sheet)."]
        case .setStackup:
            return ["inner_layers": "How many inner copper layers (0 to 30).",
                    "copper_mm": "Copper thickness per layer (optional; default 0.035).",
                    "substrate_mm": "Dielectric thickness below each layer (optional; default 1.6 shared across the cores)."]
        case .addSheet:
            return ["name": "Sheet name.", "index": "Page number (optional; default after the last sheet)."]
        case .renameSheet:
            return ["sheet": "Sheet index, name or uuid.", "name": "New name."]
        case .removeSheet:
            return ["sheet": "Sheet index, name or uuid."]
        case .placePolygon:
            return ["layer": "Board layer number. 100 is the outline; board_info lists the rest.",
                    "vertices": "Three or more {\"x_mm\", \"y_mm\"} points, in order. The shape closes itself."]
        case .removePolygon:
            return ["polygon": "Polygon id, from list_polygons."]
        case .placePlane:
            return ["net": "Net name or id the pour carries.", "layer": "Copper layer number.",
                    "vertices": "Three or more {\"x_mm\", \"y_mm\"} points bounding the pour.",
                    "priority": "Lower pours first where planes overlap (optional; default 0)."]
        case .removePlane:
            return ["plane": "Plane id, from list_planes."]
        case .placeTrack:
            let endpoint = "One of {\"component\", \"pad\"}, {\"junction\"} or {\"x_mm\", \"y_mm\"}. A point becomes a junction."
            return ["from": endpoint, "to": endpoint, "layer": "Copper layer number; 0 is the top. board_info lists them.",
                    "width_mm": "Track width. Optional only when the board states a track_width rule for the net's class on that layer.",
                    "net": "Net name or id (optional; taken from the ends when they name one)."]
        case .removeTrack:
            return ["track": "Track id, from list_tracks."]
        case .setTrackWidth:
            return ["track": "Track id, from list_tracks.", "width_mm": "New width."]
        case .placeVia:
            return ["x_mm": "X position.", "y_mm": "Y position.", "net": "Net name or id the via carries.",
                    "padstack": "Pool padstack uuid (optional; defaults to what the board's other vias use)."]
        case .removeVia:
            return ["via": "Via id, from list_vias."]
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
        let unknown = Set(json.keys).subtracting(Set(kind.params.keys).union(["op"]))
        guard unknown.isEmpty else { throw HorizontalDispatchError.invalidParams("Unknown \(name) fields: \(unknown.sorted().joined(separator: ", ")).") }
        for (key, value) in json where key != "op" {
            if key == "vertices" {
                guard let vertices = value as? [Any], vertices.count >= 3, vertices.allSatisfy({ $0 is JSONDictionary }) else {
                    throw HorizontalDispatchError.invalidParams("vertices must be three or more {\"x_mm\", \"y_mm\"} points.")
                }
            } else if ["layer", "index", "priority", "inner_layers"].contains(key) {
                try HorizontalDispatchValidation.number(value, key: key, integer: true)
            } else if ["from", "to"].contains(key) {
                // A track endpoint is an object; everything else here is scalar.
                guard let endpoint = value as? JSONDictionary, !endpoint.isEmpty else {
                    throw HorizontalDispatchError.invalidParams("\(key) must be an object naming a pad, a junction or a point.")
                }
            } else if ["x_mm", "y_mm", "angle_deg", "size_mm", "width_mm", "copper_mm", "substrate_mm"].contains(key) {
                try HorizontalDispatchValidation.number(value, key: key)
            } else if ["no_populate", "is_power", "create_net", "bottom", "include_routing", "mirror", "offsheet_refs"].contains(key) {
                try HorizontalDispatchValidation.boolean(value, key: key)
            } else if value is NSNull, ["part", "group", "tag"].contains(key) {
                continue
            } else if key == "sheet" {
                // A sheet is named by its page number as well as by name or uuid.
                guard value is String || value is NSNumber else {
                    throw HorizontalDispatchError.invalidParams("sheet must be a sheet index, name or uuid.")
                }
            } else if !(value is String) { throw HorizontalDispatchError.invalidParams("\(key) must be a string.") }
        }
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
        // Resolve archive-relative paths before filesystem-dependent URL
        // canonicalization, including files that exist only in the archive.
        let prefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        if url.path.hasPrefix(prefix) {
            let relative = String(url.path.dropFirst(prefix.count))
            guard !relative.split(separator: "/").contains("..") else { return nil }
            return relative
        }
        if let path = archive.manifest?.relativePath(for: url) {
            return path
        }
        let base = baseURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
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
            throw HorizontalDispatchError.failed("Could not map \(url.path) into the document archive rooted at \(baseURL.path).")
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

    /// Which block this editor edits, and whether it is the top one. A board
    /// belongs to the top block: a sub-block's components are instantiated
    /// wherever it is used, so there is no single package to place for them.
    private(set) var blockID: String = ""
    private(set) var isTopBlock = true

    init(project: HorizontalProject, store: HorizontalProjectFileStore = HorizontalDiskFileStore(),
         snapshot: HorizontalDispatchSnapshot? = nil, block reference: String? = nil) throws {
        self.project = project
        self.store = store
        pool = HorizontalDispatchPoolIndex(project: project, snapshot: snapshot)
        poolURL = project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }

        let top = project.blocks.first(where: \.isTop)
        var selected = top
        if let reference, !reference.isEmpty {
            let matches = project.blocks.filter {
                $0.uuid.caseInsensitiveCompare(reference) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(reference) == .orderedSame
            }
            guard matches.count == 1, let match = matches.first else {
                if matches.isEmpty {
                    throw HorizontalDispatchError.notFound(
                        "No block \(reference). Blocks: \(project.blocks.map(\.displayName).joined(separator: ", "))."
                    )
                }
                throw HorizontalDispatchError.ambiguous("More than one block is called \(reference); use its uuid.",
                                                        candidates: matches.map(\.uuid))
            }
            selected = match
        }
        blockID = selected?.uuid ?? ""
        isTopBlock = selected?.isTop ?? true

        guard let blockFilename = selected?.blockFilename ?? (isTopBlock ? project.blockFilename : nil), !blockFilename.isEmpty else {
            throw HorizontalDispatchError.failed("Block \(selected?.displayName ?? "?") has no file to edit.")
        }
        try load("block", url: project.baseURL.appendingPathComponent(blockFilename))
        if let schematicFilename = selected?.schematicFilename ?? (isTopBlock ? project.schematicFilename : nil), !schematicFilename.isEmpty {
            try load("schematic", url: project.baseURL.appendingPathComponent(schematicFilename))
        }
        // The board is the top block's. Leaving it unloaded is what makes a
        // board op on a sub-block fail loudly instead of editing the wrong one.
        if isTopBlock, let boardFilename = project.boardFilename, !boardFilename.isEmpty {
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
        case .addNetClass:
            change.merge(try addNetClass(params)) { _, new in new }
        case .renameNetClass:
            change.merge(try renameNetClass(params)) { _, new in new }
        case .renameNet:
            let id = try netID(params)
            guard let name = params["name"] as? String else {
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
        case .placeSymbol:
            let id = try componentID(params)
            change["component"] = id
            change.merge(try placeSymbol(id, params)) { _, new in new }
        case .removeSymbol:
            let id = try componentID(params)
            change["component"] = id
            change["removed"] = try removeSymbol(id, params)
        case .drawNetLine:
            change.merge(try drawNetLine(params)) { _, new in new }
        case .placeText:
            change.merge(try placeText(params)) { _, new in new }
        case .removeText:
            change.merge(try removeText(params)) { _, new in new }
        case .placePowerSymbol:
            change.merge(try placePowerSymbol(params)) { _, new in new }
        case .removePowerSymbol:
            change.merge(try removeSheetMark(params, key: "power_symbols", label: "power symbol")) { _, new in new }
        case .placeNetLabel:
            change.merge(try placeNetLabel(params)) { _, new in new }
        case .removeNetLabel:
            change.merge(try removeSheetMark(params, key: "net_labels", label: "net label")) { _, new in new }
        case .addBlockInstance:
            change.merge(try addBlockInstance(params)) { _, new in new }
        case .removeBlockInstance:
            change.merge(try removeBlockInstance(params)) { _, new in new }
        case .connectBlockPort:
            change.merge(try connectBlockPort(params)) { _, new in new }
        case .placeBlockSymbol:
            change.merge(try placeBlockSymbol(params)) { _, new in new }
        case .removeBlockSymbol:
            change.merge(try removeBlockSymbol(params)) { _, new in new }
        case .setStackup:
            change.merge(try setStackup(params)) { _, new in new }
        case .addSheet:
            change.merge(try addSheet(params)) { _, new in new }
        case .renameSheet:
            change.merge(try renameSheet(params)) { _, new in new }
        case .removeSheet:
            change.merge(try removeSheet(params)) { _, new in new }
        case .placePolygon:
            change.merge(try placePolygon(params)) { _, new in new }
        case .removePolygon:
            change.merge(try removePolygon(params)) { _, new in new }
        case .placePlane:
            change.merge(try placePlane(params)) { _, new in new }
        case .removePlane:
            change.merge(try removePlane(params)) { _, new in new }
        case .placeTrack:
            change.merge(try placeTrack(params)) { _, new in new }
        case .removeTrack:
            change.merge(try removeTrack(params)) { _, new in new }
        case .setTrackWidth:
            change.merge(try setTrackWidth(params)) { _, new in new }
        case .placeVia:
            change.merge(try placeVia(params)) { _, new in new }
        case .removeVia:
            change.merge(try removeVia(params)) { _, new in new }
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
        guard !(store is HorizontalArchiveFileStore), let poolURL else {
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

    private func addNetClass(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_net_class needs a \"name\".")
        }
        var classes = block["net_classes"] as? JSONDictionary ?? [:]
        if let existing = classes.first(where: { ($0.value as? JSONDictionary)?.string("name") == name }) {
            return ["net_class": existing.key, "name": name, "created": false]
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        guard classes[id] == nil else {
            throw HorizontalDispatchError.invalidParams("A net class \(id) already exists.")
        }
        classes[id] = ["name": name]
        block["net_classes"] = classes
        return ["net_class": id, "name": name, "created": true,
                "note": "Its parameters — widths, clearances — live in the board rules, not here."]
    }

    private func renameNetClass(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("net_class") else {
            throw HorizontalDispatchError.invalidParams("rename_net_class needs \"net_class\".")
        }
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("rename_net_class needs a \"name\".")
        }
        let id = try netClassID(reference)
        var classes = block["net_classes"] as? JSONDictionary ?? [:]
        var item = classes[id] as? JSONDictionary ?? [:]
        item["name"] = name
        classes[id] = item
        block["net_classes"] = classes
        return ["net_class": id, "name": name]
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

    /// The sheets of the top block's schematic, in page order.
    private func sheetsInOrder() throws -> [(id: String, json: JSONDictionary)] {
        guard let schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic to draw on.")
        }
        return (schematic["sheets"] as? JSONDictionary ?? [:])
            .compactMap { id, value in (value as? JSONDictionary).map { (id, $0) } }
            .sorted { ($0.1.int("index") ?? 0, $0.0) < ($1.1.int("index") ?? 0, $1.0) }
    }

    /// Resolves the `sheet` parameter — a page number, a name or a uuid — to
    /// one sheet. Without it, the first sheet.
    private func sheetID(_ params: JSONDictionary) throws -> String {
        let sheets = try sheetsInOrder()
        guard let first = sheets.first else {
            throw HorizontalDispatchError.notFound("The schematic has no sheets.")
        }
        guard let reference = params["sheet"], !(reference is NSNull) else {
            return first.id
        }
        if let index = params.int("sheet"), !(reference is String) {
            guard let match = sheets.first(where: { $0.json.int("index") == index }) else {
                throw HorizontalDispatchError.notFound("No sheet \(index). Sheets: \(sheets.map { "\($0.json.int("index") ?? 0) \($0.json.string("name") ?? "")" }.joined(separator: ", ")).")
            }
            return match.id
        }
        guard let text = params.string("sheet") else {
            throw HorizontalDispatchError.invalidParams("sheet must be a sheet index, name or uuid.")
        }
        if let match = sheets.first(where: { $0.id.caseInsensitiveCompare(text) == .orderedSame }) {
            return match.id
        }
        let named = sheets.filter { ($0.json.string("name") ?? "").caseInsensitiveCompare(text) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("\(named.count) sheets are named \(text); pass the uuid.", candidates: named.map(\.id))
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound("No sheet \(text). Sheets: \(sheets.map { $0.json.string("name") ?? $0.id }.joined(separator: ", ")).")
        }
        return match.id
    }

    private func updateSheet(_ sheetID: String, _ body: (inout JSONDictionary) throws -> Void) throws {
        guard var schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        var sheets = schematic["sheets"] as? JSONDictionary ?? [:]
        guard var sheet = sheets[sheetID] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No sheet \(sheetID).")
        }
        try body(&sheet)
        sheets[sheetID] = sheet
        schematic["sheets"] = sheets
        files["schematic"] = schematic
        dirty.insert("schematic")
    }

    /// Resolves the `gate` parameter against a component's entity. Optional
    /// when the entity has exactly one gate.
    private func gate(_ params: JSONDictionary, componentID: String, key: String = "gate") throws -> (id: String, gate: HorizontalDispatchPoolIndex.Gate) {
        guard let entityID = components()[componentID]?.string("entity")?.lowercased() else {
            throw HorizontalDispatchError.notFound("Component \(componentID) has no entity.")
        }
        guard let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("Pool entity \(entityID) for \(componentID) is not in the project pool.")
        }
        guard let reference = params.string(key), !reference.isEmpty else {
            guard entity.gates.count == 1, let only = entity.gates.first else {
                throw HorizontalDispatchError.invalidParams(
                    "\(entity.name) has \(entity.gates.count) gates; pass \"\(key)\". Gates: \(entity.gates.values.map { $0.suffix.isEmpty ? $0.name : $0.suffix }.sorted().joined(separator: ", "))."
                )
            }
            return (only.key, only.value)
        }
        let matches = entity.gates.filter { id, gate in
            id.caseInsensitiveCompare(reference) == .orderedSame
                || gate.name.caseInsensitiveCompare(reference) == .orderedSame
                || (!gate.suffix.isEmpty && gate.suffix.caseInsensitiveCompare(reference) == .orderedSame)
        }
        guard matches.count == 1, let match = matches.first else {
            throw HorizontalDispatchError.notFound("No gate \(reference) on \(entity.name). Gates: \(entity.gates.values.map(\.name).sorted().joined(separator: ", ")).")
        }
        return (match.key, match.value)
    }

    /// Every symbol instance on every sheet, as (sheetID, instanceID, item).
    private func symbolInstances() throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        try sheetsInOrder().flatMap { sheet in
            sheet.json.dictionaryMap("symbols")
                .sorted { $0.key < $1.key }
                .map { (sheet.id, $0.key, $0.value) }
        }
    }

    private func symbolInstance(componentID: String, gateID: String) throws -> (sheet: String, id: String, json: JSONDictionary)? {
        try symbolInstances().first {
            $0.json.string("component")?.lowercased() == componentID
                && $0.json.string("gate")?.lowercased() == gateID.lowercased()
        }
    }

    private func placeSymbol(_ componentID: String, _ params: JSONDictionary) throws -> JSONDictionary {
        let (gateID, resolvedGate) = try gate(params, componentID: componentID)
        let existing = try symbolInstance(componentID: componentID, gateID: gateID)
        // Without a sheet, a gate already drawn stays where it is and a new one
        // goes on the first sheet.
        let targetSheet: String
        if params["sheet"] == nil, let existing {
            targetSheet = existing.sheet
        } else {
            targetSheet = try sheetID(params)
        }
        var item = existing?.json ?? [:]

        // A gate is drawn by a symbol for its unit. Naming one is optional
        // while the project pool holds a single symbol that draws the unit;
        // more than one is a choice the caller has to make.
        if let requested = params.string("symbol")?.lowercased() {
            item["symbol"] = requested
        } else if item["symbol"] == nil {
            guard let unitID = resolvedGate.unitID else {
                throw HorizontalDispatchError.notFound("Gate \(resolvedGate.name) names no unit, so nothing draws it.")
            }
            let symbols = pool.symbols(forUnit: unitID)
            guard !symbols.isEmpty else {
                throw HorizontalDispatchError.notFound(
                    "No symbol in the project pool draws unit \(unitID). Import the part with import_pool_part, or pass \"symbol\"."
                )
            }
            guard symbols.count == 1 else {
                throw HorizontalDispatchError.ambiguous("\(symbols.count) symbols draw unit \(unitID); pass \"symbol\".", candidates: symbols)
            }
            item["symbol"] = symbols[0]
        }
        item["component"] = componentID
        item["gate"] = gateID
        if item["pin_display_mode"] == nil { item["pin_display_mode"] = "selected_only" }

        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Int((x * 1_000_000).rounded()), Int((y * 1_000_000).rounded())]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_symbol needs \"x_mm\" and \"y_mm\" for a gate that is not on a sheet yet.")
        }
        if let degrees = params.double("angle_deg") {
            placement["angle"] = Self.horizonAngle(degrees)
        }
        if let mirror = params.bool("mirror") {
            placement["mirror"] = mirror
        }
        item["placement"] = placement

        let instanceID = existing?.id ?? UUID().uuidString.lowercased()
        // Moving a gate to another sheet takes its net lines' endpoints with
        // it, which this editor cannot redraw; make the caller do it in two
        // explicit steps instead of leaving lines pointing at nothing.
        if let existing, existing.sheet != targetSheet {
            throw HorizontalDispatchError.invalidParams(
                "\(instanceID) is already on another sheet. Remove it with remove_symbol, then place it on \(targetSheet)."
            )
        }
        try updateSheet(targetSheet) { sheet in
            var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
            symbols[instanceID] = item
            sheet["symbols"] = symbols
        }
        return ["gate": gateID, "sheet": targetSheet, "symbol_instance": instanceID,
                "symbol": item.string("symbol") as Any, "created": existing == nil]
    }

    private func removeSymbol(_ componentID: String, _ params: JSONDictionary) throws -> JSONDictionary {
        // No gate named means every gate of this component comes off.
        let gateID = params.string("gate") == nil ? nil : try gate(params, componentID: componentID).id
        let sheetFilter = params["sheet"] == nil ? nil : try sheetID(params)
        let doomed = try symbolInstances().filter { instance in
            instance.json.string("component")?.lowercased() == componentID
                && (gateID == nil || instance.json.string("gate")?.lowercased() == gateID)
                && (sheetFilter == nil || instance.sheet == sheetFilter)
        }
        guard !doomed.isEmpty else {
            throw HorizontalDispatchError.notFound("No symbol for \(componentID) is on a sheet.")
        }
        var lines = 0
        for instance in doomed {
            try updateSheet(instance.sheet) { sheet in
                var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
                symbols.removeValue(forKey: instance.id)
                sheet["symbols"] = symbols
                var netLines = sheet["net_lines"] as? JSONDictionary ?? [:]
                let before = netLines.count
                netLines = netLines.filter { _, value in
                    guard let line = value as? JSONDictionary else { return true }
                    return !["from", "to"].contains { end in
                        line.dictionary(end)?.string("pin")?.split(separator: "/").first
                            .map { $0.lowercased() == instance.id.lowercased() } ?? false
                    }
                }
                lines += before - netLines.count
                sheet["net_lines"] = netLines
            }
        }
        return ["symbols": doomed.count, "net_lines": lines]
    }

    /// The wire between two pins the block already ties to one net. Horizon
    /// derives connectivity from the block, not from these lines, so drawing
    /// one records a decision rather than making it — and drawing one where
    /// the block disagrees would draw a lie.
    private func drawNetLine(_ params: JSONDictionary) throws -> JSONDictionary {
        let fromComponent = try componentID(params)
        let fromPin = try pinPath(params, componentID: fromComponent)
        guard let toReference = params.string("to_component"), let toPinReference = params.string("to_pin") else {
            throw HorizontalDispatchError.invalidParams("draw_net_line needs \"to_component\" and \"to_pin\".")
        }
        let toComponent = try componentID(reference: toReference)
        let toPin = try pinPath(["pin": toPinReference], componentID: toComponent)

        func net(_ component: String, _ pin: String) throws -> String {
            guard let net = (components()[component]?["connections"] as? JSONDictionary)?
                .dictionary(pin)?.string("net")?.lowercased() else {
                throw HorizontalDispatchError.notFound("\(component) pin \(pin) is on no net. Connect it first.")
            }
            return net
        }
        let fromNet = try net(fromComponent, fromPin)
        let toNet = try net(toComponent, toPin)
        guard fromNet == toNet else {
            throw HorizontalDispatchError.invalidParams(
                "The two pins are on different nets (\(fromNet), \(toNet)); connect them to one net before drawing the wire."
            )
        }

        func endpoint(_ component: String, _ pin: String) throws -> (sheet: String, path: String) {
            let gateID = String(pin.split(separator: "/")[0])
            guard let instance = try symbolInstance(componentID: component, gateID: gateID) else {
                throw HorizontalDispatchError.notFound("\(component) gate \(gateID) is not on a sheet; place_symbol it first.")
            }
            let pinID = String(pin.split(separator: "/")[1])
            return (instance.sheet, "\(instance.id)/\(pinID)")
        }
        let from = try endpoint(fromComponent, fromPin)
        let to = try endpoint(toComponent, toPin)
        guard from.sheet == to.sheet else {
            throw HorizontalDispatchError.invalidParams(
                "The two gates are on different sheets; a net line stays on one sheet. Nets cross sheets through their names."
            )
        }
        if let sheet = params["sheet"], !(sheet is NSNull) {
            let requested = try sheetID(params)
            guard requested == from.sheet else {
                throw HorizontalDispatchError.invalidParams("Both gates are on sheet \(from.sheet), not \(requested).")
            }
        }

        var lineID = UUID().uuidString.lowercased()
        var created = true
        try updateSheet(from.sheet) { sheet in
            var lines = sheet["net_lines"] as? JSONDictionary ?? [:]
            let ends = Set([from.path.lowercased(), to.path.lowercased()])
            if let existing = lines.first(where: { _, value in
                guard let line = value as? JSONDictionary else { return false }
                return Set(["from", "to"].compactMap { line.dictionary($0)?.string("pin")?.lowercased() }) == ends
            }) {
                lineID = existing.key
                created = false
                return
            }
            lines[lineID] = ["from": Self.pinEndpoint(from.path), "to": Self.pinEndpoint(to.path), "net": fromNet]
            sheet["net_lines"] = lines
        }
        return ["net_line": lineID, "sheet": from.sheet, "net": fromNet, "created": created,
                "from": ["component": fromComponent, "pin": fromPin], "to": ["component": toComponent, "pin": toPin]]
    }

    // MARK: - Sheet texts

    static let textOrigins = ["baseline", "center", "bottom"]
    static let textFonts = ["simplex", "complex", "complex_italic", "complex_small",
                            "complex_small_italic", "duplex", "triplex", "triplex_italic"]

    /// Every free text on every sheet, as (sheetID, textID, item).
    private func sheetTexts() throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        try sheetsInOrder().flatMap { sheet in
            sheet.json.dictionaryMap("texts")
                .sorted { $0.key < $1.key }
                .map { (sheet.id, $0.key, $0.value) }
        }
    }

    private func placeText(_ params: JSONDictionary) throws -> JSONDictionary {
        let existing = try params.string("id").map { reference -> (sheet: String, id: String, json: JSONDictionary) in
            guard let found = try sheetTexts().first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame }) else {
                throw HorizontalDispatchError.notFound("No text \(reference) on any sheet. list_texts returns the ids.")
            }
            return found
        }
        // A text a symbol carries is the symbol's, extracted by Horizon's
        // Smash; it moves and dies with the symbol rather than on its own.
        if let existing, existing.json.bool("from_smash") == true {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is a symbol's own text, not free text on the sheet. Change the component instead."
            )
        }
        let targetSheet: String
        if params["sheet"] == nil, let existing {
            targetSheet = existing.sheet
        } else {
            targetSheet = try sheetID(params)
        }
        if let existing, existing.sheet != targetSheet {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is on another sheet. Remove it with remove_text, then write it on \(targetSheet)."
            )
        }

        var item = existing?.json ?? ["from_smash": false, "origin": "center", "font": "simplex", "width": 0, "size": 1_500_000]
        if let text = params.string("text") {
            guard !text.isEmpty else { throw HorizontalDispatchError.invalidParams("place_text needs a non-empty \"text\".") }
            item["text"] = text
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_text needs \"text\" for a text that is not on a sheet yet.")
        }
        for (key, allowed) in [("origin", Self.textOrigins), ("font", Self.textFonts)] {
            guard let value = params.string(key) else { continue }
            guard allowed.contains(value) else {
                throw HorizontalDispatchError.invalidParams("\(key) must be one of \(allowed.joined(separator: ", ")).")
            }
            item[key] = value
        }
        for (key, field) in [("size_mm", "size"), ("width_mm", "width")] {
            guard let millimetres = params.double(key) else { continue }
            guard millimetres >= 0 else { throw HorizontalDispatchError.invalidParams("\(key) cannot be negative.") }
            item[field] = Int((millimetres * 1_000_000).rounded())
        }
        guard (item["size"] as? Int ?? 0) > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }

        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Int((x * 1_000_000).rounded()), Int((y * 1_000_000).rounded())]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_text needs \"x_mm\" and \"y_mm\" for a text that is not on a sheet yet.")
        }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement

        let id = existing?.id ?? UUID().uuidString.lowercased()
        try updateSheet(targetSheet) { sheet in
            var texts = sheet["texts"] as? JSONDictionary ?? [:]
            texts[id] = item
            sheet["texts"] = texts
        }
        return ["text_id": id, "sheet": targetSheet, "text": item.string("text") as Any, "created": existing == nil]
    }

    private func removeText(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("id"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_text needs \"id\"; list_texts returns them.")
        }
        let sheetFilter = params["sheet"] == nil ? nil : try sheetID(params)
        guard let found = try sheetTexts().first(where: {
            $0.id.caseInsensitiveCompare(reference) == .orderedSame && (sheetFilter == nil || $0.sheet == sheetFilter)
        }) else {
            throw HorizontalDispatchError.notFound("No text \(reference)\(sheetFilter == nil ? "" : " on that sheet").")
        }
        guard found.json.bool("from_smash") != true else {
            throw HorizontalDispatchError.invalidParams(
                "\(found.id) is a symbol's own text; removing the symbol is what removes it."
            )
        }
        // A text a symbol references would leave a dangling id behind.
        let referenced = try symbolInstances().contains { instance in
            (instance.json["texts"] as? [String] ?? []).contains { $0.caseInsensitiveCompare(found.id) == .orderedSame }
        }
        guard !referenced else {
            throw HorizontalDispatchError.invalidParams("\(found.id) belongs to a symbol on the sheet, which still refers to it.")
        }
        try updateSheet(found.sheet) { sheet in
            var texts = sheet["texts"] as? JSONDictionary ?? [:]
            texts.removeValue(forKey: found.id)
            sheet["texts"] = texts
        }
        return ["text_id": found.id, "sheet": found.sheet, "text": found.json.string("text") as Any]
    }

    // MARK: - Net labels, power symbols and sheets

    static let markOrientations = ["up", "down", "left", "right"]
    static let powerSymbolStyles = ["gnd", "dot", "antenna", "earth"]

    /// A junction on a schematic sheet, at a point, carrying a net. Net labels
    /// and power symbols both sit on one; a point that already has one joins it.
    private func ensureSheetJunction(_ sheetID: String, x: Double, y: Double, net: String) throws -> String {
        let point = [Self.nanometres(x), Self.nanometres(y)]
        let sheets = try sheetsInOrder()
        let existing = sheets.first { $0.id == sheetID }?.json.dictionaryMap("junctions")
            .first { $0.value["position"] as? [Int] == point }
        let id = existing?.key ?? UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var junctions = sheet["junctions"] as? JSONDictionary ?? [:]
            var item = junctions[id] as? JSONDictionary ?? [:]
            item["position"] = point
            item["net"] = net
            junctions[id] = item
            sheet["junctions"] = junctions
        }
        return id
    }

    /// Junctions on a sheet that nothing refers to any more.
    @discardableResult
    private func collectSheetJunctions(_ sheetID: String) throws -> [String] {
        guard let sheet = try sheetsInOrder().first(where: { $0.id == sheetID })?.json else { return [] }
        var referenced = Set<String>()
        for key in ["net_labels", "power_symbols", "bus_labels", "bus_rippers"] {
            for (_, item) in sheet.dictionaryMap(key) {
                if let junction = item.string("junction") { referenced.insert(junction.lowercased()) }
            }
        }
        for (_, line) in sheet.dictionaryMap("net_lines") {
            for end in ["from", "to"] {
                if let junction = line.dictionary(end)?.string("junc") { referenced.insert(junction.lowercased()) }
            }
        }
        var removed = [String]()
        try updateSheet(sheetID) { sheet in
            var junctions = sheet["junctions"] as? JSONDictionary ?? [:]
            for id in junctions.keys where !referenced.contains(id.lowercased()) {
                junctions.removeValue(forKey: id)
                removed.append(id)
            }
            sheet["junctions"] = junctions
        }
        return removed.sorted()
    }

    private func markOption(_ params: JSONDictionary, key: String, allowed: [String], default fallback: String) throws -> String {
        guard let value = params.string(key) else { return fallback }
        guard allowed.contains(value) else {
            throw HorizontalDispatchError.invalidParams("\(key) must be one of \(allowed.joined(separator: ", ")).")
        }
        return value
    }

    private func placePowerSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let net = try netID(params)
        let sheetID = try sheetID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_power_symbol needs \"x_mm\" and \"y_mm\".")
        }
        let orientation = try markOption(params, key: "orientation", allowed: Self.markOrientations, default: "up")
        let style = params.string("style")
        if let style, !Self.powerSymbolStyles.contains(style) {
            throw HorizontalDispatchError.invalidParams("style must be one of \(Self.powerSymbolStyles.joined(separator: ", ")).")
        }
        // A power symbol on a net is what makes it a power net, and the symbol's
        // shape is a property of the net rather than of the symbol.
        var madePower = false
        try updateNet(net) { item in
            madePower = item.bool("is_power") != true
            item["is_power"] = true
            if let style { item["power_symbol_style"] = style }
        }
        let junction = try ensureSheetJunction(sheetID, x: x, y: y, net: net)
        let id = UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var symbols = sheet["power_symbols"] as? JSONDictionary ?? [:]
            symbols[id] = ["junction": junction, "net": net, "orientation": orientation,
                           "mirror": params.bool("mirror") ?? false]
            sheet["power_symbols"] = symbols
        }
        var change: JSONDictionary = ["power_symbol": id, "net": net, "sheet": sheetID, "junction": junction]
        if madePower { change["note"] = "The net is now a power net, which is what a power symbol on it means." }
        if let style { change["style"] = style }
        return change
    }

    private func placeNetLabel(_ params: JSONDictionary) throws -> JSONDictionary {
        let net = try netID(params)
        let sheetID = try sheetID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_net_label needs \"x_mm\" and \"y_mm\".")
        }
        let orientation = try markOption(params, key: "orientation", allowed: Self.markOrientations, default: "right")
        let sizeMM = params.double("size_mm") ?? 1.5
        guard sizeMM > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }
        let junction = try ensureSheetJunction(sheetID, x: x, y: y, net: net)
        let id = UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var labels = sheet["net_labels"] as? JSONDictionary ?? [:]
            labels[id] = ["junction": junction, "last_net": net, "size": Self.nanometres(sizeMM),
                          "orientation": orientation, "offsheet_refs": params.bool("offsheet_refs") ?? true]
            sheet["net_labels"] = labels
        }
        return ["net_label": id, "net": net, "sheet": sheetID, "junction": junction,
                "orientation": orientation, "size_mm": sizeMM]
    }

    /// Removes one net label or power symbol, and the junction it leaves idle.
    private func removeSheetMark(_ params: JSONDictionary, key: String, label: String) throws -> JSONDictionary {
        guard let reference = params.string("id"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove needs \"id\".")
        }
        let found = try sheetsInOrder().compactMap { sheet -> (sheet: String, id: String)? in
            guard let match = sheet.json.dictionaryMap(key).keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
                return nil
            }
            return (sheet.id, match)
        }.first
        guard let found else {
            throw HorizontalDispatchError.notFound("No \(label) \(reference) on any sheet.")
        }
        try updateSheet(found.sheet) { sheet in
            var map = sheet[key] as? JSONDictionary ?? [:]
            map.removeValue(forKey: found.id)
            sheet[key] = map
        }
        return ["id": found.id, "sheet": found.sheet, "junctions_removed": try collectSheetJunctions(found.sheet)]
    }

    // MARK: - Block composition

    /// The blocks this project defines, other than the one being edited. A
    /// block cannot use itself.
    private func usableBlocks() -> [HorizontalProjectBlock] {
        project.blocks.filter { $0.uuid.lowercased() != blockID.lowercased() }
    }

    private func blockInstances() -> JSONDictionary {
        block["block_instances"] as? JSONDictionary ?? [:]
    }

    private func blockInstanceID(_ params: JSONDictionary, key: String = "instance") throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required; list_block_instances returns them.")
        }
        let instances = blockInstances()
        if let match = instances.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let named = instances.filter { ($0.value as? JSONDictionary)?.string("refdes")?.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one block instance is called \(reference); use its id.",
                                                    candidates: named.keys.sorted())
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound("No block instance \(reference).")
        }
        return match.key
    }

    private func addBlockInstance(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("block"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_block_instance needs \"block\": the block to use.")
        }
        let candidates = usableBlocks().filter {
            $0.uuid.caseInsensitiveCompare(reference) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(reference) == .orderedSame
        }
        guard candidates.count == 1, let used = candidates.first else {
            if candidates.isEmpty {
                // Naming the block being edited is the mistake worth catching.
                if project.blocks.contains(where: { $0.uuid.caseInsensitiveCompare(reference) == .orderedSame }) {
                    throw HorizontalDispatchError.invalidParams("A block cannot use itself.")
                }
                throw HorizontalDispatchError.notFound(
                    "No block \(reference). Blocks this one can use: \(usableBlocks().map(\.displayName).joined(separator: ", "))."
                )
            }
            throw HorizontalDispatchError.ambiguous("More than one block is called \(reference); use its uuid.",
                                                    candidates: candidates.map(\.uuid))
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        var instances = blockInstances()
        guard instances[id] == nil else {
            throw HorizontalDispatchError.invalidParams("A block instance \(id) already exists.")
        }
        instances[id] = ["block": used.uuid, "refdes": params.string("refdes") ?? "U?",
                         "connections": [String: Any]()]
        block["block_instances"] = instances
        return ["block_instance": id, "block": used.uuid, "block_name": used.displayName,
                "refdes": params.string("refdes") ?? "U?",
                "note": "Its ports reach this block through connect_block_port, and place_block_symbol draws it."]
    }

    private func removeBlockInstance(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        instances.removeValue(forKey: id)
        block["block_instances"] = instances
        let symbols = try removeBlockSymbols(instanceID: id, sheetFilter: nil)
        return ["block_instance": id, "symbols": symbols]
    }

    /// A block's ports are the nets it declares as ports; a using block wires
    /// its own nets onto them.
    private func blockPortID(_ reference: String, of usedBlockID: String) throws -> String {
        guard let used = project.blocks.first(where: { $0.uuid.lowercased() == usedBlockID.lowercased() }),
              let filename = used.blockFilename,
              let data = try store.read(project.baseURL.appendingPathComponent(filename)),
              let json = try? JSONHelper.loadDictionary(from: data) else {
            throw HorizontalDispatchError.notFound("Could not read the used block to find its ports.")
        }
        let ports = json.dictionaryMap("nets").filter { $0.value.bool("is_port") == true }
        if let match = ports.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let named = ports.filter { $0.value.string("name")?.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one port is called \(reference); use its uuid.",
                                                    candidates: named.keys.sorted())
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound(
                "No port \(reference) on that block. Ports: \(ports.values.compactMap { $0.string("name") }.sorted().joined(separator: ", "))."
            )
        }
        return match.key
    }

    private func connectBlockPort(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        guard var instance = instances[id] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(id) names no block.")
        }
        guard let portReference = params.string("port") else {
            throw HorizontalDispatchError.invalidParams("connect_block_port needs \"port\".")
        }
        let port = try blockPortID(portReference, of: usedBlock)
        let net: String
        if let existing = try? netID(params) {
            net = existing
        } else if params.bool("create_net") ?? false, let name = params.string("net") {
            net = try ensureNet(["name": name]).0
        } else {
            throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
        }
        var connections = instance["connections"] as? JSONDictionary ?? [:]
        connections[port] = ["net": net]
        instance["connections"] = connections
        instances[id] = instance
        block["block_instances"] = instances
        return ["block_instance": id, "port": port, "net": net]
    }

    private func placeBlockSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        guard let instance = blockInstances()[id] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(id) names no block.")
        }
        // A block draws itself with the symbol it defines; without one there is
        // nothing to put on the sheet.
        guard let used = project.blocks.first(where: { $0.uuid.lowercased() == usedBlock.lowercased() }),
              let symbolFilename = used.symbolFilename, !symbolFilename.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "The block \(usedBlock) defines no symbol of its own, so it cannot be drawn on a sheet. Give it one in Horizontal first."
            )
        }
        let existing = try blockSymbolInstances().first { $0.json.string("block_instance")?.lowercased() == id.lowercased() }
        let targetSheet: String
        if params["sheet"] == nil, let existing {
            targetSheet = existing.sheet
        } else {
            targetSheet = try sheetID(params)
        }
        if let existing, existing.sheet != targetSheet {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is already on another sheet. Remove it with remove_block_symbol, then place it on \(targetSheet)."
            )
        }
        var item = existing?.json ?? ["block_instance": id]
        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Self.nanometres(x), Self.nanometres(y)]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_block_symbol needs \"x_mm\" and \"y_mm\" the first time.")
        }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement
        let symbolID = existing?.id ?? UUID().uuidString.lowercased()
        try updateSheet(targetSheet) { sheet in
            var symbols = sheet["block_symbols"] as? JSONDictionary ?? [:]
            symbols[symbolID] = item
            sheet["block_symbols"] = symbols
        }
        return ["block_symbol": symbolID, "block_instance": id, "sheet": targetSheet, "created": existing == nil]
    }

    private func blockSymbolInstances() throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        try sheetsInOrder().flatMap { sheet in
            sheet.json.dictionaryMap("block_symbols").sorted { $0.key < $1.key }.map { (sheet.id, $0.key, $0.value) }
        }
    }

    @discardableResult
    private func removeBlockSymbols(instanceID: String, sheetFilter: String?) throws -> Int {
        let doomed = try blockSymbolInstances().filter {
            $0.json.string("block_instance")?.lowercased() == instanceID.lowercased()
                && (sheetFilter == nil || $0.sheet == sheetFilter)
        }
        for symbol in doomed {
            try updateSheet(symbol.sheet) { sheet in
                var symbols = sheet["block_symbols"] as? JSONDictionary ?? [:]
                symbols.removeValue(forKey: symbol.id)
                sheet["block_symbols"] = symbols
            }
        }
        return doomed.count
    }

    private func removeBlockSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        let sheetFilter = params["sheet"] == nil ? nil : try sheetID(params)
        let removed = try removeBlockSymbols(instanceID: id, sheetFilter: sheetFilter)
        guard removed > 0 else {
            throw HorizontalDispatchError.notFound("No symbol for block instance \(id) is on a sheet.")
        }
        return ["block_instance": id, "symbols": removed]
    }

    // MARK: - Stackup

    private func setStackup(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let inner = params.int("inner_layers") else {
            throw HorizontalDispatchError.invalidParams("set_stackup needs \"inner_layers\".")
        }
        guard (0...30).contains(inner) else {
            throw HorizontalDispatchError.invalidParams("inner_layers must be between 0 and 30.")
        }
        let copper = Self.nanometres(params.double("copper_mm") ?? 0.035)
        guard copper > 0 else { throw HorizontalDispatchError.invalidParams("copper_mm must be above zero.") }
        let total = params.double("substrate_mm") ?? 1.6
        guard total > 0 else { throw HorizontalDispatchError.invalidParams("substrate_mm must be above zero.") }
        // Horizon's layers: 0 is top, -100 bottom, inner ones -1, -2, … Each
        // layer's substrate is the dielectric below it, so the bottom has none
        // and the cores share the total thickness between them.
        let cores = inner + 1
        let substrate = Self.nanometres(total / Double(cores))
        var stackup: JSONDictionary = ["0": ["thickness": copper, "substrate_thickness": substrate]]
        for layer in 1...max(inner, 1) where inner > 0 {
            stackup[String(-layer)] = ["thickness": copper, "substrate_thickness": substrate]
        }
        stackup["-100"] = ["thickness": copper, "substrate_thickness": 0]
        try updateBoard { board in
            board["n_inner_layers"] = inner
            board["stackup"] = stackup
        }
        return ["inner_layers": inner, "copper_layers": inner + 2, "copper_mm": Double(copper) / 1_000_000,
                "substrate_mm": Double(substrate) / 1_000_000,
                "note": "Copper layers are 0 (top), \(inner > 0 ? "-1…-\(inner) (inner), " : "")-100 (bottom)."]
    }

    // MARK: - Sheets

    /// The object maps a sheet carries. Mirrors the new-document template, so a
    /// sheet added here loads exactly like one the app made.
    private static let emptySheetKeys = ["junctions", "net_lines", "net_labels", "net_ties", "bus_labels",
                                         "bus_rippers", "power_symbols", "block_symbols", "symbols", "lines",
                                         "arcs", "texts", "pictures", "title_block_values"]

    private func addSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_sheet needs a \"name\".")
        }
        let sheets = try sheetsInOrder()
        let index = params.int("index") ?? ((sheets.map { $0.json.int("index") ?? 0 }.max() ?? 0) + 1)
        if let clash = sheets.first(where: { $0.json.int("index") == index }) {
            throw HorizontalDispatchError.invalidParams(
                "Sheet \(index) is already \(clash.json.string("name") ?? clash.id); pass another index or leave it out."
            )
        }
        let id = UUID().uuidString.lowercased()
        guard var schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        var all = schematic["sheets"] as? JSONDictionary ?? [:]
        var sheet: JSONDictionary = ["name": name, "index": index]
        for key in Self.emptySheetKeys { sheet[key] = [String: Any]() }
        all[id] = sheet
        schematic["sheets"] = all
        files["schematic"] = schematic
        dirty.insert("schematic")
        return ["sheet": id, "name": name, "index": index]
    }

    private func renameSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try sheetID(params)
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("rename_sheet needs a \"name\".")
        }
        try updateSheet(id) { $0["name"] = name }
        return ["sheet": id, "name": name]
    }

    private func removeSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try sheetID(params)
        let sheets = try sheetsInOrder()
        guard sheets.count > 1 else {
            throw HorizontalDispatchError.invalidParams("A schematic keeps at least one sheet.")
        }
        guard let sheet = sheets.first(where: { $0.id == id }) else {
            throw HorizontalDispatchError.notFound("No sheet \(id).")
        }
        // Deleting a page of work on the way to deleting a page is not a thing
        // to do quietly; clearing it is the caller's decision to make.
        let drawn = Self.emptySheetKeys
            .filter { $0 != "title_block_values" }
            .map { (key: $0, count: sheet.json.dictionaryMap($0).count) }
            .filter { $0.count > 0 }
        guard drawn.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "Sheet \(sheet.json.string("name") ?? id) still holds \(drawn.map { "\($0.count) \($0.key)" }.joined(separator: ", ")). Clear it first."
            )
        }
        guard var schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        var all = schematic["sheets"] as? JSONDictionary ?? [:]
        all.removeValue(forKey: id)
        schematic["sheets"] = all
        files["schematic"] = schematic
        dirty.insert("schematic")
        return ["sheet": id, "name": sheet.json.string("name") as Any]
    }

    /// Horizon's net-line endpoint: exactly one of the four is set.
    private static func pinEndpoint(_ path: String) -> JSONDictionary {
        ["bus_ripper": NSNull(), "junc": NSNull(), "pin": path, "port": NSNull()]
    }

    /// Horizon stores rotation as 1/65536 of a turn.
    private static func horizonAngle(_ degrees: Double) -> Int {
        var angle = Int((degrees / 360 * 65_536).rounded()) % 65_536
        if angle < 0 { angle += 65_536 }
        return angle
    }

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

    // MARK: - Board copper

    /// One end of a track, resolved to what the file will say and the net it
    /// already carries.
    private struct TrackEnd {
        var json: JSONDictionary
        var net: String?
        /// Set when this end needs a junction written for it.
        var newJunction: (id: String, point: [Int])?
    }

    private func board() throws -> JSONDictionary {
        guard isTopBlock else {
            throw HorizontalDispatchError.invalidParams(
                "The board belongs to the top block; a sub-block's components are instantiated wherever it is used, so there is no package to place for them. Edit the board without a \"block\"."
            )
        }
        guard let board = files["board"] else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        return board
    }

    private func updateBoard(_ body: (inout JSONDictionary) throws -> Void) throws {
        var board = try board()
        try body(&board)
        files["board"] = board
        dirty.insert("board")
    }

    private static func nanometres(_ millimetres: Double) -> Int {
        Int((millimetres * 1_000_000).rounded())
    }

    /// The pad uuid a name or uuid refers to on a component's package, and the
    /// net its pin is on.
    private func padOnComponent(_ reference: String, padReference: String) throws -> (package: String, pad: String, net: String?) {
        let componentID = try componentID(reference: reference)
        guard let component = components()[componentID] else {
            throw HorizontalDispatchError.notFound("No component \(reference).")
        }
        guard let partID = component.string("part")?.lowercased() else {
            throw HorizontalDispatchError.invalidParams("\(reference) has no part, so it has no pads.")
        }
        let packages = (try board()["packages"] as? JSONDictionary ?? [:])
        guard let placed = packages.first(where: { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == componentID }) else {
            throw HorizontalDispatchError.notFound("\(reference) is not placed on the board; place_component it first.")
        }
        let terminals = pool.terminals(partID: partID)
        let matches = terminals.filter {
            ($0.string("id") ?? "").caseInsensitiveCompare(padReference) == .orderedSame
                || ($0.string("name") ?? "").caseInsensitiveCompare(padReference) == .orderedSame
        }
        guard matches.count == 1, let terminal = matches.first, let padID = terminal.string("id") else {
            if matches.isEmpty {
                throw HorizontalDispatchError.notFound(
                    "No pad \(padReference) on \(reference). Pads: \(terminals.compactMap { $0.string("name") }.sorted().joined(separator: ", "))."
                )
            }
            throw HorizontalDispatchError.ambiguous("More than one pad on \(reference) is called \(padReference); use its uuid.",
                                                    candidates: matches.compactMap { $0.string("id") })
        }
        // The pad's net is the net of the pin it maps to.
        let net = terminal.string("gate_pin_path").flatMap { path in
            (component["connections"] as? JSONDictionary)?.dictionary(path)?.string("net")?.lowercased()
        }
        return (placed.key, padID, net)
    }

    private func resolveTrackEnd(_ params: JSONDictionary, key: String) throws -> TrackEnd {
        guard let endpoint = params[key] as? JSONDictionary else {
            throw HorizontalDispatchError.invalidParams("place_track needs \"\(key)\".")
        }
        let known: Set<String> = ["component", "pad", "junction", "x_mm", "y_mm"]
        let unknown = Set(endpoint.keys).subtracting(known)
        guard unknown.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Unknown \(key) fields: \(unknown.sorted().joined(separator: ", ")).")
        }
        if let component = endpoint.string("component") {
            guard let pad = endpoint.string("pad") else {
                throw HorizontalDispatchError.invalidParams("\(key) names a component, so it needs a \"pad\" too.")
            }
            let resolved = try padOnComponent(component, padReference: pad)
            return TrackEnd(json: ["junc": NSNull(), "pad": "\(resolved.package)/\(resolved.pad)"], net: resolved.net)
        }
        if let junction = endpoint.string("junction")?.lowercased() {
            let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
            guard let match = junctions.first(where: { $0.key.lowercased() == junction }) else {
                throw HorizontalDispatchError.notFound("No junction \(junction) on the board.")
            }
            return TrackEnd(json: ["junc": match.key, "pad": NSNull()],
                            net: (match.value as? JSONDictionary)?.string("net")?.lowercased())
        }
        guard let x = endpoint.double("x_mm"), let y = endpoint.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams(
                "\(key) must name a pad ({\"component\", \"pad\"}), a junction ({\"junction\"}) or a point ({\"x_mm\", \"y_mm\"})."
            )
        }
        let point = [Self.nanometres(x), Self.nanometres(y)]
        // A junction already at that exact point is the one to join, not a
        // second one on top of it.
        let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
        if let existing = junctions.first(where: { ($0.value as? JSONDictionary)?["position"] as? [Int] == point }) {
            return TrackEnd(json: ["junc": existing.key, "pad": NSNull()],
                            net: (existing.value as? JSONDictionary)?.string("net")?.lowercased())
        }
        let id = UUID().uuidString.lowercased()
        return TrackEnd(json: ["junc": id, "pad": NSNull()], net: nil, newJunction: (id, point))
    }

    private func writeJunction(_ id: String, point: [Int], net: String?) throws {
        try updateBoard { board in
            var junctions = board["junctions"] as? JSONDictionary ?? [:]
            var item = junctions[id] as? JSONDictionary ?? [:]
            item["position"] = point
            if let net { item["net"] = net } else { item.removeValue(forKey: "net") }
            junctions[id] = item
            board["junctions"] = junctions
        }
    }

    private func placeTrack(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let layer = params.int("layer") else {
            throw HorizontalDispatchError.invalidParams("place_track needs \"layer\"; board_info lists the copper layers.")
        }
        if let given = params.double("width_mm"), given <= 0 {
            throw HorizontalDispatchError.invalidParams("width_mm must be above zero.")
        }
        let from = try resolveTrackEnd(params, key: "from")
        let to = try resolveTrackEnd(params, key: "to")
        guard from.json["pad"] as? String != to.json["pad"] as? String || from.json["junc"] as? String != to.json["junc"] as? String else {
            throw HorizontalDispatchError.invalidParams("A track needs two different ends.")
        }

        // A track joins its ends, so ends on different nets would short them.
        // Refusing beats writing copper that quietly ties two nets together.
        let ends = [from.net, to.net].compactMap { $0 }
        if let first = ends.first, ends.contains(where: { $0 != first }) {
            let names = ends.map { nets()[$0]?.string("name") ?? $0 }
            throw HorizontalDispatchError.invalidParams(
                "The two ends are on different nets (\(names.joined(separator: ", "))); a track between them would short them."
            )
        }
        var carried = ends.first
        if let requested = params.string("net") {
            let resolved = try netID(reference: requested)
            if let carried, carried != resolved {
                throw HorizontalDispatchError.invalidParams(
                    "The ends are on \(nets()[carried]?.string("name") ?? carried), not \(requested)."
                )
            }
            carried = resolved
        }
        guard let net = carried else {
            throw HorizontalDispatchError.invalidParams("Neither end names a net, so pass \"net\".")
        }

        // A width the board's rules state for this net class on this layer is
        // not a guess; without one there is nothing to fall back on but a
        // number nobody chose, so the caller has to say.
        let ruled = ruledTrackWidth(net: net, layer: layer)
        guard let widthMM = params.double("width_mm") ?? ruled else {
            throw HorizontalDispatchError.invalidParams(
                "place_track needs \"width_mm\": this board states no track_width rule for that net class on layer \(layer). board_rules shows what it does state."
            )
        }
        for end in [from, to] {
            if let junction = end.newJunction {
                try writeJunction(junction.id, point: junction.point, net: net)
            }
        }
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            // Field set and defaults mirror Track::serialize, including pinning
            // width_from_net_class false so the width given here is the width used.
            tracks[id] = ["from": from.json, "to": to.json, "width": Self.nanometres(widthMM),
                          "layer": layer, "width_from_net_class": false, "locked": false, "net": net]
            board["tracks"] = tracks
        }
        var change: JSONDictionary = ["track": id, "net": net, "layer": layer, "width_mm": widthMM,
                                      "junctions_created": [from, to].compactMap { $0.newJunction?.id }]
        if params.double("width_mm") == nil { change["width_from"] = "track_width rule" }
        return change
    }

    /// The default width the board's `track_width` rules state for a net's
    /// class on a layer, in millimetres, or nil when they state none.
    private func ruledTrackWidth(net: String, layer: Int) -> Double? {
        guard let rules = (try? board())?.dictionary("rules") else { return nil }
        let netClass = nets()[net]?.string("net_class")?.lowercased()
        var best: Double?
        for (_, value) in rules {
            guard let rule = value as? JSONDictionary, rule.string("rule") == "track_width",
                  rule.bool("enabled") ?? true else { continue }
            let match = rule.dictionary("match")
            let mode = match?.string("mode") ?? "all"
            switch mode {
            case "all": break
            case "net_class":
                guard let netClass, match?.string("net_class")?.lowercased() == netClass else { continue }
            default: continue
            }
            guard let width = rule.dictionary("widths")?.dictionary(String(layer))?.double("def") else { continue }
            // A rule naming this net class beats one that matches everything.
            if mode == "net_class" { return width / 1_000_000 }
            best = best ?? width / 1_000_000
        }
        return best
    }

    /// Writes routed polylines as tracks, joining their bends with junctions.
    /// Used by `autoroute`, which has already had every path checked clear.
    /// Returns how many segments were written.
    func writeRoutedPaths(_ paths: [[HorizontalPoint]], net: String, layer: Int, widthMM: Double) throws -> Int {
        var written = 0
        for path in paths where path.count > 1 {
            var previous: JSONDictionary?
            for index in 1..<path.count {
                let a = path[index - 1], b = path[index]
                guard a != b else { continue }
                let from = try previous ?? endpointJSON(at: a, net: net)
                let to = try endpointJSON(at: b, net: net)
                let id = UUID().uuidString.lowercased()
                try updateBoard { board in
                    var tracks = board["tracks"] as? JSONDictionary ?? [:]
                    tracks[id] = ["from": from, "to": to, "width": Self.nanometres(widthMM),
                                  "layer": layer, "width_from_net_class": false, "locked": false, "net": net]
                    board["tracks"] = tracks
                }
                previous = to
                written += 1
            }
        }
        return written
    }

    /// A track end at a point: the pad whose centre it is, else a junction —
    /// reusing one already there so consecutive segments share their bend.
    private func endpointJSON(at point: HorizontalPoint, net: String) throws -> JSONDictionary {
        let key = [Int(point.x.rounded()), Int(point.y.rounded())]
        if let pad = project.board?.packagePadPositions.first(where: {
            Int($0.value.x.rounded()) == key[0] && Int($0.value.y.rounded()) == key[1]
        }) {
            return ["junc": NSNull(), "pad": pad.key]
        }
        let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
        if let existing = junctions.first(where: { ($0.value as? JSONDictionary)?["position"] as? [Int] == key }) {
            return ["junc": existing.key, "pad": NSNull()]
        }
        let id = UUID().uuidString.lowercased()
        try writeJunction(id, point: key, net: net)
        return ["junc": id, "pad": NSNull()]
    }

    private func trackID(_ params: JSONDictionary, key: String = "track") throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required; list_tracks returns the ids.")
        }
        let tracks = try board()["tracks"] as? JSONDictionary ?? [:]
        guard let match = tracks.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No track \(reference) on the board.")
        }
        return match
    }

    /// Drops junctions nothing refers to any more. Horizon has no free-standing
    /// junctions on a board; one exists to join copper.
    @discardableResult
    private func collectJunctions() throws -> [String] {
        var referenced = Set<String>()
        let board = try board()
        for (_, value) in board["tracks"] as? JSONDictionary ?? [:] {
            guard let track = value as? JSONDictionary else { continue }
            for end in ["from", "to"] {
                if let junction = track.dictionary(end)?.string("junc") { referenced.insert(junction.lowercased()) }
            }
        }
        for (_, value) in board["vias"] as? JSONDictionary ?? [:] {
            if let junction = (value as? JSONDictionary)?.string("junction") { referenced.insert(junction.lowercased()) }
        }
        var removed = [String]()
        try updateBoard { board in
            var junctions = board["junctions"] as? JSONDictionary ?? [:]
            for id in junctions.keys where !referenced.contains(id.lowercased()) {
                junctions.removeValue(forKey: id)
                removed.append(id)
            }
            board["junctions"] = junctions
        }
        return removed.sorted()
    }

    private func removeTrack(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try trackID(params)
        try updateBoard { board in
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            tracks.removeValue(forKey: id)
            board["tracks"] = tracks
        }
        return ["track": id, "junctions_removed": try collectJunctions()]
    }

    private func setTrackWidth(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try trackID(params)
        guard let widthMM = params.double("width_mm"), widthMM > 0 else {
            throw HorizontalDispatchError.invalidParams("set_track_width needs a \"width_mm\" above zero.")
        }
        try updateBoard { board in
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            var track = tracks[id] as? JSONDictionary ?? [:]
            track["width"] = Self.nanometres(widthMM)
            // The width given is the width used, not the net class's.
            track["width_from_net_class"] = false
            tracks[id] = track
            board["tracks"] = tracks
        }
        return ["track": id, "width_mm": widthMM]
    }

    private func placeVia(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_via needs \"x_mm\" and \"y_mm\".")
        }
        guard let reference = params.string("net") else {
            throw HorizontalDispatchError.invalidParams("place_via needs \"net\": a via carries one.")
        }
        let net = try netID(reference: reference)
        let padstack = params.string("padstack")?.lowercased() ?? project.board?.viaTemplate?.padstackID
        guard let padstack else {
            throw HorizontalDispatchError.invalidParams(
                "The board has no via to copy a padstack from, so pass \"padstack\" — a via padstack uuid from search_pool."
            )
        }
        let point = [Self.nanometres(x), Self.nanometres(y)]
        let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
        let junction: String
        if let existing = junctions.first(where: { ($0.value as? JSONDictionary)?["position"] as? [Int] == point }) {
            junction = existing.key
        } else {
            junction = UUID().uuidString.lowercased()
        }
        try writeJunction(junction, point: point, net: net)
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var vias = board["vias"] as? JSONDictionary ?? [:]
            // net_set pins the net onto the via, so it seeds propagation like a
            // pad instead of waiting for copper to reach it.
            vias[id] = ["junction": junction, "padstack": padstack, "from_rules": true,
                        "net_set": net, "parameter_set": [String: Any]()]
            board["vias"] = vias
        }
        return ["via": id, "junction": junction, "net": net, "padstack": padstack]
    }

    private func removeVia(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("via"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_via needs \"via\"; list_vias returns the ids.")
        }
        let vias = try board()["vias"] as? JSONDictionary ?? [:]
        guard let id = vias.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No via \(reference) on the board.")
        }
        try updateBoard { board in
            var vias = board["vias"] as? JSONDictionary ?? [:]
            vias.removeValue(forKey: id)
            board["vias"] = vias
        }
        return ["via": id, "junctions_removed": try collectJunctions()]
    }

    // MARK: - Board polygons and planes

    /// Horizon's polygon vertex: a straight corner unless an arc says otherwise.
    private func polygonVertices(_ params: JSONDictionary) throws -> [JSONDictionary] {
        guard let raw = params["vertices"] as? [Any] else {
            throw HorizontalDispatchError.invalidParams("vertices is required: three or more {\"x_mm\", \"y_mm\"} points.")
        }
        return try raw.enumerated().map { index, value in
            guard let point = value as? JSONDictionary, let x = point.double("x_mm"), let y = point.double("y_mm") else {
                throw HorizontalDispatchError.invalidParams("Vertex \(index) needs \"x_mm\" and \"y_mm\".")
            }
            let unknown = Set(point.keys).subtracting(["x_mm", "y_mm"])
            guard unknown.isEmpty else {
                throw HorizontalDispatchError.invalidParams("Unknown vertex fields: \(unknown.sorted().joined(separator: ", ")). Arcs are the app's.")
            }
            return ["type": "line", "position": [Self.nanometres(x), Self.nanometres(y)],
                    "arc_center": [0, 0], "arc_reverse": false]
        }
    }

    /// Writes a polygon and returns its id. Field set mirrors Polygon::serialize.
    private func writePolygon(layer: Int, vertices: [JSONDictionary]) throws -> String {
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var polygons = board["polygons"] as? JSONDictionary ?? [:]
            polygons[id] = ["layer": layer, "parameter_class": "", "vertices": vertices]
            board["polygons"] = polygons
        }
        return id
    }

    private func placePolygon(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let layer = params.int("layer") else {
            throw HorizontalDispatchError.invalidParams("place_polygon needs \"layer\"; 100 is the board outline.")
        }
        let vertices = try polygonVertices(params)
        let id = try writePolygon(layer: layer, vertices: vertices)
        var change: JSONDictionary = ["polygon": id, "layer": layer, "vertices": vertices.count]
        if layer == 100 { change["note"] = "Layer 100 is the board outline; this is the shape the board is cut to." }
        return change
    }

    private func polygonID(_ params: JSONDictionary, key: String) throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required.")
        }
        let polygons = try board()["polygons"] as? JSONDictionary ?? [:]
        guard let match = polygons.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No polygon \(reference) on the board.")
        }
        return match
    }

    private func removePolygon(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try polygonID(params, key: "polygon")
        // A plane's polygon is the plane's shape; removing it alone would leave
        // a plane pouring into nothing.
        let planes = try board()["planes"] as? JSONDictionary ?? [:]
        if let owner = planes.first(where: { ($0.value as? JSONDictionary)?.string("polygon")?.lowercased() == id.lowercased() }) {
            throw HorizontalDispatchError.invalidParams("Polygon \(id) is the shape of plane \(owner.key); remove_plane takes both.")
        }
        try updateBoard { board in
            var polygons = board["polygons"] as? JSONDictionary ?? [:]
            polygons.removeValue(forKey: id)
            board["polygons"] = polygons
        }
        return ["polygon": id]
    }

    private func placePlane(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let layer = params.int("layer") else {
            throw HorizontalDispatchError.invalidParams("place_plane needs a copper \"layer\".")
        }
        let net = try netID(params)
        let vertices = try polygonVertices(params)
        let polygon = try writePolygon(layer: layer, vertices: vertices)
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var planes = board["planes"] as? JSONDictionary ?? [:]
            // Field set mirrors Plane::serialize. from_rules true takes the pour
            // settings from the board rules, which is Horizon's default.
            planes[id] = ["net": net, "polygon": polygon, "priority": params.int("priority") ?? 0,
                          "from_rules": true, "settings": [String: Any]()]
            board["planes"] = planes
        }
        return ["plane": id, "polygon": polygon, "net": net, "layer": layer,
                "note": "Defined, not filled. pour_planes computes the copper."]
    }

    private func removePlane(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("plane"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_plane needs \"plane\"; list_planes returns the ids.")
        }
        let planes = try board()["planes"] as? JSONDictionary ?? [:]
        guard let match = planes.first(where: { $0.key.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No plane \(reference) on the board.")
        }
        let polygon = (match.value as? JSONDictionary)?.string("polygon")
        try updateBoard { board in
            var planes = board["planes"] as? JSONDictionary ?? [:]
            planes.removeValue(forKey: match.key)
            board["planes"] = planes
            if let polygon {
                var polygons = board["polygons"] as? JSONDictionary ?? [:]
                polygons.removeValue(forKey: polygon)
                board["polygons"] = polygons
            }
        }
        return ["plane": match.key, "polygon": polygon as Any? as Any]
    }

    // MARK: - Board

    private func placeComponent(_ id: String, _ params: JSONDictionary) throws -> String {
        var board = try self.board()
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
        _ = try board()
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
