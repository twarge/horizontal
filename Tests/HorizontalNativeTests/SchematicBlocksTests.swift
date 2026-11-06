import XCTest
import PDFKit
import HorizontalProjectIO
@testable import HorizontalNative

/// Hierarchical blocks made in Horizontal, the way Horizon makes them: a
/// block added beside the top one, a port net drawn on its symbol, an
/// instance of it placed on a sheet; and the sheet edits — moving, turning,
/// wiring a port — reaching the files.
final class SchematicBlocksTests: XCTestCase {
    private var archive = HorizontalProjectArchive.newProject()
    private var project: HorizontalProject!
    private let mm = 1_000_000.0
    private let channelID = "0c0c0c0c-1111-4222-8333-444455556666"

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blocks-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Test.horizontal")
        try archive.write(to: url)
        project = try HorizontalProject.load(from: url)
    }

    /// Runs ops on `block` (the top block when nil) as the canvas runs them,
    /// and reloads the project from what they wrote.
    @discardableResult
    private func apply(_ ops: [JSONDictionary], block: String? = nil) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project, block: block)
        archive = edited.archive
        try reload()
        return edited.changes
    }

    private func reload() throws {
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
    }

    private func file(_ path: String) throws -> JSONDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: path), "no \(path)")) as? JSONDictionary)
    }

    private var topSheet: HorizontalSchematicSheet {
        get throws { try XCTUnwrap(project.schematic?.sheets.first) }
    }

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    /// A "Channel" block with one port, In, on the left of its symbol, and an
    /// instance of it drawn on the top sheet at (50, 50).
    private func placeChannel() throws -> (instance: String, port: String, net: String) {
        try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        let changes = try apply([
            ["op": "ensure_net", "name": "In"],
            ["op": "set_net_port", "net": "In", "port_direction": "input"],
            ["op": "place_block_port", "net": "In", "x_mm": -10, "y_mm": 0, "orientation": "left"],
        ], block: "Channel")
        let net = try XCTUnwrap(changes.first?["net"] as? String)
        let added = try apply([["op": "add_block_instance", "block": "Channel"]])
        let instance = try XCTUnwrap(added.first?["block_instance"] as? String)
        try apply([["op": "place_block_symbol", "instance": instance, "x_mm": 50, "y_mm": 50]])
        return (instance, try XCTUnwrap(HorizontalBlockSymbolPortID.uuid(forNet: net)), net)
    }

    // MARK: - Blocks

    func testHorizonsPortUUIDIsDerivedFromItsNet() {
        // Board N's Channel block, as Horizon wrote it.
        XCTAssertEqual(HorizontalBlockSymbolPortID.uuid(forNet: "6d439051-f0a2-411a-a7a7-02f07fbf58ee"),
                       "91243938-caea-57ef-9c04-c6d011e65c49")
    }

    func testAddBlockFilesTheBlockAsHorizonDoes() throws {
        let changes = try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        XCTAssertEqual(changes.first?["block"] as? String, channelID)

        let entry = try XCTUnwrap(try file("blocks.json").dictionaryMap("blocks")[channelID])
        XCTAssertEqual(entry.string("block_filename"), "blocks/\(channelID)/block.json")
        XCTAssertEqual(entry.string("schematic_filename"), "blocks/\(channelID)/schematic.json")
        XCTAssertEqual(entry.string("symbol_filename"), "blocks/\(channelID)/symbol.json")

        let top = try file("top_block.json")
        let block = try file("blocks/\(channelID)/block.json")
        XCTAssertEqual(block.string("name"), "Channel")
        XCTAssertEqual(block.string("net_class_default"), top.string("net_class_default"), "the top's default class, as Horizon shares it")
        for key in ["nets", "components", "buses", "block_instances"] {
            XCTAssertNotNil(block[key] as? JSONDictionary, "Horizon's loader needs \(key)")
        }

        let schematic = try file("blocks/\(channelID)/schematic.json")
        XCTAssertEqual(schematic.string("type"), "schematic_block")
        XCTAssertEqual(schematic.string("block"), channelID)
        XCTAssertEqual(schematic.dictionaryMap("sheets").values.map { $0.string("name") }, ["First sheet"])

        let symbol = try file("blocks/\(channelID)/symbol.json")
        XCTAssertEqual(symbol.string("type"), "block_symbol")
        XCTAssertEqual(symbol.dictionaryMap("lines").count, 4, "Horizon's template box")
        XCTAssertEqual(Set(symbol.dictionaryMap("texts").values.compactMap { $0.string("text") }), ["$REFDES", "$NAME"])

        let loaded = try XCTUnwrap(project.blocks.first { $0.uuid == channelID })
        XCTAssertEqual(loaded.displayName, "Channel", "named by its file's name, not its file")
        XCTAssertEqual(project.schematics.first { $0.block.uuid == channelID }?.schematic.sheets.map(\.name), ["First sheet"])
    }

    func testABlockIsNamedByItsNameOrItsFile() throws {
        try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        let blocks = project.blocks
        XCTAssertEqual(HorizontalProjectBlock.matching("channel", in: blocks).map(\.uuid), [channelID])
        XCTAssertEqual(HorizontalProjectBlock.matching(channelID.uppercased(), in: blocks).map(\.uuid), [channelID])
        // Horizon's layout calls every block's file block.json.
        XCTAssertEqual(HorizontalProjectBlock.matching("block", in: blocks).map(\.uuid), [channelID])

        try apply([["op": "rename_block", "block": "Channel", "name": "Filter"]])
        XCTAssertEqual(project.blocks.first { $0.uuid == channelID }?.displayName, "Filter")
    }

    func testAPlacedInstanceDrawsItsPortsAndIsMapped() throws {
        let placed = try placeChannel()
        let instance = try XCTUnwrap(try file("top_block.json").dictionaryMap("block_instances")[placed.instance])
        XCTAssertEqual(instance.string("refdes"), "I?", "as Horizon names a new instance")
        XCTAssertEqual(instance.string("block"), channelID)
        // Horizon's board reads a mapping for every instance path.
        XCTAssertEqual(try file("top_block.json").dictionaryMap("block_instance_mappings")[placed.instance]?.string("block"), channelID)

        let port = try XCTUnwrap(try file("blocks/\(channelID)/symbol.json").dictionaryMap("ports")[placed.port])
        XCTAssertEqual(port.string("net"), placed.net)
        XCTAssertEqual(port.string("orientation"), "left")

        let sheet = try topSheet
        let symbol = try XCTUnwrap(sheet.blockSymbols.first)
        XCTAssertEqual(sheet.blockSymbols.count, 1)
        XCTAssertEqual(symbol.instanceID, placed.instance)
        XCTAssertEqual(symbol.portNets, [placed.port: placed.net])
        XCTAssertEqual(sheet.blockSymbolPortEnds(symbol.id)[placed.port]?.point, point(40, 50))
        XCTAssertTrue(sheet.blockSymbolTexts.contains { $0.text == "Channel" }, "$NAME draws the block's name")
    }

    func testABlockCannotUseABlockThatUsesIt() throws {
        let second = "0d0d0d0d-1111-4222-8333-444455556666"
        try apply([["op": "add_block", "name": "Channel", "id": channelID], ["op": "add_block", "name": "Stage", "id": second]])
        try apply([["op": "add_block_instance", "block": "Channel"]], block: "Stage")
        XCTAssertThrowsError(try apply([["op": "add_block_instance", "block": "Stage"]], block: "Channel"))
        XCTAssertThrowsError(try apply([["op": "add_block_instance", "block": "Channel"]], block: "Channel"))

        // Stage inside the top: the paths through it reach Channel too.
        let placed = try apply([["op": "add_block_instance", "block": "Stage"]])
        let stage = try XCTUnwrap(placed.first?["block_instance"] as? String)
        let mappings = try file("top_block.json").dictionaryMap("block_instance_mappings")
        XCTAssertEqual(mappings[stage]?.string("block"), second)
        XCTAssertEqual(mappings.filter { $0.key.hasPrefix(stage + "/") }.values.map { $0.string("block") }, [channelID])
    }

    func testABlockInUseCannotBeRemoved() throws {
        let placed = try placeChannel()
        XCTAssertThrowsError(try apply([["op": "remove_block", "block": "Channel"]]))
        XCTAssertThrowsError(try apply([["op": "remove_block", "block": project.blocks.first(where: \.isTop)!.uuid]]))

        try apply([["op": "remove_block_instance", "instance": placed.instance]])
        XCTAssertTrue(try file("top_block.json").dictionaryMap("block_instance_mappings").isEmpty)
        try apply([["op": "remove_block", "block": "Channel"]])
        XCTAssertNil(archive.regularFileData(relativePath: "blocks/\(channelID)/block.json"))
        XCTAssertNil(try file("blocks.json").dictionaryMap("blocks")[channelID])
        XCTAssertFalse(project.blocks.contains { $0.uuid == channelID })
    }

    func testAPortStopsBeingOneWithItsWiring() throws {
        let placed = try placeChannel()
        try apply([["op": "connect_block_port", "instance": placed.instance, "port": "In", "net": "SIG", "create_net": true]])
        XCTAssertNotNil(try file("top_block.json").dictionaryMap("block_instances")[placed.instance]?.dictionaryMap("connections")[placed.net])

        let changes = try apply([["op": "set_net_port", "net": "In", "is_port": false]], block: "Channel")
        XCTAssertEqual(changes.first?["port_removed"] as? Bool, true)
        XCTAssertNil(try file("blocks/\(channelID)/symbol.json").dictionaryMap("ports")[placed.port])
        XCTAssertNil(try file("top_block.json").dictionaryMap("block_instances")[placed.instance]?.dictionaryMap("connections")[placed.net])
    }

    func testAPortIsMarkedNotConnected() throws {
        let placed = try placeChannel()
        try apply([["op": "connect_block_port", "instance": placed.instance, "port": "In", "nc": true]])
        let connection = try XCTUnwrap(try file("top_block.json").dictionaryMap("block_instances")[placed.instance]?.dictionaryMap("connections")[placed.net])
        XCTAssertTrue(connection["net"] is NSNull)
        XCTAssertEqual(try topSheet.blockSymbols.first?.connection(ofPort: placed.port), .notConnected)

        try apply([["op": "disconnect_block_port", "instance": placed.instance, "port": "In"]])
        XCTAssertNil(try topSheet.blockSymbols.first?.connection(ofPort: placed.port))
        try apply([["op": "set_block_instance", "instance": placed.instance, "refdes": "I7"]])
        XCTAssertTrue(try topSheet.blockSymbolTexts.contains { $0.text == "I7" })
    }

    func testAPortNetsLabelShowsItsPort() throws {
        _ = try placeChannel()
        let changes = try apply([["op": "place_net_label", "net": "In", "x_mm": 20, "y_mm": 10, "show_port": true]], block: "Channel")
        let labelID = try XCTUnwrap(changes.first?["net_label"] as? String)
        func label() throws -> JSONDictionary? {
            try file("blocks/\(channelID)/schematic.json").dictionaryMap("sheets").values
                .compactMap { $0.dictionaryMap("net_labels")[labelID] }.first
        }
        XCTAssertEqual(try label()?.bool("show_port"), true)
        try apply([["op": "place_net_label", "id": labelID, "show_port": false]], block: "Channel")
        XCTAssertEqual(try label()?.bool("show_port"), false)
    }

    // MARK: - Sheet edits

    private func save(_ sheet: HorizontalSchematicSheet) throws {
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        try reload()
    }

    func testAMovedAndTurnedBlockSymbolIsSaved() throws {
        let placed = try placeChannel()
        var sheet = try topSheet
        let id = try XCTUnwrap(sheet.blockSymbols.first?.id)
        sheet.shiftBlockSymbol(id, by: point(10, 0))
        let turned = HorizontalPlacementTransform(shift: point(60, 50), angle: 16_384, mirrored: false)
        let moved = sheet.placeBlockSymbol(id, at: turned)
        XCTAssertEqual(moved.first?.from, point(50, 50))
        try save(sheet)

        let placement = try XCTUnwrap(try file("top_schematic.json").dictionaryMap("sheets").values.first?.dictionaryMap("block_symbols")[id]?.dictionary("placement"))
        XCTAssertEqual(placement.int("angle"), 16_384)
        XCTAssertEqual(placement.point("shift"), point(60, 50))
        // A quarter turn takes the port on the left to the bottom.
        XCTAssertEqual(try topSheet.blockSymbolPortEnds(id)[placed.port]?.point, point(60, 40))
    }

    func testAWireToAPortOnNoNetConnectsItAndItsDeletionDisconnectsIt() throws {
        let placed = try placeChannel()
        var session = HorizontalSchematicWireTool.Session(sheet: try topSheet)
        XCTAssertEqual(session.click(at: point(40, 50)), .done, "a port on no net starts a wire, as in Horizon")
        XCTAssertEqual(session.click(at: point(30, 50)), .done)
        var sheet = session.sheet
        let touched = sheet.touchedPointKeys(since: session.originalSheet)
        sheet.connectCoincident(at: touched)
        sheet.spreadNets(touching: touched)
        let symbolID = try XCTUnwrap(sheet.blockSymbols.first?.id)
        let net = try XCTUnwrap(sheet.blockSymbols.first?.connection(ofPort: placed.port)?.netID, "the port got a net")
        XCTAssertEqual(sheet.blockSymbolPortEnds(symbolID)[placed.port]?.netID, net)
        try save(sheet)

        let connection = try file("top_block.json").dictionaryMap("block_instances")[placed.instance]?.dictionaryMap("connections")[placed.net]
        XCTAssertEqual(connection?.string("net"), net)
        XCTAssertNotNil(try file("top_block.json").dictionaryMap("nets")[net], "the new net is the block's")

        // Horizon's MCP side names the port by its own uuid.
        let sheetJSON = try XCTUnwrap(try file("top_schematic.json").dictionaryMap("sheets").values.first)
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheetJSON, block: try file("top_block.json"))
        XCTAssertEqual(connectivity.net(at: ["port": "\(symbolID)/\(placed.port)"]), net)

        var deleting = try topSheet
        let before = deleting.netLines
        deleting.netLines.removeAll()
        deleting.disconnectPortsLeftWithoutWires(netLinesBefore: before)
        XCTAssertNil(deleting.blockSymbols.first?.connection(ofPort: placed.port))
        try save(deleting)
        XCTAssertNil(try file("top_block.json").dictionaryMap("block_instances")[placed.instance]?.dictionaryMap("connections")[placed.net])
    }

    func testTheMCPWiresToAPortAndConnectsItAsTheWireToolDoes() throws {
        let placed = try placeChannel()
        let junction = "5e5e5e5e-1111-4222-8333-444455556666", other = "6f6f6f6f-1111-4222-8333-444455556666"
        let changes = try apply([
            ["op": "ensure_net", "name": "SIG"],
            ["op": "place_junction", "id": junction, "net": "SIG", "x_mm": 30, "y_mm": 50],
            ["op": "draw_net_line", "from": ["kind": "port", "instance": "I?", "port": "In"],
             "to": ["kind": "junction", "junction": junction]],
        ])
        let net = try XCTUnwrap(changes.first?["net"] as? String)
        let wire = try XCTUnwrap(changes.last)
        XCTAssertEqual(wire["net"] as? String, net)
        XCTAssertEqual((wire["connected_ports"] as? [JSONDictionary])?.first?["port"] as? String, placed.net)
        let connection = try file("top_block.json").dictionaryMap("block_instances")[placed.instance]?.dictionaryMap("connections")[placed.net]
        XCTAssertEqual(connection?.string("net"), net, "the port on no net took the wire's")

        let symbolID = try XCTUnwrap(try topSheet.blockSymbols.first?.id)
        let sheetJSON = try XCTUnwrap(try file("top_schematic.json").dictionaryMap("sheets").values.first)
        let line = try XCTUnwrap(sheetJSON.dictionaryMap("net_lines")[XCTUnwrap(wire["net_line"] as? String)])
        XCTAssertEqual(line.dictionary("from")?.string("port"), "\(symbolID)/\(placed.port)")
        XCTAssertEqual(HorizontalSchematicNetConnectivity(sheet: sheetJSON, block: try file("top_block.json"))
            .net(at: ["port": "\(symbolID)/\(placed.port)"]), net)

        // Retargeting the junction end reads the port end back as a port.
        let moved = "7a7a7a7a-1111-4222-8333-444455556666"
        let retarget = try apply([
            ["op": "place_junction", "id": moved, "net": "SIG", "x_mm": 30, "y_mm": 40],
            ["op": "set_net_line_endpoint", "line": try XCTUnwrap(wire["net_line"] as? String), "end": "to",
             "endpoint": ["kind": "junction", "junction": moved]],
        ])
        XCTAssertEqual(retarget.last?["net"] as? String, net)

        // A port on another net, or marked not connected, takes no wire. A
        // junction joined to nothing is on the net place_junction gives it
        // only in that batch, as Horizon stores none.
        try apply([["op": "ensure_net", "name": "OTHER"]])
        XCTAssertThrowsError(try apply([["op": "place_junction", "id": other, "net": "OTHER", "x_mm": 30, "y_mm": 60],
                                        ["op": "draw_net_line", "from": ["kind": "port", "instance": placed.instance, "port": "In"],
                                         "to": ["kind": "junction", "junction": other]]]))
        try apply([["op": "place_junction", "id": other, "net": "OTHER", "x_mm": 30, "y_mm": 60]])
        try apply([["op": "disconnect_block_port", "instance": placed.instance, "port": "In"],
                   ["op": "connect_block_port", "instance": placed.instance, "port": "In", "nc": true]])
        XCTAssertThrowsError(try apply([["op": "draw_net_line", "from": ["kind": "port", "instance": placed.instance, "port": "In"],
                                         "to": ["kind": "junction", "junction": other]]])) { error in
            XCTAssertTrue("\(error)".contains("not connected"), "\(error)")
        }
    }

    func testANoConnectPortRefusesAWire() throws {
        let placed = try placeChannel()
        try apply([["op": "connect_block_port", "instance": placed.instance, "port": "In", "nc": true]])
        var session = HorizontalSchematicWireTool.Session(sheet: try topSheet)
        guard case .refused = session.click(at: point(40, 50)) else {
            return XCTFail("an NC port takes no wire")
        }
    }

    // MARK: - Block symbol editor

    private func editorSymbol() throws -> HorizontalBlockSymbol {
        let symbolJSON = try file("blocks/\(channelID)/symbol.json")
        return try HorizontalBlockSymbol(symbolJSON: symbolJSON, blockJSON: try file("blocks/\(channelID)/block.json"), name: "Channel")
    }

    func testTheBlockSymbolEditorOffersThePortsStillToDraw() throws {
        try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        try apply([
            ["op": "ensure_net", "name": "In"], ["op": "set_net_port", "net": "In"],
            ["op": "ensure_net", "name": "Out"], ["op": "set_net_port", "net": "Out", "port_direction": "output"],
        ], block: "Channel")
        let blockSymbol = try editorSymbol()
        XCTAssertEqual(blockSymbol.unplacedPortNames, ["In", "Out"])
        let sheet = blockSymbol.makeSheet(poolURL: project.baseURL.appendingPathComponent("pool"))
        XCTAssertEqual(Set(sheet.placeableObjects.map(\.label)), ["In", "Out"], "the unplaced column lists the port nets")
        XCTAssertEqual(sheet.drawingLines.count, 4, "the template box")

        // Horizon's Place Port: the editor's pin for Out becomes Out's port.
        let out = try XCTUnwrap(blockSymbol.portNets.first { $0.value.name == "Out" })
        var edited = sheet
        edited.editablePins.append(HorizontalSymbolPin(id: out.key, position: point(10, 0), orientation: .right, padVisible: false))
        let json = blockSymbol.applying(sheet: edited).json()
        let port = try XCTUnwrap(json.dictionaryMap("ports")[out.key])
        XCTAssertEqual(port.string("net"), out.value.netID)
        XCTAssertEqual(port.string("orientation"), "right")
        XCTAssertEqual(port.point("position"), point(10, 0))
        XCTAssertEqual(json.string("type"), "block_symbol")
        XCTAssertEqual(json.dictionaryMap("lines").count, 4)
        XCTAssertNil(json["polygons"], "a block symbol has none")

        // Written and read back, it is what was written, so the editor
        // doesn't take its own save for a change from outside.
        try HorizontalProjectJSONApplicator.apply(blockSymbol: json, symbolURL: project.baseURL.appendingPathComponent("blocks/\(channelID)/symbol.json"),
                                                  in: project, to: &archive)
        XCTAssertEqual(try editorSymbol().sourceJSON, HorizontalPreservedJSON(json))
        XCTAssertEqual(try editorSymbol().unplacedPortNames, ["In"])
    }

    func testTheBlockSymbolEditorChecksItsPorts() throws {
        _ = try placeChannel()
        XCTAssertEqual(try editorSymbol().validationIssues(), [], "the template with In on its left edge")

        try apply([
            ["op": "ensure_net", "name": "Out"], ["op": "set_net_port", "net": "Out", "port_direction": "output"],
            ["op": "ensure_net", "name": "Clk"], ["op": "set_net_port", "net": "Clk"],
            ["op": "place_block_port", "net": "Clk", "x_mm": -10, "y_mm": 0.5, "orientation": "left"],
        ], block: "Channel")
        let messages = try editorSymbol().validationIssues().map(\.message)
        XCTAssertTrue(messages.contains("Port Out is not placed"), "\(messages)")
        XCTAssertTrue(messages.contains("Port Clk is off-grid, residual: 0 mm, 0.5 mm"), "\(messages)")
        XCTAssertFalse(messages.contains { $0.contains("reference designators") }, "the template has its $REFDES")
    }

    // MARK: - The symbol's box

    private var symbolPath: String { "blocks/\(channelID)/symbol.json" }

    private func boxMM(_ change: JSONDictionary?, _ key: String = "box_mm") -> [Double]? {
        guard let box = change?[key] as? JSONDictionary else { return nil }
        return ["min_x_mm", "min_y_mm", "max_x_mm", "max_y_mm"].compactMap { box.double($0) }
    }

    private func corners(_ symbol: JSONDictionary) -> Set<HorizontalPoint> {
        Set(symbol.dictionaryMap("junctions").values.compactMap { $0.point("position") })
    }

    private func textShift(_ symbol: JSONDictionary, _ text: String) -> HorizontalPoint? {
        symbol.dictionaryMap("texts").values.first { $0.string("text") == text }?.dictionary("placement")?.point("shift")
    }

    /// Writes the Channel's symbol as given, as the block symbol editor saves one.
    private func writeSymbol(_ json: JSONDictionary) throws {
        try HorizontalProjectJSONApplicator.apply(blockSymbol: json, symbolURL: project.baseURL.appendingPathComponent(symbolPath),
                                                  in: project, to: &archive)
        try reload()
    }

    /// Board A's ADC Converter, as the template left it: ports 2.5 mm long at
    /// x = ±12.5, from y = -7.5 to 7.5, so their inner ends at ±10 sit
    /// outside the template's 15 × 10 mm box.
    private func portsOutsideTheTemplate() throws {
        var ops: [JSONDictionary] = [["op": "place_block_port", "net": "In", "x_mm": -12.5, "y_mm": 5, "orientation": "left"]]
        for (name, x, y, side) in [("Clk", -12.5, -7.5, "left"), ("Out", 12.5, 7.5, "right"), ("Ref", 12.5, 0.0, "right")] {
            ops += [["op": "ensure_net", "name": name], ["op": "set_net_port", "net": name],
                    ["op": "place_block_port", "net": name, "x_mm": x, "y_mm": y, "orientation": side]]
        }
        try apply(ops, block: "Channel")
    }

    func testABlockSymbolBoxIsRedrawnAndItsTextsFollow() throws {
        _ = try placeChannel()
        let before = try file(symbolPath)
        let change = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "min_x_mm": -10, "min_y_mm": -10,
                                               "max_x_mm": 10, "max_y_mm": 10]], block: "Channel").first)
        XCTAssertEqual(boxMM(change), [-10, -10, 10, 10])
        XCTAssertEqual(boxMM(change, "previous_box_mm"), [-7.5, -5, 7.5, 5], "the template's")
        XCTAssertEqual(change["texts_moved"] as? [String], ["$NAME", "$REFDES"])
        XCTAssertEqual(change["ports_off_box"] as? [String], ["In"], "In's inner end, at x = -7.5, is inside the box now")
        XCTAssertEqual(change["changed"] as? Bool, true)

        let symbol = try file(symbolPath)
        XCTAssertEqual(Set(symbol.dictionaryMap("junctions").keys), Set(before.dictionaryMap("junctions").keys), "the corners keep their uuids")
        XCTAssertEqual(symbol["lines"] as? NSDictionary, before["lines"] as? NSDictionary, "and so do the lines between them")
        XCTAssertEqual(corners(symbol), [point(-10, -10), point(10, -10), point(10, 10), point(-10, 10)])
        XCTAssertEqual(textShift(symbol, "$REFDES"), point(-10, 11.25), "a grid step above the top-left corner")
        XCTAssertEqual(textShift(symbol, "$NAME"), point(-10, -11.25), "and below the bottom-left")
        XCTAssertEqual(Set(symbol.dictionaryMap("texts").values.compactMap { $0.string("origin") }), ["center"], "as they were")
        XCTAssertEqual(symbol["ports"] as? NSDictionary, before["ports"] as? NSDictionary, "the ports stay")

        // The instance at (50, 50) is drawn with the new box.
        let sheet = try topSheet
        let id = try XCTUnwrap(sheet.blockSymbols.first?.id)
        let drawn = Set(sheet.blockSymbolLines.filter { $0.id.hasPrefix(id + "/") }.flatMap { [$0.from, $0.to] })
        XCTAssertEqual(drawn, [point(40, 40), point(60, 40), point(60, 60), point(40, 60)])
        XCTAssertEqual(sheet.blockSymbolTexts.first { $0.text == "Channel" }?.position, point(40, 38.75))
        XCTAssertEqual(sheet.blockSymbolTexts.first { $0.text == "I?" }?.position, point(40, 61.25))

        // Edit Block Symbol opens it as that box, and saves it unchanged.
        let editor = try editorSymbol()
        let editorSheet = editor.makeSheet(poolURL: project.baseURL.appendingPathComponent("pool"))
        XCTAssertEqual(Set(editorSheet.drawingLines.flatMap { [$0.from, $0.to] }), [point(-10, -10), point(10, -10), point(10, 10), point(-10, 10)])
        XCTAssertEqual(corners(editor.applying(sheet: editorSheet).json()), corners(symbol))

        // The same box again changes nothing.
        let again = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "max_x_mm": 10]], block: "Channel").first)
        XCTAssertEqual(again["changed"] as? Bool, false)
    }

    func testABlockSymbolBoxFitsItsPorts() throws {
        _ = try placeChannel()
        try portsOutsideTheTemplate()
        let fitted = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "fit_ports": true]], block: "Channel").first)
        XCTAssertEqual(boxMM(fitted), [-10, -10, 10, 10],
                       "the left and right sides through the ports' inner ends, the top and bottom 2.5 mm past the outermost ports")
        XCTAssertEqual(fitted["fitted_to_ports"] as? Int, 4)
        XCTAssertNil(fitted["ports_off_box"], "every port ends on its side")
        XCTAssertEqual(textShift(try file(symbolPath), "$REFDES"), point(-10, 11.25))
        XCTAssertEqual(textShift(try file(symbolPath), "$NAME"), point(-10, -11.25))

        // A margin of its own, and a side given wins over the fit.
        let wider = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "fit_ports": true, "margin_mm": 5, "max_x_mm": 15]],
                                            block: "Channel").first)
        XCTAssertEqual(boxMM(wider), [-10, -12.5, 15, 12.5])
        XCTAssertEqual(wider["ports_off_box"] as? [String], ["Out", "Ref"], "their inner ends stop 5 mm short of the right side")

        // A side alone moves alone, and the texts can stay.
        let taller = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "max_y_mm": 20, "move_texts": false]], block: "Channel").first)
        XCTAssertEqual(boxMM(taller), [-10, -12.5, 15, 20])
        XCTAssertNil(taller["texts_moved"])
        XCTAssertEqual(textShift(try file(symbolPath), "$REFDES"), point(-10, 13.75), "where the last box put it")
    }

    func testTheTopBlockHasNoSymbolBoxAndABoxNeedsSides() throws {
        _ = try placeChannel()
        func refusal(_ op: JSONDictionary, block: String? = "Channel") -> String {
            do {
                try apply([op], block: block)
                return "applied"
            } catch {
                return (error as? HorizontalDispatchError)?.message ?? "\(error)"
            }
        }
        XCTAssertTrue(refusal(["op": "set_block_symbol_box", "fit_ports": true], block: nil).contains("The top block has no symbol"))
        XCTAssertTrue(refusal(["op": "set_block_symbol_box"]).contains("needs the box"))
        XCTAssertTrue(refusal(["op": "set_block_symbol_box", "min_x_mm": 10, "max_x_mm": -10]).contains("encloses nothing"))
        XCTAssertTrue(refusal(["op": "set_block_symbol_box", "max_y_mm": 10, "margin_mm": 1]).contains("pass fit_ports"))
        XCTAssertTrue(refusal(["op": "set_block_symbol_box", "fit_ports": true, "margin_mm": -1]).contains("negative"))
        XCTAssertTrue(refusal(["op": "set_block_symbol_box", "max_y_mm": "10"]).contains("number"))
        XCTAssertEqual(corners(try file(symbolPath)), [point(-7.5, -5), point(7.5, -5), point(7.5, 5), point(-7.5, 5)], "nothing written")
    }

    func testASymbolWithoutABoxGetsOneAndADrawingWithoutOneIsRefused() throws {
        _ = try placeChannel()
        var bare = try file(symbolPath)
        bare["junctions"] = JSONDictionary()
        bare["lines"] = JSONDictionary()
        try writeSymbol(bare)
        XCTAssertThrowsError(try apply([["op": "set_block_symbol_box", "max_y_mm": 10]], block: "Channel"), "no box to keep the other sides of")
        let drawn = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "min_x_mm": -10, "min_y_mm": -5, "max_x_mm": 10, "max_y_mm": 5]],
                                            block: "Channel").first)
        XCTAssertEqual(drawn["drawn"] as? Bool, true)
        XCTAssertTrue(drawn["previous_box_mm"] is NSNull)
        XCTAssertEqual(try file(symbolPath).dictionaryMap("lines").count, 4)
        let again = try XCTUnwrap(try apply([["op": "set_block_symbol_box", "max_y_mm": 7.5]], block: "Channel").first)
        XCTAssertNil(again["drawn"], "the box it drew is the box it finds")
        XCTAssertEqual(boxMM(again, "previous_box_mm"), [-10, -5, 10, 5])

        // A triangle is a drawing, but no box to resize.
        var triangle = try file(symbolPath)
        let ids = ["a", "b", "c"].map { _ in UUID().uuidString.lowercased() }
        triangle["junctions"] = Dictionary(uniqueKeysWithValues: zip(ids, [[0, 0], [5_000_000, 0], [0, 5_000_000]].map { ["position": $0] as JSONDictionary }))
        triangle["lines"] = Dictionary(uniqueKeysWithValues: (0..<3).map {
            (UUID().uuidString.lowercased(), ["from": ids[$0], "to": ids[($0 + 1) % 3], "layer": 0, "width": 0] as JSONDictionary)
        })
        try writeSymbol(triangle)
        XCTAssertThrowsError(try apply([["op": "set_block_symbol_box", "fit_ports": true]], block: "Channel")) { error in
            XCTAssertTrue(((error as? HorizontalDispatchError)?.message ?? "").contains("no rectangle"), "\(error)")
        }
    }

    // MARK: - Pages

    func testPagesFollowEachInstanceAsHorizonPrintsThem() throws {
        let first = try placeChannel()
        let added = try apply([["op": "add_block_instance", "block": "Channel", "refdes": "I1"]])
        let second = try XCTUnwrap(added.first?["block_instance"] as? String)
        try apply([["op": "place_block_symbol", "instance": second, "x_mm": 100, "y_mm": 50],
                   ["op": "set_block_instance", "instance": first.instance, "refdes": "I2"]])

        let pages = project.schematicPages
        XCTAssertEqual(pages.map(\.path), [[], [second], [first.instance]], "the top sheet, then its blocks by instance refdes")
        XCTAssertEqual(pages.map(\.number), [1, 2, 3])
        XCTAssertEqual(pages.dropFirst().map(\.block.uuid), [channelID, channelID])

        // The frame is numbered among the pages.
        var sheet = try topSheet
        sheet.frameTexts = [HorizontalText(id: "frame/text/n", text: "1/1", position: .zero, size: 1_000_000, layer: nil)]
        sheet.frameNumberTemplates = ["frame/text/n": "$sheet_idx/$sheet_total"]
        XCTAssertEqual(sheet.numbered(2, of: 3).frameTexts.first?.text, "2/3")

        // The PDF prints every page, links each block symbol to its
        // instance's first page and outlines the hierarchy.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var settings = HorizontalExportSettings(project: project)
        settings.targetDirectory = directory.path
        let status = HorizontalExportBackend.export(sections: [.schematicPDF], settings: settings, project: project)
        XCTAssertNotEqual(status.kind, .error, status.message)
        XCTAssertEqual(status.outputs.map(\.lastPathComponent), [settings.schematicPDF.filename], "what Reveal in Finder selects")
        let pdf = try XCTUnwrap(PDFDocument(url: directory.appendingPathComponent(settings.schematicPDF.filename)))
        XCTAssertEqual(pdf.pageCount, 3)
        let links = try XCTUnwrap(pdf.page(at: 0)).annotations.compactMap { $0.destination?.page.map(pdf.index(for:)) }
        XCTAssertEqual(Set(links), [1, 2])
        let root = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 1)
        let top = try XCTUnwrap(root.child(at: 0))
        XCTAssertEqual((0..<top.numberOfChildren).compactMap { top.child(at: $0)?.label }, ["I1", "I2"])
        XCTAssertEqual(top.child(at: 1)?.child(at: 0)?.destination?.page.map(pdf.index(for:)), 2)
    }

    // MARK: - Flattening

    private func put(_ path: String, _ json: JSONDictionary) throws {
        try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json))
    }

    func testFlatteningExpandsEveryInstanceAsHorizonDoes() throws {
        let placed = try placeChannel()
        // A second instance, and a resistor inside Channel from In to a net
        // of its own.
        let second = try XCTUnwrap(try apply([["op": "add_block_instance", "block": "Channel", "refdes": "I2"]]).first?["block_instance"] as? String)
        try apply([
            ["op": "set_block_instance", "instance": placed.instance, "refdes": "I1"],
            ["op": "connect_block_port", "instance": placed.instance, "port": "In", "net": "SIG", "create_net": true],
        ])
        var channel = try file("blocks/\(channelID)/block.json")
        let inner = "11111111-2222-4333-8444-555566667777"
        let resistor = "22222222-2222-4333-8444-555566667777"
        var nets = channel["nets"] as? JSONDictionary ?? [:]
        nets[inner] = ["name": "", "is_power": false, "is_port": false]
        channel["nets"] = nets
        channel["components"] = [resistor: ["refdes": "R?", "value": "1k", "connections": [
            "g/1": ["net": placed.net], "g/2": ["net": inner],
        ]]]
        try put("blocks/\(channelID)/block.json", channel)
        var top = try file("top_block.json")
        var mappings = top["block_instance_mappings"] as? JSONDictionary ?? [:]
        mappings[placed.instance] = ["block": channelID, "components": [resistor: ["refdes": "R1", "nopopulate": false]]]
        top["block_instance_mappings"] = mappings
        try put("top_block.json", top)
        try reload()

        let flat = try XCTUnwrap(project.flattenedBlock)
        let components = flat.json.dictionaryMap("components")
        let first = HorizontalBlockFlattener.flattenedID([placed.instance, resistor])
        let other = HorizontalBlockFlattener.flattenedID([second, resistor])
        XCTAssertEqual(components[first]?.string("refdes"), "R1", "the instance mapping's refdes")
        XCTAssertEqual(components[other]?.string("refdes"), "R?", "no mapping entry: the block's own")
        XCTAssertNil(components[resistor], "the block's own component is used, not placed")
        XCTAssertEqual(flat.componentPaths[first], [placed.instance, resistor])

        let sig = try XCTUnwrap(project.blocks.first(where: \.isTop).flatMap { _ in
            try? file("top_block.json").dictionaryMap("nets").first { $0.value.string("name") == "SIG" }?.key
        })
        XCTAssertEqual(components[first]?.dictionaryMap("connections")["g/1"]?.string("net"), sig, "a wired port is the net outside")
        let flatNets = flat.json.dictionaryMap("nets")
        let secondIn = HorizontalBlockFlattener.flattenedID([second, placed.net])
        XCTAssertEqual(components[other]?.dictionaryMap("connections")["g/1"]?.string("net"), secondIn)
        XCTAssertEqual(flatNets[secondIn]?.string("name"), "I2/In", "an unwired port is the instance's own net")
        let firstInner = HorizontalBlockFlattener.flattenedID([placed.instance, inner])
        XCTAssertEqual(flatNets[firstInner]?.string("name"), "I1/R?", "an unnamed net takes its parts' refdes, as Horizon's get_net_name")
        XCTAssertEqual(flat.netPaths[sig]?.contains([placed.instance, placed.net]), true)

        // The MCP check annotates per instance, and its BOM lists each use.
        XCTAssertTrue(flat.isHierarchical)
    }

    func testAProjectWithoutInstancesIsNotFlattened() throws {
        try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        XCTAssertNil(project.flattenedBlock)
        XCTAssertEqual(HorizontalBlockFlattener.flattenedID(["0c0c0c0c-1111-4222-8333-444455556666"]), "0c0c0c0c-1111-4222-8333-444455556666")
    }

    func testAnInstanceGetsItsOwnRefdes() throws {
        let placed = try placeChannel()
        try apply([["op": "set_block_instance", "instance": placed.instance, "refdes": "I1"]])
        var channel = try file("blocks/\(channelID)/block.json")
        let resistor = "22222222-2222-4333-8444-555566667777"
        channel["components"] = [resistor: ["refdes": "R?", "value": "1k", "connections": JSONDictionary()]]
        try put("blocks/\(channelID)/block.json", channel)
        try reload()

        let changes = try apply([["op": "set_refdes", "component": resistor, "refdes": "R7", "instance": "I1"]], block: "Channel")
        XCTAssertEqual(changes.first?["instance"] as? String, placed.instance)
        let mapping = try XCTUnwrap(try file("top_block.json").dictionaryMap("block_instance_mappings")[placed.instance])
        XCTAssertEqual(mapping.dictionaryMap("components")[resistor]?.string("refdes"), "R7")
        XCTAssertEqual(try file("blocks/\(channelID)/block.json").dictionaryMap("components")[resistor]?.string("refdes"), "R?",
                       "the block's own refdes stays")
        XCTAssertEqual(project.flattenedBlock?.instanceRefdes[placed.instance]?[resistor], "R7")
        let flatID = HorizontalBlockFlattener.flattenedID([placed.instance, resistor])
        XCTAssertEqual(project.flattenedBlock?.json.dictionaryMap("components")[flatID]?.string("refdes"), "R7")

        try apply([["op": "set_no_populate", "component": resistor, "no_populate": true, "instance": placed.instance]], block: "Channel")
        XCTAssertEqual(try file("top_block.json").dictionaryMap("block_instance_mappings")[placed.instance]?
            .dictionaryMap("components")[resistor]?.bool("nopopulate"), true)
        XCTAssertEqual(project.flattenedBlock?.instanceNoPopulate[placed.instance]?[resistor], true)
        XCTAssertEqual(project.flattenedBlock?.json.dictionaryMap("components")[flatID]?.bool("nopopulate"), true)

        XCTAssertThrowsError(try apply([["op": "set_refdes", "component": resistor, "refdes": "R8", "instance": "I9"]], block: "Channel"))
    }

    func testASheetDrawsAnInstancesRefdes() throws {
        var schematic = try file("top_schematic.json")
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        var sheet = try XCTUnwrap(schematic.dictionaryMap("sheets")[sheetID])
        sheet["symbols"] = ["s1": ["symbol": "part-symbol", "component": "r1", "gate": "gate",
                                   "placement": ["shift": [0, 0], "angle": 0, "mirror": false]]]
        schematic["sheets"] = [sheetID: sheet]
        try put("top_schematic.json", schematic)
        var top = try file("top_block.json")
        top["components"] = ["r1": ["refdes": "R?", "value": "", "connections": JSONDictionary()]]
        try put("top_block.json", top)
        try put("pool/symbols/cache/part-symbol.json", ["uuid": "part-symbol", "unit": "unit", "pins": JSONDictionary(),
            "texts": ["t": ["text": "$REFDES", "placement": ["shift": [0, 2_500_000], "angle": 0, "mirror": false], "size": 1_500_000]]])
        try put("pool/units/cache/unit.json", ["uuid": "unit", "pins": JSONDictionary()])
        try reload()

        let drawn = try topSheet
        XCTAssertEqual(drawn.drawnRefdes["r1"], "R?")
        XCTAssertTrue(drawn.symbolTexts.contains { $0.text == "R?" })
        let instance = drawn.showingRefdes(["r1": "R12"])
        XCTAssertEqual(instance.drawnRefdes["r1"], "R12")
        XCTAssertTrue(instance.symbolTexts.contains { $0.text == "R12" })
        XCTAssertFalse(instance.symbolTexts.contains { $0.text == "R?" })
        // And back, as an edit through the instance is written.
        XCTAssertTrue(instance.showingRefdes(drawn.drawnRefdes).symbolTexts.contains { $0.text == "R?" })
    }

    /// Through an instance, a component is (not) populated as the instance's
    /// mapping says, and crossed out as Horizon crosses it: the same cross a
    /// sheet draws for its own do-not-populate component.
    func testASheetDrawsAnInstancesDoNotPopulate() throws {
        var schematic = try file("top_schematic.json")
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        var sheet = try XCTUnwrap(schematic.dictionaryMap("sheets")[sheetID])
        // A quarter turn, so the box the cross is drawn over turns with it.
        sheet["symbols"] = ["s1": ["symbol": "part-symbol", "component": "r1", "gate": "gate",
                                   "placement": ["shift": [10_000_000, 0], "angle": 16_384, "mirror": false]]]
        schematic["sheets"] = [sheetID: sheet]
        try put("top_schematic.json", schematic)
        var top = try file("top_block.json")
        top["components"] = ["r1": ["refdes": "R1", "value": "", "connections": JSONDictionary()]]
        try put("top_block.json", top)
        try put("pool/symbols/cache/part-symbol.json", ["uuid": "part-symbol", "unit": "unit", "pins": JSONDictionary(),
            "junctions": ["a": ["position": [-2_000_000, -1_000_000]], "b": ["position": [2_000_000, 1_000_000]]],
            "lines": ["l": ["from": "a", "to": "b", "width": 0]]])
        try put("pool/units/cache/unit.json", ["uuid": "unit", "pins": JSONDictionary()])
        try reload()

        let populated = try topSheet
        XCTAssertTrue(populated.noPopulateMarks.isEmpty)
        let instance = populated.showingNoPopulate(["r1": true])
        XCTAssertEqual(instance.symbols.first?.componentDetails?.noPopulate, true)
        XCTAssertEqual(instance.componentInfo["r1"]?.noPopulate, true)
        let cross = try XCTUnwrap(instance.noPopulateMarks.first)
        XCTAssertEqual(instance.noPopulateMarks.count, 1)
        // The turned box, x 9…11 and y −2…2 mm, grown by 0.2 mm.
        XCTAssertEqual(Set(cross.points), [
            HorizontalPoint(x: 8_800_000, y: -2_200_000), HorizontalPoint(x: 11_200_000, y: 2_200_000),
            HorizontalPoint(x: 8_800_000, y: 2_200_000), HorizontalPoint(x: 11_200_000, y: -2_200_000),
        ])
        XCTAssertTrue(instance.showingNoPopulate(["r1": false]).noPopulateMarks.isEmpty)
        XCTAssertEqual(populated.showingNoPopulate(["r2": true]).noPopulateMarks, [], "a component the mapping leaves out keeps its own")

        top["components"] = ["r1": ["refdes": "R1", "value": "", "nopopulate": true, "connections": JSONDictionary()]]
        try put("top_block.json", top)
        try reload()
        let own = try XCTUnwrap(try topSheet.noPopulateMarks.first)
        XCTAssertEqual(Set(own.points), Set(cross.points))
        XCTAssertTrue(try topSheet.showingNoPopulate(["r1": false]).noPopulateMarks.isEmpty)
    }

    func testAnnotateNumbersEachInstanceAsHorizonDoes() throws {
        let placed = try placeChannel()
        let second = try XCTUnwrap(try apply([["op": "add_block_instance", "block": "Channel"]]).first?["block_instance"] as? String)
        try apply([
            ["op": "place_block_symbol", "instance": second, "x_mm": 100, "y_mm": 50],
            ["op": "set_block_instance", "instance": placed.instance, "refdes": "I1"],
            ["op": "set_block_instance", "instance": second, "refdes": "I2"],
        ])
        // A resistor inside Channel, drawn on its sheet.
        let resistor = "22222222-2222-4333-8444-555566667777"
        var channel = try file("blocks/\(channelID)/block.json")
        channel["components"] = [resistor: ["refdes": "R?", "value": "1k", "connections": JSONDictionary()]]
        try put("blocks/\(channelID)/block.json", channel)
        var schematic = try file("blocks/\(channelID)/schematic.json")
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        var sheet = try XCTUnwrap(schematic.dictionaryMap("sheets")[sheetID])
        sheet["symbols"] = ["s1": ["symbol": "part-symbol", "component": resistor, "gate": "gate",
                                   "placement": ["shift": [0, 0], "angle": 0, "mirror": false]]]
        schematic["sheets"] = [sheetID: sheet]
        try put("blocks/\(channelID)/schematic.json", schematic)
        try reload()

        func instanceRefdes(_ instance: String) throws -> String? {
            try file("top_block.json").dictionaryMap("block_instance_mappings")[instance]?.dictionaryMap("components")[resistor]?.string("refdes")
        }
        let sequential = try apply([["op": "annotate", "mode": "sequential", "order": "down_right"]])
        XCTAssertEqual(sequential.first?["annotated"] as? Int, 2)
        XCTAssertEqual(try instanceRefdes(placed.instance), "R1", "I1's sheet comes first, as Horizon numbers pages")
        XCTAssertEqual(try instanceRefdes(second), "R2")
        XCTAssertEqual(try file("blocks/\(channelID)/block.json").dictionaryMap("components")[resistor]?.string("refdes"), "R?",
                       "the block's own refdes is no instance's")
        XCTAssertEqual(try file("top_schematic.json").dictionary("annotation")?.string("mode"), "sequential", "the options are kept")

        // Per page: the top sheet is page 1, I1's 2 and I2's 3.
        try apply([["op": "annotate", "mode": "sheet_100", "keep": false]])
        XCTAssertEqual(try instanceRefdes(placed.instance), "R201")
        XCTAssertEqual(try instanceRefdes(second), "R301")
        XCTAssertEqual(try apply([["op": "annotate"]]).first?["annotated"] as? Int, 0, "again changes nothing")
    }
}
