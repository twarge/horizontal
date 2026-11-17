import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// find_path through MCP: a path with the ops that draw it, which a dry run
/// with check then passes; and no path, with what blocks it. The board is
/// one channel of `BlockLayoutFixture`: OUT1 is R2's pad 2 at (5.75, 0) and
/// R3's at (10.75, 0), with R3's pad 1, of another net, between them.
final class HorizontalDispatchFindPathTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var client: BlockLayoutDispatchClient!
    private var instance: String { fixture.instances[0] }
    private let left = "33333333-3333-4333-8333-333333333331", right = "33333333-3333-4333-8333-333333333332"

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 1, innerLayers: 2)
        // A stub up from each OUT1 pad, the two not yet joined.
        try fixture.addCopper(
            junctions: [left: HorizontalPoint(x: 5_750_000, y: 1_000_000), right: HorizontalPoint(x: 10_750_000, y: -1_000_000)],
            tracks: ["44444444-4444-4444-8444-444444444441": (try fixture.padEnd(instance, "R2", 2), fixture.junctionEnd(left), 0),
                     "44444444-4444-4444-8444-444444444442": (try fixture.padEnd(instance, "R3", 2), fixture.junctionEnd(right), 0)])
        try fixture.saveToDisk()
        client = try BlockLayoutDispatchClient(path: fixture.url.path)
    }

    override func tearDown() {
        client?.close()
        fixture?.remove()
        super.tearDown()
    }

    private func find(_ more: JSONDictionary = [:]) throws -> JSONDictionary {
        var params: JSONDictionary = ["from": ["junction": left], "to": [["junction": right]], "width_mm": 0.2, "grid_mm": 0.05]
        params.merge(more) { _, new in new }
        return try XCTUnwrap(try client.result("find_path", params) as? JSONDictionary)
    }

    /// The path's ops, dry-run with check, take the airwire off and
    /// introduce nothing.
    func testAFoundPathsOpsDrawItClean() throws {
        let found = try find()
        XCTAssertEqual(found["found"] as? Bool, true, "\(found)")
        XCTAssertEqual(found.string("net_name"), "OUT1")
        let legs = try XCTUnwrap(found["path"] as? [JSONDictionary])
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(legs[0].int("layer"), 0)
        let points = try XCTUnwrap(legs[0]["points_mm"] as? [[Double]])
        XCTAssertEqual(points.first, [5.75, 1])
        XCTAssertEqual(points.last, [10.75, -1])
        XCTAssertGreaterThanOrEqual(found.dictionary("tightest")?.double("slack_mm") ?? -1, 0)
        let ops = try XCTUnwrap(found["ops"] as? [JSONDictionary])
        XCTAssertEqual(ops.count, points.count - 1)
        XCTAssertEqual(ops.first?.dictionary("from")?.string("junction"), left)
        XCTAssertEqual(ops.last?.dictionary("to")?.string("junction"), right)

        let dry = try XCTUnwrap(try client.result("apply", ["ops": ops, "dry_run": true, "check": "delta"]) as? JSONDictionary)
        let check = try XCTUnwrap(dry.dictionary("check"))
        XCTAssertEqual((check["introduced"] as? [JSONDictionary])?.count, 0, "\(check)")
        XCTAssertEqual(check.dictionary("airwires")?["nets_routed"] as? [String], ["OUT1"])
        XCTAssertEqual(check["ok"] as? Bool, true)
    }

    /// Fenced in, there is no path, and the fence is named; another layer
    /// and a via get out, and the ops place the via before the tracks that
    /// leave it.
    func testNoPathSaysWhatBlocksAndAViaGetsRoundIt() throws {
        let fence: JSONDictionary = ["layer": 0, "box_mm": [7.5, -4, 8, 4]]
        let blocked = try find(["avoid": [fence], "window_mm": 1])
        XCTAssertEqual(blocked["found"] as? Bool, false)
        XCTAssertEqual(blocked.string("reason"), "blocked")
        let wall = try XCTUnwrap(blocked.dictionary("blocked_by")?["from"] as? [JSONDictionary])
        XCTAssertTrue(wall.contains { $0.string("kind") == "avoid" }, "\(wall)")
        XCTAssertNil(blocked["ops"])

        let under = try find(["avoid": [fence], "window_mm": 1, "layers": [0, -1],
                              "via": "rules"])
        XCTAssertEqual(under["found"] as? Bool, true, "\(under)")
        XCTAssertEqual((under["vias"] as? [JSONDictionary])?.count, 2)
        let ops = try XCTUnwrap(under["ops"] as? [JSONDictionary])
        let kinds = ops.map { "\($0.string("op") ?? "")@\($0.int("layer") ?? 99)" }
        let firstVia = try XCTUnwrap(kinds.firstIndex(of: "place_via@99"))
        XCTAssertTrue(kinds[..<firstVia].allSatisfy { $0 == "place_track@0" })
        XCTAssertEqual(kinds[firstVia + 1], "place_track@-1")
        let dry = try XCTUnwrap(try client.result("apply", ["ops": ops, "dry_run": true, "check": "delta"]) as? JSONDictionary)
        XCTAssertEqual((dry.dictionary("check")?["introduced"] as? [JSONDictionary])?.count, 0, "\(dry)")
        XCTAssertEqual(dry.dictionary("check")?.dictionary("airwires")?["nets_routed"] as? [String], ["OUT1"])
    }

    /// An end on another net is refused before anything is searched.
    func testEndsOfTwoNetsAreRefused() throws {
        let reply = try client.call("find_path", ["from": ["junction": left], "to": [["component": "R1", "pad": "1"]], "width_mm": 0.2])
        XCTAssertNotNil(reply["error"], "\(reply)")
    }
}
