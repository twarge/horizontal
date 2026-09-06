import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A part placed on the schematic reaches the board: the unplaced column at
/// once, the package on the board when it is placed there, and both in the
/// saved JSON.
final class HorizontalBoardNetlistSyncTests: XCTestCase {
    private var temporaryRoot: URL!
    private var testDefaults: UserDefaults!
    private var stockPoolURL: URL { temporaryRoot.appendingPathComponent("stock", isDirectory: true) }
    private var projectPoolURL: URL { temporaryRoot.appendingPathComponent("project/pool", isDirectory: true) }
    private let mm = 1_000_000.0

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalBoardNetlistSyncTests-\(UUID().uuidString)", isDirectory: true)
        testDefaults = UserDefaults(suiteName: "HorizontalBoardNetlistSyncTests-\(UUID().uuidString)")
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

    private func padstack(_ uuid: String, x: Double) -> [String: Any] {
        ["type": "padstack", "padstack_type": "top", "uuid": uuid, "name": "SMD",
         "shapes": ["shape-\(uuid)": ["form": "rectangle", "params": [Int(1 * mm), Int(1.2 * mm)],
                                      "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "layer": 0, "parameter_class": ""]],
         "holes": [:], "polygons": [:], "parameter_set": [:]]
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
             "pins": [:], "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]],
            to: "stock/symbols/passive/resistor.json"
        )
        try write(
            ["type": "entity", "uuid": "ent-1", "name": "Resistor", "manufacturer": "", "prefix": "R", "tags": [],
             "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-1"]]],
            to: "stock/entities/passive/resistor.json"
        )
        try write(padstack("ps-1", x: 0), to: "stock/padstacks/smd.json")
        try write(
            ["type": "package", "uuid": "pkg-1", "name": "R0603", "manufacturer": "", "tags": [],
             "pads": ["pad-1": ["name": "1", "padstack": "ps-1", "placement": ["shift": [Int(-0.8 * mm), 0], "angle": 0, "mirror": false], "parameter_set": [:]],
                      "pad-2": ["name": "2", "padstack": "ps-1", "placement": ["shift": [Int(0.8 * mm), 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
            to: "stock/packages/r0603/package.json"
        )
        try write(
            ["type": "part", "uuid": "part-1", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
             "MPN": [false, "RES-0603-10K"], "value": [false, "10k"], "manufacturer": [false, "Generic"],
             "description": [false, "Resistor"], "datasheet": [false, ""],
             "tags": ["resistor"], "inherit_tags": false, "inherit_model": true,
             "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]],
             "parametric": [:]],
            to: "stock/parts/passive/res-10k.json"
        )
    }

    /// The part cached into the project pool, as placing it from the Pools pane does.
    private func cachedPart() throws -> HorizontalPoolPart {
        let items = HorizontalPoolLibrary.items(inPool: stockPoolURL, poolName: "Stock")
        let item = try XCTUnwrap(items.first { $0.category == .part && $0.uuid == "part-1" })
        _ = try HorizontalPoolCacheImporter.cachePart(item, into: projectPoolURL)
        return try XCTUnwrap(HorizontalPoolPart.loadCached(id: "part-1", from: projectPoolURL))
    }

    private func component(_ id: String, connections: [String: String] = [:]) -> SchematicComponentInfo {
        SchematicComponentInfo(
            refdes: "R1",
            value: "10k",
            partID: "part-1",
            noPopulate: false,
            gateSuffixes: [:],
            gateSymbolIDs: [:],
            altPins: [:],
            connections: connections.mapValues { SchematicConnectionState.connected($0) },
            details: HorizontalComponentDetails(componentID: id, refdes: "R1", value: "10k", partID: "part-1", mpn: "RES-0603-10K")
        )
    }

    func testTheUnplacedColumnComesFromTheSchematicsComponents() {
        let objects = HorizontalBoard.placeableObjects(fromSchematicComponents: [
            "COMP-1": component("comp-1", connections: ["gate-1/pin-1": "NET-A"]),
            "comp-2": SchematicComponentInfo(refdes: "X1", value: "", partID: nil, noPopulate: false, gateSuffixes: [:], gateSymbolIDs: [:], altPins: [:], connections: [:], details: nil),
        ])
        XCTAssertEqual(objects.map(\.id), ["comp-1"], "only components with a part have a package to place")
        XCTAssertEqual(objects.first?.label, "R1")
        XCTAssertEqual(objects.first?.componentID, "comp-1")
        XCTAssertEqual(objects.first?.details?.connections, ["gate-1/pin-1": "net-a"])

        var board = HorizontalBoard.poolEditorBoard(uuid: "b", name: "B", url: URL(fileURLWithPath: "/tmp/b"))
        board.replacePlaceableObjects(objects)
        XCTAssertEqual(board.unplacedObjects.map(\.id), ["comp-1"])
        board.packages.append(HorizontalPlacement(id: "pkg", position: .zero, angle: 0, mirrored: false, label: "R1", componentID: "comp-1"))
        board.replacePlaceableObjects(objects)
        XCTAssertTrue(board.unplacedObjects.isEmpty, "a placed component leaves the column")
    }

    func testTheNetlistSignatureFollowsComponentsConnectionsAndNetsNotPositions() throws {
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let empty = sheet.netlistSignature

        sheet.componentInfo["comp-1"] = component("comp-1")
        let withComponent = sheet.netlistSignature
        XCTAssertNotEqual(withComponent, empty)

        sheet.componentInfo["comp-1"]?.connections["gate-1/pin-1"] = .connected("net-a")
        let wired = sheet.netlistSignature
        XCTAssertNotEqual(wired, withComponent)

        sheet.netDetails["net-a"] = HorizontalNetDetails(id: "net-a", name: "SIG")
        let named = sheet.netlistSignature
        XCTAssertNotEqual(named, wired)

        sheet.junctions["j"] = HorizontalPoint(x: mm, y: mm)
        sheet.netLines.append(HorizontalSegment(id: "l", from: .zero, to: HorizontalPoint(x: mm, y: mm), width: 0, layer: nil))
        XCTAssertEqual(sheet.netlistSignature, named, "geometry alone is not the netlist")
    }

    func testAComponentsPackageIsPlacedFromThePoolWithItsPadsOnTheirNets() throws {
        let part = try cachedPart()
        XCTAssertEqual(part.id, "part-1")
        let object = HorizontalUnplacedObject(
            id: "comp-1", label: "R1", subtitle: "Package", componentID: "comp-1", gateID: nil,
            details: HorizontalComponentDetails(
                componentID: "comp-1", refdes: "R1", value: "10k", partID: "part-1",
                connections: ["gate-1/pin-1": "net-a"]
            )
        )
        var board = HorizontalBoard.poolEditorBoard(uuid: "b", name: "B", url: URL(fileURLWithPath: "/tmp/b"))
        board.replacePlaceableObjects([object])
        board.netDetails["net-a"] = HorizontalNetDetails(id: "net-a", name: "SIG")

        let draft = try XCTUnwrap(HorizontalBoard.placingPackage(for: object, in: board, at: HorizontalPoint(x: 10 * mm, y: 5 * mm), poolURL: projectPoolURL))
        let placed = draft.board
        XCTAssertEqual(placed.packages.count, 1)
        let package = try XCTUnwrap(placed.packages.first)
        XCTAssertEqual(package.id, draft.placementID)
        XCTAssertEqual(package.componentID, "comp-1")
        XCTAssertEqual(package.position, HorizontalPoint(x: 10 * mm, y: 5 * mm))
        XCTAssertEqual(package.label, "R1")
        XCTAssertEqual(package.packageID, "pkg-1")
        XCTAssertTrue(placed.unplacedObjects.isEmpty, "the component left the column")

        let pads = placed.packagePads.filter { $0.id.hasPrefix(draft.placementID + "/") }
        XCTAssertFalse(pads.isEmpty)
        let padOne = pads.filter { $0.id.contains("/pad/pad-1/") }
        let padTwo = pads.filter { $0.id.contains("/pad/pad-2/") }
        XCTAssertFalse(padOne.isEmpty)
        XCTAssertTrue(padOne.allSatisfy { $0.netID == "net-a" }, "pad 1 is on the net its pin connects to")
        XCTAssertTrue(padTwo.allSatisfy { $0.netID == nil }, "pad 2's pin is unconnected")
        let padOnePosition = try XCTUnwrap(placed.packagePadPositions["\(draft.placementID)/pad-1"])
        XCTAssertEqual(padOnePosition.x, 10 * mm - 0.8 * mm, accuracy: 1)
    }

    func testAPlacedPackageReachesTheBoardJSONAndLoadsBack() throws {
        let part = try cachedPart()
        let packageURL = try writtenTemplate()
        // The template's pool becomes the pool the part was cached into.
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent("pool"))
        try FileManager.default.copyItem(at: projectPoolURL, to: packageURL.appendingPathComponent("pool"))
        var project = try HorizontalProject.load(from: packageURL)
        var board = try XCTUnwrap(project.board)
        let object = HorizontalUnplacedObject(
            id: "comp-1", label: "R1", subtitle: "Package", componentID: "comp-1", gateID: nil,
            details: HorizontalComponentDetails(componentID: "comp-1", refdes: "R1", value: "10k", partID: part.id)
        )
        board.replacePlaceableObjects([object])
        let draft = try XCTUnwrap(HorizontalBoard.placingPackage(
            for: object, in: board, at: HorizontalPoint(x: 3 * mm, y: 4 * mm), poolURL: packageURL.appendingPathComponent("pool")
        ))

        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        try HorizontalProjectJSONApplicator.apply(board: draft.board, in: project, to: &archive)
        let boardData = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let boardJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: boardData) as? [String: Any])
        let packages = try XCTUnwrap(boardJSON["packages"] as? [String: Any])
        let item = try XCTUnwrap(packages[draft.placementID] as? [String: Any], "a placed package is a new entry")
        XCTAssertEqual(item["component"] as? String, "comp-1")
        XCTAssertEqual(item["flip"] as? Bool, false)
        XCTAssertEqual(item["smashed"] as? Bool, false)
        XCTAssertEqual(item["fixed"] as? Bool, false)
        XCTAssertEqual((item["placement"] as? [String: Any])?["shift"] as? [Int], [Int(3 * mm), Int(4 * mm)])

        // The block must know the component for the loader to bake the package again.
        var blockData = try XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: blockData) as? [String: Any])
        block["components"] = ["comp-1": ["entity": "ent-1", "part": "part-1", "refdes": "R1", "value": "", "connections": [:], "alt_pins": [:], "pin_names": [:], "group": HorizontalProjectArchive.nullUUID, "tag": HorizontalProjectArchive.nullUUID]]
        blockData = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
        try archive.replaceRegularFileData(relativePath: "top_block.json", with: blockData)
        try archive.write(to: packageURL)

        project = try HorizontalProject.load(from: packageURL)
        let reloaded = try XCTUnwrap(project.board)
        XCTAssertEqual(reloaded.packages.map(\.id), [draft.placementID])
        XCTAssertEqual(reloaded.packages.first?.position, HorizontalPoint(x: 3 * mm, y: 4 * mm))
        XCTAssertFalse(reloaded.packagePads.isEmpty)
        XCTAssertTrue(reloaded.unplacedObjects.isEmpty)
    }

    private func writtenTemplate() throws -> URL {
        let root = temporaryRoot.appendingPathComponent("doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }
}
