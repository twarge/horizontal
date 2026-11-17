import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The board's geometry as MCP reads give it: pads where the board draws
/// them, what is near a point, and the box a text fills. The board is one
/// channel of `BlockLayoutFixture`: R1 at the origin, R2 5 mm right of it and
/// R3 10 mm, pads 0.8 × 0.9 mm with pad 1 at −0.75 mm, and each package's
/// refdes on the silkscreen.
final class HorizontalDispatchBoardGeometryTests: XCTestCase {
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

    private func pads(_ params: JSONDictionary) throws -> [JSONDictionary] {
        let reply = try XCTUnwrap(try client.result("list_pads", params) as? JSONDictionary)
        return try XCTUnwrap(reply["pads"] as? [JSONDictionary])
    }

    private func at(_ pad: JSONDictionary) throws -> (x: Double, y: Double) {
        let at = try XCTUnwrap(pad.dictionary("at_mm"), "\(pad)")
        return (try XCTUnwrap(at.double("x_mm")), try XCTUnwrap(at.double("y_mm")))
    }

    /// A pad is where the board draws it, its size the padstack's, its net
    /// the net of its pin.
    func testListPadsGivesEachPadsPlaceSizeAndNet() throws {
        try open()
        let listed = try pads(["component": fixture.flat(instance, "R1")])
        XCTAssertEqual(listed.map { $0.string("pad") ?? "" }, ["1", "2"])
        let first = try XCTUnwrap(listed.first)
        XCTAssertEqual(try at(first).x, -0.75, accuracy: 1e-9)
        XCTAssertEqual(try at(first).y, 0, accuracy: 1e-9)
        XCTAssertEqual(first.string("refdes"), "R1")
        XCTAssertEqual(first.string("net_name"), "IN1")
        XCTAssertEqual(first.string("side"), "top")
        XCTAssertEqual(first["layers"] as? [Int], [0])
        XCTAssertEqual(first.dictionary("shape")?.double("width_mm") ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(first.dictionary("shape")?.double("height_mm") ?? 0, 0.9, accuracy: 1e-9)
        let box = try XCTUnwrap(first.dictionary("box_mm"))
        XCTAssertEqual(box.double("min_x_mm") ?? 0, -1.15, accuracy: 1e-9)
        XCTAssertEqual(box.double("max_y_mm") ?? 0, 0.45, accuracy: 1e-9)
        XCTAssertNil(first["copper"], "outlines only on request")
        // By refdes too, and get_component carries the same rows.
        XCTAssertEqual(try pads(["component": "R1", "pads": ["2"]]).count, 1)
        let outlined = try pads(["component": "R1", "pads": ["1"], "outline": true])
        XCTAssertEqual(((outlined.first?["copper"] as? [JSONDictionary])?.first?["outline_mm"] as? [[Double]])?.count, 4)
        // Narrowed by net, by layer and by where.
        XCTAssertEqual(try pads(["net": "OUT1"]).map { "\($0.string("refdes") ?? "").\($0.string("pad") ?? "")" }, ["R2.2", "R3.2"])
        XCTAssertEqual(try pads(["layer": -100]).count, 0)
        XCTAssertEqual(try pads(["region": ["min_x_mm": 4, "min_y_mm": -1, "max_x_mm": 4.5, "max_y_mm": 1]])
            .map { "\($0.string("refdes") ?? "").\($0.string("pad") ?? "")" }, ["R2.1"])
    }

    /// A part flipped to the bottom is mirrored: at angle 0 its pad 1, left
    /// of centre on the top, is right of it; turned to 270° it is below.
    func testAFlippedPartsPadsAreWhereTheBoardDrawsThem() throws {
        try fixture.place(instance, x: 0, y: 0, angle: 0, bottom: true)
        try open()
        var pad = try XCTUnwrap(try pads(["component": "R1", "pads": ["1"]]).first)
        XCTAssertEqual(try at(pad).x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(try at(pad).y, 0, accuracy: 1e-9)
        XCTAssertEqual(pad.string("side"), "bottom")
        XCTAssertEqual(pad["layers"] as? [Int], [-100])

        _ = try client.result("apply", ["ops": [["op": "place_component", "component": fixture.flat(instance, "R1"),
                                                 "x_mm": 0, "y_mm": 0, "angle_deg": 270, "bottom": true]]])
        pad = try XCTUnwrap(try pads(["component": "R1", "pads": ["1"]]).first)
        XCTAssertEqual(try at(pad).x, 0, accuracy: 1e-9)
        XCTAssertEqual(try at(pad).y, -0.75, accuracy: 1e-9)
        // Its copper is where its centre is: 0.9 wide now, 0.8 tall.
        let box = try XCTUnwrap(pad.dictionary("box_mm"))
        XCTAssertEqual(box.double("min_x_mm") ?? 0, -0.45, accuracy: 1e-9)
        XCTAssertEqual(box.double("min_y_mm") ?? 0, -1.15, accuracy: 1e-9)
    }

    /// items_near lists what is round a point, nearest first, each with how
    /// far its copper is; layers narrows it, and a region lists what reaches
    /// into a box.
    func testItemsNearMeasuresFromThePointToEachItemsCopper() throws {
        let junction = "77777777-7777-4777-8777-777777777771", far = "77777777-7777-4777-8777-777777777772"
        try fixture.addCopper(
            junctions: [junction: HorizontalPoint(x: 2_500_000, y: 2_000_000), far: HorizontalPoint(x: 2_500_000, y: 6_000_000)],
            tracks: ["88888888-8888-4888-8888-888888888881": (fixture.junctionEnd(junction), fixture.junctionEnd(far), 0)],
            vias: ["99999999-9999-4999-8999-999999999991": junction])
        try open()
        // 1 mm right of the via's centre: its copper, Ø0.5, is 0.75 mm off;
        // the 0.2 mm track above it starts at the via.
        let reply = try XCTUnwrap(try client.result("items_near", ["at": ["x_mm": 3.5, "y_mm": 2], "radius_mm": 1.2]) as? JSONDictionary)
        let items = try XCTUnwrap(reply["items"] as? [JSONDictionary])
        XCTAssertEqual(items.map { $0.string("kind") ?? "" }, ["via", "track"], "\(reply)")
        XCTAssertEqual(items[0].string("id"), "99999999-9999-4999-8999-999999999991")
        XCTAssertEqual(items[0].double("distance_mm") ?? 0, 0.75, accuracy: 1e-6)
        XCTAssertEqual(items[0].double("x_mm") ?? 0, 2.75, accuracy: 1e-6)
        XCTAssertEqual(items[0]["layers"] as? [Int], [0, -100])
        XCTAssertEqual(items[1].double("distance_mm") ?? 0, 0.9, accuracy: 1e-6)
        XCTAssertEqual(reply["truncated"] as? Bool, false)

        // On the bottom only the via is there.
        let bottom = try XCTUnwrap(try client.result("items_near", ["at": ["x_mm": 3.5, "y_mm": 2], "radius_mm": 1.2, "layers": [-100]]) as? JSONDictionary)
        XCTAssertEqual((bottom["items"] as? [JSONDictionary])?.map { $0.string("kind") ?? "" }, ["via"])

        // A box over R2's pad 1 and nothing else.
        let region: JSONDictionary = ["min_x_mm": 4, "min_y_mm": -0.2, "max_x_mm": 4.5, "max_y_mm": 0.2]
        let boxed = try XCTUnwrap(try client.result("items_near", ["region": region]) as? JSONDictionary)
        XCTAssertEqual((boxed["items"] as? [JSONDictionary])?.map { $0.string("label") ?? "" }, ["Pad R2.1"], "\(boxed)")

        // list_tracks and list_vias take the same box.
        let over: JSONDictionary = ["min_x_mm": 2, "min_y_mm": 3, "max_x_mm": 3, "max_y_mm": 4]
        XCTAssertEqual((try client.result("list_tracks", ["region": over]) as? JSONDictionary)?.int("total"), 1)
        XCTAssertEqual((try client.result("list_vias", ["region": over]) as? JSONDictionary)?.int("total"), 0)
        XCTAssertEqual((try client.result("list_tracks", ["region": region]) as? JSONDictionary)?.int("total"), 0)
    }

    /// A text says where it draws. One placed at a point runs right from it;
    /// mirrored, as on the bottom, it runs left. A package's own text is
    /// listed with its package, though no board text stands for it.
    func testTextsSayWhereTheyDraw() throws {
        try open()
        func place(_ params: JSONDictionary) throws -> JSONDictionary {
            var op = params
            op["op"] = "place_board_text"
            let result = try XCTUnwrap(try client.result("apply", ["ops": [op], "dry_run": true]) as? JSONDictionary)
            return try XCTUnwrap((result["changes"] as? [JSONDictionary])?.first)
        }
        let plain = try place(["text": "HELLO", "layer": 20, "x_mm": 20, "y_mm": 5, "size_mm": 1, "width_mm": 0.15])
        let box = try XCTUnwrap(plain.dictionary("box_mm"), "\(plain)")
        XCTAssertEqual(plain.string("runs"), "right")
        XCTAssertEqual(box.double("min_x_mm") ?? 0, 20, accuracy: 0.2)
        XCTAssertGreaterThan(box.double("max_x_mm") ?? 0, 23)
        XCTAssertEqual(((box.double("min_y_mm") ?? 0) + (box.double("max_y_mm") ?? 0)) / 2, 5, accuracy: 0.1)

        let mirrored = try place(["text": "HELLO", "layer": -120, "x_mm": 20, "y_mm": 5, "size_mm": 1, "width_mm": 0.15, "mirror": true])
        let flipped = try XCTUnwrap(mirrored.dictionary("box_mm"), "\(mirrored)")
        XCTAssertEqual(mirrored.string("runs"), "left")
        XCTAssertEqual(flipped.double("max_x_mm") ?? 0, 20, accuracy: 0.2)
        XCTAssertLessThan(flipped.double("min_x_mm") ?? 99, 17)

        // The board has no text of its own, and three its packages draw.
        XCTAssertEqual((try client.result("list_board_texts") as? [JSONDictionary])?.count, 0)
        let owned = try XCTUnwrap(try client.result("list_board_texts", ["package_texts": true]) as? [JSONDictionary])
        XCTAssertEqual(owned.map { $0.string("drawn") ?? "" }.sorted(), ["R1", "R2", "R3"], "\(owned)")
        let r1 = try XCTUnwrap(owned.first { $0.string("refdes") == "R1" })
        XCTAssertEqual(r1["smashed"] as? Bool, false)
        XCTAssertEqual(r1.string("text"), "$RD")
        XCTAssertEqual(r1.double("x_mm") ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertNotNil(r1.dictionary("box_mm"))
        // A component search finds its package's text too.
        XCTAssertEqual((try client.result("list_board_texts", ["component": "R2"]) as? [JSONDictionary])?.count, 1)
    }
}
