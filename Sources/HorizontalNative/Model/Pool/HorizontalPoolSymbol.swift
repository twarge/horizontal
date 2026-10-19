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
        validationIssues(unit: nil)
    }

    /// Upstream's item checks, then its symbol rules check
    /// (`SymbolRules::check_symbol`): one `$REFDES` and one `$VALUE`, 1.5 mm
    /// with no line width, at one x and mirrored y with the refdes above; in
    /// a box symbol, 1.25 mm clear of the box; pins on the 1.25 mm grid,
    /// apart, on the rectangle the pins span and pointing out of it; every
    /// unit pin placed; no junction joined to nothing. And one of this app's
    /// own: a pin pointing up or down keeps its name horizontal. Without the
    /// unit, pins go by uuid and the unplaced-pin check is skipped.
    func validationIssues(unit: HorizontalPoolUnit?) -> [HorizontalPoolCheckIssue] {
        var issues = [HorizontalPoolCheckIssue]()
        if name.isEmpty {
            issues.append(.failure("Name must not be empty"))
        }
        if name.horizonNeedsTrim {
            issues.append(.failure("Name has trailing/leading whitespace"))
        }
        func nm(_ value: Double) -> Int64 { Int64(value.rounded()) }
        func pinName(_ id: String) -> String {
            unit?.pins.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }?.value.primaryName ?? id
        }

        // Reference designator and value texts.
        let refdes = drawing.texts.values.filter { $0.text == "$REFDES" }
        let value = drawing.texts.values.filter { $0.text == "$VALUE" }
        if refdes.count != 1 {
            issues.append(.failure("Symbol has \(refdes.count) reference designators, need 1"))
        }
        if value.count != 1 {
            issues.append(.failure("Symbol has \(value.count) values, need 1"))
        }
        for (texts, label) in [(refdes, "Refdes"), (value, "Value")] {
            if let text = texts.first, text.width != 0 || nm(text.size) != 1_500_000 {
                issues.append(.failure("\(label) text must have 0 line width and 1.5mm size"))
            }
        }
        let refdesText = refdes.count == 1 ? refdes.first : nil, valueText = value.count == 1 ? value.first : nil
        if let refdesText, let valueText {
            let r = refdesText.placement.shift, v = valueText.placement.shift
            if nm(r.x) != nm(v.x) {
                issues.append(.warning("Refdes and value text should be at same X position"))
            }
            if nm(r.y) != -nm(v.y) {
                issues.append(.warning("Refdes and value text should be at mirrored Y position"))
            }
            if nm(v.y) > nm(r.y) {
                issues.append(.warning("Refdes should be above value"))
            }
        }
        // A box symbol: junctions at all four corners of what they span.
        let junctionPoints = Set(drawing.junctions.values.map { [nm($0.x), nm($0.y)] })
        let box = junctionPoints.reduce(into: [Int64(0), Int64(0)]) { $0 = [max($0[0], abs($1[0])), max($0[1], abs($1[1]))] }
        let isBox = [[1, 1], [1, -1], [-1, 1], [-1, -1]].allSatisfy { junctionPoints.contains([box[0] * $0[0], box[1] * $0[1]]) }
        if isBox {
            let spacing: Int64 = 1_250_000
            if let refdesText, nm(refdesText.placement.shift.y) != box[1] + spacing {
                issues.append(.warning("Refdes should be 1.25mm above symbol box", at: refdesText.placement.shift))
            }
            if let valueText, nm(valueText.placement.shift.y) != -box[1] - spacing {
                issues.append(.warning("Value should be 1.25mm below symbol box", at: valueText.placement.shift))
            }
        }

        // Pins.
        let grid: Int64 = 1_250_000
        let ordered = pins.values.sorted { (pinName($0.id), $0.id) < (pinName($1.id), $1.id) }
        var bounds = [Int64(0), Int64(0)]
        var byPosition = [[Int64]: [String]]()
        for pin in ordered {
            let p = [nm(pin.position.x), nm(pin.position.y)]
            let residual = [p[0] % grid, p[1] % grid]
            if residual != [0, 0] {
                issues.append(.failure("Pin \(pinName(pin.id)) is off-grid, residual: \(Self.millimetres(residual[0])), \(Self.millimetres(residual[1]))",
                                       at: pin.position))
            }
            bounds = [max(bounds[0], abs(p[0])), max(bounds[1], abs(p[1]))]
            byPosition[p, default: []].append(pinName(pin.id))
        }
        for (position, names) in byPosition.sorted(by: { $0.value.first ?? "" < $1.value.first ?? "" }) where names.count > 1 {
            issues.append(.failure("Overlapping pins: \(names.joined(separator: ", "))",
                                   at: HorizontalPoint(x: Double(position[0]), y: Double(position[1]))))
        }
        for pin in ordered {
            let p = [nm(pin.position.x), nm(pin.position.y)]
            var outward = Set<HorizontalPinOrientation>()
            if p[0] == bounds[0] { outward.insert(.right) }
            if p[0] == -bounds[0] { outward.insert(.left) }
            if p[1] == bounds[1] { outward.insert(.up) }
            if p[1] == -bounds[1] { outward.insert(.down) }
            if outward.isEmpty {
                issues.append(.warning("Pin \(pinName(pin.id)) is not on bounding box", at: pin.position))
            } else if !outward.contains(pin.orientation) {
                issues.append(.warning("Pin \(pinName(pin.id)) has improper orientation", at: pin.position))
            }
            if [.up, .down].contains(pin.orientation), pin.nameVisible, pin.nameOrientation != .horizontal {
                issues.append(.warning("Pin \(pinName(pin.id)) points \(pin.orientation.rawValue); its name should be horizontal",
                                       at: pin.position))
            }
        }
        if let unit {
            let placed = Set(pins.keys.map { $0.lowercased() })
            for pin in unit.pins.values.sorted(by: { $0.primaryName < $1.primaryName }) where !placed.contains(pin.id.lowercased()) {
                issues.append(.failure("Pin \(pin.primaryName) is not placed"))
            }
        }

        // Junctions joined to nothing.
        var attached = Set<String>()
        for line in drawing.lines.values { attached.formUnion([line.from, line.to].map { $0.lowercased() }) }
        for arc in drawing.arcs.values { attached.formUnion([arc.from, arc.to, arc.center].map { $0.lowercased() }) }
        for (id, position) in drawing.junctions.sorted(by: { $0.key < $1.key }) where !attached.contains(id.lowercased()) {
            issues.append(.warning("Junction has no connections", at: position))
        }
        return issues
    }

    /// A length in nanometres as upstream's checks print it, in millimetres.
    private static func millimetres(_ value: Int64) -> String {
        let text = String(format: "%.3f", Double(value) / 1_000_000)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(text == "-0" ? "0" : text) mm"
    }
}
