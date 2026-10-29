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
    /// See `frontLiveDocumentHandle`.
    private var frontLiveHandle: Int?

    func perform<T>(_ body: (HorizontalDispatchSession) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    var openEntries: [HorizontalDispatchProjectEntry] {
        entries.values.sorted { $0.handle < $1.handle }
    }

    /// What a holder record beside a project calls this process.
    static var holderName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// How many open documents are being served live — what decides whether
    /// the live listener runs.
    var liveDocumentCount: Int {
        perform { session in session.entries.values.filter { $0.live != nil }.count }
    }

    /// The live document whose scene most recently came to the front, by
    /// handle — what stands in for a document controller on the iPad, which
    /// has none to ask. Nil until a document says so, and nil again once that
    /// document unregisters.
    var frontLiveDocumentHandle: Int? {
        guard let handle = frontLiveHandle, entries[handle]?.live != nil else {
            return nil
        }
        return handle
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
        copy.revisionSnapshotIDs = original.revisionSnapshotIDs
        copy.generation = original.generation
        copy.frozen = original.frozen
        copy.loadedAt = original.loadedAt
        copy.readMetadata = original.metadata
        // What the board canvas draws is a live document closure, so it is
        // read now, as a value, while the caller holds the main actor (the
        // live channel prepares its reads there).
        if let live = original.live, Thread.isMainThread {
            let drawn = HorizontalUnsafeSendableBox<HorizontalDrawnAirwires?>(nil)
            MainActor.assumeIsolated {
                drawn.value = live.drawnAirwires()
            }
            copy.liveCanvas = .init(drawnAirwires: drawn.value)
        }
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
            #if os(macOS)
            // The record is for other processes on this machine to find, and
            // the iPad has none; nor does a document opened there carry access
            // to the directory beside it, where the record would go.
            entry.holder = HorizontalProjectHolder(projectURL: entry.url, name: Self.holderName,
                                                   endpoint: HorizontalLiveServer.endpoint())
            #endif
            entry.liveRevision = document.revision()
            entry.livePlaneFillRevision = document.planeFillRevision()
            Self.takeLiveArchive(document.archive(), into: entry)
            session.nextHandle += 1
            session.entries[entry.handle] = entry
            HorizontalLiveServer.documentsDidChange(count: session.liveDocumentCount)
            return entry.handle
        }
    }

    /// Republishes the live channel in every open document's holder record.
    /// Called when the listener starts or stops, which is also when the user
    /// turns the channel on or off.
    @MainActor
    func refreshHolders(endpoint: [String: String]?) {
        perform { session in
            for entry in session.entries.values where entry.live != nil {
                entry.holder?.update(endpoint: endpoint)
            }
        }
    }

    /// Records that `handle`'s scene is the one in front — the iPad
    /// workspace's answer to `NSDocumentController.currentDocument`. A handle
    /// that is not a live document is ignored rather than remembered.
    @MainActor
    func noteLiveDocumentInFront(handle: Int) {
        perform { session in
            guard session.entries[handle]?.live != nil else {
                return
            }
            session.frontLiveHandle = handle
        }
    }

    @MainActor
    func unregisterLive(handle: Int) {
        perform { session in
            guard session.entries[handle]?.live != nil else {
                return
            }
            session.entries[handle]?.holder = nil
            session.entries.removeValue(forKey: handle)
            if session.frontLiveHandle == handle {
                session.frontLiveHandle = nil
            }
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
                let planeFillRevision = live.planeFillRevision()
                let archive = live.archive()
                let snapshot = HorizontalDispatchSnapshot(archive: archive, baseURL: entry.project.baseURL)
                guard revision != entry.liveRevision || snapshot.id != entry.liveArchiveID else {
                    continue
                }
                // A pour that landed while nothing else changed: the fills are
                // derived from the board, and the board is as the client read
                // it, so the revision it holds stays good, and so do its dry
                // runs once they have the new fills too.
                let fillsOnly = revision == entry.liveRevision && planeFillRevision != entry.livePlaneFillRevision
                let reportedSnapshotID = entry.revisionSnapshotID
                let previousSnapshot = entry.snapshot
                entry.project = Self.withEditorConnectivity(live.currentProject())
                entry.liveRevision = revision
                entry.livePlaneFillRevision = planeFillRevision
                Self.takeLiveArchive(archive, into: entry, snapshot: snapshot)
                if fillsOnly, let reportedSnapshotID, let previousSnapshot, let current = entry.snapshot {
                    entry.revisionSnapshotIDs = [current.id: reportedSnapshotID]
                    entry.stagedPlans = entry.stagedPlans.compactMap {
                        Self.rebased($0, from: previousSnapshot, onto: current, fillsFrom: entry.project)
                    }
                } else {
                    entry.revisionSnapshotIDs = [:]
                    entry.generation += 1
                }
                entry.loadedAt = Date()
                entry.invalidateIndex()
            }
        }
    }
}

