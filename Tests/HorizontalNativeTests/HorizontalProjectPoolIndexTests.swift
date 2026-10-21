import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A project pool's own items: Horizon indexes the whole pool directory, so a
/// part made in the project (by its editors, or by a generator) sits wherever
/// they put it under its kind's directory, named for what it is, rather than
/// at `<kind>/cache/<uuid>.json`. The loaders find them all the same.
final class HorizontalProjectPoolIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalProjectPoolIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ json: JSONDictionary, to path: String, in directory: URL? = nil) throws {
        let url = (directory ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    private func symbol(pinLength: Int) -> JSONDictionary {
        ["type": "symbol", "uuid": "symbol-1", "unit": "unit-1", "name": "Widget", "pins": [
            "pin-1": ["position": [0, 0], "length": pinLength, "orientation": "left", "name_visible": false, "pad_visible": false],
        ]]
    }

    /// A project whose part, entity, unit, symbol, package and frame all sit
    /// outside the pool's cache, as calypso's generated ones do, and a sheet
    /// drawing the part.
    private func loadProject(cachedSymbol: JSONDictionary? = nil) throws -> HorizontalProject {
        var archive = HorizontalProjectArchive.newProject()
        func put(_ path: String, _ json: JSONDictionary) throws {
            try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json))
        }
        try put("pool/units/mine/Widget.json", ["type": "unit", "uuid": "unit-1", "name": "Widget",
                                                 "pins": ["pin-1": ["primary_name": "IN", "direction": "input"]]])
        try put("pool/entities/mine/Widget.json", ["type": "entity", "uuid": "entity-1", "name": "Widget", "prefix": "W",
                                                    "gates": ["gate-1": ["name": "Main", "suffix": "", "unit": "unit-1"]]])
        try put("pool/symbols/mine/Widget.json", symbol(pinLength: 2_500_000))
        try put("pool/packages/mine/WDG-1/package.json", ["type": "package", "uuid": "package-1", "name": "WDG-1", "pads": [:]])
        try put("pool/parts/mine/WIDGET-1.json", ["type": "part", "uuid": "part-1", "entity": "entity-1", "package": "package-1",
                                                  "MPN": [false, "WIDGET-1"], "value": [false, ""], "manufacturer": [false, "Us"],
                                                  "description": [false, ""], "datasheet": [false, ""], "tags": [], "pad_map": [:]])
        try put("pool/frames/mine/Frame.json", ["type": "frame", "uuid": "frame-1", "name": "Our frame"])
        if let cachedSymbol {
            try put("pool/symbols/cache/symbol-1.json", cachedSymbol)
        }

