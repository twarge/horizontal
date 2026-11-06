import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Copper whose pad goes, or whose pad's pin leaves its net, keeps no net
/// when the board is read again: the canvas draws it orange. The tracks and
/// junctions the track tool and `place_track` wrote carried the net they were
/// drawn on, and the loader read it back as the copper's own, so a deleted
/// symbol left its routing on the old net. Now, as Horizon writes them, they
/// carry none, and the loader takes each from the pads its copper reaches.
final class BoardOrphanedCopperNetTests: XCTestCase {
    private struct Fixture {
        var project: HorizontalProject
        var archive: HorizontalProjectArchive
        var gate: String
        var pin: String
    }

    func testRoutingLeftByADeletedPackageHasNoNet() throws {
        let fixture = try makeFixture()
        let before = try XCTUnwrap(fixture.project.board)
        let signal = try XCTUnwrap(before.tracks.first?.netID)
        XCTAssertEqual(before.tracks.count, 2)
        XCTAssertTrue(before.tracks.allSatisfy { $0.netID == signal })

        // What deleting R1's last symbol on the canvas does to the board.
        let board = try reloaded(fixture, applying: [["op": "remove_placement", "component": "R1"]])
        XCTAssertEqual(board.packages.map(\.label), ["R3"])
        XCTAssertEqual(board.tracks.count, 2, "The routing stays on junctions where the pad was")
        XCTAssertTrue(board.tracks.allSatisfy { $0.netID == nil }, "No pad reaches the routing any more")
        XCTAssertTrue(board.junctionNetIDs.isEmpty, "No pad reaches a junction")
        XCTAssertTrue(board.airwires.isEmpty, "Net-less copper joins R3 to nothing")
        XCTAssertEqual(board.tracks.map(\.netID), HorizontalBoardConnectivity.recompute(board).tracks.map(\.netID),
                       "The board as read agrees with the editor's own pass")
    }

