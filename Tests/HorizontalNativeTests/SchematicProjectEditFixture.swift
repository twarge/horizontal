import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A template project whose pool holds a two-pin resistor — a unit, an
/// entity, two symbols that draw the unit and a part — edited through the
/// same ops the app's controls send (`HorizontalCanvasProjectEdit`), each
/// batch one archive edit, as the app puts one on the undo stack.
final class SchematicProjectEditFixture {
    private(set) var archive: HorizontalProjectArchive
    private(set) var project: HorizontalProject
    let part: String
    let gate: String
    let symbol: String
    let otherSymbol: String
    let pins: [String]
    let poolURL: URL

    init(testCase: XCTestCase) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schematic-project-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)

        poolURL = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let first = HorizontalPoolItemFactory.newUUID(), second = HorizontalPoolItemFactory.newUUID()
        unit.pins = [first: HorizontalUnitPin(id: first, primaryName: "1"), second: HorizontalUnitPin(id: second, primaryName: "2")]
        pins = [first.lowercased(), second.lowercased()]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        gate = try XCTUnwrap(entity.gates.keys.first).lowercased()
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.name = "Resistor"
        symbol.pins = [
            first: HorizontalSymbolPin(id: first, position: .init(x: -5_000_000, y: 0), length: 2_500_000),
            second: HorizontalSymbolPin(id: second, position: .init(x: 5_000_000, y: 0), length: 2_500_000),
        ]
        var other = HorizontalPoolItemFactory.newSymbol(for: unit)
        other.name = "Resistor (US)"
        other.pins = [
            first: HorizontalSymbolPin(id: first, position: .init(x: 0, y: 5_000_000), length: 2_500_000),
            second: HorizontalSymbolPin(id: second, position: .init(x: 0, y: -5_000_000), length: 2_500_000),
        ]
        self.symbol = symbol.uuid.lowercased()
        otherSymbol = other.uuid.lowercased()
        let package = HorizontalPoolItemFactory.newPackage()
        let resistor = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part = resistor.uuid
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(other), to: poolURL.appendingPathComponent("symbols/cache/\(other.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(resistor), to: poolURL.appendingPathComponent("parts/cache/\(resistor.uuid).json"))
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
    }

    /// One batch, one archive edit: what the app's undo step is made of.
    @discardableResult
    func apply(_ ops: [JSONDictionary]) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project)
        archive = edited.archive
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        return edited.changes
    }

    var sheet: HorizontalSchematicSheet {
        get throws { try XCTUnwrap(project.schematic?.sheets.first) }
    }

    /// R1 (and more) drawn on the first sheet, nothing wired.
    func placeResistors(_ refdes: [String] = ["R1"]) throws {
        try apply(refdes.enumerated().flatMap { offset, refdes -> [JSONDictionary] in [
            ["op": "ensure_component", "refdes": refdes, "part": part],
            ["op": "place_symbol", "component": refdes, "gate": gate, "symbol": symbol, "x_mm": 20 + 30 * offset, "y_mm": 20],
        ] })
    }

    func symbol(_ refdes: String) throws -> HorizontalPlacement {
        let sheet = try sheet
        return try XCTUnwrap(sheet.symbols.first { symbol in
            symbol.componentID.flatMap { sheet.componentInfo[$0.lowercased()]?.refdes } == refdes
        })
    }

    /// The top block's JSON as the archive holds it.
    func blockJSON() throws -> JSONDictionary {
        let filename = try XCTUnwrap(project.blocks.first(where: \.isTop)?.blockFilename ?? project.blockFilename)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: filename))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    /// The first sheet's JSON as the archive holds it.
    func sheetJSON() throws -> JSONDictionary {
        let filename = try XCTUnwrap(project.blocks.first(where: \.isTop)?.schematicFilename ?? project.schematicFilename)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: filename))
        let schematic = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        return try XCTUnwrap(schematic.dictionaryMap("sheets").values.first)
    }
}
