import Foundation

/// A pool padstack the inspector pickers can offer: normalized UUID, display
/// name, and Horizon padstack type ("via", "hole", "mechanical", "top", ...).
struct HorizontalPoolPadstackInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    /// Lives in the package being edited (`<package>/padstacks/`), not the pool.
    var isPackageLocal = false
}

/// Scans a pool's global `padstacks/` directory (including the project-pool
/// `padstacks/cache/`) and answers "which padstacks of a given type can this
/// board reference", plus on-demand padstack JSON loads for parameter
/// defaults. Padstack files are keyed by their embedded `uuid`, not their
/// filename, so name-based pool filenames resolve too. Results are cached per
/// pool URL — pools don't change under a running editor.
enum HorizontalPoolPadstacks {
    private struct Catalog {
        var infos: [HorizontalPoolPadstackInfo]
        var urlsByID: [String: URL]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalogCache = [String: Catalog]()
    nonisolated(unsafe) private static var jsonCache = [String: JSONDictionary]()

    /// All padstacks of the given types, sorted by display name.
    static func padstacks(ofTypes types: Set<String>, poolURL: URL) -> [HorizontalPoolPadstackInfo] {
        catalog(for: poolURL).infos.filter { types.contains($0.type) }
    }

    /// The display name for one padstack UUID, if the pool knows it.
    static func padstackName(id: String, poolURL: URL) -> String? {
        let normalized = normalizedID(id)
        return catalog(for: poolURL).infos.first { $0.id == normalized }?.name
    }

    /// The raw padstack JSON (parameters_required, parameter_set defaults, …).
    static func padstack(id: String, poolURL: URL) -> JSONDictionary? {
        let normalized = normalizedID(id)
        let cacheKey = poolURL.path + "|" + normalized

        lock.lock()
        let cached = jsonCache[cacheKey]
        lock.unlock()
        if let cached {
            return cached
        }

        guard let url = catalog(for: poolURL).urlsByID[normalized],
              let json = try? JSONHelper.loadDictionary(from: url) else {
            return nil
        }
        lock.lock()
        jsonCache[cacheKey] = json
        lock.unlock()
        return json
    }

    private static func catalog(for poolURL: URL) -> Catalog {
        let cacheKey = poolURL.path

        lock.lock()
        let cached = catalogCache[cacheKey]
        lock.unlock()
        if let cached {
            return cached
        }

        let catalog = scanPadstacks(poolURL: poolURL)
        lock.lock()
        catalogCache[cacheKey] = catalog
        lock.unlock()
        return catalog
    }

    private static func scanPadstacks(poolURL: URL) -> Catalog {
        var infosByID = [String: HorizontalPoolPadstackInfo]()
        var urlsByID = [String: URL]()
        var cachedIDs = Set<String>()

        scanPadstacksDirectory(
            poolURL.appendingPathComponent("padstacks"),
            infosByID: &infosByID,
            urlsByID: &urlsByID,
            cachedIDs: &cachedIDs
        )

        // Base pools discovered near the project only FILL IN padstacks the
        // project pool doesn't have; project-pool entries always win, so a
        // project's own (possibly customized) copy is never shadowed.
        for basePoolURL in basePoolURLs(for: poolURL) {
            var baseInfos = [String: HorizontalPoolPadstackInfo]()
            var baseURLs = [String: URL]()
            var baseCachedIDs = Set<String>()
            scanPadstacksDirectory(
                basePoolURL.appendingPathComponent("padstacks"),
                infosByID: &baseInfos,
                urlsByID: &baseURLs,
                cachedIDs: &baseCachedIDs
            )
            for (id, info) in baseInfos where infosByID[id] == nil {
                infosByID[id] = info
                urlsByID[id] = baseURLs[id]
            }
        }

        let infos = infosByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        return Catalog(infos: infos, urlsByID: urlsByID)
    }

