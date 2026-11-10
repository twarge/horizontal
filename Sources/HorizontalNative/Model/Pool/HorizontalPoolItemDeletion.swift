import Foundation
import HorizontalProjectIO

/// Deleting one item from a pool, as Horizon's pool manager deletes one
/// (`PoolNotebook::handle_delete`): the item's file, or a package's whole
/// directory with its own padstacks, after saying what uses it (Horizon's
/// Where Used). Here the files go to the Trash rather than away for good,
/// and the pool's scan is dropped so the item leaves the browser at once.
///
/// What uses an item is read from an index of the browsed pools plus every
/// registered pool that includes the item's pool, so a part in a pool built
/// on this one counts too.
struct HorizontalPoolItemDeletion {
    enum Refusal: LocalizedError, Equatable {
        case readOnlyOperation
        case projectPool
        case bundled
        case notInPool
        case notWritable(String)
        case inUse(String)

        var errorDescription: String? {
            switch self {
            case .readOnlyOperation:
                "Read-only operation is enabled in Horizontal."
            case .projectPool:
                "This is a project pool’s copy, which the project’s schematic and board draw from. Use Clean Up Project Pool to remove what the project no longer uses."
            case .bundled:
                "This item ships with Horizontal and can’t be deleted."
            case .notInPool:
                "The item’s file isn’t inside its pool’s folder."
            case .notWritable(let path):
                "Horizontal can’t write to “\(path)”, so the item can’t be deleted from this pool."
            case .inUse(let users):
                users
            }
        }
    }

    var item: HorizontalPoolLibraryItem
    /// The files and directories that go, a package's directory as one.
    var paths: [URL]
    /// The items naming this one (or, for a package, one of its own
    /// padstacks), apart from what is deleted with it, sorted by kind and
    /// name.
    var users: [HorizontalPoolLibraryItem]
    /// What the pool's own `pool.json` names it as: its default via or frame.
    var poolSettings: [String]
    /// The 3D models a package names that are outside its directory and
    /// stay, as Horizon leaves them: other packages may share them.
    var keptModels: [String]

    var isInUse: Bool { !users.isEmpty || !poolSettings.isEmpty }

    /// Horizon's Where Used, in a sentence: “Used by part “X” and entity “Y”
    /// in Pool.” Names the first eight and counts the rest.
    var usersDescription: String {
        var phrases = users.prefix(8).map { user in
            "\(user.category.singularTitle.lowercased()) “\(user.name)” (\(user.poolName))"
        }
        if users.count > 8 {
            phrases.append("\(users.count - 8) more")
        }
        phrases.append(contentsOf: poolSettings)
        guard !phrases.isEmpty else {
            return ""
        }
        return "“\(item.name)” is used by " + Self.list(phrases) + "."
    }

    private static func list(_ phrases: [String]) -> String {
        switch phrases.count {
        case 0: ""
        case 1: phrases[0]
        case 2: phrases[0] + " and " + phrases[1]
        default: phrases.dropLast().joined(separator: ", ") + " and " + (phrases.last ?? "")
        }
    }

    // MARK: - Checking

    /// Why the item can't be deleted at all, or nil. Being in use is not a
    /// refusal here: the caller warns about it (`isInUse`) and may go on.
    static func refusal(for item: HorizontalPoolLibraryItem, readOnlyOperation: Bool = false) -> Refusal? {
        if readOnlyOperation {
            return .readOnlyOperation
        }
        let poolURL = HorizontalPoolLibrary.canonicalURL(item.poolURL)
        let itemURL = HorizontalPoolLibrary.canonicalURL(item.url)
        let bundles = [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap { $0 }
            .map { HorizontalPoolLibrary.canonicalURL($0).path }
        if bundles.contains(where: { isInside(itemURL.path, $0) || isInside(poolURL.path, $0) }) {
            return .bundled
        }
        if HorizontalPoolRegistryStore.poolInfo(at: poolURL).uuid.lowercased() == HorizontalProjectArchive.projectPoolUUID {
            return .projectPool
        }
        guard isInside(itemURL.path, poolURL.path) else {
            return .notInPool
        }
        let fileManager = FileManager.default
        for url in [itemURL.deletingLastPathComponent(), itemURL] where !fileManager.isWritableFile(atPath: url.path) {
            return .notWritable(url.lastPathComponent)
        }
        return nil
    }

    /// What deleting the item takes and what it breaks. `index` is what the
    /// caller browses; registered pools including the item's pool are added.
    static func plan(
        for item: HorizontalPoolLibraryItem,
        index: HorizontalPoolLibraryIndex,
        readOnlyOperation: Bool = false
    ) throws -> HorizontalPoolItemDeletion {
        if let refusal = refusal(for: item, readOnlyOperation: readOnlyOperation) {
            throw refusal
        }
        let poolURL = HorizontalPoolLibrary.canonicalURL(item.poolURL)
        let itemURL = HorizontalPoolLibrary.canonicalURL(item.url)
        let index = widened(index, including: poolURL)

        var paths = [itemURL]
        var deleted = [HorizontalPoolLibraryReference(category: item.category, uuid: item.uuid)]
        var keptModels = [String]()
        if item.category == .package {
            let directory = itemURL.deletingLastPathComponent()
            let json = try JSONHelper.loadDictionary(from: itemURL)
            // A package beside others in one folder goes as its file alone:
            // the folder's padstacks may be theirs too.
            let ownsFolder = Self.ownsDirectory(itemURL, poolURL: poolURL)
            if ownsFolder {
                paths = [directory]
                deleted += localPadstackIDs(in: directory).map { HorizontalPoolLibraryReference(category: .padstack, uuid: $0) }
            }
            for model in json.dictionaryMap("models").values {
                guard let filename = model.string("filename"), !filename.isEmpty else { continue }
                let url = poolURL.appendingPathComponent(filename).standardizedFileURL
                if !(ownsFolder && isInside(url.path, directory.path)) {
                    keptModels.append(filename)
                }
            }
        }

        let deletedKeys = Set(deleted.map(\.key))
        var users = [HorizontalPoolLibraryItem]()
        var seen = Set<String>()
        for reference in deleted {
            for user in index.users(of: reference.category, uuid: reference.uuid)
            where !deletedKeys.contains(user.itemKey) && seen.insert(user.itemKey).inserted {
                users.append(user)
            }
        }
        users.sort { ($0.category.rawValue, $0.name.localizedLowercase) < ($1.category.rawValue, $1.name.localizedLowercase) }

        var poolSettings = [String]()
        let poolJSON = (try? JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("pool.json"))) ?? [:]
        if item.category == .padstack, poolJSON.string("default_via")?.lowercased() == item.uuid.lowercased() {
            poolSettings.append("the pool’s default via")
        }
        if item.category == .frame, poolJSON.string("default_frame")?.lowercased() == item.uuid.lowercased() {
            poolSettings.append("the pool’s default frame")
        }
        return HorizontalPoolItemDeletion(item: item, paths: paths, users: users,
                                          poolSettings: poolSettings, keptModels: keptModels.sorted())
    }

