import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Files Horizontal writes open in Horizon EDA 2.7.2 as the files it writes
/// itself: every via on a junction the board has, no empty padstack uuid, the
/// release's file versions, and the keys Horizon's serializers always write.
///
/// Board C, saved by Horizontal and opened in Horizon, lost a via ("couldn't
/// load Via … map::at": its junction had been folded into another at its
/// point) and a via definition ("invalid UUID": its padstack was ""), showed
/// its schematic as "created with an older version", and a save there filled
/// in symbols' and labels' keys, a line's width, and dropped empty net ties
/// and an unused tag name.
final class HorizontalHorizonFileConformanceTests: XCTestCase {
    private let mm = 1_000_000.0
    private let via = HorizontalBoardViaTemplate(
        padstackID: HorizontalProjectArchive.horizonPoolTentedCircularVia, diameter: 500_000, holeDiameter: 200_000,
        fromRules: false, parameterSet: ["via_diameter": 500_000, "hole_diameter": 200_000])

    private struct Fixture {
        var archive: HorizontalProjectArchive
        var project: HorizontalProject

        mutating func save(_ board: HorizontalBoard) throws -> HorizontalBoard {
            try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
            var reloaded = try HorizontalProject.loadSnapshot(of: archive)
            reloaded.rebaseURLs(onto: project)
            project = reloaded
            return try XCTUnwrap(project.board)
        }

