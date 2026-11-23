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
/// (Board A's `top_block.json` has none).
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
    ///   hole's padstack and each decal;
    /// - each via rule's padstack. Horizon's cleanup counts a via's alone, but
    ///   the rule's is every via the rule gives, and the board's next save
    ///   would only cache it again (`HorizontalProjectJSONApplicator`).
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
            for rule in (board.dictionary("rules")?.dictionaryMap("via") ?? [:]).values {
                add("padstack", rule.string("padstack"))
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

/// One thing a cleanup can remove: a pool item (a package with the padstacks
/// beside it) or a 3D model, cached from a library or the project's own.
struct HorizontalPoolCacheCleanupItem: Identifiable, Hashable, Sendable {
    /// For a cached copy, "part|<uuid>" for a pool item and "model|<path>"
    /// for a 3D model. For one of the project's own, "local|<path>": a cached
    /// copy can share its uuid.
    var id: String
    var kind: String
    var uuid: String?
    var name: String
    /// Pool-relative files.
    var paths: [String]
    var bytes: Int
    /// The project's own, kept outside `cache/`: no library has it to copy
    /// again, so a cleanup removes it only when it is chosen.
    var isProjectLocal = false

    var kindTitle: String {
        HorizontalPoolItemCategory(rawValue: kind)?.singularTitle ?? "3D model"
    }
}

struct HorizontalPoolCacheCleanupReview: Sendable {
    /// What nothing in the design reaches: the cached copies, parts first,
    /// then the project's own in the same order.
    var items: [HorizontalPoolCacheCleanupItem]
    /// What a cleanup removes when it isn't told what to: every cached copy.
    /// The sheet starts with these ticked.
    var defaultSelection: Set<String> {
        Set(items.filter { !$0.isProjectLocal }.map(\.id))
    }
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
/// later needs no re-import. `pool.json`, the cache manifest and hidden files
/// are never offered.
///
/// Horizon stops at the cache. Here the project's own unused items are
/// offered after it (`localItems`), since nothing else in the app removes
/// one, but a cleanup takes them only when they are chosen.
enum HorizontalPoolCacheCleanup {
    static let cacheKinds: [HorizontalPoolItemCategory] = [.part, .entity, .unit, .symbol, .package, .padstack, .frame, .decal]
    static let modelCache = "3d_models/cache/"

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
                items.append(item(category, uuid: uuid, name: name(of: json, category, uuid: uuid, partsByID: partsByID),
                                  paths: [path], files: files))
            }
        }
        for path in files.keys.sorted() where path.hasPrefix(modelCache) && !keptModels.contains(path) {
            items.append(.init(id: "model|" + path, kind: "model", uuid: nil, name: URL(fileURLWithPath: path).lastPathComponent,
                               paths: [path], bytes: files[path]?.count ?? 0))
        }
        items += localItems(files: files, jsons: jsons, reachedKeys: reachedKeys, keptModels: keptModels, partsByID: partsByID)
        return .init(items: items, projectFiles: files)
    }

    /// The name a row shows: a part's MPN and manufacturer, anything else's
    /// own name.
    static func name(of json: JSONDictionary, _ category: HorizontalPoolItemCategory, uuid: String,
                     partsByID: [String: JSONDictionary]) -> String {
        guard category == .part else { return json.string("name") ?? uuid }
        let part = HorizontalPartRecord.resolve(json) { partsByID[$0.lowercased()] }
        let name = [part.mpn, part.manufacturer].filter { !$0.isEmpty }.joined(separator: " / ")
        return name.isEmpty ? uuid : name
    }

    private static func item(_ category: HorizontalPoolItemCategory, uuid: String, name: String,
                             paths: [String], files: [String: Data]) -> HorizontalPoolCacheCleanupItem {
        .init(id: category.rawValue + "|" + uuid.lowercased(), kind: category.rawValue, uuid: uuid.lowercased(), name: name,
              paths: paths, bytes: paths.reduce(0) { $0 + (files[$1]?.count ?? 0) })
    }

    /// What removing the chosen items (every cached copy when `ids` is nil)
    /// takes out of the pool: their pool-relative files, and the cache
    /// manifest without their entries (nil when it has none of them). The
    /// design is reviewed again first, so nothing it has come to use since is
    /// removed.
    static func removal(_ review: HorizontalPoolCacheCleanupReview, removing ids: Set<String>?,
                        archive: HorizontalProjectArchive, project: HorizontalProject,
                        poolDirectory: String) throws -> (paths: [String], manifest: Data?) {
        let files = reviewedFiles(HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: poolDirectory))
        guard files == review.projectFiles else {
            throw HorizontalDispatchError.failed("The project pool changed since it was reviewed. Review it again.")
        }
        let current = Self.review(archive: archive, project: project, files: files)
        let available = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
        let chosen = ids ?? review.defaultSelection
        guard !chosen.isEmpty else {
            throw HorizontalDispatchError.invalidParams(review.items.isEmpty
                ? "Nothing in the project pool is unused."
                : "Nothing in the project pool's cache is unused. The project's own unused items go only when they are named.")
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
