import Foundation

/// Whether a board's planes are poured again after every change, in the
/// background, rather than only when asked (Q, Update All Planes). Off unless
/// turned on: a pour rewrites the planes file, so with it on every edit also
/// changes a file that can run to tens of megabytes.
enum HorizontalPlaneFillDefaults {
    static let updatesAutomaticallyKey = "planes.updateAutomatically"

    static func updatesAutomatically(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: updatesAutomaticallyKey)
    }
}

/// The fills a pour made, without the board they were poured on: what a
/// document splices into the board it has now, which must still have the
/// inputs `inputs` names (`HorizontalBoardPlaneInputs.signature`).
struct HorizontalPlaneFills: Sendable {
    var inputs: Int
    var fragmentsByPlaneID: [String: [HorizontalPlaneFragment]]
    /// The rats' nest with these fills joining what they reach.
    var airwires: [HorizontalSegment]
}

extension HorizontalBoard {
    /// Takes `fills` into this board's planes and airwires; a plane they do
    /// not name keeps its own. Returns whether the airwires changed.
    @discardableResult
    mutating func takePlaneFills(_ fills: HorizontalPlaneFills) -> Bool {
        for index in planes.indices {
            if let fragments = fills.fragmentsByPlaneID[planes[index].id] {
                planes[index].fragments = fragments
            }
        }
        guard airwires != fills.airwires else {
            return false
        }
        airwires = fills.airwires
        return true
    }

    /// Takes the fills `other` has for planes this board shares with it. A
    /// board read back from the archive can be older than the one in memory,
    /// whose fills a pour may have replaced since the archive was read.
    mutating func carryPlaneFills(from other: HorizontalBoard) {
        let fragmentsByPlaneID = Dictionary(other.planes.map { ($0.id, $0.fragments) }, uniquingKeysWith: { first, _ in first })
        for index in planes.indices {
            if let fragments = fragmentsByPlaneID[planes[index].id] {
                planes[index].fragments = fragments
            }
        }
    }
}

/// What a document asks to have poured.
struct HorizontalPlanePourRequest: Sendable {
    var board: HorizontalBoard
    /// `HorizontalBoardPlaneInputs.signature(of: board)`.
    var inputs: Int
    /// Q or a plane edit, which the user is waiting on, rather than the pour
    /// that follows an edit: it starts at once and at a higher priority.
    var isManual = false
    /// Q: the pour is an undoable step of its own, "Update All Planes".
    var registersUndo = false
    /// Whether the project has a planes file to write the fills to.
    var makesPlanesFile = true
    /// The fragments the board canvas was last handed, whose triangles it has.
    var knownFragmentKeys: Set<BoardPlaneFragmentKey> = []
}

/// A finished pour, with the work its document would otherwise do on the main
/// thread done already: the planes file, the airwires, and the fills'
/// triangles for the board canvas.
struct HorizontalPlanePourResult: Sendable {
    var fills: HorizontalPlaneFills
    var pouredPlaneIDs: Set<String>
    var planesFileData: Data?
    /// Triangles for the fragments of the planes poured afresh, keyed as the
    /// board canvas keys its tessellation.
    var triangles: [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]]
    /// Every fragment the board now has, so the canvas can let go of the
    /// triangles of fills that are gone.
    var fragmentKeys: Set<BoardPlaneFragmentKey>
    var isManual: Bool
    var registersUndo: Bool
}

/// New fills for the board canvas, handed over without the canvas being
/// reset: it splices them into the board it shows and rebuilds only what is
/// drawn from them. A class so that SwiftUI compares it by identity rather
/// than by its fragments.
final class HorizontalPlaneFillDelivery: @unchecked Sendable {
    let revision: Int
    let fills: HorizontalPlaneFills
    /// Emptied by the canvas once it has them, so a large board's triangles
    /// are not held twice; read and written on the main thread only.
    var triangles: [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]]
    let fragmentKeys: Set<BoardPlaneFragmentKey>

    init(revision: Int, result: HorizontalPlanePourResult) {
        self.revision = revision
        fills = result.fills
        triangles = result.triangles
        fragmentKeys = result.fragmentKeys
    }
}

