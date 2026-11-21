import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Horizontal pinned every via it made for a route (`net_set`), so a board
/// it routed has vias pinned to the very net their pads give them, which
/// stay behind when the schematic moves a rail. Horizon's Place Via pins as
/// well, so a pin can't be told for a mistake from the file alone. The pin
/// comes off only when asked (unpin_vias, Let Vias Follow Their Tracks…), and
/// only where it changes no net: a via whose copper, with no pin on it,
/// reaches pads of one net, the one it is pinned to (`HorizontalPinnedVias`).
///
/// A stitching via standing alone, a via whose tracks reach no pad, and one
/// on copper joining several nets keep their pins. A via pinned to a net its
/// pads don't give is a conflict: reported with where it is, never changed.
final class OnlyViasPinnedToTheirPadsNetAreUnpinnedTests: XCTestCase {
    private var fixture: PinnedViaFixture!

    override func setUpWithError() throws {
        fixture = try PinnedViaFixture()
    }

    override func tearDown() {
        fixture?.remove()
        super.tearDown()
    }

    private func review() throws -> HorizontalPinnedVias.Review {
        HorizontalPinnedVias.review(try fixture.board)
    }

    /// The kind of the via at (`x`, `y`) mm.
    private func kind(at x: Double, _ y: Double, in review: HorizontalPinnedVias.Review) throws -> HorizontalPinnedVias.Kind {
        let point = HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
        return try XCTUnwrap(review.vias.first { abs($0.position.x - point.x) < 1 && abs($0.position.y - point.y) < 1 }?.kind,
                             "a pinned via at (\(x), \(y))")
    }

    /// Every via's and track's net on `board`, as connectivity gives them.
    private func nets(_ board: HorizontalBoard) -> [String: String?] {
        let resolved = HorizontalBoardConnectivity.recompute(board)
        var nets = [String: String?]()
        for via in resolved.vias { nets["via " + via.id.lowercased()] = via.netID?.lowercased() }
        for track in resolved.tracks { nets["track " + track.id.lowercased()] = track.netID?.lowercased() }
        return nets
    }

    // MARK: - Each kind

    /// The vias Horizontal's track tool used to pin: on a route between two
    /// +3V3 pads, pinned to +3V3. They follow, and taking the pins off
    /// changes no net now; when the rail moves, they go with their tracks.
    func testAViaPinnedToTheNetItsPadsGiveFollowsAndUnpinningChangesNoNet() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", true)))
        let rail = try fixture.net("+3V3")
        let found = try review()
        XCTAssertEqual(found.vias.count, 2)
        XCTAssertEqual(found.vias.map(\.kind), [.follows, .follows])
        XCTAssertEqual(found.vias.map(\.padNets), [[rail], [rail]], "the pads' net, the pins left out")

        var board = try fixture.board
        let before = nets(board)
        XCTAssertTrue(BoardViaNetCommands.letViasFollow(found, in: &board))
        XCTAssertTrue(board.vias.allSatisfy { $0.netSetID == nil })
        XCTAssertEqual(nets(board), before, "no via or track changes net")

