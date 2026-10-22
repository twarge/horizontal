import Foundation
import HorizontalProjectIO

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
    /// The item's manufacturer (a part's attribute, else the `manufacturer`
    /// key), for the editors' completions.
    var manufacturer: String = ""
    /// A symbol's unit uuid (lowercased), so a unit's symbols can be found
    /// without opening every symbol file.
    var symbolUnitID: String = ""
    /// A part's value, description and parametric table, for searching by
    /// what a part is ("2.2uF") rather than what it is called.
    var value: String = ""
    var partDescription: String = ""
    /// A part's MPN, a derived part's taken from its base; empty for one with
    /// none (whose name is then its value), and for every other kind.
    var mpn: String = ""
    var parametric: [String: String] = [:]
    /// A part's package uuid (lowercased, empty when it has none).
    var packageID: String = ""
    /// A part flagged base_part, on itself or through its base: one to
    /// derive others from, which Horizon's part browser doesn't offer.
    var isBasePart = false
    /// A part's entity uuid (lowercased, empty when it has none), a derived
    /// part's taken from its base.
    var partEntityID: String = ""
    /// What a part's own file says. A scan reads each file alone, so a
    /// derived part's name, manufacturer, value, description, tags and
    /// package are its file's until `resolvingInheritance` works them out
    /// through its base.
    var partRecord: HorizontalPartRecord?
    /// Every browsed pool holding this item, its own first. A scan leaves it
    /// empty; the Pools pane fills it (`HorizontalPoolBrowserView.visibleItems`),
    /// so one row for a part cached in the project pool still names the pool
    /// it came from.
    var pools: [String] = []

    /// What the Pools pane's Pool column shows and its search matches.
    var poolsLabel: String {
        pools.isEmpty ? poolName : pools.joined(separator: " · ")
    }

    /// The kind and uuid, which is what makes two copies the same item.
    var itemKey: String { Self.key(category, uuid) }

    static func key(_ category: HorizontalPoolItemCategory, _ uuid: String) -> String {
        category.rawValue + "|" + uuid.lowercased()
    }
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
    /// Each unit's symbols (by lowercased unit uuid), sorted by name.
    private var symbolsByUnit: [String: [HorizontalPoolLibraryItem]]
    /// Every manufacturer the browsed pools name, sorted, for completions.
    let manufacturers: [String]
    /// Every tag the browsed pools use, sorted, for completions.
    let tags: [String]

    init(items: [HorizontalPoolLibraryItem]) {
        var itemsByKey = [String: HorizontalPoolLibraryItem]()
        var orderedItems = [HorizontalPoolLibraryItem]()
        // Spellings that differ only in case fold to the first one seen.
        var manufacturers = [String: String]()
        var tags = [String: String]()
        for item in items {
            let key = Self.key(item.category, item.uuid)
            if itemsByKey[key] == nil {
                itemsByKey[key] = item
                orderedItems.append(item)
            }
            let manufacturer = item.manufacturer.trimmingCharacters(in: .whitespaces)
            if !manufacturer.isEmpty, manufacturers[manufacturer.lowercased()] == nil {
                manufacturers[manufacturer.lowercased()] = manufacturer
            }
            for tag in item.tags.split(whereSeparator: \.isWhitespace) where !tag.isEmpty && tags[tag.lowercased()] == nil {
                tags[tag.lowercased()] = String(tag)
            }
        }
        self.itemsByKey = itemsByKey
        self.orderedItems = orderedItems
        self.symbolsByUnit = Dictionary(grouping: orderedItems.filter { $0.category == .symbol && !$0.symbolUnitID.isEmpty }) {
            $0.symbolUnitID
        }.mapValues(Self.sortedByName)
        self.manufacturers = manufacturers.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        self.tags = tags.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Every item of one kind, sorted by name.
    func items(in category: HorizontalPoolItemCategory) -> [HorizontalPoolLibraryItem] {
        Self.sortedByName(orderedItems.filter { $0.category == category })
    }

    /// The symbols drawn for a unit, sorted by name, as Horizon's entity
    /// preview lists them for a gate (`SELECT … FROM symbols WHERE unit=?
    /// ORDER BY name`).
    func symbols(forUnit unitID: String) -> [HorizontalPoolLibraryItem] {
        symbolsByUnit[unitID.lowercased()] ?? []
    }

    private static func sortedByName(_ items: [HorizontalPoolLibraryItem]) -> [HorizontalPoolLibraryItem] {
        items.sorted { ($0.name.localizedLowercase, $0.uuid) < ($1.name.localizedLowercase, $1.uuid) }
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
/// A pool another pool includes (`pools_included`) that none of the pools
/// found has: not registered, not named in the environment, not nearby.
struct HorizontalMissingPool: Equatable, Sendable {
    var uuid: String
    var includedBy: String
}

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

    /// A pool directory as one URL however it was reached: symlinks resolved,
    /// then standardized. A scan has to start from the real directory, since
    /// FileManager's enumerator doesn't descend into a root that is a link,
    /// and two spellings of one pool are one pool.
    static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Every item in a pool, each with the pool's canonical URL.
    static func items(inPool poolURL: URL, poolName: String) -> [HorizontalPoolLibraryItem] {
        let poolURL = canonicalURL(poolURL)
        let cacheKey = poolURL.path

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
        nearbyLock.lock()
        nearbyMisses.removeAll()
        nearbyLock.unlock()
    }

    static func invalidateCache(for poolURL: URL) {
        lock.lock()
        cache.removeValue(forKey: canonicalURL(poolURL).path)
        lock.unlock()
    }

    /// The names of the pools holding each item, by `itemKey`, in the order
    /// `items` come: the project pool first, as every scan orders them. Horizon
    /// keeps one row per uuid and marks where it came from; this is what lets
    /// a single row say so.
    static func holders(_ items: [HorizontalPoolLibraryItem]) -> [String: [String]] {
        var names = [String: [String]]()
        var seen = Set<String>()
        for item in items where seen.insert(item.itemKey + "|" + item.poolURL.standardizedFileURL.path).inserted {
            names[item.itemKey, default: []].append(item.poolName)
        }
        return names
    }

    /// The pools `holders` names for an item, `own` first.
    static func pools(holding key: String, own: String, holders: [String: [String]]) -> [String] {
        var others = holders[key] ?? []
        if let index = others.firstIndex(of: own) { others.remove(at: index) }
        return [own] + others
    }

    /// `item` naming every pool that holds it, its own first.
    static func naming(_ item: HorizontalPoolLibraryItem, holders: [String: [String]]) -> HorizontalPoolLibraryItem {
        var named = item
        named.pools = pools(holding: item.itemKey, own: item.poolName, holders: holders)
        return named
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
                url: url,
                manufacturer: category == .part
                    ? (attributeString(json["manufacturer"]) ?? "")
                    : (json.string("manufacturer") ?? ""),
                symbolUnitID: category == .symbol ? (json.string("unit")?.lowercased() ?? "") : "",
                value: category == .part ? (attributeString(json["value"]) ?? "") : "",
                partDescription: category == .part ? (attributeString(json["description"]) ?? "") : "",
                mpn: category == .part ? (attributeString(json["MPN"]) ?? "") : "",
                parametric: category == .part ? (json["parametric"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String } : [:],
                packageID: category == .part ? (json.string("package")?.lowercased() ?? "") : "",
                isBasePart: category == .part && HorizontalPartRecord(json: json).resolved(base: nil).isBasePart,
                partEntityID: category == .part ? (json.string("entity")?.lowercased() ?? "") : "",
                partRecord: category == .part ? HorizontalPartRecord(json: json) : nil
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

    /// Part items as Horizon's pool database records them: a derived
    /// part's name (its MPN), manufacturer, value, description, tags and
    /// package worked out through its base, where its own file may store
    /// nothing or a stale copy. A base is looked up among `items` (the
    /// first copy of a uuid, in scan order, so the project pool's wins),
    /// which is why this runs over every scanned pool together. Parametric
    /// data is never inherited and stays as the file has it.
    static func resolvingInheritance(_ items: [HorizontalPoolLibraryItem]) -> [HorizontalPoolLibraryItem] {
        var records = [String: HorizontalPartRecord]()
        for item in items where item.category == .part && records[item.uuid] == nil {
            records[item.uuid] = item.partRecord
        }
        var resolved = [String: HorizontalResolvedPart]()
        var resolving = Set<String>()
        func base(_ id: String?) -> HorizontalResolvedPart? {
            guard let id, let record = records[id], resolving.count < 8, !resolving.contains(id) else { return nil }
            if let done = resolved[id] { return done }
            resolving.insert(id)
            defer { resolving.remove(id) }
            let part = record.resolved(base: base(record.baseID))
            resolved[id] = part
            return part
        }
        return items.map { item in
            guard item.category == .part, let record = item.partRecord, record.baseID != nil else { return item }
            let part = record.resolved(base: base(record.baseID))
            var item = item
            item.name = [part.mpn, part.value].first { !$0.isEmpty } ?? item.url.deletingPathExtension().lastPathComponent
            item.detail = part.manufacturer
            item.manufacturer = part.manufacturer
            item.value = part.value
            item.mpn = part.mpn
            item.partDescription = part.description
            item.tags = part.tags.joined(separator: " ")
            item.packageID = part.packageID ?? ""
            item.isBasePart = part.isBasePart
            item.partEntityID = part.entityID?.lowercased() ?? ""
            return item
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
    /// ones, `$HORIZON_POOL`, `$HORIZONTAL_POOLS` and any horizon-pool
    /// checkout nearby. One none of those has is looked for by uuid around
    /// the pool (`nearbyPoolURLs`).
    static func includedPoolURLs(for poolURL: URL) -> [URL] {
        let included = includedPoolUUIDs(of: poolURL)
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
        let unresolved = Set(included.filter { urlsByUUID[$0] == nil })
        if !unresolved.isEmpty {
            urlsByUUID.merge(nearbyPoolURLs(withUUIDs: unresolved, around: poolURL)) { known, _ in known }
        }
        return included.compactMap { urlsByUUID[$0] }
    }

    /// The uuids in a pool's `pools_included`, lowercased. Every project pool
    /// shares one uuid, and the null uuid names nothing, so neither counts.
    static func includedPoolUUIDs(of poolURL: URL) -> [String] {
        let json = (try? JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("pool.json"))) ?? [:]
        let ignored: Set<String> = ["", HorizontalProjectArchive.projectPoolUUID, HorizontalProjectArchive.nullUUID]
        return (json["pools_included"] as? [String] ?? []).map { $0.lowercased() }.filter { !ignored.contains($0) }
    }

    /// The pools that pools in `urls` include and `urls` lacks, each with the
    /// name of a pool including it. A review names these once, rather than
    /// telling every part taken from one that it has no source.
    static func missingIncludedPools(among urls: [URL]) -> [HorizontalMissingPool] {
        let present = Set(urls.map { HorizontalPoolRegistryStore.poolInfo(at: $0).uuid.lowercased() })
        var missing = [HorizontalMissingPool]()
        var seen = Set<String>()
        for url in urls {
            for uuid in includedPoolUUIDs(of: url) where !present.contains(uuid) && seen.insert(uuid).inserted {
                missing.append(HorizontalMissingPool(uuid: uuid, includedBy: HorizontalPoolRegistryStore.poolInfo(at: url).name))
            }
        }
        return missing
    }

    private static let nearbyLock = NSLock()
    nonisolated(unsafe) private static var nearbyHits = [String: URL]()
    nonisolated(unsafe) private static var nearbyMisses = Set<String>()

    /// Included pools nothing registered names, found by uuid in the
    /// directories around the pool: each of the four above it (where
    /// horizon-pool is looked for too) and two levels into each. That finds a
    /// pool checked out beside the project, as Twinleaf Pool is beside Billo,
    /// even from a worker process, which can't see the pools the app has
    /// registered.
    ///
    /// The walk stops short of the home directory, whose children are the
    /// folders macOS asks permission for, and skips hidden directories and
    /// symlinks. A hit is remembered for the life of the process and checked
    /// again on use. A miss is remembered until `invalidateCache()`, so a
    /// project including a pool this machine lacks isn't searched for again
    /// until something asks the library to look afresh.
    static func nearbyPoolURLs(withUUIDs uuids: Set<String>, around poolURL: URL) -> [String: URL] {
        let pool = canonicalURL(poolURL)
        var found = [String: URL]()
        var wanted = Set<String>()
        nearbyLock.lock()
        for uuid in uuids {
            let key = pool.path + "|" + uuid
            if let hit = nearbyHits[key], HorizontalPoolRegistryStore.poolInfo(at: hit).uuid.lowercased() == uuid {
                found[uuid] = hit
            } else if !nearbyMisses.contains(key) {
                wanted.insert(uuid)
            }
        }
        nearbyLock.unlock()
        guard !wanted.isEmpty else {
            return found
        }

        let fileManager = FileManager.default
        let home = userHomePath
        var remaining = wanted
        var scanned = [String: URL]()
        var checked = Set([pool.path])
        var listed = Set<String>()
        func directories(in url: URL) -> [URL] {
            guard listed.insert(url.path).inserted else {
                return []
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            let entries = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])) ?? []
            return entries.filter { entry in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func check(_ directory: URL) {
            guard !remaining.isEmpty, checked.insert(directory.path).inserted,
                  fileManager.fileExists(atPath: directory.appendingPathComponent("pool.json").path) else {
                return
            }
            let uuid = HorizontalPoolRegistryStore.poolInfo(at: directory).uuid.lowercased()
            if remaining.remove(uuid) != nil {
                scanned[uuid] = directory
            }
        }
        var ancestor = pool.deletingLastPathComponent()
        for _ in 0..<4 {
            guard !remaining.isEmpty, ancestor.pathComponents.count > 3,
                  ancestor.path != home, !home.hasPrefix(ancestor.path + "/") else {
                break
            }
            let children = directories(in: ancestor)
            children.forEach(check)
            for child in children where !remaining.isEmpty {
                directories(in: child).forEach(check)
            }
            ancestor = ancestor.deletingLastPathComponent()
        }

        nearbyLock.lock()
        for uuid in wanted {
            let key = pool.path + "|" + uuid
            if let url = scanned[uuid] {
                nearbyHits[key] = url
            } else {
                nearbyMisses.insert(key)
            }
        }
        nearbyLock.unlock()
        return found.merging(scanned) { known, _ in known }
    }

    /// The user's own home directory, not a sandbox container's, which is
    /// what `NSHomeDirectory()` gives the app.
    private static var userHomePath: String {
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return URL(fileURLWithPath: String(cString: directory)).standardizedFileURL.path
    }

    /// Forgets what `nearbyPoolURLs` found, hits included.
    static func forgetNearbyPools() {
        nearbyLock.lock()
        nearbyHits.removeAll()
        nearbyMisses.removeAll()
        nearbyLock.unlock()
    }

    /// The pools an item editor indexes, root first so the item's own pool
    /// shadows the rest (the same precedence the browser and the padstack
    /// catalog use): the pool itself, the pools it includes, then every
    /// discovered base pool.
    static func editorPoolURLs(forPoolRoot poolURL: URL) -> [URL] {
        var result = [URL]()
        var seen = Set<String>()
        func add(_ url: URL) {
            let canonical = canonicalURL(url)
            if seen.insert(canonical.path).inserted {
                result.append(canonical)
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
