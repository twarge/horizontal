import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A via's net comes one of two ways, as Horizon's does. A via with no
/// `net_set` takes the net of the copper it joins: its tracks, and through
/// them their pads. So when the schematic moves those pads to another net,
/// as a change of power rail does, the via goes with its tracks. A via with a
/// `net_set` holds that net itself and stands on it alone, as a stitching via
/// does, whatever its copper does.
///
/// Horizontal pinned every via it made for a track: the track tool's and the
/// router's (`BoardTrackRouting.throughVia`, `applyPushShoveCommit`), every
/// new via the writer wrote (`patchNewBoardVias` wrote `net_set` from the
/// net connectivity gave it), and every `place_via`. Horizon's router pins
/// none (`PNS_HORIZON_IFACE::AddItem`); only its Place Via and Set via net
/// do, on a net the user chose. A pinned via never followed its tracks: they
/// went to the new rail and it stayed on the old one, shorting them.
final class ViaTakesItsTracksNetUnlessSetTests: XCTestCase {
    private var url: URL!
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!
    private var part = ""
    private var padIDs: [String] = []

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("via-net-from-tracks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        part = try fabricateResistor(poolURL: url.appendingPathComponent("pool"))
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        // R1 and R2, pin 1 of each on the 3V3 rail, placed apart.
        try edit([
            ["op": "ensure_component", "refdes": "R1", "part": part],
            ["op": "ensure_component", "refdes": "R2", "part": part],
            ["op": "ensure_net", "name": "+3V3", "is_power": true],
            ["op": "ensure_net", "name": "+5V", "is_power": true],
            ["op": "connect", "component": "R1", "pin": "1", "net": "+3V3"],
            ["op": "connect", "component": "R2", "pin": "1", "net": "+3V3"],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R2", "x_mm": 40, "y_mm": 10],
        ])
    }

