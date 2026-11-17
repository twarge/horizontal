import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The path search behind find_path: a legal path on the board's exact
/// shapes where there is one, and where there is none the items that bound
/// what it could reach.
final class HorizontalPathSearchTests: XCTestCase {
    private typealias Fixture = BoardGeometryFixture
    private let mm = BoardGeometryFixture.mm
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { Fixture.p(x, y) }

    private func search(_ board: HorizontalBoard, from: HorizontalPoint, to: [HorizontalPoint], layers: [Int] = [0], width: Double = 0.1,
                        net: String = "net-a", via: HorizontalViaShape? = nil, targetLayers: [Int] = [],
                        configure: (inout HorizontalBoardProbe, inout HorizontalPathSearch.Request) -> Void = { _, _ in })
        -> HorizontalPathSearch.Outcome {
        var probe = HorizontalBoardProbe(board: board)
        var request = HorizontalPathSearch.Request(from: from, targets: to.map { .init(point: $0, layers: targetLayers) }, layers: layers,
                                                   width: width * mm, net: net, via: via)
        configure(&probe, &request)
        var search = HorizontalPathSearch(probe: probe, request: request)
        return search.run()
    }

    private func path(_ outcome: HorizontalPathSearch.Outcome, file: StaticString = #filePath, line: UInt = #line) -> HorizontalPathSearch.Path? {
        guard case .found(let path) = outcome else {
            XCTFail("no path: \(outcome)", file: file, line: line)
            return nil
        }
        return path
    }

    /// The path as the check would see it: its legs as tracks on the board.
    private func drawn(_ path: HorizontalPathSearch.Path, on fixture: Fixture, net: String, width: Double = 0.1, id: String = "new") -> Fixture {
        var fixture = fixture
        for (legIndex, leg) in path.legs.enumerated() where leg.points.count >= 2 {
            for index in leg.points.indices.dropLast() {
                fixture.tracks.append(Fixture.track("\(id)-\(legIndex)-\(index)", leg.points[index], leg.points[index + 1], net: net,
                                                    width: width, layer: leg.layer))
            }
        }
        return fixture
    }

