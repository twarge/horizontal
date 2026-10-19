import Foundation
import HorizontalProjectIO

/// A pool a part can be copied into, as a menu lists it.
struct HorizontalPoolCopyTarget: Identifiable, Hashable {
    var url: URL
    var name: String
    var id: String { url.path }
}

/// One item of a copy, as its confirmation lists it.
struct HorizontalPoolCopyItem: Hashable {
    /// "Part", "Entity", … as the pool browser names its kinds.
    var kind: String
    var name: String
    /// What else goes with it (a package's padstacks and 3D models), or
    /// where the pool finds one it has already.
    var note: String = ""
}

/// A part of the project's pool that no attached pool has, and what copying
/// it into one takes: the files to write there, and the project's copies the
/// pool then supplies.
struct HorizontalPoolPartCopy: Identifiable {
    var id: String { partID + "|" + target.path }
    var partID: String
    var partName: String
    var target: URL
    var targetName: String
    /// What goes into the pool, by pool-relative path: the part and whatever
    /// it needs that the pool (or a pool it includes) doesn't have.
    var poolFiles: [(path: String, data: Data)]
    /// Project pool paths the pool supplies from now on: taken out of the
    /// project, then cached from the pool again, origin and all.
    var recached: Set<String>
    /// What goes into the pool, item by item, part first.
    var copied: [HorizontalPoolCopyItem]
    /// What the part needs that the pool, or a pool it includes, has
    /// already. One with other contents under the same uuid says so: the
    /// project keeps its own, and the parts review shows the difference.
    var existing: [HorizontalPoolCopyItem]

    /// The confirmation's text: what is copied, what is there already, and
    /// what the project does after.
    var summary: String {
        func list(_ items: [HorizontalPoolCopyItem]) -> String {
            items.map { "• \($0.kind): \($0.name)" + ($0.note.isEmpty ? "" : " (\($0.note))") }.joined(separator: "\n")
        }
        var sections = ["Copies into \(targetName):\n" + list(copied)]
        if !existing.isEmpty {
            sections.append("Already in \(targetName), not copied:\n" + list(existing))
        }
        sections.append("The project then keeps the part up to date from \(targetName). Undo takes back the project's change, "
            + "not the \(poolFiles.count) file\(poolFiles.count == 1 ? "" : "s") written to \((target.path as NSString).abbreviatingWithTildeInPath).")
        return sections.joined(separator: "\n\n")
    }
}

/// Copying a project's part into a pool it's attached to, for a part made in
/// the project or written into its pool, so other projects can use it and
/// this one keeps it up to date from there.
///
/// The pool gets the part and every item it depends on that the pool can't
/// already resolve, itself or through the pools it includes, filed as a pool
/// files them (`parts/<MPN>.json`, `packages/<name>/package.json`, the 3D
/// models under their own paths) rather than under the project cache's
/// uuid names. The project then caches the part from the pool, as placing it
/// from the pool would have, so its copies record where they came from.
enum HorizontalPoolPartCopier {
    static func plan(
        partID: String,
        projectFiles: [String: Data],
        projectPoolURL: URL,
        into target: URL
    ) throws -> HorizontalPoolPartCopy {
        let partID = partID.lowercased()
        let jsons = projectFiles.compactMapValues { try? JSONHelper.loadDictionary(from: $0) }
        let dependencies = HorizontalPoolCacheUpdater.dependencies(of: [.init(type: "part", uuid: partID)], jsons: jsons)
        guard let partPath = dependencies.first(where: { jsons[$0]?.string("type") == "part" && jsons[$0]?.string("uuid")?.lowercased() == partID }),
              let partJSON = jsons[partPath] else {
            throw HorizontalDispatchError.notFound("The project pool has no part \(partID).")
        }
        let partName = HorizontalPartRecord.resolve(partJSON) { id in
            jsons.values.first { $0.string("type") == "part" && $0.string("uuid")?.lowercased() == id.lowercased() }
        }.mpn
        let targetInfo = HorizontalPoolRegistryStore.poolInfo(at: target)

        // What the pool resolves already, itself or through what it includes.
        var held = [String: HorizontalPoolLibraryItem]()
        for pool in [target] + HorizontalPoolLibrary.includedPoolURLs(for: target) {
            for item in HorizontalPoolLibrary.items(inPool: pool, poolName: HorizontalPoolRegistryStore.poolInfo(at: pool).name) {
                let key = item.category.rawValue + "|" + item.uuid
                if held[key] == nil { held[key] = item }
            }
        }
        guard held["part|" + partID] == nil else {
            throw HorizontalDispatchError.invalidParams("\(targetInfo.name) has \(partName.isEmpty ? partID : partName) already.")
        }
        // A cached copy with a recorded origin in a pool the project is
        // attached to is that pool's to keep up to date.
        let metadata = try HorizontalPoolCacheProvenance.load(projectFiles[HorizontalPoolCacheProvenance.path])
        let attached = Set(HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: projectPoolURL).dropFirst()
            .map { HorizontalPoolRegistryStore.poolInfo(at: $0).uuid.lowercased() })
        func isTracked(_ path: String) -> Bool {
            isCached(path) && metadata.files[path].map { attached.contains($0.poolUUID.lowercased()) } == true
        }

