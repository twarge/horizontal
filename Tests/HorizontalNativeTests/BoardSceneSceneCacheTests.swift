import Foundation
import XCTest
@testable import HorizontalNative

/// The 3D view's scene cache: the first scene is built at once, an edit
/// keeps the old scene up while a new one builds after the edits settle,
/// and a burst of edits costs one rebuild plus one catch-up pass.
@MainActor
final class BoardSceneSceneCacheTests: XCTestCase {
    private func board(polygonCount: Int) -> HorizontalBoard {
        let mm = 1_000_000.0
        var board = HorizontalBoard.poolEditorBoard(uuid: "cache", name: "Cache", url: URL(fileURLWithPath: "/tmp/cache"))
        for index in 0..<polygonCount {
            let x = Double(index) * 10 * mm
            board.polygons.append(HorizontalPolygon(id: "p\(index)", vertices: [
                HorizontalPoint(x: x, y: 0), HorizontalPoint(x: x + 5 * mm, y: 0),
                HorizontalPoint(x: x + 5 * mm, y: 5 * mm), HorizontalPoint(x: x, y: 5 * mm),
            ], layer: HorizontalBoardLayers.outline))
        }
        return board
    }

    private func waitForBuilds(_ cache: BoardSceneSceneCache, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while cache.isBuilding, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testFirstSceneBuildsAtOnceAndIsReturnedAfterwards() async {
        let cache = BoardSceneSceneCache()
        var readyRevisions = [Int]()
        let first = cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in readyRevisions.append(cache.builtRevision ?? -1) }
        XCTAssertNil(first, "nothing to show before the first build")
        XCTAssertTrue(cache.isBuilding)
        await waitForBuilds(cache)
        XCTAssertEqual(readyRevisions, [0])
        XCTAssertNotNil(cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in XCTFail("nothing to build") })
        XCTAssertFalse(cache.isBuilding)
    }

    func testAnEditKeepsTheOldSceneUpUntilTheNewOneIsReady() async {
        let cache = BoardSceneSceneCache()
        _ = cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in }
        await waitForBuilds(cache)
        let shown = cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in }

        var readyRevisions = [Int]()
        let standIn = cache.nodes(for: board(polygonCount: 2), revision: 1) { _ in readyRevisions.append(cache.builtRevision ?? -1) }
        XCTAssertTrue(standIn === shown, "the previous scene stands in")
        XCTAssertTrue(cache.isBuilding)
        // Nothing happens until the edits settle.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cache.builtRevision, 0)
        await waitForBuilds(cache)
        XCTAssertEqual(cache.builtRevision, 1)
        XCTAssertEqual(readyRevisions, [1])
        XCTAssertFalse(cache.nodes(for: board(polygonCount: 2), revision: 1) { _ in } === shown)
    }

    func testABurstOfEditsCostsOneRebuildAndOneCatchUp() async {
        let cache = BoardSceneSceneCache()
        _ = cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in }
        await waitForBuilds(cache)

        var readyRevisions = [Int]()
        for revision in 1...5 {
            _ = cache.nodes(for: board(polygonCount: revision + 1), revision: revision) { _ in readyRevisions.append(cache.builtRevision ?? -1) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        await waitForBuilds(cache)
        XCTAssertEqual(cache.builtRevision, 5)
        XCTAssertEqual(readyRevisions, [5], "the burst settled into a single build")

        // An edit that lands once the first settle window has passed (so
        // during or right after that build) is picked up by one more pass;
        // a tiny board builds too fast to pin down which.
        readyRevisions = []
        _ = cache.nodes(for: board(polygonCount: 40), revision: 6) { _ in readyRevisions.append(cache.builtRevision ?? -1) }
        try? await Task.sleep(for: .milliseconds(450))
        _ = cache.nodes(for: board(polygonCount: 3), revision: 7) { _ in readyRevisions.append(cache.builtRevision ?? -1) }
        await waitForBuilds(cache)
        XCTAssertEqual(cache.builtRevision, 7)
        XCTAssertEqual(readyRevisions.last, 7)
        XCTAssertLessThanOrEqual(readyRevisions.count, 2)
    }

    func testReturningToTheBuiltRevisionCancelsThePendingRebuild() async {
        let cache = BoardSceneSceneCache()
        _ = cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in }
        await waitForBuilds(cache)
        _ = cache.nodes(for: board(polygonCount: 1), silkscreenClipping: HorizontalSilkscreenClipping(clearance: 100_000), revision: 0) { _ in XCTFail("cancelled") }
        XCTAssertTrue(cache.isBuilding)
        _ = cache.nodes(for: board(polygonCount: 1), revision: 0) { _ in XCTFail("nothing to build") }
        XCTAssertFalse(cache.isBuilding)
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(cache.builtRevision, 0)
    }
}
