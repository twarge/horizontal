import Foundation

/// An item one pool item leads to: a part's base part, entity, units,
/// symbols, package and the package's padstacks; an entity's units; a
/// symbol's unit; a package's padstacks. The preview lists them as links and
/// the browser's context menu as "Show …" entries, both taking the browser to
/// the item, as Horizon's part preview has a go-to button beside its entity,
/// gate, symbol and package.
struct HorizontalPoolItemLink: Identifiable, Hashable, Sendable {
    /// What the item is to the one that names it, in the order the preview
    /// lists them: a part's own chain first, then what it draws with, then
    /// what it is built on.
    enum Role: String, CaseIterable, Sendable {
        case basePart
        case entity
        case unit
        case symbol
        case package
        case padstack

        var category: HorizontalPoolItemCategory {
            switch self {
            case .basePart: .part
            case .entity: .entity
            case .unit: .unit
            case .symbol: .symbol
            case .package: .package
            case .padstack: .padstack
            }
        }

        /// The preview's row label, plural for several.
        func label(count: Int) -> String {
            switch self {
            case .basePart: "Base part"
            case .entity: "Entity"
            case .unit: count == 1 ? "Unit" : "Units"
            case .symbol: count == 1 ? "Symbol" : "Symbols"
            case .package: "Package"
            case .padstack: count == 1 ? "Padstack" : "Padstacks"
            }
        }

        /// The kind as a menu names it, "Show Base Part “…”".
        var menuTitle: String {
            switch self {
            case .basePart: "Base Part"
            case .entity: "Entity"
            case .unit: "Unit"
            case .symbol: "Symbol"
            case .package: "Package"
            case .padstack: "Padstack"
            }
        }
    }

    var role: Role
    /// Lowercased, as the browser's index keys it.
    var uuid: String
    /// The item's name, or the start of its uuid where no browsed pool has it.
    var name: String
    /// What tells it apart here: the gates a unit is used for, the unit a
    /// symbol draws when the entity has several.
    var note: String = ""
    /// Whether a browsed pool has it, so that the browser can go to it.
    var isResolved: Bool

    var category: HorizontalPoolItemCategory { role.category }
    var id: String { role.rawValue + "|" + uuid }
}

/// A key/value table for the data kinds (units, entities, parts): header
/// fields plus tabular sections such as a unit's pins or an entity's gates.
struct HorizontalPoolItemPreviewTable: Sendable {
    struct Field: Identifiable, Sendable {
        var label: String
        var value: String
        /// A field naming other pool items: their links, which the preview
        /// shows instead of `value` (their names, for reading and copying).
        var links: [HorizontalPoolItemLink] = []

        var id: String { label }
    }

    struct Section: Identifiable, Sendable {
        var title: String
        var columns: [String]
        var rows: [[String]]

        var id: String { title }
    }

    var fields: [Field] = []
    var sections: [Section] = []
}

/// A part as the browser previews it, Horizon's part preview: its data and
/// what it leads to, its entity's gates with the symbols each can be drawn
/// with, and its package.
struct HorizontalPoolPartPreview {
    struct Symbol: Identifiable {
        /// The symbol's uuid, lowercased.
        var id: String
        var name: String
        /// Nil past `HorizontalPoolPreviewBuilder.maximumPartSymbols`, or
        /// when the symbol's file can't be read.
        var artwork: HorizontalSymbolPreviewArtwork?
    }

    struct Gate: Identifiable {
        /// The gate's uuid.
        var id: String
        var name: String
        var suffix: String
        var unitID: String
        var unitName: String
        /// The unit's symbols in the browsed pools, sorted by name.
        var symbols: [Symbol]

        /// Horizon's gate menu entry: "A: Opamp", or the unit's name alone
        /// for a gate without a suffix.
        var title: String {
            suffix.isEmpty ? unitName : "\(suffix): \(unitName)"
        }
    }

    var table: HorizontalPoolItemPreviewTable
    /// Sorted naturally by suffix, as Horizon's gate menu has them.
    var gates: [Gate]
    var package: HorizontalPackageGeometry?
}

/// What the library browser previews for one pool item.
enum HorizontalPoolItemPreview {
    /// Symbols and frames: schematic-style line art.
    case symbol(HorizontalSymbolPreviewArtwork)
    /// Packages, padstacks and decals: board-style layered geometry. The
    /// hidden layers are drawn nowhere (mask and paste clutter a footprint).
    case board(HorizontalPackageGeometry, hiddenLayers: Set<Int>)
    /// Units and entities.
    case table(HorizontalPoolItemPreviewTable)
    /// Parts: data and links, the entity's symbols and the package, each
    /// where it resolves.
    case part(HorizontalPoolPartPreview)
    case unavailable(String)
}