/// Tells a pour in progress to stop before its next plane.
final class HorizontalPlanePourCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Whether any document has a pour pending or running, for callers off the
/// main thread that must not read fills a pour is about to replace: the live
/// channel holds an export or a check until the pour lands.
final class HorizontalPlanePourActivity: @unchecked Sendable {
    static let shared = HorizontalPlanePourActivity()

    private let condition = NSCondition()
    private var busy = 0

    func begin() {
        condition.lock()
        busy += 1
        condition.unlock()
    }

    func end() {
        condition.lock()
        busy = max(busy - 1, 0)
        if busy == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    var isIdle: Bool {
        condition.lock()
        defer { condition.unlock() }
        return busy == 0
    }

    /// Blocks until no pour is pending or running, or `timeout` has passed;
    /// returns whether it is idle. Never call it on the main thread, which
    /// the pours land on.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while busy > 0 {
            if !condition.wait(until: deadline) {
                return busy == 0
            }
        }
        return true
    }
}

/// Pours a document's planes off the main thread, one pour at a time.
///
/// Requests coalesce: an automatic one waits until edits have stopped for
/// `settleDelay`, and a request for a board other than the one being poured
/// stops that pour before its next plane, since its fills would describe
/// copper that is gone. A stopped pour still leaves what it finished in the
/// cache. Only a pour that got to the end is delivered, and the document
/// checks it against the board it has before taking it.
@MainActor
final class HorizontalPlanePourScheduler: ObservableObject {
    typealias Work = @Sendable (
        HorizontalPlanePourRequest,
        HorizontalPlanePourCache,
        HorizontalPlanePourCancellation,
        @escaping @Sendable (Double) -> Void
    ) -> (cache: HorizontalPlanePourCache, result: HorizontalPlanePourResult?)

    @Published private(set) var isPouring = false
    /// nil while pouring means a pour too small to report a fraction.
    @Published private(set) var progress: Double?

    /// How long edits must have stopped before an automatic pour starts.
    var settleDelay: Duration
    /// Takes a finished pour. Called on the main actor.
    var deliver: ((HorizontalPlanePourResult) -> Void)?

    private let work: Work
    private let activity: HorizontalPlanePourActivity
    private var cache = HorizontalPlanePourCache()
    /// Bumped by `forgetCache`, so a pour that started before it does not put
    /// its cache back.
    private var cacheGeneration = 0
    private var latest: HorizontalPlanePourRequest?
    private var latestGeneration = 0
    private var running: (request: HorizontalPlanePourRequest, cancellation: HorizontalPlanePourCancellation)?
    private var driver: Task<Void, Never>?
    /// The driver's wait for edits to settle, which a manual request cuts short.
    private var settleWait: Task<Void, Never>?
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(
        settleDelay: Duration = .milliseconds(300),
        activity: HorizontalPlanePourActivity = .shared,
        work: @escaping Work = HorizontalPlanePourScheduler.pour
    ) {
        self.settleDelay = settleDelay
        self.activity = activity
        self.work = work
    }

    /// Whether a pour is pending or running.
    var isBusy: Bool { driver != nil }

    /// Asks for `request.board` to be poured. A manual request starts at once;
    /// an automatic one once edits have settled.
    func request(_ request: HorizontalPlanePourRequest) {
        var request = request
        if let running, !running.cancellation.isCancelled, running.request.inputs == request.inputs {
            // Already being poured: what is pending was for a board that is
            // no longer the newest, and the pour running is for the one that is.
            if let latest, latest.inputs == request.inputs {
                request.isManual = request.isManual || latest.isManual
                request.registersUndo = request.registersUndo || latest.registersUndo
            }
            latest = nil
            self.running?.request.isManual = running.request.isManual || request.isManual
            self.running?.request.registersUndo = running.request.registersUndo || request.registersUndo
            return
        }
        running?.cancellation.cancel()
        if let latest, latest.inputs == request.inputs {
            request.isManual = request.isManual || latest.isManual
            request.registersUndo = request.registersUndo || latest.registersUndo
        }
        latest = request
        latestGeneration &+= 1
        if request.isManual {
            settleWait?.cancel()
        }
        if driver == nil {
            let activity = activity
            activity.begin()
            driver = Task { [weak self] in
                guard let self else {
                    activity.end()
                    return
                }
                await self.drive()
            }
        }
    }

