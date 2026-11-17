import Foundation
import HorizontalProjectIO

/// One file a copy of a project's edits writes into a pool.
struct HorizontalPoolEditFile {
    var url: URL
    var data: Data
    /// The pool's file as the plan found it, nil where the pool had none.
    /// The copy stops if the pool holds anything else when it comes to write.
    var replacing: Data?
}

/// Edits a project made to items it cached from its pools, and what copying
/// them back takes: the pools' files to write, and what the project then
/// records of where its copies came from, so they read as current again.
struct HorizontalPoolEditCopy: Identifiable {
    let id = UUID()
    /// What goes to each pool, item by item, part first.
    var sections: [Section]
    var files: [HorizontalPoolEditFile]
    /// The project pool's files the plan was made from. The copy stops if
    /// the project's pool is anything else by then.
    var projectFiles: [String: Data]
    /// Each copy's origin once its pool has it, by its path in the project
    /// pool.
    var origins: [String: HorizontalPoolCacheProvenance.Origin]
    /// Project pool files rewritten to be what the pool now supplies: a
    /// package naming a 3D model outside the cache names the cached one, as
    /// an update from the pool would have left it.
    var projectUpdates: [String: Data]

    struct Section {
        var poolName: String
        var poolURL: URL
        var items: [HorizontalPoolCopyItem]
    }

    /// "Stock", or "Stock and Mine".
    var targetList: String { sections.map(\.poolName).joined(separator: " and ") }

    /// The confirmation's text: what each pool's copy is replaced with, and
    /// what can't be taken back.
    var summary: String {
        var paragraphs = sections.map { section in
            "Replaces in \(section.poolName):\n" + section.items.map {
                "• \($0.kind): \($0.name)" + ($0.note.isEmpty ? "" : " (\($0.note))")
            }.joined(separator: "\n")
        }
        let folders = sections.map { ($0.poolURL.path as NSString).abbreviatingWithTildeInPath }.joined(separator: " and ")
        paragraphs.append("Other projects that use \(sections.count == 1 ? "this pool" : "these pools") are offered the change as an update. "
            + "Undo doesn't take back the \(files.count) file\(files.count == 1 ? "" : "s") written to \(folders).")
        return paragraphs.joined(separator: "\n\n")
    }
}

/// Copying a project's edits of cached pool items back into the pools they
/// came from: the reverse of updating the project from its pools
/// (`HorizontalPoolCacheUpdater`). The parts review finds the edits, a copy
/// whose contents are no longer what the project took while the pool can be
/// written (`HorizontalPoolCacheChange.canCopyToPool`).
///
/// Each edited file goes over the pool file it was cached from, in the form
/// a pool keeps it: a package's 3D model paths are the pool's own again, and
/// a model or a padstack of its own that the pool doesn't have goes with it.
/// The project then records the pool's new contents as what it holds.
enum HorizontalPoolEditCopier {
    /// Plans a copy of the edits the review found in `partIDs`' parts and
    /// what they depend on. Nothing is written.
    static func plan(partIDs: Set<String>, review: HorizontalPoolCacheReview) throws -> HorizontalPoolEditCopy {
        var changes = [HorizontalPoolCacheChange]()
        for change in review.parts.filter({ partIDs.contains($0.id) }).flatMap(\.poolCopyChanges)
        where !changes.contains(where: { $0.path == change.path }) {
            changes.append(change)
        }
        return try plan(changes: changes, review: review)
    }

    /// Plans a copy of the edits of one item of the project pool, the file at
    /// `itemPath` there: a row of the Pools pane, where a part's symbol or
    /// package is an item of its own (`poolCopyChangesByItem`).
    static func plan(itemPath: String, review: HorizontalPoolCacheReview) throws -> HorizontalPoolEditCopy {
        try plan(changes: review.poolCopyChangesByItem[itemPath] ?? [], review: review)
    }

    private static func plan(changes: [HorizontalPoolCacheChange], review: HorizontalPoolCacheReview) throws -> HorizontalPoolEditCopy {
        guard !changes.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Nothing edited in the project is waiting to be copied to a pool.")
        }
        let files = review.projectFiles
        let jsons = files.compactMapValues { try? JSONHelper.loadDictionary(from: $0) }