/// Builds a pool item's preview from its JSON and the browser's
/// cross-reference index. Pure and synchronous, so the view runs it off the
/// main thread.
enum HorizontalPoolPreviewBuilder {
    /// Mask and paste openings clutter a footprint; the padstack preview
    /// shows them.
    static let packageHiddenLayers: Set<Int> = [
        HorizontalBoardLayers.topMask,
        HorizontalBoardLayers.bottomMask,
        HorizontalBoardLayers.topPaste,
        HorizontalBoardLayers.bottomPaste,
    ]

    static func preview(
        for item: HorizontalPoolLibraryItem,
        index: HorizontalPoolLibraryIndex,
        symbolTransform: HorizontalPlacementTransform = .identity
    ) -> HorizontalPoolItemPreview {
        guard let json = try? JSONHelper.loadDictionary(from: item.url) else {
            return .unavailable("Could not read \(item.url.lastPathComponent).")
        }

        switch item.category {
        case .symbol:
            let unitJSON = json.string("unit").flatMap { index.json(.unit, uuid: $0) }
            return .symbol(
                HorizontalSchematic.symbolPreviewArtwork(
                    symbolJSON: json,
                    unitJSON: unitJSON,
                    poolURL: item.poolURL,
                    transform: symbolTransform
                )
            )
        case .frame:
            return .symbol(HorizontalSchematic.framePreviewArtwork(frameJSON: json))
        case .package:
            return .board(packageGeometry(json, packageItem: item, index: index), hiddenLayers: packageHiddenLayers)
        case .decal:
            let geometry = HorizontalBoard.packagePreviewGeometry(
                packageJSON: json,
                packageID: item.uuid,
                poolURL: item.poolURL
            ) { _ in nil }
            return .board(geometry, hiddenLayers: [])
        case .padstack:
            return .board(
                HorizontalBoard.padstackPreviewGeometry(padstackJSON: json, poolURL: item.poolURL),
                hiddenLayers: []
            )
        case .unit:
            return .table(unitTable(json))
        case .entity:
            return .table(entityTable(json, index: index))
        case .part:
            return .part(partPreview(json, index: index))
        }
    }

    // MARK: - Packages

