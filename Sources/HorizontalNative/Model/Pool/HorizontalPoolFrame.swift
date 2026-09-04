import Foundation

struct HorizontalPoolFrame: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.frame

    /// Upstream's defaults: an A4 landscape page.
    static let defaultWidth = 297_000_000.0
    static let defaultHeight = 210_000_000.0

    var uuid: String
    var name: String
    var width: Double
    var height: Double
    var drawing: HorizontalPoolDrawing
    var sourceJSON: HorizontalPreservedJSON

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
        width = Self.defaultWidth
        height = Self.defaultHeight
        drawing = HorizontalPoolDrawing()
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        width = json.double("width") ?? Self.defaultWidth
        height = json.double("height") ?? Self.defaultHeight
        drawing = try HorizontalPoolDrawing(json: json)
        sourceJSON = HorizontalPreservedJSON(json)
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("type", "frame")
        builder.set("name", name)
        builder.set("uuid", uuid)
        builder.set("width", HorizontalPoolJSON.int(width))
        builder.set("height", HorizontalPoolJSON.int(height))
        drawing.apply(to: &builder)
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
        if width <= 0 || height <= 0 {
            issues.append(.failure("Width and height must be positive"))
        }
        return issues
    }
}
