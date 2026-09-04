import Foundation

/// The Horizon pool item kinds the library browser lists, in Horizon's pool
/// manager order.
enum HorizontalPoolItemCategory: String, CaseIterable, Identifiable {
    case unit
    case symbol
    case entity
    case padstack
    case package
    case part
    case frame
    case decal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unit: "Units"
        case .symbol: "Symbols"
        case .entity: "Entities"
        case .padstack: "Padstacks"
        case .package: "Packages"
        case .part: "Parts"
        case .frame: "Frames"
        case .decal: "Decals"
        }
    }

    var symbolName: String {
        switch self {
        case .unit: "u.square"
        case .symbol: "bolt"
        case .entity: "square.on.square"
        case .padstack: "circle.circle"
        case .package: "shippingbox"
        case .part: "list.bullet.rectangle"
        case .frame: "rectangle"
        case .decal: "seal"
        }
    }

    /// The column header for the category's detail column.
    var detailTitle: String {
        switch self {
        case .part: "Manufacturer"
        case .padstack: "Type"
        default: "Description"
        }
    }
}

/// One pool item as the library browser lists it.
struct HorizontalPoolLibraryItem: Identifiable, Hashable, Sendable {
    var id: String
    var uuid: String
    var name: String
    var detail: String
    var tags: String
    var category: HorizontalPoolItemCategory
    var poolName: String
    /// The root of the pool the item was found in — the directory carrying
    /// its `pool.json`. "Open in Pool" opens a window on this directory.
    var poolURL: URL
    var url: URL
}

/// Cross-reference lookup over the browsed pools' items by kind and uuid, so
/// a preview can resolve a symbol's unit, a package's padstacks, or a part's
/// entity and package through whichever pool carries them. Items arrive
/// project pool first, so a project's copy shadows the base pools' — the same
/// precedence the loaders use.
struct HorizontalPoolLibraryIndex: Sendable {
    static let empty = HorizontalPoolLibraryIndex(items: [])

    private var itemsByKey: [String: HorizontalPoolLibraryItem]
    /// The winning item per key, in scan order — what a picker lists.
    private var orderedItems: [HorizontalPoolLibraryItem]

    init(items: [HorizontalPoolLibraryItem]) {
        var itemsByKey = [String: HorizontalPoolLibraryItem]()
        var orderedItems = [HorizontalPoolLibraryItem]()
        for item in items {
            let key = Self.key(item.category, item.uuid)
            if itemsByKey[key] == nil {
                itemsByKey[key] = item
                orderedItems.append(item)
            }
        }
        self.itemsByKey = itemsByKey
        self.orderedItems = orderedItems
    }

    /// Every item of one kind, sorted by name.
    func items(in category: HorizontalPoolItemCategory) -> [HorizontalPoolLibraryItem] {
        orderedItems
            .filter { $0.category == category }
            .sorted { ($0.name.localizedLowercase, $0.uuid) < ($1.name.localizedLowercase, $1.uuid) }
    }

    func item(_ category: HorizontalPoolItemCategory, uuid: String) -> HorizontalPoolLibraryItem? {
        itemsByKey[Self.key(category, uuid)]
    }

    func name(_ category: HorizontalPoolItemCategory, uuid: String) -> String? {
        item(category, uuid: uuid)?.name
    }

    /// The item's JSON, read from wherever the scan found it.
    func json(_ category: HorizontalPoolItemCategory, uuid: String) -> JSONDictionary? {
        guard let item = item(category, uuid: uuid) else {
            return nil
        }
        return try? JSONHelper.loadDictionary(from: item.url)
    }

    private static func key(_ category: HorizontalPoolItemCategory, _ uuid: String) -> String {
        category.rawValue + "|" + uuid.lowercased()
    }
}

