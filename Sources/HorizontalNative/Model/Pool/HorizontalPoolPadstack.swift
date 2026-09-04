import Foundation

enum HorizontalPadstackType: String, CaseIterable, Hashable {
    case top
    case bottom
    case through
    case via
    case hole
    case mechanical

    var displayName: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .through: "Through"
        case .via: "Via"
        case .hole: "Hole"
        case .mechanical: "Mechanical"
        }
    }
}

enum HorizontalPadstackShapeForm: String, CaseIterable, Hashable {
    case circle
    case rectangle
    case obround

    var displayName: String {
        switch self {
        case .circle: "Circle"
        case .rectangle: "Rectangle"
        case .obround: "Obround"
        }
    }
}

/// A padstack shape: a primitive placed on one layer. `params` is `[d]` for a
/// circle and `[w, h]` otherwise, in nanometres.
struct HorizontalPadstackShape: Identifiable, Hashable {
    var id: String
    var form: HorizontalPadstackShapeForm
    var params: [Double]
    var placement: HorizontalPlacementTransform
    var layer: Int
    var parameterClass: String

    init(
        id: String,
        form: HorizontalPadstackShapeForm,
        params: [Double],
        placement: HorizontalPlacementTransform = .identity,
        layer: Int = 0,
        parameterClass: String = ""
    ) {
        self.id = id
        self.form = form
        self.params = params
        self.placement = placement
        self.layer = layer
        self.parameterClass = parameterClass
    }

    init(id: String, json: JSONDictionary) throws {
        guard let form = HorizontalPadstackShapeForm(rawValue: json.string("form") ?? "") else {
            throw HorizontalPoolModelError.missingKey("form")
        }
        self.init(
            id: id,
            form: form,
            params: json.doubleArray("params"),
            placement: try HorizontalPoolJSON.placement(json),
            layer: json.int("layer") ?? 0,
            parameterClass: json.string("parameter_class") ?? ""
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("placement", HorizontalPoolJSON.placement(placement))
        builder.set("layer", layer)
        builder.set("form", form.rawValue)
        builder.set("params", params.map(HorizontalPoolJSON.int))
        builder.set("parameter_class", parameterClass)
        return builder.json
    }
}

struct HorizontalPadstackHole: Identifiable, Hashable {
    var id: String
    var placement: HorizontalPlacementTransform
    var diameter: Double
    var length: Double
    var shape: HorizontalHoleShape
    var plated: Bool
    var parameterClass: String
    /// A partial-span hole's `span`, kept as the file spells it.
    var span: HorizontalPreservedJSON?

    init(
        id: String,
        placement: HorizontalPlacementTransform = .identity,
        diameter: Double,
        length: Double = 0,
        shape: HorizontalHoleShape = .round,
        plated: Bool = false,
        parameterClass: String = ""
    ) {
        self.id = id
        self.placement = placement
        self.diameter = diameter
        self.length = length
        self.shape = shape
        self.plated = plated
        self.parameterClass = parameterClass
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            placement: try HorizontalPoolJSON.placement(json),
            diameter: json.double("diameter") ?? 0,
            length: json.double("length") ?? 0,
            shape: HorizontalHoleShape(rawValue: json.string("shape") ?? "") ?? .round,
            plated: json.bool("plated") ?? false,
            parameterClass: json.string("parameter_class") ?? ""
        )
        if let span = json.dictionary("span") {
            self.span = HorizontalPreservedJSON(span)
        }
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("placement", HorizontalPoolJSON.placement(placement))
        builder.set("diameter", HorizontalPoolJSON.int(diameter))
        builder.set("length", HorizontalPoolJSON.int(length))
        builder.set("shape", shape.rawValue)
        builder.set("plated", plated)
        builder.set("parameter_class", parameterClass)
        if let span {
            builder.set("span", span.dictionary)
        } else {
            builder.remove("span")
        }
        return builder.json
    }
}

struct HorizontalPoolPadstack: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.padstack

    var uuid: String
    var name: String
    var wellKnownName: String
    var type: HorizontalPadstackType
    var parameterProgram: String
    var parameterSet: [String: Int]
    var parametersRequired: [String]
    var polygons: [String: HorizontalPoolPolygon]
    var holes: [String: HorizontalPadstackHole]
    var shapes: [String: HorizontalPadstackShape]
    var sourceJSON: HorizontalPreservedJSON

    init(uuid: String, name: String, type: HorizontalPadstackType = .top) {
        self.uuid = uuid
        self.name = name
        wellKnownName = ""
        self.type = type
        parameterProgram = ""
        parameterSet = [:]
        parametersRequired = []
        polygons = [:]
        holes = [:]
        shapes = [:]
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        wellKnownName = json.string("well_known_name") ?? ""
        type = HorizontalPadstackType(rawValue: json.string("padstack_type") ?? "") ?? .top
        parameterProgram = json.string("parameter_program") ?? ""
        parameterSet = HorizontalPoolJSON.parameterSet(json.dictionary("parameter_set"))
        parametersRequired = HorizontalPoolJSON.stringArray(json, "parameters_required")
        var polygons = [String: HorizontalPoolPolygon]()
        for (id, polygon) in json.dictionaryMap("polygons") {
            let parsed = HorizontalPoolPolygon(id: id, json: polygon)
            if !parsed.vertices.isEmpty {
                polygons[id] = parsed
            }
        }
        self.polygons = polygons
        var holes = [String: HorizontalPadstackHole]()
        for (id, hole) in json.dictionaryMap("holes") {
            holes[id] = try HorizontalPadstackHole(id: id, json: hole)
        }
        self.holes = holes
        var shapes = [String: HorizontalPadstackShape]()
        for (id, shape) in json.dictionaryMap("shapes") {
            shapes[id] = try HorizontalPadstackShape(id: id, json: shape)
        }
        self.shapes = shapes
        sourceJSON = HorizontalPreservedJSON(json)
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("uuid", uuid)
        builder.set("type", "padstack")
        builder.set("name", name)
        builder.set("well_known_name", wellKnownName, isDefault: wellKnownName.isEmpty)
        builder.set("padstack_type", type.rawValue)
        builder.set("parameter_program", parameterProgram, isDefault: parameterProgram.isEmpty)
        builder.set("parameter_set", HorizontalPoolJSON.parameterSetJSON(parameterSet), isDefault: parameterSet.isEmpty)
        builder.setMap("polygons", polygons) { $0.json(original: $1) }
        builder.setMap("holes", holes) { $0.json(original: $1) }
        builder.setMap("shapes", shapes, isDefault: true) { $0.json(original: $1) }
        builder.set("parameters_required", parametersRequired, isDefault: parametersRequired.isEmpty)
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