    /// Drops what the cache remembers, for a board read back from its files:
    /// its planes may share ids with fills that are no longer its own.
    func forgetCache() {
        cache = HorizontalPlanePourCache()
        cacheGeneration &+= 1
    }

    /// Returns once no pour is pending or running.
    func settled() async {
        guard driver != nil else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func drive() async {
        while let pending = latest {
            var request = pending
            if !request.isManual {
                // Wait for edits to stop: each new request starts the wait again.
                while true {
                    let generation = latestGeneration
                    let delay = settleDelay
                    let wait = Task { _ = try? await Task.sleep(for: delay) }
                    settleWait = wait
                    await wait.value
                    settleWait = nil
                    guard let newest = latest else {
                        break
                    }
                    request = newest
                    if latestGeneration == generation || newest.isManual {
                        break
                    }
                }
            }
            guard let next = latest else {
                continue
            }
            latest = nil
            request = next
            await run(request)
        }
        isPouring = false
        progress = nil
        driver = nil
        activity.end()
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }

    private func run(_ request: HorizontalPlanePourRequest) async {
        let cancellation = HorizontalPlanePourCancellation()
        running = (request, cancellation)
        // A single plane can only ever report 0% then 100%, so a ring stuck at
        // zero for the whole pour would read as hung. Spin instead.
        let isDeterminate = request.board.planes.count > 1
        isPouring = true
        progress = isDeterminate ? 0 : nil

        let (updates, progressContinuation) = AsyncStream<Double>.makeStream()
        let cacheAtStart = cache
        let generationAtStart = cacheGeneration
        let work = work
        let job = Task.detached(priority: request.isManual ? .userInitiated : .utility) {
            let made = work(request, cacheAtStart, cancellation) { progressContinuation.yield($0) }
            progressContinuation.finish()
            return made
        }
        for await fraction in updates where isDeterminate {
            progress = fraction
        }
        let made = await job.value
        // Q or a plane edit that arrived while this pour ran for the same
        // board rides on it.
        let flags = running?.request ?? request
        running = nil
        isPouring = false
        progress = nil
        if cacheGeneration == generationAtStart {
            cache = made.cache
        }
        guard var result = made.result, !cancellation.isCancelled else {
            return
        }
        result.isManual = flags.isManual
        result.registersUndo = flags.registersUndo
        deliver?(result)
    }

    /// The pour itself, as a document's scheduler runs it: the fills, then
    /// whatever its document would otherwise make from them on the main
    /// thread. Nil result when it was cancelled.
    nonisolated static func pour(
        _ request: HorizontalPlanePourRequest,
        cache: HorizontalPlanePourCache,
        cancellation: HorizontalPlanePourCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) -> (cache: HorizontalPlanePourCache, result: HorizontalPlanePourResult?) {
        let outcome = HorizontalBoardPlaneUpdater.pour(
            in: request.board,
            cache: cache,
            isCancelled: { cancellation.isCancelled },
            onProgress: { completed, total in
                progress(total > 0 ? Double(completed) / Double(total) : 1)
            }
        )
        guard outcome.isComplete, !cancellation.isCancelled else {
            return (outcome.cache, nil)
        }
        let poured = outcome.board

        // Three jobs from the fills, independent of each other, run side by
        // side: the rats' nest, the planes file and the canvas's triangles.
        let made = BoardPlanePourFollowUps()
        DispatchQueue.concurrentPerform(iterations: 3) { job in
            switch job {
            case 0:
                // The fills join copper they reach, so the rats' nest follows
                // them. Made as a placement makes it: after the editor's
                // connectivity pass, without which every routed bend would
                // come back as an airwire.
                var resolved = HorizontalBoardConnectivity.recompute(poured)
                resolved.regenerateAirwires()
                made.set { $0.airwires = resolved.airwires }
            case 1:
                guard request.makesPlanesFile else { return }
                let data = try? HorizontalProjectJSONApplicator.planeCacheData(board: poured)
                made.set { $0.planesFileData = data }
            default:
                let tessellated = tessellate(poured.planes, freshlyPoured: outcome.pouredPlaneIDs, known: request.knownFragmentKeys)
                made.set {
                    $0.triangles = tessellated.triangles
                    $0.fragmentKeys = tessellated.keys
                }
            }
        }
        guard !cancellation.isCancelled else {
            return (outcome.cache, nil)
        }
        let values = made.values
        return (outcome.cache, HorizontalPlanePourResult(
            fills: HorizontalPlaneFills(
                inputs: request.inputs,
                fragmentsByPlaneID: Dictionary(poured.planes.map { ($0.id, $0.fragments) }, uniquingKeysWith: { first, _ in first }),
                airwires: values.airwires
            ),
            pouredPlaneIDs: outcome.pouredPlaneIDs,
            planesFileData: values.planesFileData,
            triangles: values.triangles,
            fragmentKeys: values.fragmentKeys,
            isManual: request.isManual,
            registersUndo: request.registersUndo
        ))
    }

    /// The canvas's triangles for the freshly poured planes' fragments, and
    /// the keys of every fragment. Done here so the canvas never draws a new
    /// fill as an outline while it tessellates it. A fragment in `known` is
    /// one the canvas was last handed, and so has already: a plane poured
    /// again often comes out the same, and its fill need not be redone.
    nonisolated private static func tessellate(
        _ planes: [HorizontalPlane],
        freshlyPoured: Set<String>,
        known: Set<BoardPlaneFragmentKey>
    ) -> (triangles: [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]], keys: Set<BoardPlaneFragmentKey>) {
        var keys = Set<BoardPlaneFragmentKey>()
        var fresh = [(key: BoardPlaneFragmentKey, fragment: HorizontalPlaneFragment)]()
        for plane in planes {
            for (index, fragment) in plane.renderFragments.enumerated() {
                let key = boardPlaneFragmentKey(planeID: plane.id, fragmentIndex: index, fragment: fragment)
                keys.insert(key)
                if freshlyPoured.contains(plane.id), !known.contains(key) {
                    fresh.append((key, fragment))
                }
            }
        }
        // Biggest first, so the heavy fragments start at once and the light
        // ones fill in round them.
        let entries = fresh.sorted { $0.key.vertexCount > $1.key.vertexCount }
        let collected = BoardPlaneTriangleCollector(count: entries.count)
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            collected.store(boardPlaneFragmentTrianglePoints(entries[index].fragment), at: index)
        }
        let points = collected.values()
        var triangles = [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]]()
        for (index, entry) in entries.enumerated() {
            triangles[entry.key] = points[index]
        }
        return (triangles, keys)
    }
}

/// What the jobs after a pour made, written from their threads.
private final class BoardPlanePourFollowUps: @unchecked Sendable {
    struct Values {
        var airwires: [HorizontalSegment] = []
        var planesFileData: Data?
        var triangles: [BoardPlaneFragmentKey: [BoardMetalTrianglePoints]] = [:]
        var fragmentKeys: Set<BoardPlaneFragmentKey> = []
    }

    private let lock = NSLock()
    private var stored = Values()

    func set(_ change: (inout Values) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }

    var values: Values {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Triangles made on several threads, read back in order.
private final class BoardPlaneTriangleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [[BoardMetalTrianglePoints]]

    init(count: Int) {
        slots = Array(repeating: [], count: count)
    }

    func store(_ points: [BoardMetalTrianglePoints], at index: Int) {
        lock.lock()
        slots[index] = points
        lock.unlock()
    }

    func values() -> [[BoardMetalTrianglePoints]] {
        lock.lock()
        defer { lock.unlock() }
        return slots
    }
}
