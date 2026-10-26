import Foundation

/// Watches the pools on screen for changes to their files, by anything: a
/// `git pull` in a pool checkout, Horizon or another window editing an item,
/// an MCP `pool_write` once the document's autosave writes it (item 152), a
/// pool in iCloud Drive syncing in. A changed pool is read again
/// (`HorizontalPoolLibrary.rescan`) once its folder has been quiet a moment,
/// and if what it lists changed, `poolsDidChangeNotification` names it.
///
/// What watches holds a `Lease` for the pools it shows: the Pools pane for
/// the pools it browses, an item editor for its item's. A pool is watched
/// while any lease names it.
///
/// On the Mac the change comes from FSEvents, which hears every writer; on
/// iPad, which has no FSEvents, from a file presenter, which hears the
/// writes that coordinate (the Files app, iCloud Drive, other apps). The
/// app's own writes announce themselves through `invalidateCache`.
@MainActor
final class HorizontalPoolWatcher {
    static let shared = HorizontalPoolWatcher()

    /// How long a pool's folder has to be quiet before it is read: a pull or
    /// an autosave writes many files.
    static let settleDelay: Duration = .milliseconds(500)

    /// Keeps pools watched until released, or until it goes away.
    final class Lease {
        fileprivate let id = UUID()
        fileprivate let paths: [String]
        private var released = false

        fileprivate init(paths: [String]) {
            self.paths = paths
        }

        func release() {
            guard !released else { return }
            released = true
            let id = id
            let paths = paths
            Task { @MainActor in HorizontalPoolWatcher.shared.release(id: id, paths: paths) }
        }

        deinit {
            release()
        }
    }

    private struct Watch {
        var url: URL
        var leases: Set<UUID>
        var source: HorizontalPoolChangeSource?
    }

    private var watches = [String: Watch]()
    private var settling = [String: Task<Void, Never>]()
    /// Bumped by each change seen, so a read overtaken by a later change
    /// leaves the announcement to the later one.
    private var generations = [String: Int]()
    /// Pools a read found changed whose change hasn't been announced yet,
    /// because a later change overtook the read: the later read may find
    /// nothing new, and still has to say so.
    private var unannounced = Set<String>()

    /// The pools being watched, by canonical path; for tests.
    var watchedPaths: Set<String> { Set(watches.keys) }

    /// Watches `poolURLs` until the lease is released.
    func watch(_ poolURLs: [URL]) -> Lease {
        let urls = poolURLs.map(HorizontalPoolLibrary.canonicalURL)
        let lease = Lease(paths: Array(Set(urls.map(\.path))))
        for url in urls {
            var watch = watches[url.path] ?? Watch(url: url, leases: [], source: nil)
            watch.leases.insert(lease.id)
            if watch.source == nil {
                let path = url.path
                watch.source = HorizontalPoolChangeSource(directory: url) { relativePaths in
                    Task { @MainActor in HorizontalPoolWatcher.shared.changed(path: path, relativePaths: relativePaths) }
                }
            }
            watches[url.path] = watch
        }
        return lease
    }

    fileprivate func release(id: UUID, paths: [String]) {
        for path in paths {
            guard var watch = watches[path] else { continue }
            watch.leases.remove(id)
            if watch.leases.isEmpty {
                watch.source?.stop()
                watches.removeValue(forKey: path)
                settling.removeValue(forKey: path)?.cancel()
                unannounced.remove(path)
            } else {
                watches[path] = watch
            }
        }
    }

    /// Something under a watched pool changed: read it again once it is
    /// quiet, unless all that changed is what a scan never reads.
    func changed(path: String, relativePaths: [String]) {
        guard let watch = watches[path], relativePaths.contains(where: Self.mayHoldItems) else {
            return
        }
        let generation = (generations[path] ?? 0) + 1
        generations[path] = generation
        settling[path]?.cancel()
        let url = watch.url
        settling[path] = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            let changed = await Task.detached(priority: .utility) {
                HorizontalPoolLibrary.rescan(poolURL: url)
            }.value
            if changed { self.unannounced.insert(path) }
            guard self.generations[path] == generation else { return }
            self.settling.removeValue(forKey: path)
            if self.unannounced.remove(path) != nil {
                HorizontalPoolPadstacks.invalidateCaches()
                HorizontalPoolLibrary.announcePoolsChanged([url])
            }
        }
    }

    /// Whether a changed path (relative to its pool) can change what a scan
    /// lists: a JSON file, a folder (one removed or renamed takes its items
    /// with it), or "" for "look at the whole folder again". The folders a
    /// scan skips, hidden files and 3D models never can.
    nonisolated static func mayHoldItems(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty else {
            return true
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0.hasPrefix(".") || HorizontalPoolLibrary.skippedDirectoryNames.contains($0.lowercased()) }) else {
            return false
        }
        let pathExtension = (components.last.map { ($0 as NSString).pathExtension } ?? "").lowercased()
        return pathExtension == "json" || pathExtension.isEmpty
    }
}

#if os(macOS)
/// A pool folder's changes as FSEvents reports them.
private final class HorizontalPoolChangeSource {
    private let events: HorizontalDirectoryEvents

    init?(directory: URL, handler: @escaping @Sendable ([String]) -> Void) {
        events = HorizontalDirectoryEvents(directory: directory, handler: handler)
        guard events.start(latency: 0.3) else {
            return nil
        }
    }

    func stop() {
        events.stop()
    }
}
#else
/// A pool folder's changes as file coordination reports them: the writes the
/// Files app, iCloud Drive and other apps make through a coordinator.
private final class HorizontalPoolChangeSource: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let root: String
    private let handler: @Sendable ([String]) -> Void

    init?(directory: URL, handler: @escaping @Sendable ([String]) -> Void) {
        presentedItemURL = directory
        root = directory.standardizedFileURL.path
        self.handler = handler
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    private func report(_ url: URL) {
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        handler([path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""])
    }

    func presentedItemDidChange() { handler([""]) }
    func presentedSubitemDidChange(at url: URL) { report(url) }
    func presentedSubitemDidAppear(at url: URL) { report(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        report(oldURL)
        report(newURL)
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        report(url)
        completionHandler(nil)
    }
}
#endif
