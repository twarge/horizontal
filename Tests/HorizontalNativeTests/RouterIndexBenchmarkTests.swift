import XCTest
@testable import HorizontalNative

/// Measures the router index against a real board.
///
/// `docs/push-shove-router.md` budgets the whole interactive solve at ~5 ms per
/// mouse-move, so an obstacle query has to cost microseconds — it happens many
/// times inside that budget. Synthetic boards will not show the pathologies, so
/// this uses a real one and skips when it is absent.
///
/// Deliberately asserts nothing about elapsed time, following
/// `BoardMovePerfBenchmarkTests`. A timing assertion fails on a busy machine and
/// teaches everyone to ignore it; the numbers are written out to be read.
final class RouterIndexBenchmarkTests: XCTestCase {
    func testIndexPerformanceOnARealBoard() throws {
        let path = ProcessInfo.processInfo.environment["HORIZONTAL_GOLDEN_BOARD"]
            ?? "/Users/kornack/Repositories/randi/Randi Short Horizon/Randi Short.hprj"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real board available")
        }
        let board = try XCTUnwrap(HorizontalProject.load(from: URL(fileURLWithPath: path)).board)

        let extractStart = DispatchTime.now().uptimeNanoseconds
        let world = HorizontalRouterWorld.extract(from: board)
        let extractMs = Double(DispatchTime.now().uptimeNanoseconds - extractStart) / 1_000_000

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let index = HorizontalRouterIndex(world: world)
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000

        XCTAssertFalse(index.obstacles.isEmpty, "a real board must produce obstacles")

        // A track-sized probe swept over the board, which is the shape of query
        // the router makes while dragging.
        let bounds = board.bounds
        let probeHalf = 250_000.0
        var queries = 0
        var hits = 0
        let queryStart = DispatchTime.now().uptimeNanoseconds
        var y = bounds.minY
        while y <= bounds.maxY {
            var x = bounds.minX
            while x <= bounds.maxX {
                let probe = HorizontalOctagon(
                    center: HorizontalPoint(x: x, y: y), radius: probeHalf)
                hits += index.obstacles(colliding: probe, on: 0).count
                queries += 1
                x += 500_000
            }
            y += 500_000
        }
        let queryMs = Double(DispatchTime.now().uptimeNanoseconds - queryStart) / 1_000_000

        let report = """
        obstacles: \(index.obstacles.count) \
        (tracks \(world.tracks.count), pads \(world.solids.count), vias \(world.vias.count))
        world extract: \(String(format: "%.1f", extractMs)) ms
        index build:   \(String(format: "%.1f", buildMs)) ms
        queries:       \(queries) in \(String(format: "%.1f", queryMs)) ms \
        = \(String(format: "%.1f", queryMs * 1000 / Double(max(queries, 1)))) µs each
        hits:          \(hits)
        """
        try? report.write(toFile: "/tmp/router-index-bench.txt", atomically: true, encoding: .utf8)
    }
}
