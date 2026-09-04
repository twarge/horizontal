import Foundation

/// The five part attributes, each stored as `[inherited, value]` in the file.
enum HorizontalPartAttributeKind: String, CaseIterable, Hashable {
    case mpn = "MPN"
    case value
    case manufacturer
    case datasheet
    case description

    var displayName: String {
        switch self {
        case .mpn: "MPN"
        case .value: "Value"
        case .manufacturer: "Manufacturer"
        case .datasheet: "Datasheet"
        case .description: "Description"
        }
    }
}

struct HorizontalPartAttribute: Hashable {
    var inherited: Bool = false
    var value: String = ""

    init(inherited: Bool = false, value: String = "") {
        self.inherited = inherited
        self.value = value
    }

    init?(json: Any?) {
        guard let pair = json as? [Any], pair.count == 2, let value = pair[1] as? String else {
            return nil
        }
        self.init(inherited: (pair[0] as? NSNumber)?.boolValue ?? false, value: value)
    }

    var json: [Any] {
        [inherited, value]
    }
}

struct HorizontalPartPadMapEntry: Hashable {
    var gateID: String
    var pinID: String
}

enum HorizontalPartFlag: String, CaseIterable, Hashable {
    case basePart = "base_part"
    case excludeBOM = "exclude_bom"
    case excludePNP = "exclude_pnp"

    var displayName: String {
        switch self {
        case .basePart: "Base part"
        case .excludeBOM: "Exclude from BOM"
        case .excludePNP: "Exclude from pick and place"
        }
    }
}

enum HorizontalPartFlagState: String, CaseIterable, Hashable {
    case set
    case clear
    case inherit
}

enum HorizontalPartOverridePrefix: String, CaseIterable, Hashable {
    case no
    case yes
    case inherit
}

