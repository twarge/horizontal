import Foundation
import HorizontalProjectIO

/// The open-project table every dispatch call runs against. All access is
/// serialized by `perform`, so handlers may touch entries freely.
final class HorizontalDispatchSession: @unchecked Sendable {
    static let shared = HorizontalDispatchSession()
    let serverID = UUID().uuidString.lowercased()

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

    /// How many open documents are being served live — what decides whether
    /// the live listener runs.
    var liveDocumentCount: Int {
        perform { session in session.entries.values.filter { $0.live != nil }.count }
    }

    /// Opens the project at `url`, or returns the entry already holding it.
    func open(url: URL) throws -> HorizontalDispatchProjectEntry {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = entries.values.first(where: { $0.url == standardized && !$0.frozen }) {
            return existing
        }
        guard entries.count < 64 else { throw HorizontalDispatchError.failed("Close unused project contexts before opening another.") }
        let snapshot = try Self.readSnapshot(url: standardized)
        let project = try Self.project(from: snapshot, url: standardized)
        let entry = HorizontalDispatchProjectEntry(handle: nextHandle, url: standardized, project: project)
        entry.snapshot = snapshot
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

    func freeze(_ original: HorizontalDispatchProjectEntry) throws -> HorizontalDispatchProjectEntry {
        guard entries.count < 64, let snapshot = original.snapshot else { throw HorizontalDispatchError.failed("Close unused snapshots before creating another.") }
        let frozen = HorizontalDispatchProjectEntry(handle: nextHandle, url: original.url, project: original.project)
        nextHandle += 1
        frozen.snapshot = snapshot
        frozen.frozen = true
        frozen.origin = original.metadata
        entries[frozen.handle] = frozen
        return frozen
    }

    /// A private read session owns value copies and the immutable archive, never
    /// a live document closure or the shared session lock while doing the work.
    func detachedReadSession(handle: Int) throws -> HorizontalDispatchSession {
        let original = try entry(handle: handle)
        let session = HorizontalDispatchSession()
        let copy = HorizontalDispatchProjectEntry(handle: handle, url: original.url, project: original.project, instanceID: original.instanceID)
        copy.snapshot = original.snapshot
        copy.generation = original.generation
        copy.frozen = original.frozen
        copy.loadedAt = original.loadedAt
        copy.readMetadata = original.metadata
        session.entries[handle] = copy
        return session
    }

    @discardableResult
    func close(handle: Int) -> Bool {
        guard entries[handle]?.live == nil else { return false }
        return entries.removeValue(forKey: handle) != nil
    }

    func reload(handle: Int) throws -> HorizontalDispatchProjectEntry {
        let entry = try entry(handle: handle)
        guard !entry.frozen else { throw HorizontalDispatchError(code: .readOnly, message: "Pinned snapshots cannot be reloaded.") }
        if entry.live != nil {
            // A live document reloads from the app, not from disk.
            return entry
        }
        let snapshot = try Self.readSnapshot(url: entry.url)
        entry.project = try Self.project(from: snapshot, url: entry.url)
        entry.snapshot = snapshot
        entry.generation += 1
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
            entry.snapshot = HorizontalDispatchSnapshot(archive: document.archive(), baseURL: entry.project.baseURL)
            session.nextHandle += 1
            session.entries[entry.handle] = entry
            HorizontalLiveServer.documentsDidChange(count: session.liveDocumentCount)
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
            HorizontalLiveServer.documentsDidChange(count: session.liveDocumentCount)
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
                let snapshot = HorizontalDispatchSnapshot(archive: live.archive(), baseURL: entry.project.baseURL)
                guard revision != entry.liveRevision || snapshot.id != entry.snapshot?.id else {
                    continue
                }
                entry.project = Self.withEditorConnectivity(live.currentProject())
                entry.liveRevision = revision
                entry.snapshot = snapshot
                entry.generation += 1
                entry.loadedAt = Date()
                entry.invalidateIndex()
            }
        }
    }
}