        // What each pool finds, itself or in a pool it includes.
        var searchedByPool = [String: [URL]]()
        func searched(_ pool: URL) -> [URL] {
            if let known = searchedByPool[pool.path] { return known }
            let pools = [pool] + HorizontalPoolLibrary.includedPoolURLs(for: pool)
            searchedByPool[pool.path] = pools
            return pools
        }
        var heldByPool = [String: Set<String>]()
        func holds(_ pool: URL, _ type: String, _ uuid: String) -> Bool {
            if heldByPool[pool.path] == nil {
                heldByPool[pool.path] = Set(searched(pool).flatMap { url in
                    HorizontalPoolLibrary.items(inPool: url, poolName: HorizontalPoolRegistryStore.poolInfo(at: url).name)
                        .map { $0.category.rawValue + "|" + $0.uuid }
                })
            }
            return heldByPool[pool.path]?.contains(type + "|" + uuid.lowercased()) == true
        }

        var poolFiles = [HorizontalPoolEditFile]()
        var origins = [String: HorizontalPoolCacheProvenance.Origin]()
        var projectUpdates = [String: Data]()
        var sections = [HorizontalPoolEditCopy.Section]()
        /// A file the pool doesn't have; false for one already on its way.
        func add(_ url: URL, _ data: Data) -> Bool {
            guard !poolFiles.contains(where: { $0.url == url }) else { return false }
            poolFiles.append(.init(url: url, data: data, replacing: nil))
            return true
        }

        for change in changes.sorted(by: { $0.path < $1.path }) {
            guard let edited = change.before, let pool = change.sourcePoolURL, let sourceURL = change.sourceURL else { continue }
            let poolName = change.sourcePoolName
            let poolUUID = change.origin.poolUUID
            // What is replaced is what the review compared the edit with.
            let present = try Data(contentsOf: sourceURL)
            guard review.sourceDigests[sourceURL] == HorizontalProjectTransaction.digest(present) else {
                throw HorizontalDispatchError.failed("\(poolName) changed after the parts were checked. Check again before copying.")
            }
            var poolData = edited
            var kind = "3D model", name = sourceURL.lastPathComponent
            var notes = [String]()

            if change.path.hasSuffix(".json") {
                let json = try JSONHelper.loadDictionary(from: edited)
                let type = json.string("type") ?? "", uuid = json.string("uuid")?.lowercased() ?? ""
                let theirs = try JSONHelper.loadDictionary(from: present)
                guard theirs.string("type") == type, theirs.string("uuid")?.lowercased() == uuid else {
                    throw HorizontalDispatchError.failed("\(poolName) has another item at \(change.origin.sourcePath) now. Check the parts again.")
                }
                kind = HorizontalPoolItemCategory(rawValue: type)?.singularTitle ?? type.capitalized
                name = type == "part" ? partName(json, jsons: jsons) : json.string("name") ?? uuid
                var ownPadstacks = Set<String>()

                if type == "package" {
                    let cacheDirectory = String(change.path.dropLast("package.json".count)) + "padstacks/"
                    let poolDirectory = sourceURL.deletingLastPathComponent().appendingPathComponent("padstacks", isDirectory: true)
                    var newPadstacks = 0
                    for (path, padstack) in jsons.sorted(by: { $0.key < $1.key }) where path.hasPrefix(cacheDirectory) {
                        if let id = padstack.string("uuid")?.lowercased() { ownPadstacks.insert(id) }
                        let url = poolDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                        guard !FileManager.default.fileExists(atPath: url.path), let data = files[path] else { continue }
                        guard add(url, data) else { continue }
                        origins[path] = .init(poolUUID: poolUUID, sourcePath: try HorizontalPoolCacheProvenance.relativePath(url, in: pool),
                                              baseline: try HorizontalPoolCacheProvenance.digest(data, path: path))
                        newPadstacks += 1
                    }
                    // The cache's model paths name the pool they were cached
                    // from; a pool's own are its paths.
                    var newModels = 0
                    func poolModelPath(_ filename: String) throws -> String {
                        let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
                        let modelPath = parts.count > 3 && parts[0] == "3d_models" && parts[1] == "cache"
                            ? parts.dropFirst(3).joined(separator: "/") : filename
                        guard let data = files[filename] else { return modelPath }
                        let holders = try searched(pool).map { try HorizontalPoolCacheProvenance.safeURL(modelPath, in: $0) }
                            .filter { FileManager.default.fileExists(atPath: $0.path) }
                        if holders.isEmpty {
                            if add(try HorizontalPoolCacheProvenance.safeURL(modelPath, in: pool), data) { newModels += 1 }
                        } else if filename != "3d_models/cache/\(poolUUID)/\(modelPath)", try !holders.contains(where: { try Data(contentsOf: $0) == data }) {
                            // A model of the project's own, not this pool's
                            // cached: the pool's file there is another model.
                            throw HorizontalDispatchError.invalidParams("\(poolName) has a different 3D model at \(modelPath).")
                        }
                        // The project names the pool's model as an update would.
                        let cached = "3d_models/cache/\(poolUUID)/\(modelPath)"
                        if files[cached] == nil {
                            projectUpdates[cached] = data
                            origins[cached] = .init(poolUUID: poolUUID, sourcePath: modelPath,
                                                    baseline: try HorizontalPoolCacheProvenance.digest(data, path: cached))
                        }
                        return modelPath
                    }
                    var package = json
                    if let filename = package.string("model_filename") { package["model_filename"] = try poolModelPath(filename) }
                    var models = package.dictionaryMap("models")
                    for (id, var model) in models {
                        if let filename = model.string("filename") { model["filename"] = try poolModelPath(filename) }
                        models[id] = model
                    }
                    if !models.isEmpty { package["models"] = models }
                    poolData = try HorizontalHorizonJSONWriter.data(package)
                    if newPadstacks > 0 { notes.append("with \(newPadstacks) new padstack\(newPadstacks == 1 ? "" : "s")") }
                    if newModels > 0 { notes.append("\(newModels) new 3D model\(newModels == 1 ? "" : "s")") }
                }

                // The pool must find everything the edit names.
                for reference in references(of: json) where !(reference.type == "padstack" && ownPadstacks.contains(reference.uuid)) {
                    guard holds(pool, reference.type, reference.uuid) else {
                        let named = jsons.values.first { $0.string("type") == reference.type && $0.string("uuid")?.lowercased() == reference.uuid }
                            .map { reference.type == "part" ? partName($0, jsons: jsons) : $0.string("name") ?? reference.uuid } ?? reference.uuid
                        throw HorizontalDispatchError.invalidParams(
                            "The project's \(kind.lowercased()) \(name) uses the \(reference.type) \(named), which \(poolName) doesn't have, "
                                + "itself or in a pool it includes. Nothing was copied.")
                    }
                }
            }

            poolFiles.append(.init(url: sourceURL, data: poolData, replacing: present))
            // What the project holds after: the pool's copy as it caches it.
            let cachedForm = try HorizontalPoolCacheUpdater.normalizedSource(poolData, path: change.path, poolUUID: poolUUID)
            let baseline = try HorizontalPoolCacheProvenance.digest(cachedForm, path: change.path)
            origins[change.path] = .init(poolUUID: poolUUID, sourcePath: change.origin.sourcePath, baseline: baseline)
            if try HorizontalPoolCacheProvenance.digest(edited, path: change.path) != baseline {
                projectUpdates[change.path] = cachedForm
            }
            if change.sourceChanged { notes.append("\(poolName)'s own changes since are replaced") }
            let item = HorizontalPoolCopyItem(kind: kind, name: name, note: notes.joined(separator: "; "))
            if let index = sections.firstIndex(where: { $0.poolURL == pool }) {
                sections[index].items.append(item)
            } else {
                sections.append(.init(poolName: poolName, poolURL: pool, items: [item]))
            }
        }

