import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// How many tracks fit through a gap, and whether nets can leave a region
/// and share a layer once out.
final class HorizontalChannelCapacityTests: XCTestCase {
    private typealias Fixture = BoardGeometryFixture
    private let mm = BoardGeometryFixture.mm
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { Fixture.p(x, y) }

    /// Between a via Ø0.35 at (55.5, 4.375) and a 0.1 mm track along
    /// y = 5.18, with 0.125 mm asked of both, a 0.1 mm track's centre may lie
    /// from y = 4.725 to 4.955: room for two, and for one once a margin of
    /// 0.01 mm is asked as well.
    func testTwoTracksFitBetweenAViaAndATrackAndOneWithAMargin() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        fixture.vias = [Fixture.via("v", at: p(55.5, 4.375), net: "net-b")]
        fixture.tracks = [Fixture.track("t", p(54, 5.18), p(57, 5.18), net: "net-c", width: 0.1)]
        var probe = HorizontalBoardProbe(board: fixture.board)
        let gaps = HorizontalChannelCapacity.gaps(probe: probe, from: p(55.5, 4.375), to: p(55.5, 5.18), layer: 0, width: 0.1 * mm, net: "net-a")
        XCTAssertEqual(gaps.count, 1)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.from.y, 4.725 * mm, accuracy: 100)
        XCTAssertEqual(gap.to.y, 4.955 * mm, accuracy: 100)
        XCTAssertEqual(gap.tracks, 2)
        func id(_ obstacle: HorizontalBoardProbe.Obstacle?) -> String? {
            if case .item(let index)? = obstacle { return probe.items.items[index].id }
            return nil
        }
        XCTAssertEqual(id(gap.before), "v")
        XCTAssertEqual(id(gap.after), "t")

        probe.margin = 0.01 * mm
        let tighter = HorizontalChannelCapacity.gaps(probe: probe, from: p(55.5, 4.375), to: p(55.5, 5.18), layer: 0, width: 0.1 * mm, net: "net-a")
        XCTAssertEqual(tighter.first?.tracks, 1)
        XCTAssertEqual(tighter.first?.centres ?? 0, 0.21 * mm, accuracy: 200)
        // On the bottom only the via is in the way, and the cut runs out clear.
        probe.margin = 0
        let bottom = HorizontalChannelCapacity.gaps(probe: probe, from: p(55.5, 4.375), to: p(55.5, 5.18), layer: -100, width: 0.1 * mm, net: "net-a")
        XCTAssertEqual(bottom.count, 1)
        XCTAssertNil(bottom.first?.after)
        XCTAssertEqual(bottom.first?.to.y ?? 0, 5.18 * mm, accuracy: 1)
        // A cut across two gaps finds both.
        fixture.vias.append(Fixture.via("w", at: p(55.5, 6.5), net: "net-b"))
        let both = HorizontalChannelCapacity.gaps(probe: HorizontalBoardProbe(board: fixture.board), from: p(55.5, 4.375), to: p(55.5, 6.5),
                                                  layer: 0, width: 0.1 * mm, net: "net-a")
        XCTAssertEqual(both.count, 2)
    }

    /// Two nets enter a strip from the west, A above B; B's end is against
    /// the north edge over an obstacle and A's south-east of it. Each has a
    /// path alone; together they must cross, so they are listed as unable to
    /// share the layer, and with a second layer each is given its own.
    func testNetsThatMustCrossAreListedAndGivenLayersApart() throws {
        let fixture = HorizontalPathSearchTests.crossingFixture()
        let ends = HorizontalPathSearchTests.crossing
        func analysis(layers: [Int]) -> HorizontalEscapeAnalysis.Result {
            HorizontalEscapeAnalysis(
                board: fixture.board, region: HorizontalRect(points: [p(0.2, 0.2), p(19.8, 5.8)]),
                nets: [.init(id: "net-a", start: ends.aStart, startLayers: layers, target: ends.aEnd),
                       .init(id: "net-b", start: ends.bStart, startLayers: layers, target: ends.bEnd, targetLayers: [0])],
                layers: layers, width: 0.2 * mm, pitch: 100_000).run()
        }
        let one = analysis(layers: [0])
        XCTAssertEqual(one.alone["net-a"], [0])
        XCTAssertEqual(one.alone["net-b"], [0])
        XCTAssertEqual(one.pairs.count, 1)
        XCTAssertEqual(one.pairs[0].crossing, [0])
        XCTAssertEqual(one.pairs[0].shared, [])
        XCTAssertEqual(one.layerAssignment["net-a"] ?? nil, 0)
        XCTAssertNil(one.layerAssignment["net-b"] ?? nil, "one layer cannot hold both")

        // B's end is a pad on the top, so on the bottom only A has a path.
        let two = analysis(layers: [0, -100])
        XCTAssertEqual(two.alone["net-a"], [0, -100])
        XCTAssertEqual(two.alone["net-b"], [0])
        XCTAssertEqual(two.pairs[0].crossing, [0])
        XCTAssertEqual(two.layerAssignment["net-b"] ?? nil, nil, "taken in order, A has the top")
    }

    /// The gaps in a region's edge are its gates, each with what it holds;
    /// a net reaches the gates its side of a wall, and three nets with one
    /// gate of two between them are a bottleneck.
    func testGatesReachAndTheBottleneck() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        // A box of another net's tracks round (10…12, 10…12), open only in
        // a slot on its east side from y = 10.7 to 11.3 less the tracks' ends.
        func wall(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint) -> HorizontalSegment { Fixture.track(id, a, b, net: "net-c", width: 0.1) }
        fixture.tracks = [wall("s", p(10, 10), p(12, 10)), wall("w", p(10, 10), p(10, 12)), wall("n", p(10, 12), p(12, 12)),
                          wall("e1", p(12, 10), p(12, 10.7)), wall("e2", p(12, 11.3), p(12, 12))]
        func analysis(_ nets: [String]) -> HorizontalEscapeAnalysis.Result {
            HorizontalEscapeAnalysis(
                board: fixture.board, region: HorizontalRect(points: [p(10, 10), p(12, 12)]),
                nets: nets.enumerated().map { .init(id: $1, start: p(10.6 + 0.3 * Double($0), 11), startLayers: [0]) },
                layers: [0], width: 0.1 * mm, pitch: 25_000).run()
        }
        let one = analysis(["net-a"])
        // The slot is 0.6 mm less a track's half width and its clearance
        // each side, and the 0.1 mm track's own half: 0.6 − 2 × 0.225 = 0.15
        // of room for centres, which is one track.
        XCTAssertEqual(one.gates.count, 1)
        XCTAssertEqual(one.gates[0].side, "east")
        XCTAssertEqual(one.gates[0].gap.tracks, 1)
        XCTAssertEqual(one.gates[0].gap.centres, 0.15 * mm, accuracy: 200)
        XCTAssertEqual(one.reach["net-a"], [0])
        XCTAssertEqual(one.assignment["net-a"], 0)
        XCTAssertNil(one.bottleneck)

        let crowd = analysis(["net-a", "net-b"])
        let bottleneck = try XCTUnwrap(crowd.bottleneck)
        XCTAssertEqual(bottleneck.nets, ["net-a", "net-b"])
        XCTAssertEqual(bottleneck.gates, [0])
        XCTAssertEqual(bottleneck.capacity, 1)
    }
}
