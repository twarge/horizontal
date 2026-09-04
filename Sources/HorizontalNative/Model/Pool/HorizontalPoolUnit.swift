import Foundation

/// Horizon pin directions, in the file's spelling.
enum HorizontalPinDirection: String, CaseIterable, Hashable {
    case output
    case input
    case bidirectional
    case openCollector = "open_collector"
    case powerInput = "power_input"
    case powerOutput = "power_output"
    case passive
    case notConnected = "not_connected"

    /// Upstream's editor order and labels (`Pin::direction_names`).
    static let editorOrder: [HorizontalPinDirection] = [
        .input, .output, .bidirectional, .passive, .powerInput, .powerOutput, .openCollector, .notConnected,
    ]

    var displayName: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        case .bidirectional: "Bidirectional"
        case .passive: "Passive"
        case .powerInput: "Power Input"
        case .powerOutput: "Power Output"
        case .openCollector: "Open Collector"
        case .notConnected: "Not Connected"
        }
    }

    var abbreviation: String {
        switch self {
        case .input: "In"
        case .output: "Out"
        case .bidirectional: "BiDi"
        case .passive: "Passive"
        case .powerInput: "PIn"
        case .powerOutput: "POut"
        case .openCollector: "OC"
        case .notConnected: "NC"
        }
    }
}

struct HorizontalUnitPinAlternateName: Identifiable, Hashable {
    var id: String
    var name: String
    var direction: HorizontalPinDirection
}

struct HorizontalUnitPin: Identifiable, Hashable {
    var id: String
    var primaryName: String
    var direction: HorizontalPinDirection = .input
    var swapGroup: Int = 0
    /// Alternate names in id order (upstream keeps them in a uuid-keyed map).
    var alternateNames: [HorizontalUnitPinAlternateName] = []
    /// The pre-`alt_names` encoding this pin was loaded with, if any: a bare
    /// string array whose ids are derived from the index. Kept so a unit that
    /// still uses it stays byte-identical until its alternate names change.
    var legacyNames: [String]? = nil

    init(
        id: String,
        primaryName: String,
        direction: HorizontalPinDirection = .input,
        swapGroup: Int = 0,
        alternateNames: [HorizontalUnitPinAlternateName] = []
    ) {
        self.id = id
        self.primaryName = primaryName
        self.direction = direction
        self.swapGroup = swapGroup
        self.alternateNames = alternateNames
    }

    init(id: String, json: JSONDictionary) throws {
        self.id = id
        primaryName = try HorizontalPoolJSON.requiredString(json, "primary_name")
        direction = HorizontalPinDirection(rawValue: json.string("direction") ?? "") ?? .input
        swapGroup = json.int("swap_group") ?? 0
        if let modern = json.dictionary("alt_names") {
            alternateNames = modern.compactMap { key, value -> HorizontalUnitPinAlternateName? in
                guard let entry = value as? JSONDictionary, let name = entry.string("name") else {
                    return nil
                }
                return HorizontalUnitPinAlternateName(
                    id: key,
                    name: name,
                    direction: HorizontalPinDirection(rawValue: entry.string("direction") ?? "") ?? direction
                )
            }
            .sorted { $0.id < $1.id }
        } else if let legacy = json["names"] as? [String], !legacy.isEmpty {
            legacyNames = legacy
            alternateNames = Self.derivedAlternateNames(from: legacy, direction: direction)
        }
    }

