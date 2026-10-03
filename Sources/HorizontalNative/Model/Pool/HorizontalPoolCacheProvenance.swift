import Foundation
import HorizontalProjectIO

/// Horizontal-owned metadata; Horizon's cached item JSON stays unchanged.
struct HorizontalPoolCacheProvenance: Codable, Sendable {
    struct Origin: Codable, Sendable {
        var poolUUID: String
        var sourcePath: String
        var baseline: String
    }

    static let path = ".horizontal/pool-cache.json"
    var version = 1
    var files: [String: Origin] = [:]

    static func load(_ data: Data?) throws -> Self {
        guard let data else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else {
            throw HorizontalDispatchError.unsupported("Unknown project-library metadata version.")
        }
        return value
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    static func digest(_ data: Data, path: String) throws -> String {
        guard path.lowercased().hasSuffix(".json") else {
            return HorizontalProjectTransaction.digest(data)
        }
        var json = try JSONHelper.loadDictionary(from: data)
        json.removeValue(forKey: "_imp")
        return HorizontalProjectTransaction.digest(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    static func relativePath(_ url: URL, in root: URL) throws -> String {
        func relative(_ path: String, root: String) -> String? {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        if let path = relative(url.standardizedFileURL.path, root: root.standardizedFileURL.path) { return path }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var ancestor = url.standardizedFileURL
        var suffix = [String]()
        while ancestor.path != "/" {
            let canonical = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
            if canonical.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == canonicalRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                return suffix.reversed().joined(separator: "/")
            }
            if let path = relative(canonical, root: canonicalRoot) {
                return ([path] + suffix.reversed()).joined(separator: "/")
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        throw HorizontalDispatchError.failed("Library file is outside its pool: \(url.path)")
    }

    static func safeURL(_ path: String, in root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw HorizontalDispatchError.failed("Invalid library-relative path: \(path)")
        }
        let url = root.appendingPathComponent(path).standardizedFileURL
        _ = try relativePath(url, in: root)
        return url
    }
}
