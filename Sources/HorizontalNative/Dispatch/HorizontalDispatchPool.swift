import Foundation
import HorizontalProjectIO

/// Pool search and import for the dispatch layer.
///
/// `list_parts` answers from the project pool alone — the self-contained cache
/// Horizon keeps beside a project. Everything a project *could* use lives in
/// the base pools it draws from, and until now nothing on this surface could
/// see them, so a caller could not name a part the project had never used.
/// These methods browse the same pools the app's library pane browses, and
/// copy a part with its whole dependency chain into the project pool.
enum HorizontalDispatchPool {
    /// The pools a project draws from, project pool first: its own pool, the
    /// pools that pool includes, then every discovered base pool. Matches the
    /// precedence the library browser and the padstack catalog use.
    ///
    /// Discovery finds pools registered with the app, `HORIZON_POOL`, and
    /// `horizon-pool` directories above the project. A worker process has its
    /// own user defaults and so cannot see the app's registrations, which is
    /// why `pool_path` names one directly.
    static func poolURLs(for entry: HorizontalDispatchProjectEntry, params: JSONDictionary = [:]) throws -> [URL] {
        guard let poolDirectory = entry.project.poolDirectory else {
            throw HorizontalDispatchError.failed("The project has no pool directory.")
        }
        var urls = HorizontalPoolLibrary.editorPoolURLs(
            forPoolRoot: entry.project.baseURL.appendingPathComponent(poolDirectory)
        )
        guard let path = params.string("pool_path"), !path.isEmpty else {
            return urls
        }
        let requested = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: requested.appendingPathComponent("pool.json").path) else {
            throw HorizontalDispatchError.notFound("\(requested.path) carries no pool.json, so it is not a pool.")
        }
        if let existing = urls.firstIndex(where: { $0.standardizedFileURL.path == requested.path }) {
            // Named on its own, a pool the project already draws from narrows
            // the search to itself. The project pool stays, so items it holds
            // are still reported as the project's own.
            urls = existing == 0 ? [urls[0]] : [urls[0], urls[existing]]
        } else {
            urls = [urls[0], requested]
        }
        return urls
    }

    /// Every item in those pools, tagged with the pool it came from. The
    /// project pool comes first, so `seenInProject` marks the uuids a project
    /// already carries.
    static func scan(_ poolURLs: [URL]) -> (items: [HorizontalPoolLibraryItem], pools: [JSONDictionary], inProject: Set<String>) {
        var items = [HorizontalPoolLibraryItem]()
        var pools = [JSONDictionary]()
        var inProject = Set<String>()
        for (index, url) in poolURLs.enumerated() {
            let info = HorizontalPoolRegistryStore.poolInfo(at: url)
            let error = HorizontalPoolLibrary.accessError(for: url)
            let found = error == nil ? HorizontalPoolLibrary.items(inPool: url, poolName: info.name) : []
            var json: JSONDictionary = ["name": info.name, "uuid": info.uuid, "path": url.path,
                                        "is_project_pool": index == 0, "item_count": found.count]
            if let error {
                // An unreadable pool is not an empty one; say which it was, so
                // a caller is not told a part is missing when it is unreachable.
                json["unreadable"] = error
            }
            pools.append(json)
            if index == 0 {
                inProject = Set(found.map { key($0.category, $0.uuid) })
            }
            items.append(contentsOf: found)
        }
        return (items, pools, inProject)
    }

    private static func key(_ category: HorizontalPoolItemCategory, _ uuid: String) -> String {
        category.rawValue + "|" + uuid.lowercased()
    }

    static func itemJSON(_ item: HorizontalPoolLibraryItem, inProject: Set<String>) -> JSONDictionary {
        [
            "uuid": item.uuid,
            "kind": item.category.rawValue,
            "name": item.name,
            "detail": item.detail,
            "manufacturer": item.manufacturer,
            "tags": item.tags.split(whereSeparator: \.isWhitespace).map(String.init),
            "pool": item.poolName,
            "pool_path": item.poolURL.path,
            "path": item.url.path,
            "in_project_pool": inProject.contains(key(item.category, item.uuid))
        ]
    }

    /// `search_pool`: the pools a project draws from, filtered by kind and a
    /// case-insensitive substring of name, description, manufacturer, tags or
    /// uuid.
    @Sendable static func search(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let urls = try poolURLs(for: entry, params: params)
        var kinds = Set(HorizontalPoolItemCategory.allCases)
        if let kind = params.string("kind"), !kind.isEmpty {
            guard let category = HorizontalPoolItemCategory(rawValue: kind) else {
                throw HorizontalDispatchError.invalidParams(
                    "Unknown kind \(kind). Known: \(HorizontalPoolItemCategory.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            kinds = [category]
        }
        let limit = min(max(params.int("limit") ?? 50, 1), 500)
        let query = (params.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let (items, pools, inProject) = scan(urls)

        var seen = Set<String>()
        let matched = items
            .filter { kinds.contains($0.category) && matches(query, $0) }
            // The project pool is scanned first, so its copy of a uuid wins.
            .filter { seen.insert(key($0.category, $0.uuid)).inserted }
            .sorted { ($0.name.localizedLowercase, $0.uuid) < ($1.name.localizedLowercase, $1.uuid) }
        return [
            "pools": pools,
            "total": matched.count,
            "truncated": matched.count > limit,
            "items": matched.prefix(limit).map { itemJSON($0, inProject: inProject) }
        ] as JSONDictionary
    }

    private static func matches(_ query: String, _ item: HorizontalPoolLibraryItem) -> Bool {
        guard !query.isEmpty else { return true }
        for field in [item.name, item.detail, item.manufacturer, item.tags, item.uuid]
        where field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        return false
    }

    /// `get_pool_item`: one pool item's JSON, read through the project's own
    /// view of its pool. Editing an item means reading it first, and reading it
    /// off disk would miss what an unsaved document holds — and is refused
    /// outright when the pool sits inside another app's container.
    @Sendable static func getItem(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let uuid = params.string("uuid")?.lowercased(), !uuid.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass \"uuid\": the pool item to read. search_pool finds one.")
        }
        var kinds = HorizontalPoolItemCategory.allCases
        if let kind = params.string("kind") {
            guard let category = HorizontalPoolItemCategory(rawValue: kind) else {
                throw HorizontalDispatchError.invalidParams(
                    "Unknown kind \(kind). Known: \(HorizontalPoolItemCategory.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            kinds = [category]
        }
        let urls = try poolURLs(for: entry, params: params)
        let (items, _, inProject) = scan(urls)
        let matches = items.filter { kinds.contains($0.category) && $0.uuid == uuid }
        guard let item = matches.first else {
            throw HorizontalDispatchError.notFound("No pool item \(uuid) in \(urls.map(\.lastPathComponent).joined(separator: ", ")).")
        }
        guard matches.count == 1 || Set(matches.map(\.category)).count == 1 else {
            throw HorizontalDispatchError.ambiguous("More than one kind of pool item has the uuid \(uuid); pass \"kind\".",
                                                    candidates: matches.map { $0.category.rawValue })
        }
        // A project-pool item is read through the snapshot, so an unsaved
        // change to it is what comes back; a base pool's is read from its file.
        let json: JSONDictionary
        if let snapshot = entry.snapshot, let cached = snapshot.json(at: item.url) {
            json = cached
        } else {
            guard let loaded = try? JSONHelper.loadDictionary(from: item.url) else {
                throw HorizontalDispatchError.notFound("Could not read \(item.url.path).")
            }
            json = loaded
        }
        return ["uuid": item.uuid, "kind": item.category.rawValue, "name": item.name,
                "pool": item.poolName, "pool_path": item.poolURL.path, "path": item.url.path,
                "in_project_pool": inProject.contains(key(item.category, item.uuid)),
                "item": json] as JSONDictionary
    }

    /// `import_pool_part`: stage a part and everything it needs — entity,
    /// units, symbols, package, padstacks and 3D models — into the project
    /// pool cache, so `ensure_component` can name it. Runs through the same
    /// transaction as any other edit; nothing is written on a dry run.
    @Sendable static func importPart(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let reference = params.string("part")?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass \"part\": a pool part uuid or MPN.")
        }
        let urls = try poolURLs(for: entry, params: params)
        let (items, _, inProject) = scan(urls)
        let parts = items.filter { $0.category == .part }
        let normalized = reference.lowercased()
        var found = parts.filter { $0.uuid == normalized }
        if found.isEmpty {
            found = parts.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        }
        guard !found.isEmpty else {
            throw HorizontalDispatchError.notFound(
                "No part \(reference) in \(urls.map(\.lastPathComponent).joined(separator: ", ")). Use search_pool to find one, "
                    + "or name the pool's directory with pool_path — a worker process cannot see the pools registered in the app."
            )
        }
        // The scan is project-pool first, so more than one match means genuinely
        // different parts sharing an MPN, not a pool copy of the same uuid.
        let unique = found.reduce(into: [HorizontalPoolLibraryItem]()) { result, item in
            if !result.contains(where: { $0.uuid == item.uuid }) { result.append(item) }
        }
        guard unique.count == 1, let item = unique.first else {
            throw HorizontalDispatchError.ambiguous(
                "\(unique.count) parts are named \(reference); pass the uuid.",
                candidates: unique.map(\.uuid)
            )
        }
        guard let poolDirectory = entry.project.poolDirectory else {
            throw HorizontalDispatchError.failed("The project has no pool directory.")
        }
        let projectPoolURL = entry.project.baseURL.appendingPathComponent(poolDirectory)
        // The library scan and the padstack catalog cache per pool path, so a
        // project pool that just grew has to be rescanned before the next
        // search reports what it now holds.
        defer {
            HorizontalPoolLibrary.invalidateCache()
            HorizontalPoolPadstacks.invalidateCaches()
        }
        return try HorizontalDispatchMutation.execute(session: session, entry: entry, params: params) { store in
            // The project pool the importer sees is the document's archive, not
            // the last-saved copy on disk: an unsaved edit that already cached
            // half a package must not be cached again.
            let destination = HorizontalPoolCacheDestination(
                read: { try store.read($0) },
                list: { directory in
                    guard let prefix = store.relativePath(for: directory).map({ $0.hasSuffix("/") ? $0 : $0 + "/" }) else { return [] }
                    return store.archive.regularFilePaths
                        .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
                        .map { entry.project.baseURL.appendingPathComponent($0) }
                }
            )
            let planned = try HorizontalPoolCacheImporter.plan(item, into: projectPoolURL, destination: destination)
            var written = [String]()
            for file in planned {
                if let existing = try store.read(file.url), existing == file.data { continue }
                try store.write(file.data, to: file.url)
                written.append(file.url.path)
            }
            return [
                "part": item.uuid,
                "mpn": item.name,
                "pool": item.poolName,
                "already_cached": inProject.contains(key(.part, item.uuid)),
                "written": written,
                "applied": written.count
            ]
        }
    }
}
