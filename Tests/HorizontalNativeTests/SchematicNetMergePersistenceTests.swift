import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Wiring edits as they reach the project files: the wire tool
/// (`HorizontalSchematicWireTool.Session`, the clicks the canvas passes on)
/// connecting a named net to a free pin, splitting a wire it ends on and
/// merging the nets it joins, and a merge of two nets the project had
/// rewriting every file that names the merged one.
final class SchematicNetMergePersistenceTests: XCTestCase {
    /// Sheet 1: R1's pin `a` on SIG_A, wired left to junction `ja`; R2's pin
    /// `a` on SIG_B, wired to junction `jb`; R3's pin `a` free, above `ja`;
    /// R4's marked no-connect, above R1; R5's free, above `jb`. Sheet 2: a
    /// junction cached on SIG_B. The board pours SIG_B and has a via set to it.
    private func project() throws -> (project: HorizontalProject, archive: HorizontalProjectArchive) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("net-merge-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        var archive = HorizontalProjectArchive.newProject()
        func json(_ path: String) throws -> JSONDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: path))) as? JSONDictionary)
        }
        func put(_ path: String, _ json: JSONDictionary) throws {
            try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json))
        }
        var schematic = try json("top_schematic.json")
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        func symbol(_ component: String, x: Int, y: Int = 0) -> JSONDictionary {
            ["symbol": "part-symbol", "component": component, "gate": "gate",
             "placement": ["shift": [x, y], "angle": 0, "mirror": false]]
        }
        schematic["sheets"] = [
            sheetID: [
                "name": "One", "index": 1,
                "symbols": ["s1": symbol("r1", x: 0), "s2": symbol("r2", x: 10_000_000), "s3": symbol("r3", x: -2_500_000, y: 5_000_000),
                            "s4": symbol("r4", x: 0, y: 5_000_000), "s5": symbol("r5", x: 7_500_000, y: 5_000_000)],
                "junctions": ["ja": ["position": [-2_500_000, 0]], "jb": ["position": [7_500_000, 0]]],
                "net_lines": [
                    "wa": ["from": ["pin": "s1/a"], "to": ["junc": "ja"]],
                    "wb": ["from": ["pin": "s2/a"], "to": ["junc": "jb"]],
                ],
                "net_labels": ["la": ["junction": "ja", "last_net": "a", "size": 1_500_000, "orientation": "left"]],
            ],
            "second": [
                "name": "Two", "index": 2,
                "junctions": ["far": ["position": [0, 0], "net": "b"], "fa": ["position": [5_000_000, 0]]],
                "net_labels": ["lb": ["junction": "fa", "last_net": "a", "size": 1_500_000, "orientation": "right"]],
            ],
        ]
        try put("top_schematic.json", schematic)
        var block = try json("top_block.json")
        block["nets"] = ["a": ["name": "SIG_A"], "b": ["name": "SIG_B"]]
        block["components"] = [
            "r1": ["refdes": "R1", "value": "", "connections": ["gate/a": ["net": "a"]]],
            "r2": ["refdes": "R2", "value": "", "connections": ["gate/a": ["net": "b"]]],
            "r3": ["refdes": "R3", "value": "", "connections": [:] as JSONDictionary],
            "r4": ["refdes": "R4", "value": "", "connections": ["gate/a": ["net": NSNull()]]],
            "r5": ["refdes": "R5", "value": "", "connections": [:] as JSONDictionary],
        ]
        try put("top_block.json", block)
        var board = try json("board.json")
        board["planes"] = ["p": ["net": "b", "polygon": "poly", "priority": 0]]
        board["vias"] = ["v": ["net_set": "b", "position": [0, 0]]]
        try put("board.json", board)
        try put("pool/symbols/cache/part-symbol.json", ["uuid": "part-symbol", "unit": "unit", "pins": [
            "a": ["position": [0, 0], "length": 1_250_000, "orientation": "left", "name_visible": false, "pad_visible": false],
        ]])
        try put("pool/units/cache/unit.json", ["uuid": "unit", "pins": ["a": ["primary_name": "1"]]])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try archive.write(to: url)
        return (try HorizontalProject.load(from: url), archive)
    }

    private func file(_ path: String, in archive: HorizontalProjectArchive) throws -> JSONDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: path))) as? JSONDictionary)
    }

    private func sheetOne(_ project: HorizontalProject) throws -> HorizontalSchematicSheet {
        try XCTUnwrap(project.schematic?.sheets.first { $0.name == "One" })
    }

    private let grid = 1_250_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint { .init(x: x * grid, y: y * grid) }

    /// What the canvas does when the tool commits, once no merge is left to
    /// ask about.
    private func committed(_ session: HorizontalSchematicWireTool.Session) -> HorizontalSchematicSheet {
        var sheet = session.sheet
        let touched = sheet.touchedPointKeys(since: session.originalSheet)
        sheet.connectCoincident(at: touched)
        XCTAssertEqual(sheet.netConflicts(touching: touched), [])
        sheet.spreadNets(touching: touched)
        sheet.healNetLines()
        return sheet
    }

    private func pinNet(_ symbol: String, _ sheet: HorizontalSchematicSheet) -> String? {
        sheet.symbolPins.first { $0.id.lowercased() == "\(symbol)/pin/a" }?.netID
    }

    func testTheWireToolConnectsANamedNetToAFreeResistorPin() throws {
        var (project, archive) = try project()
        var session = HorizontalSchematicWireTool.Session(sheet: try sheetOne(project))
        // From the end of SIG_A's wire up to R3's pin.
        XCTAssertEqual(session.click(at: point(-2, 0)), .done)
        XCTAssertEqual(session.netID, "a")
        XCTAssertEqual(session.click(at: point(-2, 4)), .done)
        XCTAssertNil(session.anchor, "ending on a pin finishes the wire")
        XCTAssertEqual(session.sheet.componentInfo["r3"]?.connections["gate/a"]?.netID, "a")

        let sheet = committed(session)
        let drawn = try XCTUnwrap(sheet.netLines.first { $0.schematicTo == .pin("s3/a") })
        XCTAssertEqual(drawn.schematicFrom, .junction("ja"))
        XCTAssertEqual(drawn.netID, "a")
        XCTAssertTrue(sheet.symbolPins.filter { $0.id.lowercased().hasPrefix("s3/pin-connector/a") }.isEmpty)

        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        project = try HorizontalProject.loadSnapshot(of: archive)
        let reloaded = try sheetOne(project)
        XCTAssertEqual(reloaded.netLines.first { $0.id == drawn.id }?.netID, "a")
        XCTAssertEqual(pinNet("s3", reloaded), "a")
        XCTAssertTrue(reloaded.symbolPins.filter { $0.id.lowercased().hasPrefix("s3/pin-connector/a") }.isEmpty)
    }

    func testEndingOnTheSideOfAWireSplitsItIntoAT() throws {
        let (project, _) = try project()
        var session = HorizontalSchematicWireTool.Session(sheet: try sheetOne(project))
        // From R3's free pin down onto the middle of SIG_A's wire `wa`.
        XCTAssertEqual(session.click(at: point(-2, 4)), .done)
        XCTAssertEqual(session.click(at: point(-1, 0)), .done)

        let sheet = committed(session)
        XCTAssertEqual(sheet.componentInfo["r3"]?.connections["gate/a"]?.netID, "a")
        let tee = try XCTUnwrap(sheet.junctions.first { $0.value == point(-1, 0) }?.key)
        let atTee = sheet.netLines.filter { [$0.schematicFrom, $0.schematicTo].contains(.junction(tee)) }
        XCTAssertEqual(atTee.count, 3, "the wire's two halves and the new one meet at the T")
        XCTAssertTrue(atTee.allSatisfy { $0.netID == "a" })
    }

    func testTwoNamedNetsMeetingAskWhichNameStays() throws {
        let (project, _) = try project()
        var session = HorizontalSchematicWireTool.Session(sheet: try sheetOne(project))
        XCTAssertEqual(session.click(at: point(-2, 0)), .done)
        XCTAssertEqual(session.click(at: point(6, 0)), .ask(net: "b", into: "a"))
        XCTAssertEqual(session.segmentCount, 0, "nothing is drawn until the user answers")

        XCTAssertEqual(session.resolve((from: "a", into: "b")), .done)
        XCTAssertEqual(session.externalMerges, ["a": "b"])
        let sheet = committed(session)
        XCTAssertNil(sheet.netDetails["a"])
        XCTAssertEqual(pinNet("s1", sheet), "b")
        XCTAssertEqual(pinNet("s2", sheet), "b")
    }

    func testCancellingTheMergeDrawsNothing() throws {
        let (project, _) = try project()
        let original = try sheetOne(project)
        var session = HorizontalSchematicWireTool.Session(sheet: original)
        _ = session.click(at: point(-2, 0))
        _ = session.click(at: point(6, 0))
        XCTAssertEqual(session.resolve(nil), .done)
        XCTAssertEqual(session.sheet.netLines.count, original.netLines.count)
        XCTAssertNotNil(session.anchor, "the wire is still being drawn from where it started")
    }

    func testANoConnectPinRefusesTheWire() throws {
        let (project, _) = try project()
        var session = HorizontalSchematicWireTool.Session(sheet: try sheetOne(project))
        XCTAssertEqual(session.click(at: point(0, 4)), .refused("Can't connect to a pin marked no connect"))
        XCTAssertNil(session.anchor)
    }

    func testAWireBetweenTwoFreePinsPutsBothOnANewNet() throws {
        let (project, _) = try project()
        var session = HorizontalSchematicWireTool.Session(sheet: try sheetOne(project))
        XCTAssertEqual(session.click(at: point(-2, 4)), .done)
        // Round R4's no-connect pin: up, across, down to R5.
        XCTAssertEqual(session.click(at: point(-2, 6)), .done)
        XCTAssertEqual(session.click(at: point(6, 6)), .done)
        XCTAssertEqual(session.click(at: point(6, 4)), .done)

        let sheet = committed(session)
        let netID = try XCTUnwrap(sheet.componentInfo["r3"]?.connections["gate/a"]?.netID)
        XCTAssertEqual(sheet.componentInfo["r5"]?.connections["gate/a"]?.netID, netID)
        XCTAssertEqual(sheet.netDetails[netID]?.name, "")
        XCTAssertNotEqual(netID, "a")
        XCTAssertNotEqual(netID, "b")
    }

    func testAWireFromANamedNetToAFreePinConnectsIt() throws {
        var (project, archive) = try project()
        let original = try sheetOne(project)
        XCTAssertEqual(original.netLines.first { $0.id == "wa" }?.netID, "a")
        var sheet = original
        // What the wire tool lays down from `ja` to R3's pin.
        let pinPoint = try XCTUnwrap(sheet.symbolPins.first { $0.id.lowercased() == "s3/pin/a" }?.from)
        let start = try XCTUnwrap(sheet.junctions["ja"])
        sheet.netLines.append(HorizontalSegment(id: "drawn", from: start, to: pinPoint, width: 0, layer: nil, netID: "a",
                                                schematicFrom: .junction("ja"), schematicTo: .pin("s3/a")))
        let touched = sheet.touchedPointKeys(since: original)
        sheet.connectCoincident(at: touched)
        XCTAssertTrue(sheet.netConflicts(touching: touched).isEmpty)
        sheet.spreadNets(touching: touched)
        sheet.healNetLines()

        XCTAssertEqual(sheet.componentInfo["r3"]?.connections["gate/a"]?.netID, "a")
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        let connection = try file("top_block.json", in: archive).dictionaryMap("components")["r3"]?.dictionaryMap("connections")["gate/a"]
        XCTAssertEqual(connection?.string("net"), "a")

        project = try HorizontalProject.loadSnapshot(of: archive)
        let reloaded = try sheetOne(project)
        XCTAssertEqual(reloaded.netLines.first { $0.id == "drawn" }?.netID, "a")
        XCTAssertEqual(reloaded.symbolPins.first { $0.id.lowercased() == "s3/pin/a" }?.netID, "a")
        XCTAssertTrue(reloaded.symbolPins.filter { $0.id.lowercased().hasPrefix("s3/pin-connector/a") }.isEmpty,
                      "R3's pin no longer draws the open box of an unconnected pin")
    }

    /// What the canvas's net name field does: `rename_net` through the
    /// project edit, then the reload, so every sheet shows the new name and
    /// its labels their other-sheet references, which the name never holds.
    func testRenamingANetShowsTheNewNameOnEverySheet() throws {
        let (project, archive) = try project()
        XCTAssertEqual(try sheetOne(project).netLabels.first?.text, "SIG_A [2]")
        XCTAssertEqual(try sheetOne(project).netDetails["a"]?.name, "SIG_A", "the name has no sheet references")

        let edited = try HorizontalCanvasProjectEdit.archive(applying: [["op": "rename_net", "net": "a", "name": "CLK"]],
                                                             to: archive, in: project)
        let reloaded = try HorizontalProject.loadSnapshot(of: edited.archive)
        let sheets = try XCTUnwrap(reloaded.schematic?.sheets)
        XCTAssertEqual(sheets.first { $0.name == "One" }?.netLabels.first?.text, "CLK [2]")
        XCTAssertEqual(sheets.first { $0.name == "Two" }?.netLabels.first?.text, "CLK [1]")
        XCTAssertTrue(sheets.allSatisfy { $0.netDetails["a"]?.name == "CLK" })
    }

    func testMergingANetTheProjectHadRewritesEveryFileThatNamesIt() throws {
        var (project, archive) = try project()
        var sheet = try sheetOne(project)
        sheet.mergeNet("b", into: "a")

        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        try HorizontalProjectJSONApplicator.apply(netMerges: ["b": "a"], schematicURL: project.schematic!.url, in: project, to: &archive)

        let block = try file("top_block.json", in: archive)
        XCTAssertEqual(Set(block.dictionaryMap("nets").keys), ["a"])
        XCTAssertEqual(block.dictionaryMap("components")["r2"]?.dictionaryMap("connections")["gate/a"]?.string("net"), "a")
        let schematic = try file("top_schematic.json", in: archive)
        XCTAssertEqual(schematic.dictionaryMap("sheets")["second"]?.dictionaryMap("junctions")["far"]?.string("net"), "a")
        let board = try file("board.json", in: archive)
        XCTAssertEqual(board.dictionaryMap("planes")["p"]?.string("net"), "a")
        XCTAssertEqual(board.dictionaryMap("vias")["v"]?.string("net_set"), "a")

        project = try HorizontalProject.loadSnapshot(of: archive)
        let reloaded = try sheetOne(project)
        XCTAssertEqual(reloaded.netLines.first { $0.id == "wb" }?.netID, "a")
        XCTAssertNil(reloaded.netDetails["b"])
    }
}
