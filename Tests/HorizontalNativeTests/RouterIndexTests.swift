import XCTest
@testable import HorizontalNative

/// The router's spatial index (`docs/push-shove-router.md`, step 2).
///
/// One property matters more than the rest: the index may never MISS an
/// obstacle. A false positive costs an exact test the caller was going to make
/// anyway; a false negative is a collision the router cannot see, and a board
/// that ships with a short. So the central test is an exhaustive comparison
/// against brute force rather than a set of examples.
final class RouterIndexTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func world(
        tracks: [HorizontalRouterWorld.Track] = [],
        solids: [HorizontalRouterWorld.Solid] = [],
        vias: [HorizontalRouterWorld.Via] = []
    ) -> HorizontalRouterWorld {
        var world = HorizontalRouterWorld()
        world.tracks = tracks
        world.solids = solids
        world.vias = vias
        return world
    }

    private func track(_ id: Int64, _ a: HorizontalPoint, _ b: HorizontalPoint,
                       layer: Int = 0, net: Int = 1, width: Double = 200_000)
        -> HorizontalRouterWorld.Track {
        .init(id: id, from: a, to: b, center: nil, width: width,
              layer: layer, netCode: net, locked: false)
    }

    /// A deterministic pseudo-random board: enough obstacles, spread over
    /// several layers, for the grid to actually bucket rather than degenerate
    /// into one cell. Seeded by hand so a failure is reproducible.
    private func syntheticWorld(count: Int) -> HorizontalRouterWorld {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var tracks: [HorizontalRouterWorld.Track] = []
        for index in 0..<count {
            let x = Double(next(50_000_000))
            let y = Double(next(50_000_000))
            let dx = Double(next(2_000_000)) - 1_000_000
            let dy = Double(next(2_000_000)) - 1_000_000
            let layer = [0, -1, -2, -100][next(4)]
            tracks.append(track(Int64(index), p(x, y), p(x + dx, y + dy),
                                layer: layer, net: next(20)))
        }
        return world(tracks: tracks)
    }

    /// Brute force: every obstacle whose box overlaps and whose layer matches.
    private func bruteForce(
        _ index: HorizontalRouterIndex, box: HorizontalRect, layer: Int
    ) -> Set<Int> {
        var expected = Set<Int>()
        for (position, obstacle) in index.obstacles.enumerated() {
            guard obstacle.layerMin <= layer, layer <= obstacle.layerMax else { continue }
            guard obstacle.box.maxX >= box.minX, obstacle.box.minX <= box.maxX,
                  obstacle.box.maxY >= box.minY, obstacle.box.minY <= box.maxY else { continue }
            expected.insert(position)
        }
        return expected
    }

    // MARK: - The property

    func testTheIndexNeverMissesAnObstacle() {
        let index = HorizontalRouterIndex(world: syntheticWorld(count: 600))

        var seed: UInt64 = 0xC0FFEE
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }

        for _ in 0..<400 {
            let x = Double(next(52_000_000)) - 1_000_000
            let y = Double(next(52_000_000)) - 1_000_000
            let w = Double(next(4_000_000)) + 1
            let h = Double(next(4_000_000)) + 1
            let layer = [0, -1, -2, -100][next(4)]
            let box = HorizontalRect(points: [p(x, y), p(x + w, y + h)])

            var found = Set<Int>()
            index.forEachObstacle(overlapping: box, on: layer) { position, _ in
                found.insert(position)
            }
            let expected = bruteForce(index, box: box, layer: layer)

            XCTAssertTrue(
                expected.isSubset(of: found),
                "missed \(expected.subtracting(found).count) obstacle(s) in \(box) on layer \(layer)"
            )
            // And the converse, which is not required for correctness but keeps
            // the index honest about how much work it hands the caller.
            XCTAssertEqual(found, expected, "the box filter should be exact")
        }
    }

    /// An obstacle spanning many cells must be reported once, not once per cell.
    func testObstaclesAreVisitedOnce() {
        let long = track(1, p(0, 0), p(40_000_000, 0), width: 500_000)
        let index = HorizontalRouterIndex(world: world(tracks: [long]))

        var visits = 0
        index.forEachObstacle(
            overlapping: HorizontalRect(points: [p(-1_000_000, -1_000_000),
                                                 p(41_000_000, 1_000_000)]),
            on: 0
        ) { _, _ in visits += 1 }

        XCTAssertEqual(visits, 1)
    }

    /// Repeated queries must not leak state between them — the visit stamps are
    /// reused, and getting that wrong makes the SECOND query return nothing.
    func testRepeatedQueriesAreIndependent() {
        let index = HorizontalRouterIndex(world: syntheticWorld(count: 200))
        let box = HorizontalRect(points: [p(0, 0), p(50_000_000, 50_000_000)])

        var counts: [Int] = []
        for _ in 0..<5 {
            var found = 0
            index.forEachObstacle(overlapping: box, on: 0) { _, _ in found += 1 }
            counts.append(found)
        }
        XCTAssertEqual(Set(counts).count, 1, "each query must see the same board: \(counts)")
        XCTAssertGreaterThan(counts[0], 0)
    }

    // MARK: - Layers

    func testLayerFilteringExcludesOtherLayers() {
        let index = HorizontalRouterIndex(world: world(tracks: [
            track(1, p(0, 0), p(1_000_000, 0), layer: 0),
            track(2, p(0, 0), p(1_000_000, 0), layer: -100),
        ]))
        let box = HorizontalRect(points: [p(-1_000_000, -1_000_000), p(2_000_000, 1_000_000)])

        var top: [Int] = []
        index.forEachObstacle(overlapping: box, on: 0) { position, _ in top.append(position) }
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(index.obstacles[top[0]].kind, .track(0))
    }

    /// A via reaches every layer it spans, so it must be found from all of them.
    /// Missing this is how a router routes a track straight through a via.
    func testAViaIsFoundOnEveryLayerItSpans() {
        var world = self.world()
        world.vias = [.init(id: 1, pos: p(0, 0), layerStart: 0, layerEnd: -100,
                            diameter: 600_000, drill: 300_000, netCode: 2)]
        let index = HorizontalRouterIndex(world: world)
        let box = HorizontalRect(points: [p(-1_000_000, -1_000_000), p(1_000_000, 1_000_000)])

        for layer in [0, -1, -50, -100] {
            var found = 0
            index.forEachObstacle(overlapping: box, on: layer) { _, _ in found += 1 }
            XCTAssertEqual(found, 1, "a through via must be visible on layer \(layer)")
        }
    }

    // MARK: - The collision query

    func testCollisionQueryIsExactAndIgnoresItsOwnNet() {
        let index = HorizontalRouterIndex(world: world(tracks: [
            track(1, p(0, 0), p(10_000_000, 0), layer: 0, net: 1),
            track(2, p(0, 5_000_000), p(10_000_000, 5_000_000), layer: 0, net: 2),
        ]))

        // A hull straddling the first track only.
        let probe = HorizontalOctagon(from: p(5_000_000, 0), to: p(5_000_000, 0), width: 400_000)
        XCTAssertEqual(index.obstacles(colliding: probe, on: 0).count, 1)

        // Same query, told to ignore that net: the router does not collide with
        // the net it is currently routing.
        XCTAssertTrue(index.obstacles(colliding: probe, on: 0, ignoringNet: 1).isEmpty)

        // A net of -1 means "no net", which must NOT be treated as a match — two
        // unconnected pieces of copper still have to clear each other.
        XCTAssertEqual(index.obstacles(colliding: probe, on: 0, ignoringNet: -1).count, 1)
    }

    func testAnEmptyWorldAnswersEveryQuery() {
        let index = HorizontalRouterIndex(world: world())
        var visits = 0
        index.forEachObstacle(
            overlapping: HorizontalRect(points: [p(0, 0), p(1_000, 1_000)]), on: 0
        ) { _, _ in visits += 1 }
        XCTAssertEqual(visits, 0)
        XCTAssertTrue(index.obstacles(colliding: HorizontalOctagon(center: p(0, 0), radius: 1),
                                      on: 0).isEmpty)
    }
}

