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

    init(items: [HorizontalPoolLibraryItem]) {
        var itemsByKey = [String: HorizontalPoolLibraryItem]()
        for item in items {
            let key = Self.key(item.category, item.uuid)
            if itemsByKey[key] == nil {
                itemsByKey[key] = item
            }
        }
        self.itemsByKey = itemsByKey
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

    static func items(inPool poolURL: URL, poolName: String) -> [HorizontalPoolLibraryItem] {
        let cacheKey = poolURL.standardizedFileURL.path

        lock.lock()
        let cached = cache[cacheKey]
        lock.unlock()
        if let cached {
            return cached
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
