import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Every sheet carries its own copy of the whole block's pin connections, and
/// only the sheet a gate is drawn on can wire its pins. Saving one sheet must
/// not write its out-of-date copy of a gate drawn on another back over that
/// sheet's edit — which is how a net segment moved to a new net on one sheet
/// went back on its old net when another sheet was saved.
final class SchematicSiblingSheetConnectionTests: XCTestCase {
    /// R1 on sheet "one", its pin `a` on net "old"; R2 on sheet "two", its
    /// pin `a` on "old" too. U1 has a gate on each sheet.
    private func project() throws -> (project: HorizontalProject, archive: HorizontalProjectArchive) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sibling-sheets-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        var archive = HorizontalProjectArchive.newProject()
        func put(_ path: String, _ json: JSONDictionary) throws {
            try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json))
        }
        var schematic = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))) as? JSONDictionary)
        func symbol(_ component: String, gate: String) -> JSONDictionary {
            ["symbol": "part-symbol", "component": component, "gate": gate,
             "placement": ["shift": [0, 0], "angle": 0, "mirror": false]]
        }
        schematic["sheets"] = [
            "one": ["name": "One", "index": 1,
                    "symbols": ["r1-symbol": symbol("r1", gate: "gate"), "u1-a-symbol": symbol("u1", gate: "gate-a")]],
            "two": ["name": "Two", "index": 2,
                    "symbols": ["r2-symbol": symbol("r2", gate: "gate"), "u1-b-symbol": symbol("u1", gate: "gate-b")]],
        ]
        try put("top_schematic.json", schematic)
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))) as? JSONDictionary)
        block["nets"] = ["old": ["name": "OLD"], "new": ["name": ""]]
        block["components"] = [
            "r1": ["refdes": "R1", "value": "", "connections": ["gate/a": ["net": "old"]]],
            "r2": ["refdes": "R2", "value": "", "connections": ["gate/a": ["net": "old"]]],
            "u1": ["refdes": "U1", "value": "", "connections": ["gate-a/a": ["net": "old"], "gate-b/a": ["net": "old"]]],
        ]
        try put("top_block.json", block)
        try put("pool/symbols/cache/part-symbol.json", ["uuid": "part-symbol", "unit": "unit", "pins": [
            "a": ["position": [0, 0], "length": 1_250_000, "orientation": "left", "name_visible": false, "pad_visible": false],
        ]])
        try put("pool/units/cache/unit.json", ["uuid": "unit", "pins": ["a": ["primary_name": "1"]]])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try archive.write(to: url)
        return (try HorizontalProject.load(from: url), archive)
    }

    private func net(_ component: String, _ path: String, in archive: HorizontalProjectArchive) throws -> String? {
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))) as? JSONDictionary)
        return block.dictionaryMap("components")[component]?.dictionaryMap("connections")[path]?.string("net")
    }

    private func sheet(_ id: String, in project: HorizontalProject) throws -> HorizontalSchematicSheet {
        try XCTUnwrap(project.schematic?.sheets.first { $0.id.lowercased() == id })
    }

    func testSavingAnotherSheetKeepsAPinMovedOnItsOwnSheet() throws {
        var (project, archive) = try project()
        let url = try XCTUnwrap(project.schematic?.url)
        // On sheet one, R1's pin goes to the new net, and U1's gate there.
        var one = try sheet("one", in: project)
        one.componentInfo["r1"]?.connections["gate/a"] = .connected("new")
        one.componentInfo["u1"]?.connections["gate-a/a"] = .connected("new")
        try HorizontalProjectJSONApplicator.apply(schematicSheet: one, schematicURL: url, in: project, to: &archive)
        XCTAssertEqual(try net("r1", "gate/a", in: archive), "new")

        // Sheet two, as loaded before that edit, still has R1 and U1's gate A
        // on the old net; saving it after an edit of its own must not put
        // them back there.
        var two = try sheet("two", in: project)
        XCTAssertEqual(two.componentInfo["r1"]?.connections["gate/a"]?.netID, "old", "the stale copy the fix guards against")
        two.componentInfo["r2"]?.connections["gate/a"] = .connected("new")
        two.componentInfo["u1"]?.connections["gate-b/a"] = .notConnected
        try HorizontalProjectJSONApplicator.apply(schematicSheet: two, schematicURL: url, in: project, to: &archive)

        XCTAssertEqual(try net("r1", "gate/a", in: archive), "new", "R1 is drawn on sheet one only")
        XCTAssertEqual(try net("u1", "gate-a/a", in: archive), "new", "U1's gate A is drawn on sheet one only")
        XCTAssertEqual(try net("r2", "gate/a", in: archive), "new", "sheet two still writes its own gates")
        XCTAssertNil(try net("u1", "gate-b/a", in: archive), "a no-connect on sheet two's gate B is written too")

        project = try HorizontalProject.loadSnapshot(of: archive)
        XCTAssertEqual(try sheet("two", in: project).componentInfo["r1"]?.connections["gate/a"]?.netID, "new")
    }

    func testReplacingASheetBringsTheOtherSheetsCopiesUpToDate() throws {
        let (project, _) = try project()
        var schematic = try XCTUnwrap(project.schematic)
        var one = try sheet("one", in: project)
        one.componentInfo["r1"]?.connections["gate/a"] = .connected("new")
        one.componentInfo["u1"]?.connections.removeValue(forKey: "gate-a/a")
        // A gate the edited sheet doesn't draw is not its to change, even
        // in its own copy.
        one.componentInfo["r2"]?.connections["gate/a"] = .connected("new")
        schematic.replaceSheet(one)

        let two = try XCTUnwrap(schematic.sheets.first { $0.id.lowercased() == "two" })
        XCTAssertEqual(two.componentInfo["r1"]?.connections["gate/a"]?.netID, "new")
        XCTAssertNil(two.componentInfo["u1"]?.connections["gate-a/a"], "a pin taken off its net leaves the other copies too")
        XCTAssertEqual(two.componentInfo["u1"]?.connections["gate-b/a"]?.netID, "old", "the gate sheet two draws is its own")
        XCTAssertEqual(two.componentInfo["r2"]?.connections["gate/a"]?.netID, "old")
        XCTAssertEqual(schematic.sheets.first { $0.id.lowercased() == "one" }?.componentInfo["r1"]?.connections["gate/a"]?.netID, "new")
    }
}
