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
        let prefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        if url.path.hasPrefix(prefix) {
            return archive.regularFileData(relativePath: String(url.path.dropFirst(prefix.count)))
        }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = baseURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard path.hasPrefix(base) else { return nil }
        return archive.regularFileData(relativePath: String(path.dropFirst(base.count)))
    }

    func json(at url: URL) -> JSONDictionary? {
        data(at: url).flatMap { try? JSONHelper.loadDictionary(from: $0) }
    }

    func jsonFiles(under url: URL) -> [URL] {
        files.map { baseURL.appendingPathComponent($0) }.filter {
            $0.path.hasPrefix(url.standardizedFileURL.path + "/") && $0.pathExtension == "json"
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