    private static func packageGeometry(
        _ packageJSON: JSONDictionary,
        packageItem: HorizontalPoolLibraryItem,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPackageGeometry {
        HorizontalBoard.packagePreviewGeometry(
            packageJSON: packageJSON,
            packageID: packageItem.uuid,
            poolURL: packageItem.poolURL
        ) { padstackID in
            resolvePadstack(padstackID, poolURL: packageItem.poolURL, index: index)
        }
    }

    /// A pad's padstack: whichever browsed pool carries it (the scan indexes
    /// package-local padstacks too), else the padstack catalog for a project
    /// pool's cache copies.
    static func resolvePadstack(
        _ padstackID: String,
        poolURL: URL,
        index: HorizontalPoolLibraryIndex
    ) -> JSONDictionary? {
        if let json = index.json(.padstack, uuid: padstackID) {
            return json
        }
        return HorizontalPoolPadstacks.padstack(id: padstackID, poolURL: poolURL)
    }

    // MARK: - Parts

    /// The most symbols a part preview draws. An entity with more (a large
    /// FPGA's banks, each its own unit with a symbol or two) still lists
    /// them; the ones past this say they aren't drawn.
    static let maximumPartSymbols = 48

    private static func partPreview(_ json: JSONDictionary, index: HorizontalPoolLibraryIndex) -> HorizontalPoolPartPreview {
        let entityID = partReference("entity", in: json, index: index)
        let gates = entityID.flatMap { index.json(.entity, uuid: $0) }.map(entityGates) ?? []
        let packageItem = partReference("package", in: json, index: index).flatMap { index.item(.package, uuid: $0) }
        let packageJSON = packageItem.flatMap { try? JSONHelper.loadDictionary(from: $0.url) }
        var table = partTable(json, index: index)
        table.fields += linkFields(partLinks(json, gates: gates, packageJSON: packageJSON, index: index))
        let geometry = packageItem.flatMap { item in
            packageJSON.map { packageGeometry($0, packageItem: item, index: index) }
        }
        return HorizontalPoolPartPreview(table: table, gates: gateSymbols(gates, index: index), package: geometry)
    }

    /// One of an entity's gates, as a part's preview reads it.
    struct EntityGate: Equatable {
        var id: String
        var name: String
        var suffix: String
        /// Lowercased.
        var unitID: String
    }

    /// An entity's gates in Horizon's gate-menu order: naturally by suffix
    /// (A, B, … P for the power gate), then by name.
    static func entityGates(_ entityJSON: JSONDictionary) -> [EntityGate] {
        entityJSON.dictionaryMap("gates")
            .map { id, gate in
                EntityGate(
                    id: id,
                    name: gate.string("name") ?? "",
                    suffix: gate.string("suffix") ?? "",
                    unitID: gate.string("unit")?.lowercased() ?? ""
                )
            }
            .sorted { lhs, rhs in
                let bySuffix = lhs.suffix.localizedStandardCompare(rhs.suffix)
                if bySuffix != .orderedSame {
                    return bySuffix == .orderedAscending
                }
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
    }

    /// Every symbol of every gate's unit, drawn once however many gates share
    /// it, up to `maximumPartSymbols` drawings.
    private static func gateSymbols(_ gates: [EntityGate], index: HorizontalPoolLibraryIndex) -> [HorizontalPoolPartPreview.Gate] {
        var drawn = [String: HorizontalSymbolPreviewArtwork?]()
        var unitJSONs = [String: JSONDictionary?]()
        return gates.map { gate in
            if unitJSONs[gate.unitID] == nil {
                unitJSONs[gate.unitID] = .some(index.json(.unit, uuid: gate.unitID))
            }
            let unitJSON = unitJSONs[gate.unitID] ?? nil
            let symbols = index.symbols(forUnit: gate.unitID).map { symbolItem -> HorizontalPoolPartPreview.Symbol in
                if drawn[symbolItem.uuid] == nil {
                    let artwork = drawn.count < maximumPartSymbols
                        ? (try? JSONHelper.loadDictionary(from: symbolItem.url)).map {
                            HorizontalSchematic.symbolPreviewArtwork(symbolJSON: $0, unitJSON: unitJSON, poolURL: symbolItem.poolURL)
                        }
                        : nil
                    drawn[symbolItem.uuid] = .some(artwork)
                }
                return HorizontalPoolPartPreview.Symbol(id: symbolItem.uuid, name: symbolItem.name, artwork: drawn[symbolItem.uuid] ?? nil)
            }
            return HorizontalPoolPartPreview.Gate(
                id: gate.id,
                name: gate.name,
                suffix: gate.suffix,
                unitID: gate.unitID,
                unitName: index.name(.unit, uuid: gate.unitID) ?? shortID(gate.unitID),
                symbols: symbols
            )
        }
    }

    // MARK: - Links

    /// What an item leads to, for the context menu's "Show …" entries and
    /// the part preview's links: a part's base part, entity, units, symbols,
    /// package and padstacks (an inherited entity or package through its
    /// base); an entity's units and their symbols; a symbol's unit; a
    /// package's padstacks.
    static func links(
        for item: HorizontalPoolLibraryItem,
        json: JSONDictionary,
        index: HorizontalPoolLibraryIndex
    ) -> [HorizontalPoolItemLink] {
        switch item.category {
        case .part:
            let gates = partReference("entity", in: json, index: index)
                .flatMap { index.json(.entity, uuid: $0) }
                .map(entityGates) ?? []
            let packageJSON = partReference("package", in: json, index: index)
                .flatMap { index.json(.package, uuid: $0) }
            return partLinks(json, gates: gates, packageJSON: packageJSON, index: index)
        case .entity:
            let gates = entityGates(json)
            return unitLinks(gates, index: index) + symbolLinks(gates, index: index)
        case .symbol:
            return json.string("unit").map { [link(.unit, $0, index: index)] } ?? []
        case .package:
            return padstackLinks(json, index: index)
        case .unit, .padstack, .frame, .decal:
            return []
        }
    }

    private static func partLinks(
        _ json: JSONDictionary,
        gates: [EntityGate],
        packageJSON: JSONDictionary?,
        index: HorizontalPoolLibraryIndex
    ) -> [HorizontalPoolItemLink] {
        var links = [HorizontalPoolItemLink]()
        if let baseID = json.string("base"), !baseID.isEmpty {
            links.append(link(.basePart, baseID, index: index))
        }
        if let entityID = partReference("entity", in: json, index: index) {
            links.append(link(.entity, entityID, index: index))
        }
        links += unitLinks(gates, index: index)
        links += symbolLinks(gates, index: index)
        if let packageID = partReference("package", in: json, index: index) {
            links.append(link(.package, packageID, index: index))
        }
        if let packageJSON {
            links += padstackLinks(packageJSON, index: index)
        }
        return links
    }

    /// Each unit once, in gate order; with several gates, the gates it is
    /// used for (by suffix, else name): "gates A, B, C".
    private static func unitLinks(_ gates: [EntityGate], index: HorizontalPoolLibraryIndex) -> [HorizontalPoolItemLink] {
        var order = [String]()
        var gateLabels = [String: [String]]()
        for gate in gates where !gate.unitID.isEmpty {
            if gateLabels[gate.unitID] == nil {
                order.append(gate.unitID)
            }
            gateLabels[gate.unitID, default: []].append(gate.suffix.isEmpty ? gate.name : gate.suffix)
        }
        return order.map { unitID in
            var unit = link(.unit, unitID, index: index)
            let labels = (gateLabels[unitID] ?? []).filter { !$0.isEmpty }
            if gates.count > 1, !labels.isEmpty {
                unit.note = (labels.count == 1 ? "gate " : "gates ") + labels.joined(separator: ", ")
            }
            return unit
        }
    }

    /// The units' symbols, unit by unit; with several units, each names the
    /// unit it draws: "for Opamp".
    private static func symbolLinks(_ gates: [EntityGate], index: HorizontalPoolLibraryIndex) -> [HorizontalPoolItemLink] {
        var units = [String]()
        for gate in gates where !gate.unitID.isEmpty && !units.contains(gate.unitID) {
            units.append(gate.unitID)
        }
        return units.flatMap { unitID in
            index.symbols(forUnit: unitID).map { symbol in
                HorizontalPoolItemLink(
                    role: .symbol,
                    uuid: symbol.uuid,
                    name: symbol.name,
                    note: units.count > 1 ? "for " + (index.name(.unit, uuid: unitID) ?? shortID(unitID)) : "",
                    isResolved: true
                )
            }
        }
    }

    /// A package's padstacks, each once, by name.
    private static func padstackLinks(_ packageJSON: JSONDictionary, index: HorizontalPoolLibraryIndex) -> [HorizontalPoolItemLink] {
        var seen = Set<String>()
        return packageJSON.dictionaryMap("pads").values
            .compactMap { $0.string("padstack")?.lowercased() }
            .filter { seen.insert($0).inserted }
            .map { link(.padstack, $0, index: index) }
            .sorted { lhs, rhs in
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.uuid < rhs.uuid : byName == .orderedAscending
            }
    }

    private static func link(
        _ role: HorizontalPoolItemLink.Role,
        _ uuid: String,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPoolItemLink {
        let uuid = uuid.lowercased()
        let item = index.item(role.category, uuid: uuid)
        return HorizontalPoolItemLink(role: role, uuid: uuid, name: item?.name ?? shortID(uuid), isResolved: item != nil)
    }

    /// One field per kind, in `Role` order, its value the names.
    private static func linkFields(_ links: [HorizontalPoolItemLink]) -> [HorizontalPoolItemPreviewTable.Field] {
        HorizontalPoolItemLink.Role.allCases.compactMap { role in
            let ofRole = links.filter { $0.role == role }
            guard !ofRole.isEmpty else {
                return nil
            }
            return HorizontalPoolItemPreviewTable.Field(
                label: role.label(count: ofRole.count),
                value: ofRole.map(\.name).joined(separator: ", "),
                links: ofRole
            )
        }
    }

    // MARK: - Tables

    private static func unitTable(_ json: JSONDictionary) -> HorizontalPoolItemPreviewTable {
        var table = HorizontalPoolItemPreviewTable()
        table.fields = [
            field("Name", json.string("name")),
            field("Manufacturer", json.string("manufacturer")),
        ].compactMap { $0 }

        let rows = json.dictionaryMap("pins").values
            .map { pin -> [String] in
                [
                    pin.string("primary_name") ?? "",
                    displayName(for: pin.string("direction") ?? ""),
                    (pin["names"] as? [String])?.joined(separator: ", ") ?? "",
                    swapGroupText(pin.int("swap_group")),
                ]
            }
            .sorted { $0[0].localizedStandardCompare($1[0]) == .orderedAscending }
        table.sections = [
            HorizontalPoolItemPreviewTable.Section(
                title: "Pins (\(rows.count))",
                columns: ["Name", "Direction", "Alternate names", "Swap group"],
                rows: rows
            )
        ]
        return table
    }

    private static func entityTable(
        _ json: JSONDictionary,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPoolItemPreviewTable {
        var table = HorizontalPoolItemPreviewTable()
        table.fields = [
            field("Name", json.string("name")),
            field("Prefix", json.string("prefix")),
            field("Manufacturer", json.string("manufacturer")),
            field("Tags", (json["tags"] as? [String])?.joined(separator: ", ")),
        ].compactMap { $0 }

        let rows = json.dictionaryMap("gates").values
            .map { gate -> [String] in
                let unitID = gate.string("unit") ?? ""
                return [
                    gate.string("name") ?? "",
                    gate.string("suffix") ?? "",
                    index.name(.unit, uuid: unitID) ?? shortID(unitID),
                    swapGroupText(gate.int("swap_group")),
                ]
            }
            .sorted { lhs, rhs in
                let suffixOrder = lhs[1].localizedStandardCompare(rhs[1])
                if suffixOrder != .orderedSame {
                    return suffixOrder == .orderedAscending
                }
                return lhs[0].localizedStandardCompare(rhs[0]) == .orderedAscending
            }
        table.sections = [
            HorizontalPoolItemPreviewTable.Section(
                title: "Gates (\(rows.count))",
                columns: ["Name", "Suffix", "Unit", "Swap group"],
                rows: rows
            )
        ]
        return table
    }

    /// The part's own data; `linkFields` follows it with what it leads to.
    private static func partTable(
        _ json: JSONDictionary,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPoolItemPreviewTable {
        var table = HorizontalPoolItemPreviewTable()
        let orderableMPNs = (json["orderable_MPNs"] as? [String: String])?.values
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: ", ")
        table.fields = [
            field("MPN", partAttribute("MPN", in: json, index: index)),
            field("Value", partAttribute("value", in: json, index: index)),
            field("Manufacturer", partAttribute("manufacturer", in: json, index: index)),
            field("Description", partAttribute("description", in: json, index: index)),
            field("Datasheet", partAttribute("datasheet", in: json, index: index)),
            field("Orderable MPNs", orderableMPNs),
            field("Tags", partTags(json, index: index).joined(separator: ", ")),
        ].compactMap { $0 }
        return table
    }

    /// Horizon part attributes serialize as `[inherited, value]` pairs; an
    /// inherited one reads through the `base` part chain.
    static func partAttribute(
        _ key: String,
        in json: JSONDictionary,
        index: HorizontalPoolLibraryIndex,
        depth: Int = 0
    ) -> String? {
        if let pair = json[key] as? [Any], pair.count == 2 {
            let inherited = (pair[0] as? Bool) ?? false
            if !inherited {
                return pair[1] as? String
            }
        } else if let value = json[key] as? String {
            return value
        }
        guard depth < 8,
              let baseID = json.string("base"),
              let baseJSON = index.json(.part, uuid: baseID) else {
            return nil
        }
        return partAttribute(key, in: baseJSON, index: index, depth: depth + 1)
    }

    /// A part's entity or package: its own when it names one, else its base's.
    static func partReference(
        _ key: String,
        in json: JSONDictionary,
        index: HorizontalPoolLibraryIndex,
        depth: Int = 0
    ) -> String? {
        if let value = json.string(key), !value.isEmpty {
            return value
        }
        guard depth < 8,
              let baseID = json.string("base"),
              let baseJSON = index.json(.part, uuid: baseID) else {
            return nil
        }
        return partReference(key, in: baseJSON, index: index, depth: depth + 1)
    }

    private static func partTags(
        _ json: JSONDictionary,
        index: HorizontalPoolLibraryIndex,
        depth: Int = 0
    ) -> [String] {
        var tags = (json["tags"] as? [String]) ?? []
        if json.bool("inherit_tags") == true,
           depth < 8,
           let baseID = json.string("base"),
           let baseJSON = index.json(.part, uuid: baseID) {
            for tag in partTags(baseJSON, index: index, depth: depth + 1) where !tags.contains(tag) {
                tags.append(tag)
            }
        }
        return tags
    }

    // MARK: - Helpers

    private static func field(_ label: String, _ value: String?) -> HorizontalPoolItemPreviewTable.Field? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return HorizontalPoolItemPreviewTable.Field(label: label, value: value)
    }

    /// `power_input` reads as "Power input".
    private static func displayName(for rawValue: String) -> String {
        let words = rawValue.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func swapGroupText(_ group: Int?) -> String {
        guard let group, group != 0 else {
            return ""
        }
        return String(group)
    }

    private static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }
}
