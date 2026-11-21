import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A dry run's `check`: what a plan does to the board's findings, airwires
/// and the tracks bound to a part it moves, before anything is committed.
/// The board is one channel of `BlockLayoutFixture`: R1 at the origin, R2
/// 5 mm right of it and R3 10 mm, pads 0.8 × 0.9 mm at ±0.75 mm.
final class HorizontalDispatchPlanCheckTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var client: BlockLayoutDispatchClient!
    private var instance: String { fixture.instances[0] }

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 1)
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

    private func dryRun(_ ops: [JSONDictionary], check: String = "delta", pour: Bool? = nil) throws -> JSONDictionary {
        var params: JSONDictionary = ["ops": ops, "dry_run": true, "check": check]
        if let pour { params["pour"] = pour }
        let result = try XCTUnwrap(try client.result("apply", params) as? JSONDictionary)
        return try XCTUnwrap(result.dictionary("check"), "\(result)")
    }

    private func component(_ refdes: String) -> String { fixture.flat(instance, refdes) }

    /// A part moved to 0.07 mm from a track is an introduced finding for each
    /// of its pads, naming the op that moved it; once committed, the plan
    /// that moves it away resolves both and says how far apart they are then.
    func testAPlanSaysWhatItIntroducesAndWhatItResolves() throws {
        // A track of IN1 from R1's pad 1 up to y = 2.42 and along it: its
        // lower edge is at 2.32.
        let corner = "11111111-1111-4111-8111-111111111111", end = "11111111-1111-4111-8111-111111111112"
        try fixture.addCopper(
            junctions: [corner: HorizontalPoint(x: -750_000, y: 2_420_000), end: HorizontalPoint(x: 4_000_000, y: 2_420_000)],
            tracks: ["22222222-2222-4222-8222-222222222221": (try fixture.padEnd(instance, "R1", 1), fixture.junctionEnd(corner), 0),
                     "22222222-2222-4222-8222-222222222222": (fixture.junctionEnd(corner), fixture.junctionEnd(end), 0)])
        try open()
        // R2's pads are 0.9 mm tall: at y = 1.8 their top edge is at 2.25.
        let near: JSONDictionary = ["op": "place_component", "component": component("R2"), "x_mm": 2.5, "y_mm": 1.8]
        let check = try dryRun([near])
        let introduced = try XCTUnwrap(check["introduced"] as? [JSONDictionary]).filter { $0.string("check") == "copper" }
        XCTAssertEqual(Set(introduced.compactMap { $0.dictionary("second")?.string("label") }), ["Pad R2.1", "Pad R2.2"], "\(check)")
        for finding in introduced {
            XCTAssertEqual(finding.double("distance_mm") ?? 0, 0.07, accuracy: 1e-4)
            XCTAssertEqual(finding.double("clearance_mm") ?? 0, 0.125, accuracy: 1e-9)
            XCTAssertEqual(finding["from_ops"] as? [Int], [0])
            XCTAssertEqual(finding.dictionary("first")?.string("id"), "22222222-2222-4222-8222-222222222222")
        }
        XCTAssertEqual(check["ok"] as? Bool, false)
        XCTAssertEqual((check["resolved"] as? [JSONDictionary])?.count, 0, "\(check)")
        XCTAssertEqual(check.string("planes"), "none")

        // A dry run changes nothing: the check method still finds no such pair.
        let now = try XCTUnwrap(try client.result("check", ["full": true]) as? JSONDictionary)
        XCTAssertFalse((now["messages"] as? [JSONDictionary] ?? []).contains { $0.string("check") == "copper" })

        _ = try client.result("apply", ["ops": [near]])
        let away = try dryRun([["op": "place_component", "component": component("R2"), "x_mm": 2.5, "y_mm": 1.7]])
        let resolved = try XCTUnwrap(away["resolved"] as? [JSONDictionary]).filter { $0.string("check") == "copper" }
        XCTAssertEqual(resolved.count, 2, "\(away)")
        for finding in resolved {
            XCTAssertEqual(finding.double("now_distance_mm") ?? 0, 0.17, accuracy: 1e-4)
        }
        XCTAssertEqual((away["introduced"] as? [JSONDictionary])?.count, 0, "\(away)")
        XCTAssertEqual(away["ok"] as? Bool, true)
    }

    /// A part moved 0.2 mm takes the three track ends on its pad with it, and
    /// the plan lists each: the track, the pad, where the end was and is.
    func testAMovedPartsTracksAreListedAsStretched() throws {
        let junctions = ["aaaaaaa1-0000-4000-8000-000000000001": HorizontalPoint(x: 750_000, y: 2_000_000),
                         "aaaaaaa1-0000-4000-8000-000000000002": HorizontalPoint(x: 1_750_000, y: 2_000_000),
                         "aaaaaaa1-0000-4000-8000-000000000003": HorizontalPoint(x: 750_000, y: -2_000_000)]
        var tracks = [String: (from: JSONDictionary, to: JSONDictionary, layer: Int)]()
        for (index, junction) in junctions.keys.sorted().enumerated() {
            tracks["bbbbbbb1-0000-4000-8000-00000000000\(index + 1)"] = (try fixture.padEnd(instance, "R1", 2), fixture.junctionEnd(junction), 0)
        }
        try fixture.addCopper(junctions: junctions, tracks: tracks)
        try open()
        let check = try dryRun([["op": "place_component", "component": component("R1"), "x_mm": 0.2, "y_mm": 0]])
        let stretched = try XCTUnwrap(check["stretched"] as? [JSONDictionary])
        XCTAssertEqual(stretched.map { $0.string("track") ?? "" }, tracks.keys.sorted())
        for row in stretched {
            XCTAssertEqual(row.string("end"), "from")
            XCTAssertEqual(row.string("pad"), "R1.2")
            XCTAssertEqual(row.dictionary("was_mm")?.double("x_mm") ?? 0, 0.75, accuracy: 1e-9)
            XCTAssertEqual(row.dictionary("now_mm")?.double("x_mm") ?? 0, 0.95, accuracy: 1e-9)
            XCTAssertEqual(row.dictionary("now_mm")?.double("y_mm") ?? 1, 0, accuracy: 1e-9)
        }
        // A plan that moves nothing stretches nothing.
        let still = try dryRun([["op": "place_component", "component": component("R3"), "x_mm": 10, "y_mm": 1]])
        XCTAssertEqual((still["stretched"] as? [JSONDictionary])?.count, 0)
    }

    /// A track that joins two stubs of a net takes an airwire off it, and
    /// the plan counts the airwires before and after and names the net.
    func testAPlanCountsAirwiresBeforeAndAfter() throws {
        // OUT1 is R2's pad 2 and R3's: a stub up from each, not yet joined.
        let left = "33333333-3333-4333-8333-333333333331", right = "33333333-3333-4333-8333-333333333332"
        try fixture.addCopper(
            junctions: [left: HorizontalPoint(x: 5_750_000, y: 1_500_000), right: HorizontalPoint(x: 10_750_000, y: 1_500_000)],
            tracks: ["44444444-4444-4444-8444-444444444441": (try fixture.padEnd(instance, "R2", 2), fixture.junctionEnd(left), 0),
                     "44444444-4444-4444-8444-444444444442": (try fixture.padEnd(instance, "R3", 2), fixture.junctionEnd(right), 0)])
        try open()
        let check = try dryRun([["op": "place_track", "from": ["junction": left], "to": ["junction": right], "layer": 0, "width_mm": 0.2]])
        let airwires = try XCTUnwrap(check.dictionary("airwires"))
        let before = try XCTUnwrap(airwires.int("before")), after = try XCTUnwrap(airwires.int("after"))
        XCTAssertEqual(after, before - 1, "\(check)")
        XCTAssertEqual(airwires["nets_routed"] as? [String], ["OUT1"])
        XCTAssertEqual(airwires["nets"] as? [String], [])
        XCTAssertEqual(check["ok"] as? Bool, true, "\(check)")
    }

    /// A via on a pad's centre is joined to the pad. One that overlaps the
    /// pad off its centre is not until a track joins them: it is an airwire.
    func testAViaOffAPadsCentreIsAnAirwireUntilATrackJoinsIt() throws {
        // A stub from R1's pad 1, at (−0.75, 0), to a junction still in the pad.
        let stub = "55555555-5555-4555-8555-555555555551"
        try fixture.addCopper(junctions: [stub: HorizontalPoint(x: -550_000, y: 200_000)],
                              tracks: ["66666666-6666-4666-8666-666666666661": (try fixture.padEnd(instance, "R1", 1), fixture.junctionEnd(stub), 0)])
        try open()
        func via(_ x: Double, _ y: Double) -> JSONDictionary {
            ["op": "place_via", "x_mm": x, "y_mm": y, "net": "IN1", "diameter_mm": 0.3, "hole_mm": 0.15]
        }
        let centred = try XCTUnwrap(try dryRun([via(-0.75, 0)]).dictionary("airwires"))
        XCTAssertEqual(centred.int("after"), centred.int("before"), "\(centred)")
        let off = try XCTUnwrap(try dryRun([via(-0.95, -0.2)]).dictionary("airwires"))
        XCTAssertEqual(off.int("after"), (off.int("before") ?? 0) + 1, "\(off)")
        XCTAssertEqual(off["nets"] as? [String], ["IN1"])
        let joined = try XCTUnwrap(try dryRun([via(-0.55, 0.2)]).dictionary("airwires"))
        XCTAssertEqual(joined.int("after"), joined.int("before"), "\(joined)")
    }

    /// A track drawn through another net's pour is copper against the fill
    /// only until the planes are poured again. On fills as last poured the
    /// plan sets that finding aside and is ok; poured, there is none, and
    /// what is left is the track's own end on nothing, which lay in the fill
    /// till then.
    func testATrackThroughAStaleFillIsSetAsideAndNotIntroduced() throws {
        try open()
        // A pour of IN1 round the parts, reaching R1's pad 1 (a fill that
        // reaches no pad of its net is dropped), and OUT1's track from R2's
        // pad 2 up through it.
        func box(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> [JSONDictionary] {
            [[minX, minY], [maxX, minY], [maxX, maxY], [minX, maxY]].map { ["x_mm": $0[0], "y_mm": $0[1]] }
        }
        _ = try client.result("apply", ["ops": [["op": "place_polygon", "layer": 100, "vertices": box(-5, -5, 15, 10)],
                                                ["op": "place_plane", "net": "IN1", "layer": 0, "vertices": box(-3, -2, 12, 6)]]])
        _ = try client.result("pour_planes")
        let planes = try XCTUnwrap(try client.result("list_planes") as? [JSONDictionary])
        XCTAssertEqual(planes.first?["poured"] as? Bool, true, "\(planes)")
        let track: JSONDictionary = ["op": "place_track", "from": ["component": component("R2"), "pad": "2"],
                                     "to": ["x_mm": 5.75, "y_mm": 4.5], "layer": 0, "width_mm": 0.2]

        let stale = try dryRun([track])
        XCTAssertEqual(stale.string("planes"), "stale")
        XCTAssertGreaterThanOrEqual(stale.dictionary("set_aside")?.int("stale_fills") ?? 0, 1, "\(stale)")
        let listed = try XCTUnwrap(stale["introduced"] as? [JSONDictionary])
        XCTAssertFalse(listed.contains { $0.dictionary("first")?.string("type") == "plane" || $0.dictionary("second")?.string("type") == "plane" },
                       "\(listed)")
        XCTAssertEqual(listed.count, 0, "\(listed)")
        XCTAssertEqual(stale["ok"] as? Bool, true, "\(stale)")
        XCTAssertTrue((stale.string("note") ?? "").contains("stale_fills"))

        // Poured on both boards, the fill has given way: nothing to set
        // aside, and nothing against a plane. The track stops short of
        // anything, which is all the plan brings.
        let poured = try dryRun([track], pour: true)
        XCTAssertEqual(poured.string("planes"), "repoured")
        XCTAssertNil(poured["set_aside"], "\(poured)")
        XCTAssertEqual((poured["introduced"] as? [JSONDictionary])?.map { $0.string("check") ?? "" }, ["track_stub"], "\(poured)")
    }

    /// A track a plan draws from a pad to a bare point is introduced as a
    /// track that ends on nothing, a warning from the op that drew it;
    /// check_ignore sets it aside for a pass that leaves the route to be
    /// finished by the next.
    func testATrackToNowhereIsIntroducedAsAStubUnlessIgnored() throws {
        try open()
        let track: JSONDictionary = ["op": "place_track", "from": ["component": component("R2"), "pad": "2"],
                                     "to": ["x_mm": 5.75, "y_mm": 4.5], "layer": 0, "width_mm": 0.2]
        let check = try dryRun([track])
        let introduced = try XCTUnwrap(check["introduced"] as? [JSONDictionary])
        XCTAssertEqual(introduced.map { $0.string("check") ?? "" }, ["track_stub"], "\(check)")
        XCTAssertEqual(introduced.first?.string("level"), "warning")
        XCTAssertEqual(introduced.first?.string("category"), "copper")
        XCTAssertEqual(introduced.first?["from_ops"] as? [Int], [0])
        XCTAssertEqual(check.dictionary("introduced_kinds")?.int("track_stub"), 1)
        XCTAssertEqual(check["ok"] as? Bool, false)

        let reply = try client.call("apply", ["ops": [track], "dry_run": true, "check": "delta", "check_ignore": ["track_stub"]])
        let ignored = try XCTUnwrap((reply["result"] as? JSONDictionary)?.dictionary("check"), "\(reply)")
        XCTAssertEqual(ignored.dictionary("set_aside")?.int("track_stub"), 1, "\(ignored)")
        XCTAssertEqual((ignored["introduced"] as? [JSONDictionary])?.count, 0)
        XCTAssertEqual(ignored["ok"] as? Bool, true)

        // Run on to the other pad of its net, it is no stub.
        let landed: JSONDictionary = ["op": "place_track", "from": ["x_mm": 5.75, "y_mm": 4.5],
                                      "to": ["component": component("R3"), "pad": "2"], "layer": 0, "width_mm": 0.2]
        let whole = try dryRun([track, landed])
        XCTAssertFalse((whole["introduced"] as? [JSONDictionary] ?? []).contains { $0.string("check") == "track_stub" }, "\(whole)")
    }

    /// check_ignore leaves a kind of finding out of introduced and ok and
    /// counts it in set_aside; introduced_kinds counts what is listed.
    func testCheckIgnoreLeavesAKindOutAndCountsIt() throws {
        let corner = "11111111-1111-4111-8111-111111111111", end = "11111111-1111-4111-8111-111111111112"
        try fixture.addCopper(
            junctions: [corner: HorizontalPoint(x: -750_000, y: 2_420_000), end: HorizontalPoint(x: 4_000_000, y: 2_420_000)],
            tracks: ["22222222-2222-4222-8222-222222222221": (try fixture.padEnd(instance, "R1", 1), fixture.junctionEnd(corner), 0),
                     "22222222-2222-4222-8222-222222222222": (fixture.junctionEnd(corner), fixture.junctionEnd(end), 0)])
        try open()
        // R2 moved to 0.07 mm from the track: a clearance_copper finding a pad.
        let near: JSONDictionary = ["op": "place_component", "component": component("R2"), "x_mm": 2.5, "y_mm": 1.8]
        let plain = try dryRun([near])
        XCTAssertEqual(plain.dictionary("introduced_kinds")?.int("clearance_copper"), 2, "\(plain)")
        XCTAssertNil(plain["set_aside"])
        XCTAssertEqual(plain["ok"] as? Bool, false)

        func ignoring(_ kinds: [String]) throws -> JSONDictionary {
            try client.call("apply", ["ops": [near], "dry_run": true, "check": "delta", "check_ignore": kinds])
        }
        let ignored = try XCTUnwrap((try ignoring(["clearance_copper"])["result"] as? JSONDictionary)?.dictionary("check"))
        XCTAssertEqual(ignored.dictionary("set_aside")?.int("clearance_copper"), 2, "\(ignored)")
        XCTAssertFalse((ignored["introduced"] as? [JSONDictionary] ?? []).contains { $0.string("check") == "copper" })
        XCTAssertNil(ignored.dictionary("introduced_kinds")?["clearance_copper"])
        XCTAssertEqual(ignored["ok"] as? Bool, true, "\(ignored)")

        // "silkscreen" is the short name of its rule; anything else that is
        // no kind is refused, as is check_ignore without a check.
        let silkscreen = try XCTUnwrap((try ignoring(["silkscreen"])["result"] as? JSONDictionary)?.dictionary("check"))
        XCTAssertEqual(silkscreen.dictionary("introduced_kinds")?.int("clearance_copper"), 2, "\(silkscreen)")
        XCTAssertNotNil(try ignoring(["labels"])["error"])
        XCTAssertNotNil(try client.call("apply", ["ops": [near], "dry_run": true, "check_ignore": ["silkscreen"]])["error"])
    }

    /// check goes with a dry run, and is no part of the plan: the commit
    /// that names the dry run's digest installs it.
    func testCheckIsForDryRunsAndLeavesThePlanAsItWas() throws {
        try open()
        let move: JSONDictionary = ["op": "place_component", "component": component("R3"), "x_mm": 10, "y_mm": 1]
        let refused = try client.call("apply", ["ops": [move], "check": "delta"])
        XCTAssertNotNil(refused["error"], "\(refused)")
        let dry = try XCTUnwrap(try client.result("apply", ["ops": [move], "dry_run": true, "check": "full"]) as? JSONDictionary)
        XCTAssertNotNil(dry.dictionary("check")?["findings"])
        XCTAssertNotNil(dry.dictionary("timing")?["check_ms"])
        let digest = try XCTUnwrap(dry.string("plan_digest"))
        let committed = try XCTUnwrap(try client.result("apply", ["ops": [move], "plan_digest": digest]) as? JSONDictionary)
        XCTAssertEqual(committed.dictionary("timing")?["reused_dry_run"] as? Bool, true, "\(committed)")
    }
}
