import Foundation

/// An editable pool item of one kind: unit, entity, part, symbol, package,
/// padstack, frame or decal.
///
/// Every model keeps the dictionary it was loaded from and writes itself back
/// by overlaying the keys Horizon's own serializer owns onto that dictionary.
/// Keys this app does not model (Horizon's `_imp` window state, package
/// `rules` and `grid_settings`, hand-added `tags` on a unit) therefore survive
/// a save untouched, and an item that was opened and saved without an edit
/// comes back byte for byte.
protocol HorizontalPoolItemDocumentModel: Equatable {
    static var category: HorizontalPoolItemCategory { get }
    var uuid: String { get }
    /// The name the window title and library list show.
    var name: String { get }
    /// The dictionary the item was loaded from; `json()` overlays onto it.
    var sourceJSON: HorizontalPreservedJSON { get }
    init(json: JSONDictionary) throws
    func json() -> JSONDictionary
    /// Upstream's pool checks (`checks/check_*.cpp`) for the kind, as far as
    /// they can run without the rest of the pool.
    func validationIssues() -> [HorizontalPoolCheckIssue]
}

extension HorizontalPoolItemDocumentModel {
    func validationIssues() -> [HorizontalPoolCheckIssue] { [] }
}

/// A JSON dictionary that compares by content, so models holding their
/// source dictionary can still be `Equatable` (`[String: Any]` is not).
struct HorizontalPreservedJSON: Hashable {
    var dictionary: JSONDictionary

    init(_ dictionary: JSONDictionary) {
        self.dictionary = dictionary
    }

    static func == (lhs: HorizontalPreservedJSON, rhs: HorizontalPreservedJSON) -> Bool {
        NSDictionary(dictionary: lhs.dictionary).isEqual(to: rhs.dictionary)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(dictionary.keys.sorted())
    }
}

/// One finding of a pool check, in upstream's two severities.
struct HorizontalPoolCheckIssue: Hashable, Identifiable {
    enum Level: Hashable {
        case warning
        case failure
    }

    var level: Level
    var message: String

    var id: String { "\(level)|\(message)" }

    static func failure(_ message: String) -> HorizontalPoolCheckIssue {
        HorizontalPoolCheckIssue(level: .failure, message: message)
    }

    static func warning(_ message: String) -> HorizontalPoolCheckIssue {
        HorizontalPoolCheckIssue(level: .warning, message: message)
    }
}

enum HorizontalPoolModelError: LocalizedError, Equatable {
    case missingKey(String)
    case wrongType(String)
    case unsupportedCategory(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let key):
            "The pool item is missing \"\(key)\"."
        case .wrongType(let key):
            "The pool item's \"\(key)\" has an unexpected type."
        case .unsupportedCategory(let type):
            "\"\(type)\" is not an editable pool item kind."
        }
    }
}

/// The editable model for any pool item kind, with the per-kind model behind
/// one case each so the editor session and document host can stay generic.
enum HorizontalPoolItemModel: Equatable {
    case unit(HorizontalPoolUnit)
    case entity(HorizontalPoolEntity)
    case part(HorizontalPoolPartItem)
    case symbol(HorizontalPoolSymbol)
    case package(HorizontalPoolPackage)
    case padstack(HorizontalPoolPadstack)
    case frame(HorizontalPoolFrame)
    case decal(HorizontalPoolDecal)

    static func load(category: HorizontalPoolItemCategory, json: JSONDictionary) throws -> HorizontalPoolItemModel {
        switch category {
        case .unit: .unit(try HorizontalPoolUnit(json: json))
        case .entity: .entity(try HorizontalPoolEntity(json: json))
        case .part: .part(try HorizontalPoolPartItem(json: json))
        case .symbol: .symbol(try HorizontalPoolSymbol(json: json))
        case .package: .package(try HorizontalPoolPackage(json: json))
        case .padstack: .padstack(try HorizontalPoolPadstack(json: json))
        case .frame: .frame(try HorizontalPoolFrame(json: json))
        case .decal: .decal(try HorizontalPoolDecal(json: json))
        }
    }

    /// Loads whichever kind the dictionary's `type` names.
    static func load(json: JSONDictionary) throws -> HorizontalPoolItemModel {
        let type = json.string("type") ?? ""
        guard let category = HorizontalPoolItemCategory(rawValue: type) else {
            throw HorizontalPoolModelError.unsupportedCategory(type)
        }
        return try load(category: category, json: json)
    }

    var category: HorizontalPoolItemCategory {
        switch self {
        case .unit: .unit
        case .entity: .entity
        case .part: .part
        case .symbol: .symbol
        case .package: .package
        case .padstack: .padstack
        case .frame: .frame
        case .decal: .decal
        }
    }

    var uuid: String {
        switch self {
        case .unit(let model): model.uuid
        case .entity(let model): model.uuid
        case .part(let model): model.uuid
        case .symbol(let model): model.uuid
        case .package(let model): model.uuid
        case .padstack(let model): model.uuid
        case .frame(let model): model.uuid
        case .decal(let model): model.uuid
        }
    }

    var name: String {
        switch self {
        case .unit(let model): model.name
        case .entity(let model): model.name
        case .part(let model): model.name
        case .symbol(let model): model.name
        case .package(let model): model.name
        case .padstack(let model): model.name
        case .frame(let model): model.name
        case .decal(let model): model.name
        }
    }

