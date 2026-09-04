import Foundation

enum HorizontalPinOrientation: String, CaseIterable, Hashable {
    case up
    case down
    case left
    case right
}

enum HorizontalPinNameOrientation: String, CaseIterable, Hashable {
    case inLine = "in_line"
    case perpendicular
    case horizontal

    var displayName: String {
        switch self {
        case .inLine: "In line"
        case .perpendicular: "Perpendicular"
        case .horizontal: "Horizontal"
        }
    }
}

enum HorizontalPinDriver: String, CaseIterable, Hashable {
    case `default`
    case openCollector = "open_collector"
    case openCollectorPullup = "open_collector_pullup"
    case openEmitter = "open_emitter"
    case openEmitterPulldown = "open_emitter_pulldown"
    case tristate

    var displayName: String {
        switch self {
        case .default: "Default"
        case .openCollector: "Open collector"
        case .openCollectorPullup: "Open collector with pull-up"
        case .openEmitter: "Open emitter"
        case .openEmitterPulldown: "Open emitter with pull-down"
        case .tristate: "Tristate"
        }
    }
}

struct HorizontalSymbolPinDecoration: Hashable {
    var dot = false
    var clock = false
    var schmitt = false
    var driver: HorizontalPinDriver = .default

    init(dot: Bool = false, clock: Bool = false, schmitt: Bool = false, driver: HorizontalPinDriver = .default) {
        self.dot = dot
        self.clock = clock
        self.schmitt = schmitt
        self.driver = driver
    }

    init(json: JSONDictionary) {
        self.init(
            dot: json.bool("dot") ?? false,
            clock: json.bool("clock") ?? false,
            schmitt: json.bool("schmitt") ?? false,
            driver: HorizontalPinDriver(rawValue: json.string("driver") ?? "") ?? .default
        )
    }

    var isDefault: Bool {
        self == HorizontalSymbolPinDecoration()
    }

    var json: JSONDictionary {
        ["dot": dot, "clock": clock, "schmitt": schmitt, "driver": driver.rawValue]
    }
}

/// A symbol's placed pin. Its id is the unit pin's id; the name and direction
/// are never stored, they come from the unit when the symbol is expanded.
struct HorizontalSymbolPin: Identifiable, Hashable {
    var id: String
    var position: HorizontalPoint
    var length: Double = 2_500_000
    var orientation: HorizontalPinOrientation = .right
    var nameVisible = true
    var padVisible = true
    var nameOrientation: HorizontalPinNameOrientation = .inLine
    var decoration = HorizontalSymbolPinDecoration()
    /// The file spelled this with the pre-`name_orientation` flag; kept so an
    /// untouched pin writes back the same way.
    var usesLegacyKeepHorizontal = false

    init(
        id: String,
        position: HorizontalPoint,
        length: Double = 2_500_000,
        orientation: HorizontalPinOrientation = .right,
        nameVisible: Bool = true,
        padVisible: Bool = true,
        nameOrientation: HorizontalPinNameOrientation = .inLine,
        decoration: HorizontalSymbolPinDecoration = HorizontalSymbolPinDecoration()
    ) {
        self.id = id
        self.position = position
        self.length = length
        self.orientation = orientation
        self.nameVisible = nameVisible
        self.padVisible = padVisible
        self.nameOrientation = nameOrientation
        self.decoration = decoration
    }

    init(id: String, json: JSONDictionary) throws {
        self.id = id
        position = try HorizontalPoolJSON.requiredPoint(json, "position")
        length = json.double("length") ?? 2_500_000
        orientation = HorizontalPinOrientation(rawValue: json.string("orientation") ?? "") ?? .right
        nameVisible = json.bool("name_visible") ?? true
        padVisible = json.bool("pad_visible") ?? true
        if let decoration = json.dictionary("decoration") {
            self.decoration = HorizontalSymbolPinDecoration(json: decoration)
        }
        if let keepHorizontal = json.bool("keep_horizontal") {
            usesLegacyKeepHorizontal = true
            nameOrientation = keepHorizontal ? .horizontal : .inLine
        } else if let raw = json.string("name_orientation") {
            nameOrientation = HorizontalPinNameOrientation(rawValue: raw) ?? .inLine
        }
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("position", HorizontalPoolJSON.point(position))
        builder.set("length", HorizontalPoolJSON.int(length))
        builder.set("orientation", orientation.rawValue)
        builder.set("name_visible", nameVisible, isDefault: nameVisible)
        builder.set("pad_visible", padVisible, isDefault: padVisible)
        let legacyStillValid = usesLegacyKeepHorizontal
            && (original?.bool("keep_horizontal") ?? false) == (nameOrientation == .horizontal)
            && nameOrientation != .perpendicular
        if legacyStillValid {
            // Untouched: keep the old spelling rather than rewriting it.
        } else if original?["keep_horizontal"] != nil {
            // Migrating off the legacy flag: say the orientation outright.
            builder.remove("keep_horizontal")
            builder.set("name_orientation", nameOrientation.rawValue)
        } else {
            builder.set("name_orientation", nameOrientation.rawValue, isDefault: nameOrientation == .inLine)
        }
        builder.set("decoration", decoration.json, isDefault: decoration.isDefault)
        return builder.json
    }
}

