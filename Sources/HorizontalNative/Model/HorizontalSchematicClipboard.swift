import Foundation
import HorizontalProjectIO
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A self-contained circuit fragment. Like Horizon's ClipboardSchematic and
/// ToolPaste, it carries the electrical graph, not just its drawing.
/// Behavior reference: horizon-eda/horizon at 3d4e309, src/core/clipboard/
/// clipboard_schematic.cpp and src/core/tools/tool_paste.cpp.
struct HorizontalSchematicClipboard {
    var json: JSONDictionary
    var anchor: HorizontalPoint { json.point("cursor_pos") ?? .zero }

    init(json: JSONDictionary) { self.json = json }

    init(data: Data) throws {
        json = try JSONHelper.loadDictionary(from: data)
        guard json.int("horizontal_schematic_clipboard") == 1 else {
            throw HorizontalDispatchError.invalidParams("The clipboard does not contain schematic items.")
        }
    }

    func data() throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) }

    private static let pasteboardType = "org.horizontal.schematic-clipboard"

    @MainActor func writeToPasteboard() throws {
        let data = try data()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .init(Self.pasteboardType))
        #elseif os(iOS)
        UIPasteboard.general.setData(data, forPasteboardType: Self.pasteboardType)
        #endif
    }

    @MainActor static func readFromPasteboard() throws -> Self? {
        #if os(macOS)
        let data = NSPasteboard.general.data(forType: .init(pasteboardType))
        #elseif os(iOS)
        let data = UIPasteboard.general.data(forPasteboardType: pasteboardType)
        #else
        let data: Data? = nil
        #endif
        return try data.map { try Self(data: $0) }
    }
}

enum HorizontalSchematicClipboardEditor {
    static let sheetTables: [(String, HorizontalObjectType)] = [
        ("symbols", .schematicSymbol), ("net_lines", .lineNet), ("junctions", .junction),
        ("lines", .drawingLine), ("arcs", .drawingArc), ("texts", .text),
        ("net_labels", .netLabel), ("power_symbols", .powerSymbol),
        ("bus_labels", .busLabel), ("bus_rippers", .busRipper),
        ("net_ties", .schematicNetTie), ("block_symbols", .schematicBlockSymbol)
    ]

    static func supports(_ ref: HorizontalSelectableRef) -> Bool {
        sheetTables.contains { $0.1 == ref.type }
    }