/// A pool part. Named `PartItem` because `HorizontalPoolPart` is the Parts
/// pane's placement summary.
struct HorizontalPoolPartItem: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.part

    var uuid: String
    var attributes: [HorizontalPartAttributeKind: HorizontalPartAttribute]
    var tags: [String]
    var inheritTags: Bool
    var parametric: [String: String]
    /// The 3D model uuid, `nil` when the file has no `model` key at all
    /// (older files); a nil uuid string is what upstream writes for "none".
    var modelID: String?
    var inheritModel: Bool
    /// A derived part: attributes may inherit from `base`, and entity,
    /// package and pad map come from it rather than the file.
    var baseID: String?
    var entityID: String?
    var packageID: String?
    var padMap: [String: HorizontalPartPadMapEntry]
    var orderableMPNs: [String: String]
    var flags: [HorizontalPartFlag: HorizontalPartFlagState]
    var overridePrefix: HorizontalPartOverridePrefix
    var prefix: String
    var sourceJSON: HorizontalPreservedJSON

    static let nilModelID = "00000000-0000-0000-0000-000000000000"

    init(uuid: String, entityID: String, packageID: String, mpn: String = "", manufacturer: String = "") {
        self.uuid = uuid
        attributes = [
            .mpn: HorizontalPartAttribute(value: mpn),
            .value: HorizontalPartAttribute(),
            .manufacturer: HorizontalPartAttribute(value: manufacturer),
            .datasheet: HorizontalPartAttribute(),
            .description: HorizontalPartAttribute(),
        ]
        tags = []
        inheritTags = false
        parametric = [:]
        modelID = Self.nilModelID
        inheritModel = true
        baseID = nil
        self.entityID = entityID
        self.packageID = packageID
        padMap = [:]
        orderableMPNs = [:]
        flags = Dictionary(uniqueKeysWithValues: HorizontalPartFlag.allCases.map { ($0, .clear) })
        overridePrefix = .no
        prefix = ""
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        var attributes = [HorizontalPartAttributeKind: HorizontalPartAttribute]()
        for kind in HorizontalPartAttributeKind.allCases {
            attributes[kind] = HorizontalPartAttribute(json: json[kind.rawValue]) ?? HorizontalPartAttribute()
        }
        self.attributes = attributes
        tags = HorizontalPoolJSON.stringArray(json, "tags")
        inheritTags = json.bool("inherit_tags") ?? false
        parametric = (json.dictionary("parametric") ?? [:]).compactMapValues { $0 as? String }
        modelID = json.string("model")
        inheritModel = json.bool("inherit_model") ?? true
        baseID = json.string("base")
        entityID = json.string("entity")
        packageID = json.string("package")
        var padMap = [String: HorizontalPartPadMapEntry]()
        for (padID, entry) in json.dictionaryMap("pad_map") {
            guard let gateID = entry.string("gate"), let pinID = entry.string("pin") else {
                continue
            }
            padMap[padID] = HorizontalPartPadMapEntry(gateID: gateID, pinID: pinID)
        }
        self.padMap = padMap
        orderableMPNs = (json.dictionary("orderable_MPNs") ?? [:]).compactMapValues { $0 as? String }

        var flags = Dictionary(uniqueKeysWithValues: HorizontalPartFlag.allCases.map { ($0, HorizontalPartFlagState.clear) })
        for (key, value) in json.dictionary("flags") ?? [:] {
            guard let flag = HorizontalPartFlag(rawValue: key),
                  let state = HorizontalPartFlagState(rawValue: value as? String ?? "") else {
                continue
            }
            // Upstream normalises an inherit on a part without a base to clear.
            flags[flag] = (state == .inherit && baseID == nil) ? .clear : state
        }
        self.flags = flags
        overridePrefix = HorizontalPartOverridePrefix(rawValue: json.string("override_prefix") ?? "") ?? .no
        prefix = json.string("prefix") ?? ""
        sourceJSON = HorizontalPreservedJSON(json)
    }

    var name: String {
        let mpn = attributes[.mpn]?.value ?? ""
        return mpn.isEmpty ? (attributes[.value]?.value ?? "") : mpn
    }

    func attribute(_ kind: HorizontalPartAttributeKind) -> HorizontalPartAttribute {
        attributes[kind] ?? HorizontalPartAttribute()
    }

    var hasNonClearFlags: Bool {
        flags.values.contains { $0 != .clear }
    }

    /// `Part::get_required_version`: 1 with any non-clear flag, 2 with a
    /// prefix override.
    var requiredVersion: Int {
        if overridePrefix != .no {
            return 2
        }
        return hasNonClearFlags ? 1 : 0
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("type", "part")
        builder.set("uuid", uuid)
        builder.set("version", requiredVersion, when: requiredVersion > 0)
        for kind in HorizontalPartAttributeKind.allCases {
            let attribute = self.attribute(kind)
            let optional = kind == .datasheet || kind == .description
            builder.set(kind.rawValue, attribute.json, isDefault: optional && !attribute.inherited && attribute.value.isEmpty)
        }
        builder.set("tags", tags, isDefault: tags.isEmpty)
        builder.set("inherit_tags", inheritTags, isDefault: !inheritTags)
        builder.set("parametric", parametric.mapValues { $0 as Any }, isDefault: parametric.isEmpty)
        if let modelID {
            builder.set("model", modelID)
        }
        builder.set("inherit_model", inheritModel, isDefault: inheritModel)
        if let baseID {
            builder.set("base", baseID)
            builder.remove("entity")
            builder.remove("package")
            builder.remove("pad_map")
        } else {
            builder.remove("base")
            builder.set("entity", entityID ?? "")
            builder.set("package", packageID ?? "")
            builder.setMap("pad_map", padMap) { entry, original in
                var item = HorizontalPoolJSONBuilder(original: original)
                item.set("gate", entry.gateID)
                item.set("pin", entry.pinID)
                return item.json
            }
        }
        builder.set("orderable_MPNs", orderableMPNs.mapValues { $0 as Any }, when: !orderableMPNs.isEmpty)
        var flagsJSON = JSONDictionary()
        for flag in HorizontalPartFlag.allCases {
            flagsJSON[flag.rawValue] = (flags[flag] ?? .clear).rawValue
        }
        builder.set("flags", flagsJSON, when: hasNonClearFlags)
        builder.set("override_prefix", overridePrefix.rawValue, when: overridePrefix != .no)
        builder.set("prefix", prefix, when: overridePrefix != .no)
        return builder.json
    }

    func validationIssues() -> [HorizontalPoolCheckIssue] {
        var issues = [HorizontalPoolCheckIssue]()
        let mpn = attribute(.mpn)
        if !mpn.inherited, mpn.value.isEmpty {
            issues.append(.failure("MPN must not be empty"))
        }
        if mpn.value.horizonNeedsTrim {
            issues.append(.failure("MPN has trailing/leading whitespace"))
        }
        let value = attribute(.value)
        if !value.inherited, !value.value.isEmpty, value.value == mpn.value {
            issues.append(.warning("Leave value blank if it's the same as MPN"))
        }
        if value.value.horizonNeedsTrim {
            issues.append(.failure("Value has trailing/leading whitespace"))
        }
        if attribute(.manufacturer).value.horizonNeedsTrim {
            issues.append(.failure("Manufacturer has trailing/leading whitespace"))
        }
        let description = attribute(.description)
        if !description.inherited, description.value.isEmpty {
            issues.append(.failure("Description must not be empty"))
        }
        if description.value.horizonNeedsTrim {
            issues.append(.failure("Description has trailing/leading whitespace"))
        }
        let datasheet = attribute(.datasheet)
        if datasheet.value.horizonNeedsTrim {
            issues.append(.failure("Datasheet has trailing/leading whitespace"))
        }
        if !datasheet.inherited, !datasheet.value.isEmpty {
            let ext = (datasheet.value as NSString).pathExtension.lowercased()
            if ext.hasPrefix("p"), ext != "pdf" {
                issues.append(.warning("Datasheet extension likely missing/mistyped"))
            }
            let discouraged = ["rs-online.com", "digikey.com", "mouser.com", "farnell.com", "octopart.com",
                               "google.com", "reichelt.de", "conrad.de", "conrad.com"]
            if let domain = discouraged.first(where: { datasheet.value.contains($0) }) {
                issues.append(.warning("Discouraged datasheet domain \(domain)"))
            }
        }
        if overridePrefix == .yes {
            issues += HorizontalPoolChecks.prefixIssues(prefix)
        }
        for orderable in orderableMPNs.values.sorted() {
            if orderable.horizonNeedsTrim {
                issues.append(.failure("Orderable MPN \"\(orderable)\" has trailing/leading whitespace"))
            }
            if orderable.isEmpty {
                issues.append(.warning("Orderable MPNs must not be empty"))
            }
        }
        for tag in tags {
            issues += HorizontalPoolChecks.tagIssues(tag)
        }
        return issues
    }
}