        try fixture.commit(board)
        try fixture.edit([["op": "connect", "component": "R1", "pin": "1", "net": "+5V"],
                          ["op": "connect", "component": "R2", "pin": "1", "net": "+5V"]])
        let five = try fixture.net("+5V")
        XCTAssertTrue(try fixture.board.vias.allSatisfy { $0.netID?.lowercased() == five }, "they follow their tracks to +5V")
    }

    /// A via standing alone holds its net only by its pin: it keeps it.
    func testAStitchingViaKeepsItsPin() throws {
        try fixture.edit([PinnedViaFixture.via(50, 30, "+3V3", pinned: true)])
        let found = try review()
        XCTAssertEqual(try kind(at: 50, 30, in: found), .stitching)
        XCTAssertTrue(found.following.isEmpty)
    }

    /// A via whose tracks reach no pad on a net gives them their net with
    /// its pin: it keeps it.
    func testAViaWhoseTracksReachNoPadKeepsItsPin() throws {
        try fixture.edit([
            PinnedViaFixture.track((60, 30), (65, 30), layer: 0, net: "+3V3"),
            PinnedViaFixture.via(65, 30, "+3V3", pinned: true),
        ])
        let found = try review()
        XCTAssertEqual(try kind(at: 65, 30, in: found), .noPad)
        XCTAssertEqual(found.vias.first?.padNets, [])
    }

    /// Copper joining a +3V3 pad to a +5V one is a short already, as R2's
    /// pin moved to +5V with its tracks left on it makes: the via on it
    /// keeps its pin, whichever net that is.
    func testAViaOnCopperJoiningPadsOfTwoNetsIsAShortAndKeepsItsPin() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", false)))
        try fixture.edit([["op": "connect", "component": "R2", "pin": "1", "net": "+5V"]])
        let found = try review()
        XCTAssertEqual(try kind(at: 20, 20, in: found), .short)
        XCTAssertEqual(found.vias.first?.padNets, [try fixture.net("+3V3"), try fixture.net("+5V")])
    }

    /// Calypso's case: a via pinned to +5V on copper its +3V3 pad gives
    /// +3V3. It is a conflict and keeps its pin; the other via on that
    /// copper, pinned to +3V3, would take the short's no net if it lost its
    /// pin, so it is held back as on a short until the conflict is settled.
    func testAViaPinnedToAnotherNetThanItsPadsIsAConflictAndNothingOnItsCopperChanges() throws {
        try fixture.edit([
            PinnedViaFixture.track(from: "R1", pad: "1", to: 20, 20),
            PinnedViaFixture.via(20, 20, "+3V3", pinned: true),
            PinnedViaFixture.track((20, 20), (30, 20), layer: -100),
            PinnedViaFixture.via(30, 20, "+5V", pinned: true),
        ])
        let found = try review()
        XCTAssertEqual(try kind(at: 30, 20, in: found), .conflict)
        XCTAssertEqual(try kind(at: 20, 20, in: found), .short)
        let conflict = try XCTUnwrap(found.conflicts.first)
        XCTAssertEqual(conflict.pin, try fixture.net("+5V"))
        XCTAssertEqual(conflict.padNets, [try fixture.net("+3V3")])

        var board = try fixture.board
        XCTAssertFalse(BoardViaNetCommands.letViasFollow(found, in: &board), "nothing to unpin")
        XCTAssertEqual(board.vias.compactMap(\.netSetID).count, 2)
    }

    /// A via no pin holds is none of these: it already follows.
    func testAViaWithNoPinIsLeftOut() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", false), up: (30, 20, "+3V3", true)))
        let found = try review()
        XCTAssertEqual(found.vias.count, 1)
        XCTAssertEqual(try kind(at: 30, 20, in: found), .follows)
    }

    // MARK: - unpin_vias

    /// A board with two vias that follow, a conflict, a stitching via and
    /// one whose tracks reach no pad.
    private func mixedBoard() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", true)))
        try fixture.edit([
            PinnedViaFixture.track(from: "R1", pad: "2", to: 15, 0),
            PinnedViaFixture.via(15, 0, "+3V3", pinned: true),
            PinnedViaFixture.via(50, 30, "+3V3", pinned: true),
            PinnedViaFixture.track((60, 30), (65, 30), layer: 0, net: "+5V"),
            PinnedViaFixture.via(65, 30, "+5V", pinned: true),
        ])
    }

    /// The dry run lists the vias it would unpin and the conflicts it
    /// leaves, with where they are, and writes nothing; the commit takes
    /// net_set off those vias alone, the rest of each entry as it was.
    func testUnpinViasDryRunListsWhatItWouldUnpinAndTheConflictsThenUnpinsThoseAlone() throws {
        try mixedBoard()
        try fixture.writeToDisk()
        let before = try fixture.viaEntries()
        XCTAssertEqual(before.values.filter { $0["net_set"] != nil }.count, 5)
        let client = try BlockLayoutDispatchClient(path: fixture.url.path)
        defer { client.close() }

        let dry = try XCTUnwrap(try client.result("apply", ["ops": [["op": "unpin_vias"]], "dry_run": true]) as? JSONDictionary)
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        let change = try XCTUnwrap((dry["changes"] as? [JSONDictionary])?.first)
        XCTAssertEqual(change.int("pinned"), 5)
        XCTAssertEqual(change.dictionary("counts")?.int("follows"), 2)
        XCTAssertEqual(change.dictionary("counts")?.int("conflict"), 1)
        XCTAssertEqual(change.dictionary("counts")?.int("stitching"), 1)
        XCTAssertEqual(change.dictionary("counts")?.int("no_pad"), 1)
        XCTAssertEqual(change.dictionary("counts")?.int("short"), 0)
        let unpinned = try XCTUnwrap(change["unpinned"] as? [JSONDictionary])
        XCTAssertEqual(Set(unpinned.compactMap { $0.double("x_mm") }), [20, 30])
        XCTAssertEqual(Set(unpinned.compactMap { $0.string("net") }), ["+3V3"])
        let conflicts = try XCTUnwrap(change["conflicts"] as? [JSONDictionary])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.string("net_set"), "+3V3")
        XCTAssertEqual(conflicts.first?.string("pads_net"), "+5V")
        XCTAssertEqual(conflicts.first?.double("x_mm"), 15)
        XCTAssertEqual(conflicts.first?.double("y_mm"), 0)
        let onDisk = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.url.appendingPathComponent(try XCTUnwrap(fixture.project.boardFilename)))) as? JSONDictionary)
        XCTAssertEqual(onDisk.dictionaryMap("vias").values.filter { $0["net_set"] != nil }.count, 5, "a dry run writes nothing")

        let done = try XCTUnwrap(try client.result("apply", ["ops": [["op": "unpin_vias"]]]) as? JSONDictionary)
        XCTAssertEqual((done["changes"] as? [JSONDictionary])?.first?.int("unpinned_count"), 2)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.url.appendingPathComponent(try XCTUnwrap(fixture.project.boardFilename)))) as? JSONDictionary)
            .dictionaryMap("vias")
        let unpinnedIDs = Set(unpinned.compactMap { $0.string("via")?.lowercased() })
        XCTAssertEqual(unpinnedIDs.count, 2)
        for (id, entry) in before {
            let after = try XCTUnwrap(written[id])
            if unpinnedIDs.contains(id.lowercased()) {
                XCTAssertNil(after["net_set"], "Via::serialize writes no net_set on a via that holds none")
                var expected = entry
                expected.removeValue(forKey: "net_set")
                XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: expected), "only net_set changes")
            } else {
                XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: entry), "a via that keeps its pin is as it was")
            }
        }

        let again = try XCTUnwrap(try client.result("apply", ["ops": [["op": "unpin_vias"]], "dry_run": true]) as? JSONDictionary)
        XCTAssertEqual((again["changes"] as? [JSONDictionary])?.first?.int("unpinned_count"), 0, "nothing more to unpin")
    }

    /// The nets it goes by are the project's as it loaded, which another op
    /// of the batch would change: it goes in a batch of its own.
    func testUnpinViasGoesInABatchOfItsOwn() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", true)))
        for batch in [[PinnedViaFixture.via(50, 30, "+3V3", pinned: true), ["op": "unpin_vias"]],
                      [["op": "unpin_vias"], PinnedViaFixture.via(50, 30, "+3V3", pinned: true)]] {
            XCTAssertThrowsError(try fixture.edit(batch)) { error in
                XCTAssertTrue("\(error)".contains("a batch of its own"), "\(error)")
            }
        }
        XCTAssertEqual(try fixture.edit([["op": "unpin_vias"]]).first?.int("unpinned_count"), 2)
        XCTAssertTrue(try fixture.viaEntries().values.allSatisfy { $0["net_set"] == nil })
    }

    /// Two instances of a block laid out alike, each with a via on R1's pad
    /// 2: the first pinned to its MID, which its pad gives it, the second to
    /// OUT, which its pad doesn't. unpin_vias takes the first pin off and
    /// leaves the conflict pinned: the block sync `apply` makes for an edit
    /// of one instance would have copied the first via's unpinning onto the
    /// second, as Calypso's conflict lost its pin in a dry run.
    func testUnpinViasTakesNoPinOffTheViaLaidOutLikeItInAnotherBlockInstance() throws {
        let blocks = try BlockLayoutFixture(instances: 2)
        defer { blocks.remove() }
        var junctions = [String: HorizontalPoint](), tracks = [String: (from: JSONDictionary, to: JSONDictionary, layer: Int)]()
        var vias = [String: String]()
        let viaIDs = ["55555555-5555-4555-8555-555555555551", "55555555-5555-4555-8555-555555555552"]
        for (index, instance) in blocks.instances.enumerated() {
            let junction = "66666666-6666-4666-8666-66666666666\(index)"
            junctions[junction] = HorizontalPoint(x: Double(index) * 20_000_000 + 750_000, y: 3_000_000)
            tracks["77777777-7777-4777-8777-77777777777\(index)"] = (try blocks.padEnd(instance, "R1", 2), blocks.junctionEnd(junction), 0)
            vias[viaIDs[index]] = junction
        }
        try blocks.addCopper(junctions: junctions, tracks: tracks, vias: vias)
        func padNet(_ instance: String, _ refdes: String, _ number: Int) throws -> String {
            let package = try blocks.packageID(instance, refdes)
            let pad = try XCTUnwrap(try blocks.board.packagePads.first {
                $0.id.lowercased().hasPrefix("\(package.lowercased())/pad/\(blocks.padIDs[number - 1].lowercased())")
            })
            return try XCTUnwrap(pad.netID).lowercased()
        }
        let mid = try padNet(blocks.instances[0], "R1", 2), out = try padNet(blocks.instances[1], "R2", 2)
        var json = try blocks.boardJSON()
        var viaMap = json.dictionaryMap("vias")
        viaMap[viaIDs[0]]?["net_set"] = mid
        viaMap[viaIDs[1]]?["net_set"] = out
        json["vias"] = viaMap
        try blocks.putBoard(json)
        XCTAssertEqual(HorizontalPinnedVias.review(try blocks.board).vias.map(\.kind).sorted { $0.rawValue < $1.rawValue },
                       [.conflict, .follows])
        try blocks.saveToDisk()

        let client = try BlockLayoutDispatchClient(path: blocks.url.path)
        defer { client.close() }
        let done = try XCTUnwrap(try client.result("apply", ["ops": [["op": "unpin_vias"]]]) as? JSONDictionary)
        XCTAssertNil(done["synced"], "nothing made in the other instance")
        let change = try XCTUnwrap((done["changes"] as? [JSONDictionary])?.first)
        XCTAssertEqual((change["unpinned"] as? [JSONDictionary])?.compactMap { $0.string("via") }, [viaIDs[0]])
        XCTAssertEqual((change["conflicts"] as? [JSONDictionary])?.compactMap { $0.string("via") }, [viaIDs[1]])
        let written = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: blocks.url.appendingPathComponent("board.json"))) as? JSONDictionary).dictionaryMap("vias")
        XCTAssertNil(written[viaIDs[0]]?["net_set"])
        XCTAssertEqual(written[viaIDs[1]]?.string("net_set"), out, "the conflict keeps its pin")
    }
}
