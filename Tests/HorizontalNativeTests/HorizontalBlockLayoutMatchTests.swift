import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Which instances of a block are laid out alike, found from the board
/// alone: the motion between two instances, the parts it takes onto each
/// other and those it doesn't, the copper each instance owns, and the copper
/// that corresponds.
final class HorizontalBlockLayoutMatchTests: XCTestCase {
    private var fixture: BlockLayoutFixture!

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    func testTheIndexKnowsEachInstanceAndItsParts() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        let index = try XCTUnwrap(fixture.project.flattenedBlock).boardInstances
        XCTAssertEqual(index.siblings[fixture.channelID], [fixture.path(0), fixture.path(1), fixture.path(2)])
        let first = try XCTUnwrap(index.instances[fixture.path(0)])
        XCTAssertEqual(first.name, "I1")
        XCTAssertEqual(first.blockID, fixture.channelID)
        XCTAssertEqual(index.blockNames[fixture.channelID], "Channel")
        XCTAssertEqual(first.members, [
            fixture.components["R1"]!.lowercased(): fixture.flat(fixture.instances[0], "R1"),
            fixture.components["R2"]!.lowercased(): fixture.flat(fixture.instances[0], "R2"),
            fixture.components["R3"]!.lowercased(): fixture.flat(fixture.instances[0], "R3"),
        ])
        XCTAssertEqual(index.syncedInstances(of: fixture.flat(fixture.instances[1], "R2")).map(\.path), [fixture.path(1)])
        // MID is the instance's own; IN is the top block's IN1 too.
        let mid = try XCTUnwrap(fixture.project.board?.netDetails.first { $0.value.name == "I1/MID" }?.key)
        XCTAssertTrue(index.isOwnNet(mid, of: first))
        XCTAssertNotNil(index.localNet(mid, in: first))
        let in1 = try XCTUnwrap(fixture.project.board?.netDetails.first { $0.value.name == "IN1" }?.key)
        XCTAssertFalse(index.isOwnNet(in1, of: first))
        XCTAssertNotNil(index.localNet(in1, in: first), "the port is the instance's IN there")
    }

    func testAnInstanceIsPlacedByItsLowestNumberedUElseItsFirstPartByRefdes() throws {
        XCTAssertEqual(HorizontalBlockLayoutMatch.anchorKey(among: ["a": "R1", "b": "U10", "c": "U2", "d": "C1"]), "c", "U2 before U10")
        XCTAssertEqual(HorizontalBlockLayoutMatch.anchorKey(among: ["a": "U?", "b": "U7A", "c": "R1"]), "b", "a U with a number")
        XCTAssertEqual(HorizontalBlockLayoutMatch.anchorKey(among: ["a": "R10", "b": "R2", "c": "C3"]), "c", "no U: the first by refdes")
        XCTAssertEqual(HorizontalBlockLayoutMatch.anchorKey(among: ["a": "R10", "b": "R2"]), "b", "R2 before R10")
        XCTAssertNil(HorizontalBlockLayoutMatch.anchorKey(among: [:]))

        fixture = try BlockLayoutFixture(instances: 2)
        let anchor = try XCTUnwrap(try fixture.match().anchor(of: fixture.path(1)))
        XCTAssertEqual(anchor.local, fixture.components["R1"]!.lowercased(), "Channel has no U: R1")
        XCTAssertEqual(anchor.package.position, HorizontalPoint(x: 20_000_000, y: 0), "I2's R1")
    }

    func testInstancesShiftedTurnedOrFlippedAreLaidOutAlike() throws {
        fixture = try BlockLayoutFixture(instances: 5)
        try fixture.place(fixture.instances[1], x: 30, y: 20, angle: 90)
        try fixture.place(fixture.instances[2], x: 60, y: -10, angle: 45)
        try fixture.place(fixture.instances[3], x: 0, y: 40, angle: 30)
        try fixture.place(fixture.instances[4], x: 80, y: 40, angle: 90, bottom: true)
        let match = try fixture.match()
        let expected: [(index: Int, shift: HorizontalPoint, angle: Int, mirrored: Bool)] = [
            (1, HorizontalPoint(x: 30_000_000, y: 20_000_000), 16_384, false),
            (2, HorizontalPoint(x: 60_000_000, y: -10_000_000), 8_192, false),
            (3, HorizontalPoint(x: 0, y: 40_000_000), 5_461, false),
            (4, HorizontalPoint(x: 80_000_000, y: 40_000_000), 16_384, true),
        ]
        for item in expected {
            let pair = try XCTUnwrap(match.pair(from: fixture.path(0), to: fixture.path(item.index)), "I\(item.index + 1)")
            XCTAssertTrue(pair.related, "I\(item.index + 1)")
            XCTAssertEqual(pair.synced.count, 3, "I\(item.index + 1)")
            XCTAssertTrue(pair.differs.isEmpty)
            XCTAssertEqual(pair.transform.angle, item.angle, "I\(item.index + 1)")
            XCTAssertEqual(pair.transform.mirrored, item.mirrored, "I\(item.index + 1)")
            XCTAssertEqual(pair.transform.shift.x, item.shift.x, accuracy: 300, "I\(item.index + 1)")
            XCTAssertEqual(pair.transform.shift.y, item.shift.y, accuracy: 300, "I\(item.index + 1)")
            let back = try XCTUnwrap(match.pair(from: fixture.path(item.index), to: fixture.path(0)))
            XCTAssertTrue(back.related)
            let composed = back.transform.accumulated(with: pair.transform)
            XCTAssertEqual(composed.angle, 0)
            XCTAssertFalse(composed.mirrored)
        }
        XCTAssertEqual(match.classmates(of: fixture.path(0)), [fixture.path(1), fixture.path(2), fixture.path(3), fixture.path(4)])
        XCTAssertEqual(match.classes.count, 1)
    }

    func testAPartOffDiffersAndTwoOffIsNoLongerAlike() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        // I2's R3 a millimetre up; I3's R2 and R3 both moved.
        try fixture.apply([["op": "place_component", "component": fixture.flat(fixture.instances[1], "R3"), "x_mm": 30, "y_mm": 1]])
        try fixture.apply([
            ["op": "place_component", "component": fixture.flat(fixture.instances[2], "R2"), "x_mm": 45, "y_mm": 3],
            ["op": "place_component", "component": fixture.flat(fixture.instances[2], "R3"), "x_mm": 50, "y_mm": 4],
        ])
        let match = try fixture.match()
        let second = try XCTUnwrap(match.pair(from: fixture.path(0), to: fixture.path(1)))
        XCTAssertTrue(second.related)
        XCTAssertEqual(second.differs, [fixture.components["R3"]!.lowercased()])
        XCTAssertEqual(second.synced.count, 2)
        let third = try XCTUnwrap(match.pair(from: fixture.path(0), to: fixture.path(2)))
        XCTAssertFalse(third.related, "one part of three in place isn't the layout")
        XCTAssertEqual(match.classmates(of: fixture.path(0)), [fixture.path(1)])
    }

    func testStackedInstancesAreNotTakenForALayout() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try fixture.place(fixture.instances[1], x: 0, y: 0)
        let match = try fixture.match()
        XCTAssertEqual(match.pair(from: fixture.path(0), to: fixture.path(1))?.related, false)
        try fixture.place(fixture.instances[1], x: 1, y: 0.2)
        XCTAssertEqual(try fixture.match().pair(from: fixture.path(0), to: fixture.path(1))?.related, false, "over each other more than half")
    }

    /// An instance owns the copper between its own pads and the stubs and
    /// vias off them; copper that reaches another part's pad, or floats,
    /// is no instance's.
    func testAnInstanceOwnsTheCopperOnlyItsPadsJoin() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let (i1, i2) = (fixture.instances[0], fixture.instances[1])
        try fixture.addCopper(
            junctions: [
                "a0000000-0000-4000-8000-000000000001": HorizontalPoint(x: 2_500_000, y: 2_000_000),
                "a0000000-0000-4000-8000-000000000002": HorizontalPoint(x: -3_000_000, y: 0),
                "a0000000-0000-4000-8000-000000000003": HorizontalPoint(x: 40_000_000, y: 30_000_000),
            ],
            tracks: [
                // MID: R1 pin 2 to R2 pin 1 over a via.
                "b0000000-0000-4000-8000-000000000001": (try fixture.padEnd(i1, "R1", 2), fixture.junctionEnd("a0000000-0000-4000-8000-000000000001"), 0),
                "b0000000-0000-4000-8000-000000000002": (fixture.junctionEnd("a0000000-0000-4000-8000-000000000001"), try fixture.padEnd(i1, "R2", 1), 0),
                // A stub off IN.
                "b0000000-0000-4000-8000-000000000003": (try fixture.padEnd(i1, "R1", 1), fixture.junctionEnd("a0000000-0000-4000-8000-000000000002"), 0),
                // I1's R3 to I2's R1: neither's.
                "b0000000-0000-4000-8000-000000000004": (try fixture.padEnd(i1, "R3", 2), try fixture.padEnd(i2, "R1", 1), 0),
            ],
            vias: [
                "c0000000-0000-4000-8000-000000000001": "a0000000-0000-4000-8000-000000000001",
                "c0000000-0000-4000-8000-000000000002": "a0000000-0000-4000-8000-000000000003",
            ]
        )
        let match = try fixture.match()
        let owned = match.owned(fixture.path(0))
        XCTAssertEqual(owned.tracks, ["b0000000-0000-4000-8000-000000000001", "b0000000-0000-4000-8000-000000000002", "b0000000-0000-4000-8000-000000000003"])
        XCTAssertEqual(owned.vias, ["c0000000-0000-4000-8000-000000000001"])
        XCTAssertEqual(owned.junctions, ["a0000000-0000-4000-8000-000000000001", "a0000000-0000-4000-8000-000000000002"])
        XCTAssertTrue(match.owned(fixture.path(1)).isEmpty, "the track between the two is neither's")
    }

    /// Copper laid out alike in two instances corresponds, through a turn
    /// and through a flip to the bottom.
    func testCopperLaidOutAlikeCorresponds() throws {
        for (angle, bottom) in [(0.0, false), (90.0, false), (90.0, true)] {
            fixture?.remove()
            fixture = try BlockLayoutFixture(instances: 2)
            let (i1, i2) = (fixture.instances[0], fixture.instances[1])
            try fixture.place(i2, x: 40, y: 20, angle: angle, bottom: bottom)
            let pair = try XCTUnwrap(try fixture.match().pair(from: fixture.path(0), to: fixture.path(1)))
            let bend = HorizontalPoint(x: 2_500_000, y: 2_000_000)
            let moved = pair.transform.applying(to: bend).rounded
            let layer = bottom ? HorizontalBoardLayers.bottomCopper : HorizontalBoardLayers.topCopper
            try fixture.addCopper(
                junctions: ["a0000000-0000-4000-8000-000000000001": bend, "a0000000-0000-4000-8000-000000000011": moved],
                tracks: [
                    "b0000000-0000-4000-8000-000000000001": (try fixture.padEnd(i1, "R1", 2), fixture.junctionEnd("a0000000-0000-4000-8000-000000000001"), 0),
                    "b0000000-0000-4000-8000-000000000002": (fixture.junctionEnd("a0000000-0000-4000-8000-000000000001"), try fixture.padEnd(i1, "R2", 1), 0),
                    // I2's, drawn from the other end for the first.
                    "b0000000-0000-4000-8000-000000000011": (fixture.junctionEnd("a0000000-0000-4000-8000-000000000011"), try fixture.padEnd(i2, "R1", 2), layer),
                    "b0000000-0000-4000-8000-000000000012": (fixture.junctionEnd("a0000000-0000-4000-8000-000000000011"), try fixture.padEnd(i2, "R2", 1), layer),
                ],
                vias: ["c0000000-0000-4000-8000-000000000001": "a0000000-0000-4000-8000-000000000001",
                       "c0000000-0000-4000-8000-000000000011": "a0000000-0000-4000-8000-000000000011"]
            )
            let map = try fixture.match().copper(from: fixture.path(0), to: fixture.path(1))
            let label = "\(angle)° \(bottom ? "bottom" : "top")"
            XCTAssertEqual(map.junctions, ["a0000000-0000-4000-8000-000000000001": "a0000000-0000-4000-8000-000000000011"], label)
            XCTAssertEqual(map.vias, ["c0000000-0000-4000-8000-000000000001": "c0000000-0000-4000-8000-000000000011"], label)
            XCTAssertEqual(map.tracks["b0000000-0000-4000-8000-000000000001"],
                           .init(id: "b0000000-0000-4000-8000-000000000011", reversed: true), label)
            XCTAssertEqual(map.tracks["b0000000-0000-4000-8000-000000000002"],
                           .init(id: "b0000000-0000-4000-8000-000000000012", reversed: false), label)
        }
    }
}