        var poolFiles = [(path: String, data: Data)]()
        var taken = Set<String>()
        // A name the pool already uses gets the uuid's first digits.
        func reserve(_ path: String, uuid: String) -> String {
            var candidate = path
            if taken.contains(candidate) || FileManager.default.fileExists(atPath: target.appendingPathComponent(candidate).path) {
                let suffix = "-" + uuid.prefix(8)
                if path.hasSuffix(".json") {
                    candidate = String(path.dropLast(".json".count)) + suffix + ".json"
                } else {
                    candidate = path + suffix
                }
            }
            taken.insert(candidate)
            return candidate
        }
        var recached = Set<String>(), copied = [HorizontalPoolCopyItem](), existing = [HorizontalPoolCopyItem]()
        for path in dependencies.sorted() {
            guard let json = jsons[path], let type = json.string("type"), let uuid = json.string("uuid")?.lowercased(),
                  !isPackageLocalPadstack(path) else { continue }
            let packageLocals = type == "package" ? dependencies.filter { isPackageLocalPadstack($0) && $0.hasPrefix(packageDirectory(path)) } : []
            let kind = HorizontalPoolItemCategory(rawValue: type)?.singularTitle ?? type.capitalized
            let displayName = type == "part"
                ? HorizontalPartRecord.resolve(json) { id in jsons.values.first { $0.string("type") == "part" && $0.string("uuid")?.lowercased() == id.lowercased() } }.mpn
                : json.string("name") ?? uuid
            if let item = held[type + "|" + uuid] {
                // Found where the pool finds it: itself, or a pool it includes.
                let whereFound = item.poolName == targetInfo.name ? "" : "in \(item.poolName)"
                guard !isTracked(path) else {
                    existing.append(.init(kind: kind, name: displayName, note: whereFound))
                    continue
                }
                let poolData = try Data(contentsOf: item.url)
                let poolForm = isCached(path)
                    ? try HorizontalPoolCacheUpdater.normalizedSource(poolData, path: path, poolUUID: HorizontalPoolRegistryStore.poolInfo(at: item.poolURL).uuid)
                    : poolData
                if try HorizontalPoolCacheProvenance.digest(poolForm, path: path) == HorizontalPoolCacheProvenance.digest(projectFiles[path]!, path: path) {
                    recached.insert(path)
                    recached.formUnion(packageLocals)
                    existing.append(.init(kind: kind, name: displayName, note: whereFound))
                } else if isCached(path) {
                    existing.append(.init(kind: kind, name: displayName,
                                          note: [whereFound, "a different version; the project keeps its own"].filter { !$0.isEmpty }.joined(separator: ", ")))
                } else {
                    throw HorizontalDispatchError.invalidParams(
                        "\(item.poolName) has the \(type) \(json.string("name") ?? uuid) under the same uuid, with other contents than this project's (\(path)). Make them agree, or give one a new uuid, first.")
                }
                continue
            }
            // Filed as a pool files it, not by the cache's uuid names.
            let category = HorizontalPoolItemCategory(rawValue: type) ?? .part
            let name = sanitizedName(type == "part" ? HorizontalPartRecord.resolve(json) { _ in nil }.mpn : json.string("name") ?? "", fallback: uuid)
            let directory = HorizontalPoolItemFactory.directoryName(for: category)
            if type == "package" {
                let folder = reserve(isCached(path) ? "\(directory)/\(name)" : String(packageDirectory(path).dropLast()), uuid: uuid)
                var package = json
                let filesBeforeModels = poolFiles.count
                // The cache's model paths name the pool they were cached
                // from; a pool's own are its paths.
                func poolModelPath(_ filename: String) throws -> String {
                    let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
                    let modelPath = parts.count > 3 && parts[0] == "3d_models" && parts[1] == "cache" ? parts.dropFirst(3).joined(separator: "/") : filename
                    guard let data = projectFiles[filename] else { return modelPath }
                    let existing = target.appendingPathComponent(modelPath)
                    if let present = try? Data(contentsOf: existing) {
                        guard present == data else {
                            throw HorizontalDispatchError.invalidParams("\(targetInfo.name) has a different 3D model at \(modelPath).")
                        }
                    } else if !taken.contains(modelPath) {
                        taken.insert(modelPath)
                        poolFiles.append((modelPath, data))
                    }
                    return modelPath
                }
                if let filename = package.string("model_filename") { package["model_filename"] = try poolModelPath(filename) }
                var models = package.dictionaryMap("models")
                for (id, var model) in models {
                    if let filename = model.string("filename") { model["filename"] = try poolModelPath(filename) }
                    models[id] = model
                }
                if !models.isEmpty { package["models"] = models }
                let models3D = poolFiles.count - filesBeforeModels
                poolFiles.append(("\(folder)/package.json", try HorizontalHorizonJSONWriter.data(package)))
                for local in packageLocals.sorted() {
                    poolFiles.append(("\(folder)/padstacks/\(URL(fileURLWithPath: local).lastPathComponent)", projectFiles[local]!))
                }
                let extras = [packageLocals.isEmpty ? nil : "with \(packageLocals.count) padstack\(packageLocals.count == 1 ? "" : "s")",
                              models3D > 0 ? "\(models3D) 3D model\(models3D == 1 ? "" : "s")" : nil].compactMap { $0 }
                copied.append(.init(kind: kind, name: displayName, note: extras.joined(separator: " and ")))
            } else {
                let file = reserve(isCached(path) ? "\(directory)/\(name).json" : path, uuid: uuid)
                poolFiles.append((file, projectFiles[path]!))
                copied.append(.init(kind: kind, name: displayName))
            }
            if !isTracked(path) {
                recached.insert(path)
                recached.formUnion(packageLocals)
            }
        }
        // Listed part first, then what it is made of.
        let order = ["Part", "Entity", "Unit", "Symbol", "Package", "Padstack"]
        func sorted(_ items: [HorizontalPoolCopyItem]) -> [HorizontalPoolCopyItem] {
            items.sorted { (order.firstIndex(of: $0.kind) ?? order.count, $0.name) < (order.firstIndex(of: $1.kind) ?? order.count, $1.name) }
        }
        return HorizontalPoolPartCopy(partID: partID, partName: partName.isEmpty ? partID : partName, target: target,
                                      targetName: targetInfo.name, poolFiles: poolFiles, recached: recached,
                                      copied: sorted(copied), existing: sorted(existing))
    }

    /// Writes the copy's files into the pool. Nothing is overwritten: a path
    /// taken since the plan was made stops the copy before any file is written.
    static func writePoolFiles(_ copy: HorizontalPoolPartCopy) throws {
        for file in copy.poolFiles where FileManager.default.fileExists(atPath: copy.target.appendingPathComponent(file.path).path) {
            throw HorizontalDispatchError.failed("\(copy.targetName) has \(file.path) now; nothing was copied. Try again.")
        }
        for file in copy.poolFiles {
            let url = copy.target.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
    }

    /// The project's side, once the pool has the files: the copies the pool
    /// supplies come out, and the part is cached from the pool, as placing it
    /// from there would cache it, with its origin recorded.
    static func track(_ copy: HorizontalPoolPartCopy, in archive: inout HorizontalProjectArchive, poolDirectory: String, projectPoolURL: URL) throws {
        for path in copy.recached {
            try? archive.removeRegularFile(relativePath: "\(poolDirectory)/\(path)")
        }
        guard let item = HorizontalPoolLibrary.items(inPool: copy.target, poolName: copy.targetName)
            .first(where: { $0.category == .part && $0.uuid == copy.partID }) else {
            throw HorizontalDispatchError.failed("\(copy.targetName) doesn't list the part it was given.")
        }
        let prefix = projectPoolURL.path.hasSuffix("/") ? projectPoolURL.path : projectPoolURL.path + "/"
        func archivePath(_ url: URL) -> String? {
            url.path.hasPrefix(prefix) ? "\(poolDirectory)/\(url.path.dropFirst(prefix.count))" : nil
        }
        let current = archive
        let destination = HorizontalPoolCacheDestination(
            read: { url in archivePath(url).flatMap { current.regularFileData(relativePath: $0) } },
            list: { directory in
                guard let base = archivePath(directory).map({ $0.hasSuffix("/") ? $0 : $0 + "/" }) else { return [] }
                return current.regularFilePaths.filter { $0.hasPrefix(base) && !$0.dropFirst(base.count).contains("/") }
                    .map { projectPoolURL.appendingPathComponent(String($0.dropFirst(poolDirectory.count + 1))) }
            }
        )
        for file in try HorizontalPoolCacheImporter.plan(item, into: projectPoolURL, destination: destination) {
            guard let path = archivePath(file.url) else { throw HorizontalProjectJSONApplyError.missingArchivePath(file.url) }
            try archive.replaceRegularFileData(relativePath: path, with: file.data)
        }
    }

    /// The pools a project is attached to that a part can be copied into: the
    /// pools its pool includes and the registered and discovered ones, where
    /// this app can write.
    static func targets(forProjectPool projectPoolURL: URL) -> [HorizontalPoolCopyTarget] {
        HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: projectPoolURL).dropFirst()
            .filter { FileManager.default.isWritableFile(atPath: $0.path) }
            .map { HorizontalPoolCopyTarget(url: $0, name: HorizontalPoolRegistryStore.poolInfo(at: $0).name) }
    }

    private static func isCached(_ path: String) -> Bool {
        path.split(separator: "/").dropFirst().first == "cache"
    }

    private static func isPackageLocalPadstack(_ path: String) -> Bool {
        path.hasPrefix("packages/") && path.split(separator: "/").dropLast().last == "padstacks"
    }

    /// `packages/…/` for a package's `package.json`.
    private static func packageDirectory(_ packagePath: String) -> String {
        String(packagePath.dropLast("package.json".count))
    }

    private static func sanitizedName(_ name: String, fallback: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? fallback : cleaned
    }
}