        var schematic = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))) as? JSONDictionary)
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        schematic["sheets"] = [sheetID: [
            "name": "Sheet", "index": 1,
            "symbols": ["placed": ["symbol": "symbol-1", "component": "component-1", "gate": "gate-1",
                                   "placement": ["shift": [0, 0], "angle": 0, "mirror": false]]],
        ]]
        try put("top_schematic.json", schematic)
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))) as? JSONDictionary)
        block["components"] = ["component-1": ["refdes": "W1", "value": "", "part": "part-1", "entity": "entity-1", "connections": [:]]]
        try put("top_block.json", block)

        let url = root.appendingPathComponent("Test.horizontal")
        try archive.write(to: url)
        return try HorizontalProject.load(from: url)
    }

    func testTheProjectsOwnItemsLoadWhereverThePoolKeepsThem() throws {
        let project = try loadProject()
        XCTAssertFalse(project.diagnostics.contains { $0.message.contains("Could not resolve") },
                       project.diagnostics.map(\.message).joined(separator: "\n"))

        let sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let pin = try XCTUnwrap(sheet.symbolPins.first, "the symbol under symbols/mine/ is drawn")
        XCTAssertEqual(abs(pin.to.x - pin.from.x) + abs(pin.to.y - pin.from.y), 2_500_000)
        let component = try XCTUnwrap(sheet.componentInfo["component-1"])
        XCTAssertEqual(component.gateSymbolIDs.values.first, "symbol-1")
        XCTAssertEqual(component.details?.mpn, "WIDGET-1")
        XCTAssertEqual(component.details?.packageName, "WDG-1")

        let part = try XCTUnwrap(project.poolParts.first { $0.id == "part-1" }, "the part list offers the project's own part")
        XCTAssertEqual(part.mpn, "WIDGET-1")
        XCTAssertEqual(part.packageName, "WDG-1")
        XCTAssertEqual(part.refdesPrefix, "W")
        XCTAssertEqual(part.gates.map(\.symbolID), ["symbol-1"])

        let poolURL = project.baseURL.appendingPathComponent("pool")
        XCTAssertEqual(HorizontalSchematic.projectPoolFrames(poolURL: poolURL).map(\.name), ["Our frame"])
        XCTAssertEqual(HorizontalPoolPart.loadCached(id: "PART-1", from: poolURL)?.mpn, "WIDGET-1")
    }

    func testACacheCopyOfTheSameUUIDIsTheOneDrawn() throws {
        let project = try loadProject(cachedSymbol: symbol(pinLength: 5_000_000))
        let pin = try XCTUnwrap(project.schematic?.sheets.first?.symbolPins.first)
        XCTAssertEqual(abs(pin.to.x - pin.from.x) + abs(pin.to.y - pin.from.y), 5_000_000)
        XCTAssertEqual(project.poolParts.first { $0.id == "part-1" }?.gates.map(\.symbolID), ["symbol-1"],
                       "one symbol however many files carry its uuid")
    }

    func testABoardPlacesTheProjectsOwnPackage() throws {
        let pool = root.appendingPathComponent("pool", isDirectory: true)
        try write(["type": "package", "uuid": "package-1", "name": "WDG-1", "pads": [:], "polygons": [
            "polygon-1": ["layer": HorizontalBoardLayers.topCopper, "parameter_class": "", "vertices": [
                [-1_000_000, -500_000], [1_000_000, -500_000], [1_000_000, 500_000], [-1_000_000, 500_000],
            ].map { ["type": "line", "position": $0, "arc_center": [0, 0], "arc_reverse": false] as JSONDictionary }],
        ]], to: "packages/mine/WDG-1/package.json", in: pool)
        try write(["type": "part", "uuid": "part-1", "package": "package-1", "MPN": [false, "WIDGET-1"], "value": [false, ""]],
                  to: "parts/mine/WIDGET-1.json", in: pool)
        try write(["type": "block", "components": ["component-1": ["part": "part-1", "refdes": "W1", "connections": [:]]],
                   "nets": [:], "net_classes": [:]], to: "top_block.json")
        try write(["type": "board", "n_inner_layers": 0,
                   "stackup": ["0": ["thickness": 35_000, "substrate_thickness": 1_500_000],
                               "-100": ["thickness": 35_000, "substrate_thickness": 1_500_000]],
                   "packages": ["board-package-1": ["component": "component-1",
                                                    "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "flip": false]]],
                  to: "board.json")

        var diagnostics = [HorizontalDiagnostic]()
        let board = try HorizontalBoard.load(
            from: root.appendingPathComponent("board.json"),
            blockURL: root.appendingPathComponent("top_block.json"),
            planesURL: nil,
            poolURL: pool,
            diagnostics: &diagnostics
        )
        XCTAssertEqual(board.packages.count, 1, diagnostics.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(board.packagePolygons.count, 1, "the package under packages/mine/ draws its artwork")
    }

    func testTheIndexSeesFilesAddedAndRemovedAndLeavesTheCacheOut() throws {
        let pool = root.appendingPathComponent("pool", isDirectory: true)
        try write(["type": "pool", "uuid": HorizontalProjectArchive.projectPoolUUID], to: "pool.json", in: pool)
        try write(["type": "symbol", "uuid": "A"], to: "symbols/mine/A.json", in: pool)
        try write(["type": "symbol", "uuid": "cached"], to: "symbols/cache/cached.json", in: pool)
        // Another kind's file in the directory isn't a symbol.
        try write(["type": "unit", "uuid": "stray"], to: "symbols/mine/Stray.json", in: pool)
        XCTAssertEqual(Set(HorizontalProjectPoolIndex.items(.symbol, poolURL: pool).keys), ["a"])

        try write(["type": "symbol", "uuid": "b"], to: "symbols/mine/deeper/B.json", in: pool)
        XCTAssertEqual(Set(HorizontalProjectPoolIndex.items(.symbol, poolURL: pool).keys), ["a", "b"])
        try FileManager.default.removeItem(at: pool.appendingPathComponent("symbols/mine/A.json"))
        XCTAssertEqual(Set(HorizontalProjectPoolIndex.items(.symbol, poolURL: pool).keys), ["b"])
        XCTAssertEqual(HorizontalProjectPoolIndex.url(.symbol, "B", poolURL: pool)?.lastPathComponent, "B.json")
    }

    func testAPoolThatIsNotAProjectsIsNotWalked() throws {
        let pool = root.appendingPathComponent("horizon-pool", isDirectory: true)
        try write(["type": "pool", "uuid": "6d752bc3-29b3-45df-8cf2-1e3aacefbcc6", "name": "horizon-pool"], to: "pool.json", in: pool)
        try write(["type": "symbol", "uuid": "a"], to: "symbols/passive/A.json", in: pool)
        XCTAssertEqual(HorizontalProjectPoolIndex.items(.symbol, poolURL: pool), [:])
    }
}
