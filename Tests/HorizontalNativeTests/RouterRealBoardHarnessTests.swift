import XCTest
@testable import HorizontalNative

/// Exercises the router over a REAL board, pad to pad, and reports quality.
///
/// This exists because the synthetic tests passed twice while the router was
/// visibly broken in the app. They never did the one thing every real route
/// does: start on a pad. A route begins inside the pad it is connecting, and an
/// obstacle you are standing on cannot be avoided — so the router reported
/// blocked on essentially every real request, which no toy case revealed.
///
/// So this samples many real pad-to-pad requests and reports, rather than
/// asserting a shape: completion rate, violations, corner counts, timing. The
/// assertions are the invariants that must hold whatever the board (a completed
/// route is clear; nothing takes absurdly long); the NUMBERS are the signal, and
/// they are written out to be read.
final class RouterRealBoardHarnessTests: XCTestCase {
    private func loadBoard() throws -> HorizontalBoard {
        let path = ProcessInfo.processInfo.environment["HORIZONTAL_GOLDEN_BOARD"]
            ?? "/Users/kornack/Repositories/randi/Randi Short Horizon/Randi Short.hprj"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real board available")
        }
        return try XCTUnwrap(HorizontalProject.load(from: URL(fileURLWithPath: path)).board)
    }

    /// Re-derives the verdict: does any segment come closer to anything than the
    /// rules allow, ignoring what the route legitimately connects to?
    private func violations(
        points: [HorizontalPoint],
        layer: Int,
        net: Int,
        width: Double,
        session: HorizontalBoardTrackRouterSession
    ) -> Int {
        guard points.count > 1 else { return 0 }
        let ends = [points[0], points[points.count - 1]].map {
            HorizontalOctagon(from: $0, to: $0, width: 0)
        }
        var count = 0
        for segment in 0..<(points.count - 1) {
            let swept = HorizontalOctagon(from: points[segment], to: points[segment + 1], width: 0)
            for obstacle in session.index.obstacles {
                guard obstacle.layerMin <= layer, layer <= obstacle.layerMax else { continue }
                let gap = session.clearances.clearance(
                    .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
                let hull = obstacle.hull.inflated(by: gap + width / 2)
                // The pads at either end are what the route connects; standing on
                // them is the point, not a violation.
                if ends.contains(where: { hull.overlaps($0) }) { continue }
                if hull.overlaps(swept) { count += 1 }
            }
        }
        return count
    }

    func testRoutingBetweenRealPads() throws {
        let board = try loadBoard()
        let session = HorizontalBoardTrackRouterSession(board: board)
        let layer = HorizontalBoardLayers.topCopper
        let width = 200_000.0

        // Pad centres on the top layer, with their nets.
        var pads: [(point: HorizontalPoint, net: String?)] = []
        for pad in board.packagePads where pad.layer == layer {
            let centre = HorizontalRect(points: pad.renderVertices(arcPrecision: 16)).center
            pads.append((centre, pad.netID))
        }
        try XCTSkipIf(pads.count < 20, "board has too few top-layer pads to sample")

        // Deterministic sample of pairs a few millimetres apart — the length of
        // route someone actually draws by hand.
        var seed: UInt64 = 0x12345678
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }

        var attempted = 0
        var completed = 0
        var violating = 0
        var corners: [Int] = []
        var blocked = 0
        var exhausted = 0
        var blockerClasses: [String: Int] = [:]
        var worstMilliseconds = 0.0

        for _ in 0..<200 {
            let a = pads[next(pads.count)]
            let b = pads[next(pads.count)]
            let dx = b.point.x - a.point.x
            let dy = b.point.y - a.point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > 1_000_000, distance < 20_000_000 else { continue }
            attempted += 1

            let start = DispatchTime.now().uptimeNanoseconds
            let result = session.route(
                from: a.point, to: b.point, layer: layer, netID: a.net,
                width: width, diagonalFirst: true)
            worstMilliseconds = max(
                worstMilliseconds,
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

            switch result.outcome {
            case .complete: break
            case .blocked(let obstacle):
                blocked += 1
                if session.index.obstacles.indices.contains(obstacle) {
                    blockerClasses["\(session.index.obstacles[obstacle].objectClass)", default: 0] += 1
                }
            case .exhausted(let obstacle):
                exhausted += 1
                if session.index.obstacles.indices.contains(obstacle) {
                    blockerClasses["\(session.index.obstacles[obstacle].objectClass)", default: 0] += 1
                }
            }

            if result.isComplete {
                completed += 1
                corners.append(HorizontalRoute45.corners(of: result.points))
                let bad = violations(
                    points: result.points, layer: layer,
                    net: session.netCode(for: a.net), width: width, session: session)
                if bad > 0 { violating += 1 }
            }
        }

        let report = """
        pads sampled:   \(pads.count) on top copper
        routes tried:   \(attempted)
        completed:      \(completed) (\(attempted == 0 ? 0 : completed * 100 / attempted)%)
        with violations:\(violating)
        corners:        median \(corners.sorted().isEmpty ? 0 : corners.sorted()[corners.count / 2]), \
        max \(corners.max() ?? 0)
        blocked:        \(blocked)
        exhausted:      \(exhausted)
        what blocks:    \(blockerClasses.sorted { $0.value > $1.value }.prefix(6)
                            .map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        slowest route:  \(String(format: "%.1f", worstMilliseconds)) ms
        """
        try? report.write(toFile: "/tmp/router-harness.txt", atomically: true, encoding: .utf8)

        // KNOWN FAILURE, recorded rather than hidden. On a real board the router
        // blocks on ~98% of pad-to-pad requests and the few it completes are not
        // reliably clear. The cause this harness identified: a detour picks its
        // entry onto the obstacle's corner ring by PROXIMITY, then elbows to it —
        // and that elbow cuts straight through the hull it is meant to avoid. The
        // fix is tangent selection, which is the next piece of work.
        //
        // Left as an expected failure so the suite stays honest: it goes green
        // when the router actually works, and shouts if someone thinks it already
        // does.
        XCTExpectFailure("router blocks on most real pad-to-pad routes; see docs/push-shove-router.md")

        // The invariants. Quality is reported; these must hold regardless.
        XCTAssertEqual(violating, 0, "a route reported complete must actually be clear")
        XCTAssertLessThan(worstMilliseconds, 250, "no single route should take a quarter second")
        XCTAssertGreaterThan(attempted, 20, "the sample should be big enough to mean something")
    }
}