    private static func scanPadstacksDirectory(
        _ padstacksURL: URL,
        infosByID: inout [String: HorizontalPoolPadstackInfo],
        urlsByID: inout [String: URL],
        cachedIDs: inout Set<String>
    ) {
        let enumerator = FileManager.default.enumerator(
            at: padstacksURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "json",
                  let json = try? JSONHelper.loadDictionary(from: url),
                  let uuid = json.string("uuid") else {
                continue
            }

            let id = normalizedID(uuid)
            let isCacheCopy = url.pathComponents.contains("cache")
            // A pool padstack beats its project-pool cache copy; among
            // same-rank duplicates the first one found wins.
            if let _ = infosByID[id], !(cachedIDs.contains(id) && !isCacheCopy) {
                continue
            }

            infosByID[id] = HorizontalPoolPadstackInfo(
                id: id,
                name: json.string("name") ?? String(id.prefix(8)),
                type: padstackType(of: json)
            )
            urlsByID[id] = url
            if isCacheCopy {
                cachedIDs.insert(id)
            } else {
                cachedIDs.remove(id)
            }
        }
    }

    /// Base pools reachable from a project pool: pools the user registered in
    /// the library browser first, then the directory named by `$HORIZON_POOL`,
    /// then any `horizon-pool` directory (carrying a `pool.json`) next to the
    /// project or up to a few levels above it — covering the common "checkout
    /// of horizon-pool beside the projects" layout. The project pool itself is
    /// never returned.
    static func basePoolURLs(for poolURL: URL) -> [URL] {
        var results = [URL]()
        var seen = Set([poolURL.standardizedFileURL.path])

        func addIfPool(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.appendingPathComponent("pool.json").path),
                  seen.insert(standardized.path).inserted else {
                return
            }
            results.append(standardized)
        }

        for registered in HorizontalPoolRegistryStore.poolURLs() {
            addIfPool(registered)
        }
        if let environmentPool = ProcessInfo.processInfo.environment["HORIZON_POOL"], !environmentPool.isEmpty {
            addIfPool(URL(fileURLWithPath: environmentPool, isDirectory: true))
        }
        var ancestor = poolURL.deletingLastPathComponent()
        for _ in 0..<4 {
            addIfPool(ancestor.appendingPathComponent("horizon-pool"))
            ancestor = ancestor.deletingLastPathComponent()
        }
        return results
    }

    /// Drops every cached catalog and padstack JSON, so the next lookup
    /// rescans. Called when the registered-pool list changes.
    static func invalidateCaches() {
        lock.lock()
        catalogCache.removeAll()
        jsonCache.removeAll()
        lock.unlock()
    }

    /// Makes sure the project pool itself carries this padstack, copying it
    /// verbatim from a discovered base pool into `padstacks/cache/<uuid>.json`
    /// when it is missing — the same self-contained cache Horizon's pool
    /// update maintains, so the project stays openable in Horizon and this
    /// app's parser (which reads only the project pool) resolves it on reload.
    /// Returns false when the padstack exists nowhere reachable.
    @discardableResult
    static func ensureCached(id: String, poolURL: URL) -> Bool {
        let normalized = normalizedID(id)
        let cacheURL = poolURL
            .appendingPathComponent("padstacks")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(normalized).json")
        let directURL = poolURL
            .appendingPathComponent("padstacks")
            .appendingPathComponent("\(normalized).json")
        if FileManager.default.fileExists(atPath: cacheURL.path)
            || FileManager.default.fileExists(atPath: directURL.path) {
            return true
        }

        guard let sourceURL = catalog(for: poolURL).urlsByID[normalized],
              let data = try? Data(contentsOf: sourceURL) else {
            return false
        }
        // A catalog hit inside the project pool with a non-UUID filename
        // (name-based pool files) also counts as present — don't duplicate it.
        if sourceURL.standardizedFileURL.path.hasPrefix(poolURL.standardizedFileURL.path) {
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// The padstack's kind ("via", "hole", "top", "through", "mechanical", …).
    /// Pool cache copies carry it under `padstack_type` — their `type` is the
    /// generic pool-item marker "padstack" — while raw pool files carry the
    /// kind directly under `type`.
    private static func padstackType(of json: JSONDictionary) -> String {
        if let padstackType = json.string("padstack_type") {
            return padstackType
        }
        let type = json.string("type") ?? ""
        return type == "padstack" ? "" : type
    }

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }
}
