import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The power net editor's model: which nets it lists and which it may
/// delete, deletion reaching the block, and the pin connector mark that
/// follows a pin's connection.
final class HorizontalPowerNetEditingTests: XCTestCase {
    private var temporaryRoot: URL!
    private var testDefaults: UserDefaults!
    private var stockPoolURL: URL { temporaryRoot.appendingPathComponent("stock", isDirectory: true) }
    private var projectPoolURL: URL { temporaryRoot.appendingPathComponent("project/pool", isDirectory: true) }
    private let mm = 1_000_000.0

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPowerNetEditingTests-\(UUID().uuidString)", isDirectory: true)
        testDefaults = UserDefaults(suiteName: "HorizontalPowerNetEditingTests-\(UUID().uuidString)")
        HorizontalPoolRegistryStore.defaults = testDefaults
        HorizontalPoolLibrary.invalidateCache()
        try writeStockPool()
        try write(HorizontalProjectArchive.projectPoolJSON(), to: "project/pool/pool.json")
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @discardableResult
    private func write(_ json: [String: Any], to relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func writeStockPool() throws {
        try write(["type": "pool", "uuid": "stock-pool", "name": "Stock", "default_via": HorizontalProjectArchive.nullUUID, "default_frame": HorizontalProjectArchive.nullUUID, "pools_included": []], to: "stock/pool.json")
        try write(
            ["type": "unit", "uuid": "unit-1", "name": "Resistor", "manufacturer": "",
             "pins": ["pin-1": ["primary_name": "1", "direction": "passive", "swap_group": 0, "names": []],
                      "pin-2": ["primary_name": "2", "direction": "passive", "swap_group": 0, "names": []]]],
            to: "stock/units/passive/resistor.json"
        )
        try write(
            ["type": "symbol", "uuid": "sym-1", "name": "Resistor", "unit": "unit-1",
             "pins": ["pin-1": ["position": [0, Int(2.5 * mm)], "length": Int(2.5 * mm), "orientation": "up", "name_visible": true, "pad_visible": true],
                      "pin-2": ["position": [0, Int(-2.5 * mm)], "length": Int(2.5 * mm), "orientation": "down", "name_visible": true, "pad_visible": true]],
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]],
            to: "stock/symbols/passive/resistor.json"
        )
        try write(
            ["type": "entity", "uuid": "ent-1", "name": "Resistor", "manufacturer": "", "prefix": "R", "tags": [],
             "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-1"]]],
            to: "stock/entities/passive/resistor.json"
        )
        try write(
            ["type": "padstack", "padstack_type": "top", "uuid": "ps-1", "name": "SMD",
             "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]],
            to: "stock/padstacks/smd.json"
        )
        try write(
            ["type": "package", "uuid": "pkg-1", "name": "R0603", "manufacturer": "", "tags": [],
             "pads": ["pad-1": ["name": "1", "padstack": "ps-1", "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
            to: "stock/packages/r0603/package.json"
        )
        try write(
            ["type": "part", "uuid": "part-1", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
             "MPN": [false, "RES"], "value": [false, "10k"], "manufacturer": [false, "Generic"],
             "description": [false, "Resistor"], "datasheet": [false, ""],
             "tags": [], "inherit_tags": false, "inherit_model": true,
             "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"]], "parametric": [:]],
            to: "stock/parts/passive/res-10k.json"
        )
    }

    private func writtenTemplate() throws -> URL {
        let root = temporaryRoot.appendingPathComponent("doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }

    private func powerNet(_ id: String, _ name: String, style: String = "gnd") -> HorizontalNetDetails {
        HorizontalNetDetails(id: id, name: name, isPower: true, powerSymbolStyle: style)
    }

    func testTheEditorListsPowerNetsAndKnowsWhichAreInUse() throws {
        let packageURL = try writtenTemplate()
        var project = try HorizontalProject.load(from: packageURL)
        var schematic = try XCTUnwrap(project.schematic)
        var sheet = schematic.sheets[0]
        sheet.netDetails["gnd"] = powerNet("gnd", "GND")
        sheet.netDetails["vcc"] = powerNet("vcc", "VCC", style: "dot")
        sheet.netDetails["sig"] = HorizontalNetDetails(id: "sig", name: "SIG")
        sheet.junctions["j"] = .zero
        sheet.junctionNetIDs["j"] = "gnd"
        schematic.sheets[0] = sheet

        let summaries = schematic.powerNetSummaries(currentSheetID: sheet.id)
        XCTAssertEqual(summaries.map(\.name), ["GND", "VCC"], "only power nets, by name")
        XCTAssertEqual(summaries.map(\.style), ["gnd", "dot"])
        XCTAssertEqual(summaries.map(\.isInUse), [true, false], "a junction on GND keeps it")

        // A net deleted on the edited sheet is gone even if another sheet still lists it.
        var other = sheet
        other.id = "other"
        other.junctions = [:]
        other.junctionNetIDs = [:]
        schematic.sheets.append(other)
        sheet.netDetails.removeValue(forKey: "vcc")
        sheet.removedNetIDs.insert("vcc")
        schematic.sheets[0] = sheet
        XCTAssertEqual(schematic.powerNetSummaries(currentSheetID: sheet.id).map(\.name), ["GND"])
        // Use anywhere counts: the other sheet's power symbol on GND.
        XCTAssertTrue(schematic.powerNetSummaries(currentSheetID: sheet.id)[0].isInUse)
        project.schematic = schematic
        _ = project
    }

    func testADeletedPowerNetLeavesTheBlockOnSave() throws {
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let schematicURL = packageURL.appendingPathComponent("top_schematic.json")
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)

        sheet.netDetails["gnd"] = powerNet("gnd", "GND")
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematicURL, in: project, to: &archive)
        XCTAssertNotNil(try nets(in: archive)["gnd"])

        sheet.netDetails.removeValue(forKey: "gnd")
        sheet.removedNetIDs.insert("gnd")
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematicURL, in: project, to: &archive)
        XCTAssertNil(try nets(in: archive)["gnd"], "the net is taken out of the block")
    }

    func testThePinConnectorMarkFollowsThePinsConnection() throws {
        let items = HorizontalPoolLibrary.items(inPool: stockPoolURL, poolName: "Stock")
        let item = try XCTUnwrap(items.first { $0.category == .part && $0.uuid == "part-1" })
        _ = try HorizontalPoolCacheImporter.cachePart(item, into: projectPoolURL)
        let part = try XCTUnwrap(HorizontalPoolPart.loadCached(id: "part-1", from: projectPoolURL))
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        let base = try XCTUnwrap(project.schematic?.sheets.first)
        let draft = try XCTUnwrap(HorizontalSchematic.placingPart(part, in: base, at: HorizontalPoint(x: 10 * mm, y: 10 * mm), poolURL: projectPoolURL))
        var sheet = draft.sheet
        let symbolID = draft.symbolInstanceID
        let componentID = try XCTUnwrap(sheet.symbols.first { $0.id == symbolID }?.componentID)

        func connectorSegments(_ pin: String) -> [HorizontalSegment] {
            sheet.symbolPins.filter { $0.id.hasPrefix("\(symbolID)/pin-connector/\(pin)") }
        }
        XCTAssertEqual(connectorSegments("pin-1").count, 4, "an unconnected pin shows the open box")
        let stem = try XCTUnwrap(sheet.symbolPins.first { $0.id == "\(symbolID)/pin/pin-1" })
        let boxPoints = connectorSegments("pin-1").flatMap { [$0.from, $0.to] }
        XCTAssertTrue(boxPoints.allSatisfy { ($0 - stem.from).length < 0.5 * mm }, "the box sits at the pin's end")

        sheet.componentInfo[componentID]?.connections["gate-1/pin-1"] = .connected("net-a")
        sheet.rebakePinConnector(symbolID: symbolID, pinID: "pin-1")
        XCTAssertTrue(connectorSegments("pin-1").isEmpty, "a connected pin has no mark")
        XCTAssertEqual(connectorSegments("pin-2").count, 4, "the other pin is untouched")

        sheet.componentInfo[componentID]?.connections["gate-1/pin-1"] = .notConnected
        sheet.rebakePinConnector(symbolID: symbolID, pinID: "pin-1")
        XCTAssertEqual(connectorSegments("pin-1").count, 2, "a pin marked not connected shows the cross")
        let crossPoints = connectorSegments("pin-1").flatMap { [$0.from, $0.to] }
        XCTAssertTrue(crossPoints.allSatisfy { ($0 - stem.from).length < 0.5 * mm })

        sheet.componentInfo[componentID]?.connections.removeValue(forKey: "gate-1/pin-1")
        sheet.rebakePinConnector(symbolID: symbolID, pinID: "pin-1")
        XCTAssertEqual(connectorSegments("pin-1").count, 4, "and back to the box")
    }

    private func nets(in archive: HorizontalProjectArchive) throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["nets"] as? [String: Any])
    }
}
