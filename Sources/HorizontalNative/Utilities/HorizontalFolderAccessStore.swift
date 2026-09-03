#if os(macOS)
import AppKit
import Foundation
import os

/// Folder access for the sandboxed app, persisted as app-scoped security
/// bookmarks in user preferences.
///
/// Opening a `.horizontal` package or any file through the system open panel /
/// Finder grants sandbox access to exactly that item. Two flows need more than
/// that:
///  - opening a bare project file (`.hprj`): the loaders read sibling
///  files (board/board.json, blocks, pool, planes) from the enclosing folder;
///  - exports: they write to a folder *outside* the project package (the
///  default is a sibling "<Name> Export" directory).
/// For those we prompt once for the enclosing folder, store an app-scoped
/// security bookmark in `UserDefaults`, and silently restore it on later runs.
///
/// Every entry point degrades to a no-op when the process already has access
/// (e.g. unsandboxed builds, or paths inside an opened package), so the store
/// is safe to call unconditionally.
@MainActor
enum HorizontalFolderAccessStore {
    private static let defaultsKey = "HorizontalFolderAccessBookmarks"
    private static let logger = Logger(subsystem: "com.twarge.horizontal", category: "FolderAccess")

    /// Folders whose security scope we have started this session, keyed by
    /// standardized path. Kept for the app's lifetime; the scope ends when the
    /// process exits.
    private static var activeScopes = [String: URL]()

    // MARK: - Project opening

    /// Ensures the loaders can read everything a project at `url` references.
    /// For files inside a `.horizontal` package this is a no-op (the package
    /// grant covers it). For bare project files it restores or prompts for the
    /// enclosing folder, plus the pool directory when the project references a
    /// pool outside that folder.
    static func prepareProjectAccess(for url: URL) async {
        guard !isInsideHorizontalPackage(url) else {
            return
        }

        let folder = url.deletingLastPathComponent().standardizedFileURL
        await ensureAccess(
            to: folder,
            requiresWrite: false,
            message: "Horizontal needs access to the project folder to read its board, schematic and pool files. Grant access to “\(folder.lastPathComponent)”."
        )

        if let poolFolder = escapedPoolDirectory(projectFileURL: url, projectFolder: folder) {
            await ensureAccess(
                to: poolFolder,
                requiresWrite: false,
                message: "This project references a parts pool outside its folder. Grant access to “\(poolFolder.lastPathComponent)” to load pads and packages."
            )
        }
    }

    /// Whether the project's sibling files can actually be read.
    ///
    /// A Horizon `.hprj` is a JSON file whose board, schematic, blocks and pool
    /// live BESIDE it, but opening a bare `.hprj` from Finder or the open panel
    /// grants the sandbox exactly that one file. Without the enclosing-folder
    /// grant every sibling read is denied — and `HorizontalProject.load` treats an
    /// unreadable sibling as a non-fatal diagnostic, so the project would open
    /// with an empty board and empty panes rather than saying why. Callers use
    /// this to refuse the open instead.
    ///
    /// Files inside a `.horizontal` package are covered by the package's own
    /// grant, so they always report accessible.
    static func hasProjectFolderAccess(for url: URL) -> Bool {
        guard !isInsideHorizontalPackage(url) else {
            return true
        }
        return hasAccess(to: url.deletingLastPathComponent().standardizedFileURL, requiresWrite: false)
    }

    /// Explains a denied project folder in terms of what the user has to do.
    /// Names both the project and the folder, since "grant access to a folder"
    /// is meaningless without knowing which one macOS will ask about.
    static func projectFolderAccessMessage(for url: URL) -> String {
        let projectName = url.lastPathComponent
        let folderName = url.deletingLastPathComponent().lastPathComponent
        return """
        Horizontal doesn’t have permission to read the folder that contains “\(projectName)”.

        A Horizon project is a .hprj file plus the board, schematic and pool files stored next to it, so Horizontal needs access to the enclosing folder “\(folderName)” — not just the project file.

        Choose Grant Access below, then select “\(folderName)” when macOS asks.
        """
    }

    // MARK: - Pool opening

    /// Ensures a pool opened by its `pool.json` can be browsed: the open
    /// grant covers that one file, and the browser lists the whole folder.
    static func preparePoolAccess(for poolJSONURL: URL) async {
        let folder = poolJSONURL.deletingLastPathComponent().standardizedFileURL
        await ensureAccess(
            to: folder,
            requiresWrite: false,
            message: "Horizontal needs access to the pool folder to list its parts, symbols and packages. Grant access to “\(folder.lastPathComponent)”."
        )
    }

    static func hasPoolFolderAccess(for poolJSONURL: URL) -> Bool {
        hasAccess(to: poolJSONURL.deletingLastPathComponent().standardizedFileURL, requiresWrite: false)
    }

