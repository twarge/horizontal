import XCTest
@testable import HorizontalNative

/// Exercises `HorizontalBoardPlaneUpdater.updateAllPlanes` — the whole Swift-side
/// pour: rule lookup, obstacle classification, the priority tier loop, thermal
/// inputs and orphan classification.
///
/// Nothing covered this path before. The clipper tests exercise the C primitives
/// (cutouts, outline contraction, thermals, hatch) but never a board going in and
/// fragments coming out.
///
/// A fill that differs is not a cosmetic difference — it is copper that is or is
/// not fabricated — so these pin observable geometry rather than asserting
/// against a copy of any implementation.
/// Collects progress callbacks. The pour calls back from whatever thread it runs
/// on — the app pours on a detached task — so the callback is `@Sendable` and
/// this has to be safe to write from there.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(completed: Int, total: Int)] = []

    func record(completed: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append((completed, total))
    }

    var steps: [(completed: Int, total: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

final class BoardPlanePourTests: XCTestCase {
    private let mm = 1_000_000.0
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func square(_ id: String, cx: Double, cy: Double, half: Double,
                        layer: Int = 0, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(cx - half, cy - half), p(cx + half, cy - half),
                       p(cx + half, cy + half), p(cx - half, cy + half)],
            layer: layer,
            netID: net
        )
    }

    private func outline(half: Double) -> HorizontalPolygon {
        square("outline", cx: 0, cy: 0, half: half, layer: HorizontalBoardLayers.outline)
    }

    /// A plane needs THREE things or it pours nothing, and each failure is silent:
    ///  • `fallbackPolygon` — the resolved source outline. The pour reads this,
    ///    not `polygonID`; without it `update` returns the plane zeroed.
    ///  • `fromRules = false` unless the board carries plane rules, since
    ///    settings are otherwise looked up from rules this board has none of.
    ///  • same-net copper somewhere on the board, or every poured fragment is an
    ///    ORPHAN and `keepOrphans == false` discards it. An unanchored plane
    ///    pours nothing — which is correct: copper connected to no net is copper
    ///    that should not be fabricated.
    private func plane(_ id: String, half: Double, net: String?, layer: Int = 0,
                       cx: Double = 0, cy: Double = 0, keepOrphans: Bool = false) -> HorizontalPlane {
        var value = HorizontalPlane(
            id: id, netID: net, polygonID: "poly-\(id)", layer: layer,
            priority: 0, fillStyle: "solid", minWidth: 200_000,
            keepOrphans: keepOrphans, fragments: []
        )
        value.fallbackPolygon = square("poly-\(id)", cx: cx, cy: cy, half: half, layer: layer, net: net)
        value.fromRules = false
        return value
    }

    private func makeBoard(polygons: [HorizontalPolygon], planes: [HorizontalPlane],
                           packagePads: [HorizontalPolygon] = []) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/pour.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: polygons, planes: planes, keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: packagePads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    /// NET copper area: the outer ring minus any holes punched in it. Summing
    /// only the outer ring would miss cutouts entirely — a hole leaves the outer
    /// contour untouched.
    private func area(_ plane: HorizontalPlane) -> Double {
        func ringArea(_ ring: [HorizontalPoint]) -> Double {
            guard ring.count > 2 else { return 0 }
            var sum = 0.0
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        }
        return plane.fragments.reduce(0) { total, fragment in
            guard let outer = fragment.paths.first else { return total }
            let holes = fragment.paths.dropFirst().reduce(0) { $0 + ringArea($1) }
            return total + ringArea(outer) - holes
        }
    }

    /// A pad on the plane's own net, which anchors the pour.
    private func anchor(net: String = "gnd") -> HorizontalPolygon {
        square("anchor", cx: 8 * mm, cy: 8 * mm, half: 500_000, net: net)
    }

    // MARK: - Tests

    func testAnchoredPlanePours() throws {
        let board = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [plane("p1", half: 10 * mm, net: "gnd")],
            packagePads: [anchor()]
        )
        let updated = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes.first)

        XCTAssertFalse(updated.fragments.isEmpty, "a plane anchored by same-net copper must pour")
        XCTAssertGreaterThan(area(updated) / (mm * mm), 300, "should cover most of the 20mm square")
    }

    /// A plane with no same-net copper anywhere pours NOTHING: every fragment is
    /// an orphan and is discarded. That is correct — copper connected to no net
    /// is copper that should not be fabricated — and it is the single most
    /// surprising behaviour of this path, because the failure is silent.
    ///
    /// (`keepOrphans` on the plane does not override this when `fromRules` is
    /// false; retention is governed by the effective settings, not the stored
    /// flag. Not asserted here because it is not what this test is about.)
    func testUnanchoredPlanePoursNothing() throws {
        let board = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [plane("p1", half: 10 * mm, net: "gnd")]
        )
        let poured = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes.first)
        XCTAssertTrue(poured.fragments.isEmpty)
    }

    /// Foreign copper must be cut out, or a pour would short to every pad it
    /// covers.
    func testForeignPadIsCutOut() throws {
        let bare = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [plane("p1", half: 10 * mm, net: "gnd")],
            packagePads: [anchor()]
        )
        let withForeign = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [plane("p1", half: 10 * mm, net: "gnd")],
            packagePads: [anchor(), square("pad1", cx: 0, cy: 0, half: 2 * mm, net: "vcc")]
        )

        let a = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: bare).planes.first)
        let b = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: withForeign).planes.first)

        XCTAssertGreaterThan(
            (area(a) - area(b)) / (mm * mm), 9,
            "a 4mm foreign pad plus its clearance must be removed from the fill"
        )
    }

    /// The progress callback drives the pour overlay's ring, so it has to report
    /// once per plane, count up, and finish at the total — a ring that stalls
    /// short of full or repeats a step reads as a hang on a board that is in
    /// fact still working.
    func testProgressIsReportedOncePerPlaneInOrder() {
        let collector = ProgressCollector()
        let board = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [
                plane("p1", half: 4 * mm, net: "gnd", cx: -5 * mm),
                plane("p2", half: 4 * mm, net: "gnd", cx: 5 * mm),
                plane("p3", half: 4 * mm, net: "gnd", cx: 5 * mm, cy: 5 * mm),
            ],
            packagePads: [anchor()]
        )

        _ = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board) { completed, total in
            collector.record(completed: completed, total: total)
        }

        XCTAssertEqual(collector.steps.map(\.completed), [1, 2, 3])
        XCTAssertEqual(Set(collector.steps.map(\.total)), [3], "total must be every plane on the board")
    }

    /// Reported totals come from the board, not the tier, so planes spread over
    /// several priority tiers still count towards one run to 100% rather than
    /// restarting the ring at each tier.
    func testProgressSpansPriorityTiers() {
        let collector = ProgressCollector()
        var low = plane("p1", half: 4 * mm, net: "gnd", cx: -5 * mm)
        low.priority = 1
        var high = plane("p2", half: 4 * mm, net: "gnd", cx: 5 * mm)
        high.priority = 9
        let board = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [low, high],
            packagePads: [anchor()]
        )

        _ = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board) { completed, total in
            collector.record(completed: completed, total: total)
        }

        XCTAssertEqual(collector.steps.map(\.completed), [1, 2])
        XCTAssertEqual(Set(collector.steps.map(\.total)), [2])
    }

    /// Pouring twice must give the same answer: fragments are zeroed before
    /// recomputing, so an already-poured board is not a different input.
    func testPourIsIdempotent() throws {
        let board = makeBoard(
            polygons: [outline(half: 12 * mm)],
            planes: [plane("p1", half: 10 * mm, net: "gnd")],
            packagePads: [anchor(), square("pad1", cx: 3 * mm, cy: 0, half: 1 * mm, net: "vcc")]
        )
        let once = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board)
        let twice = HorizontalBoardPlaneUpdater.updateAllPlanes(in: once)

        let a = try XCTUnwrap(once.planes.first)
        let b = try XCTUnwrap(twice.planes.first)
        XCTAssertEqual(a.fragments.count, b.fragments.count)
        XCTAssertEqual(area(a), area(b), accuracy: 1)
    }

    /// How close the fill comes to a track's centreline, from `points` along
    /// it: the least distance from any edge of the fill within `radius` of
    /// `near` to any of its legs.
    private func closestApproach(
        of plane: HorizontalPlane,
        to points: [HorizontalPoint],
        near: HorizontalPoint,
        radius: Double
    ) -> Double {
        func distance(_ point: HorizontalPoint, _ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
            let ab = b - a, ap = point - a
            let length = ab.x * ab.x + ab.y * ab.y
            let t = length > 0 ? max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / length)) : 0
            return hypot(ap.x - ab.x * t, ap.y - ab.y * t)
        }
        var closest = Double.infinity
        let legs = Array(zip(points, points.dropFirst()))
        for ring in plane.fragments.flatMap(\.paths) {
            for (index, a) in ring.enumerated() {
                let b = ring[(index + 1) % ring.count]
                guard hypot(a.x - near.x, a.y - near.y) < radius || hypot(b.x - near.x, b.y - near.y) < radius else {
                    continue
                }
                for (from, to) in legs {
                    closest = min(closest, distance(a, from, to), distance(b, from, to),
                                  distance(from, a, b), distance(to, a, b))
                }
            }
        }
        return closest
    }

    /// The fill keeps its clearance from a track all the way round, as
    /// Horizon's does: round the outside of a bend and round a free end, where
    /// the track's copper is round, as it is drawn and exported. The pour took
    /// a track as a strip with square ends, which left a notch on the outside
    /// of every bend that the clearance only partly filled (70 µm short at
    /// this 90° bend), and brought the fill over the round end of a track
    /// that stops in it, onto the other net's copper.
    func testTheFillKeepsItsClearanceRoundBendsAndEnds() throws {
        let width = 600_000.0
        let corner = p(0, 0)
        for bend in [p(5 * mm, 5 * mm), p(0, 5 * mm)] {
            var board = makeBoard(
                polygons: [outline(half: 12 * mm)],
                planes: [plane("p1", half: 10 * mm, net: "gnd")],
                packagePads: [anchor()]
            )
            let start = p(-5 * mm, 0)
            board.junctions = ["start": start, "corner": corner, "end": bend]
            board.tracks = [
                HorizontalSegment(id: "in", from: start, to: corner, width: width, layer: 0, netID: "vcc"),
                HorizontalSegment(id: "out", from: corner, to: bend, width: width, layer: 0, netID: "vcc"),
            ]
            let clearance = Double(board.rules.clearanceCopper(net1: "gnd", net2: "vcc", layer: 0).clearance(.track, .plane))
            XCTAssertGreaterThan(clearance, 0)
            let poured = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes.first)
            XCTAssertFalse(poured.fragments.isEmpty)

            // Within the chords of the round ends and the clipper's 2 µm arc
            // tolerance.
            let rule = width / 2 + clearance
            for (place, point) in [("the bend", corner), ("the free end", start), ("the other free end", bend)] {
                let approach = closestApproach(of: poured, to: [start, corner, bend], near: point, radius: 2 * mm)
                XCTAssertGreaterThan(approach, rule - 5_000,
                                     "\(place), bending to \(bend.x / mm), \(bend.y / mm) mm: the fill comes \((rule - approach) / 1000) µm too close")
            }
        }
    }
}