/// What the board inspector and MCP say of an instance's layout, and Select
/// Instance.
final class HorizontalBlockInstanceSummaryTests: XCTestCase {
    private var fixture: BlockLayoutFixture!

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        // I2's R3 a millimetre up.
        try fixture.apply([["op": "place_component", "component": fixture.flat(fixture.instances[1], "R3"), "x_mm": 30, "y_mm": 1]])
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
        super.tearDown()
    }

    func testTheInspectorSaysWhichInstanceAndWhatDiffers() throws {
        let match = try fixture.match()
        let second = try fixture.packageID(fixture.instances[1], "R1")
        let instances = HorizontalBlockInstanceSummary.instances(ofPackages: [second], in: match)
        XCTAssertEqual(instances.map(\.name), ["I2"])
        let rows = HorizontalBlockInstanceSummary.details(for: instances, in: match).map { "\($0.label): \($0.value)" }
        let anchor = try XCTUnwrap(match.anchor(of: fixture.path(1))?.package.componentDetails?.refdes)
        XCTAssertEqual(rows, ["Block instance: I2 of Channel", "Anchor: \(anchor)", "In sync with: I1, I3",
                              "Differs from I1: R3", "Differs from I3: R3"])

        let first = try fixture.packageID(fixture.instances[0], "R2")
        let both = HorizontalBlockInstanceSummary.instances(ofPackages: [second, first], in: match)
        XCTAssertEqual(HorizontalBlockInstanceSummary.details(for: both, in: match).map { "\($0.label): \($0.value)" },
                       ["Block instances: I1, I2 of Channel"])
        XCTAssertEqual(HorizontalBlockInstanceSummary.actions(canCopyLayout: false).map(\.id), [HorizontalBlockInstanceSummary.selectActionID])
    }

    func testSelectInstanceSelectsItsPartsAndItsOwnCopper() throws {
        let i1 = fixture.instances[0]
        try fixture.addCopper(
            junctions: ["a0000000-0000-4000-8000-000000000001": HorizontalPoint(x: 2_500_000, y: 2_000_000)],
            tracks: [
                "b0000000-0000-4000-8000-000000000001": (try fixture.padEnd(i1, "R1", 2), fixture.junctionEnd("a0000000-0000-4000-8000-000000000001"), 0),
                "b0000000-0000-4000-8000-000000000002": (fixture.junctionEnd("a0000000-0000-4000-8000-000000000001"), try fixture.padEnd(i1, "R2", 1), 0),
                "b0000000-0000-4000-8000-000000000003": (try fixture.padEnd(i1, "R3", 2), try fixture.padEnd(fixture.instances[1], "R1", 1), 0),
            ],
            vias: ["c0000000-0000-4000-8000-000000000001": "a0000000-0000-4000-8000-000000000001"]
        )
        let board = try fixture.board
        let refs = board.packages.map { HorizontalSelectableRef(id: $0.id, type: .boardPackage) }
            + board.tracks.map { HorizontalSelectableRef(id: $0.id, type: .track, layer: $0.layer) }
            + board.vias.map { HorizontalSelectableRef(id: $0.id, type: .via) }
        let match = try fixture.match()
        let instances = HorizontalBlockInstanceSummary.instances(ofPackages: [try fixture.packageID(i1, "R3")], in: match)
        let selected = HorizontalBlockInstanceSummary.selection(of: instances, in: match, from: refs)
        XCTAssertEqual(Set(selected.filter { $0.type == .boardPackage }.map(\.id)),
                       Set(try ["R1", "R2", "R3"].map { try fixture.packageID(i1, $0) }))
        XCTAssertEqual(Set(selected.filter { $0.type == .track }.map { $0.id.lowercased() }),
                       ["b0000000-0000-4000-8000-000000000001", "b0000000-0000-4000-8000-000000000002"])
        XCTAssertEqual(selected.filter { $0.type == .via }.map { $0.id.lowercased() }, ["c0000000-0000-4000-8000-000000000001"])
    }

    func testListBlockInstancesSaysWhichAreLaidOutAlike() throws {
        try fixture.saveToDisk()
        let client = try BlockLayoutDispatchClient(path: fixture.url.path)
        defer { client.close() }
        let listed = try XCTUnwrap(try client.result("list_block_instances") as? [JSONDictionary])
        let byRefdes = listed.reduce(into: [String: JSONDictionary]()) { $0[$1.string("refdes") ?? ""] = $1 }
        let first = try XCTUnwrap(byRefdes["I1"]?.dictionary("board"))
        XCTAssertEqual(first.int("members"), 3)
        XCTAssertEqual(first.int("placed_members"), 3)
        XCTAssertEqual(first["in_sync_with"] as? [String], ["I2", "I3"])
        XCTAssertEqual((first.dictionary("differs_from")?["I2"]) as? [String], ["R3"])
        XCTAssertEqual(byRefdes["I3"]?.dictionary("board")?["in_sync_with"] as? [String], ["I1", "I2"])
    }
}