    static func poolFolderAccessMessage(for poolJSONURL: URL) -> String {
        let folderName = poolJSONURL.deletingLastPathComponent().lastPathComponent
        return """
        Horizontal doesn’t have permission to read the folder that contains this pool.json.

        A Horizon pool is a folder of parts, symbols, packages and padstacks with a pool.json at its root, so Horizontal needs access to the whole folder “\(folderName)” — not just the pool.json file.

        Choose Grant Access below, then select “\(folderName)” when macOS asks.
        """
    }

    // MARK: - Exports

    /// Ensures the export target directory (which may not exist yet) can be
    /// created and written. Prompts for the nearest existing ancestor folder
    /// when no stored grant covers it.
    static func prepareExportAccess(to targetDirectory: URL) async {
        let target = targetDirectory.standardizedFileURL
        let existing = nearestExistingDirectory(for: target)
        await ensureAccess(
            to: existing,
            requiresWrite: true,
            message: "Horizontal needs permission to write exports to “\(target.lastPathComponent)”. Grant access to “\(existing.lastPathComponent)”."
        )
    }

    // MARK: - Core

    /// Restores a stored grant covering `folder` or, failing that, shows an
    /// open panel rooted at `folder` and stores the chosen folder's bookmark.
    ///
    /// The panel is presented with `begin` and awaited, NOT `runModal()`:
    /// a modal session started from inside SwiftUI's initial document `.task`
    /// aborts immediately (the panel "cancels" itself within a frame), which
    /// silently skipped the grant.
    private static func ensureAccess(to folder: URL, requiresWrite: Bool, message: String) async {
        if hasAccess(to: folder, requiresWrite: requiresWrite) {
            return
        }
        if restoreBookmarkCovering(folder), hasAccess(to: folder, requiresWrite: requiresWrite) {
            return
        }

        logger.notice("prompting for folder access: \(folder.path, privacy: .public)")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = message
        panel.prompt = "Grant Access"

        NSApplication.shared.activate()
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        guard response == .OK, let chosen = panel.url else {
            logger.notice("folder access prompt dismissed for \(folder.path, privacy: .public)")
            return
        }
        logger.notice("folder access granted for \(chosen.path, privacy: .public)")
        storeBookmark(for: chosen.standardizedFileURL)
    }

    /// Probes with real filesystem operations, not `access(2)`-based checks
    /// (`isReadableFile`/`isWritableFile`): the sandbox answers `access(2)`
    /// from POSIX permissions, reporting paths as accessible that actual
    /// reads or writes will then be denied on.
    private static func hasAccess(to folder: URL, requiresWrite: Bool) -> Bool {
        if requiresWrite {
            let probe = folder.appendingPathComponent(".horizontal-write-probe-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
                return false
            }
            try? FileManager.default.removeItem(at: probe)
            return true
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// Resolves and activates the first stored bookmark whose folder is an
    /// ancestor of (or equal to) `folder`.
    private static func restoreBookmarkCovering(_ folder: URL) -> Bool {
        let targetPath = folder.standardizedFileURL.path
        var bookmarks = storedBookmarks()
        for (path, data) in bookmarks where covers(ancestorPath: path, path: targetPath) {
            if activeScopes[path] != nil {
                continue
            }
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                bookmarks.removeValue(forKey: path)
                continue
            }
            guard resolved.startAccessingSecurityScopedResource() else {
                continue
            }
            activeScopes[path] = resolved
            if isStale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope]) {
                bookmarks[path] = refreshed
            }
            persist(bookmarks)
            return true
        }
        persist(bookmarks)
        return false
    }

    private static func storeBookmark(for folder: URL) {
        guard let data = try? folder.bookmarkData(options: [.withSecurityScope]) else {
            return
        }
        var bookmarks = storedBookmarks()
        bookmarks[folder.path] = data
        persist(bookmarks)
        if folder.startAccessingSecurityScopedResource() {
            activeScopes[folder.path] = folder
        }
    }

    // MARK: - Helpers

    private static func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private static func persist(_ bookmarks: [String: Data]) {
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    private static func covers(ancestorPath: String, path: String) -> Bool {
        path == ancestorPath || path.hasPrefix(ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/")
    }

    private static func isInsideHorizontalPackage(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0.lowercased().hasSuffix(".horizontal") }
    }

    private static func nearestExistingDirectory(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        while candidate.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    /// Reads `pool_directory` from a bare project file (the file itself is
    /// always readable — it carries the powerbox grant) and returns the
    /// resolved pool folder when it escapes the project folder.
    private static func escapedPoolDirectory(projectFileURL: URL, projectFolder: URL) -> URL? {
        guard let data = try? Data(contentsOf: projectFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poolDirectory = json["pool_directory"] as? String,
              !poolDirectory.isEmpty else {
            return nil
        }
        let poolURL = projectFolder.appendingPathComponent(poolDirectory).standardizedFileURL
        guard !covers(ancestorPath: projectFolder.path, path: poolURL.path) else {
            return nil
        }
        return poolURL
    }
}
#endif
