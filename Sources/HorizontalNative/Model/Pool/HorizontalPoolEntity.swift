import Foundation

struct HorizontalEntityGate: Identifiable, Hashable {
    var id: String
    var name: String
    var suffix: String
    var swapGroup: Int
    var unitID: String

    init(id: String, name: String, suffix: String = "", swapGroup: Int = 0, unitID: String) {
        self.id = id
        self.name = name
        self.suffix = suffix
        self.swapGroup = swapGroup
        self.unitID = unitID
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            name: json.string("name") ?? "",
            suffix: json.string("suffix") ?? "",
            swapGroup: json.int("swap_group") ?? 0,
            unitID: try HorizontalPoolJSON.requiredString(json, "unit")
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("name", name)
        builder.set("suffix", suffix)
        builder.set("swap_group", swapGroup, isDefault: swapGroup == 0)
        builder.set("unit", unitID)
        return builder.json
    }
}

struct HorizontalPoolEntity: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.entity

    var uuid: String
    var name: String
    var manufacturer: String
    var prefix: String
    /// Upstream keeps tags in a `std::set`, so its writes are sorted and
    /// unique; the editor keeps that invariant when it changes them.
    var tags: [String]
    var gates: [String: HorizontalEntityGate]
    var sourceJSON: HorizontalPreservedJSON

    init(
        uuid: String,
        name: String,
        manufacturer: String = "",
        prefix: String = "U",
        tags: [String] = [],
        gates: [String: HorizontalEntityGate] = [:]
    ) {
        self.uuid = uuid
        self.name = name
        self.manufacturer = manufacturer
        self.prefix = prefix
        self.tags = tags
        self.gates = gates
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        manufacturer = json.string("manufacturer") ?? ""
        prefix = json.string("prefix") ?? ""
        tags = HorizontalPoolJSON.stringArray(json, "tags")
        var gates = [String: HorizontalEntityGate]()
        for (id, gate) in json.dictionaryMap("gates") {
            gates[id] = try HorizontalEntityGate(id: id, json: gate)
        }
        self.gates = gates
        sourceJSON = HorizontalPreservedJSON(json)
    }

    /// Gates in upstream's preview order: by suffix, then name.
    var sortedGates: [HorizontalEntityGate] {
        gates.values.sorted {
            ($0.suffix, $0.name.localizedLowercase) < ($1.suffix, $1.name.localizedLowercase)
        }
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("type", "entity")
        builder.set("name", name)
        builder.set("manufacturer", manufacturer, isDefault: manufacturer.isEmpty)
        builder.set("uuid", uuid)
        builder.set("prefix", prefix)
        builder.set("tags", tags, isDefault: tags.isEmpty)
        builder.setMap("gates", gates) { $0.json(original: $1) }
        return builder.json
    }

    func validationIssues() -> [HorizontalPoolCheckIssue] {
        var issues = [HorizontalPoolCheckIssue]()
        if name.isEmpty {
            issues.append(.failure("Name must not be empty"))
        }
        if name.horizonNeedsTrim {
            issues.append(.failure("Name has trailing/leading whitespace"))
        }
        if manufacturer.horizonNeedsTrim {
            issues.append(.failure("Manufacturer has trailing/leading whitespace"))
        }
        issues += HorizontalPoolChecks.prefixIssues(prefix)
        if tags.isEmpty {
            issues.append(.failure("Tags must not be empty"))
        }
        for tag in tags {
            issues += HorizontalPoolChecks.tagIssues(tag)
        }

        let gates = sortedGates
        if gates.isEmpty {
            issues.append(.failure("Entity has no gates"))
        } else if gates.count == 1 {
            let gate = gates[0]
            if gate.name != "Main" {
                issues.append(.warning("Only gate must be named \"Main\""))
            }
            if !gate.suffix.isEmpty {
                issues.append(.warning("Only gate must have empty suffix"))
            }
            if gate.swapGroup != 0 {
                issues.append(.warning("Only gate must have zero swap group"))
            }
        } else {
            var names = Set<String>()
            var suffixes = Set<String>()
            var swapGroups = [Int: [HorizontalEntityGate]]()
            for gate in gates {
                if gate.name.horizonNeedsTrim {
                    issues.append(.failure("Gate \"\(gate.name)\" has trailing/leading whitespace"))
                }
                if names.contains(gate.name) {
                    issues.append(.failure("Gate \"\(gate.name)\" not unique"))
                }
                names.insert(gate.name)
                if suffixes.contains(gate.suffix) {
                    issues.append(.failure("Gate suffix \"\(gate.suffix)\" not unique"))
                }
                suffixes.insert(gate.suffix)
                if !HorizontalPoolChecks.prefixIssues(gate.suffix).isEmpty {
                    issues.append(.failure("Gate suffix \"\(gate.suffix)\" must be one or more capital letters"))
                }
                if gate.swapGroup != 0 {
                    swapGroups[gate.swapGroup, default: []].append(gate)
                }
            }
            for (group, members) in swapGroups.sorted(by: { $0.key < $1.key }) {
                if members.count == 1 {
                    issues.append(.warning("Swap group \(group) only has one gate"))
                } else if Set(members.map(\.unitID)).count > 1 {
                    issues.append(.warning("Swap group \(group) has gates with more than one distinct unit"))
                }
            }
        }
        return issues
    }
}

/// Checks shared by more than one kind (`checks/check_util.cpp`).
enum HorizontalPoolChecks {
    /// `^[A-Z]+$`
    static func prefixIssues(_ prefix: String) -> [HorizontalPoolCheckIssue] {
        let valid = !prefix.isEmpty && prefix.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
        return valid ? [] : [.failure("Prefix must be one or more capital letters")]
    }

    /// `^[a-z-0-9.]+$`
    static func tagIssues(_ tag: String) -> [HorizontalPoolCheckIssue] {
        let valid = !tag.isEmpty && tag.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "."
        }
        return valid ? [] : [.failure("Tag \"\(tag)\" must only contain lowercase letters, digits, dots or dashes")]
    }
}
