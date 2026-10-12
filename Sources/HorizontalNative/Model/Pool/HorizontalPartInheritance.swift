import Foundation

/// What a pool part's file says, before its base is consulted: each
/// attribute with its inherited flag, the tags, flags and prefix override.
/// Read once per file, so a pool scan can keep it and resolve a part through
/// whichever pool holds its base.
struct HorizontalPartRecord: Hashable, Sendable {
    var attributes: [HorizontalPartAttributeKind: HorizontalPartAttribute] = [:]
    var baseID: String?
    var entityID: String?
    var packageID: String?
    var tags: [String] = []
    var inheritTags = false
    var flags: [HorizontalPartFlag: HorizontalPartFlagState] = [:]
    var overridePrefix: HorizontalPartOverridePrefix = .no
    var prefix = ""

    init(json: JSONDictionary) {
        for kind in HorizontalPartAttributeKind.allCases {
            if let pair = json[kind.rawValue] as? [Any], pair.count == 2, let value = pair[1] as? String {
                attributes[kind] = HorizontalPartAttribute(inherited: (pair[0] as? NSNumber)?.boolValue ?? false, value: value)
            } else if let value = json[kind.rawValue] as? String {
                attributes[kind] = HorizontalPartAttribute(value: value)
            }
        }
        baseID = json.string("base")?.lowercased()
        entityID = json.string("entity")?.lowercased()
        packageID = json.string("package")?.lowercased()
        tags = (json["tags"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        inheritTags = json.bool("inherit_tags") ?? false
        for (key, state) in json["flags"] as? [String: Any] ?? [:] {
            guard let flag = HorizontalPartFlag(rawValue: key),
                  let state = (state as? String).flatMap(HorizontalPartFlagState.init(rawValue:)) else { continue }
            flags[flag] = state
        }
        overridePrefix = json.string("override_prefix").flatMap(HorizontalPartOverridePrefix.init(rawValue:)) ?? .no
        prefix = json.string("prefix") ?? ""
    }

    /// The part as Horizon resolves it (`pool/part.cpp`), given its base
    /// already resolved, or nil when it has none or the base can't be read.
    /// - An attribute flagged inherited is the base's, whatever the file
    ///   stores: "create part from part" stores a copy of the base's value
    ///   then, which goes stale when the base is edited. With no base the
    ///   stored value stands, as Horizon's `get_attribute` has it.
    /// - Entity and package are always the base's.
    /// - Tags are the part's own, plus the base's when `inherit_tags`.
    /// - A flag or prefix set to inherit is the base's, else clear / the
    ///   entity's.
    /// - Parametric data and orderable MPNs are never inherited, so callers
    ///   read them from the part's own file.
    func resolved(base: HorizontalResolvedPart?) -> HorizontalResolvedPart {
        var part = HorizontalResolvedPart()
        func attribute(_ kind: HorizontalPartAttributeKind) -> String {
            guard let stored = attributes[kind] else { return "" }
            if stored.inherited, let base { return base.attribute(kind) }
            return stored.value
        }
        part.mpn = attribute(.mpn)
        part.value = attribute(.value)
        part.manufacturer = attribute(.manufacturer)
        part.datasheet = attribute(.datasheet)
        part.description = attribute(.description)
        part.entityID = base.map(\.entityID) ?? entityID
        part.packageID = base.map(\.packageID) ?? packageID
        var tags = self.tags
        if inheritTags, let base {
            tags += base.tags
        }
        part.tags = Array(Set(tags)).sorted()
        func flag(_ flag: HorizontalPartFlag) -> Bool {
            switch flags[flag] ?? .clear {
            case .set: true
            case .clear: false
            case .inherit: base?.flag(flag) ?? false
            }
        }
        part.isBasePart = flag(.basePart)
        part.excludeFromBOM = flag(.excludeBOM)
        part.excludeFromPnP = flag(.excludePNP)
        switch overridePrefix {
        case .yes: part.prefix = prefix
        case .no: part.prefix = nil
        case .inherit: part.prefix = base?.prefix
        }
        return part
    }

    /// The part's file resolved through `base`, which returns the base
    /// part's own JSON. Chains stop at eight levels or a loop.
    static func resolve(_ json: JSONDictionary, base: (String) -> JSONDictionary?) -> HorizontalResolvedPart {
        resolve(json, base: base, visited: [])
    }

    private static func resolve(_ json: JSONDictionary, base: (String) -> JSONDictionary?, visited: Set<String>) -> HorizontalResolvedPart {
        let record = HorizontalPartRecord(json: json)
        let resolvedBase = record.baseID.flatMap { id -> HorizontalResolvedPart? in
            guard visited.count < 8, !visited.contains(id), let baseJSON = base(id) else { return nil }
            return resolve(baseJSON, base: base, visited: visited.union([id]))
        }
        return record.resolved(base: resolvedBase)
    }
}

/// A pool part with its inheritance worked out: what Horizon's `Part`
/// getters return. Empty strings stand for an attribute it doesn't have.
struct HorizontalResolvedPart: Hashable, Sendable {
    var mpn = ""
    /// The value attribute itself; `displayValue` is what is shown.
    var value = ""
    var manufacturer = ""
    var datasheet = ""
    var description = ""
    var entityID: String?
    var packageID: String?
    var tags: [String] = []
    var isBasePart = false
    var excludeFromBOM = false
    var excludeFromPnP = false
    /// The refdes prefix the part sets, or nil for its entity's.
    var prefix: String?

    /// What Horizon shows as the part's value: its value, or its MPN when
    /// it has none (`Part::get_value`).
    var displayValue: String { value.isEmpty ? mpn : value }

    func attribute(_ kind: HorizontalPartAttributeKind) -> String {
        switch kind {
        case .mpn: mpn
        case .value: value
        case .manufacturer: manufacturer
        case .datasheet: datasheet
        case .description: description
        }
    }

    func flag(_ flag: HorizontalPartFlag) -> Bool {
        switch flag {
        case .basePart: isBasePart
        case .excludeBOM: excludeFromBOM
        case .excludePNP: excludeFromPnP
        }
    }
}
