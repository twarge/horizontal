import Foundation

/// A key/value table for the data kinds (units, entities, parts): header
/// fields plus tabular sections such as a unit's pins or an entity's gates.
struct HorizontalPoolItemPreviewTable: Sendable {
    struct Field: Identifiable, Sendable {
        var label: String
        var value: String

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

/// What the library browser previews for one pool item.
enum HorizontalPoolItemPreview {
    /// Symbols and frames: schematic-style line art.
    case symbol(HorizontalSymbolPreviewArtwork)
    /// Packages, padstacks and decals: board-style layered geometry. The
    /// hidden layers are drawn nowhere (mask and paste clutter a footprint).
    case board(HorizontalPackageGeometry, hiddenLayers: Set<Int>)
    /// Units and entities.
    case table(HorizontalPoolItemPreviewTable)
    /// Parts: attributes plus the part's package, when it resolves.
    case part(HorizontalPoolItemPreviewTable, HorizontalPackageGeometry?)
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
            return .part(partTable(json, index: index), partPackageGeometry(json, index: index))
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

    private static func partPackageGeometry(
        _ partJSON: JSONDictionary,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPackageGeometry? {
        guard let packageID = partReference("package", in: partJSON, index: index),
              let packageItem = index.item(.package, uuid: packageID),
              let packageJSON = try? JSONHelper.loadDictionary(from: packageItem.url) else {
            return nil
        }
        return packageGeometry(packageJSON, packageItem: packageItem, index: index)
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

    private static func partTable(
        _ json: JSONDictionary,
        index: HorizontalPoolLibraryIndex
    ) -> HorizontalPoolItemPreviewTable {
        var table = HorizontalPoolItemPreviewTable()
        let entityID = partReference("entity", in: json, index: index)
        let packageID = partReference("package", in: json, index: index)
        let baseID = json.string("base")
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
            field("Entity", entityID.map { index.name(.entity, uuid: $0) ?? shortID($0) }),
            field("Package", packageID.map { index.name(.package, uuid: $0) ?? shortID($0) }),
            field("Base part", baseID.map { index.name(.part, uuid: $0) ?? shortID($0) }),
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
