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
        // NSNull drops a default, as leaving the key out would.
        params = params.filter { !($0.value is NSNull) }
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
        XCTAssertEqual(ops[firstVia]["net_pinned"] as? Bool, false,
                       "a path's via takes its tracks' net, as Horizon's router leaves one, and follows them to another")
        let dry = try XCTUnwrap(try client.result("apply", ["ops": ops, "dry_run": true, "check": "delta"]) as? JSONDictionary)
        XCTAssertEqual((dry.dictionary("check")?["introduced"] as? [JSONDictionary])?.count, 0, "\(dry)")
        XCTAssertEqual(dry.dictionary("check")?.dictionary("airwires")?["nets_routed"] as? [String], ["OUT1"])
    }

    /// A path that has to leave a pad for another layer changes layer beside
    /// the pad and not in it, though the via in the pad is the shorter way.
    /// via_in_pad asks for that one.
    func testALayerChangeIsMadeClearOfThePadUnlessAsked() throws {
        // From R2's pad 2 to a point 3 mm below it, the top fenced off
        // between them: the short way is straight down through a via in the
        // pad, the other round by a via beside it.
        let request: JSONDictionary = ["from": ["component": fixture.flat(instance, "R2"), "pad": "2"], "to": [["x_mm": 5.75, "y_mm": -3]],
                                       "avoid": [["layer": 0, "box_mm": [4.5, -1.2, 7, -0.8]] as JSONDictionary],
                                       "window_mm": 1, "layers": [0, -1], "via": "rules"]
        func inPad(_ via: JSONDictionary) throws -> JSONDictionary? {
            let candidate: JSONDictionary = ["via": ["net": "OUT1", "x_mm": via.double("x_mm") ?? 0, "y_mm": via.double("y_mm") ?? 0] as JSONDictionary]
            let reply = try XCTUnwrap(try client.result("probe_clearance", ["candidates": [candidate]]) as? JSONDictionary)
            return (reply["candidates"] as? [JSONDictionary])?.first?.dictionary("in_pad")
        }
        let beside = try find(request)
        XCTAssertEqual(beside["found"] as? Bool, true, "\(beside)")
        let vias = try XCTUnwrap(beside["vias"] as? [JSONDictionary])
        XCTAssertEqual(vias.count, 1)
        XCTAssertNil(try inPad(vias[0]), "\(vias)")

        var asked = request
        asked["via_in_pad"] = true
        let within = try find(asked)
        XCTAssertEqual(within["found"] as? Bool, true, "\(within)")
        let first = try XCTUnwrap((within["vias"] as? [JSONDictionary])?.first)
        XCTAssertNotNil(try inPad(first), "\(first)")
        XCTAssertLessThan(within.double("length_mm") ?? 99, beside.double("length_mm") ?? 0)
    }

    /// Where the only room for a via is in the pad, there is no path, and
    /// the reply says a via fitted there; allowed, the path goes through it.
    func testNoPathSaysWhenOnlyAViaInThePadWouldDo() throws {
        // The top fenced off all round R2's pad 2, inside the pad's own edge.
        let ring: [JSONDictionary] = [[5.25, -1, 5.37, 1], [6.13, -1, 6.25, 1], [5.25, 0.38, 6.25, 0.5], [5.25, -0.5, 6.25, -0.38]]
            .map { ["layer": 0, "box_mm": $0] }
        let request: JSONDictionary = ["from": ["component": fixture.flat(instance, "R2"), "pad": "2"], "to": [["x_mm": 5.75, "y_mm": -3]],
                                       "avoid": ring, "window_mm": 1, "layers": [0, -1], "via": "rules"]
        let blocked = try find(request)
        XCTAssertEqual(blocked["found"] as? Bool, false, "\(blocked)")
        XCTAssertGreaterThan(blocked.int("vias_kept_out_of_pads") ?? 0, 0, "\(blocked)")
        XCTAssertTrue((blocked.string("note") ?? "").contains("via_in_pad"), "\(blocked)")

        var asked = request
        asked["via_in_pad"] = true
        let through = try find(asked)
        XCTAssertEqual(through["found"] as? Bool, true, "\(through)")
        XCTAssertEqual((through["vias"] as? [JSONDictionary])?.count, 1)
    }

    /// A connection inside a block instance: the ops name its pads as any
    /// other part's, and committed as they are they bind the track to both
    /// and take the airwire off the instance's own net.
    func testAPathBetweenAnInstancesPadsCommitsAsItsOpsNameThem() throws {
        let found = try XCTUnwrap(try client.result("find_path", [
            "from": ["component": fixture.flat(instance, "R1"), "pad": "2"],
            "to": [["component": fixture.flat(instance, "R2"), "pad": "1"]], "width_mm": 0.2,
        ]) as? JSONDictionary)
        XCTAssertEqual(found["found"] as? Bool, true, "\(found)")
        XCTAssertEqual(found.string("net_name"), "I1/MID")
        let ops = try XCTUnwrap(found["ops"] as? [JSONDictionary])
        XCTAssertEqual(ops.first?.dictionary("from")?.string("component"), "R1")
        XCTAssertEqual(ops.last?.dictionary("to")?.string("component"), "R2")
        let commit = try XCTUnwrap(try client.result("apply", ["ops": ops, "sync": false]) as? JSONDictionary)
        XCTAssertEqual(commit.string("status"), "committed", "\(commit)")
        let tracks = try XCTUnwrap((try client.result("list_tracks", ["net": "I1/MID"]) as? JSONDictionary)?["tracks"] as? [JSONDictionary])
        XCTAssertEqual(tracks.first?.dictionary("from")?.string("kind"), "pad")
        XCTAssertEqual(tracks.last?.dictionary("to")?.string("kind"), "pad")
        // The net is asked about by name wherever the board's copper is:
        // a probe for a via on it finds the room beside the track.
        let sites = try XCTUnwrap(try client.result("find_via_sites", [
            "net": "I1/MID", "near": ["x_mm": 2.5, "y_mm": 1], "radius_mm": 0.5, "diameter_mm": 0.35, "grid_mm": 0.1,
        ]) as? JSONDictionary)
        XCTAssertGreaterThan(sites.int("total") ?? 0, 0)
    }

    /// autoroute takes a limit on how many airwires it tries, as a number,
    /// and routes an instance's net like any other.
    func testAutorouteTakesItsLimitAndAnInstancesNet() throws {
        let routed = try XCTUnwrap(try client.result("autoroute", ["net": "I1/MID", "max_routes": 1, "width_mm": 0.2, "sync": false]) as? JSONDictionary)
        XCTAssertEqual(routed.int("attempted"), 1, "\(routed)")
        XCTAssertEqual(routed.int("routed"), 1, "\(routed)")
        let refused = try client.call("autoroute", ["net": "I1/MID", "max_routes": "1", "width_mm": 0.2])
        XCTAssertTrue("\(refused["error"] ?? "")".contains("max_routes must be a finite integer"), "\(refused)")
    }

    /// Ends far apart are searched at the finest pitch that fits when the
    /// request states none, and the reply says which; a stated pitch that
    /// does not fit is refused with the one that does.
    func testADistantEndIsSearchedAtAPitchThatFits() throws {
        let far: JSONDictionary = ["from": ["x_mm": 0, "y_mm": 8], "to": [["x_mm": 60, "y_mm": 28]], "net": "OUT1", "layers": [0], "width_mm": 0.2]
        let found = try XCTUnwrap(try client.result("find_path", far) as? JSONDictionary)
        XCTAssertEqual(found["found"] as? Bool, true, "\(found)")
        XCTAssertEqual(found.double("grid_mm") ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertNotNil(found["grid_note"])
        var fine = far
        fine["grid_mm"] = 0.025
        let refused = try client.call("find_path", fine)
        XCTAssertTrue("\(refused["error"] ?? "")".contains("here 0.05"), "\(refused)")
        // Near ends are searched at 25 µm and say nothing of it.
        let near = try find(["grid_mm": NSNull()])
        XCTAssertNil(near["grid_note"])
    }

    /// An end on another net is refused before anything is searched.
    func testEndsOfTwoNetsAreRefused() throws {
        let reply = try client.call("find_path", ["from": ["junction": left], "to": [["component": "R1", "pad": "1"]], "width_mm": 0.2])
        XCTAssertNotNil(reply["error"], "\(reply)")
    }
}
