import XCTest
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
        // Dark Blue Tiger's Channel block, as Horizon wrote it.
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

    func testANoConnectPortRefusesAWire() throws {
        let placed = try placeChannel()
        try apply([["op": "connect_block_port", "instance": placed.instance, "port": "In", "nc": true]])
        var session = HorizontalSchematicWireTool.Session(sheet: try topSheet)
        guard case .refused = session.click(at: point(40, 50)) else {
            return XCTFail("an NC port takes no wire")
        }
    }
}