/// Scans whole pools for the library browser. A pool item is any JSON file
/// whose `type` names a pool item kind, wherever it lives — this covers both
/// the flat category directories of a horizon-pool checkout and a project
/// pool's `cache/` copies with one walk. Results are cached per pool path;
/// `invalidateCache` forces a rescan (the browser's Refresh).
enum HorizontalPoolLibrary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = [String: [HorizontalPoolLibraryItem]]()

    /// Directories that hold no pool JSON but plenty of files (3D models, git
    /// internals, Horizon's layer help): skipping them keeps the walk fast.
    private static let skippedDirectoryNames: Set<String> = [
        "3d_models", ".git", "layer_help", "tmp", "scripts", "versions",
    ]

    /// Why the pool directory can't be listed, or nil when it can. Under the
    /// sandbox a pool found by path — a horizon-pool checkout beside the
    /// projects — is visible (it exists) yet unreadable until the user grants
    /// access to its folder, and a scan of it would come back empty.
    static func accessError(for poolURL: URL) -> String? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: poolURL.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func items(inPool poolURL: URL, poolName: String) -> [HorizontalPoolLibraryItem] {
        let cacheKey = poolURL.standardizedFileURL.path

        lock.lock()
        let cached = cache[cacheKey]
        lock.unlock()
        if let cached {
            return cached
        }

        // An unreadable pool is not "empty": leave it uncached so the scan
        // after an access grant sees the real contents.
        guard accessError(for: poolURL) == nil else {
            return []
        }

        let items = scan(poolURL: poolURL, poolName: poolName)
        lock.lock()
        cache[cacheKey] = items
        lock.unlock()
        return items
    }

    static func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func scan(poolURL: URL, poolName: String) -> [HorizontalPoolLibraryItem] {
        var itemsByKey = [String: HorizontalPoolLibraryItem]()
        var cachedKeys = Set<String>()

        let enumerator = FileManager.default.enumerator(
            at: poolURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedDirectoryNames.contains(url.lastPathComponent.lowercased()) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "json",
                  let json = try? JSONHelper.loadDictionary(from: url),
                  let category = (json.string("type")).flatMap(HorizontalPoolItemCategory.init(rawValue:)),
                  let uuid = json.string("uuid") else {
                continue
            }

            // A pool's own item beats its project-pool cache copy, mirroring
            // the padstack catalog's rule.
            let key = category.rawValue + "|" + uuid.lowercased()
            let isCacheCopy = url.pathComponents.contains("cache")
            if itemsByKey[key] != nil, !(cachedKeys.contains(key) && !isCacheCopy) {
                continue
            }

            itemsByKey[key] = HorizontalPoolLibraryItem(
                id: poolURL.standardizedFileURL.path + "|" + key,
                uuid: uuid.lowercased(),
                name: itemName(json, category: category, url: url),
                detail: itemDetail(json, category: category),
                tags: (json["tags"] as? [String])?.joined(separator: " ") ?? "",
                category: category,
                poolName: poolName,
                poolURL: poolURL.standardizedFileURL,
                url: url
            )
            if isCacheCopy {
                cachedKeys.insert(key)
            } else {
                cachedKeys.remove(key)
            }
        }

        return itemsByKey.values.sorted {
            ($0.name.localizedLowercase, $0.uuid) < ($1.name.localizedLowercase, $1.uuid)
        }
    }

    private static func itemName(
        _ json: JSONDictionary,
        category: HorizontalPoolItemCategory,
        url: URL
    ) -> String {
        switch category {
        case .part:
            return attributeString(json["MPN"])
                ?? attributeString(json["value"])
                ?? url.deletingPathExtension().lastPathComponent
        default:
            return json.string("name") ?? url.deletingPathExtension().lastPathComponent
        }
    }

    private static func itemDetail(
        _ json: JSONDictionary,
        category: HorizontalPoolItemCategory
    ) -> String {
        switch category {
        case .part:
            return attributeString(json["manufacturer"]) ?? ""
        case .padstack:
            if let padstackType = json.string("padstack_type") {
                return padstackType
            }
            let type = json.string("type") ?? ""
            return type == "padstack" ? "" : type
        default:
            return attributeString(json["description"])
                ?? json.string("description")
                ?? ""
        }
    }

    /// Horizon part attributes serialize as `[inherited, value]` pairs; an
    /// inherited or empty value reads as absent (the base part carries it).
    private static func attributeString(_ value: Any?) -> String? {
        if let pair = value as? [Any], pair.count == 2, let string = pair[1] as? String {
            return string.isEmpty ? nil : string
        }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }
}

// MARK: - Editing support

extension HorizontalPoolLibrary {
    /// Posted after a pool item document was saved, carrying the bytes that
    /// went to disk. Open projects refresh their in-memory copy of the file
    /// from the payload (the document write may not have hit disk yet) and
    /// browsers rescan.
    static let itemDidSaveNotification = Notification.Name("HorizontalPoolItemDidSave")
    /// `userInfo` key carrying the `ItemDidSavePayload`.
    static let itemDidSavePayloadKey = "HorizontalPoolItemDidSavePayload"

    struct ItemDidSavePayload: Sendable {
        var url: URL
        var category: HorizontalPoolItemCategory
        var uuid: String
        var data: Data
    }

    /// The nearest ancestor of `itemURL` carrying a `pool.json`, or nil when
    /// the item lives outside any pool. Registered pools are consulted first
    /// so their security scopes are restored before the walk probes the
    /// filesystem (an item reopened from Recent Items after a relaunch would
    /// otherwise find its pool unreadable).
    static func poolRoot(forItemURL itemURL: URL) -> URL? {
        let standardized = itemURL.standardizedFileURL
        for registered in HorizontalPoolRegistryStore.poolURLs() {
            let root = registered.standardizedFileURL
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if standardized.path.hasPrefix(prefix) {
                return root
            }
        }
        var directory = standardized.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pool.json").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// The pools a standalone pool includes (`pools_included` uuids in its
    /// pool.json), found among the pools this app knows about: registered
    /// ones, `$HORIZON_POOL`, and any horizon-pool checkout nearby.
    static func includedPoolURLs(for poolURL: URL) -> [URL] {
        let json = (try? JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("pool.json"))) ?? [:]
        let included = (json["pools_included"] as? [String] ?? []).map { $0.lowercased() }
        guard !included.isEmpty else {
            return []
        }
        var urlsByUUID = [String: URL]()
        for url in HorizontalPoolPadstacks.basePoolURLs(for: poolURL) {
            let uuid = HorizontalPoolRegistryStore.poolInfo(at: url).uuid.lowercased()
            if !uuid.isEmpty, urlsByUUID[uuid] == nil {
                urlsByUUID[uuid] = url
            }
        }
        return included.compactMap { urlsByUUID[$0] }
    }

    /// The pools an item editor indexes, root first so the item's own pool
    /// shadows the rest (the same precedence the browser and the padstack
    /// catalog use): the pool itself, the pools it includes, then every
    /// discovered base pool.
    static func editorPoolURLs(forPoolRoot poolURL: URL) -> [URL] {
        var result = [URL]()
        var seen = Set<String>()
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                result.append(standardized)
            }
        }
        add(poolURL)
        for url in includedPoolURLs(for: poolURL) {
            add(url)
        }
        for url in HorizontalPoolPadstacks.basePoolURLs(for: poolURL) {
            add(url)
        }
        return result
    }
}
