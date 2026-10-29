import XCTest
@testable import HorizontalNative

/// What the scheduler's work was asked to pour, written from the pour's thread.
private final class PourLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startedInputs: [Int] = []
    private var cachesSeen: [Int] = []
    private var cancelledInputs: [Int] = []
    private var held = false

    var started: [Int] { locked { startedInputs } }
    var cacheCounts: [Int] { locked { cachesSeen } }
    var cancelled: [Int] { locked { cancelledInputs } }

    /// Holds every pour until `release`, so a test can act while one runs.
    func hold() { locked { held = true } }
    func release() { locked { held = false } }

    func start(_ inputs: Int, cacheCount: Int) {
        locked {
            startedInputs.append(inputs)
            cachesSeen.append(cacheCount)
        }
    }

    /// Spins while held, giving way as a pour does when it is cancelled.
    func wait(_ inputs: Int, cancellation: HorizontalPlanePourCancellation) -> Bool {
        while locked({ held }) {
            if cancellation.isCancelled {
                locked { cancelledInputs.append(inputs) }
                return false
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return !cancellation.isCancelled
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The coalescing pour scheduler both document hosts share: automatic pours
/// wait for edits to settle, a newer board stops a pour of an older one, and
/// only a pour that finished is delivered.
@MainActor
final class HorizontalPlanePourSchedulerTests: XCTestCase {
    private func board() -> HorizontalBoard {
        HorizontalGerberExportFixture.board()
    }

    private func request(_ inputs: Int, manual: Bool = false, undo: Bool = false) -> HorizontalPlanePourRequest {
        HorizontalPlanePourRequest(board: board(), inputs: inputs, isManual: manual, registersUndo: undo, makesPlanesFile: false)
    }

    /// A scheduler whose work pours nothing: it records the request, waits
    /// while the log holds it, stores one cache entry, and hands back fills
    /// naming the inputs it was given.
    private func scheduler(
        settle: Duration = .milliseconds(40),
        log: PourLog,
        activity: HorizontalPlanePourActivity = HorizontalPlanePourActivity()
    ) -> HorizontalPlanePourScheduler {
        HorizontalPlanePourScheduler(settleDelay: settle, activity: activity) { request, cache, cancellation, _ in
            log.start(request.inputs, cacheCount: cache.count)
            var cache = cache
            cache.store(planeID: "plane-\(request.inputs)", signature: request.inputs, fragments: [])
            guard log.wait(request.inputs, cancellation: cancellation) else {
                return (cache, nil)
            }
            let fills = HorizontalPlaneFills(inputs: request.inputs, fragmentsByPlaneID: [:], airwires: [])
            return (cache, HorizontalPlanePourResult(
                fills: fills, pouredPlaneIDs: [], planesFileData: nil, triangles: [:], fragmentKeys: [],
                isManual: request.isManual, registersUndo: request.registersUndo
            ))
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    func testAutomaticRequestsWithinTheSettleDelayPourOnceForTheNewestBoard() async {
        let log = PourLog()
        let scheduler = scheduler(settle: .milliseconds(150), log: log)
        var delivered = [Int]()
        scheduler.deliver = { delivered.append($0.fills.inputs) }

        scheduler.request(request(1))
        try? await Task.sleep(for: .milliseconds(30))
        scheduler.request(request(2))
        try? await Task.sleep(for: .milliseconds(30))
        scheduler.request(request(3))
        await scheduler.settled()

        XCTAssertEqual(log.started, [3], "edits in quick succession are poured once, as the last one left the board")
        XCTAssertEqual(delivered, [3])
        XCTAssertFalse(scheduler.isBusy)
    }

    func testAManualRequestDoesNotWaitForEditsToSettle() async {
        let log = PourLog()
        let scheduler = scheduler(settle: .seconds(30), log: log)
        var delivered = [Int]()
        scheduler.deliver = { delivered.append($0.fills.inputs) }

        scheduler.request(request(1))
        scheduler.request(request(1, manual: true, undo: true))
        let landed = await settle { !delivered.isEmpty }

        XCTAssertTrue(landed, "Q pours at once, even with an automatic pour waiting on the same board")
        XCTAssertEqual(log.started, [1])
    }

    func testANewerBoardStopsThePourInProgressAndOnlyItIsDelivered() async {
        let log = PourLog()
        log.hold()
        let scheduler = scheduler(log: log)
        var delivered = [Int]()
        scheduler.deliver = { delivered.append($0.fills.inputs) }

        scheduler.request(request(1, manual: true))
        let started = await settle { log.started == [1] }
        XCTAssertTrue(started)
        XCTAssertTrue(scheduler.isPouring)

        scheduler.request(request(2, manual: true))
        let stopped = await settle { log.cancelled == [1] }
        XCTAssertTrue(stopped, "the pour of the board that is gone is told to stop")
        log.release()
        await scheduler.settled()

        XCTAssertEqual(log.started, [1, 2])
        XCTAssertEqual(delivered, [2], "a stopped pour's fills describe copper that is gone, so it delivers nothing")
        XCTAssertFalse(scheduler.isPouring)
    }

    func testARequestForTheBoardBeingPouredRidesOnIt() async {
        let log = PourLog()
        log.hold()
        let scheduler = scheduler(log: log)
        var delivered = [HorizontalPlanePourResult]()
        scheduler.deliver = { delivered.append($0) }

        scheduler.request(request(7, manual: true))
        let started = await settle { log.started == [7] }
        XCTAssertTrue(started)
        // Q while the pour that followed the edit runs for the same board.
        scheduler.request(request(7, manual: true, undo: true))
        // And the edit's own check again, which must not start a second pour.
        scheduler.request(request(7))
        log.release()
        await scheduler.settled()

        XCTAssertEqual(log.started, [7], "one pour serves them all")
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.registersUndo, true, "Q's undo step rides on the pour already running")
        XCTAssertEqual(delivered.first?.isManual, true)
    }

    func testWhatAStoppedPourFinishedStaysInTheCache() async {
        let log = PourLog()
        log.hold()
        let scheduler = scheduler(log: log)
        scheduler.request(request(1, manual: true))
        let started = await settle { log.started.count == 1 }
        XCTAssertTrue(started)
        scheduler.request(request(2, manual: true))
        let stopped = await settle { log.cancelled == [1] }
        XCTAssertTrue(stopped)
        log.release()
        await scheduler.settled()

        XCTAssertEqual(log.cacheCounts, [0, 1], "the next pour starts from what the stopped one finished")
    }

    func testForgettingTheCacheDropsWhatAPourInProgressWouldPutBack() async {
        let log = PourLog()
        log.hold()
        let scheduler = scheduler(log: log)
        scheduler.request(request(1, manual: true))
        let started = await settle { log.started.count == 1 }
        XCTAssertTrue(started)
        // The board is read back from its files while the pour runs.
        scheduler.forgetCache()
        log.release()
        await scheduler.settled()

        scheduler.request(request(2, manual: true))
        await scheduler.settled()
        XCTAssertEqual(log.cacheCounts, [0, 0], "the pour that began before the reload does not put its cache back")
    }

    func testTheActivityIsBusyFromTheRequestUntilThePourLands() async {
        let log = PourLog()
        let activity = HorizontalPlanePourActivity()
        let scheduler = scheduler(settle: .milliseconds(80), log: log, activity: activity)
        var delivered = false
        scheduler.deliver = { _ in delivered = true }

        XCTAssertTrue(activity.isIdle)
        scheduler.request(request(1))
        XCTAssertFalse(activity.isIdle, "busy while the pour waits for edits to settle, not only while it runs")
        await scheduler.settled()
        XCTAssertTrue(delivered)
        XCTAssertTrue(activity.isIdle)
    }

    func testAnExportWaitingOffTheMainThreadGoesOnOnceThePourLands() async {
        let log = PourLog()
        let activity = HorizontalPlanePourActivity()
        let scheduler = scheduler(settle: .milliseconds(80), log: log, activity: activity)
        var delivered = false
        scheduler.deliver = { _ in delivered = true }
        scheduler.request(request(1))

        // The live channel waits on its connection queue, never the main
        // thread, which the pour lands on.
        let waited = await Task.detached { activity.waitUntilIdle(timeout: 5) }.value
        XCTAssertTrue(waited)
        XCTAssertTrue(delivered, "the wait ends only after the fills are in")
    }

    func testTheWaitGivesUpAtItsLimit() async {
        let activity = HorizontalPlanePourActivity()
        activity.begin()
        let waited = await Task.detached { activity.waitUntilIdle(timeout: 0.05) }.value
        XCTAssertFalse(waited)
        activity.end()
        XCTAssertTrue(activity.isIdle)
    }
}

/// The pour the scheduler runs, and the fills it hands a document.
final class HorizontalPlanePourWorkTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let net = "net-a"

    private func square(around center: HorizontalPoint, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y + half),
            HorizontalPoint(x: center.x - half, y: center.y + half),
        ]
    }

    private func plane(_ id: String, priority: Int = 0, half: Double = 12_000_000) -> HorizontalPlane {
        var plane = HorizontalPlane(
            id: id, netID: net, polygonID: "poly-\(id)", layer: top,
            priority: priority, fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: []
        )
        plane.fallbackPolygon = HorizontalPolygon(
            id: "poly-\(id)", vertices: square(around: HorizontalPoint(x: 5 * mm, y: 0), half: half), layer: top, netID: net
        )
        plane.fromRules = false
        return plane
    }

    /// Two pads of one net 10 mm apart on the top copper with no track between
    /// them, and a plane of that net over both: one airwire until it pours.
    private func board(planes: [HorizontalPlane]) -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.polygons = [HorizontalPolygon(
            id: "outline", vertices: square(around: HorizontalPoint(x: 5 * mm, y: 0), half: 15 * mm),
            layer: HorizontalBoardLayers.outline
        )]
        let a = HorizontalPoint(x: 0, y: 0)
        let b = HorizontalPoint(x: 10 * mm, y: 0)
        board.packagePads = [
            HorizontalPolygon(id: "pkg-a/pad/p1/shape/s", vertices: square(around: a, half: 400_000), layer: top, netID: net),
            HorizontalPolygon(id: "pkg-b/pad/p1/shape/s", vertices: square(around: b, half: 400_000), layer: top, netID: net),
        ]
        board.packagePadPositions = ["pkg-a/p1": a, "pkg-b/p1": b]
        board.planes = planes
        board.regenerateAirwires()
        return board
    }

    func testThePourMakesTheFillsTheirAirwiresTheirTrianglesAndThePlanesFile() throws {
        let unpoured = board(planes: [plane("p1")])
        XCTAssertEqual(unpoured.airwires.count, 1, "precondition: nothing joins the pads yet")
        let request = HorizontalPlanePourRequest(board: unpoured, inputs: HorizontalBoardPlaneInputs.signature(of: unpoured))

        let made = HorizontalPlanePourScheduler.pour(
            request, cache: HorizontalPlanePourCache(), cancellation: HorizontalPlanePourCancellation(), progress: { _ in }
        )
        let result = try XCTUnwrap(made.result)
        let fragments = try XCTUnwrap(result.fills.fragmentsByPlaneID["p1"])
        XCTAssertFalse(fragments.isEmpty, "precondition: the plane poured")
        XCTAssertEqual(result.fills.inputs, request.inputs)
        XCTAssertEqual(result.pouredPlaneIDs, ["p1"])
        XCTAssertTrue(result.fills.airwires.isEmpty, "the fill joins the two pads, so the rats' nest follows it")

        var poured = unpoured
        poured.planes[0].fragments = fragments
        XCTAssertEqual(result.planesFileData, try HorizontalProjectJSONApplicator.planeCacheData(board: poured),
                       "the planes file is the one the applicator writes, made off the main thread")
        XCTAssertEqual(result.fragmentKeys.count, fragments.count)
        XCTAssertEqual(Set(result.triangles.keys), result.fragmentKeys)
        for (index, fragment) in fragments.enumerated() {
            let key = boardPlaneFragmentKey(planeID: "p1", fragmentIndex: index, fragment: fragment)
            XCTAssertEqual(result.triangles[key], boardPlaneFragmentTrianglePoints(fragment),
                           "the triangles are the ones the canvas would make")
        }

        // Poured again unchanged, nothing is poured afresh, so nothing needs tessellating.
        let again = HorizontalPlanePourScheduler.pour(
            request, cache: made.cache, cancellation: HorizontalPlanePourCancellation(), progress: { _ in }
        )
        XCTAssertEqual(try XCTUnwrap(again.result).pouredPlaneIDs, [])
        XCTAssertTrue(try XCTUnwrap(again.result).triangles.isEmpty)

        // Poured afresh and coming out the same, a fill the canvas was last
        // handed is not tessellated again either.
        var knowing = request
        knowing.knownFragmentKeys = result.fragmentKeys
        let repoured = try XCTUnwrap(HorizontalPlanePourScheduler.pour(
            knowing, cache: HorizontalPlanePourCache(), cancellation: HorizontalPlanePourCancellation(), progress: { _ in }
        ).result)
        XCTAssertEqual(repoured.pouredPlaneIDs, ["p1"])
        XCTAssertTrue(repoured.triangles.isEmpty)
        XCTAssertEqual(repoured.fragmentKeys, result.fragmentKeys, "though the canvas is still told which fragments it has")
    }

    func testACancelledPourDeliversNothing() {
        let unpoured = board(planes: [plane("p1")])
        let cancellation = HorizontalPlanePourCancellation()
        cancellation.cancel()
        let made = HorizontalPlanePourScheduler.pour(
            HorizontalPlanePourRequest(board: unpoured, inputs: 1), cache: HorizontalPlanePourCache(),
            cancellation: cancellation, progress: { _ in }
        )
        XCTAssertNil(made.result)
    }

    func testAPourStoppedBetweenTiersKeepsTheTiersItFinished() throws {
        let unpoured = board(planes: [plane("first", priority: 0), plane("second", priority: 1, half: 6 * mm)])
        // Asked once before the first tier and once before its plane; the
        // third time, before the second tier, it says stop.
        let asks = AskCounter()
        let outcome = HorizontalBoardPlaneUpdater.pour(
            in: unpoured, cache: HorizontalPlanePourCache(), isCancelled: { asks.next() > 2 }
        )
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.pouredPlaneIDs, ["first"])
        XCTAssertTrue(outcome.board.planes.allSatisfy { $0.fragments.isEmpty }, "an unfinished pour hands back the board unpoured")
        let signature = HorizontalBoardPlaneUpdater.planeInputSignature(for: unpoured.planes[0], in: unpoured)
        let kept = try XCTUnwrap(outcome.cache.fragments(for: "first", signature: signature))
        XCTAssertFalse(kept.isEmpty, "what finished is in the cache for the pour that follows")
        XCTAssertNil(outcome.cache.fragments(for: "second", signature: 0))
    }

    func testUndoFindsTheFillsItPutsBackInTheCache() {
        let before = board(planes: [plane("p1")])
        var after = before
        after.packagePads[1].vertices = after.packagePads[1].vertices.map { HorizontalPoint(x: $0.x, y: $0.y + 2 * mm) }

        let first = HorizontalBoardPlaneUpdater.pour(in: before, cache: HorizontalPlanePourCache())
        let edited = HorizontalBoardPlaneUpdater.pour(in: after, cache: first.cache)
        XCTAssertEqual(edited.pouredPlaneIDs, ["p1"], "precondition: the edit changed the plane's inputs")
        let undone = HorizontalBoardPlaneUpdater.pour(in: before, cache: edited.cache)
        XCTAssertEqual(undone.pouredPlaneIDs, [], "the fill from before the edit is still remembered")
        XCTAssertEqual(undone.board.planes[0].fragments, first.board.planes[0].fragments)
    }

    func testTakingFillsReplacesOnlyThePlanesTheyName() {
        var board = board(planes: [plane("p1"), plane("p2", priority: 1)])
        board.planes[1].fragments = [HorizontalPlaneFragment(paths: [square(around: .zero, half: mm)], orphan: false)]
        let kept = board.planes[1].fragments
        let poured = [HorizontalPlaneFragment(paths: [square(around: HorizontalPoint(x: mm, y: 0), half: mm)], orphan: false)]

        XCTAssertFalse(board.takePlaneFills(HorizontalPlaneFills(inputs: 0, fragmentsByPlaneID: ["p1": poured], airwires: board.airwires)))
        XCTAssertEqual(board.planes[0].fragments, poured)
        XCTAssertEqual(board.planes[1].fragments, kept)
        XCTAssertTrue(board.takePlaneFills(HorizontalPlaneFills(inputs: 0, fragmentsByPlaneID: [:], airwires: [])),
                      "says so when the airwires change, which the canvas then draws again")
        XCTAssertTrue(board.airwires.isEmpty)
    }

    func testABoardReadBackTakesTheFillsInMemory() {
        var memory = board(planes: [plane("p1"), plane("p2", priority: 1)])
        let poured = [HorizontalPlaneFragment(paths: [square(around: .zero, half: mm)], orphan: false)]
        memory.planes[0].fragments = poured
        var readBack = board(planes: [plane("p1"), plane("p3", priority: 2)])
        readBack.carryPlaneFills(from: memory)
        XCTAssertEqual(readBack.planes[0].fragments, poured)
        XCTAssertEqual(readBack.planes[1].fragments, [], "a plane the memory board lacks keeps its own")
    }
}

private final class AskCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