    static func copy(
        _ refs: [HorizontalSelectableRef], from sheet: HorizontalSchematicSheet,
        schematicURL: URL, anchor: HorizontalPoint,
        archive: HorizontalProjectArchive, project: HorizontalProject
    ) throws -> HorizontalSchematicClipboard {
        let context = try context(schematicURL: schematicURL, sheetID: sheet.id, archive: archive, project: project)
        let source = context.sheet
        let block = context.block
        var tables = [String: [String: JSONDictionary]]()
        for (table, type) in sheetTables {
            let wanted = Set(refs.filter { $0.type == type }.map { rawID($0.id) })
            tables[table] = map(source, table).filter { wanted.contains($0.key) }
        }
        guard tables.values.contains(where: { !$0.isEmpty }) else {
            throw HorizontalDispatchError.invalidParams("Select schematic items to copy.")
        }
        func include(_ id: String?, table: String, in json: JSONDictionary = [:]) {
            guard let id = id?.lowercased(), let item = map(json.isEmpty ? source : json, table)[id] else { return }
            tables[table, default: [:]][id] = item
        }
        var nets = Set<String>()
        for symbol in tables["symbols", default: [:]].values {
            include(symbol.string("component"), table: "components", in: block)
            for id in symbol["texts"] as? [String] ?? [] { include(id, table: "texts") }
        }
        for symbol in tables["block_symbols", default: [:]].values {
            include(symbol.string("block_instance"), table: "block_instances", in: block)
        }
        for table in ["lines", "arcs", "net_ties"] {
            for item in tables[table, default: [:]].values {
                for key in ["from", "to", "center"] { include(item.string(key), table: "junctions") }
                if table == "net_ties" { include(item.string("net_tie"), table: "block_net_ties", in: ["block_net_ties": block.dictionaryMap("net_ties")]) }
            }
        }
        for table in ["net_labels", "power_symbols", "bus_labels", "bus_rippers"] {
            for item in tables[table, default: [:]].values {
                include(item.string("junction"), table: "junctions")
                include(item.string("bus"), table: "buses", in: block)
                if let net = item.string("net") ?? item.string("last_net") { nets.insert(net.lowercased()) }
            }
        }

        // Pins/ports outside the selection become free junctions. Their UUIDs
        // must never point back into the source circuit after a paste.
        var copiedPins = [String: Set<String>]()
        var copiedPorts = [String: Set<String>]()
        for (id, original) in tables["net_lines", default: [:]] {
            var line = original
            include(line.string("bus"), table: "buses", in: block)
            let geometry = sheet.netLines.first { $0.id.lowercased() == id }
            let net = geometry?.netID?.lowercased() ?? line.string("net")?.lowercased()
            if let net { nets.insert(net); line["net"] = net }
            for end in ["from", "to"] {
                guard let endpoint = line.dictionary(end) else { continue }
                if let junction = endpoint.string("junc") {
                    include(junction, table: "junctions")
                    continue
                }
                let pin = endpoint.string("pin")?.lowercased().split(separator: "/").map(String.init)
                let port = endpoint.string("port")?.lowercased().split(separator: "/").map(String.init)
                if let pin, pin.count == 2, let symbol = tables["symbols"]?[pin[0]],
                   let component = symbol.string("component"), let gate = symbol.string("gate") {
                    copiedPins[component.lowercased(), default: []].insert("\(gate.lowercased())/\(pin[1])")
                } else if let port, port.count == 2, let symbol = tables["block_symbols"]?[port[0]],
                          let instance = symbol.string("block_instance") {
                    copiedPorts[instance.lowercased(), default: []].insert(port[1])
                } else if let ripper = endpoint.string("bus_ripper")?.lowercased(), tables["bus_rippers"]?[ripper] != nil {
                    continue
                } else {
                    guard let point = end == "from" ? geometry?.from : geometry?.to else {
                        throw HorizontalDispatchError.invalidParams("A copied wire has an unresolved endpoint.")
                    }
                    let junction = uuid()
                    var item: JSONDictionary = ["position": pointJSON(point)]
                    if let net { item["net"] = net }
                    tables["junctions", default: [:]][junction] = item
                    line[end] = ["junc": junction, "pin": NSNull(), "port": NSNull(), "bus_ripper": NSNull()]
                }
            }
            tables["net_lines"]?[id] = line
        }
        for (id, original) in tables["junctions", default: [:]] {
            var item = original
            if let net = sheet.junctionNetIDs[id]?.lowercased() ?? item.string("net")?.lowercased() {
                nets.insert(net)
                item["net"] = net
            }
            tables["junctions"]?[id] = item
        }
        for item in tables["buses", default: [:]].values {
            for member in item.dictionaryMap("members").values {
                if let net = member.string("net") { nets.insert(net.lowercased()) }
            }
        }
        for item in tables["block_net_ties", default: [:]].values {
            for key in ["net_primary", "net_secondary"] {
                if let net = item.string(key) { nets.insert(net.lowercased()) }
            }
        }
        for table in ["components", "block_instances"] {
            for (id, original) in tables[table, default: [:]] {
                var item = original
                let connected = table == "components" ? copiedPins[id, default: []] : copiedPorts[id, default: []]
                item["connections"] = item.dictionaryMap("connections").filter { path, connection in
                    guard let net = connection.string("net"), net != HorizontalProjectArchive.nullUUID else { return true }
                    return connected.contains(path.lowercased()) && nets.contains(net.lowercased())
                }
                tables[table]?[id] = item
            }
        }
        tables["nets"] = map(block, "nets").filter { nets.contains($0.key) }
        var json = tables.mapValues { $0 as Any }
        json["horizontal_schematic_clipboard"] = 1
        json["cursor_pos"] = pointJSON(anchor)
        for key in ["group_names", "tag_names"] {
            let field = key == "group_names" ? "group" : "tag"
            let ids = Set(tables["components", default: [:]].values.compactMap { $0.string(field) })
            json[key] = (block[key] as? JSONDictionary ?? [:]).filter { ids.contains($0.key) }
        }
        let resources = tables["components", default: [:]].values.flatMap { [$0.string("entity"), $0.string("part")] }
            + tables["symbols", default: [:]].values.map { $0.string("symbol") }
        json["pool_files"] = try poolFiles(for: resources.compactMap { $0 }, archive: archive, project: project)
            .mapValues { $0.base64EncodedString() }
        return HorizontalSchematicClipboard(json: json)
    }

