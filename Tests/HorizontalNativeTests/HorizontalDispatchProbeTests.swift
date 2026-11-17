import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// probe_clearance and find_via_sites: whether copper that is not there yet
/// would fit, on every layer it reaches, without building ops. The board is
/// one channel of `BlockLayoutFixture` on four copper layers: R1 at the
/// origin, R2 5 mm right of it, pads 0.8 × 0.9 mm at ±0.75 mm, and R3 moved
/// to the bottom at (10, 5).
final class HorizontalDispatchProbeTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var client: BlockLayoutDispatchClient!
    private var instance: String { fixture.instances[0] }

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 1, innerLayers: 2)
        try fixture.apply([["op": "place_component", "component": fixture.flat(instance, "R3"), "x_mm": 10, "y_mm": 5, "bottom": true]])
    }

    override func tearDown() {
        client?.close()
        fixture?.remove()
        super.tearDown()
    }

    private func open() throws {
        try fixture.saveToDisk()
        client = try BlockLayoutDispatchClient(path: fixture.url.path)
    }

    private func probe(_ candidates: [JSONDictionary], _ more: JSONDictionary = [:]) throws -> [JSONDictionary] {
        var params = more
        params["candidates"] = candidates
        let reply = try XCTUnwrap(try client.result("probe_clearance", params) as? JSONDictionary)
        return try XCTUnwrap(reply["candidates"] as? [JSONDictionary])
    }

    private func via(_ x: Double, _ y: Double, net: String = "IN1") -> JSONDictionary {
        ["via": ["x_mm": x, "y_mm": y, "net": net, "diameter_mm": 0.35, "hole_mm": 0.15] as JSONDictionary]
    }

    /// A through via that is clear on the top layer but stands over a pad of
    /// another net on the bottom is refused, and the pad is named.
    func testAViaIsTestedOnEveryLayerItReaches() throws {
        try open()
        let results = try probe([via(10.75, 5), via(10.75, 8)])
        XCTAssertEqual(results[0]["ok"] as? Bool, false)
        XCTAssertEqual(results[0]["layers"] as? [Int], [0, -1, -2, -100])
        let violations = try XCTUnwrap(results[0]["violations"] as? [JSONDictionary])
        XCTAssertEqual(violations.count, 1, "\(violations)")
        XCTAssertEqual(violations[0].int("layer"), -100)
        XCTAssertEqual(violations[0].dictionary("item")?.string("kind"), "pad")
        XCTAssertTrue(violations[0].dictionary("item")?.string("label")?.hasPrefix("Pad R3.") == true, "\(violations)")
        XCTAssertEqual(violations[0].double("distance_mm"), 0)
        XCTAssertEqual(violations[0].double("clearance_mm") ?? 0, 0.125, accuracy: 1e-9)
        XCTAssertEqual(results[1]["ok"] as? Bool, true, "\(results[1])")

        // find_via_sites round the same point: nothing fits in the pad, and
        // the reply says what is in the way; a wider look finds room beside it.
        let none = try XCTUnwrap(try client.result("find_via_sites", [
            "net": "IN1", "near": ["x_mm": 10.75, "y_mm": 5], "radius_mm": 0.2, "diameter_mm": 0.35, "grid_mm": 0.05]) as? JSONDictionary)
        XCTAssertEqual(none.int("total"), 0)
        let blockers = try XCTUnwrap(none.dictionary("nearest_miss")?["blocked_by"] as? [JSONDictionary], "\(none)")
        XCTAssertTrue(blockers.contains { $0.dictionary("item")?.string("label")?.hasPrefix("Pad R3.") == true && $0.int("layer") == -100 })

        let some = try XCTUnwrap(try client.result("find_via_sites", [
            "net": "IN1", "near": ["x_mm": 10.75, "y_mm": 5], "radius_mm": 1.5, "diameter_mm": 0.35, "grid_mm": 0.05, "limit": 5]) as? JSONDictionary)
        XCTAssertGreaterThan(some.int("total") ?? 0, 0)
        let sites = try XCTUnwrap(some["sites"] as? [JSONDictionary])
        XCTAssertEqual(sites.count, 5)
        XCTAssertEqual(some["truncated"] as? Bool, true)
        // The pad is 0.8 mm wide, so the nearest site is beside it:
        // 0.4 + 0.125 + 0.175 mm from its centre, which is on the grid.
        XCTAssertEqual(sites[0].double("distance_mm") ?? 0, 0.7, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(sites[0].double("slack_mm") ?? -1, 0)
        XCTAssertEqual((sites[0]["tightest"] as? [JSONDictionary])?.contains { $0.int("layer") == -100 }, true)
        let regions = try XCTUnwrap(some["regions"] as? [JSONDictionary])
        XCTAssertEqual(regions.reduce(0) { $0 + ($1.int("sites") ?? 0) }, some.int("total"))
        // The same question again has the same answer.
        let again = try XCTUnwrap(try client.result("find_via_sites", [
            "net": "IN1", "near": ["x_mm": 10.75, "y_mm": 5], "radius_mm": 1.5, "diameter_mm": 0.35, "grid_mm": 0.05, "limit": 5]) as? JSONDictionary)
        XCTAssertEqual(NSDictionary(dictionary: some), NSDictionary(dictionary: again))
    }

    /// A via in a pad of its own net is clear, and says whether it is joined
    /// to the pad: on the centre it is, off it a track has to.
    func testAViaInItsOwnPadSaysWhetherItNeedsALink() throws {
        try open()
        let results = try probe([via(-0.75, 0), via(-0.6, 0.1), via(-0.75, 0, net: "OUT1")])
        XCTAssertEqual(results[0]["ok"] as? Bool, true, "\(results[0])")
        XCTAssertEqual(results[0].dictionary("in_pad")?["on_center"] as? Bool, true)
        XCTAssertNil(results[0]["needs_link"])
        XCTAssertEqual(results[1]["ok"] as? Bool, true)
        XCTAssertEqual(results[1].dictionary("in_pad")?.string("pad"), "Pad R1.1")
        XCTAssertEqual(results[1]["needs_link"] as? Bool, true)
        XCTAssertEqual(results[2]["ok"] as? Bool, false, "another net's via in the pad")
    }

    /// A track candidate is measured along its whole length, margin_mm asks
    /// for more than the rules do, and ignore takes an item out of the way.
    func testATrackCandidateIsMeasuredWithTheMarginAndWithoutWhatIsIgnored() throws {
        let junction = "77777777-7777-4777-8777-777777777771"
        try fixture.addCopper(junctions: [junction: HorizontalPoint(x: 2_500_000, y: 2_000_000)],
                              vias: ["99999999-9999-4999-8999-999999999991": junction])
        try open()
        // The via, Ø0.5, reaches y = 2.25: a 0.2 mm track along y = 2.48 is
        // 0.13 mm from it, which 0.125 allows and a 0.01 margin does not.
        let track: JSONDictionary = ["track": ["layer": 0, "net": "IN1", "width_mm": 0.2, "points_mm": [[1, 2.48], [4, 2.48]]] as JSONDictionary]
        let plain = try probe([track])
        XCTAssertEqual(plain[0]["ok"] as? Bool, true, "\(plain[0])")
        let tightest = try XCTUnwrap((plain[0]["tightest"] as? [JSONDictionary])?.first)
        XCTAssertEqual(tightest.double("distance_mm") ?? 0, 0.13, accuracy: 1e-6)
        XCTAssertEqual(tightest.double("slack_mm") ?? 0, 0.005, accuracy: 1e-6)
        XCTAssertEqual(tightest.dictionary("item")?.string("id"), "99999999-9999-4999-8999-999999999991")
        XCTAssertEqual(plain[0].double("length_mm") ?? 0, 3, accuracy: 1e-9)

        let strict = try probe([track], ["margin_mm": 0.01])
        XCTAssertEqual(strict[0]["ok"] as? Bool, false)
        XCTAssertEqual((strict[0]["violations"] as? [JSONDictionary])?.first?.double("slack_mm") ?? 0, -0.005, accuracy: 1e-6)

        let ripped = try probe([track], ["margin_mm": 0.01, "ignore": ["99999999"]])
        XCTAssertEqual(ripped[0]["ok"] as? Bool, true, "\(ripped[0])")
        // A track on an inner layer passes under the top's pads but not the via.
        let inner: JSONDictionary = ["track": ["layer": -1, "net": "IN1", "width_mm": 0.2, "points_mm": [[4, -1], [4, 3]]] as JSONDictionary]
        let top: JSONDictionary = ["track": ["layer": 0, "net": "IN1", "width_mm": 0.2, "points_mm": [[4, -1], [4, 3]]] as JSONDictionary]
        let layered = try probe([inner, top])
        XCTAssertEqual(layered.map { $0["ok"] as? Bool }, [true, false], "\(layered)")
    }

    /// A part somewhere else: its pads where they would be, measured against
    /// the rest of the board, and the tracks on its pads stretched with it.
    func testAComponentCandidateMovesItsPadsAndStretchesItsTracks() throws {
        let corner = "11111111-1111-4111-8111-111111111111", end = "11111111-1111-4111-8111-111111111112"
        let stub = "11111111-1111-4111-8111-111111111113"
        try fixture.addCopper(
            junctions: [corner: HorizontalPoint(x: -750_000, y: 2_420_000), end: HorizontalPoint(x: 4_000_000, y: 2_420_000),
                        stub: HorizontalPoint(x: 5_750_000, y: -2_000_000)],
            tracks: ["22222222-2222-4222-8222-222222222221": (try fixture.padEnd(instance, "R1", 1), fixture.junctionEnd(corner), 0),
                     "22222222-2222-4222-8222-222222222222": (fixture.junctionEnd(corner), fixture.junctionEnd(end), 0),
                     "22222222-2222-4222-8222-222222222223": (try fixture.padEnd(instance, "R2", 2), fixture.junctionEnd(stub), 0)])
        try open()
        func move(_ y: Double) -> JSONDictionary {
            ["component": ["refdes": "R2", "x_mm": 2.5, "y_mm": y] as JSONDictionary]
        }
        // At y = 1.8 its pads' top edge, 2.25, is 0.07 mm from the track.
        let results = try probe([move(1.8), move(1.7)])
        XCTAssertEqual(results[0]["ok"] as? Bool, false)
        let violations = try XCTUnwrap(results[0]["violations"] as? [JSONDictionary])
        XCTAssertEqual(Set(violations.compactMap { $0.string("of") }), ["Pad R2.1", "Pad R2.2"], "\(violations)")
        for violation in violations {
            XCTAssertEqual(violation.double("distance_mm") ?? 0, 0.07, accuracy: 1e-6)
            XCTAssertEqual(violation.dictionary("item")?.string("id"), "22222222-2222-4222-8222-222222222222")
        }
        XCTAssertEqual(results[1]["ok"] as? Bool, true, "\(results[1])")
        let stretched = try XCTUnwrap(results[1]["stretched"] as? [JSONDictionary])
        XCTAssertEqual(stretched.count, 1)
        XCTAssertEqual(stretched[0].string("track"), "22222222-2222-4222-8222-222222222223")
        XCTAssertEqual(stretched[0]["pads"] as? [String], ["R2.2"])
        XCTAssertEqual(stretched[0].dictionary("from_mm")?.double("x_mm") ?? 0, 3.25, accuracy: 1e-9)
        XCTAssertEqual(stretched[0].dictionary("from_mm")?.double("y_mm") ?? 0, 1.7, accuracy: 1e-9)
        // Turned a quarter turn where it is, its pads are one above the
        // other, and the track from pad 2, now on top, to the stub below
        // runs through pad 1.
        let turned = try probe([["component": ["refdes": "R2", "x_mm": 5, "y_mm": 0, "angle_deg": 90] as JSONDictionary]])
        XCTAssertEqual(turned[0].double("angle_deg"), 90)
        XCTAssertEqual(turned[0]["ok"] as? Bool, false)
        let crossed = try XCTUnwrap(turned[0]["violations"] as? [JSONDictionary])
        XCTAssertEqual(crossed.count, 1, "\(crossed)")
        XCTAssertEqual(crossed[0].string("of"), "Track 22222222 on R2.2")
        XCTAssertEqual(crossed[0].dictionary("item")?.string("label"), "Pad R2.1")
        // Nothing moved: probing changes nothing.
        let pads = try XCTUnwrap(try client.result("list_pads", ["component": "R2", "pads": ["1"]]) as? JSONDictionary)
        XCTAssertEqual((pads["pads"] as? [JSONDictionary])?.first?.dictionary("at_mm")?.double("x_mm") ?? 0, 4.25, accuracy: 1e-9)
    }

    /// link keeps only the via sites a track can join to an anchor.
    func testViaSitesCanBeKeptToThoseATrackCanJoin() throws {
        let anchor = "33333333-3333-4333-8333-333333333331"
        try fixture.addCopper(junctions: [anchor: HorizontalPoint(x: -750_000, y: 3_000_000)],
                              tracks: ["44444444-4444-4444-8444-444444444441": (try fixture.padEnd(instance, "R1", 1), fixture.junctionEnd(anchor), 0)])
        try open()
        let request: JSONDictionary = ["net": "IN1", "near": ["x_mm": 2.5, "y_mm": 3], "radius_mm": 0.5, "diameter_mm": 0.35, "grid_mm": 0.1]
        let open = try XCTUnwrap(try client.result("find_via_sites", request) as? JSONDictionary)
        var straight = request
        straight["link"] = ["layer": 0, "to": ["junction": anchor], "width_mm": 0.2, "bends": 0] as JSONDictionary
        let linked = try XCTUnwrap(try client.result("find_via_sites", straight) as? JSONDictionary)
        XCTAssertGreaterThan(open.int("total") ?? 0, linked.int("total") ?? 0)
        let sites = try XCTUnwrap(linked["sites"] as? [JSONDictionary])
        // A straight link to (−0.75, 3) from round (2.5, 3) runs along y = 3.
        XCTAssertFalse(sites.isEmpty)
        XCTAssertTrue(sites.allSatisfy { abs(($0.double("y_mm") ?? 0) - 3) < 1e-9 }, "\(sites)")
        XCTAssertEqual((sites[0]["link_mm"] as? [[Double]])?.last, [-0.75, 3])
        var bent = request
        bent["link"] = ["layer": 0, "to": ["junction": anchor], "width_mm": 0.2] as JSONDictionary
        XCTAssertEqual((try client.result("find_via_sites", bent) as? JSONDictionary)?.int("total"), open.int("total"))
    }
}
