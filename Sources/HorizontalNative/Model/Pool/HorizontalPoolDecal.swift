import Foundation

struct HorizontalPoolDecal: HorizontalPoolItemDocumentModel {
    static let category = HorizontalPoolItemCategory.decal

    var uuid: String
    var name: String
    var drawing: HorizontalPoolDrawing
    var sourceJSON: HorizontalPreservedJSON

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
        drawing = HorizontalPoolDrawing()
        sourceJSON = HorizontalPreservedJSON([:])
    }

    init(json: JSONDictionary) throws {
        uuid = try HorizontalPoolJSON.requiredString(json, "uuid")
        name = json.string("name") ?? ""
        drawing = try HorizontalPoolDrawing(json: json)
        sourceJSON = HorizontalPreservedJSON(json)
    }

    func json() -> JSONDictionary {
        var builder = HorizontalPoolJSONBuilder(original: sourceJSON.dictionary)
        builder.set("type", "decal")
        builder.set("name", name)
        builder.set("uuid", uuid)
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
        return issues
    }
}
