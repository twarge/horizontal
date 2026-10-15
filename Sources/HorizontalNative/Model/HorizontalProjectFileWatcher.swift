#if os(macOS)
import CoreServices
import Foundation
import HorizontalProjectIO
import Synchronization

/// The paths under a directory that any process changed, as FSEvents reports
/// them. git, a sync client or a script writes without file coordination, so
/// a file presenter would not hear of it; FSEvents does.
final class HorizontalDirectoryEvents: @unchecked Sendable {
    /// Relative paths; "" when FSEvents can only say something in the folder
    /// changed and it has to be looked at again as a whole.
    typealias Handler = @Sendable ([String]) -> Void

    /// The directory as FSEvents spells it, every link resolved
    /// (`/private/var/…`), and as Foundation does (`/var/…`).
    private let path: String
    private let alias: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.twarge.horizontal.project-file-events")
    private var stream: FSEventStreamRef?

    init(directory: URL, handler: @escaping Handler) {
        alias = directory.resolvingSymlinksInPath().standardizedFileURL.path
        path = realpath(directory.path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? alias
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    func start(latency: TimeInterval = 0.2) -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let events = Unmanaged<HorizontalDirectoryEvents>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            events.deliver(count: count, paths: changed, flags: flags)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>) {
        let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        var relative = [String]()
        for index in 0..<count {
            if Int(flags[index]) & rescan != 0 {
                relative.append("")
            } else if let changed = paths[index] as? String, let path = relativePath(of: changed) {
                relative.append(path)
            }
        }
        if !relative.isEmpty { handler(relative) }
    }

    private func relativePath(of changed: String) -> String? {
        let standardized = URL(fileURLWithPath: changed).standardizedFileURL.path
        for base in [path, alias] {
            if standardized == base { return "" }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if standardized.hasPrefix(prefix) { return String(standardized.dropFirst(prefix.count)) }
        }
        return nil
    }
}

/// Watches an open project's files and reports a change something other
/// than the document made: a git checkout, pull, stash or reset, or another
/// program (item 121; docs/automation.md, "Who has the project open").
///
/// The document autosaves in place, so its own writes arrive here all the
/// time. Each burst of events is followed, once the folder is quiet, by a read
/// of the project as it is on disk, which `HorizontalProjectChangeDetector`
/// compares with the document and with what the document has written.
@MainActor
final class HorizontalProjectFileWatcher {
    struct Handlers {
        /// The document as it is now.
        var document: () -> HorizontalProjectDocument
        /// Whether the document holds a complete copy of the project to
        /// compare with. A project opened read-only holds only its `.hprj`.
        var holdsCompleteArchive: () -> Bool
        /// Whether the document has edits its files don't, waiting to autosave.
        var hasUnsavedChanges: () -> Bool
        /// The files changed on disk: what they hold now, and its fingerprint
        /// to `accept` if the document keeps its own version.
        var changedOnDisk: (_ disk: HorizontalProjectArchive, _ fingerprint: HorizontalProjectFingerprint,
                            _ documentHasUnsavedChanges: Bool) -> Void
    }

    /// How long the folder has to be quiet before it is read: a checkout or an
    /// autosave writes several files.
    static let settleDelay: Duration = .milliseconds(500)

    let projectURL: URL
    private let handlers: Handlers
    private var events: HorizontalDirectoryEvents?
    private var writeObserver: NSObjectProtocol?
    nonisolated private let detector = Mutex<HorizontalProjectChangeDetector?>(nil)
    nonisolated private let baseURL: URL
    private var baselineTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var isChecking = false
    private var needsCheck = false
    /// Bumped by every check, so one overtaken by a later one drops its result.
    private var generation = 0
    private var failedReads = 0

    init(projectURL: URL, handlers: Handlers) {
        self.projectURL = projectURL
        self.handlers = handlers
        var isDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory)
        baseURL = (isDirectory.boolValue ? projectURL : projectURL.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL
    }

    func start() {
        guard events == nil else { return }
        let url = projectURL
        baselineTask = Task { [weak self] in
            let baseline = await Task.detached(priority: .utility) {
                (try? HorizontalProjectArchive.completeProject(from: url)).map(HorizontalProjectFingerprint.init(archive:))
            }.value
            guard let self, let baseline else { return }
            self.detector.withLock { $0 = HorizontalProjectChangeDetector(baseline: baseline) }
        }
        // Posted on the saving thread before the files land, with the archive
        // being written, so the check that follows the write already knows it.
        writeObserver = NotificationCenter.default.addObserver(
            forName: HorizontalProjectDocument.didWriteNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let archive = notification.object as? HorizontalProjectArchive, self.writes(archive) else { return }
            let fingerprint = HorizontalProjectFingerprint(archive: archive)
            self.detector.withLock { $0?.recordWrite(fingerprint) }
        }
        let events = HorizontalDirectoryEvents(directory: baseURL) { [weak self] paths in
            Task { @MainActor in self?.filesChanged(paths) }
        }
        events.start()
        self.events = events
    }

