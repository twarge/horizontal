import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// channel_capacity, escape_analysis, find_stubs and render_board's
/// annotations through MCP. The board is one channel of
/// `BlockLayoutFixture`: R1 at the origin, R2 5 mm right of it and R3 10 mm,
/// pads 0.8 × 0.9 mm at ±0.75 mm; OUT1 is R2's pad 2 and R3's, each with a
/// stub to a junction, the two not joined.
final class HorizontalDispatchChannelsTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var client: BlockLayoutDispatchClient!
    private var instance: String { fixture.instances[0] }
    private let left = "33333333-3333-4333-8333-333333333331", right = "33333333-3333-4333-8333-333333333332"
    private let loose = "33333333-3333-4333-8333-333333333333", inPad = "33333333-3333-4333-8333-333333333334"

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 1)
        try fixture.addCopper(
            junctions: [left: HorizontalPoint(x: 5_750_000, y: 1_000_000), right: HorizontalPoint(x: 10_750_000, y: -1_000_000),
                        loose: HorizontalPoint(x: 10_750_000, y: -3_000_000), inPad: HorizontalPoint(x: -600_000, y: 100_000)],
            tracks: ["44444444-4444-4444-8444-444444444441": (try fixture.padEnd(instance, "R2", 2), fixture.junctionEnd(left), 0),
                     "44444444-4444-4444-8444-444444444442": (try fixture.padEnd(instance, "R3", 2), fixture.junctionEnd(right), 0),
                     // On from the second stub's end to nowhere.
                     "44444444-4444-4444-8444-444444444443": (fixture.junctionEnd(right), fixture.junctionEnd(loose), 0),
                     // From R1's pad 1 to a point still inside it.
                     "44444444-4444-4444-8444-444444444444": (try fixture.padEnd(instance, "R1", 1), fixture.junctionEnd(inPad), 0)],
            vias: ["99999999-9999-4999-8999-999999999991": loose])
        try fixture.saveToDisk()
        client = try BlockLayoutDispatchClient(path: fixture.url.path)
    }

    override func tearDown() {
        client?.close()
        fixture?.remove()
        super.tearDown()
    }

    /// Between R1's pad 2 and R2's pad 1, 2.7 mm apart, a 0.2 mm track's
    /// centre has 2.7 − 2 × 0.225 = 2.25 mm, which is seven tracks at a
    /// pitch of 0.325; on the bottom nothing is in the way.
    func testChannelCapacityBetweenTwoPads() throws {
        let r1 = try XCTUnwrap((try client.result("list_pads", ["component": "R1", "pads": ["2"]]) as? JSONDictionary)
            .flatMap { ($0["pads"] as? [JSONDictionary])?.first?.string("id") })
        let r2 = try XCTUnwrap((try client.result("list_pads", ["component": "R2", "pads": ["1"]]) as? JSONDictionary)
            .flatMap { ($0["pads"] as? [JSONDictionary])?.first?.string("id") })
        let between = try XCTUnwrap(try client.result("channel_capacity", ["between": [r1, r2], "width_mm": 0.2]) as? JSONDictionary)
        let layers = try XCTUnwrap(between["layers"] as? [JSONDictionary])
        XCTAssertEqual(layers.map { $0.int("layer") }, [0])
        XCTAssertEqual(layers[0].int("tracks"), 7, "\(between)")
        let gap = try XCTUnwrap((layers[0]["gaps"] as? [JSONDictionary])?.first)
        XCTAssertEqual(gap.double("centres_mm") ?? 0, 2.25, accuracy: 1e-3)
        XCTAssertEqual((gap["bounded_by"] as? [JSONDictionary])?.map { $0.string("label") ?? "" }, ["Pad R1.2", "Pad R2.1"])

        let cut: JSONDictionary = ["from_mm": [0.75, 0], "to_mm": [4.25, 0]]
        let both = try XCTUnwrap(try client.result("channel_capacity", ["cut": cut, "width_mm": 0.2, "margin_mm": 0.05]) as? JSONDictionary)
        let byLayer = try XCTUnwrap(both["layers"] as? [JSONDictionary])
        XCTAssertEqual(byLayer.map { $0.int("layer") }, [0, -100])
        // 2.7 − 2 × 0.275 = 2.15 at a pitch of 0.375: six.
        XCTAssertEqual(byLayer[0].int("tracks"), 6)
        XCTAssertGreaterThan(byLayer[1].int("tracks") ?? 0, 8)
    }

    /// OUT1 leaves R2's pad field through a gate it reaches, and has a path
    /// to its target on the layer its pad is on.
    func testEscapeAnalysisOfAPartsNet() throws {
        let reply = try XCTUnwrap(try client.result("escape_analysis", [
            "component": "R2", "nets": ["OUT1"], "targets": ["OUT1": ["junction": right]], "width_mm": 0.2, "grid_mm": 0.1,
            "layers": [0]]) as? JSONDictionary)
        XCTAssertEqual(reply["feasible"] as? Bool, true, "\(reply)")
        let gates = try XCTUnwrap(reply["gates"] as? [JSONDictionary])
        XCTAssertFalse(gates.isEmpty)
        XCTAssertTrue(gates.allSatisfy { ($0.int("capacity") ?? 0) >= 1 && $0.int("layer") == 0 })
        let reach = try XCTUnwrap((reply["reach"] as? [JSONDictionary])?.first)
        XCTAssertEqual(reach.string("net"), "OUT1")
        XCTAssertEqual(reach.string("from"), "R2.2")
        XCTAssertEqual(reach["trapped"] as? Bool, false)
        XCTAssertEqual(reply.dictionary("paths_alone")?["OUT1"] as? [Int], [0])
        XCTAssertEqual((reply["cannot_share"] as? [JSONDictionary])?.count, 0)
        XCTAssertNotNil(reply.dictionary("assignment")?["OUT1"])
        // The bottom is not a layer its pad is on, and nothing takes it there.
        let bottom = try XCTUnwrap(try client.result("escape_analysis", [
            "component": "R2", "nets": ["OUT1"], "width_mm": 0.2, "grid_mm": 0.1, "layers": [-100]]) as? JSONDictionary)
        XCTAssertEqual(bottom["feasible"] as? Bool, false)
        XCTAssertEqual(((bottom["reach"] as? [JSONDictionary])?.first)?["trapped"] as? Bool, true)
    }

    /// The run past R3's stub to a via nothing else meets is a stub whose
    /// far end is on a junction of two tracks; the via joins one layer; and
    /// the track inside R1's pad is listed with its pad.
    func testFindStubsSaysWhatEachEndTouches() throws {
        let reply = try XCTUnwrap(try client.result("find_stubs") as? JSONDictionary)
        let stubs = try XCTUnwrap(reply["stubs"] as? [JSONDictionary])
        // The first stub, on R2's pad, ends on a bare junction.
        let open = try XCTUnwrap(stubs.first { ($0["tracks"] as? [String]) == ["44444444-4444-4444-8444-444444444441"] }, "\(stubs)")
        XCTAssertEqual(open["dead_end"] as? Bool, true)
        XCTAssertEqual(open.double("length_mm") ?? 0, 1, accuracy: 1e-9)
        let ends = try XCTUnwrap(open["ends"] as? [JSONDictionary])
        XCTAssertEqual(ends[0].string("touches"), "nothing")
        XCTAssertEqual(ends[1].string("touches"), "pad")
        XCTAssertEqual(ends[1].string("pad"), "R2.2")
        // The run to the via ends on it, so it is no stub; the via is what
        // goes nowhere.
        XCTAssertFalse(stubs.contains { ($0["tracks"] as? [String])?.contains("44444444-4444-4444-8444-444444444443") == true })
        let vias = try XCTUnwrap(reply["vias_on_one_layer"] as? [JSONDictionary])
        XCTAssertEqual(vias.map { $0.string("via") ?? "" }, ["99999999-9999-4999-8999-999999999991"])
        XCTAssertEqual(vias[0]["joined_on"] as? [Int], [0])
        // The track in the pad: its free end lies in the pad's copper.
        let inside = try XCTUnwrap(reply["tracks_in_a_pad"] as? [JSONDictionary])
        XCTAssertEqual(inside.map { $0.string("pad") ?? "" }, ["Pad R1.1"])
        let live = try XCTUnwrap(stubs.first { ($0["tracks"] as? [String]) == ["44444444-4444-4444-8444-444444444444"] })
        XCTAssertEqual(live["dead_end"] as? Bool, false)
        XCTAssertEqual(((live["ends"] as? [JSONDictionary])?.first)?["lies_in"] as? [String], ["Pad R1.1"])
        // Narrowed to a net.
        let other = try XCTUnwrap(try client.result("find_stubs", ["net": "IN1"]) as? JSONDictionary)
        XCTAssertEqual(other.int("stub_count"), 1)
        XCTAssertEqual(other.int("via_count"), 0)
    }

    /// A render takes a grid, items to pick out and shapes to draw over it,
    /// and they change the picture; a truncated list says so in words.
    func testARenderTakesAGridHighlightsAndAnOverlay() throws {
        func png(_ more: JSONDictionary) throws -> Data {
            var params: JSONDictionary = ["dpi": 100, "region": ["min_x_mm": -2, "min_y_mm": -4, "max_x_mm": 12, "max_y_mm": 3]]
            params.merge(more) { _, new in new }
            let reply = try XCTUnwrap(try client.result("render_board", params) as? JSONDictionary)
            return try XCTUnwrap(reply.string("png_base64").flatMap { Data(base64Encoded: $0) })
        }
        let plain = try png([:])
        XCTAssertNotEqual(try png(["grid_mm": 1]), plain)
        XCTAssertNotEqual(try png(["highlight": ["44444444-4444-4444-8444-444444444443"]]), plain)
        XCTAssertNotEqual(try png(["overlay": [["via": ["x_mm": 2, "y_mm": 1, "diameter_mm": 0.6]],
                                               ["track": ["points_mm": [[2, 1], [4, 1]], "width_mm": 0.2]]]]), plain)
        XCTAssertNotNil(try client.call("render_board", ["highlight": ["no-such-id"]])["error"])

        let cut = try XCTUnwrap(try client.result("list_tracks", ["limit": 2]) as? JSONDictionary)
        XCTAssertEqual(cut["truncated"] as? Bool, true)
        XCTAssertTrue(cut.string("note")?.hasPrefix("TRUNCATED: these are the first 2 of 4 tracks") == true, "\(cut)")
        XCTAssertNil((try client.result("list_tracks") as? JSONDictionary)?["note"])
    }
}
