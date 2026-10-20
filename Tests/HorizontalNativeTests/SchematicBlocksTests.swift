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