    func stop() {
        events?.stop()
        events = nil
        if let writeObserver { NotificationCenter.default.removeObserver(writeObserver) }
        writeObserver = nil
        baselineTask?.cancel()
        checkTask?.cancel()
        generation += 1
    }

    /// The document keeps its own version over what the files hold now.
    func accept(_ fingerprint: HorizontalProjectFingerprint) {
        detector.withLock { $0?.accept(fingerprint) }
    }

    /// Whether events have arrived that no check has looked at yet. An edit
    /// arriving then should look first rather than build on a document the
    /// files no longer match.
    var hasUnreadChanges: Bool { needsCheck || checkTask != nil }

    /// Reads the files now, on this thread, if events are waiting. Reports a
    /// change the way a scheduled check does, and returns whether it found one.
    @discardableResult
    func checkNow() -> Bool {
        guard hasUnreadChanges else { return false }
        checkTask?.cancel()
        checkTask = nil
        needsCheck = false
        generation += 1
        let document = handlers.holdsCompleteArchive() ? HorizontalProjectFingerprint(archive: handlers.document().archive) : nil
        guard let (disk, fingerprint) = settledRead(document: document) else {
            needsCheck = true
            scheduleCheck(after: Self.settleDelay)
            return false
        }
        return decide(disk: disk, fingerprint: fingerprint, document: document)
    }

    /// The files as they are, read without waiting for the folder to go
    /// quiet. An autosave or a checkout halfway through looks like a change,
    /// so one that does is read again shortly after, and believed only when
    /// two reads agree.
    private func settledRead(document: HorizontalProjectFingerprint?) -> (HorizontalProjectArchive, HorizontalProjectFingerprint)? {
        var previous: HorizontalProjectFingerprint?
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
            guard let disk = try? HorizontalProjectArchive.completeProject(from: projectURL) else { continue }
            let fingerprint = HorizontalProjectFingerprint(archive: disk)
            var trial = detector.withLock { $0 }
            let looksChanged = trial?.classify(disk: fingerprint, document: document) == .changedOnDisk
            if !looksChanged || fingerprint == previous { return (disk, fingerprint) }
            previous = fingerprint
        }
        return nil
    }

    nonisolated private func writes(_ archive: HorizontalProjectArchive) -> Bool {
        // A package's archive has no manifest to say where it came from;
        // remembering another document's write costs a fingerprint and
        // matches nothing.
        guard let manifest = archive.manifest else { return true }
        return manifest.baseURL.resolvingSymlinksInPath().standardizedFileURL == baseURL
    }

    private func filesChanged(_ paths: [String]) {
        guard events != nil else { return }
        let archive = handlers.document().archive
        guard paths.contains(where: { $0.isEmpty || archive.tracks(relativePath: $0) }) else { return }
        needsCheck = true
        scheduleCheck(after: Self.settleDelay)
    }

    private func scheduleCheck(after delay: Duration) {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    private func check() async {
        checkTask = nil
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            // Events that came in while the files were being read.
            if needsCheck, checkTask == nil { scheduleCheck(after: Self.settleDelay) }
        }
        needsCheck = false
        await baselineTask?.value
        generation += 1
        let generation = generation
        let document = handlers.document()
        let documentArchive = handlers.holdsCompleteArchive() ? document.archive : nil
        let url = projectURL
        let read = await Task.detached(priority: .utility) { () -> (HorizontalProjectArchive, HorizontalProjectFingerprint, HorizontalProjectFingerprint?)? in
            guard let disk = try? HorizontalProjectArchive.completeProject(from: url) else { return nil }
            return (disk, .init(archive: disk), documentArchive.map(HorizontalProjectFingerprint.init(archive:)))
        }.value
        guard generation == self.generation, events != nil else { return }
        guard let (disk, fingerprint, documentFingerprint) = read else {
            // Caught halfway through a checkout: a file it references isn't
            // there yet. Its last write brings another event; this is in case
            // it doesn't.
            failedReads += 1
            if failedReads <= 3 { needsCheck = true }
            return
        }
        failedReads = 0
        // The document changed while the files were read, or the files did:
        // the comparison would be with something no longer there.
        guard handlers.document().hasSameArchive(as: document), !needsCheck else {
            needsCheck = true
            return
        }
        decide(disk: disk, fingerprint: fingerprint, document: documentFingerprint)
    }

    @discardableResult
    private func decide(disk: HorizontalProjectArchive, fingerprint: HorizontalProjectFingerprint,
                        document: HorizontalProjectFingerprint?) -> Bool {
        let verdict = detector.withLock { detector -> HorizontalProjectChangeDetector.Verdict? in
            guard detector != nil else {
                detector = HorizontalProjectChangeDetector(baseline: fingerprint)
                return nil
            }
            return detector?.classify(disk: fingerprint, document: document)
        }
        guard verdict == .changedOnDisk else { return false }
        handlers.changedOnDisk(disk, fingerprint, handlers.hasUnsavedChanges())
        return true
    }
}
#endif
