import Foundation
import HorizontalProjectIO

/// A pool item named by kind and uuid, as the design refers to it.
struct HorizontalPoolItemReference: Hashable, Sendable {
    var type: String
    var uuid: String

    init(type: String, uuid: String) {
        self.type = type
        self.uuid = uuid.lowercased()
    }
}

/// What the design refers to in its pool, read from the project's own block,
/// schematic and board files. The blocks come from the project's block list,
/// not from a `"type": "block"` key, which Horizon doesn't always write
/// (Billo's `top_block.json` has none).
enum HorizontalPoolCacheUsage {
    /// Each block file's JSON, keyed by its archive path.
    static func blocks(in archive: HorizontalProjectArchive, project: HorizontalProject) -> [String: JSONDictionary] {
        let filenames = project.blocks.compactMap(\.blockFilename) + [project.blockFilename].compactMap { $0 }
        return json(Set(filenames), in: archive)
    }

    /// The items the design refers to directly:
    /// - each component's part, or its entity when it has none;
    /// - the BOM's concrete parts;
    /// - each sheet's frame;
    /// - each board package's alternate package, each via's padstack, each
    ///   hole's padstack and each decal.
    static func roots(in archive: HorizontalProjectArchive, project: HorizontalProject) -> Set<HorizontalPoolItemReference> {
        var roots = Set<HorizontalPoolItemReference>()
        func add(_ type: String, _ uuid: String?) {
            if let uuid, !uuid.isEmpty { roots.insert(.init(type: type, uuid: uuid)) }
        }
        for block in blocks(in: archive, project: project).values {
            for component in block.dictionaryMap("components").values {
                if let part = component.string("part") {
                    add("part", part)
                } else {
                    add("entity", component.string("entity"))
                }
            }
            for concrete in (block.dictionary("bom_export_settings")?.dictionary("concrete_parts") ?? [:]).values {
                add("part", concrete as? String)
            }
        }
        let schematics = project.blocks.compactMap(\.schematicFilename) + [project.schematicFilename].compactMap { $0 }
        for schematic in json(Set(schematics), in: archive).values {
            for sheet in schematic.dictionaryMap("sheets").values {
                add("frame", sheet.string("frame"))
            }
        }
        if let boardFilename = project.boardFilename, let board = json([boardFilename], in: archive).values.first {
            for package in board.dictionaryMap("packages").values {
                add("package", package.string("alternate_package"))
            }
            for key in ["vias", "via_definitions", "holes"] {
                for item in board.dictionaryMap(key).values {
                    add("padstack", item.string("padstack"))
                }
            }
            for decal in board.dictionaryMap("decals").values {
                add("decal", decal.string("decal"))
            }
        }
        return roots
    }

    private static func json(_ paths: Set<String>, in archive: HorizontalProjectArchive) -> [String: JSONDictionary] {
        var result = [String: JSONDictionary]()
        for path in paths where !path.trimmingCharacters(in: .whitespaces).isEmpty {
            if let data = archive.regularFileData(relativePath: path), let json = try? JSONHelper.loadDictionary(from: data) {
                result[path] = json
            }
        }
        return result
    }
}

/// One thing a cleanup can remove: a cached pool item (a package with the
/// padstacks beside it) or a cached 3D model.
struct HorizontalPoolCacheCleanupItem: Identifiable, Hashable, Sendable {
    /// "part|<uuid>" for a pool item, "model|<path>" for a 3D model.
    var id: String
    var kind: String
    var uuid: String?
    var name: String
    /// Pool-relative files.
    var paths: [String]
    var bytes: Int

    var kindTitle: String {
        HorizontalPoolItemCategory(rawValue: kind)?.singularTitle ?? "3D model"
    }
}

struct HorizontalPoolCacheCleanupReview: Sendable {
    /// What nothing in the design reaches, parts first.
    var items: [HorizontalPoolCacheCleanupItem]
    /// The pool files the review was computed from.
    var projectFiles: [String: Data]
    let digest: String

