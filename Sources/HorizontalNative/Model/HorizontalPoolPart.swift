import Foundation

struct HorizontalPoolPartGate: Identifiable, Hashable {
    var id: String
    var suffix: String
    var unitID: String
    var symbolID: String?
}

struct HorizontalPartPlacementRequest: Identifiable, Equatable {
    var id = UUID()
    var part: HorizontalPoolPart
}

struct HorizontalPoolPart: Identifiable, Hashable {
    var id: String
    var mpn: String
    var manufacturer: String
    var partDescription: String
    var packageName: String
    var tags: [String]
    var value: String
    var entityID: String?
    var refdesPrefix: String
    var gates: [HorizontalPoolPartGate]

    var tagList: String {
        tags.joined(separator: ", ")
    }

    /// One part from the project pool's cache, resolved the way `loadAll`
    /// resolves them (entity, gates, symbols, package name).
    static func loadCached(id: String, from poolURL: URL) -> HorizontalPoolPart? {
        let normalized = id.lowercased()
        let url = poolURL
            .appendingPathComponent("parts")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(normalized).json")
        guard let json = try? JSONHelper.loadDictionary(from: url) else {
            return nil
        }
        return PoolPartLoader(poolURL: poolURL).part(id: normalized, json: json)
    }

    static func loadAll(from poolURL: URL) -> [HorizontalPoolPart] {
        BoardLoadTimer.measure("HorizontalPoolPart.loadAll") {
            let partsURL = poolURL
                .appendingPathComponent("parts")
                .appendingPathComponent("cache")

            guard let partURLs = try? FileManager.default.contentsOfDirectory(
                at: partsURL,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }

            let jsonByID = BoardLoadTimer.measure("  parse pool JSON files") { () -> [(String, JSONDictionary)] in
                let result = partURLs
                    .filter { $0.pathExtension.lowercased() == "json" }
                    .compactMap { url -> (String, JSONDictionary)? in
                        guard let json = try? JSONHelper.loadDictionary(from: url) else {
                            return nil
                        }
                        let id = (json.string("uuid") ?? url.deletingPathExtension().lastPathComponent).lowercased()
                        return (id, json)
                    }
                return result
            }
            let basePartIDs = Set(jsonByID.compactMap { _, json in
                json.string("base")?.lowercased()
            })

            let loader = PoolPartLoader(poolURL: poolURL, preloadedParts: Dictionary(uniqueKeysWithValues: jsonByID))
            return BoardLoadTimer.measure("  resolve pool parts (gates/symbols/packages)") {
                jsonByID
                    .filter { id, _ in !basePartIDs.contains(id) }
                    .compactMap { id, json in loader.part(id: id, json: json) }
                    .sorted { lhs, rhs in
                        let mpnOrder = lhs.mpn.localizedStandardCompare(rhs.mpn)
                        if mpnOrder != .orderedSame {
                            return mpnOrder == .orderedAscending
                        }
                        return lhs.manufacturer.localizedStandardCompare(rhs.manufacturer) == .orderedAscending
                    }
            }
        }
    }
}

private final class PoolPartLoader {
    private struct PartDetails {
        var value: String?
        var mpn: String?
        var manufacturer: String?
        var description: String?
        var entityID: String?
        var refdesPrefix: String
        var packageID: String?
        var packageName: String?
        var tags: [String]
        var gates: [HorizontalPoolPartGate]
    }

    private let poolURL: URL
    private var partCache = [String: JSONDictionary]()
    private var detailsCache = [String: PartDetails]()
    private var packageNameCache = [String: String?]()
    private lazy var symbolsByUnitID = loadSymbolsByUnitID()

    init(poolURL: URL, preloadedParts: [String: JSONDictionary] = [:]) {
        self.poolURL = poolURL
        self.partCache = preloadedParts
    }

    func part(id partID: String, json: JSONDictionary) -> HorizontalPoolPart? {
        let partID = normalizedID(partID)
        partCache[partID] = json
        guard let details = details(for: partID, fallbackJSON: json) else {
            return nil
        }

        return HorizontalPoolPart(
            id: partID,
            mpn: nonEmpty(details.mpn) ?? String(partID.prefix(8)),
            manufacturer: nonEmpty(details.manufacturer) ?? "",
            partDescription: nonEmpty(details.description) ?? "",
            packageName: nonEmpty(details.packageName) ?? details.packageID.map { String($0.prefix(8)) } ?? "",
            tags: details.tags,
            value: nonEmpty(details.value) ?? "",
            entityID: details.entityID,
            refdesPrefix: details.refdesPrefix,
            gates: details.gates
        )
    }