        // Listed part first, then what it is made of.
        let order = ["Part", "Entity", "Unit", "Symbol", "Package", "Padstack"]
        for index in sections.indices {
            sections[index].items.sort {
                (order.firstIndex(of: $0.kind) ?? order.count, $0.name) < (order.firstIndex(of: $1.kind) ?? order.count, $1.name)
            }
        }
        return HorizontalPoolEditCopy(sections: sections, files: poolFiles, projectFiles: files, origins: origins, projectUpdates: projectUpdates)
    }

    /// The project's side, staged before the pools are written: its copies
    /// record what their pools hold now. The copy stops here, with nothing
    /// written, if the project's pool changed after the plan was made.
    static func track(_ copy: HorizontalPoolEditCopy, in archive: inout HorizontalProjectArchive, poolDirectory: String) throws {
        guard HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: poolDirectory) == copy.projectFiles else {
            throw HorizontalDispatchError.failed("The project library changed after it was checked. Check again before copying.")
        }
        var metadata = try HorizontalPoolCacheProvenance.load(copy.projectFiles[HorizontalPoolCacheProvenance.path])
        metadata.files.merge(copy.origins) { _, new in new }
        var updates = copy.projectUpdates
        updates[HorizontalPoolCacheProvenance.path] = try metadata.data()
        for (path, data) in updates {
            try archive.replaceRegularFileData(relativePath: poolDirectory + "/" + path, with: data)
        }
    }

    /// Writes the edits into their pools. A pool file that is no longer what
    /// the plan found stops the copy before any file is written.
    static func writePoolFiles(_ copy: HorizontalPoolEditCopy) throws {
        for file in copy.files {
            let present = FileManager.default.fileExists(atPath: file.url.path) ? try Data(contentsOf: file.url) : nil
            guard present == file.replacing else {
                throw HorizontalDispatchError.failed("\(file.url.lastPathComponent) changed in its pool after it was checked; nothing was copied. Check again.")
            }
        }
        for file in copy.files {
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: file.url, options: [.atomic])
        }
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
    }

    /// For a cached copy about to be edited that nothing records the origin
    /// of, though it is its pool's copy to the letter (a project Horizon
    /// made): the project's provenance with that origin added, so the edit
    /// reads as one made here and not as a copy that fell behind. Nil when
    /// there is nothing to record.
    static func provenanceBeforeEdit(of path: String, current: Data?, provenance: Data?, review: HorizontalPoolCacheReview?) -> Data? {
        guard let current, let origin = review?.parts.lazy.compactMap({ $0.origins[path] }).first,
              var metadata = try? HorizontalPoolCacheProvenance.load(provenance), metadata.files[path] == nil,
              (try? HorizontalPoolCacheProvenance.digest(current, path: path)) == origin.baseline else {
            return nil
        }
        metadata.files[path] = origin
        return try? metadata.data()
    }

    /// The items a pool item names, which its pool has to be able to find.
    private static func references(of json: JSONDictionary) -> [(type: String, uuid: String)] {
        let named: [(String, String?)]
        switch json.string("type") {
        case "part": named = [("part", json.string("base")), ("entity", json.string("entity")), ("package", json.string("package"))]
        case "entity": named = json.dictionaryMap("gates").values.map { ("unit", $0.string("unit")) }
        case "symbol": named = [("unit", json.string("unit"))]
        case "package": named = json.dictionaryMap("pads").values.map { ("padstack", $0.string("padstack")) }
        default: named = []
        }
        return named.compactMap { type, uuid in uuid.map { (type, $0.lowercased()) } }
    }

    private static func partName(_ json: JSONDictionary, jsons: [String: JSONDictionary]) -> String {
        let mpn = HorizontalPartRecord.resolve(json) { id in
            jsons.values.first { $0.string("type") == "part" && $0.string("uuid")?.lowercased() == id.lowercased() }
        }.mpn
        return mpn.isEmpty ? json.string("uuid") ?? "" : mpn
    }
}