    /// A two-pin resistor with a top-copper pad for each pin, in the
    /// project's pool. Returns the part.
    private func fabricateResistor(poolURL: URL) throws -> String {
        let pin1 = HorizontalPoolItemFactory.newUUID(), pin2 = HorizontalPoolItemFactory.newUUID()
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.pins = [pin1: HorizontalUnitPin(id: pin1, primaryName: "1"), pin2: HorizontalUnitPin(id: pin2, primaryName: "2")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shape: HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        for (index, name) in ["1", "2"].enumerated() {
            let pad = HorizontalPoolItemFactory.newUUID()
            padIDs.append(pad)
            package.pads[pad] = HorizontalPad(
                id: pad, name: name, padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(
                    shift: HorizontalPoint(x: Double(index * 1_600_000 - 800_000), y: 0), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [padIDs[0]: HorizontalPartPadMapEntry(gateID: gate, pinID: pin1),
                       padIDs[1]: HorizontalPartPadMapEntry(gateID: gate, pinID: pin2)]
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        return part.uuid
    }

    // MARK: - Fixture

    /// One batch of ops, one archive edit, the project read again: how the
    /// app's own controls edit the schematic and board through the edit
    /// vocabulary (`HorizontalCanvasProjectEdit`).
    @discardableResult
    private func edit(_ ops: [JSONDictionary]) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project)
        archive = edited.archive
        try reload()
        return edited.changes
    }

    private func reload() throws {
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
    }

    /// The board canvas's commit and save: the edit's nets re-derived
    /// (`publishConnectivityResolvedEdit`), written through the applicator
    /// the document saves with, and the project read again.
    private func commit(_ board: HorizontalBoard) throws {
        let resolved = HorizontalBoardConnectivity.recompute(board)
        try HorizontalProjectJSONApplicator.apply(board: resolved, in: project, to: &archive)
        try reload()
    }

    /// A change of power rail in the schematic: R1's and R2's pin 1 leave
    /// +3V3 for +5V, so their pads do too.
    private func moveTheRailTo5V() throws {
        try edit([
            ["op": "connect", "component": "R1", "pin": "1", "net": "+5V"],
            ["op": "connect", "component": "R2", "pin": "1", "net": "+5V"],
        ])
    }

    private var board: HorizontalBoard {
        get throws { try XCTUnwrap(project.board) }
    }

    private func net(_ name: String) throws -> String {
        try XCTUnwrap(project.board?.netDetails.values.first { $0.name == name }?.id).lowercased()
    }

    private func componentID(_ refdes: String) throws -> String {
        try XCTUnwrap(project.board?.packages.first { $0.label == refdes }?.id)
    }

    /// The centre of `refdes`'s pad 1, where the track tool lands a route.
    private func padOne(_ refdes: String) throws -> HorizontalPoint {
        let key = "\(try componentID(refdes))/\(padIDs[0])".lowercased()
        return try XCTUnwrap(try board.packagePadPositions.first { $0.key.lowercased() == key }?.value)
    }

    private func boardFile() throws -> JSONDictionary {
        let name = try XCTUnwrap(project.boardFilename)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    private func viaEntries() throws -> [String: JSONDictionary] {
        try boardFile().dictionaryMap("vias")
    }

    private func normalized(_ id: String?) -> String? { id?.lowercased() }

    /// R1's pad 1 to R2's pad 1 the way the track tool lays it with `v`:
    /// down through a via to the bottom, along, and up through a second via
    /// to the top again. Returns the board with the route on it.
    private func routeDownAndUp(on start: HorizontalBoard) throws -> HorizontalBoard {
        var board = start
        let rail = try net("+3V3")
        let via = board.routeVia(netID: rail)
            ?? HorizontalBoardViaTemplate(padstackID: "test-via", diameter: 500_000, holeDiameter: 250_000)
        let from = try padOne("R1"), to = try padOne("R2")
        let down = HorizontalPoint(x: 20_000_000, y: 20_000_000)
        let up = HorizontalPoint(x: 30_000_000, y: 20_000_000)
        func legs(_ a: HorizontalPoint, _ b: HorizontalPoint) -> [BoardTrackSegmentSpec] {
            BoardTrackRouting.route(from: a, to: b, horizontalFirst: true, cornerStyle: .ninety)
        }
        var head = BoardTrackRouteHead(anchor: from, anchorJunctionID: nil, anchorOnPad: true, netID: rail,
                                       width: 250_000, layer: HorizontalBoardLayers.topCopper, placesVia: true)
        head = BoardTrackRouting.lay(legs(from, down), to: down, endsOnPad: false, via: via, from: head, on: &board).head
        XCTAssertEqual(head.layer, HorizontalBoardLayers.bottomCopper)
        head.placesVia = true
        head = BoardTrackRouting.lay(legs(down, up), to: up, endsOnPad: false, via: via, from: head, on: &board).head
        XCTAssertEqual(head.layer, HorizontalBoardLayers.topCopper)
        _ = BoardTrackRouting.lay(legs(up, to), to: to, endsOnPad: true, via: nil, from: head, on: &board)
        XCTAssertEqual(board.vias.count, 2)
        return board
    }

    // MARK: - From the tracks

    /// The case that went wrong: a route through two vias, the rail moved
    /// to +5V in the schematic, and the tracks went to +5V while the vias
    /// stayed on +3V3.
    func testARoutesViasFollowItsTracksWhenTheSchematicMovesTheRail() throws {
        try commit(try routeDownAndUp(on: try board))
        let rail = try net("+3V3"), five = try net("+5V")
        let routed = try board
        XCTAssertEqual(routed.vias.count, 2)
        XCTAssertTrue(routed.vias.allSatisfy { $0.netSetID == nil }, "the track tool pins no net on them")
        XCTAssertEqual(Set(routed.vias.compactMap { normalized($0.netID) }), [rail], "they take their tracks' net")
        XCTAssertTrue(try viaEntries().values.allSatisfy { $0["net_set"] == nil }, "and the file holds none for them")

        try moveTheRailTo5V()
        let moved = try board
        XCTAssertFalse(moved.tracks.isEmpty)
        XCTAssertTrue(moved.tracks.allSatisfy { normalized($0.netID) == five }, "the tracks follow their pads to +5V")
        XCTAssertTrue(moved.vias.allSatisfy { normalized($0.netID) == five }, "and so do the vias joining them")
        XCTAssertTrue(HorizontalBoardConnectivity.shorts(moved).isEmpty, "with no short left between the rails")

        // The canvas's next commit agrees, and writes no net onto them.
        let resolved = HorizontalBoardConnectivity.recompute(moved)
        XCTAssertTrue(resolved.vias.allSatisfy { normalized($0.netID) == five && $0.netSetID == nil })
        try commit(moved)
        XCTAssertTrue(try viaEntries().values.allSatisfy { $0["net_set"] == nil })
    }

    /// The via the track tool drops is written as Horizon's router writes
    /// one: the fields Via::serialize writes, and no `net_set`.
    func testARouteViaIsWrittenWithNoNetOfItsOwn() throws {
        var board = try board
        let rail = try net("+3V3")
        let via = board.routeVia(netID: rail)
            ?? HorizontalBoardViaTemplate(padstackID: "test-via", diameter: 500_000, holeDiameter: 250_000)
        let point = HorizontalPoint(x: 20_000_000, y: 10_000_000)
        let head = BoardTrackRouteHead(anchor: try padOne("R1"), anchorJunctionID: nil, anchorOnPad: true, netID: rail,
                                       width: 250_000, layer: HorizontalBoardLayers.topCopper, placesVia: true)
        _ = BoardTrackRouting.lay(BoardTrackRouting.route(from: head.anchor, to: point, horizontalFirst: true, cornerStyle: .ninety),
                                  to: point, endsOnPad: false, via: via, from: head, on: &board)
        let dropped = try XCTUnwrap(board.vias.first)
        XCTAssertNil(dropped.netSetID, "a route's via holds no net")
        XCTAssertEqual(normalized(dropped.netID), rail, "it is on its track's, which connectivity gives it")

        try commit(board)
        let entry = try XCTUnwrap(try viaEntries().first { $0.key.lowercased() == dropped.id.lowercased() }?.value)
        XCTAssertEqual(Set(entry.keys), ["junction", "padstack", "parameter_set", "from_rules", "source", "locked"],
                       "Via::serialize's fields for a through via from the rules, with no net_set")
        let read = try XCTUnwrap(try self.board.vias.first { $0.id.lowercased() == dropped.id.lowercased() })
        XCTAssertNil(read.netSetID)
        XCTAssertEqual(normalized(read.netID), rail, "read back on its track's net")
    }

    // MARK: - Set on the via

    /// A via that holds its net keeps it when the schematic moves the copper
    /// it joins: the copper is shorted to it and flagged, and the via is
    /// never unpinned by the collision.
    func testAViaSetOnANetKeepsItWhenTheSchematicMovesItsTracks() throws {
        var routed = try routeDownAndUp(on: try board)
        let rail = try net("+3V3"), five = try net("+5V")
        // Set Net… as the user would on the first via.
        routed.vias[0].netSetID = rail
        let pinnedID = routed.vias[0].id
        try commit(routed)
        XCTAssertEqual(normalized(try viaEntries().first { $0.key.lowercased() == pinnedID.lowercased() }?.value.string("net_set")), rail)

        try moveTheRailTo5V()
        let moved = try board
        let pinned = try XCTUnwrap(moved.vias.first { $0.id == pinnedID })
        XCTAssertEqual(normalized(pinned.netSetID), rail, "it holds the net set on it")
        XCTAssertEqual(normalized(pinned.netID), rail)

        let resolved = HorizontalBoardConnectivity.recompute(moved)
        let kept = try XCTUnwrap(resolved.vias.first { $0.id == pinnedID })
        XCTAssertEqual(normalized(kept.netSetID), rail, "the short between the rails never unpins it")
        XCTAssertEqual(normalized(kept.netID), rail)
        XCTAssertEqual(HorizontalBoardConnectivity.shorts(resolved).first?.nets, [rail, five], "it is flagged as a short")

        try commit(moved)
        XCTAssertEqual(normalized(try viaEntries().first { $0.key.lowercased() == pinnedID.lowercased() }?.value.string("net_set")), rail,
                       "and the file keeps it")
    }

    /// The inspector shows which way the via has its net: plain where its
    /// copper gives it, "(set)" with Clear Net where it holds one. Clear Net
    /// hands the net back to the copper, which takes the new rail.
    func testTheInspectorMarksASetNetAndClearNetLetsTheViaFollowItsTracks() throws {
        var routed = try routeDownAndUp(on: try board)
        let rail = try net("+3V3"), five = try net("+5V")
        let names = try board.netDetails
        func rows(_ id: String, in board: HorizontalBoard) throws -> [HorizontalSelectionProperty] {
            let via = try XCTUnwrap(board.vias.first { $0.id == id })
            return BoardCopperLockCommands.viaNetProperties(
                via, in: board, editable: true, name: { $0.flatMap { names[$0.lowercased()]?.name } }, options: { [] })
        }
        let pinnedID = routed.vias[0].id, freeID = routed.vias[1].id
        let free = HorizontalBoardConnectivity.recompute(routed)
        let freeRows = try rows(freeID, in: free)
        XCTAssertEqual(freeRows.map(\.label), ["Net"], "nothing to clear on a via its tracks give a net")
        XCTAssertEqual(freeRows.first?.value, .readOnly("+3V3"), "the net it takes, with no mark")

        routed.vias[0].netSetID = rail
        try commit(routed)
        try moveTheRailTo5V()
        var moved = HorizontalBoardConnectivity.recompute(try board)
        let pinnedRows = try rows(pinnedID, in: moved)
        XCTAssertEqual(pinnedRows.map(\.label), ["Net", "Clear Net"])
        XCTAssertEqual(pinnedRows.first?.value, .readOnly("+3V3 (set)"), "the net set on it, said to be")
        XCTAssertEqual(pinnedRows.last?.editor, .action)

        let ref = HorizontalSelectableRef(id: pinnedID, type: .via)
        XCTAssertTrue(BoardCopperLockCommands.apply(
            .bool(true), propertyID: BoardCopperLockCommands.clearViaNetPropertyID, to: ref, board: &moved))
        moved = HorizontalBoardConnectivity.recompute(moved)
        let cleared = try XCTUnwrap(moved.vias.first { $0.id == pinnedID })
        XCTAssertNil(cleared.netSetID)
        XCTAssertEqual(normalized(cleared.netID), five, "it takes its tracks' net, the new rail's")
        XCTAssertTrue(moved.tracks.allSatisfy { normalized($0.netID) == five }, "and the short is gone")
        XCTAssertEqual(try rows(pinnedID, in: moved).map(\.value), [.readOnly("+5V")])

        try commit(moved)
        XCTAssertNil(try viaEntries().first { $0.key.lowercased() == pinnedID.lowercased() }?.value["net_set"],
                     "Clear Net takes net_set off the file, as Horizon's Clear via net does")
    }

    // MARK: - place_via

    /// A via `place_via` puts between tracks of its batch takes their net;
    /// one standing alone holds the net it is placed on, as a stitching via
    /// must, or it would have none. `net_pinned` says which outright.
    func testPlaceViaPinsTheNetOnlyOnAViaStandingAlone() throws {
        let rail = try net("+3V3"), five = try net("+5V")
        let routed = try edit([
            ["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 20, "y_mm": 20], "layer": 0, "width_mm": 0.25],
            ["op": "place_via", "x_mm": 20, "y_mm": 20, "net": "+3V3"],
            ["op": "place_track", "from": ["x_mm": 20, "y_mm": 20], "to": ["component": "R2", "pad": "1"], "layer": -100, "width_mm": 0.25],
        ])
        let joined = try XCTUnwrap(routed[1]["via"] as? String)
        XCTAssertEqual(routed[1]["net_pinned"] as? Bool, false, "the reply says it takes its tracks' net")
        let alone = try XCTUnwrap(try edit([["op": "place_via", "x_mm": 50, "y_mm": 30, "net": "+3V3"]]).first)
        XCTAssertEqual(alone["net_pinned"] as? Bool, true)
        let stitching = try XCTUnwrap(alone["via"] as? String)
        let unpinned = try XCTUnwrap(try edit([["op": "place_via", "x_mm": 55, "y_mm": 30, "net": "+3V3", "net_pinned": false]]).first)
        XCTAssertEqual(unpinned["net_pinned"] as? Bool, false)

        let entries = try viaEntries()
        XCTAssertNil(entries[joined]?["net_set"], "the via between the tracks holds no net")
        XCTAssertEqual(normalized(entries[stitching]?.string("net_set")), rail, "the one standing alone holds +3V3")
        XCTAssertNil(entries[try XCTUnwrap(unpinned["via"] as? String)]?["net_set"])
        XCTAssertEqual(normalized(try board.vias.first { $0.id == joined }?.netID), rail, "from its tracks")

        try moveTheRailTo5V()
        let moved = try board
        XCTAssertEqual(normalized(moved.vias.first { $0.id == joined }?.netID), five, "it follows them to +5V")
        XCTAssertEqual(normalized(moved.vias.first { $0.id == stitching }?.netID), rail, "the stitching via stays")
    }

    /// `net_pinned` true holds the net even on a via its batch's tracks reach.
    func testPlaceViaPinsTheNetWhenAskedToEvenBetweenTracks() throws {
        let rail = try net("+3V3")
        let routed = try edit([
            ["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 20, "y_mm": 20], "layer": 0, "width_mm": 0.25],
            ["op": "place_via", "x_mm": 20, "y_mm": 20, "net": "+3V3", "net_pinned": true],
        ])
        XCTAssertEqual(routed[1]["net_pinned"] as? Bool, true)
        let id = try XCTUnwrap(routed[1]["via"] as? String)
        XCTAssertEqual(normalized(try viaEntries()[id]?.string("net_set")), rail)
    }
}
