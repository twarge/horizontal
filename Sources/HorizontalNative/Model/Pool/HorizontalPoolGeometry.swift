import Foundation

/// The drawing primitives shared by every canvas-shaped pool item (symbol,
/// frame, package, decal), mirroring Horizon's JSON one to one: lines and
/// arcs reference junctions BY ID, not by position, exactly as the file does.
/// The canvas projections resolve ids to positions on the way in and
/// regenerate junctions by position on the way out.

struct HorizontalPoolLine: Identifiable, Hashable {
    var id: String
    var from: String
    var to: String
    var width: Double
    var layer: Int

    init(id: String, from: String, to: String, width: Double = 0, layer: Int = 0) {
        self.id = id
        self.from = from
        self.to = to
        self.width = width
        self.layer = layer
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            from: try HorizontalPoolJSON.requiredString(json, "from"),
            to: try HorizontalPoolJSON.requiredString(json, "to"),
            width: json.double("width") ?? 0,
            layer: json.int("layer") ?? 0
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("from", from)
        builder.set("to", to)
        builder.set("width", HorizontalPoolJSON.int(width), isDefault: width == 0)
        builder.set("layer", layer, isDefault: layer == 0)
        return builder.json
    }
}

struct HorizontalPoolArc: Identifiable, Hashable {
    var id: String
    var from: String
    var to: String
    var center: String
    var width: Double
    var layer: Int

    init(id: String, from: String, to: String, center: String, width: Double = 0, layer: Int = 0) {
        self.id = id
        self.from = from
        self.to = to
        self.center = center
        self.width = width
        self.layer = layer
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            from: try HorizontalPoolJSON.requiredString(json, "from"),
            to: try HorizontalPoolJSON.requiredString(json, "to"),
            center: try HorizontalPoolJSON.requiredString(json, "center"),
            width: json.double("width") ?? 0,
            layer: json.int("layer") ?? 0
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("from", from)
        builder.set("to", to)
        builder.set("center", center)
        builder.set("width", HorizontalPoolJSON.int(width), isDefault: width == 0)
        builder.set("layer", layer, isDefault: layer == 0)
        return builder.json
    }
}

struct HorizontalPoolPolygon: Identifiable, Hashable {
    var id: String
    var layer: Int
    var parameterClass: String
    var vertices: [HorizontalPolygonVertex]

    init(id: String, layer: Int = 0, parameterClass: String = "", vertices: [HorizontalPolygonVertex]) {
        self.id = id
        self.layer = layer
        self.parameterClass = parameterClass
        self.vertices = vertices
    }

    init(id: String, json: JSONDictionary) {
        self.init(
            id: id,
            layer: json.int("layer") ?? 0,
            parameterClass: json.string("parameter_class") ?? "",
            vertices: json.dictionaryArray("vertices").compactMap(HorizontalPolygonVertex.init)
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("layer", layer)
        builder.set("parameter_class", parameterClass)
        builder.set("vertices", vertices.map(Self.vertexJSON))
        return builder.json
    }

    static func vertexJSON(_ vertex: HorizontalPolygonVertex) -> JSONDictionary {
        [
            "type": vertex.type.rawValue,
            "position": HorizontalPoolJSON.point(vertex.position),
            "arc_center": HorizontalPoolJSON.point(vertex.arcCenter),
            "arc_reverse": vertex.arcReverse,
        ]
    }
}

struct HorizontalPoolText: Identifiable, Hashable {
    var id: String
    var text: String
    var placement: HorizontalPlacementTransform
    var size: Double
    var width: Double
    var layer: Int
    var origin: HorizontalTextOrigin
    var font: HorizontalTextFont
    var allowUpsideDown: Bool
    var fromSmash: Bool

    init(
        id: String,
        text: String,
        placement: HorizontalPlacementTransform,
        size: Double = 1_500_000,
        width: Double = 0,
        layer: Int = 0,
        origin: HorizontalTextOrigin = .baseline,
        font: HorizontalTextFont = .simplex,
        allowUpsideDown: Bool = false,
        fromSmash: Bool = false
    ) {
        self.id = id
        self.text = text
        self.placement = placement
        self.size = size
        self.width = width
        self.layer = layer
        self.origin = origin
        self.font = font
        self.allowUpsideDown = allowUpsideDown
        self.fromSmash = fromSmash
    }