extension HorizontalDispatchSession {
    static func readSnapshot(url: URL) throws -> HorizontalDispatchSnapshot {
        var transaction = try HorizontalProjectTransaction.existing(projectURL: url)
        defer { withExtendedLifetime(transaction) {} }
        try transaction?.recover()
        var snapshot = try HorizontalDispatchSnapshot.capture(url: url)
        if transaction == nil {
            // Lock files persist. If the first writer appeared during capture,
            // join it and recapture, so a reader cannot retain a partial batch.
            transaction = try HorizontalProjectTransaction.existing(projectURL: url)
            if transaction != nil {
                try transaction?.recover()
                snapshot = try HorizontalDispatchSnapshot.capture(url: url)
            }
        }
        return snapshot
    }

    static func project(from snapshot: HorizontalDispatchSnapshot, url: URL) throws -> HorizontalProject {
        var project = withEditorConnectivity(try snapshot.materializedProject())
        project.url = url
        project.baseURL = snapshot.baseURL
        project.projectFileURL = snapshot.baseURL.appendingPathComponent(project.projectFileURL.lastPathComponent)
        if var board = project.board {
            board.url = snapshot.baseURL.appendingPathComponent(project.boardFilename ?? board.url.lastPathComponent)
            project.board = board
        }
        if var schematic = project.schematic {
            schematic.url = snapshot.baseURL.appendingPathComponent(project.schematicFilename ?? schematic.url.lastPathComponent)
            project.schematic = schematic
        }
        for i in project.schematics.indices {
            project.schematics[i].schematic.url = snapshot.baseURL.appendingPathComponent(project.schematics[i].schematicFilename)
        }
        return project
    }

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
    var liveRevision = "0"
    var snapshot: HorizontalDispatchSnapshot?
    let instanceID: String
    var generation = 0
    var receipts: [String: JSONDictionary] = [:]
    var frozen = false
    var origin: JSONDictionary?
    var readMetadata: JSONDictionary?
    var revision: String { "\(instanceID):\(generation):\(snapshot?.id ?? "unknown")" }
    var metadata: JSONDictionary {
        if let readMetadata { return readMetadata }
        return ["source": origin?.string("source") ?? (live == nil ? "disk" : "live"), "revision": revision,
         "snapshot_id": snapshot?.id ?? "", "instance_id": instanceID, "api_version": HorizontalDispatch.apiVersion,
         "frozen": frozen, "origin": origin as Any]
    }

    func requireRevision(_ params: JSONDictionary) throws {
        guard !frozen else { throw HorizontalDispatchError(code: .readOnly, message: "Pinned snapshots cannot be edited.") }
        guard let expected = params["expected_revision"] as? String else {
            throw HorizontalDispatchError.invalidParams("expected_revision is required; use the revision returned by your preceding read.")
        }
        guard expected == revision else {
            throw HorizontalDispatchError(code: .staleRevision, message: "Project changed since it was read.", details: ["expected": expected, "actual": revision])
        }
        if live == nil {
            let current = try HorizontalDispatchSnapshot.capture(url: url)
            guard current.id == snapshot?.id else {
                throw HorizontalDispatchError(code: .staleRevision, message: "Project files changed on disk. Reload before editing.", details: ["expected_snapshot": snapshot?.id ?? "", "actual_snapshot": current.id])
            }
        }
    }
    private var cachedIndex: HorizontalDesignIndex?

    init(handle: Int, url: URL, project: HorizontalProject, instanceID: String = UUID().uuidString.lowercased()) {
        self.handle = handle
        self.url = url
        self.project = project
        self.instanceID = instanceID
        loadedAt = Date()
    }

    /// The netlist-shaped view of the project, built on first use.
    var index: HorizontalDesignIndex {
        if let cachedIndex {
            return cachedIndex
        }
        let index = HorizontalDesignIndex(project: project, snapshot: snapshot)
        cachedIndex = index
        return index
    }

    func invalidateIndex() {
        cachedIndex = nil
    }
}