    static func prepare(
        _ clipboard: HorizontalSchematicClipboard, at point: HorizontalPoint,
        sheetID: String, schematicURL: URL,
        archive: HorizontalProjectArchive, project: HorizontalProject
    ) throws -> HorizontalSchematicPaste {
        let context = try context(schematicURL: schematicURL, sheetID: sheetID, archive: archive, project: project)
        var result = archive
        var block = context.block
        var schematic = context.schematic
        var sheet = context.sheet
        let source = clipboard.json
        var ids = [String: String]()
        var nets = map(block, "nets")
        let destinationNets = nets
        let defaultClass = block.string("net_class_default") ?? HorizontalProjectArchive.nullUUID
        for (old, original) in map(source, "nets").sorted(by: { $0.key < $1.key }) {
            let name = original.string("name") ?? ""
            let matches = name.isEmpty ? [] : nets.keys.filter { nets[$0]?.string("name") == name }
            guard matches.count <= 1 else {
                throw HorizontalDispatchError.invalidParams("More than one net is named \(name). Give those nets distinct names before pasting.")
            }
            if let existing = matches.first {
                ids[old] = existing
            } else {
                let id = uuid()
                ids[old] = id
                var net = original
                net["net_class"] = defaultClass
                net["is_port"] = false
                nets[id] = net
            }
        }
        for id in Set(ids.values) where destinationNets[id] == nil {
            if var net = nets[id] {
                if let pair = net.string("diffpair"), let mapped = ids[pair.lowercased()] {
                    net["diffpair"] = mapped
                } else {
                    net["diffpair"] = HorizontalProjectArchive.nullUUID
                    net["diffpair_primary"] = false
                }
                nets[id] = net
            }
        }
        block["nets"] = nets
        for table in ["components", "block_instances", "buses", "block_net_ties"] + sheetTables.map(\.0) {
            for id in map(source, table).keys where ids[id] == nil { ids[id] = uuid() }
        }
        // Bus members also have identities, referenced by rippers.
        for bus in map(source, "buses").values {
            for id in bus.dictionaryMap("members").keys { ids[id.lowercased()] = uuid() }
        }
        for instance in map(source, "block_instances").values {
            guard let used = instance.string("block"), used.lowercased() != block.string("uuid")?.lowercased(),
                  project.blocks.contains(where: { $0.uuid.lowercased() == used.lowercased() }) else {
                throw HorizontalDispatchError.invalidParams("A copied block is not available in this destination schematic.")
            }
            // Do not introduce a hierarchy cycle through an ancestor.
            var visited = Set<String>()
            func reachesDestination(_ id: String) throws -> Bool {
                if id.lowercased() == block.string("uuid")?.lowercased() { return true }
                guard visited.insert(id.lowercased()).inserted,
                      let definition = project.blocks.first(where: { $0.uuid.lowercased() == id.lowercased() }),
                      let path = definition.blockFilename else { return false }
                for child in try read(path, archive: archive).dictionaryMap("block_instances").values {
                    if let next = child.string("block"), try reachesDestination(next) { return true }
                }
                return false
            }
            guard try !reachesDestination(used) else { throw HorizontalDispatchError.invalidParams("Pasting this block would make it contain itself.") }
        }
        for table in ["components", "block_instances", "buses", "block_net_ties"] {
            let destination = table == "block_net_ties" ? "net_ties" : table
            var entries = map(block, destination)
            var refdeses = Set(entries.values.compactMap { $0.string("refdes") })
            for (old, value) in map(source, table).sorted(by: {
                let comparison = ($0.value.string("refdes") ?? "").localizedStandardCompare($1.value.string("refdes") ?? "")
                return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
            }) {
                guard let id = ids[old], var item = remap(value, ids: ids) as? JSONDictionary else { continue }
                if table == "components" || table == "block_instances" {
                    let original = value.string("refdes") ?? "X"
                    let prefix = String(original.prefix { !$0.isNumber && $0 != "?" })
                    var number = 1
                    while refdeses.contains("\(prefix)\(number)") { number += 1 }
                    item["refdes"] = "\(prefix)\(number)"
                    refdeses.insert("\(prefix)\(number)")
                }
                entries[id] = item
            }
            block[destination] = entries
        }
        for table in ["group_names", "tag_names"] {
            var names = block[table] as? JSONDictionary ?? [:]
            for (id, name) in source[table] as? JSONDictionary ?? [:] where names[id] == nil { names[id] = name }
            block[table] = names
        }
        var pastedIDs = Set<String>()
        var refs = [HorizontalSelectableRef]()
        let translation = HorizontalPlacementTransform(shift: point - clipboard.anchor, angle: 0, mirrored: false)
        for (table, type) in sheetTables {
            var entries = map(sheet, table)
            for (old, value) in map(source, table) {
                guard let id = ids[old], let item = remap(value, ids: ids) as? JSONDictionary else { continue }
                entries[id] = transformed(item, table: table, by: translation)
                pastedIDs.insert(id)
                let refID = table == "lines" ? "sheet/line/\(id)" : (table == "arcs" ? "sheet/arc/\(id)" : id)
                refs.append(HorizontalSelectableRef(id: refID, type: type))
            }
            sheet[table] = entries
        }
        guard !refs.isEmpty else { throw HorizontalDispatchError.invalidParams("The clipboard contains no schematic items.") }
        var sheets = schematic.dictionaryMap("sheets")
        sheets[context.sheetKey] = sheet
        schematic["sheets"] = sheets
        try write(block, path: context.blockPath, archive: &result)
        try write(schematic, path: context.schematicPath, archive: &result)
        if let pool = project.poolDirectory {
            for (path, value) in source["pool_files"] as? [String: String] ?? [:] {
                guard safeRelativePath(path), let data = Data(base64Encoded: value) else {
                    throw HorizontalDispatchError.invalidParams("The clipboard contains an invalid part definition.")
                }
                let target = pool + "/" + path
                if result.regularFileData(relativePath: target) == nil {
                    try result.replaceRegularFileData(relativePath: target, with: data)
                }
            }
        }
        var reloaded = try HorizontalProject.loadSnapshot(of: result)
        reloaded.rebaseURLs(onto: project)
        let loaded = reloaded.schematics.first { $0.schematic.url.standardizedFileURL == schematicURL.standardizedFileURL }?.schematic
            ?? reloaded.schematic
        guard let preview = loaded?.sheets.first(where: { $0.id == sheetID }) else {
            throw HorizontalDispatchError.failed("Could not load the pasted schematic items.")
        }
        return HorizontalSchematicPaste(baseArchive: archive, archive: result, sheet: preview, refs: refs, pastedIDs: pastedIDs,
                                        schematicPath: context.schematicPath, sheetKey: context.sheetKey)
    }