        func json(_ path: String) throws -> [String: Any] {
            let data = try XCTUnwrap(archive.regularFileData(relativePath: path), "no \(path)")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("horizon-conformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        return Fixture(archive: try HorizontalProjectArchive.completeProject(from: url), project: try HorizontalProject.load(from: url))
    }

    private func viaJunction(_ viaID: String, in board: [String: Any]) -> String? {
        ((board["vias"] as? [String: Any])?[viaID] as? [String: Any])?["junction"] as? String
    }

    private func junctionPosition(_ id: String, in board: [String: Any]) -> [Int]? {
        (((board["junctions"] as? [String: Any])?[id] as? [String: Any])?["position"] as? [NSNumber])?.map(\.intValue)
    }

    // MARK: - Vias

    /// A track end moved onto a via keeps its own junction and folds the via's
    /// into it, as the move tool's merge does: the via goes on the junction
    /// now at its point, where it went on naming the one folded away.
    func testAViaWhoseJunctionWasFoldedGoesOnTheJunctionAtItsPoint() throws {
        var fixture = try fixture()
        var board = try XCTUnwrap(fixture.project.board)
        let point = HorizontalPoint(x: 10 * mm, y: 10 * mm)
        let dropped = BoardTrackRouting.dropVia(via, at: point, netID: nil, preferredJunctionID: nil, on: &board)
        board = try fixture.save(board)
        let viaID = try XCTUnwrap(board.vias.first?.id)
        XCTAssertEqual(viaJunction(viaID, in: try fixture.json("board.json")), dropped)

        board.junctions["moved"] = point
        BoardTrackRouting.mergeJunctions(at: point, preferredID: "moved", netID: nil, board: &board)
        XCTAssertNil(board.junctions[dropped], "the via's junction was folded into the one moved there")
        board = try fixture.save(board)

        let file = try fixture.json("board.json")
        XCTAssertEqual(viaJunction(viaID, in: file), "moved")
        XCTAssertEqual(junctionPosition("moved", in: file), [10_000_000, 10_000_000])
        XCTAssertNil(junctionPosition(dropped, in: file))
    }

    /// With no junction left at its point, the via's own is written back
    /// there, the same one save after save.
    func testAViaWithNoJunctionAtItsPointKeepsItsOwn() throws {
        var fixture = try fixture()
        var board = try XCTUnwrap(fixture.project.board)
        let point = HorizontalPoint(x: 5 * mm, y: 20 * mm)
        let dropped = BoardTrackRouting.dropVia(via, at: point, netID: nil, preferredJunctionID: nil, on: &board)
        board = try fixture.save(board)
        let viaID = try XCTUnwrap(board.vias.first?.id)

        board.junctions.removeValue(forKey: dropped)
        board = try fixture.save(board)
        var file = try fixture.json("board.json")
        XCTAssertEqual(viaJunction(viaID, in: file), dropped)
        XCTAssertEqual(junctionPosition(dropped, in: file), [5_000_000, 20_000_000])

        // A via new to the file with no junction at its point gets one, where
        // it was left out of the file.
        let lone = HorizontalMarker(
            id: "lone", position: HorizontalPoint(x: 30 * mm, y: 30 * mm), size: 500_000, holeSize: 200_000, layer: nil,
            padstackID: HorizontalProjectArchive.horizonPoolTentedCircularVia)
        board.vias.append(lone)
        board = try fixture.save(board)
        file = try fixture.json("board.json")
        let loneJunction = try XCTUnwrap(viaJunction("lone", in: file))
        XCTAssertEqual(junctionPosition(loneJunction, in: file), [30_000_000, 30_000_000])
    }

    // MARK: - Padstacks

    func testAnEmptyPadstackIsWrittenAsTheNullUUID() {
        let board: [String: Any] = [
            "type": "board",
            "rules": [
                "via": ["r": ["padstack": "", "enabled": true] as [String: Any]],
                "via_definitions": ["via_definitions": [
                    "d": ["name": "Via", "padstack": ""],
                    "kept": ["name": "Own", "padstack": HorizontalProjectArchive.horizonPoolCircularVia],
                ] as [String: Any]] as [String: Any],
            ] as [String: Any],
        ]
        let rules = HorizontalHorizonFileConformance.conformed(board)["rules"] as? [String: Any]
        let viaRule = (rules?["via"] as? [String: Any])?["r"] as? [String: Any]
        let definitions = (rules?["via_definitions"] as? [String: Any])?["via_definitions"] as? [String: Any]
        XCTAssertEqual(viaRule?["padstack"] as? String, HorizontalProjectArchive.nullUUID)
        XCTAssertEqual((definitions?["d"] as? [String: Any])?["padstack"] as? String, HorizontalProjectArchive.nullUUID)
        XCTAssertEqual((definitions?["kept"] as? [String: Any])?["padstack"] as? String, HorizontalProjectArchive.horizonPoolCircularVia)
    }

    func testTheRulesWindowFlagsAViaDefinitionWithNoPadstack() {
        let context = HorizontalBoardRuleContext(board: nil, netClasses: [])
        func titles(padstack: String) -> [String] {
            let rules: JSONDictionary = ["via_definitions": [
                "enabled": true, "order": -1,
                "via_definitions": ["d": ["name": "Via", "padstack": padstack] as JSONDictionary] as JSONDictionary,
            ] as JSONDictionary]
            return HorizontalBoardRulesValidator.validate(rules: rules, selectedKind: .viaDefinitions, context: context).map(\.title)
        }
        XCTAssertTrue(titles(padstack: "").contains("Via definition has no padstack"))
        XCTAssertTrue(titles(padstack: HorizontalProjectArchive.nullUUID).contains("Via definition has no padstack"))
        XCTAssertFalse(titles(padstack: HorizontalProjectArchive.horizonPoolCircularVia).contains("Via definition has no padstack"))
    }

    // MARK: - Versions

    func testFilesTakeHorizonsReleaseVersionAndKeepALaterOne() {
        func version(_ json: [String: Any]) -> Int? {
            (HorizontalHorizonFileConformance.conformed(json)["version"] as? NSNumber)?.intValue
        }
        XCTAssertEqual(version(["type": "board", "version": 18]), 21)
        XCTAssertEqual(version(["type": "board"]), 21)
        XCTAssertEqual(version(["type": "board", "version": 24]), 24, "a file from Horizon's master keeps its version")
        XCTAssertEqual(version(["type": "schematic_block", "version": 8]), 9)
        XCTAssertEqual(version(["type": "schematic_block", "version": 10]), 10)
        XCTAssertEqual(version(["type": "project"]), 3)
        XCTAssertNil(version(["type": "unit"]), "a pool item is left alone")
        XCTAssertEqual(HorizontalHorizonFileConformance.conformed(["type": "schematic"])["type"] as? String, "schematic_block")
    }

    /// A save changes only a file the edit changed, as Horizon changes a file
    /// only when it saves it: an old board saved with nothing changed keeps its
    /// version, and one an edit changed takes the release's.
    func testOnlyAFileTheEditChangedIsConformed() throws {
        var fixture = try fixture()
        // Saved once, so the board holds what the board writer adds to it.
        _ = try fixture.save(try XCTUnwrap(fixture.project.board))
        var board = try fixture.json("board.json")
        board["version"] = 18
        try fixture.archive.replaceRegularFileData(relativePath: "board.json", with: HorizontalHorizonJSONWriter.data(board))
        var snapshot = try HorizontalProject.loadSnapshot(of: fixture.archive)
        snapshot.rebaseURLs(onto: fixture.project)
        var model = try XCTUnwrap(snapshot.board)

        XCTAssertFalse(try HorizontalProjectJSONApplicator.apply(board: model, in: fixture.project, to: &fixture.archive))
        XCTAssertEqual((try fixture.json("board.json")["version"] as? NSNumber)?.intValue, 18)

        BoardTrackRouting.dropVia(via, at: HorizontalPoint(x: mm, y: mm), netID: nil, preferredJunctionID: nil, on: &model)
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: model, in: fixture.project, to: &fixture.archive))
        XCTAssertEqual((try fixture.json("board.json")["version"] as? NSNumber)?.intValue, 21)
    }

