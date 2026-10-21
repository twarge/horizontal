import Foundation
import HorizontalProjectIO

/// The project pool's own items: the ones it keeps outside `<kind>/cache/`.
///
/// The loaders find an item at `<kind>/cache/<uuid>.json` (a package at
/// `packages/cache/<uuid>/package.json`), where Horizon's pool cache and
/// Horizontal put the copies they make, and look there first. Horizon indexes
/// the whole pool directory, though, so an item made in the project, by
/// Horizon's editors or a generator, can sit anywhere else under its kind's
/// directory, named for what it is: `symbols/calypso/LT5400.json`. Those are
/// found here by the uuid they carry, in one walk of the kind's directory that
/// leaves `cache/` out. A walk is kept until a directory it went through
/// changes, which is how a file added, removed or renamed there shows.
///
/// Only a project pool is walked: one whose `pool.json` names another pool
/// (a horizon-pool checkout a preview reads from) holds thousands of items in
/// flat directories, none of which a cache miss here is looking for.
enum HorizontalProjectPoolIndex {
    private struct Scan {
        var urls: [String: URL]
        /// Each directory walked, with its modification date then.
        var directoryDates: [String: Date]
        var lastUse: UInt64
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scans = [String: Scan]()
    nonisolated(unsafe) private static var uses: UInt64 = 0
    /// Walks kept, a kind of one pool each. A snapshot loads from a new
    /// temporary directory every time, so the least recently used make room.
    private static let capacity = 64

    /// The project-local file holding the item (a package's `package.json`),
    /// or nil when the project pool keeps none outside its cache.
    static func url(_ category: HorizontalPoolItemCategory, _ uuid: String, poolURL: URL) -> URL? {
        items(category, poolURL: poolURL)[uuid.lowercased()]
    }

    /// Every project-local item of the kind, by lowercased uuid. Of two files
    /// with one uuid, the first by path.
    static func items(_ category: HorizontalPoolItemCategory, poolURL: URL) -> [String: URL] {
        let directory = poolURL.appendingPathComponent(HorizontalPoolItemFactory.directoryName(for: category), isDirectory: true)
        let key = category.rawValue + "|" + directory.standardizedFileURL.path

        lock.lock()
        if var kept = scans[key], kept.directoryDates.allSatisfy({ modificationDate(atPath: $0.key) == $0.value }) {
            uses += 1
            kept.lastUse = uses
            scans[key] = kept
            lock.unlock()
            return kept.urls
        }
        lock.unlock()

        let scan = scan(category, directory: directory, poolURL: poolURL)
        lock.lock()
        uses += 1
        scans[key] = Scan(urls: scan.urls, directoryDates: scan.directoryDates, lastUse: uses)
        if scans.count > capacity, let oldest = scans.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            scans.removeValue(forKey: oldest)
        }
        lock.unlock()
        return scan.urls
    }

    private static func scan(
        _ category: HorizontalPoolItemCategory,
        directory: URL,
        poolURL: URL
    ) -> (urls: [String: URL], directoryDates: [String: Date]) {
        // Dated before it is listed, so a file added during the walk shows
        // as a change next time.
        var directoryDates = [directory.path: modificationDate(atPath: directory.path)]
        guard isProjectPool(poolURL) else {
            return ([:], directoryDates)
        }

        var files = [URL]()
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let enumerator, let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if enumerator.level == 1, url.lastPathComponent.caseInsensitiveCompare("cache") == .orderedSame {
                    enumerator.skipDescendants()
                } else {
                    directoryDates[url.path] = modificationDate(atPath: url.path)
                }
                continue
            }
            // A package is its directory's package.json; the padstacks and
            // models beside it are its own.
            let isItemFile = category == .package
                ? url.lastPathComponent == "package.json"
                : url.pathExtension.lowercased() == "json"
            if isItemFile {
                files.append(url)
            }
        }

        var urls = [String: URL]()
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let json = try? JSONHelper.loadDictionary(from: url),
                  let uuid = json.string("uuid")?.lowercased(),
                  urls[uuid] == nil else {
                continue
            }
            // A file of another kind doesn't count. An older padstack names
            // its own kind ("top", "via") under `type`, so only another pool
            // item kind rules a file out.
            if let type = json.string("type"), type != category.rawValue,
               HorizontalPoolItemCategory(rawValue: type) != nil {
                continue
            }
            urls[uuid] = url
        }
        return (urls, directoryDates)
    }

    /// Whether the pool is a project's: its `pool.json` gives the uuid Horizon
    /// gives every project pool, or there is none to say otherwise.
    private static func isProjectPool(_ poolURL: URL) -> Bool {
        let poolFile = poolURL.appendingPathComponent("pool.json")
        guard FileManager.default.fileExists(atPath: poolFile.path) else {
            return true
        }
        guard let uuid = (try? JSONHelper.loadDictionary(from: poolFile))?.string("uuid") else {
            return true
        }
        return uuid.caseInsensitiveCompare(HorizontalProjectArchive.projectPoolUUID) == .orderedSame
    }

    private static func modificationDate(atPath path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }
}