    /// Upstream's reading of a legacy `names` array: ids from the index,
    /// every alternate sharing the pin's own direction.
    static func derivedAlternateNames(from legacy: [String], direction: HorizontalPinDirection) -> [HorizontalUnitPinAlternateName] {
        legacy.enumerated().map { index, name in
            HorizontalUnitPinAlternateName(
                id: UUID.horizonAlternatePinNameID(index: index),
                name: name,
                direction: direction
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Whether this pin still writes the legacy `names` array (nothing about
    /// its alternates changed since it was read that way).
    var writesLegacyNames: Bool {
        guard let legacyNames else {
            return false
        }
        return alternateNames == Self.derivedAlternateNames(from: legacyNames, direction: direction)
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("primary_name", primaryName)
        builder.set("direction", direction.rawValue)
        builder.set("swap_group", swapGroup, isDefault: swapGroup == 0)
        if writesLegacyNames, let legacyNames {
            builder.set("names", legacyNames)
            builder.remove("alt_names")
        } else {
            // `names` is written empty for older readers; the real alternates
            // live in `alt_names`, present only when there are any.
            builder.set("names", [String](), isDefault: alternateNames.isEmpty)
            var altNames = JSONDictionary()
            for alternate in alternateNames {
                altNames[alternate.id] = ["name": alternate.name, "direction": alternate.direction.rawValue]
            }
            builder.set("alt_names", altNames, when: !alternateNames.isEmpty)
        }
        return builder.json
    }
}

struct HorizontalPoolUnit: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.unit

    var uuid: String
    var name: String
    var manufacturer: String
    var pins: [String: HorizontalUnitPin]
    var sourceJSON: HorizontalPreservedJSON

    init(uuid: String, name: String, manufacturer: String = "", pins: [String: HorizontalUnitPin] = [:]) {
        self.uuid = uuid
        self.name = name
        self.manufacturer = manufacturer
        self.pins = pins
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        manufacturer = json.string("manufacturer") ?? ""
        var pins = [String: HorizontalUnitPin]()
        for (id, pin) in json.dictionaryMap("pins") {
            pins[id] = try HorizontalUnitPin(id: id, json: pin)
        }
        self.pins = pins
        sourceJSON = HorizontalPreservedJSON(json)
    }

    /// Pins in upstream's editor order: natural sort on the primary name.
    var sortedPins: [HorizontalUnitPin] {
        pins.values.sorted { $0.primaryName.localizedStandardCompare($1.primaryName) == .orderedAscending }
    }

    /// 1 once any pin carries `alt_names`, as upstream's
    /// `Unit::get_required_version`; a pin still on the legacy array doesn't
    /// count, because the file it came from never had a version.
    var requiredVersion: Int {
        pins.values.contains { !$0.alternateNames.isEmpty && !$0.writesLegacyNames } ? 1 : 0
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("version", requiredVersion, when: requiredVersion > 0)
        builder.set("type", "unit")
        builder.set("name", name)
        builder.set("manufacturer", manufacturer, isDefault: manufacturer.isEmpty)
        builder.set("uuid", uuid)
        builder.setMap("pins", pins) { $0.json(original: $1) }
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
        var pinNames = Set<String>()
        for pin in sortedPins {
            if pinNames.contains(pin.primaryName) {
                issues.append(.failure("Pin \"\(pin.primaryName)\" not unique"))
            }
            pinNames.insert(pin.primaryName)
            if pin.primaryName.horizonNeedsTrim {
                issues.append(.failure("Pin \"\(pin.primaryName)\" has trailing/leading whitespace"))
            }
            var names = Set<String>()
            for alternate in pin.alternateNames {
                if alternate.name.horizonNeedsTrim {
                    issues.append(.failure("Alt. name \"\(alternate.name)\" of pin \"\(pin.primaryName)\" has trailing/leading whitespace"))
                }
                if alternate.name.isEmpty {
                    issues.append(.failure("Alt. name of pin \"\(pin.primaryName)\" must not be empty"))
                }
                if names.contains(alternate.name) {
                    issues.append(.failure("Alt. name \"\(alternate.name)\" of pin \"\(pin.primaryName)\" not unique"))
                }
                names.insert(alternate.name)
                if alternate.name.contains(",") || alternate.name.contains(";") {
                    issues.append(.failure("Alt. name \"\(alternate.name)\" of pin \"\(pin.primaryName)\" contains comma or semicolon"))
                }
            }
            if names.contains(pin.primaryName) {
                issues.append(.failure("Alt. name of pin \"\(pin.primaryName)\" must not repeat primary name"))
            }
        }
        return issues
    }
}