    /// A new project opens in Horizon 2.7.2 with nothing to migrate: its
    /// project file states a version and the pool uuid Horizon reads with
    /// at(), its schematic is a schematic_block at the release's version.
    func testANewProjectStatesHorizonsVersions() throws {
        let fixture = try fixture()
        let project = try fixture.json("Untitled.hprj")
        XCTAssertEqual((project["version"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(project["pool_uuid"] as? String, HorizontalProjectArchive.nullUUID)
        XCTAssertEqual((try fixture.json("board.json")["version"] as? NSNumber)?.intValue, 21)
        let schematic = try fixture.json("top_schematic.json")
        XCTAssertEqual((schematic["version"] as? NSNumber)?.intValue, 9)
        XCTAssertEqual(schematic["type"] as? String, "schematic_block")
        XCTAssertNotNil(fixture.project.schematic, "Horizontal reads it back")
    }

    // MARK: - Keys Horizon always writes

    func testSymbolsLabelsAndLinesTakeHorizonsDefaults() throws {
        let sheet: [String: Any] = [
            "symbols": ["s": ["component": "c", "gate": "g", "symbol": "y", "placement": [:] as [String: Any]] as [String: Any],
                        "own": ["smashed": true, "expand": 2, "display_all_pads": false, "texts": ["t"]] as [String: Any]],
            "net_labels": ["l": ["junction": "j", "orientation": "right"],
                           "port": ["junction": "k", "orientation": "left", "show_port": true, "size": 1_500_000] as [String: Any]],
            "lines": ["line": ["from": "a", "to": "b"]],
            "net_ties": [String: Any](),
        ]
        let schematic = HorizontalHorizonFileConformance.conformed(["type": "schematic_block", "sheets": ["sheet": sheet]])
        let conformed = try XCTUnwrap((schematic["sheets"] as? [String: Any])?["sheet"] as? [String: Any])
        let symbols = try XCTUnwrap(conformed["symbols"] as? [String: Any])
        let symbol = try XCTUnwrap(symbols["s"] as? [String: Any])
        XCTAssertEqual(symbol["smashed"] as? Bool, false)
        XCTAssertEqual(symbol["pin_display_mode"] as? String, "selected_only")
        XCTAssertEqual(symbol["display_directions"] as? Bool, false)
        XCTAssertEqual(symbol["display_all_pads"] as? Bool, true)
        XCTAssertEqual(symbol["expand"] as? Int, 0)
        XCTAssertEqual((symbol["texts"] as? [Any])?.count, 0)
        let own = try XCTUnwrap(symbols["own"] as? [String: Any])
        XCTAssertEqual(own["smashed"] as? Bool, true)
        XCTAssertEqual(own["expand"] as? Int, 2)
        XCTAssertEqual(own["display_all_pads"] as? Bool, false)
        XCTAssertEqual(own["texts"] as? [String], ["t"])

        let labels = try XCTUnwrap(conformed["net_labels"] as? [String: Any])
        let label = try XCTUnwrap(labels["l"] as? [String: Any])
        XCTAssertEqual(label["show_port"] as? Bool, false)
        XCTAssertEqual(label["offsheet_refs"] as? Bool, true)
        XCTAssertEqual(label["size"] as? Int, 2_500_000)
        let port = try XCTUnwrap(labels["port"] as? [String: Any])
        XCTAssertEqual(port["show_port"] as? Bool, true)
        XCTAssertEqual(port["size"] as? Int, 1_500_000)

        let line = try XCTUnwrap((conformed["lines"] as? [String: Any])?["line"] as? [String: Any])
        XCTAssertEqual(line["width"] as? Int, 0)
        XCTAssertEqual(line["layer"] as? Int, 0)
        XCTAssertNil(conformed["net_ties"], "Horizon writes a sheet's net ties only when it has some")

        let board = HorizontalHorizonFileConformance.conformed([
            "type": "board", "lines": ["line": ["from": "a", "to": "b", "layer": 20] as [String: Any]],
        ])
        let boardLine = try XCTUnwrap((board["lines"] as? [String: Any])?["line"] as? [String: Any])
        XCTAssertEqual(boardLine["width"] as? Int, 0)
        XCTAssertEqual(boardLine["layer"] as? Int, 20)
    }

    /// A block keeps the tag and group names its components use, as
    /// `Block::vacuum_group_tag_names` keeps them, and drops empty net ties.
    func testABlockDropsTagAndGroupNamesNoComponentUses() throws {
        let null = HorizontalProjectArchive.nullUUID
        let block = HorizontalHorizonFileConformance.conformed([
            "name": "Top", "net_class_default": "nc", "nets": [String: Any](),
            "components": [
                "a": ["tag": "T1", "group": "g1"],
                "b": ["tag": null, "group": null],
            ] as [String: Any],
            "tag_names": ["t1": "1", "t2": "2"],
            "group_names": ["G1": "Left", "g2": "Right", null: "None"],
            "net_ties": [String: Any](),
        ])
        XCTAssertEqual(block["tag_names"] as? [String: String], ["t1": "1"])
        XCTAssertEqual(block["group_names"] as? [String: String], ["G1": "Left"])
        XCTAssertNil(block["net_ties"])
        XCTAssertNil(block["version"], "Horizon versions no block")
    }

    // MARK: - Nets

    /// Horizon stores no net on a board junction or track, or on a sheet's
    /// junctions and wires; what does carry one — a plane, a hole, a via's
    /// net_set, a power symbol, a label's last net — keeps it.
    func testNoNetIsStoredOnAJunctionTrackOrWire() throws {
        let board = HorizontalHorizonFileConformance.conformed([
            "type": "board",
            "junctions": ["j": ["position": [0, 0], "net": "n"]],
            "tracks": ["t": ["layer": 0, "net": "n"] as [String: Any]],
            "vias": ["v": ["junction": "j", "net_set": "n"]],
            "planes": ["p": ["net": "n"]],
            "holes": ["h": ["net": "n"]],
        ])
        func item(_ json: [String: Any], _ table: String, _ id: String) -> [String: Any]? {
            (json[table] as? [String: Any])?[id] as? [String: Any]
        }
        XCTAssertNil(item(board, "junctions", "j")?["net"])
        XCTAssertNotNil(item(board, "junctions", "j")?["position"])
        XCTAssertNil(item(board, "tracks", "t")?["net"])
        XCTAssertEqual(item(board, "vias", "v")?["net_set"] as? String, "n")
        XCTAssertEqual(item(board, "planes", "p")?["net"] as? String, "n")
        XCTAssertEqual(item(board, "holes", "h")?["net"] as? String, "n")

        let schematic = HorizontalHorizonFileConformance.conformed(["type": "schematic_block", "sheets": ["s": [
            "junctions": ["j": ["position": [0, 0], "net": "n"]],
            "net_lines": ["w": ["from": ["junc": "j"], "to": ["junc": "k"], "net": "n"] as [String: Any]],
            "power_symbols": ["g": ["junction": "j", "net": "n"]],
            "net_labels": ["l": ["junction": "j", "last_net": "n"]],
        ] as [String: Any]]])
        let sheet = try XCTUnwrap((schematic["sheets"] as? [String: Any])?["s"] as? [String: Any])
        XCTAssertNil(item(sheet, "junctions", "j")?["net"])
        XCTAssertNil(item(sheet, "net_lines", "w")?["net"])
        XCTAssertEqual(item(sheet, "power_symbols", "g")?["net"] as? String, "n")
        XCTAssertEqual(item(sheet, "net_labels", "l")?["last_net"] as? String, "n")
        XCTAssertEqual(HorizontalHorizonFileConformance.withoutNetCaches(["type": "unit", "net": "n"])["net"] as? String, "n")
    }

    /// The board writer stores no net on a track it writes or a junction, as
    /// it did, and takes away one an earlier save left.
    func testTheBoardWriterStoresNoNetOnATrackOrJunction() throws {
        var fixture = try fixture()
        var board = try XCTUnwrap(fixture.project.board)
        let a = HorizontalPoint(x: 1 * mm, y: 1 * mm), b = HorizontalPoint(x: 9 * mm, y: 1 * mm)
        board.junctions = ["ja": a, "jb": b]
        board.junctionNetIDs = ["ja": "gnd", "jb": "gnd"]
        board.tracks = [HorizontalSegment(id: "t", from: a, to: b, width: 250_000, layer: HorizontalBoardLayers.topCopper,
                                          netID: "gnd", fromJunctionID: "ja", toJunctionID: "jb")]
        board = try fixture.save(board)
        var file = try fixture.json("board.json")
        XCTAssertNotNil((file["tracks"] as? [String: Any])?["t"])
        XCTAssertNil(((file["tracks"] as? [String: Any])?["t"] as? [String: Any])?["net"])
        XCTAssertNil(((file["junctions"] as? [String: Any])?["ja"] as? [String: Any])?["net"])

        // A cache an earlier save wrote goes with the next edit.
        var stale = file
        var junctions = try XCTUnwrap(stale["junctions"] as? [String: Any])
        junctions["ja"] = ["position": [1_000_000, 1_000_000], "net": "gnd"]
        stale["junctions"] = junctions
        try fixture.archive.replaceRegularFileData(relativePath: "board.json", with: HorizontalHorizonJSONWriter.data(stale))
        var snapshot = try HorizontalProject.loadSnapshot(of: fixture.archive)
        snapshot.rebaseURLs(onto: fixture.project)
        var model = try XCTUnwrap(snapshot.board)
        // A save that changes nothing leaves the file alone, cache and all.
        XCTAssertFalse(try HorizontalProjectJSONApplicator.apply(board: model, in: fixture.project, to: &fixture.archive))
        XCTAssertEqual(((try fixture.json("board.json")["junctions"] as? [String: Any])?["ja"] as? [String: Any])?["net"] as? String, "gnd")
        model.junctions["jc"] = HorizontalPoint(x: 5 * mm, y: 5 * mm)
        _ = try fixture.save(model)
        file = try fixture.json("board.json")
        XCTAssertNil(((file["junctions"] as? [String: Any])?["ja"] as? [String: Any])?["net"])
    }

    /// A schematic junction joined to nothing that carries a net has none,
    /// whatever net an earlier save cached on it, as Horizon has it.
    func testAStaleNetOnASchematicJunctionIsIgnored() throws {
        var fixture = try fixture()
        let ground = try XCTUnwrap((try fixture.json("top_block.json")["nets"] as? [String: Any])?.keys.first)
        var schematic = try fixture.json("top_schematic.json")
        var sheets = try XCTUnwrap(schematic["sheets"] as? [String: Any])
        let sheetID = try XCTUnwrap(sheets.keys.first)
        var sheet = try XCTUnwrap(sheets[sheetID] as? [String: Any])
        sheet["junctions"] = ["floating": ["position": [0, 0], "net": ground]]
        sheets[sheetID] = sheet
        schematic["sheets"] = sheets
        try fixture.archive.replaceRegularFileData(relativePath: "top_schematic.json", with: HorizontalHorizonJSONWriter.data(schematic))
        let loaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: fixture.archive).schematic?.sheets.first)
        XCTAssertNotNil(loaded.junctions["floating"])
        XCTAssertNil(loaded.junctionNetIDs["floating"])
    }
}

/// Over MCP, a net `place_junction` gives a junction stands for the rest of
/// its batch, so a wire drawn to it there carries it; nothing stores it, and
/// in a later edit a junction joined to no pin, label or power symbol has no
/// net, as in Horizon.
final class HorizontalMCPJunctionNetTests: XCTestCase {
    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("junction-nets-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        session = HorizontalDispatchSession()
        handle = try session.open(url: root).handle
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = args
        params["handle"] = handle
        if method == "apply" {
            params["expected_revision"] = try session.entry(handle: handle).revision
            params["operation_id"] = UUID().uuidString
        }
        return try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
    }