/// What a project's Pools pane is told of the edits made in the project's
/// pool: which of the rows it shows from that pool were edited there and can
/// go back to the pools they were cached from, and the plan of one's copy.
struct HorizontalPoolItemEdits {
    var review: HorizontalPoolCacheReview
    /// The project pool's folder as the browser's rows name it.
    private let projectPoolPath: String

    init(review: HorizontalPoolCacheReview, projectPool: URL) {
        self.review = review
        projectPoolPath = HorizontalPoolLibrary.canonicalURL(projectPool).path
    }

    /// The row's file within the project pool, when it has edits a pool can
    /// take; nil for every other row, another pool's among them.
    private func editedPath(of item: HorizontalPoolLibraryItem) -> String? {
        guard !review.poolCopyChangesByItem.isEmpty, item.poolURL.path == projectPoolPath else { return nil }
        // A scan finds a pool under /var or /tmp at /private/var, which the
        // pool's own path leaves out; standardized, both do.
        let path = item.url.standardizedFileURL.path
        guard path.hasPrefix(projectPoolPath + "/") else { return nil }
        let relative = String(path.dropFirst(projectPoolPath.count + 1))
        return review.poolCopyChangesByItem[relative] == nil ? nil : relative
    }

    /// The pools the row's edits can be copied back to, by name: none for a
    /// row that wasn't edited here, or whose pool can't be written.
    func targetNames(for item: HorizontalPoolLibraryItem) -> [String] {
        guard let path = editedPath(of: item) else { return [] }
        return (review.poolCopyChangesByItem[path] ?? []).reduce(into: [String]()) {
            if !$0.contains($1.sourcePoolName) { $0.append($1.sourcePoolName) }
        }
    }

    func plan(for item: HorizontalPoolLibraryItem) throws -> HorizontalPoolEditCopy {
        guard let path = editedPath(of: item) else {
            throw HorizontalDispatchError.invalidParams("Nothing edited in the project is waiting to be copied to a pool.")
        }
        return try HorizontalPoolEditCopier.plan(itemPath: path, review: review)
    }
}