    private struct Context {
        var blockPath: String
        var schematicPath: String
        var sheetKey: String
        var block: JSONDictionary
        var schematic: JSONDictionary
        var sheet: JSONDictionary
    }

    private static func context(schematicURL: URL, sheetID: String, archive: HorizontalProjectArchive, project: HorizontalProject) throws -> Context {
        let definition = project.schematics.first { $0.schematic.url.standardizedFileURL == schematicURL.standardizedFileURL }?.block
        guard let blockPath = definition?.blockFilename ?? project.blockFilename,
              let schematicPath = definition?.schematicFilename ?? project.schematicFilename else {
            throw HorizontalDispatchError.notFound("The schematic is not part of this project.")
        }
        let schematic = try read(schematicPath, archive: archive)
        guard let key = schematic.dictionaryMap("sheets").keys.first(where: { $0.lowercased() == sheetID.lowercased() }),
              let sheet = schematic.dictionaryMap("sheets")[key] else {
            throw HorizontalDispatchError.notFound("The schematic sheet no longer exists.")
        }
        return Context(blockPath: blockPath, schematicPath: schematicPath, sheetKey: key,
                       block: try read(blockPath, archive: archive), schematic: schematic, sheet: sheet)
    }

    static func read(_ path: String, archive: HorizontalProjectArchive) throws -> JSONDictionary {
        guard let data = archive.regularFileData(relativePath: path) else { throw HorizontalDispatchError.notFound("Missing project file \(path).") }
        return try JSONHelper.loadDictionary(from: data)
    }