    private func sheet() throws -> JSONDictionary {
        let data = try Data(contentsOf: root.appendingPathComponent("top_schematic.json"))
        return try XCTUnwrap(try JSONHelper.loadDictionary(from: data).dictionaryMap("sheets").values.first)
    }

    func testAJunctionsNetHoldsForItsBatchAndIsNotStored() throws {
        let drawn = try call("apply", ["ops": [
            ["op": "place_junction", "id": "a", "net": "GND", "x_mm": 10, "y_mm": 10],
            ["op": "place_junction", "id": "b", "net": "GND", "x_mm": 20, "y_mm": 10],
            ["op": "draw_net_line", "from": ["kind": "junction", "junction": "a"], "to": ["kind": "junction", "junction": "b"]],
        ]])
        XCTAssertNil(drawn["error"], "\(drawn)")
        let wires = try sheet().dictionaryMap("net_lines")
        XCTAssertEqual(wires.count, 1)
        XCTAssertNil(wires.values.first?["net"], "a wire's net isn't stored")
        XCTAssertTrue(try sheet().dictionaryMap("junctions").values.allSatisfy { $0["net"] == nil })

        // Joined to nothing that carries one, the wiring has no net now.
        let listed = try XCTUnwrap(try call("list_junctions")["result"] as? [JSONDictionary])
        XCTAssertEqual(listed.count, 2)
        XCTAssertTrue(listed.allSatisfy { $0["net"] is NSNull || $0["net"] == nil }, "\(listed)")
        let ids = listed.compactMap { $0.string("id") }
        let refused = try call("apply", ["ops": [
            ["op": "draw_net_line", "from": ["kind": "junction", "junction": ids[0]], "to": ["kind": "junction", "junction": ids[1]]],
        ]])
        let message = (refused["error"] as? JSONDictionary)?.string("message") ?? ""
        XCTAssertTrue(message.contains("Neither end is on a net"), message)

        // A power symbol on the wiring gives it its net, as Horizon gives it.
        let marked = try call("apply", ["ops": [
            ["op": "place_power_symbol", "net": "GND", "x_mm": 10, "y_mm": 10],
        ]])
        XCTAssertNil(marked["error"], "\(marked)")
        let grounded = try XCTUnwrap(try call("list_junctions", ["net": "GND"])["result"] as? [JSONDictionary])
        XCTAssertTrue(Set(ids).isSubset(of: Set(grounded.compactMap { $0.string("id") })), "\(grounded)")
    }
}
