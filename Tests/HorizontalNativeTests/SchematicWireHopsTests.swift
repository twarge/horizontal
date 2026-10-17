import XCTest
@testable import HorizontalNative

/// Hops where wires of different nets cross (`HorizontalSchematicWireHops`).
final class SchematicWireHopsTests: XCTestCase {
    private let grid = 1_250_000.0
    private let radius = HorizontalSchematicWireHops.radius

    private func wire(_ id: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, net: String?) -> HorizontalSegment {
        HorizontalSegment(id: id, from: .init(x: x0 * grid, y: y0 * grid), to: .init(x: x1 * grid, y: y1 * grid),
                          width: 0, layer: nil, netID: net)
    }

    func testTheLevelWireHopsOverTheUprightOneOfAnotherNet() throws {
        let hops = HorizontalSchematicWireHops(lines: [
            wire("level", 0, 0, 10, 0, net: "a"),
            wire("upright", 4, -3, 4, 3, net: "b"),
        ])

        let hop = try XCTUnwrap(hops.hopsByLineID["level"]?.first)
        XCTAssertEqual(hops.hopsByLineID["level"]?.count, 1)
        XCTAssertNil(hops.hopsByLineID["upright"])
        XCTAssertEqual(hop.start, 4 * grid - radius, accuracy: 1)
        XCTAssertEqual(hop.end, 4 * grid + radius, accuracy: 1)
        XCTAssertEqual(hops.partnersByLineID["upright"], ["level"])

        let points = HorizontalSchematicWireHops.polyline(for: wire("level", 0, 0, 10, 0, net: "a"), hops: [hop])
        XCTAssertEqual(points.first, .init(x: 0, y: 0))
        XCTAssertEqual(points.last, .init(x: 10 * grid, y: 0))
        let top = try XCTUnwrap(points.max { $0.y < $1.y })
        XCTAssertEqual(top.y, radius, accuracy: radius * 0.05, "the hop rises above the wire")
        XCTAssertEqual(top.x, 4 * grid, accuracy: radius * 0.3)
        XCTAssertTrue(points.allSatisfy { $0.y >= -0.5 })
    }

    func testAHopRisesTheSameWayWhicheverWayTheWireWasDrawn() throws {
        let hops = HorizontalSchematicWireHops(lines: [
            wire("level", 10, 0, 0, 0, net: "a"),
            wire("upright", 4, -3, 4, 3, net: "b"),
        ])
        let points = HorizontalSchematicWireHops.polyline(for: wire("level", 10, 0, 0, 0, net: "a"),
                                                          hops: try XCTUnwrap(hops.hopsByLineID["level"]))
        XCTAssertGreaterThan(try XCTUnwrap(points.map(\.y).max()), radius * 0.9)
    }

    func testWiresOfOneNetAndTJointsDoNotHop() {
        let hops = HorizontalSchematicWireHops(lines: [
            wire("level", 0, 0, 10, 0, net: "a"),
            wire("same", 4, -3, 4, 3, net: "a"),
            wire("tee", 7, 0, 7, 4, net: "b"),
        ])
        XCTAssertTrue(hops.hopsByLineID.isEmpty)
    }

    func testAWireOnNoNetHopsAndIsHopped() {
        let hops = HorizontalSchematicWireHops(lines: [
            wire("level", 0, 0, 10, 0, net: nil),
            wire("upright", 4, -3, 4, 3, net: nil),
        ])
        XCTAssertEqual(hops.hopsByLineID["level"]?.count, 1)
    }

    func testCrossingsCloseTogetherShareOneHop() throws {
        let hops = HorizontalSchematicWireHops(lines: [
            wire("level", 0, 0, 10, 0, net: "a"),
            wire("first", 4, -3, 4, 3, net: "b"),
            wire("second", 4.6, -3, 4.6, 3, net: "c"),
            wire("apart", 8, -3, 8, 3, net: "d"),
        ])
        let level = try XCTUnwrap(hops.hopsByLineID["level"])
        XCTAssertEqual(level.count, 2)
        XCTAssertEqual(level[0].start, 4 * grid - radius, accuracy: 1)
        XCTAssertEqual(level[0].end, 4.6 * grid + radius, accuracy: 1)

        let points = HorizontalSchematicWireHops.polyline(for: wire("level", 0, 0, 10, 0, net: "a"), hops: level)
        let raised = points.filter { $0.y > radius * 0.99 }
        XCTAssertTrue(raised.contains { $0.x <= 4 * grid } && raised.contains { $0.x >= 4.6 * grid },
                      "the shared hop stays up across both crossings")
    }

    func testACrossingNearAWireEndGetsASmallerHopOrNone() throws {
        let hops = HorizontalSchematicWireHops(lines: [
            wire("short", 0, 0, 10, 0, net: "a"),
            wire("near", 0.25, -3, 0.25, 3, net: "b"),
            wire("nearer", 9.95, -3, 9.95, 3, net: "c"),
        ])
        let short = try XCTUnwrap(hops.hopsByLineID["short"])
        XCTAssertEqual(short.count, 1, "no room for a hop 0.05 grid from the end")
        XCTAssertEqual(short[0].height, 0.25 * grid, accuracy: 1)
        XCTAssertEqual(short[0].start, 0, accuracy: 1)
    }
}