extension HorizontalDispatchSession {
    /// A dry run staged before a pour, carried onto the files the pour left:
    /// each file the pour changed goes into what the dry run staged, and the
    /// staged board takes the new fills. Nil when the dry run changed one of
    /// those files itself, since then the two cannot both stand.
    static func rebased(
        _ plan: HorizontalDispatchProjectEntry.StagedPlan,
        from previous: HorizontalDispatchSnapshot,
        onto current: HorizontalDispatchSnapshot,
        fillsFrom project: HorizontalProject
    ) -> HorizontalDispatchProjectEntry.StagedPlan? {
        var archive = plan.after.archive
        for path in Set(previous.files).union(current.files) {
            let before = previous.archive.regularFileData(relativePath: path)
            let after = current.archive.regularFileData(relativePath: path)
            guard before != after else {
                continue
            }
            guard let after, archive.regularFileData(relativePath: path) == before,
                  (try? archive.replaceRegularFileData(relativePath: path, with: after)) != nil else {
                return nil
            }
        }
        var rebased = plan
        rebased.after = HorizontalDispatchSnapshot(archive: archive, baseURL: plan.after.baseURL)
        if let board = project.board {
            rebased.staged.board?.carryPlaneFills(from: board)
        }
        return rebased
    }

    /// Whether a live document's archive is its `.hprj` alone rather than the
    /// tree the manifest names.
    static func holdsProjectFileOnly(_ archive: HorizontalProjectArchive, url: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("hprj") == .orderedSame, case .regularFile = archive.root else { return false }
        return true
    }

    /// The snapshot a live document's requests read. A document holding its
    /// `.hprj` alone has nothing to render or edit from, and holds no edits of
    /// its own either, since every edit needs the tree; so it reads from the
    /// files on disk, which are the project it shows.
    static func takeLiveArchive(_ archive: HorizontalProjectArchive, into entry: HorizontalDispatchProjectEntry,
                                snapshot: HorizontalDispatchSnapshot? = nil) {
        let live = snapshot ?? HorizontalDispatchSnapshot(archive: archive, baseURL: entry.project.baseURL)
        entry.liveArchiveID = live.id
        entry.holdsProjectFileOnly = holdsProjectFileOnly(archive, url: entry.url)
        entry.snapshot = entry.holdsProjectFileOnly ? (try? HorizontalDispatchSnapshot.capture(url: entry.url)) ?? live : live
    }

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

    /// The editor's connectivity pass: track, via and junction nets re-derived
    /// from pad connectivity, and the airwires regenerated from them. Headless
    /// callers want that answer, so a freshly loaded project gets the same pass
    /// before anything reads it. The loader gives junctions the net of their
    /// copper for its own airwires too, so on a board whose file stores no
    /// junction nets — Horizon writes none — the app draws what this reports.
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
    /// The record beside the project announcing that this process has it open,
    /// retained for as long as the document is. Disk writers consult it before
    /// editing files an editor is holding.
    var holder: HorizontalProjectHolder?
    var liveRevision = "0"
    /// The live document's count of pours taken (`planeFillRevision`).
    var livePlaneFillRevision = 0
    var snapshot: HorizontalDispatchSnapshot?
    /// The snapshot id the revision names in place of the snapshot's own,
    /// keyed by the snapshot's: after a pour changed nothing but a live
    /// document's fills, its revision names the snapshot from before.
    var revisionSnapshotIDs: [String: String] = [:]
    /// The id of the archive a live document last handed over, which the
    /// snapshot is not when that archive held the `.hprj` alone.
    var liveArchiveID: String?
    /// A live `.hprj` document holding its project file alone, not the tree
    /// the manifest names: until its window has gathered the tree, after a
    /// Revert that read the one file again, or for as long as it is read-only.
    /// Reads come from its files on disk; edits are refused.
    var holdsProjectFileOnly = false
    let instanceID: String
    var generation = 0
    var receipts: [String: JSONDictionary] = [:]
    /// Mutations that ran and committed nothing, by operation id, so a client
    /// that lost the response can be told so rather than "unknown". A retry
    /// under the same id is still allowed, and clears the entry.
    var failedOperations: [String: JSONDictionary] = [:]
    /// The load diagnostics of the last snapshot a mutation produced. The
    /// next mutation starts from that snapshot, so it need not load the whole
    /// project again just to count them.
    var cachedDiagnostics: (snapshotID: String, counts: [String: Int])?