    private func details(
        for partID: String,
        fallbackJSON: JSONDictionary? = nil,
        visited: Set<String> = []
    ) -> PartDetails? {
        let partID = normalizedID(partID)
        if let cached = detailsCache[partID] {
            return cached
        }
        guard !visited.contains(partID) else {
            return nil
        }

        let json: JSONDictionary
        if let fallbackJSON {
            json = fallbackJSON
        } else if let cached = partCache[partID] {
            json = cached
        } else if let loaded = loadPart(partID) {
            json = loaded
            partCache[partID] = loaded
        } else {
            return nil
        }

        let baseID = json.string("base").map(normalizedID)
        let baseDetails = baseID.flatMap {
            details(for: $0, visited: visited.union([partID]))
        }
        let entityID = json.string("entity").map(normalizedID) ?? baseDetails?.entityID
        let packageID = json.string("package").map(normalizedID) ?? baseDetails?.packageID
        let entityInfo = entityID.flatMap(loadEntityInfo)
        let mpn = poolAttributeString(json["MPN"], inherited: baseDetails?.mpn)
        let valueAttribute = poolAttributeString(json["value"], inherited: baseDetails?.value)
        let resolved = PartDetails(
            value: resolvedPartValue(valueAttribute, inherited: baseID != nil, mpn: mpn, baseValue: baseDetails?.value),
            mpn: mpn,
            manufacturer: poolAttributeString(json["manufacturer"], inherited: baseDetails?.manufacturer),
            description: poolAttributeString(json["description"], inherited: baseDetails?.description),
            entityID: entityID,
            refdesPrefix: entityInfo?.prefix ?? baseDetails?.refdesPrefix ?? "U",
            packageID: packageID,
            packageName: packageID.flatMap(packageName(for:)) ?? baseDetails?.packageName,
            tags: resolvedTags(from: json, baseTags: baseDetails?.tags ?? []),
            gates: entityInfo?.gates ?? baseDetails?.gates ?? []
        )
        detailsCache[partID] = resolved
        return resolved
    }

    private func loadPart(_ partID: String) -> JSONDictionary? {
        let partURL = poolURL
            .appendingPathComponent("parts")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(normalizedID(partID)).json")
        return try? JSONHelper.loadDictionary(from: partURL)
    }

    private func packageName(for packageID: String) -> String? {
        let packageID = normalizedID(packageID)
        if let cached = packageNameCache[packageID] {
            return cached
        }

        let packageURL = poolURL
            .appendingPathComponent("packages")
            .appendingPathComponent("cache")
            .appendingPathComponent(packageID)
            .appendingPathComponent("package.json")
        let name = (try? JSONHelper.loadDictionary(from: packageURL))?
            .string("name")
            .flatMap(nonEmpty)
        packageNameCache[packageID] = name
        return name
    }

    private func loadEntityInfo(_ entityID: String) -> (prefix: String, gates: [HorizontalPoolPartGate])? {
        let entityID = normalizedID(entityID)
        let entityURL = poolURL
            .appendingPathComponent("entities")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(entityID).json")
        guard let json = try? JSONHelper.loadDictionary(from: entityURL) else {
            return nil
        }

        let gates = json.dictionaryMap("gates")
            .compactMap { id, gate -> HorizontalPoolPartGate? in
                guard let unitID = gate.string("unit").map(normalizedID) else {
                    return nil
                }
                return HorizontalPoolPartGate(
                    id: normalizedID(id),
                    suffix: gate.string("suffix") ?? "",
                    unitID: unitID,
                    symbolID: symbolsByUnitID[unitID]?.first
                )
            }
            .sorted {
                $0.suffix.localizedStandardCompare($1.suffix) == .orderedAscending
            }
        return (json.string("prefix").flatMap(nonEmpty) ?? "U", gates)
    }

    private func loadSymbolsByUnitID() -> [String: [String]] {
        let symbolsURL = poolURL
            .appendingPathComponent("symbols")
            .appendingPathComponent("cache")
        guard let symbolURLs = try? FileManager.default.contentsOfDirectory(
            at: symbolsURL,
            includingPropertiesForKeys: nil
        ) else {
            return [:]
        }

        var result = [String: [String]]()
        for url in symbolURLs where url.pathExtension.lowercased() == "json" {
            guard let json = try? JSONHelper.loadDictionary(from: url),
                  let unitID = json.string("unit").map(normalizedID) else {
                continue
            }
            let symbolID = normalizedID(json.string("uuid") ?? url.deletingPathExtension().lastPathComponent)
            result[unitID, default: []].append(symbolID)
        }

        for unitID in result.keys {
            result[unitID]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return result
    }

    private func resolvedTags(from json: JSONDictionary, baseTags: [String]) -> [String] {
        let tags = stringArray(json["tags"])
        if json.bool("inherit_tags") == true {
            return unique(baseTags + tags)
        }
        return unique(tags)
    }

    private func poolAttributeString(_ value: Any?, inherited: String? = nil) -> String? {
        if let value = value as? [Any], value.count >= 2 {
            if value[0] as? Bool == true {
                return inherited
            }
            return nonEmpty(stringValue(value[1]))
        }
        return nonEmpty(value.flatMap(stringValue))
    }

    private func resolvedPartValue(_ value: String?, inherited: Bool, mpn: String?, baseValue: String?) -> String? {
        if inherited,
           let value = nonEmpty(value),
           let baseValue = nonEmpty(baseValue),
           value == baseValue,
           let mpn = nonEmpty(mpn),
           mpn != baseValue {
            return mpn
        }

        return nonEmpty(value) ?? nonEmpty(mpn)
    }

    private func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else {
            return []
        }
        return values.compactMap { nonEmpty(stringValue($0)) }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func stringValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedID(_ id: String) -> String {
        id.lowercased()
    }
}
