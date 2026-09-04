import Foundation

/// A package pad: a placed pool padstack with its own parameter overrides.
struct HorizontalPad: Identifiable, Hashable {
    var id: String
    var name: String
    /// The POOL padstack's uuid (never an expanded copy), casing as read.
    var padstackID: String
    var placement: HorizontalPlacementTransform
    var parameterSet: [String: Int]
    var parametersFixed: [String]

    init(
        id: String,
        name: String,
        padstackID: String,
        placement: HorizontalPlacementTransform = .identity,
        parameterSet: [String: Int] = [:],
        parametersFixed: [String] = []
    ) {
        self.id = id
        self.name = name
        self.padstackID = padstackID
        self.placement = placement
        self.parameterSet = parameterSet
        self.parametersFixed = parametersFixed
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            name: json.string("name") ?? "",
            padstackID: try HorizontalPoolJSON.requiredString(json, "padstack"),
            placement: try HorizontalPoolJSON.placement(json),
            parameterSet: HorizontalPoolJSON.parameterSet(json.dictionary("parameter_set")),
            parametersFixed: HorizontalPoolJSON.stringArray(json, "parameters_fixed")
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("padstack", padstackID)
        builder.set("placement", HorizontalPoolJSON.placement(placement))
        builder.set("name", name)
        builder.set("parameter_set", HorizontalPoolJSON.parameterSetJSON(parameterSet), isDefault: parameterSet.isEmpty)
        builder.set("parameters_fixed", parametersFixed, when: !parametersFixed.isEmpty)
        return builder.json
    }
}

struct HorizontalPackageModel3D: Identifiable, Hashable {
    var id: String
    var filename: String
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var roll: Int = 0
    var pitch: Int = 0
    var yaw: Int = 0
    var heightTop: Double = 0
    var heightBottom: Double = 0

    init(id: String, filename: String) {
        self.id = id
        self.filename = filename
    }

    init(id: String, json: JSONDictionary) throws {
        self.id = id
        filename = try HorizontalPoolJSON.requiredString(json, "filename")
        x = json.double("x") ?? 0
        y = json.double("y") ?? 0
        z = json.double("z") ?? 0
        roll = json.int("roll") ?? 0
        pitch = json.int("pitch") ?? 0
        yaw = json.int("yaw") ?? 0
        heightTop = json.double("height_top") ?? 0
        heightBottom = json.double("height_bot") ?? 0
    }

    var hasHeights: Bool {
        heightTop != 0 || heightBottom != 0
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("filename", filename)
        builder.set("x", HorizontalPoolJSON.int(x))
        builder.set("y", HorizontalPoolJSON.int(y))
        builder.set("z", HorizontalPoolJSON.int(z))
        builder.set("roll", roll)
        builder.set("pitch", pitch)
        builder.set("yaw", yaw)
        builder.set("height_top", HorizontalPoolJSON.int(heightTop), when: hasHeights)
        builder.set("height_bot", HorizontalPoolJSON.int(heightBottom), when: hasHeights)
        return builder.json
    }
}

struct HorizontalPoolKeepout: Identifiable, Hashable {
    var id: String
    var polygonID: String
    var keepoutClass: String
    var exposedCopperOnly: Bool
    var allCopperLayers: Bool
    var copperPatchTypes: [String]

    init(
        id: String,
        polygonID: String,
        keepoutClass: String = "",
        exposedCopperOnly: Bool = false,
        allCopperLayers: Bool = false,
        copperPatchTypes: [String] = ["hole_pth", "pad", "pad_th", "plane", "track", "via"]
    ) {
        self.id = id
        self.polygonID = polygonID
        self.keepoutClass = keepoutClass
        self.exposedCopperOnly = exposedCopperOnly
        self.allCopperLayers = allCopperLayers
        self.copperPatchTypes = copperPatchTypes
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            polygonID: try HorizontalPoolJSON.requiredString(json, "polygon"),
            keepoutClass: json.string("keepout_class") ?? "",
            exposedCopperOnly: json.bool("exposed_cu_only") ?? false,
            allCopperLayers: json.bool("all_cu_layers") ?? false,
            copperPatchTypes: HorizontalPoolJSON.stringArray(json, "patch_types_cu")
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("polygon", polygonID)
        builder.set("keepout_class", keepoutClass)
        builder.set("exposed_cu_only", exposedCopperOnly)
        builder.set("all_cu_layers", allCopperLayers)
        builder.set("patch_types_cu", copperPatchTypes)
        return builder.json
    }
}

struct HorizontalPoolDimension: Identifiable, Hashable {
    var id: String
    var p0: HorizontalPoint
    var p1: HorizontalPoint
    var labelDistance: Double
    var labelSize: Double
    var mode: HorizontalDimensionMode

    init(
        id: String,
        p0: HorizontalPoint,
        p1: HorizontalPoint,
        labelDistance: Double = 0,
        labelSize: Double = 1_500_000,
        mode: HorizontalDimensionMode = .distance
    ) {
        self.id = id
        self.p0 = p0
        self.p1 = p1
        self.labelDistance = labelDistance
        self.labelSize = labelSize
        self.mode = mode
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            p0: try HorizontalPoolJSON.requiredPoint(json, "p0"),
            p1: try HorizontalPoolJSON.requiredPoint(json, "p1"),
            labelDistance: json.double("label_distance") ?? 0,
            labelSize: json.double("label_size") ?? 1_500_000,
            mode: HorizontalDimensionMode(rawValue: json.string("mode") ?? "") ?? .distance
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("p0", HorizontalPoolJSON.point(p0))
        builder.set("p1", HorizontalPoolJSON.point(p1))
        builder.set("label_distance", HorizontalPoolJSON.int(labelDistance))
        builder.set("label_size", HorizontalPoolJSON.int(labelSize))
        builder.set("mode", mode.rawValue)
        return builder.json
    }
}