    init(items: [HorizontalPoolCacheCleanupItem], projectFiles: [String: Data]) {
        self.items = items
        self.projectFiles = projectFiles
        let inputs = projectFiles.keys.sorted().map { "\($0):\(HorizontalProjectTransaction.digest(projectFiles[$0]!))" }
        digest = HorizontalProjectTransaction.digest(Data((inputs + items.map(\.id)).joined(separator: "\n").utf8))
    }
}

/// Horizon's "Clean up Pool Cache": items in the project pool's cache that
/// nothing in the design reaches. The rule is conservative. A used unit keeps
/// all its symbols and a used package all its models, so switching either
/// later needs no re-import. Project-local items, `pool.json`, the cache
/// manifest and hidden files are never offered.
enum HorizontalPoolCacheCleanup {
    private static let cacheKinds: [HorizontalPoolItemCategory] = [.part, .entity, .unit, .symbol, .package, .padstack, .frame, .decal]
    private static let modelCache = "3d_models/cache/"

    /// The pool files a cleanup looks at: all but hidden ones (98). A Finder
    /// `.DS_Store` isn't a pool item. Horizon's own cleanup offers one in
    /// `3d_models/cache` as a 3D model. Here hidden files are never offered or
    /// removed, and the review doesn't count them, so Finder writing one
    /// between review and removal changes nothing. The cache manifest, in the
    /// pool's hidden `.horizontal` folder, still counts.
    static func reviewedFiles(_ files: [String: Data]) -> [String: Data] {
        files.filter { path, _ in
            path == HorizontalPoolCacheProvenance.path || !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }

    static func review(archive: HorizontalProjectArchive, project: HorizontalProject,
                       files: [String: Data]) -> HorizontalPoolCacheCleanupReview {
        let files = reviewedFiles(files)
        let jsons = files.compactMapValues { try? JSONHelper.loadDictionary(from: $0) }
        let reached = HorizontalPoolCacheUpdater.dependencies(of: Array(HorizontalPoolCacheUsage.roots(in: archive, project: project)), jsons: jsons)
        // An item counts as used by kind and uuid, so a cached copy a
        // project-local item overrides stays, as Horizon keeps it.
        let reachedKeys = Set(reached.compactMap { path -> HorizontalPoolItemReference? in
            guard let json = jsons[path], let type = json.string("type"), let uuid = json.string("uuid") else { return nil }
            return .init(type: type, uuid: uuid)
        })
        // A kept package keeps its models, overridden or not.
        var keptModels = reached
        for (path, json) in jsons where path.hasPrefix("packages/cache/") && json.string("type") == "package" {
            guard let uuid = json.string("uuid"), reachedKeys.contains(.init(type: "package", uuid: uuid)) else { continue }
            if let model = json.string("model_filename") { keptModels.insert(model) }
            keptModels.formUnion(json.dictionaryMap("models").values.compactMap { $0.string("filename") })
        }
        var partsByID = [String: JSONDictionary]()
        for json in jsons.values where json.string("type") == "part" {
            if let uuid = json.string("uuid")?.lowercased(), partsByID[uuid] == nil { partsByID[uuid] = json }
        }

        var items = [HorizontalPoolCacheCleanupItem]()
        for category in cacheKinds {
            let prefix = HorizontalPoolItemFactory.directoryName(for: category) + "/cache/"
            if category == .package {
                // A package is its directory: package.json and its padstacks.
                let packagePaths = files.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix("/package.json") }
                for path in packagePaths.sorted() {
                    guard let json = jsons[path], let uuid = json.string("uuid"),
                          !reachedKeys.contains(.init(type: "package", uuid: uuid)) else { continue }
                    let directory = String(path.dropLast("package.json".count))
                    let paths = files.keys.filter { $0.hasPrefix(directory) }.sorted()
                    items.append(item(category, uuid: uuid, name: json.string("name") ?? uuid, paths: paths, files: files))
                }
                continue
            }
            for path in files.keys.sorted() where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
                guard let json = jsons[path], json.string("type") == category.rawValue, let uuid = json.string("uuid"),
                      !reachedKeys.contains(.init(type: category.rawValue, uuid: uuid)) else { continue }
                var name = json.string("name") ?? uuid
                if category == .part {
                    let part = HorizontalPartRecord.resolve(json) { partsByID[$0.lowercased()] }
                    name = [part.mpn, part.manufacturer].filter { !$0.isEmpty }.joined(separator: " / ")
                    if name.isEmpty { name = uuid }
                }
                items.append(item(category, uuid: uuid, name: name, paths: [path], files: files))
            }
        }
        for path in files.keys.sorted() where path.hasPrefix(modelCache) && !keptModels.contains(path) {
            items.append(.init(id: "model|" + path, kind: "model", uuid: nil, name: URL(fileURLWithPath: path).lastPathComponent,
                               paths: [path], bytes: files[path]?.count ?? 0))
        }
        return .init(items: items, projectFiles: files)
    }

    private static func item(_ category: HorizontalPoolItemCategory, uuid: String, name: String,
                             paths: [String], files: [String: Data]) -> HorizontalPoolCacheCleanupItem {
        .init(id: category.rawValue + "|" + uuid.lowercased(), kind: category.rawValue, uuid: uuid.lowercased(), name: name,
              paths: paths, bytes: paths.reduce(0) { $0 + (files[$1]?.count ?? 0) })
    }

    /// What removing the chosen items (every one when `ids` is nil) takes out
    /// of the pool: their pool-relative files, and the cache manifest without
    /// their entries (nil when it has none of them). The design is reviewed
    /// again first, so nothing it has come to use since is removed.
    static func removal(_ review: HorizontalPoolCacheCleanupReview, removing ids: Set<String>?,
                        archive: HorizontalProjectArchive, project: HorizontalProject,
                        poolDirectory: String) throws -> (paths: [String], manifest: Data?) {
        let files = reviewedFiles(HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: poolDirectory))
        guard files == review.projectFiles else {
            throw HorizontalDispatchError.failed("The project pool changed since it was reviewed. Review it again.")
        }
        let current = Self.review(archive: archive, project: project, files: files)
        let available = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
        let chosen = ids ?? Set(review.items.map(\.id))
        guard !chosen.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Nothing in the project pool is unused.")
        }
        if let missing = chosen.subtracting(available.keys).sorted().first {
            throw HorizontalDispatchError.invalidParams("\(missing) is not an unused item in the project pool.")
        }
        let removed = Set(chosen.flatMap { available[$0]!.paths })
        var manifest: Data?
        if let data = files[HorizontalPoolCacheProvenance.path] {
            var metadata = try HorizontalPoolCacheProvenance.load(data)
            let before = metadata.files.count
            metadata.files = metadata.files.filter { !removed.contains($0.key) }
            if metadata.files.count != before { manifest = try metadata.data() }
        }
        return (removed.sorted(), manifest)
    }

    /// The archive without the chosen items. See `removal`.
    static func applying(_ review: HorizontalPoolCacheCleanupReview, removing ids: Set<String>?,
                         to archive: HorizontalProjectArchive, project: HorizontalProject,
                         poolDirectory: String) throws -> HorizontalProjectArchive {
        let (paths, manifest) = try removal(review, removing: ids, archive: archive, project: project, poolDirectory: poolDirectory)
        var next = archive
        for path in paths {
            try next.removeRegularFile(relativePath: poolDirectory + "/" + path)
        }
        if let manifest {
            try next.replaceRegularFileData(relativePath: poolDirectory + "/" + HorizontalPoolCacheProvenance.path, with: manifest)
        }
        return next
    }
}
