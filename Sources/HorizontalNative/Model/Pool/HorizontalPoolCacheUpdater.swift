import Foundation
import HorizontalProjectIO

enum HorizontalPartLibraryStatus: String, Sendable {
    case current, updateAvailable, locallyModified, sourceUnavailable, projectOnly

    var title: String {
        switch self {
        case .current: "Current"
        case .updateAvailable: "Update available"
        case .locallyModified: "Modified in project"
        case .sourceUnavailable: "Source unavailable"
        case .projectOnly: "Project-only"
        }
    }

    var symbol: String {
        switch self {
        case .current: "checkmark.circle"
        case .updateAvailable: "arrow.triangle.2.circlepath"
        case .locallyModified: "pencil.circle"
        case .sourceUnavailable: "questionmark.circle"
        case .projectOnly: "folder"
        }
    }
}

struct HorizontalPoolCacheChange: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var before: Data?
    var after: Data
    var fields: [String]
    var locallyModified: Bool
    var unverified: Bool
    var blockingReason: String?
    var origin: HorizontalPoolCacheProvenance.Origin

    var title: String {
        if let json = try? JSONHelper.loadDictionary(from: after) {
            return json.string("name") ?? json.string("uuid") ?? path
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct HorizontalPartLibraryReview: Identifiable, Sendable {
    var id: String
    var name: String
    var status: HorizontalPartLibraryStatus
    var references: [String]
    var changes: [HorizontalPoolCacheChange] = []
    var dependencies: Set<String> = []
    var origins: [String: HorizontalPoolCacheProvenance.Origin] = [:]
    var message: String = ""
    var canUpdate: Bool {
        !changes.isEmpty && status != .sourceUnavailable && changes.allSatisfy { $0.blockingReason == nil }
    }
    var needsConfirmation: Bool { changes.contains { $0.locallyModified || $0.unverified } }
}

struct HorizontalPoolCacheReview: Sendable {
    var parts: [HorizontalPartLibraryReview]
    var projectFiles: [String: Data]
    var sourceDigests: [URL: String]

    let digest: String

    init(parts: [HorizontalPartLibraryReview], projectFiles: [String: Data], sourceDigests: [URL: String]) {
        self.parts = parts
        self.projectFiles = projectFiles
        self.sourceDigests = sourceDigests
        let changes = parts.flatMap(\.changes).map {
            "\($0.path):\(HorizontalProjectTransaction.digest($0.after)):\($0.origin.poolUUID):\($0.origin.sourcePath)"
        }.sorted()
        let inputs = projectFiles.keys.sorted().map { "\($0):\(HorizontalProjectTransaction.digest(projectFiles[$0]!))" }
        let sources = sourceDigests.keys.sorted { $0.path < $1.path }.map { "\($0.path):\(sourceDigests[$0]!)" }
        digest = HorizontalProjectTransaction.digest(Data((inputs + changes + sources).joined(separator: "\n").utf8))
    }

    func affectedParts(selecting ids: Set<String>) -> [HorizontalPartLibraryReview] {
        let paths = Set(parts.filter { ids.contains($0.id) }.flatMap(\.changes).map(\.path))
        return parts.filter { !$0.dependencies.isDisjoint(with: paths) }
    }

    /// Preflight is repeated on Apply; neither this planner nor review writes files.
    func updates(selecting ids: Set<String>, allowProjectChanges: Bool = false) throws -> [String: Data] {
        guard !ids.isEmpty, ids.isSubset(of: Set(parts.map(\.id))) else {
            throw HorizontalDispatchError.invalidParams("Select project part UUIDs from the library review.")
        }
        let selected = parts.filter { ids.contains($0.id) }
        guard selected.allSatisfy(\.canUpdate) else {
            throw HorizontalDispatchError.failed("A selected part cannot be updated. Review its source or pin/pad mapping first.")
        }
        let changes = selected.flatMap(\.changes)
        let paths = Set(changes.map(\.path))
        // A shared dependency can overwrite edits in a part that was not checked.
        let affected = affectedParts(selecting: ids)
        guard !affected.contains(where: { $0.status == .sourceUnavailable }) else {
            throw HorizontalDispatchError.failed("A shared dependency affects a part whose source could not be verified.")
        }
        guard allowProjectChanges || !affected.flatMap(\.changes).contains(where: {
            paths.contains($0.path) && ($0.locallyModified || $0.unverified)
        }) else {
            throw HorizontalDispatchError.failed("Updating would replace locally modified or unverified project copies. Explicit confirmation is required.")
        }
        try requireSourcesCurrent()
        var result = [String: Data]()
        var metadata = try HorizontalPoolCacheProvenance.load(projectFiles[HorizontalPoolCacheProvenance.path])
        for change in changes {
            if let previous = result[change.path], previous != change.after {
                throw HorizontalDispatchError.failed("Selected parts disagree about a shared library item.")
            }
            result[change.path] = change.after
            metadata.files[change.path] = change.origin
        }
        for row in selected {
            for (path, origin) in row.origins {
                let contents = result[path] ?? projectFiles[path]
                if let contents, try HorizontalPoolCacheProvenance.digest(contents, path: path) == origin.baseline {
                    metadata.files[path] = origin
                }
            }
        }
        result[HorizontalPoolCacheProvenance.path] = try metadata.data()
        return result
    }

    func requireSourcesCurrent() throws {
        for (url, digest) in sourceDigests {
            guard let data = try? Data(contentsOf: url), HorizontalProjectTransaction.digest(data) == digest else {
                throw HorizontalDispatchError.failed("The source library changed during review. Refresh before updating.")
            }
        }
    }
}

enum HorizontalPoolCacheUpdater {
    /// Read-only documents can omit pool bytes from their lightweight archive.
    static func filesOnDisk(in poolURL: URL) throws -> [String: Data] {
        if let error = HorizontalPoolLibrary.accessError(for: poolURL) { throw HorizontalDispatchError.failed(error) }
        var result = [String: Data]()
        let enumerator = FileManager.default.enumerator(at: poolURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true else { continue }
            result[try HorizontalPoolCacheProvenance.relativePath(url, in: poolURL)] = try Data(contentsOf: url)
        }
        return result
    }

    static func applying(_ review: HorizontalPoolCacheReview, selecting ids: Set<String>,
                         allowProjectChanges: Bool, to archive: HorizontalProjectArchive,
                         poolDirectory: String) throws -> HorizontalProjectArchive {
        guard files(in: archive, poolDirectory: poolDirectory) == review.projectFiles else {
            throw HorizontalDispatchError.failed("The project library changed during review. Refresh before updating.")
        }
        var next = archive
        for (path, data) in try review.updates(selecting: ids, allowProjectChanges: allowProjectChanges) {
            try next.replaceRegularFileData(relativePath: poolDirectory + "/" + path, with: data)
        }
        return next
    }

    static func validate(_ archive: HorizontalProjectArchive, against project: HorizontalProject) throws {
        let next = try HorizontalProject.loadSnapshot(of: archive)
        func counts(_ project: HorizontalProject) -> [String: Int] {
            Dictionary(project.diagnostics.map {
                ($0.message.replacingOccurrences(of: project.baseURL.path, with: "<project>"), 1)
            }, uniquingKeysWith: +)
        }
        let before = counts(project)
        guard counts(next).allSatisfy({ $0.value <= before[$0.key, default: 0] }) else {
            throw HorizontalDispatchError.failed("The update introduces project load errors. Nothing was changed.")
        }
    }

    /// Pool-relative files, always taken from the current document/archive.
    static func files(in archive: HorizontalProjectArchive, poolDirectory: String) -> [String: Data] {
        let prefix = poolDirectory.hasSuffix("/") ? poolDirectory : poolDirectory + "/"
        return Dictionary(uniqueKeysWithValues: archive.regularFilePaths.compactMap { path in
            guard path.hasPrefix(prefix), let data = archive.regularFileData(relativePath: path) else { return nil }
            return (String(path.dropFirst(prefix.count)), data)
        })
    }

    static func references(in archive: HorizontalProjectArchive, project: HorizontalProject? = nil) -> [String: [String]] {
        var result = [String: Set<String>]()
        for path in archive.regularFilePaths where path.hasSuffix(".json") {
            guard let data = archive.regularFileData(relativePath: path),
                  let json = try? JSONHelper.loadDictionary(from: data), json.string("type") == "block" else { continue }
            for (_, component) in json.dictionaryMap("components") {
                if let part = component.string("part")?.lowercased(), let refdes = component.string("refdes") {
                    result[part, default: []].insert(refdes)
                }
            }
        }
        if result.isEmpty, let project {
            let schematics = project.schematics.map(\.schematic) + (project.schematic.map { [$0] } ?? [])
            let placements = schematics.flatMap { $0.sheets.flatMap(\.symbols) } + (project.board?.packages ?? [])
            for placement in placements {
                if let details = placement.componentDetails, let part = details.partID {
                    result[part.lowercased(), default: []].insert(details.refdes)
                }
            }
        }
        return result.mapValues { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    static func review(poolURL: URL, files: [String: Data], sourcePools: [URL],
                       partIDs: [String]? = nil, references: [String: [String]] = [:],
                       sourceOverrides: [String: URL] = [:]) throws -> HorizontalPoolCacheReview {
        let metadata = try HorizontalPoolCacheProvenance.load(files[HorizontalPoolCacheProvenance.path])
        var seenPools = Set([poolURL.resolvingSymlinksInPath().standardizedFileURL.path])
        var pools = sourcePools.map { $0.resolvingSymlinksInPath().standardizedFileURL }.filter { seenPools.insert($0.path).inserted }
        for source in sourceOverrides.values {
            for pool in [source] + HorizontalPoolLibrary.includedPoolURLs(for: source) {
                let canonical = pool.resolvingSymlinksInPath().standardizedFileURL
                if seenPools.insert(canonical.path).inserted { pools.append(canonical) }
            }
        }
        var poolByUUID = [String: URL]()
        for pool in pools {
            let uuid = HorizontalPoolRegistryStore.poolInfo(at: pool).uuid
            if poolByUUID[uuid] == nil { poolByUUID[uuid] = pool }
        }
        let sourceItems = pools.flatMap {
            HorizontalPoolLibrary.items(inPool: $0, poolName: HorizontalPoolRegistryStore.poolInfo(at: $0).name)
        }
        let jsons = files.compactMapValues { try? JSONHelper.loadDictionary(from: $0) }
        let partPaths = preferredPaths(jsons).filter { jsons[$0]?.string("type") == "part" }
        let baseIDs = Set(partPaths.compactMap { jsons[$0]?.string("base")?.lowercased() })
        let visibleIDs = partIDs ?? partPaths.compactMap { jsons[$0]?.string("uuid")?.lowercased() }.filter { !baseIDs.contains($0) }
        let ids = Set(visibleIDs).union(references.keys)
        var reviews = [HorizontalPartLibraryReview]()
        var sourceDigests = [URL: String]()

        for id in ids.sorted() {
            guard let partPath = partPaths.first(where: { jsons[$0]?.string("uuid")?.lowercased() == id }),
                  let part = jsons[partPath] else { continue }
            let mpn = part["MPN"] as? [Any]
            var row = HorizontalPartLibraryReview(id: id, name: (mpn?.last as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                                 status: .current, references: references[id] ?? [])
            row.dependencies = dependencies(of: id, jsons: jsons)
            guard partPath.hasPrefix("parts/cache/") else {
                row.status = .projectOnly
                reviews.append(row)
                continue
            }
            do {
                // Provenance wins over browsing order. Legacy copies require a unique source.
                var preferred = [String: String]()
                for path in row.dependencies {
                    if let origin = metadata.files[path], let json = jsons[path],
                       let type = json.string("type"), let uuid = json.string("uuid") {
                        preferred[type + "|" + uuid.lowercased()] = origin.poolUUID
                        guard let pool = poolByUUID[origin.poolUUID] else {
                            throw HorizontalDispatchError.failed("Source library \(origin.poolUUID) is not registered or available.")
                        }
                        if let error = HorizontalPoolLibrary.accessError(for: pool) { throw HorizontalDispatchError.failed(error) }
                        let sourceURL = try sourceItems.first {
                            $0.category.rawValue == type && $0.uuid == uuid.lowercased()
                                && HorizontalPoolRegistryStore.poolInfo(at: $0.poolURL).uuid == origin.poolUUID
                        }?.url ?? HorizontalPoolCacheProvenance.safeURL(origin.sourcePath, in: pool)
                        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                            throw HorizontalDispatchError.failed("Missing in source library: \(origin.sourcePath)")
                        }
                    }
                }
                let grouped = Dictionary(grouping: sourceItems) { $0.category.rawValue + "|" + $0.uuid }
                let explicitPools = metadata.files[partPath] == nil ? sourceOverrides[id].map {
                    [$0] + HorizontalPoolLibrary.includedPoolURLs(for: $0)
                } ?? [] : []
                var resolved = [HorizontalPoolLibraryItem]()
                for (key, candidates) in grouped {
                    if let origin = preferred[key] {
                        if let match = candidates.first(where: { HorizontalPoolRegistryStore.poolInfo(at: $0.poolURL).uuid == origin }) {
                            resolved.append(match)
                        }
                    } else if let match = explicitPools.lazy.compactMap({ pool in candidates.first {
                        $0.poolURL.resolvingSymlinksInPath() == pool.resolvingSymlinksInPath()
                    } }).first {
                        resolved.append(match)
                    } else if candidates.count == 1 {
                        resolved.append(candidates[0])
                    }
                }
                guard let sourcePart = resolved.first(where: { $0.category == .part && $0.uuid == id }) else {
                    throw HorizontalDispatchError.failed("No unambiguous source for this part. Choose its source library to continue.")
                }
                let empty = HorizontalPoolCacheDestination(read: { _ in nil }, list: { _ in [] })
                let planned = try HorizontalPoolCacheImporter.plan(sourcePart, into: poolURL, destination: empty, sourceItems: resolved)
                let plannedByPath = try Dictionary(uniqueKeysWithValues: planned.map {
                    (try HorizontalPoolCacheProvenance.relativePath($0.url, in: poolURL), $0.data)
                })
                let nextMetadata = try HorizontalPoolCacheProvenance.load(plannedByPath[HorizontalPoolCacheProvenance.path])
                row.origins = nextMetadata.files
                // Never drop an existing symbol or other dependency still used by the design.
                for path in row.dependencies where path != partPath {
                    guard ["part", "entity", "unit", "symbol", "package"].contains(jsons[path]?.string("type") ?? "") else { continue }
                    guard plannedByPath[path] != nil else {
                        throw HorizontalDispatchError.failed("The library no longer supplies \(path). Remap the part before updating.")
                    }
                }
                row.dependencies.formUnion(nextMetadata.files.keys)
                for path in nextMetadata.files.keys.sorted() {
                    guard let after = plannedByPath[path], let origin = nextMetadata.files[path],
                          let sourcePool = poolByUUID[origin.poolUUID] else { continue }
                    let sourceURL = try HorizontalPoolCacheProvenance.safeURL(origin.sourcePath, in: sourcePool)
                    let rawSource = try Data(contentsOf: sourceURL)
                    let normalizedSource = try normalizedSource(rawSource, path: path, poolUUID: origin.poolUUID)
                    guard try HorizontalPoolCacheProvenance.digest(normalizedSource, path: path) == origin.baseline else {
                        throw HorizontalDispatchError.failed("The library changed while it was being checked. Refresh and try again.")
                    }
                    let sourceDigest = HorizontalProjectTransaction.digest(rawSource)
                    if let previous = sourceDigests[sourceURL], previous != sourceDigest {
                        throw HorizontalDispatchError.failed("The library changed during review.")
                    }
                    sourceDigests[sourceURL] = sourceDigest
                    let before = files[path]
                    let oldDigest = try before.map { try HorizontalPoolCacheProvenance.digest($0, path: path) }
                    guard oldDigest != origin.baseline else { continue }
                    var reason = blockingReason(before: before, after: after)
                    if let next = try? JSONHelper.loadDictionary(from: after), let uuid = next.string("uuid"), let type = next.string("type"),
                       jsons.contains(where: { !$0.key.contains("/cache/") && $0.value.string("uuid") == uuid && $0.value.string("type") == type }) {
                        reason = "A project-local item overrides this dependency. Review it in Pools before updating."
                    }
                    let modified = metadata.files[path].map { oldDigest != nil && oldDigest != $0.baseline } ?? false
                    row.changes.append(.init(path: path, before: before, after: after,
                                             fields: changedFields(before: before, after: after), locallyModified: modified,
                                             unverified: before != nil && metadata.files[path] == nil,
                                             blockingReason: reason, origin: origin))
                }
                if row.changes.contains(where: \.locallyModified) { row.status = .locallyModified }
                else if !row.changes.isEmpty { row.status = .updateAvailable }
                if let reason = row.changes.compactMap(\.blockingReason).first { row.message = reason }
                else if row.needsConfirmation { row.message = "This update replaces project edits or older copies whose import baseline is unknown." }
            } catch {
                row.status = .sourceUnavailable
                row.message = HorizontalCanvasProjectEdit.message(for: error)
                row.changes = []
            }
            reviews.append(row)
        }
        return .init(parts: reviews, projectFiles: files, sourceDigests: sourceDigests)
    }

    private static func normalizedSource(_ data: Data, path: String, poolUUID: String) throws -> Data {
        guard path.hasSuffix("/package.json") else { return data }
        var json = try JSONHelper.loadDictionary(from: data)
        if let filename = json.string("model_filename") {
            json["model_filename"] = "3d_models/cache/\(poolUUID)/\(filename)"
        }
        var models = json.dictionaryMap("models")
        for (id, var model) in models {
            if let filename = model.string("filename") {
                model["filename"] = "3d_models/cache/\(poolUUID)/\(filename)"
                models[id] = model
            }
        }
        if !models.isEmpty { json["models"] = models }
        return try HorizontalHorizonJSONWriter.data(json)
    }

    private static func dependencies(of partID: String, jsons: [String: JSONDictionary]) -> Set<String> {
        var visited = Set<String>()
        let paths = preferredPaths(jsons)
        func visit(_ type: String, _ uuid: String) {
            guard let path = paths.first(where: { jsons[$0]?.string("type") == type && jsons[$0]?.string("uuid")?.lowercased() == uuid.lowercased() }),
                  visited.insert(path).inserted, let json = jsons[path] else { return }
            switch type {
            case "part":
                if let base = json.string("base") { visit("part", base) }
                if let entity = json.string("entity") { visit("entity", entity) }
                if let package = json.string("package") { visit("package", package) }
            case "entity":
                for gate in json.dictionaryMap("gates").values {
                    if let unit = gate.string("unit") { visit("unit", unit) }
                }
            case "unit":
                for symbol in jsons.values where symbol.string("type") == "symbol" && symbol.string("unit")?.lowercased() == uuid.lowercased() {
                    if let id = symbol.string("uuid") { visit("symbol", id) }
                }
            case "package":
                let prefix = String(path.dropLast("package.json".count)) + "padstacks/"
                let locals = jsons.filter { $0.key.hasPrefix(prefix) }
                visited.formUnion(locals.keys)
                let localIDs = Set(locals.values.compactMap { $0.string("uuid")?.lowercased() })
                for pad in json.dictionaryMap("pads").values {
                    if let padstack = pad.string("padstack"), !localIDs.contains(padstack.lowercased()) { visit("padstack", padstack) }
                }
                if let model = json.string("model_filename") { visited.insert(model) }
                for model in json.dictionaryMap("models").values {
                    if let filename = model.string("filename") { visited.insert(filename) }
                }
            default: break
            }
        }
        visit("part", partID)
        return visited
    }

    private static func preferredPaths(_ jsons: [String: JSONDictionary]) -> [String] {
        jsons.keys.sorted {
            let lhsCached = $0.contains("/cache/")
            let rhsCached = $1.contains("/cache/")
            if lhsCached != rhsCached { return !lhsCached }
            return $0 < $1
        }
    }

    private static func changedFields(before: Data?, after: Data) -> [String] {
        guard let next = try? JSONHelper.loadDictionary(from: after) else { return ["3D model content"] }
        guard let before, let old = try? JSONHelper.loadDictionary(from: before) else { return ["New library item"] }
        return Set(old.keys).union(next.keys).subtracting(["_imp"]).sorted().filter {
            !NSDictionary(dictionary: ["value": old[$0] ?? NSNull()]).isEqual(to: ["value": next[$0] ?? NSNull()])
        }
    }

    private static func blockingReason(before: Data?, after: Data) -> String? {
        guard let before, let old = try? JSONHelper.loadDictionary(from: before), let next = try? JSONHelper.loadDictionary(from: after) else { return nil }
        let type = old.string("type") ?? ""
        if old.string("uuid") != next.string("uuid") || type != next.string("type") { return "The library item's identity changed." }
        let fixed: [String]
        switch type {
        case "part": fixed = ["base", "entity", "package", "pad_map"]
        case "entity": fixed = []
        case "symbol": fixed = ["unit"]
        default: fixed = []
        }
        for key in fixed where !NSDictionary(dictionary: ["value": old[key] ?? NSNull()]).isEqual(to: ["value": next[key] ?? NSNull()]) {
            return "\(key.replacingOccurrences(of: "_", with: " ").capitalized) changed. Remap the part before updating."
        }
        if type == "entity" {
            let oldGates = old.dictionaryMap("gates").mapValues { $0.string("unit") ?? "" }
            let nextGates = next.dictionaryMap("gates").mapValues { $0.string("unit") ?? "" }
            if oldGates != nextGates { return "Gate assignments changed. Remap the part before updating." }
        }
        let collection = type == "package" ? "pads" : (["unit", "symbol"].contains(type) ? "pins" : nil)
        if let collection, !Set(old.dictionaryMap(collection).keys).isSubset(of: Set(next.dictionaryMap(collection).keys)) {
            return "Connected \(collection) may have been removed. Remap the part before updating."
        }
        return nil
    }
}