/// The obstacle kinds the router could not see at all until they were
/// extracted. A clearance resolved correctly for a mounting hole is worth
/// nothing if the hole is not in the world, so these check presence and class
/// together — the class is what the clearance is then looked up by.
extension RouterIndexTests {
    private func boardWorld(
        holes: [HorizontalRouterWorld.UnplatedHole] = [],
        keepouts: [HorizontalRouterWorld.Keepout] = [],
        contours: [HorizontalRouterWorld.Contour] = []
    ) -> HorizontalRouterWorld {
        var world = HorizontalRouterWorld()
        world.unplatedHoles = holes
        world.keepouts = keepouts
        world.contours = contours
        return world
    }

    /// Routing through a mounting hole drills the track away. It has no net, so
    /// it can never be excused as same-net, and it goes through the board, so it
    /// obstructs every layer.
    func testAnUnplatedHoleObstructsEveryLayerAndHasNoNet() {
        let index = HorizontalRouterIndex(world: boardWorld(
            holes: [.init(position: HorizontalPoint(x: 0, y: 0), diameter: 3_000_000)]))
        XCTAssertEqual(index.obstacles.count, 1)
        XCTAssertEqual(index.obstacles[0].objectClass, .holeUnplated)
        XCTAssertEqual(index.obstacles[0].netCode, -1)

        let box = HorizontalRect(points: [HorizontalPoint(x: -2_000_000, y: -2_000_000),
                                          HorizontalPoint(x: 2_000_000, y: 2_000_000)])
        for layer in [0, -1, -2, -100] {
            var found = 0
            index.forEachObstacle(overlapping: box, on: layer) { _, _ in found += 1 }
            XCTAssertEqual(found, 1, "a drill obstructs layer \(layer)")
        }
    }