    static func write(_ json: JSONDictionary, path: String, archive: inout HorizontalProjectArchive) throws {
        try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
    }

    private static func map(_ json: JSONDictionary, _ key: String) -> [String: JSONDictionary] {
        Dictionary(json.dictionaryMap(key).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func rawID(_ id: String) -> String {
        let id = id.lowercased()
        if id.hasPrefix("sheet/line/") || id.hasPrefix("sheet/arc/") { return String(id.split(separator: "/").last ?? "") }
        return String(id.split(separator: "/").first ?? "")
    }

    private static func uuid() -> String { UUID().uuidString.lowercased() }
    static func pointJSON(_ point: HorizontalPoint) -> [Int64] { [Int64(point.x.rounded()), Int64(point.y.rounded())] }

    private static func remap(_ value: Any, ids: [String: String]) -> Any {
        if let string = value as? String {
            if let id = ids[string.lowercased()] { return id }
            let parts = string.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = ids[parts[0].lowercased()] { return id + "/" + parts[1] }
            return string
        }
        if let array = value as? [Any] { return array.map { remap($0, ids: ids) } }
        if let object = value as? JSONDictionary {
            let literalFields: Set<String> = ["text", "name", "value", "refdes", "custom_value", "custom_name"]
            return Dictionary(object.map {
                (ids[$0.key.lowercased()] ?? $0.key, literalFields.contains($0.key) ? $0.value : remap($0.value, ids: ids))
            }, uniquingKeysWith: { first, _ in first })
        }
        return value
    }

    static func transformed(_ source: JSONDictionary, table: String, by transform: HorizontalPlacementTransform) -> JSONDictionary {
        var item = source
        if let position = item.point("position") { item["position"] = pointJSON(transform.applying(to: position)) }
        if let placement = HorizontalPlacementTransform(json: item.dictionary("placement")) {
            let mapped = table == "symbols" || table == "block_symbols"
                ? transform.accumulatedSchematic(with: placement)
                : transform.accumulated(with: placement)
            var json = item.dictionary("placement") ?? [:]
            json["shift"] = pointJSON(mapped.shift)
            json["angle"] = mapped.angle
            json["mirror"] = mapped.mirrored
            item["placement"] = json
        }
        if let orientation = item.string("orientation") { item["orientation"] = transformedOrientation(orientation, by: transform) }
        if table == "power_symbols", transform.mirrored { item["mirror"] = !(item.bool("mirror") ?? false) }
        if table == "arcs", transform.mirrored { (item["from"], item["to"]) = (item["to"], item["from"]) }
        return item
    }

    static func transformedOrientation(_ orientation: String, by transform: HorizontalPlacementTransform) -> String {
        let directions = ["right": HorizontalPoint(x: 1, y: 0), "up": HorizontalPoint(x: 0, y: 1),
                          "left": HorizontalPoint(x: -1, y: 0), "down": HorizontalPoint(x: 0, y: -1)]
        guard let vector = directions[orientation] else { return orientation }
        let mapped = HorizontalPlacementTransform(shift: .zero, angle: transform.angle, mirrored: transform.mirrored).applying(to: vector)
        return abs(mapped.x) > abs(mapped.y) ? (mapped.x > 0 ? "right" : "left") : (mapped.y > 0 ? "up" : "down")
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Carry just the selected parts' dependency closure, including cached
    /// models. Pasting remains possible after the source document is closed.
    private static func poolFiles(for roots: [String], archive: HorizontalProjectArchive, project: HorizontalProject) throws -> [String: Data] {
        guard !roots.isEmpty, let pool = project.poolDirectory else { return [:] }
        let prefix = pool + "/"
        var index = [String: (String, JSONDictionary)]()
        for path in archive.regularFilePaths where path.hasPrefix(prefix) && path.hasSuffix(".json") {
            guard let data = archive.regularFileData(relativePath: path), let json = try? JSONHelper.loadDictionary(from: data),
                  let id = json.string("uuid") else { continue }
            index[id.lowercased()] = (String(path.dropFirst(prefix.count)), json)
        }
        var result = [String: Data]()
        var visited = Set<String>()
        func visitValue(_ value: Any) throws {
            if let string = value as? String {
                if index[string.lowercased()] != nil { try visit(string.lowercased()) }
                else if safeRelativePath(string), let data = archive.regularFileData(relativePath: prefix + string) { result[string] = data }
            } else if let object = value as? JSONDictionary {
                for value in object.values { try visitValue(value) }
            } else if let array = value as? [Any] {
                for value in array { try visitValue(value) }
            }
        }
        func visit(_ id: String) throws {
            guard visited.insert(id).inserted else { return }
            guard let (path, json) = index[id], let data = archive.regularFileData(relativePath: prefix + path) else {
                throw HorizontalDispatchError.notFound("A copied item's part definition is missing (\(id)).")
            }
            let directories = ["part": "parts", "entity": "entities", "unit": "units", "symbol": "symbols", "padstack": "padstacks"]
            let destination: String
            if let directory = directories[json.string("type") ?? ""] {
                destination = "\(directory)/cache/\(id).json"
            } else if json.string("type") == "package" {
                destination = "packages/cache/\(id)/package.json"
            } else {
                destination = path
            }
            result[destination] = data
            try visitValue(json)
            if json.string("type") == "unit" {
                for (symbolID, entry) in index where entry.1.string("type") == "symbol" && entry.1.string("unit")?.lowercased() == id {
                    try visit(symbolID)
                }
            }
        }
        for id in roots { try visit(id.lowercased()) }
        return result
    }
}

struct HorizontalSchematicPaste {
    var baseArchive: HorizontalProjectArchive
    var archive: HorizontalProjectArchive
    var sheet: HorizontalSchematicSheet
    var refs: [HorizontalSelectableRef]
    var pastedIDs: Set<String>
    var schematicPath: String
    var sheetKey: String

    /// A rigid preview of just the pasted items. Coordinate-based move plans
    /// would also pick up original wires when Duplicate starts on top of them.
    func preview(_ transform: HorizontalPlacementTransform) -> HorizontalSchematicSheet {
        var result = sheet
        func includes(_ id: String) -> Bool { pastedIDs.contains(HorizontalSchematicClipboardEditor.rawID(id)) }
        func update<T: Identifiable>(_ items: inout [T], _ change: (inout T) -> Void) where T.ID == String {
            for index in items.indices where includes(items[index].id) { change(&items[index]) }
        }
        func segment(_ line: inout HorizontalSegment) {
            line.from = transform.applying(to: line.from)
            line.to = transform.applying(to: line.to)
        }
        func arc(_ arc: inout HorizontalArc) {
            arc.from = transform.applying(to: arc.from)
            arc.to = transform.applying(to: arc.to)
            arc.center = transform.applying(to: arc.center)
            if transform.mirrored { arc.reverse.toggle() }
        }
        func text(_ text: inout HorizontalText) {
            let placement = transform.accumulated(with: HorizontalPlacementTransform(shift: text.position, angle: text.angle, mirrored: text.mirrored))
            text.position = placement.shift
            text.angle = placement.angle
            text.mirrored = placement.mirrored
        }
        func polygon(_ polygon: inout HorizontalPolygon) {
            polygon.polygonVertices = polygon.polygonVertices.map { $0.transformed(transform.applying, flipsArcReverse: transform.mirrored) }
        }
        func circle(_ circle: inout HorizontalCircle) { circle.center = transform.applying(to: circle.center) }
        for (id, point) in result.junctions where includes(id) { result.junctions[id] = transform.applying(to: point) }
        update(&result.symbols) { symbol in
            let placement = transform.accumulatedSchematic(with: HorizontalPlacementTransform(shift: symbol.position, angle: symbol.angle, mirrored: symbol.mirrored))
            symbol.position = placement.shift
            symbol.angle = placement.angle
            symbol.mirrored = placement.mirrored
        }
        update(&result.netLines, segment)
        update(&result.drawingLines, segment)
        update(&result.drawingArcs, arc)
        update(&result.symbolLines, segment)
        update(&result.symbolPins, segment)
        update(&result.symbolPinCircles, circle)
        update(&result.symbolPolygons, polygon)
        update(&result.symbolTexts, text)
        update(&result.texts, text)
        update(&result.blockSymbolLines, segment)
        update(&result.blockSymbolPorts, segment)
        update(&result.blockSymbolTexts, text)
        update(&result.busRipperLines, segment)
        update(&result.busRipperTexts, text)
        update(&result.powerSymbolLines, segment)
        update(&result.powerSymbolCircles, circle)
        update(&result.powerSymbolTexts, text)
        update(&result.noPopulateMarks) { mark in
            segment(&mark.firstLine)
            segment(&mark.secondLine)
        }
        update(&result.netLabels) { label in
            label.position = transform.applying(to: label.position)
            label.orientation = HorizontalSchematicClipboardEditor.transformedOrientation(label.orientation, by: transform)
        }
        update(&result.busLabels) { label in
            label.position = transform.applying(to: label.position)
            label.orientation = HorizontalSchematicClipboardEditor.transformedOrientation(label.orientation, by: transform)
        }
        update(&result.powerSymbols) { symbol in
            symbol.orientation = HorizontalSchematicClipboardEditor.transformedOrientation(symbol.orientation, by: transform)
            symbol.mirrored = symbol.mirrored != transform.mirrored
        }
        update(&result.netTies) { tie in
            tie.from = transform.applying(to: tie.from)
            tie.to = transform.applying(to: tie.to)
        }
        return result
    }

    /// Transform only the new graph. Existing wires and coincident junctions
    /// must not be pulled along or rewired while the paste follows the cursor.
    func placedArchive(_ transform: HorizontalPlacementTransform, in currentArchive: HorizontalProjectArchive) throws -> HorizontalProjectArchive {
        guard currentArchive == baseArchive else {
            throw HorizontalDispatchError.failed("The document changed while placing these items. Paste again to use the updated document.")
        }
        var result = archive
        var schematic = try HorizontalSchematicClipboardEditor.read(schematicPath, archive: result)
        var sheets = schematic.dictionaryMap("sheets")
        guard var sheet = sheets[sheetKey] else { throw HorizontalDispatchError.notFound("The paste destination no longer exists.") }
        for (table, _) in HorizontalSchematicClipboardEditor.sheetTables {
            var items = sheet.dictionaryMap(table)
            for (id, item) in items where pastedIDs.contains(id.lowercased()) {
                items[id] = HorizontalSchematicClipboardEditor.transformed(item, table: table, by: transform)
            }
            sheet[table] = items
        }
        sheets[sheetKey] = sheet
        schematic["sheets"] = sheets
        try HorizontalSchematicClipboardEditor.write(schematic, path: schematicPath, archive: &result)
        return result
    }
}

/// The workspace owns the eventual archive/Undo; the canvas owns placement.
struct HorizontalSchematicPastePlacement {
    var paste: HorizontalSchematicPaste
    var commit: (HorizontalPlacementTransform) -> Void
}