    /// With nothing in the way the path is the straight line.
    func testAnOpenBoardRoutesStraight() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        let found = try XCTUnwrap(path(search(fixture.board, from: p(10, 10), to: [p(14, 10)])))
        XCTAssertEqual(found.legs.count, 1)
        XCTAssertEqual(found.legs[0].points, [p(10, 10), p(14, 10)])
        XCTAssertEqual(found.length, 4 * mm, accuracy: 1)
        XCTAssertEqual(found.bends, 0)
        // Of several ends it takes the nearest it can reach.
        let either = try XCTUnwrap(path(search(fixture.board, from: p(10, 10), to: [p(14, 10), p(10, 11)])))
        XCTAssertEqual(either.target, 1)
    }

    /// A wall of another net is gone round where it ends inside the search
    /// window; what is drawn passes the clearance check.
    func testAPathGoesRoundWhatIsInTheWay() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        fixture.tracks = [Fixture.track("wall", p(12, 4), p(12, 11), net: "net-b")]
        let found = try XCTUnwrap(path(search(fixture.board, from: p(10, 5), to: [p(14, 5)])))
        XCTAssertGreaterThan(found.length, 4.4 * mm)
        XCTAssertLessThan(found.length, 6 * mm)
        XCTAssertGreaterThanOrEqual(found.bends, 2)
        // Under the wall's lower end, which is nearer than its upper.
        XCTAssertTrue(found.legs[0].points.contains { $0.y < 3.8 * mm })
        let board = drawn(found, on: fixture, net: "net-a").board
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board).filter { $0.check == .copper }.map(\.title), [])
        // The same request finds the same path.
        let again = try XCTUnwrap(path(search(fixture.board, from: p(10, 5), to: [p(14, 5)])))
        XCTAssertEqual(again.legs[0].points, found.legs[0].points)
    }

    /// A wall across the whole window leaves no path, and the reply names the
    /// wall; ignoring it, or another layer and a via, gets through.
    func testNoPathNamesWhatBoundsEachSide() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        fixture.tracks = [Fixture.track("wall", p(12, -10), p(12, 30), net: "net-b")]
        let board = fixture.board
        guard case .blocked(let fromSide, let toSide, let reachedWindowEdge) = search(board, from: p(10, 5), to: [p(14, 5)]) else {
            return XCTFail("a path through a wall")
        }
        let probe = HorizontalBoardProbe(board: board)
        func ids(_ blockers: [HorizontalPathSearch.Blocker]) -> [String] {
            blockers.compactMap { blocker -> String? in
                if case .item(let index) = blocker.obstacle { return probe.items.items[index].id }
                return nil
            }
        }
        XCTAssertEqual(ids(fromSide), ["wall"])
        XCTAssertEqual(ids(toSide), ["wall"])
        XCTAssertEqual(fromSide.first?.layer, 0)
        XCTAssertTrue(reachedWindowEdge, "the wall runs out of the window, so a way round may lie beyond it")

        let ripped = try XCTUnwrap(path(search(board, from: p(10, 5), to: [p(14, 5)]) { probe, _ in probe.ignored = ["wall"] }))
        XCTAssertEqual(ripped.bends, 0)

        // Down through a via, under the wall, and up again to an end that
        // is on the top layer only.
        let via = HorizontalViaShape(diameter: 0.35 * mm, hole: 0.15 * mm, layers: [0, -100], definition: nil, definitionID: nil, source: "local")
        let under = try XCTUnwrap(path(search(board, from: p(10, 5), to: [p(14, 5)], layers: [0, -100], via: via, targetLayers: [0]) { _, request in
            request.fromLayers = [0]
        }))
        XCTAssertEqual(under.legs.map(\.layer), [0, -100, 0])
        XCTAssertEqual(under.vias.count, 2)
        XCTAssertEqual(under.legs.last?.points.last, p(14, 5))
        // Each via keeps the via-to-track clearance from the wall.
        for point in under.vias {
            XCTAssertGreaterThanOrEqual(abs(point.x - 12 * mm), (0.175 + 0.125 + 0.1) * mm - 1)
        }
        // With an end that may be on either layer one via is enough.
        let oneVia = try XCTUnwrap(path(search(board, from: p(10, 5), to: [p(14, 5)], layers: [0, -100], via: via) { _, request in
            request.fromLayers = [0]
        }))
        XCTAssertEqual(oneVia.vias.count, 1)
    }

    /// A slot with five micrometres to spare each side is a slot: between two
    /// vias 0.71 mm apart a 0.1 mm track has 0.36 mm where it needs 0.35.
    func testATrackGoesThroughASlotItJustFits() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        fixture.vias = [Fixture.via("low", at: p(20, 10), net: "net-b"), Fixture.via("high", at: p(20, 10.71), net: "net-b")]
        // Walls, so the slot is the only way.
        fixture.tracks = [Fixture.track("below", p(20, 10), p(20, 0), net: "net-b"), Fixture.track("above", p(20, 10.71), p(20, 25), net: "net-b")]
        let found = try XCTUnwrap(path(search(fixture.board, from: p(19, 10.355), to: [p(21, 10.355)])))
        XCTAssertEqual(found.legs[0].points, [p(19, 10.355), p(21, 10.355)])
        let board = drawn(found, on: fixture, net: "net-a").board
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board).filter { $0.check == .copper }.count, 0)
        // A hair narrower and there is none: the rules ask 0.35 mm of a 0.345 mm slot.
        fixture.vias[1] = Fixture.via("high", at: p(20, 10.695), net: "net-b")
        fixture.tracks[1] = Fixture.track("above", p(20, 10.695), p(20, 25), net: "net-b")
        guard case .blocked(let fromSide, _, _) = search(fixture.board, from: p(19, 10.3475), to: [p(21, 10.3475)]) else {
            return XCTFail("a path through a slot too narrow")
        }
        XCTAssertFalse(fromSide.isEmpty)
        // A margin asks for more than the slot has.
        fixture.vias[1] = Fixture.via("high", at: p(20, 10.71), net: "net-b")
        fixture.tracks[1] = Fixture.track("above", p(20, 10.71), p(20, 25), net: "net-b")
        guard case .blocked = search(fixture.board, from: p(19, 10.355), to: [p(21, 10.355)], configure: { probe, _ in probe.margin = 0.01 * 1_000_000 }) else {
            return XCTFail("a path through a slot the margin closes")
        }
    }

    /// An area to keep out of is kept out of, and a request too large for
    /// its budget says so instead of running.
    func testAvoidAndTheSizeOfASearch() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        let board = fixture.board
        let detour = try XCTUnwrap(path(search(board, from: p(10, 5), to: [p(14, 5)]) { probe, _ in
            probe.avoid = [.init(layer: 0, box: HorizontalRect(points: [self.p(11.5, 4), self.p(12.5, 6.5)]))]
        }))
        XCTAssertGreaterThan(detour.length, 4.5 * mm)
        XCTAssertTrue(detour.legs[0].points.allSatisfy { !($0.x > 11.5 * mm && $0.x < 12.5 * mm && $0.y > 4 * mm && $0.y < 6.5 * mm) })
        guard case .tooLarge = search(board, from: p(10, 5), to: [p(90, 25)]) else {
            return XCTFail("eighty millimetres by twenty at 25 µm is more than a search spans")
        }
        _ = try XCTUnwrap(path(search(board, from: p(10, 5), to: [p(90, 25)]) { _, request in request.pitch = 200_000 }))
    }

    /// Two nets come in from the west edge, A above B. B's end is a pad
    /// against the north edge, over an obstacle; A's is south-east of it.
    /// Each has a path alone. Once either is drawn the other has none on
    /// that layer, and the one drawn is named as what blocks it.
    func testTwoNetsThatMustCrossBlockEachOther() throws {
        let fixture = Self.crossingFixture()
        let a = try XCTUnwrap(path(search(fixture.board, from: Self.crossing.aStart, to: [Self.crossing.aEnd], width: 0.2)))
        let b = try XCTUnwrap(path(search(fixture.board, from: Self.crossing.bStart, to: [Self.crossing.bEnd], width: 0.2, net: "net-b")))

        let withA = drawn(a, on: fixture, net: "net-a", width: 0.2, id: "a").board
        guard case .blocked(let fromSide, _, _) = search(withA, from: Self.crossing.bStart, to: [Self.crossing.bEnd], width: 0.2, net: "net-b") else {
            return XCTFail("B crossed A")
        }
        let probe = HorizontalBoardProbe(board: withA)
        XCTAssertTrue(fromSide.contains { blocker in
            if case .item(let index) = blocker.obstacle { return probe.items.items[index].id.hasPrefix("a-") }
            return false
        })
        let withB = drawn(b, on: fixture, net: "net-b", width: 0.2, id: "b").board
        guard case .blocked = search(withB, from: Self.crossing.aStart, to: [Self.crossing.aEnd], width: 0.2) else {
            return XCTFail("A crossed B")
        }
    }

    static let crossing = (aStart: BoardGeometryFixture.p(0.4, 4), aEnd: BoardGeometryFixture.p(14, 1),
                           bStart: BoardGeometryFixture.p(0.4, 2), bEnd: BoardGeometryFixture.p(10, 5.5))

    /// A strip 20 × 6 mm with an obstacle in its middle and B's pad against
    /// its north edge.
    static func crossingFixture() -> BoardGeometryFixture {
        var fixture = BoardGeometryFixture()
        fixture.rules = BoardGeometryFixture.clearanceRules(0.125)
        fixture.outline = (min: (0, 0), max: (20, 6))
        fixture.pads = [
            // The obstacle, of a third net.
            BoardGeometryFixture.pad("pkg/pad/p1/shape/s1", minX: 8, minY: 2.5, maxX: 12, maxY: 3.5, net: "net-c"),
            // B's end, up against the north edge: nothing passes north of it.
            BoardGeometryFixture.pad("pkg/pad/p2/shape/s1", minX: 9.5, minY: 5.2, maxX: 10.5, maxY: 5.8, net: "net-b", name: "2"),
        ]
        return fixture
    }
}
