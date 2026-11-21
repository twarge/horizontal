import Foundation

/// The folder Horizontal keeps its caches in: the STEP meshes and the DigiKey
/// stock records. The .noindex extension keeps Spotlight out: these are a
/// cache, not the user's files, and a folder named so is the one marker
/// Spotlight honours (a `.metadata_never_index` file inside a folder is
/// ignored). Temporary files need nothing: a sandboxed app's are under
/// `/var/folders`, which Spotlight doesn't index.
enum HorizontalCachesDirectory {
    static let name = "Horizontal.noindex"

    /// Where the caches lived before they were kept out of Spotlight.
    static let legacyName = "Horizontal"

    /// The folder in the user's caches directory, or nil when there is none.
    static let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        .map { directory(in: $0) }

    /// The folder in `caches`, the old folder moved there first when it is
    /// the only one, so the meshes and stock records already fetched stay. A
    /// failed move leaves a cold cache, nothing worse.
    static func directory(in caches: URL) -> URL {
        let url = caches.appendingPathComponent(name, isDirectory: true)
        let legacy = caches.appendingPathComponent(legacyName, isDirectory: true)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: url)
        }
        return url
    }
}