    func testSavingTheBoardStoresNoNetOnItsCopper() throws {
        let fixture = try makeFixture()
        var (project, archive) = try reloadedProject(fixture, applying: [
            ["op": "remove_placement", "component": "R1"]
        ])
        let board = try XCTUnwrap(project.board)
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive))
        let saved = try boardJSON(in: archive)
        XCTAssertEqual(saved.dictionaryMap("tracks").count, 2)
        XCTAssertTrue(saved.dictionaryMap("tracks").values.allSatisfy { $0["net"] == nil },
                      "A track's stored net goes with its pad")
        XCTAssertTrue(saved.dictionaryMap("junctions").values.allSatisfy { $0["net"] == nil })

        // A track still on a pad stores no net either: the pad's, now
        // another, is what it is read back on.
        (project, archive) = try reloadedProject(fixture, applying: [
            ["op": "connect", "component": "R1", "pin": "\(fixture.gate)/\(fixture.pin)", "net": "OTHER", "create_net": true]
        ])
        var moved = try XCTUnwrap(project.board)
        let other = try XCTUnwrap(moved.tracks.first?.netID)
        moved.junctions[UUID().uuidString.lowercased()] = HorizontalPoint(x: 40_000_000, y: 40_000_000)
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: moved, in: project, to: &archive))
        XCTAssertTrue(try boardJSON(in: archive).dictionaryMap("tracks").values.allSatisfy { $0["net"] == nil })
        var reread = try HorizontalProject.loadSnapshot(of: archive)
        reread.rebaseURLs(onto: project)
        XCTAssertEqual(Set(try XCTUnwrap(reread.board).tracks.compactMap(\.netID)), [other])
    }

    func testRoutingOnAPinTakenOffItsNetHasNoNet() throws {
        let fixture = try makeFixture()
        let board = try reloaded(fixture, applying: [
            ["op": "disconnect", "component": "R1", "pin": "\(fixture.gate)/\(fixture.pin)"]
        ])
        XCTAssertEqual(Set(board.packages.map(\.label)), ["R1", "R3"])
        XCTAssertTrue(board.tracks.allSatisfy { $0.netID == nil }, "R1's pad is on no net")
        XCTAssertTrue(board.airwires.isEmpty)
    }

    func testRoutingFollowsItsPinOntoAnotherNet() throws {
        let fixture = try makeFixture()
        let board = try reloaded(fixture, applying: [
            ["op": "connect", "component": "R1", "pin": "\(fixture.gate)/\(fixture.pin)", "net": "OTHER", "create_net": true]
        ])
        let r1 = try XCTUnwrap(board.packages.first { $0.label == "R1" }?.id)
        let other = try XCTUnwrap(board.packagePads.first { $0.id.hasPrefix(r1) }?.netID)
        let signal = try XCTUnwrap(fixture.project.board?.tracks.first?.netID)
        XCTAssertNotEqual(other, signal)
        XCTAssertTrue(board.tracks.allSatisfy { $0.netID == other }, "The routing is on the net its pad is on now")
        XCTAssertFalse(board.junctionNetIDs.values.contains(signal))
    }

    private func reloaded(_ fixture: Fixture, applying operations: [JSONDictionary]) throws -> HorizontalBoard {
        try XCTUnwrap(try reloadedProject(fixture, applying: operations).project.board)
    }

    /// The project as the app has it after `operations`, read again from
    /// their archive as the board's netlist sync reads it.
    private func reloadedProject(
        _ fixture: Fixture, applying operations: [JSONDictionary]
    ) throws -> (project: HorizontalProject, archive: HorizontalProjectArchive) {
        let edited = try HorizontalCanvasProjectEdit.archive(
            applying: operations, to: fixture.archive, in: fixture.project
        ).archive
        var project = try HorizontalProject.loadSnapshot(of: edited)
        project.rebaseURLs(onto: fixture.project)
        return (project, edited)
    }

    private func boardJSON(in archive: HorizontalProjectArchive) throws -> JSONDictionary {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    /// R1 and R3 with their one pin on SIG, and two tracks from R1's pad: one
    /// to a bend, one on from it. Both tracks and both junctions store SIG.
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orphaned-copper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        let poolURL = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let pin = HorizontalPoolItemFactory.newUUID()
        unit.pins = [pin: HorizontalUnitPin(id: pin, primaryName: "1")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shape: HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        let pad = HorizontalPoolItemFactory.newUUID()
        package.pads[pad] = HorizontalPad(id: pad, name: "1", padstackID: padstack.uuid,
                                          placement: HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false))
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [pad: HorizontalPartPadMapEntry(gateID: gate, pinID: pin)]
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        let project = try HorizontalProject.load(from: url)
        let seeded = try HorizontalCanvasProjectEdit.archive(applying: [
            ["op": "ensure_component", "refdes": "R1", "part": part.uuid],
            ["op": "ensure_component", "refdes": "R3", "part": part.uuid],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R3", "x_mm": 30, "y_mm": 10],
            ["op": "connect", "component": "R1", "pin": "\(gate)/\(pin)", "net": "SIG", "create_net": true],
            ["op": "connect", "component": "R3", "pin": "\(gate)/\(pin)", "net": "SIG"],
            ["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 15, "y_mm": 10],
             "layer": 0, "width_mm": 0.2],
            ["op": "place_track", "from": ["x_mm": 15, "y_mm": 10], "to": ["x_mm": 15, "y_mm": 15],
             "layer": 0, "width_mm": 0.2, "net": "SIG"]
        ], to: HorizontalProjectArchive.completeProject(from: url), in: project).archive
        var reloaded = try HorizontalProject.loadSnapshot(of: seeded)
        reloaded.rebaseURLs(onto: project)
        let board = try boardJSON(in: seeded)
        XCTAssertEqual(board.dictionaryMap("tracks").count, 2)
        XCTAssertTrue(board.dictionaryMap("tracks").values.allSatisfy { $0["net"] == nil },
                      "The fixture's tracks store no net, as Horizon writes them")
        XCTAssertTrue(board.dictionaryMap("junctions").values.allSatisfy { $0["net"] == nil },
                      "The fixture's junctions store no net, as Horizon writes them")
        XCTAssertEqual(Set(try XCTUnwrap(reloaded.board).tracks.compactMap(\.netID)).count, 1,
                       "The loader puts the routing on the net of the pads it reaches")
        return Fixture(project: reloaded, archive: seeded, gate: gate, pin: pin)
    }
}
