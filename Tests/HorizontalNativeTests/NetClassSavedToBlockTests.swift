import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A net's class set in an inspector is kept. The class is the block's: the
/// board file holds none, and every sheet carries a copy of the block's nets
/// that it writes back with its next edit. So the class goes to the block
/// file and to every copy the project holds, and a reload, the board's
/// netlist sync and the next sheet edit all find it there. The iPad project
/// view left a class set on the board in the canvas alone, and the next
/// reload put the old class back, with the widths the rules give it.
final class NetClassSavedToBlockTests: XCTestCase {
    private static let null = "00000000-0000-0000-0000-000000000000"
    private static let fast = "aaaaaaaa-0000-4000-8000-000000000001"
    private static let fastViaRule = "bbbbbbbb-0000-4000-8000-000000000001"

    /// A new project (a GND net in the Default class, a GND via the rules
    /// shape, two GND planes) with a second class, Fast, a second sheet, and
    /// a via rule that gives Fast a 0.9 mm via ahead of the 0.5 mm one for
    /// every net.
    private struct Fixture {
        var project: HorizontalProject
        var archive: HorizontalProjectArchive
        let poolURL: URL
        /// GND's id as the block file spells it, and as the model keys it.
        let gndKey: String
        var gnd: String { gndKey.lowercased() }
        let defaultClass: String

        init(_ testCase: XCTestCase) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("net-class-saved-to-block-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("Test.horizontal")

            var template = HorizontalProjectArchive.newProject()
            var gndKey = ""
            var defaultClass = ""
            try Self.edit("top_block.json", in: &template) { block in
                var classes = try XCTUnwrap(block["net_classes"] as? JSONDictionary)
                defaultClass = try XCTUnwrap(classes.keys.first)
                classes[NetClassSavedToBlockTests.fast] = ["name": "Fast"] as JSONDictionary
                block["net_classes"] = classes
                var nets = try XCTUnwrap(block["nets"] as? JSONDictionary)
                gndKey = try XCTUnwrap(nets.keys.first)
                var net = try XCTUnwrap(nets[gndKey] as? JSONDictionary)
                // A key the app doesn't know, which a write must keep.
                net["some_later_key"] = "kept"
                nets[gndKey] = net
                block["nets"] = nets
            }
            try Self.edit("top_schematic.json", in: &template) { schematic in
                var sheets = try XCTUnwrap(schematic["sheets"] as? JSONDictionary)
                var second = try XCTUnwrap(sheets.values.first as? JSONDictionary)
                second["name"] = "Sheet 2"
                second["index"] = 2
                sheets[UUID().uuidString.lowercased()] = second
                schematic["sheets"] = sheets
            }
            try Self.edit("board.json", in: &template) { board in
                var rules = try XCTUnwrap(board["rules"] as? JSONDictionary)
                var vias = try XCTUnwrap(rules["via"] as? JSONDictionary)
                let restID = try XCTUnwrap(vias.keys.first)
                var rest = try XCTUnwrap(vias[restID] as? JSONDictionary)
                var fast = rest
                rest["order"] = 1
                vias[restID] = rest
                fast["order"] = 0
                fast["match"] = [
                    "mode": "net_class", "net": NetClassSavedToBlockTests.null,
                    "net_class": NetClassSavedToBlockTests.fast, "net_name_regex": "",
                ] as JSONDictionary
                fast["parameter_set"] = ["via_diameter": 900_000, "hole_diameter": 400_000] as JSONDictionary
                vias[NetClassSavedToBlockTests.fastViaRule] = fast
                rules["via"] = vias
                board["rules"] = rules
            }
            try template.write(to: url)

            project = try HorizontalProject.load(from: url)
            archive = try HorizontalProjectArchive.completeProject(from: url)
            poolURL = url.appendingPathComponent("pool")
            self.gndKey = gndKey
            self.defaultClass = defaultClass.lowercased()
        }

