import Foundation

/// The open-project table every dispatch call runs against. All access is
/// serialized by `perform`, so handlers may touch entries freely.
final class HorizontalDispatchSession: @unchecked Sendable {
    static let shared = HorizontalDispatchSession()

    private let lock = NSRecursiveLock()
    private var entries: [Int: HorizontalDispatchProjectEntry] = [:]
    private var nextHandle = 1

    func perform<T>(_ body: (HorizontalDispatchSession) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    var openEntries: [HorizontalDispatchProjectEntry] {
        entries.values.sorted { $0.handle < $1.handle }
    }

    /// Opens the project at `url`, or returns the entry already holding it.
    func open(url: URL) throws -> HorizontalDispatchProjectEntry {
        let standardized = url.standardizedFileURL
        if let existing = entries.values.first(where: { $0.url == standardized }) {
            return existing
        }
        let project = Self.withEditorConnectivity(try HorizontalProject.load(from: standardized))
        let entry = HorizontalDispatchProjectEntry(handle: nextHandle, url: standardized, project: project)
        nextHandle += 1
        entries[entry.handle] = entry
        return entry
    }

    func entry(handle: Int) throws -> HorizontalDispatchProjectEntry {
        guard let entry = entries[handle] else {
            throw HorizontalDispatchError.notFound("No open project with handle \(handle).")
        }
        return entry
    }

    func entry(for params: JSONDictionary) throws -> HorizontalDispatchProjectEntry {
        guard let handle = params.int("handle") else {
            throw HorizontalDispatchError.invalidParams("Missing integer parameter \"handle\".")
        }
        return try entry(handle: handle)
    }

    @discardableResult
    func close(handle: Int) -> Bool {
        entries.removeValue(forKey: handle) != nil
    }

    func reload(handle: Int) throws -> HorizontalDispatchProjectEntry {
        let entry = try entry(handle: handle)
        if entry.live != nil {
            // A live document reloads from the app, not from disk.
            return entry
        }
        entry.project = Self.withEditorConnectivity(try HorizontalProject.load(from: entry.url))
        entry.loadedAt = Date()
        entry.invalidateIndex()
        return entry
    }

    /// The entry holding `url` as a live document, if the app has it open.
    func liveEntry(for url: URL) -> HorizontalDispatchProjectEntry? {
        let standardized = url.standardizedFileURL
        return entries.values.first { $0.live != nil && $0.url == standardized }
    }

    // MARK: - Live documents (the app's open documents)

    /// Registers an open document so every dispatch method can answer from
    /// its in-memory state. Returns the handle; the app keeps it to unregister.
    @MainActor
    func registerLive(_ document: HorizontalLiveDocument) -> Int {
        perform { session in
            let entry = HorizontalDispatchProjectEntry(
                handle: session.nextHandle,
                url: document.url.standardizedFileURL,
                project: Self.withEditorConnectivity(document.currentProject())
            )
            entry.live = document
            entry.liveRevision = document.revision()
            session.nextHandle += 1
            session.entries[entry.handle] = entry
            HorizontalLiveServer.documentsDidChange(count: session.entries.values.filter { $0.live != nil }.count)
            return entry.handle
        }
    }

    @MainActor
    func unregisterLive(handle: Int) {
        perform { session in
            guard session.entries[handle]?.live != nil else {
                return
            }
            session.entries.removeValue(forKey: handle)
            HorizontalLiveServer.documentsDidChange(count: session.entries.values.filter { $0.live != nil }.count)
        }
    }

    /// Pulls each live document's current project into its entry when the
    /// document has moved on. The live server calls this before every request.
    @MainActor
    func syncLiveEntries() {
        perform { session in
            for entry in session.entries.values {
                guard let live = entry.live else {
                    continue
                }
                let revision = live.revision()
                guard revision != entry.liveRevision else {
                    continue
                }
                entry.project = Self.withEditorConnectivity(live.currentProject())
                entry.liveRevision = revision
                entry.loadedAt = Date()
                entry.invalidateIndex()
            }
        }
    }
}

extension HorizontalDispatchSession {
    /// The loader's rats' nest is a first pass; the editor re-derives track and
    /// via nets from pad connectivity after every edit and regenerates the
    /// airwires from that. Headless callers want the editor's answer, so a
    /// freshly loaded project gets the same pass before anything reads it.
    static func withEditorConnectivity(_ project: HorizontalProject) -> HorizontalProject {
        guard let board = project.board else {
            return project
        }
        var project = project
        var resolved = HorizontalBoardConnectivity.recompute(board)
        resolved.regenerateAirwires()
        project.board = resolved
        return project
    }
}

final class HorizontalDispatchProjectEntry {
    let handle: Int
    let url: URL
    var project: HorizontalProject
    var loadedAt: Date
    /// Set when the entry stands for a document open in the app.
    var live: HorizontalLiveDocument?
    var liveRevision = 0
    private var cachedIndex: HorizontalDesignIndex?

    init(handle: Int, url: URL, project: HorizontalProject) {
        self.handle = handle
        self.url = url
        self.project = project
        loadedAt = Date()
    }

    /// The netlist-shaped view of the project, built on first use.
    var index: HorizontalDesignIndex {
        if let cachedIndex {
            return cachedIndex
        }
        let index = HorizontalDesignIndex(project: project)
        cachedIndex = index
        return index
    }

    func invalidateIndex() {
        cachedIndex = nil
    }
}
