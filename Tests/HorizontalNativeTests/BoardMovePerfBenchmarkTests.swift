import XCTest
@testable import HorizontalNative

/// Decisive performance benchmark for the "select whole board + arrow nudge =
/// beachball" report. Loads the real Coriander board and times the move-plan
/// stages at WHOLE-BOARD-SELECTION scale with a real clock. The goal is to find
/// which stage is super-linear (O(n^2)) by running with N and 2N refs.
///
/// TEMP FILE: this is a benchmark, not a correctness test. Safe to delete after
/// the numbers are captured.
final class BoardMovePerfBenchmarkTests: XCTestCase {
    private func ms(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }

    private func loadBoard() throws -> HorizontalBoard {
        let base = URL(fileURLWithPath: "/Users/kornack/Repositories/coriander/Coriander Horizon")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("Coriander board not available")
        }
        var diagnostics = [HorizontalDiagnostic]()
        return try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )
    }

    /// Mirror of BoardCanvasView.buildAllBoardSelectables(in:) using the same
    /// public helpers so the count + cost is representative of what the cache
    /// builds for a whole board. (The View's method is private.)
    private func buildAllSelectables(_ board: HorizontalBoard) -> [HorizontalSelectable] {
        var s = [HorizontalSelectable]()
        // polygons (edges)
        func polygonEdges(_ polygons: [HorizontalPolygon]) -> [HorizontalSelectable] {
            polygons.flatMap { polygon -> [HorizontalSelectable] in
                guard polygon.polygonVertices.count >= 2 else { return [] }
                var result = [HorizontalSelectable]()
                for index in polygon.polygonVertices.indices {
                    let edgePoints = polygon.edgePolyline(at: index, arcPrecision: 24)
                    guard edgePoints.count >= 2 else { continue }
                    result.append(HorizontalSelectable.bounds(
                        ref: HorizontalSelectableRef(id: polygon.id, type: .polygonEdge, layer: polygon.layer),
                        points: edgePoints,
                        fallbackCenter: HorizontalRect(points: edgePoints).center,
                        fallbackSize: 200_000))
                }
                return result
            }
        }
        s += polygonEdges(board.polygons)
        s += polygonEdges(board.planes.compactMap(\.fallbackPolygon))
        s += board.keepouts.map { k in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: k.id, type: .keepout, layer: k.polygon.layer),
                points: k.points, fallbackCenter: HorizontalRect(points: k.points).center, fallbackSize: 1_000_000)
        }
        s += board.dimensions.map { d in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: d.id, type: .dimension),
                points: d.points, fallbackCenter: (d.p0 + d.p1) * 0.5, fallbackSize: d.labelSize)
        }
        s += HorizontalCanvasModeSupport.segmentSelectables(board.lines, type: .boardLine, convertsArcSegments: true)
        s += HorizontalCanvasModeSupport.arcSelectables(board.arcs, type: .boardArc)
        s += HorizontalCanvasModeSupport.segmentSelectables(board.tracks, type: .track, convertsArcSegments: true)
        s += HorizontalCanvasModeSupport.segmentSelectables(board.netTies, type: .boardNetTie, convertsArcSegments: true)
        s += HorizontalCanvasModeSupport.segmentSelectables(board.connectionLines, type: .connectionLine, convertsArcSegments: true)
        s += board.junctions.map { id, point in
            HorizontalSelectable.point(ref: HorizontalSelectableRef(id: id, type: .junction), at: point)
        }
        s += board.vias.map { via in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: via.id, type: .via, layer: via.layer),
                points: via.boundsPoints, fallbackCenter: via.position, fallbackSize: via.size)
        }
        s += (board.holes + board.packageHoles).map { hole in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: hole.id, type: .boardHole),
                points: hole.boundsPoints, fallbackCenter: hole.position, fallbackSize: hole.diameter)
        }
        s += board.packagePads.map { pad in
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: pad.id, type: .pad, layer: pad.layer),
                points: pad.vertices, fallbackCenter: HorizontalRect(points: pad.vertices).center, fallbackSize: 200_000)
        }
        s += HorizontalCanvasModeSupport.textSelectables(board.texts + board.packageTexts)
        return s
    }

    /// Build the whole-board selection ref list the planner would actually be
    /// asked to move (every movable board object).
    private func allMovableRefs(_ board: HorizontalBoard) -> [HorizontalSelectableRef] {
        var refs = [HorizontalSelectableRef]()
        refs += board.tracks.map { HorizontalSelectableRef(id: $0.id, type: .track, layer: $0.layer) }
        refs += board.netTies.map { HorizontalSelectableRef(id: $0.id, type: .boardNetTie, layer: $0.layer) }
        refs += board.vias.map { HorizontalSelectableRef(id: $0.id, type: .via, layer: $0.layer) }
        refs += board.lines.map { HorizontalSelectableRef(id: $0.id, type: .boardLine, layer: $0.layer) }
        refs += board.arcs.map { HorizontalSelectableRef(id: $0.id, type: .boardArc, layer: $0.layer) }
        refs += (board.holes + board.packageHoles).map { HorizontalSelectableRef(id: $0.id, type: .boardHole) }
        refs += board.junctions.keys.map { HorizontalSelectableRef(id: $0, type: .junction) }
        // The whole board includes all packages (147), which sets includesPackages.
        let packageIDs = Set(board.packagePads.compactMap { BoardMovePlanner.packageID(forGeometryID: $0.id) }
            + board.packageHoles.compactMap { BoardMovePlanner.packageID(forGeometryID: $0.id) })
        refs += packageIDs.map { HorizontalSelectableRef(id: $0, type: .boardPackage) }
        return refs
    }

    func testWholeBoardMovePlanBenchmark() throws {
        let board = try loadBoard()

        print("=========== BOARD COUNTS ===========")
        print("tracks:        \(board.tracks.count)")
        print("netTies:       \(board.netTies.count)")
        print("vias:          \(board.vias.count)")
        print("viaHoles:      \(board.viaHoles.count)")
        print("holes:         \(board.holes.count)")
        print("packageHoles:  \(board.packageHoles.count)")
        print("packagePads:   \(board.packagePads.count)")
        print("lines:         \(board.lines.count)")
        print("arcs:          \(board.arcs.count)")
        print("junctions:     \(board.junctions.count)")
        print("polygons:      \(board.polygons.count)")
        print("planes:        \(board.planes.count)")
        print("texts:         \(board.texts.count)  packageTexts: \(board.packageTexts.count)")
        print("connectionLines: \(board.connectionLines.count)")

        // ---- Stage 1: build ALL selectables ----
        var selectables = [HorizontalSelectable]()
        var t1 = 0.0
        for i in 0..<3 {
            let dt = ms { selectables = buildAllSelectables(board) }
            if i == 2 { t1 = dt }
        }
        print("\n=========== STAGE 1: build ALL selectables ===========")
        print("selectables count: \(selectables.count)")
        print(String(format: "build selectables (warm): %.2f ms", t1))

        // ---- Stage 2: connectivityIndex for whole board ----
        var t2 = 0.0
        var connEntries = 0
        for i in 0..<3 {
            var index = BoardMoveConnectivityIndex()
            let dt = ms {
                index = BoardMovePlanner.connectivityIndex(
                    tracks: board.tracks,
                    netTies: board.netTies,
                    junctions: board.junctions,
                    junctionNetIDs: board.junctionNetIDs,
                    vias: board.vias,
                    packagePads: board.packagePads,
                    packageHoles: board.packageHoles,
                    includesPackages: true)
            }
            if i == 2 { t2 = dt; connEntries = index.segmentEndpointsByPoint.count }
        }
        print("\n=========== STAGE 2: connectivityIndex (whole board) ===========")
        print("segmentEndpointsByPoint buckets: \(connEntries)")
        print(String(format: "connectivityIndex (warm): %.2f ms", t2))

        // ---- Stage 3: residentMovePlan for ALL refs (the per-press suspect) ----
        let allRefs = allMovableRefs(board)
        print("\n=========== STAGE 3: residentMovePlan ===========")
        print("whole-board movable refs (N): \(allRefs.count)")

        func planMs(_ refs: [HorizontalSelectableRef]) -> (Double, BoardResidentMovePlan) {
            var plan = BoardResidentMovePlan()
            let dt = ms {
                plan = BoardMovePlanner.residentMovePlan(
                    for: refs,
                    tracks: board.tracks,
                    netTies: board.netTies,
                    junctions: board.junctions,
                    junctionNetIDs: board.junctionNetIDs,
                    vias: board.vias,
                    packagePads: board.packagePads,
                    packageHoles: board.packageHoles)
            }
            return (dt, plan)
        }

        // Half (N/2) vs full (N) to detect super-linearity.
        let halfRefs = Array(allRefs.prefix(allRefs.count / 2))

        // warm
        _ = planMs(halfRefs)
        _ = planMs(allRefs)

        let (tHalf, _) = planMs(halfRefs)
        let (tFull, fullPlan) = planMs(allRefs)
        print(String(format: "residentMovePlan N/2 (%d refs): %.2f ms", halfRefs.count, tHalf))
        print(String(format: "residentMovePlan N   (%d refs): %.2f ms", allRefs.count, tFull))
        let ratio = tHalf > 0 ? tFull / tHalf : Double.nan
        print(String(format: "ratio (N / N-half): %.2fx  (≈2x => linear, ≈4x => quadratic)", ratio))
        print("plan output: translated=\(fullPlan.translatedRefs.count) segmentMoves=\(fullPlan.segmentMoves.count) unsupported=\(fullPlan.unsupportedRefs.count)")

        // ---- Stage 3b: scaling curve to nail the exponent ----
        print("\n=========== STAGE 3b: scaling curve (residentMovePlan) ===========")
        let fractions = [0.125, 0.25, 0.5, 1.0]
        var prev: (n: Int, t: Double)? = nil
        for f in fractions {
            let n = max(1, Int(Double(allRefs.count) * f))
            let subset = Array(allRefs.prefix(n))
            _ = planMs(subset) // warm
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 { best = min(best, planMs(subset).0) }
            var note = ""
            if let p = prev, p.t > 0 {
                let sizeRatio = Double(n) / Double(p.n)
                let timeRatio = best / p.t
                // exponent = log(timeRatio)/log(sizeRatio)
                let exp = log(timeRatio) / log(sizeRatio)
                note = String(format: "  (x%.2f size -> x%.2f time, exponent≈%.2f)", sizeRatio, timeRatio, exp)
            }
            print(String(format: "n=%5d  %.2f ms%@", n, best, note))
            prev = (n, best)
        }

        // ---- Stage 3c: isolate which ref type drives the super-linear cost ----
        // Run residentMovePlan with ONLY junction refs vs ONLY via refs vs ONLY
        // track refs, each at full count, to attribute the quadratic blowup.
        print("\n=========== STAGE 3c: per-ref-type attribution ===========")
        func only(_ type: HorizontalObjectType) -> [HorizontalSelectableRef] { allRefs.filter { $0.type == type } }
        for (label, subset) in [
            ("junction", only(.junction)),
            ("via", only(.via)),
            ("track", only(.track)),
            ("boardHole", only(.boardHole)),
            ("boardPackage", only(.boardPackage)),
        ] {
            guard !subset.isEmpty else { continue }
            _ = planMs(subset) // warm
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 { best = min(best, planMs(subset).0) }
            print(String(format: "%-13@ refs=%5d  %.2f ms", label as NSString, subset.count, best))
        }

        // ---- Stage 4: per-press cost narrative ----
        print("\n=========== PER-PRESS COST (move path) ===========")
        print("moveSelectionByGrid: beginMove() runs ONLY on first press (moveState==nil);")
        print("subsequent presses call updateMove() which just stores lastPoint (O(1)).")
        print("beginMove() cost = boardResidentMovePlan (Stage 3 N) + snapTargets + selection center.")
        print("The metal patch (boardMetalMovePatches) DOES run per press over translated+segment refs,")
        print("but that requires the View's GPU metadata and is not reachable from this test.")
        print(String(format: "=> First-press plan cost at whole-board scale: ~%.1f ms", tFull))

        XCTAssertFalse(allRefs.isEmpty)
    }
}