        private static func edit(
            _ path: String,
            in archive: inout HorizontalProjectArchive,
            _ change: (inout JSONDictionary) throws -> Void
        ) throws {
            let data = try XCTUnwrap(archive.regularFileData(relativePath: path))
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
            try change(&json)
            try archive.replaceRegularFileData(
                relativePath: path,
                with: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            )
        }

        /// The block file as the archive holds it.
        func blockData() throws -> Data {
            try XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))
        }

        /// GND as the block file has it.
        func blockNet() throws -> JSONDictionary {
            let block = try XCTUnwrap(JSONSerialization.jsonObject(with: blockData()) as? JSONDictionary)
            let nets = try XCTUnwrap(block["nets"] as? JSONDictionary)
            return try XCTUnwrap(nets[gndKey] as? JSONDictionary)
        }

        /// As a canvas's inspector reports a class: the net, and the class.
        mutating func putGND(inClass classID: String?) throws {
            try project.putNet(gnd, inClass: classID, archive: &archive)
        }
    }

    func testAClassSetOnABoardNetIsWrittenToTheBlockAndAReloadKeepsIt() throws {
        var fixture = try Fixture(self)
        let gnd = fixture.gnd
        XCTAssertEqual(fixture.project.board?.netDetails[gnd]?.netClassID, fixture.defaultClass)
        XCTAssertNotEqual(fixture.project.board?.rules.via(net: gnd)?.id, Self.fastViaRule)

        try fixture.putGND(inClass: Self.fast)

        let net = try fixture.blockNet()
        XCTAssertEqual(net["net_class"] as? String, Self.fast, "the block is where a class is kept")
        XCTAssertEqual(net["name"] as? String, "GND")
        XCTAssertEqual(net["is_power"] as? Bool, true)
        XCTAssertEqual(net["some_later_key"] as? String, "kept", "what the app doesn't know stays")
        XCTAssertEqual(fixture.project.board?.netDetails[gnd]?.netClassID, Self.fast)
        XCTAssertEqual(fixture.project.board?.netDetails[gnd]?.netClassName, "Fast")
        XCTAssertEqual(fixture.project.schematic?.netDetails[gnd]?.netClassName, "Fast")

        // A reload, as the board's netlist sync makes one, finds the class in
        // the block, and the rules give the net's via what they give Fast.
        let reloaded = try HorizontalProject.loadSnapshot(of: fixture.archive)
        XCTAssertEqual(reloaded.schematic?.netDetails[gnd]?.netClassID, Self.fast)
        var board = try XCTUnwrap(reloaded.board)
        XCTAssertEqual(board.netDetails[gnd]?.netClassID, Self.fast)
        XCTAssertEqual(board.netDetails[gnd]?.netClassName, "Fast")
        XCTAssertEqual(board.rules.via(net: gnd)?.id, Self.fastViaRule)
        HorizontalBoardRuleApplication.apply(to: &board, poolURL: fixture.poolURL)
        XCTAssertEqual(board.vias.first?.size, 900_000)
    }

    func testEverySheetsCopyOfTheNetTakesTheClassSoASheetEditKeepsIt() throws {
        var fixture = try Fixture(self)
        let gnd = fixture.gnd
        try fixture.putGND(inClass: Self.fast)

        let schematic = try XCTUnwrap(fixture.project.schematic)
        XCTAssertEqual(schematic.sheets.count, 2)
        XCTAssertEqual(fixture.project.schematics.first?.schematic.netDetails[gnd]?.netClassID, Self.fast)
        for sheet in schematic.sheets {
            XCTAssertEqual(sheet.netDetails[gnd]?.netClassID, Self.fast, sheet.name)
            XCTAssertEqual(sheet.netDetails[gnd]?.netClassName, "Fast", sheet.name)
            // Any edit of a sheet writes its copy of the nets to the block.
            try HorizontalProjectJSONApplicator.apply(
                schematicSheet: sheet, schematicURL: schematic.url, in: fixture.project, to: &fixture.archive)
            XCTAssertEqual(try fixture.blockNet()["net_class"] as? String, Self.fast, "after an edit of \(sheet.name)")
        }
        XCTAssertEqual(try fixture.blockNet()["some_later_key"] as? String, "kept")
    }

    func testTheOldClassPutBackAsUndoPutsItLeavesTheBlockAsItWas() throws {
        var fixture = try Fixture(self)
        let gnd = fixture.gnd
        let before = try fixture.blockNet()

        try fixture.putGND(inClass: Self.fast)
        XCTAssertNotEqual(try fixture.blockNet() as NSDictionary, before as NSDictionary)
        // The canvas's Undo reports the class the net had.
        try fixture.putGND(inClass: fixture.defaultClass)

        XCTAssertEqual(try fixture.blockNet() as NSDictionary, before as NSDictionary)
        XCTAssertEqual(fixture.project.board?.netDetails[gnd]?.netClassID, fixture.defaultClass)
        XCTAssertEqual(fixture.project.board?.netDetails[gnd]?.netClassName, "Default")
        for sheet in try XCTUnwrap(fixture.project.schematic).sheets {
            XCTAssertEqual(sheet.netDetails[gnd]?.netClassName, "Default", sheet.name)
        }
        let reloaded = try HorizontalProject.loadSnapshot(of: fixture.archive)
        XCTAssertEqual(reloaded.board?.netDetails[gnd]?.netClassID, fixture.defaultClass)
        XCTAssertNotEqual(reloaded.board?.rules.via(net: gnd)?.id, Self.fastViaRule)
    }

    func testACopyWithoutTheNetIsLeftWithoutIt() throws {
        var fixture = try Fixture(self)
        let gnd = fixture.gnd
        // A sheet that hasn't heard of the net writes nothing of it; given
        // one made up for the class, it would write the made-up name.
        var schematic = try XCTUnwrap(fixture.project.schematic)
        schematic.sheets[1].netDetails[gnd] = nil
        fixture.project.schematic = schematic

        try fixture.putGND(inClass: Self.fast)

        let sheets = try XCTUnwrap(fixture.project.schematic).sheets
        XCTAssertEqual(sheets[0].netDetails[gnd]?.netClassID, Self.fast)
        XCTAssertNil(sheets[1].netDetails[gnd])
        XCTAssertEqual(try fixture.blockNet()["name"] as? String, "GND")
    }

    func testANetInsideABlockInstanceIsNotWrittenToTheTopBlock() throws {
        var fixture = try Fixture(self)
        let gnd = fixture.gnd
        let inner = "cccccccc-0000-4000-8000-000000000001"
        // A project with a block instance: GND is the top block's own, and
        // `inner` stands for a net of the instance's block.
        fixture.project.flattenedBlock = HorizontalFlattenedBlock(
            json: [:],
            componentPaths: ["part": ["instance", "part"]],
            netPaths: [gnd: [[gnd]], inner: [["instance", "net"]]],
            noConnectNets: []
        )
        var board = try XCTUnwrap(fixture.project.board)
        board.netDetails[inner] = HorizontalNetDetails(id: inner, name: "I1/N1", netClassID: fixture.defaultClass, netClassName: "Default")
        fixture.project.board = board
        let before = try fixture.blockData()

        XCTAssertThrowsError(try fixture.project.putNet(inner, inClass: Self.fast, archive: &fixture.archive)) { error in
            XCTAssertEqual(error as? HorizontalNetClassChangeError, .netOfBlockInstance)
        }
        XCTAssertEqual(try fixture.blockData(), before, "the top block's file gets no net it doesn't have")
        XCTAssertEqual(fixture.project.board?.netDetails[inner]?.netClassID, fixture.defaultClass, "and nothing changes in memory")

        try fixture.putGND(inClass: Self.fast)
        XCTAssertEqual(try fixture.blockNet()["net_class"] as? String, Self.fast, "the top block's own net is its to class")
    }
}