    // MARK: - Deleting

    /// How a file goes: the Trash, or, where the platform has none for that
    /// volume, away for good. Returns whether it went to the Trash.
    typealias Remover = (URL) throws -> Bool

    /// Moves the files to the Trash. With users, only when `breakingUsers`
    /// (Horizon's "Delete and break dependents"); without, the refusal names
    /// them. Then the pool is read again so the item disappears.
    @discardableResult
    func perform(breakingUsers: Bool = false, remove: Remover = HorizontalPoolItemDeletion.moveToTrash) throws -> Bool {
        if isInUse, !breakingUsers {
            throw Refusal.inUse(usersDescription)
        }
        var allTrashed = true
        defer {
            HorizontalPoolLibrary.invalidateCache(for: item.poolURL)
            HorizontalPoolPadstacks.invalidateCaches()
        }
        for path in paths {
            allTrashed = try remove(path) && allTrashed
        }
        return allTrashed
    }

    /// The platform's Trash. iPadOS has one only on some volumes (a file
    /// provider's, the Files app's Recently Deleted); elsewhere the item is
    /// removed, and the caller has said so before asking.
    static func moveToTrash(_ url: URL) throws -> Bool {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return true
        #else
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch let error as CocoaError where error.code == .featureUnsupported {
            try FileManager.default.removeItem(at: url)
            return false
        }
        #endif
    }

    // MARK: - Helpers

    private static func isInside(_ path: String, _ directory: String) -> Bool {
        path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// Whether a package's directory is its own, Horizon's
    /// `packages/…/<name>/package.json`, so it goes whole as Horizon removes
    /// it: not the pool's `packages/` (or the pool) itself, and holding no
    /// other package below.
    static func ownsDirectory(_ packageURL: URL, poolURL: URL) -> Bool {
        let directory = packageURL.deletingLastPathComponent().standardizedFileURL
        let pool = poolURL.standardizedFileURL
        guard packageURL.lastPathComponent == "package.json",
              directory.path != pool.path,
              directory.path != pool.appendingPathComponent("packages").standardizedFileURL.path,
              isInside(directory.path, pool.path) else {
            return false
        }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "package.json", url.deletingLastPathComponent().standardizedFileURL.path != directory.path {
                return false
            }
        }
        return true
    }

    /// The padstacks in a package's own `padstacks/` folder, by uuid.
    private static func localPadstackIDs(in directory: URL) -> [String] {
        let folder = directory.appendingPathComponent("padstacks", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.compactMap { url in
            guard let json = try? JSONHelper.loadDictionary(from: url), json.string("type") == "padstack" else { return nil }
            return json.string("uuid")?.lowercased()
        }
    }

    /// `index` with the items of every registered pool that includes `poolURL`.
    private static func widened(_ index: HorizontalPoolLibraryIndex, including poolURL: URL) -> HorizontalPoolLibraryIndex {
        let uuid = HorizontalPoolRegistryStore.poolInfo(at: poolURL).uuid.lowercased()
        let including = HorizontalPoolRegistryStore.poolURLs().filter { url in
            HorizontalPoolLibrary.canonicalURL(url).path != poolURL.path
                && HorizontalPoolLibrary.includedPoolUUIDs(of: url).contains(uuid)
        }
        guard !including.isEmpty else {
            return index
        }
        let known = HorizontalPoolItemCategory.allCases.flatMap { index.items(in: $0) }
        let extra = including.flatMap { url in
            HorizontalPoolLibrary.items(inPool: url, poolName: HorizontalPoolRegistryStore.poolInfo(at: url).name)
        }
        return HorizontalPoolLibraryIndex(items: HorizontalPoolLibrary.resolvingInheritance(known + extra))
    }
}