    init(id: String, json: JSONDictionary) throws {
        self.init(
            id: id,
            text: try HorizontalPoolJSON.requiredString(json, "text"),
            placement: try HorizontalPoolJSON.placement(json),
            size: json.double("size") ?? 2_500_000,
            width: json.double("width") ?? 0,
            layer: json.int("layer") ?? 0,
            origin: HorizontalTextOrigin(rawValue: json.string("origin") ?? "") ?? .baseline,
            font: HorizontalTextFont(rawValue: json.string("font") ?? "") ?? .simplex,
            allowUpsideDown: json.bool("allow_upside_down") ?? false,
            fromSmash: json.bool("from_smash") ?? false
        )
    }

    func json(original: JSONDictionary?) -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: original)
        builder.set("origin", origin.rawValue)
        builder.set("font", font.rawValue, isDefault: font == .simplex)
        builder.set("text", text)
        builder.set("size", HorizontalPoolJSON.int(size))
        builder.set("width", HorizontalPoolJSON.int(width), isDefault: width == 0)
        builder.set("layer", layer, isDefault: layer == 0)
        builder.set("from_smash", fromSmash, isDefault: !fromSmash)
        builder.set("placement", HorizontalPoolJSON.placement(placement))
        builder.set("allow_upside_down", true, when: allowUpsideDown)
        return builder.json
    }
}

/// The junction/line/arc/polygon/text set every canvas-shaped item carries.
struct HorizontalPoolDrawing: Hashable {
    var junctions: [String: HorizontalPoint] = [:]
    var lines: [String: HorizontalPoolLine] = [:]
    var arcs: [String: HorizontalPoolArc] = [:]
    var polygons: [String: HorizontalPoolPolygon] = [:]
    var texts: [String: HorizontalPoolText] = [:]

    init() {}

    init(json: JSONDictionary) throws {
        for (id, junction) in json.dictionaryMap("junctions") {
            junctions[id] = try HorizontalPoolJSON.requiredPoint(junction, "position")
        }
        for (id, line) in json.dictionaryMap("lines") {
            lines[id] = try HorizontalPoolLine(id: id, json: line)
        }
        for (id, arc) in json.dictionaryMap("arcs") {
            arcs[id] = try HorizontalPoolArc(id: id, json: arc)
        }
        // Upstream drops vertex-less polygons on load, and so does every
        // re-save of the file.
        for (id, polygon) in json.dictionaryMap("polygons") {
            let parsed = HorizontalPoolPolygon(id: id, json: polygon)
            if !parsed.vertices.isEmpty {
                polygons[id] = parsed
            }
        }
        for (id, text) in json.dictionaryMap("texts") {
            texts[id] = try HorizontalPoolText(id: id, json: text)
        }
    }

    /// Writes the five maps. Every kind's serializer emits all of them, but
    /// older files omit the ones that were empty, so empty maps only appear
    /// where the source had them.
    func apply(to builder: inout HorizontalPoolJSONBuilder) {
        builder.setMap("junctions", junctions, isDefault: true) { position, original in
            var entry = HorizontalPoolJSONBuilder(original: original)
            entry.set("position", HorizontalPoolJSON.point(position))
            return entry.json
        }
        builder.setMap("lines", lines, isDefault: true) { $0.json(original: $1) }
        builder.setMap("arcs", arcs, isDefault: true) { $0.json(original: $1) }
        builder.setMap("polygons", polygons, isDefault: true) { $0.json(original: $1) }
        builder.setMap("texts", texts, isDefault: true) { $0.json(original: $1) }
    }

    /// Every coordinate, for bounds.
    var points: [HorizontalPoint] {
        Array(junctions.values)
            + polygons.values.flatMap { $0.vertices.map(\.position) }
            + texts.values.map(\.placement.shift)
    }
}
