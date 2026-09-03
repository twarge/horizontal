import Foundation
#if canImport(Combine)
import Combine
#endif

/// A base pool the user has registered with the app: a directory carrying a
/// Horizon `pool.json` (e.g. a horizon-pool checkout). Registered pools feed
/// the library browser and fill the padstack pickers of every open project.
struct HorizontalRegisteredPool: Identifiable, Hashable {
    var url: URL
    var name: String
    var uuid: String

    var id: String { url.path }
}

/// The persistence and sandbox layer under `HorizontalPoolRegistry`:
/// registered pool paths plus their security-scoped bookmarks, stored in user
/// defaults. Thread-safe and callable from any context, so the board parser
/// and padstack catalog can consult the registry without touching the main
/// actor. Bookmark scopes are restored lazily on first use and kept for the
/// process lifetime, mirroring HorizontalFolderAccessStore.
enum HorizontalPoolRegistryStore {
    private static let pathsKey = "HorizontalRegisteredPoolPaths"
    private static let bookmarksKey = "HorizontalRegisteredPoolBookmarks"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeScopePaths = Set<String>()
    /// Test hook: registry state lives in this defaults instance.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The registered pool directories, in registration order, with their
    /// security scopes active. Paths whose directory no longer exists are
    /// still returned (the UI shows them as missing rather than silently
    /// forgetting the registration).
    static func poolURLs() -> [URL] {
        let paths = defaults.stringArray(forKey: pathsKey) ?? []
        restoreScopes(for: paths)
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Registers a pool directory. Returns false when the directory does not
    /// carry a `pool.json` (not a pool). Idempotent for already-registered
    /// paths; the bookmark is refreshed either way so a re-pick after a move
    /// heals the grant.
    @discardableResult
    static func addPool(at url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: standardized.appendingPathComponent("pool.json").path
        ) else {
            return false
        }

        var paths = defaults.stringArray(forKey: pathsKey) ?? []
        if !paths.contains(standardized.path) {
            paths.append(standardized.path)
            defaults.set(paths, forKey: pathsKey)
        }
        storeBookmark(for: standardized)
        return true
    }

    static func removePool(at url: URL) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: pathsKey) ?? []
        paths.removeAll { $0 == path }
        defaults.set(paths, forKey: pathsKey)

        var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: path)
        defaults.set(bookmarks, forKey: bookmarksKey)
    }

    /// Reads a registered pool's display identity from its `pool.json`.
    static func poolInfo(at url: URL) -> HorizontalRegisteredPool {
        let json = (try? JSONHelper.loadDictionary(from: url.appendingPathComponent("pool.json"))) ?? [:]
        return HorizontalRegisteredPool(
            url: url,
            name: json.string("name") ?? url.lastPathComponent,
            uuid: json.string("uuid") ?? ""
        )
    }

    // MARK: - Security scope

    private static func storeBookmark(for url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(options: options) else {
            return
        }
        var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        bookmarks[url.path] = data
        defaults.set(bookmarks, forKey: bookmarksKey)

        lock.lock()
        defer { lock.unlock() }
        if !activeScopePaths.contains(url.path), url.startAccessingSecurityScopedResource() {
            activeScopePaths.insert(url.path)
        }
    }

    private static func restoreScopes(for paths: [String]) {
        let bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        lock.lock()
        defer { lock.unlock() }
        for path in paths where !activeScopePaths.contains(path) {
            guard let data = bookmarks[path] else {
                continue
            }
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() else {
                continue
            }
            activeScopePaths.insert(path)
        }
    }
}

/// The UI face of the registered-pools store: an observable list for the
/// library browser's Pools menu. All mutations invalidate the padstack
/// catalogs so open documents' pickers pick up the new pools immediately.
@MainActor
final class HorizontalPoolRegistry: ObservableObject {
    static let shared = HorizontalPoolRegistry()

    @Published private(set) var pools: [HorizontalRegisteredPool] = []

    private init() {
        reload()
    }

    @discardableResult
    func addPool(at url: URL) -> Bool {
        guard HorizontalPoolRegistryStore.addPool(at: url) else {
            return false
        }
        reload()
        HorizontalPoolPadstacks.invalidateCaches()
        return true
    }

    func removePool(_ pool: HorizontalRegisteredPool) {
        HorizontalPoolRegistryStore.removePool(at: pool.url)
        reload()
        HorizontalPoolPadstacks.invalidateCaches()
    }

    private func reload() {
        pools = HorizontalPoolRegistryStore.poolURLs().map(HorizontalPoolRegistryStore.poolInfo(at:))
    }
}
