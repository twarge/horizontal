import Foundation
import HorizontalProjectIO

/// The archive is the authoritative byte source for an open dispatch context.
/// Materialization is private and retained while renderers/loaders use its URLs.
final class HorizontalDispatchSnapshot {
    let archive: HorizontalProjectArchive
    let id: String
    let baseURL: URL
    let files: [String]
    private var temporaryURL: URL?
    private var cachedProject: HorizontalProject?

    init(archive: HorizontalProjectArchive, baseURL: URL) {
        self.archive = archive
        self.baseURL = baseURL
        files = archive.regularFilePaths.sorted()
        var record = Data("horizontal-snapshot-v1\n".utf8)
        for path in files {
            record.append(Data("\(path.utf8.count):\(path):".utf8))
            record.append(Data(HorizontalProjectTransaction.digest(archive.regularFileData(relativePath: path) ?? Data()).utf8))
            record.append(10)
        }
        // Include link identities even though loaders reject uncaptured links.
        func recordLinks(_ node: HorizontalProjectArchiveNode, path: String) {
            switch node {
            case .directory(let children):
                for name in children.keys.sorted() { recordLinks(children[name]!, path: path + "/" + name) }
            case .symbolicLink(let target):
                record.append(Data("link:\(path.utf8.count):\(path):\(target.utf8.count):\(target)\n".utf8))
            case .regularFile: break
            }
        }
        recordLinks(archive.root, path: "")
        id = HorizontalProjectTransaction.digest(record)
    }

    deinit { if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }

    func data(at url: URL) -> Data? {
        guard let path = relativePath(for: url) else { return nil }
        return archive.regularFileData(relativePath: path)
    }

    func json(at url: URL) -> JSONDictionary? {
        data(at: url).flatMap { try? JSONHelper.loadDictionary(from: $0) }
    }

    func jsonFiles(under url: URL) -> [URL] {
        guard let directory = relativePath(for: url) else { return [] }
        let prefix = directory.isEmpty ? "" : directory + "/"
        return files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .map { baseURL.appendingPathComponent($0) }
    }

    private func relativePath(for url: URL) -> String? {
        let base = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }

        // Unsaved imports can introduce directories that do not exist on disk.
        // Resolve the ancestors as well: Foundation may leave an entire missing
        // path unresolved, including aliases such as /tmp versus /private/tmp.
        let canonicalBase = baseURL.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalPrefix = canonicalBase.hasSuffix("/") ? canonicalBase : canonicalBase + "/"
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while true {
            let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == canonicalBase { return suffix.reversed().joined(separator: "/") }
            if resolved.hasPrefix(canonicalPrefix) {
                return ([String(resolved.dropFirst(canonicalPrefix.count))] + suffix.reversed()).joined(separator: "/")
            }
            guard ancestor.path != "/" else { return nil }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }

    func materializedProject() throws -> HorizontalProject {
        if let cachedProject { return cachedProject }
        guard archive.symbolicLinkCount == 0 else {
            throw HorizontalDispatchError.unsupported("Snapshot has symbolic links; resolve dependencies before analysis or rendering.")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-snapshot-\(UUID().uuidString)")
        temporaryURL = temp
        let url = temp.appendingPathComponent("Snapshot.horizontal")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try archive.write(to: url)
        let project = try HorizontalProject.load(from: url)
        cachedProject = project
        return project
    }

    static func capture(url: URL) throws -> HorizontalDispatchSnapshot {
        let manifest = try HorizontalProjectManifest.discover(from: url)
        guard manifest.externalReferences.isEmpty else {
            throw HorizontalDispatchError.unsupported("External project dependencies must be copied into the project before opening a reproducible snapshot.")
        }
        return HorizontalDispatchSnapshot(archive: try .completeProject(from: url), baseURL: manifest.baseURL)
    }
}
