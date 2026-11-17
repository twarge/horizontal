import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Copper drawn to the parts and nets inside block instances. The board
/// places a package for each instance's use of a sub-block's component and
/// carries each instance's own nets, neither of which the top block's file
/// holds, so place_track and place_via name them as the flattened block does:
/// a part by its refdes or flat uuid, a net by `I1/MID` or its flat uuid.
/// The board is `BlockLayoutFixture`'s: R1 at the origin and R2 5 mm right of
/// it, pads at ±0.75 mm, MID on R1's pad 2 and R2's and R3's pad 1.
final class BoardBlockInstanceCopperTests: XCTestCase {
    private var fixture: BlockLayoutFixture!

    override func tearDown() {
        fixture?.remove()
        super.tearDown()
    }

    /// The flat uuid of MID in instance `index`.
    private func mid(_ index: Int) throws -> String {
        let nets = try XCTUnwrap(fixture.project.flattenedBlock).json.dictionaryMap("nets")
        return try XCTUnwrap(nets.first { $0.value.string("name") == "I\(index + 1)/MID" }?.key).lowercased()
    }

    private func part(_ index: Int, _ refdes: String) -> String {
        fixture.flat(fixture.instances[index], refdes)
    }

    private func airwires(on net: String) throws -> Int {
        try fixture.board.airwires.filter { $0.netID?.lowercased() == net }.count
    }

    /// A track between two pads of an instance is bound to both pads and is
    /// on the instance's own net, which loses the airwire it stood for.
    func testATrackEndsOnAnInstancesPadsAndTakesItsNet() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let net = try mid(0)
        XCTAssertEqual(try airwires(on: net), 2)
        let changes = try fixture.apply([[
            "op": "place_track", "layer": 0, "width_mm": 0.2,
            "from": ["component": part(0, "R1"), "pad": "2"], "to": ["component": part(0, "R2"), "pad": "1"],
        ]])
        XCTAssertEqual(changes.first?.string("net"), net)
        XCTAssertEqual((changes.first?["junctions_created"] as? [String])?.count, 0, "an end on a pad needs no junction")

        let track = try XCTUnwrap(try fixture.boardJSON().dictionaryMap("tracks").values.first)
        XCTAssertEqual(track.dictionary("from")?.string("pad"), "\(try fixture.packageID(fixture.instances[0], "R1"))/\(fixture.padIDs[1])")
        XCTAssertEqual(track.dictionary("to")?.string("pad"), "\(try fixture.packageID(fixture.instances[0], "R2"))/\(fixture.padIDs[0])")
        // The file names the pads and no net, as Horizon's does; the board
        // read back gives the track its pads' net.
        XCTAssertEqual(try fixture.board.tracks.first?.netID?.lowercased(), net)
        XCTAssertEqual(try airwires(on: net), 1)
        // The other instance's MID is another net, and untouched.
        XCTAssertEqual(try airwires(on: try mid(1)), 2)
    }

    /// With one instance its parts' refdes name them; with two that share
    /// them, a refdes names two parts and the op says to use the id.
    func testAnInstancesPartIsNamedByRefdesWhereThatNamesOne() throws {
        fixture = try BlockLayoutFixture(instances: 1)
        let changes = try fixture.apply([[
            "op": "place_track", "layer": 0, "width_mm": 0.2,
            "from": ["component": "R1", "pad": "2"], "to": ["x_mm": 2.5, "y_mm": 1.5],
        ]])
        XCTAssertEqual(changes.first?.string("net"), try mid(0))
        fixture.remove()

        fixture = try BlockLayoutFixture(instances: 2)
        let shared = Set(try XCTUnwrap(fixture.project.flattenedBlock).instances.map(\.refdes)).count < 6
        guard shared else { return }
        XCTAssertThrowsError(try fixture.apply([[
            "op": "place_track", "layer": 0, "width_mm": 0.2,
            "from": ["component": "R1", "pad": "2"], "to": ["x_mm": 2.5, "y_mm": 1.5],
        ]])) { error in
            XCTAssertTrue("\(error)".contains("use the id"), "\(error)")
        }
    }

    /// Smash takes an instance's package as it takes any other: its refdes
    /// becomes a board text that can be moved, and unsmash takes it back.
    func testAnInstancesPackageIsSmashed() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let smashed = try fixture.apply([["op": "smash", "component": part(1, "R2"), "board": true]])
        let texts = try XCTUnwrap(smashed.first?["texts"] as? [String])
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(smashed.first?.string("package"), try fixture.packageID(fixture.instances[1], "R2"))
        XCTAssertNotNil(try fixture.boardJSON().dictionaryMap("texts")[texts[0]])
        _ = try fixture.apply([["op": "place_board_text", "id": texts[0], "x_mm": 26, "y_mm": 3]])
        let undone = try fixture.apply([["op": "unsmash", "component": part(1, "R2"), "board": true]])
        XCTAssertEqual(undone.first?["texts_removed"] as? [String], texts)
    }

    /// A via carries an instance's net by the name the flattened block gives
    /// it, and a track from it to a pad of another instance's net is refused
    /// by name.
    func testAnInstancesNetIsNamedAsTheFlattenedBlockNamesIt() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let net = try mid(0)
        let via = try fixture.apply([["op": "place_via", "net": "I1/MID", "x_mm": 2.5, "y_mm": 2, "diameter_mm": 0.5, "hole_mm": 0.25]])
        XCTAssertEqual(via.first?.string("net"), net)
        XCTAssertEqual(try fixture.board.vias.first?.netID?.lowercased(), net)

        // Joined to R1's pad 2 by a track that names the net by its uuid.
        _ = try fixture.apply([[
            "op": "place_track", "layer": 0, "width_mm": 0.2, "net": net,
            "from": ["component": part(0, "R1"), "pad": "2"], "to": ["x_mm": 2.5, "y_mm": 2],
        ]])
        XCTAssertEqual(try fixture.board.tracks.first?.netID?.lowercased(), net)

        XCTAssertThrowsError(try fixture.apply([[
            "op": "place_track", "layer": 0, "width_mm": 0.2, "net": "I2/MID",
            "from": ["component": part(0, "R1"), "pad": "2"], "to": ["x_mm": 1, "y_mm": -2],
        ]])) { error in
            XCTAssertTrue("\(error)".contains("The ends are on I1/MID, not I2/MID"), "\(error)")
        }
        XCTAssertThrowsError(try fixture.apply([["op": "place_via", "net": "I9/MID", "x_mm": 2.5, "y_mm": -2]])) { error in
            XCTAssertTrue("\(error)".contains("No net I9/MID"), "\(error)")
        }
    }
}
