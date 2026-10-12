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
    /// The package's uuid, a derived part's taken from its base.
    var packageID: String? = nil
    /// The refdes prefix the part sets in place of its entity's
    /// (`override_prefix`, a derived part's possibly inherited), else nil.
    /// `refdesPrefix` already gives it when set.
    var prefixOverride: String? = nil
    /// The part's exclude_bom and exclude_pnp flags, through its base.
    var excludeFromBOM = false
    var excludeFromPnP = false

    var tagList: String {
        tags.joined(separator: ", ")
    }

    /// How search_pool's `package` names this part's package: by its name,
    /// or by its uuid when it has none (`packageName` then shows the uuid's
    /// first eight characters, which name nothing).
    var searchPackage: String? {
        guard let packageID else { return packageName.isEmpty ? nil : packageName }
        return packageName.isEmpty || packageName == String(packageID.prefix(8)) ? packageID : packageName
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
        var part: HorizontalResolvedPart
        var refdesPrefix: String
        var packageName: String?
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
        let part = details.part

        return HorizontalPoolPart(
            id: partID,
            mpn: nonEmpty(part.mpn) ?? String(partID.prefix(8)),
            manufacturer: nonEmpty(part.manufacturer) ?? "",
            partDescription: nonEmpty(part.description) ?? "",
            packageName: nonEmpty(details.packageName) ?? part.packageID.map { String($0.prefix(8)) } ?? "",
            tags: part.tags,
            value: nonEmpty(part.displayValue) ?? "",
            entityID: part.entityID,
            refdesPrefix: details.refdesPrefix,
            gates: details.gates,
            packageID: part.packageID,
            prefixOverride: part.prefix.flatMap(nonEmpty),
            excludeFromBOM: part.excludeFromBOM,
            excludeFromPnP: part.excludeFromPnP
        )
    }

    /// The part resolved through its base as Horizon resolves it
    /// (`HorizontalPartRecord.resolved`), with what the entity and package
    /// files add: the prefix, the gates and the package name.
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

        let record = HorizontalPartRecord(json: json)
        let baseDetails = record.baseID.flatMap {
            details(for: $0, visited: visited.union([partID]))
        }
        let part = record.resolved(base: baseDetails?.part)
        let entityInfo = part.entityID.flatMap(loadEntityInfo)
        let resolved = PartDetails(
            part: part,
            refdesPrefix: part.prefix.flatMap(nonEmpty) ?? entityInfo?.prefix ?? baseDetails?.refdesPrefix ?? "U",
            packageName: part.packageID.flatMap(packageName(for:)) ?? baseDetails?.packageName,
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