struct HorizontalPoolSymbol: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.symbol

    var uuid: String
    var name: String
    var unitID: String
    var canExpand: Bool
    var pins: [String: HorizontalSymbolPin]
    var drawing: HorizontalPoolDrawing
    /// Per-view text placements keyed like the file: `"0n"`, `"90m"`, … then
    /// text id. Files written before symbol version 1 stored mirrored
    /// placements with the wrong angle sign; those are kept as read (the
    /// file's own bytes) until the editor rewrites them, at which point the
    /// corrected values and `version: 1` go out together.
    var textPlacements: [String: [String: HorizontalPlacementTransform]]
    var textPlacementsAreLegacy: Bool
    var sourceJSON: HorizontalPreservedJSON

    init(uuid: String, name: String, unitID: String) {
        self.uuid = uuid
        self.name = name
        self.unitID = unitID
        canExpand = false
        pins = [:]
        drawing = HorizontalPoolDrawing()
        textPlacements = [:]
        textPlacementsAreLegacy = false
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        unitID = try HorizontalPoolJSON.requiredString(json, "unit")
        canExpand = json.bool("can_expand") ?? false
        var pins = [String: HorizontalSymbolPin]()
        for (id, pin) in json.dictionaryMap("pins") {
            pins[id] = try HorizontalSymbolPin(id: id, json: pin)
        }
        self.pins = pins
        drawing = try HorizontalPoolDrawing(json: json)
        var placements = [String: [String: HorizontalPlacementTransform]]()
        for (view, entries) in json.dictionaryMap("text_placements") {
            var byText = [String: HorizontalPlacementTransform]()
            for (textID, placement) in entries {
                if let transform = HorizontalPlacementTransform(json: placement as? JSONDictionary) {
                    byText[textID] = transform
                }
            }
            placements[view] = byText
        }
        textPlacements = placements
        textPlacementsAreLegacy = !placements.isEmpty && (json.int("version") ?? 0) == 0
        sourceJSON = HorizontalPreservedJSON(json)
    }

    /// Upstream's reading of the placements: a version-0 file's mirrored
    /// placements have their angle negated.
    var correctedTextPlacements: [String: [String: HorizontalPlacementTransform]] {
        guard textPlacementsAreLegacy else {
            return textPlacements
        }
        return textPlacements.mapValues { entries in
            entries.mapValues { placement in
                placement.mirrored
                    ? HorizontalPlacementTransform(shift: placement.shift, angle: -placement.angle, mirrored: true)
                    : placement
            }
        }
    }

    /// `Symbol::get_required_version`: 1 once text placements exist — unless
    /// they are still the uncorrected legacy ones the file came with.
    var requiredVersion: Int {
        !textPlacements.isEmpty && !textPlacementsAreLegacy ? 1 : 0
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("type", "symbol")
        builder.set("name", name)
        builder.set("uuid", uuid)
        builder.set("unit", unitID)
        builder.set("can_expand", canExpand, isDefault: !canExpand)
        builder.set("version", requiredVersion, when: requiredVersion > 0)
        drawing.apply(to: &builder)
        builder.setMap("pins", pins) { $0.json(original: $1) }
        var placementsJSON = JSONDictionary()
        for (view, entries) in textPlacements {
            var viewJSON = JSONDictionary()
            for (textID, placement) in entries {
                viewJSON[textID] = HorizontalPoolJSON.placement(placement)
            }
            placementsJSON[view] = viewJSON
        }
        builder.set("text_placements", placementsJSON, isDefault: textPlacements.isEmpty)
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
        return issues
    }
}
