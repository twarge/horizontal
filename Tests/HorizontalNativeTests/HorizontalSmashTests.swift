import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Horizon's Smash and Unsmash, on a schematic symbol and a board package,
/// and a smashed symbol's texts kept through the sheet writer: a save of a
/// sheet used to delete every smashed symbol's texts on it, which is how
/// Billo's L3 and L4 came to draw neither refdes nor value.
final class HorizontalSmashTests: XCTestCase {
    private var packageURL: URL!
    private var partID = ""
    private var refdesTextID = ""
    private var valueTextID = ""

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-smash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        partID = try fabricateResistor(poolURL: packageURL.appendingPathComponent("pool"))
    }

    /// A two-pin resistor whose symbol draws $REFDES and $VALUE, the refdes
    /// somewhere else when the symbol is turned a quarter, and whose package
    /// has its $RD on the silkscreen and its $VAL on the assembly layer.
    private func fabricateResistor(poolURL: URL) throws -> String {
        let pin1 = HorizontalPoolItemFactory.newUUID(), pin2 = HorizontalPoolItemFactory.newUUID()
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.name = "Resistor"
        unit.pins = [pin1: HorizontalUnitPin(id: pin1, primaryName: "1"), pin2: HorizontalUnitPin(id: pin2, primaryName: "2")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gateID = try XCTUnwrap(entity.gates.keys.first)
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shapeID = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shapeID: HorizontalPadstackShape(id: shapeID, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        package.name = "0603"
        var padIDs = [String]()
        for (index, name) in ["1", "2"].enumerated() {
            let padID = HorizontalPoolItemFactory.newUUID()
            padIDs.append(padID)
            package.pads[padID] = HorizontalPad(
                id: padID, name: name, padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: Double(index * 1_600_000 - 800_000), y: 0), angle: 0, mirrored: false)
            )
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [padIDs[0]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin1),
                       padIDs[1]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin2)]
        part.attributes[.mpn] = HorizontalPartAttribute(value: "RC0603FR-0710KL")
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [
            pin1: HorizontalSymbolPin(id: pin1, position: HorizontalPoint(x: -2_500_000, y: 0), length: 2_500_000),
            pin2: HorizontalSymbolPin(id: pin2, position: HorizontalPoint(x: 2_500_000, y: 0), length: 2_500_000)
        ]

        let symbolURL = poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json")
        let packageFileURL = poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json")
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: symbolURL)
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: packageFileURL)
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))

        func text(_ text: String, layer: Int, at shift: [Int]) -> JSONDictionary {
            ["text": text, "layer": layer, "size": 1_500_000, "width": 0, "origin": "center", "font": "simplex",
             "from_smash": false, "placement": ["angle": 0, "mirror": false, "shift": shift]]
        }
        refdesTextID = HorizontalPoolItemFactory.newUUID()
        valueTextID = HorizontalPoolItemFactory.newUUID()
        var symbolJSON = try JSONHelper.loadDictionary(from: symbolURL)
        symbolJSON["texts"] = [refdesTextID: text("$REFDES", layer: 0, at: [-2_500_000, 2_500_000]),
                               valueTextID: text("$VALUE", layer: 0, at: [-2_500_000, -2_500_000])]
        symbolJSON["text_placements"] = ["90n": [refdesTextID: ["angle": 16_384, "mirror": false, "shift": [3_750_000, 1_250_000]]]]
        try HorizontalHorizonJSONWriter.data(symbolJSON).write(to: symbolURL)
        var packageJSON = try JSONHelper.loadDictionary(from: packageFileURL)
        packageJSON["texts"] = [HorizontalPoolItemFactory.newUUID(): text("$RD", layer: HorizontalBoardLayers.topSilkscreen, at: [0, 1_500_000]),
                                HorizontalPoolItemFactory.newUUID(): text("$VAL", layer: HorizontalBoardLayers.topAssembly, at: [0, 0])]
        try HorizontalHorizonJSONWriter.data(packageJSON).write(to: packageFileURL)
        return part.uuid
    }

    private func applying(_ operations: [JSONDictionary], to archive: HorizontalProjectArchive) throws -> HorizontalProjectArchive {
        let project = try HorizontalProject.loadSnapshot(of: archive)
        return try HorizontalCanvasProjectEdit.archive(applying: operations, to: archive, in: project).archive
    }

    /// R1, its symbol at (20, 30) turned `angle` degrees, mirrored or not.
    private func placed(angle: Double, mirror: Bool) throws -> HorizontalProjectArchive {
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        archive = try applying([
            ["op": "ensure_component", "refdes": "R1", "part": partID, "value": "10k"],
            ["op": "place_symbol", "component": "R1", "x_mm": 20, "y_mm": 30, "angle_deg": angle, "mirror": mirror],
        ], to: archive)
        return archive
    }

    private func sheet(_ archive: HorizontalProjectArchive) throws -> HorizontalSchematicSheet {
        try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).schematic?.sheets.first)
    }

    private func sheetJSON(_ archive: HorizontalProjectArchive) throws -> JSONDictionary {
        let schematic = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json")))
        return try XCTUnwrap(schematic.dictionaryMap("sheets").values.first)
    }

    private func save(_ sheet: HorizontalSchematicSheet, to archive: inout HorizontalProjectArchive) throws {
        let project = try HorizontalProject.loadSnapshot(of: archive)
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: XCTUnwrap(project.schematic?.url), in: project, to: &archive)
    }

    private func assertDrawnAlike(_ lhs: HorizontalText?, _ rhs: HorizontalText?, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let lhs = try XCTUnwrap(lhs, message, file: file, line: line), rhs = try XCTUnwrap(rhs, message, file: file, line: line)
        XCTAssertEqual(lhs.text, rhs.text, message, file: file, line: line)
        XCTAssertEqual(lhs.position.x, rhs.position.x, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(lhs.position.y, rhs.position.y, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(HorizontalPlacementTransform(shift: .zero, angle: lhs.angle, mirrored: false).angle,
                       HorizontalPlacementTransform(shift: .zero, angle: rhs.angle, mirrored: false).angle, message, file: file, line: line)
        XCTAssertEqual(lhs.mirrored, rhs.mirrored, message, file: file, line: line)
        XCTAssertEqual(lhs.layer, rhs.layer, message, file: file, line: line)
    }

    func testSmashLeavesTheSymbolsTextsWhereItDrewThem() throws {
        for (angle, mirror) in [(0.0, false), (90.0, false), (90.0, true), (180.0, true), (270.0, false)] {
            let label = "at \(angle)°\(mirror ? " mirrored" : "")"
            let archive = try placed(angle: angle, mirror: mirror)
            let before = try sheet(archive)
            let smashed = try applying([["op": "smash", "component": "R1"]], to: archive)
            let after = try sheet(smashed)

            let symbol = try XCTUnwrap(after.symbols.first)
            XCTAssertTrue(symbol.smashed, label)
            XCTAssertEqual(symbol.smashedTextIDs.count, 2, label)
            XCTAssertTrue(after.symbolTexts.filter { !$0.id.contains("/pin") }.isEmpty, "\(label): the symbol draws none of its own")
            try assertDrawnAlike(after.texts.first { $0.fromSmash && $0.text == "R1" }, before.symbolTexts.first { $0.text == "R1" }, "\(label): refdes")
            try assertDrawnAlike(after.texts.first { $0.fromSmash && $0.fileText == "$VALUE" },
                                 before.symbolTexts.first { $0.id.lowercased().hasSuffix(valueTextID.lowercased()) }, "\(label): value")
            XCTAssertEqual(Set(after.texts.filter(\.fromSmash).map(\.fileText)), ["$REFDES", "$VALUE"], "\(label): they go on following the part")

            let unsmashed = try sheet(applying([["op": "unsmash", "component": "R1"]], to: smashed))
            XCTAssertFalse(try XCTUnwrap(unsmashed.symbols.first).smashed, label)
            XCTAssertTrue(unsmashed.texts.isEmpty, "\(label): unsmash takes the texts away")
            try assertDrawnAlike(unsmashed.symbolTexts.first { $0.text == "R1" }, before.symbolTexts.first { $0.text == "R1" }, "\(label): drawn by the symbol again")
            XCTAssertEqual(try sheetJSON(applying([["op": "unsmash", "component": "R1"]], to: smashed)).dictionaryMap("symbols").values.first?["texts"] as? [String], [])
        }
    }

    /// The regression: the writer kept only the texts the sheet drew as its
    /// own, and a smashed symbol's were drawn as the symbol's, so every save
    /// of the sheet deleted them.
    func testASheetSaveKeepsMovesAndDeletesSmashedTexts() throws {
        var archive = try applying([["op": "smash", "component": "R1"]], to: placed(angle: 0, mirror: false))
        var loaded = try sheet(archive)
        try save(loaded, to: &archive)
        XCTAssertEqual(try sheetJSON(archive).dictionaryMap("texts").values.filter { $0.bool("from_smash") == true }.count, 2,
                       "an unchanged sheet keeps its smashed texts")
        XCTAssertEqual(try sheet(archive).texts.filter(\.fromSmash).count, 2)

        // Moved on its own, as the canvas moves a text.
        let refdes = try XCTUnwrap(loaded.texts.firstIndex { $0.text == "R1" })
        let refdesID = loaded.texts[refdes].id
        loaded.texts[refdes].position.x += 1_250_000
        try save(loaded, to: &archive)
        let movedJSON = try XCTUnwrap(try sheetJSON(archive).dictionaryMap("texts")[refdesID])
        XCTAssertEqual(movedJSON.string("text"), "$REFDES")
        XCTAssertEqual(movedJSON.bool("from_smash"), true)
        XCTAssertEqual(movedJSON.dictionary("placement")?.point("shift")?.x, loaded.texts[refdes].position.x)

        // One deleted on its own goes, and the symbol stops naming it.
        loaded = try sheet(archive)
        let valueID = try XCTUnwrap(loaded.texts.first { $0.fileText == "$VALUE" }?.id)
        loaded.texts.removeAll { $0.id == valueID }
        loaded.forgetSmashedText(valueID)
        try save(loaded, to: &archive)
        let json = try sheetJSON(archive)
        XCTAssertNil(json.dictionaryMap("texts")[valueID])
        XCTAssertEqual(json.dictionaryMap("symbols").values.first?["texts"] as? [String], [refdesID])

        // The symbol deleted without them: they go with it all the same.
        loaded = try sheet(archive)
        loaded.symbols.removeAll()
        try save(loaded, to: &archive)
        XCTAssertTrue(try sheetJSON(archive).dictionaryMap("texts").isEmpty, "no text is left for a symbol that is gone")
    }

    /// Billo's L4: smashed, naming texts its sheet no longer has.
    func testASmashedSymbolWhoseTextsAreGoneIsFlaggedAndPutRight() throws {
        var archive = try applying([["op": "smash", "component": "R1"]], to: placed(angle: 0, mirror: false))
        var schematic = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json")))
        var sheets = schematic.dictionaryMap("sheets")
        let sheetID = try XCTUnwrap(sheets.keys.first)
        sheets[sheetID]?["texts"] = JSONDictionary()
        schematic["sheets"] = sheets
        try archive.replaceRegularFileData(relativePath: "top_schematic.json", with: HorizontalHorizonJSONWriter.data(schematic))

        let lost = try sheet(archive)
        XCTAssertTrue(try XCTUnwrap(lost.symbols.first).smashed)
        XCTAssertEqual(try XCTUnwrap(lost.symbols.first).smashedTextIDs, [])
        XCTAssertTrue(HorizontalSchematicWarnings.findings(lost).contains { $0.title == "Smashed symbol has no texts" })

        var saved = archive
        try save(lost, to: &saved)
        XCTAssertEqual(try sheetJSON(saved).dictionaryMap("symbols").values.first?["texts"] as? [String], [],
                       "a save names only texts the sheet has, as Horizon's load prunes them")

        let resmashed = try sheet(applying([["op": "smash", "component": "R1"]], to: archive))
        XCTAssertEqual(Set(resmashed.texts.filter(\.fromSmash).map(\.fileText)), ["$REFDES", "$VALUE"], "smashing it again makes new ones")
        let unsmashed = try sheet(applying([["op": "unsmash", "component": "R1"]], to: archive))
        XCTAssertFalse(try XCTUnwrap(unsmashed.symbols.first).smashed)
        XCTAssertNotNil(unsmashed.symbolTexts.first { $0.text == "R1" }, "unsmashed, it draws its own again")
        XCTAssertFalse(HorizontalSchematicWarnings.findings(unsmashed).contains { $0.title == "Smashed symbol has no texts" })
    }

    func testSmashOnTheBoardTakesThePackagesSilkscreenTextsOnly() throws {
        var archive = try placed(angle: 0, mirror: false)
        archive = try applying([["op": "place_component", "component": "R1", "x_mm": 40, "y_mm": 25, "angle_deg": 90, "bottom": true]], to: archive)
        let before = try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).board)
        let silk = try XCTUnwrap(before.packageTexts.first { $0.text == "R1" })
        XCTAssertEqual(silk.layer, HorizontalBoardLayers.bottomSilkscreen)

        let smashed = try applying([["op": "smash", "component": "R1", "board": true]], to: archive)
        let after = try XCTUnwrap(HorizontalProject.loadSnapshot(of: smashed).board)
        XCTAssertTrue(try XCTUnwrap(after.packages.first).smashed)
        let copies = after.packageTexts.filter(\.fromSmash)
        XCTAssertEqual(copies.count, 1, "the assembly layer's value is not smashed")
        try assertDrawnAlike(copies.first, silk, "the refdes stays where the package drew it")
        XCTAssertEqual(copies.first?.fileText, "$RD")
        XCTAssertNotNil(after.packageTexts.first { !$0.fromSmash && $0.layer == HorizontalBoardLayers.bottomAssembly })

        let unsmashed = try XCTUnwrap(HorizontalProject.loadSnapshot(of: applying([["op": "unsmash", "component": "R1", "board": true]], to: smashed)).board)
        XCTAssertFalse(try XCTUnwrap(unsmashed.packages.first).smashed)
        XCTAssertTrue(unsmashed.packageTexts.filter(\.fromSmash).isEmpty)
        let board = try JSONHelper.loadDictionary(from: XCTUnwrap(applying([["op": "unsmash", "component": "R1", "board": true]], to: smashed)
            .regularFileData(relativePath: "board.json")))
        XCTAssertTrue((board["texts"] as? JSONDictionary ?? [:]).isEmpty)
    }

    func testSmashRefusesToMixASymbolInstanceWithAComponent() throws {
        let archive = try placed(angle: 0, mirror: false)
        let instance = try XCTUnwrap(try sheet(archive).symbols.first?.id)
        XCTAssertThrowsError(try applying([["op": "smash", "component": "R1", "symbol_instance": instance]], to: archive))
        XCTAssertThrowsError(try applying([["op": "smash", "symbol_instance": instance, "board": true]], to: archive))
        XCTAssertEqual(try sheet(applying([["op": "smash", "symbol_instance": instance]], to: archive)).texts.count, 2)
    }
}