    func testAKeepoutCarriesItsClassSoItsOwnRuleApplies() {
        let square = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 1_000_000, y: 0),
                      HorizontalPoint(x: 1_000_000, y: 1_000_000), HorizontalPoint(x: 0, y: 1_000_000)]
        let index = HorizontalRouterIndex(world: boardWorld(keepouts: [
            .init(points: square, layerMin: 0, layerMax: 0,
                  keepoutClass: "no-copper", copperPatchTypes: ["track"]),
        ]))
        XCTAssertEqual(index.obstacles.count, 1)
        XCTAssertEqual(index.obstacles[0].objectClass, .keepout("no-copper"))
    }

    /// A keepout that bars only planes is not an obstacle to a track, and
    /// treating it as one would refuse legal routes across most ground pours.
    func testAKeepoutThatDoesNotBarTracksIsNotAnObstacle() {
        let square = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 1_000_000, y: 0),
                      HorizontalPoint(x: 1_000_000, y: 1_000_000), HorizontalPoint(x: 0, y: 1_000_000)]
        let index = HorizontalRouterIndex(world: boardWorld(keepouts: [
            .init(points: square, layerMin: 0, layerMax: 0,
                  keepoutClass: "no-plane", copperPatchTypes: ["plane"]),
        ]))
        XCTAssertTrue(index.obstacles.isEmpty)
    }

    /// The board outline becomes one obstacle PER EDGE. As a single hull it
    /// would be the whole board and collide with every track inside it — which
    /// is why it was left out of the index entirely until now.
    func testTheBoardOutlineBecomesEdgesNotOneBigHull() {
        let outline = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 50_000_000, y: 0),
                       HorizontalPoint(x: 50_000_000, y: 40_000_000),
                       HorizontalPoint(x: 0, y: 40_000_000)]
        let index = HorizontalRouterIndex(world: boardWorld(
            contours: [.init(points: outline, closed: true)]))

        XCTAssertEqual(index.obstacles.count, 4, "four edges, not one hull")
        XCTAssertTrue(index.obstacles.allSatisfy { $0.objectClass == .boardEdge })

        // The middle of the board must touch none of them.
        let middle = HorizontalOctagon(
            center: HorizontalPoint(x: 25_000_000, y: 20_000_000), radius: 500_000)
        XCTAssertTrue(index.obstacles(colliding: middle, on: 0).isEmpty,
                      "a track in open board must not collide with the outline")

        // A track at the edge must touch exactly the near edge.
        let atEdge = HorizontalOctagon(
            center: HorizontalPoint(x: 25_000_000, y: 100_000), radius: 300_000)
        XCTAssertEqual(index.obstacles(colliding: atEdge, on: 0).count, 1)
    }

    /// A through-hole pad and a surface pad resolve to different rule entries,
    /// so the index has to tell them apart rather than calling both "pad".
    func testPadClassFollowsItsLayerSpan() {
        var world = HorizontalRouterWorld()
        let square = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 500_000, y: 0),
                      HorizontalPoint(x: 500_000, y: 500_000), HorizontalPoint(x: 0, y: 500_000)]
        world.solids = [
            .init(points: square, layerMin: 0, layerMax: 0, netCode: 1),
            .init(points: square, layerMin: -100, layerMax: 0, netCode: 1),
        ]
        let index = HorizontalRouterIndex(world: world)

        XCTAssertEqual(index.obstacles[0].objectClass, .pad)
        XCTAssertEqual(index.obstacles[1].objectClass, .padThroughHole)
    }
}