struct HorizontalPoolPackage: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.package

    var uuid: String
    var name: String
    var manufacturer: String
    var tags: [String]
    var parameterProgram: String
    var parameterSet: [String: Int]
    var parametersFixed: [String]
    var alternateForID: String?
    var models: [String: HorizontalPackageModel3D]
    var defaultModelID: String
    var drawing: HorizontalPoolDrawing
    var pads: [String: HorizontalPad]
    var keepouts: [String: HorizontalPoolKeepout]
    var dimensions: [String: HorizontalPoolDimension]
    var sourceJSON: HorizontalPreservedJSON

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
        manufacturer = ""
        tags = []
        parameterProgram = ""
        parameterSet = [:]
        parametersFixed = []
        alternateForID = nil
        models = [:]
        defaultModelID = ""
        drawing = HorizontalPoolDrawing()
        pads = [:]
        keepouts = [:]
        dimensions = [:]
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        manufacturer = json.string("manufacturer") ?? ""
        tags = HorizontalPoolJSON.stringArray(json, "tags")
        parameterProgram = json.string("parameter_program") ?? ""
        parameterSet = HorizontalPoolJSON.parameterSet(json.dictionary("parameter_set"))
        parametersFixed = HorizontalPoolJSON.stringArray(json, "parameters_fixed")
        alternateForID = json.string("alternate_for")
        var models = [String: HorizontalPackageModel3D]()
        for (id, model) in json.dictionaryMap("models") {
            models[id] = try HorizontalPackageModel3D(id: id, json: model)
        }
        self.models = models
        defaultModelID = json.string("default_model") ?? ""
        drawing = try HorizontalPoolDrawing(json: json)
        var pads = [String: HorizontalPad]()
        for (id, pad) in json.dictionaryMap("pads") {
            pads[id] = try HorizontalPad(id: id, json: pad)
        }
        self.pads = pads
        var keepouts = [String: HorizontalPoolKeepout]()
        for (id, keepout) in json.dictionaryMap("keepouts") {
            keepouts[id] = try HorizontalPoolKeepout(id: id, json: keepout)
        }
        self.keepouts = keepouts
        var dimensions = [String: HorizontalPoolDimension]()
        for (id, dimension) in json.dictionaryMap("dimensions") {
            dimensions[id] = try HorizontalPoolDimension(id: id, json: dimension)
        }
        self.dimensions = dimensions
        sourceJSON = HorizontalPreservedJSON(json)
    }

    /// Pads in upstream's order: natural sort on the name.
    var sortedPads: [HorizontalPad] {
        pads.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Upstream's `Package::get_max_pad_name` + `ToolPlacePad`: "1" for the
    /// first pad, else the largest numeric name plus one, else unnamed.
    func nextPadName() -> String {
        Self.nextPadName(among: Array(pads.values))
    }

    static func nextPadName(among pads: [HorizontalPad]) -> String {
        if pads.isEmpty {
            return "1"
        }
        let maximum = pads.compactMap { Int($0.name) }.max() ?? 0
        return maximum > 0 ? String(maximum + 1) : ""
    }

    /// `Package::get_required_version`: 2 with model heights, 1 with any
    /// fixed parameter on the package or a pad.
    var requiredVersion: Int {
        if models.values.contains(where: \.hasHeights) {
            return 2
        }
        if !parametersFixed.isEmpty || pads.values.contains(where: { !$0.parametersFixed.isEmpty }) {
            return 1
        }
        return 0
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("version", requiredVersion, when: requiredVersion > 0)
        builder.set("uuid", uuid)
        builder.set("type", "package")
        builder.set("name", name)
        builder.set("manufacturer", manufacturer, isDefault: manufacturer.isEmpty)
        builder.set("tags", tags, isDefault: tags.isEmpty)
        builder.set("parameter_program", parameterProgram, isDefault: parameterProgram.isEmpty)
        builder.set("parameter_set", HorizontalPoolJSON.parameterSetJSON(parameterSet), isDefault: parameterSet.isEmpty)
        builder.set("parameters_fixed", parametersFixed, when: !parametersFixed.isEmpty)
        builder.set("alternate_for", alternateForID ?? "", when: alternateForID != nil && alternateForID != uuid)
        let hasModels = !models.isEmpty || !defaultModelID.isEmpty
        builder.setMap("models", models, isDefault: !hasModels) { $0.json(original: $1) }
        builder.set("default_model", defaultModelID, isDefault: !hasModels)
        drawing.apply(to: &builder)
        builder.setMap("pads", pads) { $0.json(original: $1) }
        builder.setMap("keepouts", keepouts, isDefault: true) { $0.json(original: $1) }
        builder.setMap("dimensions", dimensions, isDefault: true) { $0.json(original: $1) }
        // `pictures`, `rules`, `grid_settings` and Horizon's `_imp` window
        // state are not modelled and ride along from the source.
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
        for tag in tags {
            issues += HorizontalPoolChecks.tagIssues(tag)
        }
        var padNames = Set<String>()
        for pad in sortedPads {
            if padNames.contains(pad.name) {
                issues.append(.failure("Pad name \"\(pad.name)\" not unique"))
            }
            padNames.insert(pad.name)
        }
        return issues
    }
}