    func json() -> JSONDictionary {
        switch self {
        case .unit(let model): model.json()
        case .entity(let model): model.json()
        case .part(let model): model.json()
        case .symbol(let model): model.json()
        case .package(let model): model.json()
        case .padstack(let model): model.json()
        case .frame(let model): model.json()
        case .decal(let model): model.json()
        }
    }

    func validationIssues() -> [HorizontalPoolCheckIssue] {
        switch self {
        case .unit(let model): model.validationIssues()
        case .entity(let model): model.validationIssues()
        case .part(let model): model.validationIssues()
        case .symbol(let model): model.validationIssues()
        case .package(let model): model.validationIssues()
        case .padstack(let model): model.validationIssues()
        case .frame(let model): model.validationIssues()
        case .decal(let model): model.validationIssues()
        }
    }
}

extension HorizontalPoolItemCategory {
    /// "Unit", "Symbol", … for window titles and menus.
    var singularTitle: String {
        switch self {
        case .unit: "Unit"
        case .symbol: "Symbol"
        case .entity: "Entity"
        case .padstack: "Padstack"
        case .package: "Package"
        case .part: "Part"
        case .frame: "Frame"
        case .decal: "Decal"
        }
    }
}

// MARK: - Serialization helpers

/// Builds an item's (or one map entry's) JSON by overlaying modelled keys onto
/// the dictionary it was loaded from.
///
/// Horizon's serializers write every key they own on every save, defaults
/// included, which would turn "open and save" into a diff on any older file
/// missing a key that was added later (a symbol's `text_placements`, a text's
/// `font`, a part's `datasheet`). So a key whose value is the reader's default
/// is only written when the source already had it — or when there is no source
/// at all, i.e. a brand-new entry, which gets the full set upstream would write.
struct HorizontalPoolJSONBuilder {
    private(set) var json: JSONDictionary
    private let isNew: Bool

    init(original: JSONDictionary?) {
        json = original ?? [:]
        // A loaded item always has keys (at least its uuid), so an empty
        // source means a brand-new entry that gets the full upstream set.
        isNew = original?.isEmpty ?? true
    }

    /// A key upstream always writes with a value that is never a default.
    mutating func set(_ key: String, _ value: Any) {
        json[key] = value
    }

    /// A key upstream always writes; `isDefault` says the value is what a
    /// reader assumes when the key is absent.
    mutating func set(_ key: String, _ value: Any, isDefault: Bool) {
        if isDefault, !isNew, json[key] == nil {
            return
        }
        json[key] = value
    }

    /// A key upstream writes only under a condition, and drops otherwise.
    mutating func set(_ key: String, _ value: Any, when condition: Bool) {
        if condition {
            json[key] = value
        } else {
            json.removeValue(forKey: key)
        }
    }

    mutating func remove(_ key: String) {
        json.removeValue(forKey: key)
    }

    /// Overlays a uuid-keyed map, giving each entry its own source entry so
    /// unknown per-entry keys survive too; entries the model no longer has
    /// are dropped, as they would be by upstream's full rewrite.
    mutating func setMap<Entry>(
        _ key: String,
        _ entries: [String: Entry],
        isDefault: Bool = false,
        serialize: (Entry, JSONDictionary?) -> JSONDictionary
    ) {
        let original = json[key] as? JSONDictionary ?? [:]
        var map = JSONDictionary()
        for (id, entry) in entries {
            map[id] = serialize(entry, original[id] as? JSONDictionary)
        }
        set(key, map, isDefault: isDefault && entries.isEmpty)
    }
}

enum HorizontalPoolJSON {
    /// Horizon stores every length in integer nanometres.
    static func int(_ value: Double) -> Int {
        Int(value.rounded())
    }

    static func point(_ point: HorizontalPoint) -> [Int] {
        [int(point.x), int(point.y)]
    }

    static func placement(_ transform: HorizontalPlacementTransform) -> JSONDictionary {
        [
            "shift": point(transform.shift),
            "angle": transform.angle,
            "mirror": transform.mirrored,
        ]
    }

    static func placement(_ json: JSONDictionary?, key: String = "placement") throws -> HorizontalPlacementTransform {
        guard let placement = HorizontalPlacementTransform(json: json?.dictionary(key)) else {
            throw HorizontalPoolModelError.missingKey(key)
        }
        return placement
    }

    static func requiredString(_ json: JSONDictionary, _ key: String) throws -> String {
        guard let value = json.string(key) else {
            throw HorizontalPoolModelError.missingKey(key)
        }
        return value
    }

    static func requiredPoint(_ json: JSONDictionary, _ key: String) throws -> HorizontalPoint {
        guard let value = json.point(key) else {
            throw HorizontalPoolModelError.missingKey(key)
        }
        return value
    }

    /// `parameter_set`: a flat map of Horizon parameter ids to nanometres.
    static func parameterSet(_ json: JSONDictionary?) -> [String: Int] {
        var result = [String: Int]()
        for (key, value) in json ?? [:] {
            if let number = value as? NSNumber {
                result[key] = number.intValue
            }
        }
        return result
    }

    static func parameterSetJSON(_ set: [String: Int]) -> JSONDictionary {
        set.mapValues { $0 as Any }
    }

    static func stringArray(_ json: JSONDictionary, _ key: String) -> [String] {
        json[key] as? [String] ?? []
    }
}

extension String {
    /// Upstream trims nothing on load; its checks flag names with surrounding
    /// whitespace instead.
    var horizonNeedsTrim: Bool {
        self != trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