    /// The latest dry runs' staged edits, newest last, so a commit replaying
    /// one at the same revision installs it rather than doing the work twice.
    /// More than one is kept because a caller often dry-runs a few variants
    /// before committing the first.
    struct StagedPlan {
        var keys: Set<String>
        var digest: String
        var revision: String
        var after: HorizontalDispatchSnapshot
        var staged: HorizontalProject
        var diagnostics: [String: Int]
        var result: JSONDictionary
    }
    var stagedPlans: [StagedPlan] = []
    static let stagedPlanLimit = 4
    var frozen = false
    var origin: JSONDictionary?
    var readMetadata: JSONDictionary?
    /// On a detached read copy of a live document: what its board canvas drew
    /// when the copy was taken. Nil on the live entry itself and on disk ones.
    struct LiveCanvas {
        var drawnAirwires: HorizontalDrawnAirwires?
    }
    var liveCanvas: LiveCanvas?
    var revision: String { "\(instanceID):\(generation):\(revisionSnapshotID ?? "unknown")" }
    /// The snapshot the revision names: the snapshot's own id, unless only a
    /// pour's fills have changed since the one it named before.
    var revisionSnapshotID: String? {
        snapshot.map { revisionSnapshotIDs[$0.id] ?? $0.id }
    }
    var metadata: JSONDictionary {
        if let readMetadata { return readMetadata }
        return ["source": origin?.string("source") ?? (live == nil ? "disk" : "live"), "revision": revision,
         "snapshot_id": snapshot?.id ?? "", "instance_id": instanceID, "api_version": HorizontalDispatch.apiVersion,
         "frozen": frozen, "origin": origin as Any]
    }

    /// `currentWhenMissing` lets a request that writes nothing, a dry run,
    /// leave expected_revision out and be read against the revision as it is.
    func requireRevision(_ params: JSONDictionary, currentWhenMissing: Bool = false) throws {
        guard !frozen else { throw HorizontalDispatchError(code: .readOnly, message: "Pinned snapshots cannot be edited.") }
        guard let expected = params["expected_revision"] as? String ?? (currentWhenMissing ? revision : nil) else {
            throw HorizontalDispatchError.invalidParams("expected_revision is required; use the revision returned by your preceding read.")
        }
        guard expected == revision else {
            // instance:generation:snapshot. An edit and its undo move the
            // generation and leave the content as it was; the revision still
            // refuses, but a caller should know a fresh dry run is all it takes.
            // retryable stays false, since the same request would be refused
            // again; details.retry says what to send instead.
            let was = expected.split(separator: ":"), now = revision.split(separator: ":")
            if was.count == 3, now.count == 3, was[0] == now[0], was[2] == now[2] {
                let planned = params.string("plan_digest") != nil
                throw HorizontalDispatchError(
                    code: .staleRevision,
                    message: "Project changed since it was read, though its content is as it was then (most likely an edit and its undo). "
                        + (planned
                            ? "Dry-run it again with expected_revision \(revision), then commit with the plan_digest that gives."
                            : "Send it again with expected_revision \(revision)."),
                    details: ["expected": expected, "actual": revision, "snapshot_matches": true,
                              "retry": planned ? "dry_run_at_actual" : "resend_at_actual"])
            }
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
        cachedPoolIndex = nil
    }

    private var cachedPoolIndex: HorizontalDispatchPoolIndex?

    /// The project pool's entities, units and symbol geometry, for reads that
    /// need to know where a pin is drawn.
    var poolIndex: HorizontalDispatchPoolIndex {
        if let cachedPoolIndex { return cachedPoolIndex }
        let index = HorizontalDispatchPoolIndex(project: project, snapshot: snapshot)
        cachedPoolIndex = index
        return index
    }
}
