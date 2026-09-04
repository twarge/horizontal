import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The package editor's tools: renumber pads, courtyard and silkscreen
/// generation, the footprint generator, DXF import.
final class HorizontalPoolPackageToolsTests: XCTestCase {
    private var poolURL: URL!

    override func setUpWithError() throws {
        poolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolPackageToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: poolURL.appendingPathComponent("padstacks"), withIntermediateDirectories: true)
        HorizontalPoolPadstacks.invalidateCaches()
        let padstack: JSONDictionary = [
            "type": "padstack", "uuid": "ps-smd", "name": "SMD", "padstack_type": "top",
            "parameter_program": "", "parameter_set": ["pad_width": 1_000_000, "pad_height": 500_000, "corner_radius": 0],
            "parameters_required": [], "polygons": [:], "holes": [:],
            "shapes": ["sh": ["placement": ["shift": [0, 0], "angle": 0, "mirror": false], "layer": 0, "form": "rectangle",
                              "params": [1_000_000, 500_000], "parameter_class": "pad"]],
        ]
        try HorizontalHorizonJSONWriter.data(padstack).write(to: poolURL.appendingPathComponent("padstacks/smd.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: poolURL)
        HorizontalPoolPadstacks.invalidateCaches()
    }

    private func context() -> HorizontalPoolEditorContext {
        let items = [HorizontalPoolLibraryItem(
            id: "x|padstack|ps-smd", uuid: "ps-smd", name: "SMD", detail: "top", tags: "",
            category: .padstack, poolName: "t", poolURL: poolURL, url: poolURL.appendingPathComponent("padstacks/smd.json")
        )]
        return HorizontalPoolEditorContext(poolURL: poolURL, libraryIndex: HorizontalPoolLibraryIndex(items: items))
    }

    private func pad(_ name: String, _ x: Double, _ y: Double) -> HorizontalPad {
        HorizontalPad(id: "pad-\(name)", name: name, padstackID: "ps-smd",
                      placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: x, y: y), angle: 0, mirrored: false))
    }

    // MARK: - Renumber

    func testRenumberAlongAxes() {
        // A 2×2 grid: TL a, TR b, BL c, BR d.
        let pads = [pad("a", -1, 1), pad("b", 1, 1), pad("c", -1, -1), pad("d", 1, -1)]
        var settings = HorizontalRenumberPadsSettings()
        settings.xFirst = true; settings.right = true; settings.down = true
        XCTAssertEqual(HorizontalPoolPackage.renumberOrder(of: pads, settings: settings).map(\.name), ["a", "b", "c", "d"])
        settings.xFirst = false
        XCTAssertEqual(HorizontalPoolPackage.renumberOrder(of: pads, settings: settings).map(\.name), ["a", "c", "b", "d"])
        settings.right = false; settings.down = false
        XCTAssertEqual(HorizontalPoolPackage.renumberOrder(of: pads, settings: settings).map(\.name), ["d", "b", "c", "a"])
    }

    func testRenumberAroundTheCentre() {
        let pads = [pad("a", -1, 1), pad("b", 1, 1), pad("c", -1, -1), pad("d", 1, -1)]
        var settings = HorizontalRenumberPadsSettings()
        settings.circular = true
        settings.origin = .topLeft
        settings.clockwise = true
        XCTAssertEqual(HorizontalPoolPackage.renumberOrder(of: pads, settings: settings).map(\.name), ["a", "b", "d", "c"])
        settings.clockwise = false
        XCTAssertEqual(HorizontalPoolPackage.renumberOrder(of: pads, settings: settings).map(\.name), ["a", "c", "d", "b"])
        settings.origin = .bottomRight
        settings.clockwise = true
        XCTAssertEqual(HorizontalPoolPackage.renumberOrder(of: pads, settings: settings).map(\.name), ["d", "c", "a", "b"])
    }

    func testRenumberingAppliesPrefixStartAndStepToChosenPads() {
        var package = HorizontalPoolPackage(uuid: "k", name: "K")
        for pad in [pad("x", 0, 0), pad("y", 1, 0), pad("z", 2, 0)] {
            package.pads[pad.id] = pad
        }
        var settings = HorizontalRenumberPadsSettings()
        settings.prefix = "P"
        settings.start = 10
        settings.step = 5
        let renumbered = package.renumberingPads(ids: ["pad-x", "pad-z"], settings: settings)
        XCTAssertEqual(renumbered.pads["pad-x"]?.name, "P10")
        XCTAssertEqual(renumbered.pads["pad-z"]?.name, "P15")
        XCTAssertEqual(renumbered.pads["pad-y"]?.name, "y", "unselected pads keep their names")
    }

    // MARK: - Courtyard / silkscreen

    private func twoPadPackage() -> HorizontalPoolPackage {
        var package = HorizontalPoolPackage(uuid: "k", name: "R0603")
        package.pads["pad-1"] = pad("1", -800_000, 0)
        package.pads["pad-2"] = pad("2", 800_000, 0)
        package.drawing.polygons["body"] = HorizontalPoolPolygon(
            id: "body", layer: HorizontalBoardLayers.topPackage, parameterClass: "",
            vertices: [
                HorizontalPolygonVertex(position: HorizontalPoint(x: -1_600_000, y: -400_000)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: 1_600_000, y: -400_000)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: 1_600_000, y: 400_000)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: -1_600_000, y: 400_000)),
            ]
        )
        return package
    }

    func testGenerateCourtyardEnclosesPadsAndBody() throws {
        let package = twoPadPackage()
        let generated = try XCTUnwrap(package.generatingCourtyard(context: context()))
        let courtyard = try XCTUnwrap(generated.drawing.polygons.values.first { $0.layer == HorizontalBoardLayers.topCourtyard })
        XCTAssertEqual(courtyard.parameterClass, "courtyard")
        let xs = courtyard.vertices.map(\.position.x)
        let ys = courtyard.vertices.map(\.position.y)
        XCTAssertEqual(xs.min(), -1_600_000)
        XCTAssertEqual(xs.max(), 1_600_000)
        XCTAssertEqual(ys.min(), -400_000)
        XCTAssertEqual(ys.max(), 400_000)

        // Running it again modifies the existing courtyard rather than adding one.
        var wider = generated
        wider.pads["pad-3"] = pad("3", 3_000_000, 0)
        let again = try XCTUnwrap(wider.generatingCourtyard(context: context()))
        XCTAssertEqual(again.drawing.polygons.values.filter { $0.layer == HorizontalBoardLayers.topCourtyard }.count, 1)
        XCTAssertEqual(again.drawing.polygons[courtyard.id]?.vertices.map(\.position.x).max(), 3_500_000)

        XCTAssertNil(HorizontalPoolPackage(uuid: "e", name: "E").generatingCourtyard(context: context()), "nothing to enclose")
    }

    func testGenerateSilkscreenAvoidsPads() throws {
        let package = twoPadPackage()
        let generated = try XCTUnwrap(package.generatingSilkscreen(context: context()))
        let silk = generated.drawing.lines.values.filter { $0.layer == HorizontalBoardLayers.topSilkscreen }
        XCTAssertFalse(silk.isEmpty)
        XCTAssertTrue(silk.allSatisfy { $0.width == 150_000 })
        // The pads sit on the long edges (y = ±0.4 mm), so no silk line may
        // pass over them; every segment midpoint stays clear of the pad zones.
        for line in silk {
            let from = try XCTUnwrap(generated.drawing.junctions[line.from])
            let to = try XCTUnwrap(generated.drawing.junctions[line.to])
            let mid = HorizontalPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let overPad = abs(abs(mid.x) - 800_000) < 500_000 + 275_000 && abs(mid.y) < 250_000 + 275_000
            XCTAssertFalse(overPad, "silk crosses a pad at \(mid)")
        }
        // The outline was expanded by 0.275 mm: the far corners sit at ±1.875 mm.
        let xs = generated.drawing.junctions.values.map(\.x)
        XCTAssertEqual(xs.max().map { Int($0) }, 1_875_000)
        XCTAssertNil(HorizontalPoolPackage(uuid: "e", name: "E").generatingSilkscreen(context: context()), "no outline")
    }

    // MARK: - Footprint generator

    func testFootprintGeneratorDualQuadGrid() {
        let padstackJSON: JSONDictionary = ["parameter_set": ["pad_width": 1, "pad_height": 1, "corner_radius": 0]]
        var settings = HorizontalFootprintGeneratorSettings()
        settings.mode = .dual
        settings.padCount = 6
        settings.pitch = 1_000_000
        settings.spacing = 2_000_000
        settings.padWidth = 600_000
        settings.padHeight = 1_200_000
        settings.padstackID = "ps"
        let dual = HorizontalPoolPackage(uuid: "k", name: "K").appendingGeneratedPads(settings: settings, padstackJSON: padstackJSON)
        XCTAssertEqual(dual.pads.count, 6)
        let byName = Dictionary(uniqueKeysWithValues: dual.pads.values.map { ($0.name, $0) })
        XCTAssertEqual(byName["1"]?.placement.shift, HorizontalPoint(x: -2_000_000, y: 1_000_000))
        XCTAssertEqual(byName["3"]?.placement.shift, HorizontalPoint(x: -2_000_000, y: -1_000_000))
        XCTAssertEqual(byName["4"]?.placement.shift, HorizontalPoint(x: 2_000_000, y: -1_000_000))
        XCTAssertEqual(byName["6"]?.placement.shift, HorizontalPoint(x: 2_000_000, y: 1_000_000))
        XCTAssertEqual(byName["1"]?.placement.angle, 49_152)
        XCTAssertEqual(byName["4"]?.placement.angle, 16_384)
        XCTAssertEqual(byName["1"]?.parameterSet["pad_width"], 600_000)
        XCTAssertEqual(byName["1"]?.parameterSet["pad_height"], 1_200_000)
        XCTAssertEqual(byName["1"]?.parameterSet["corner_radius"], 150_000)

        settings.zigzag = true
        let zigzag = HorizontalPoolPackage(uuid: "k", name: "K").appendingGeneratedPads(settings: settings, padstackJSON: padstackJSON)
        let zig = Dictionary(uniqueKeysWithValues: zigzag.pads.values.map { ($0.name, $0) })
        XCTAssertEqual(zig["2"]?.placement.shift, HorizontalPoint(x: 2_000_000, y: 1_000_000))

        settings.mode = .quad
        settings.padCountV = 2
        settings.padCountH = 2
        settings.spacingV = 3_000_000
        let quad = HorizontalPoolPackage(uuid: "k", name: "K").appendingGeneratedPads(settings: settings, padstackJSON: padstackJSON)
        XCTAssertEqual(quad.pads.count, 8)
        let quadByName = Dictionary(uniqueKeysWithValues: quad.pads.values.map { ($0.name, $0) })
        XCTAssertEqual(quadByName["3"]?.placement.shift, HorizontalPoint(x: -500_000, y: -3_000_000))
        XCTAssertEqual(quadByName["8"]?.placement.shift, HorizontalPoint(x: -500_000, y: 3_000_000))
        XCTAssertEqual(quadByName["5"]?.placement.shift, HorizontalPoint(x: 2_000_000, y: -500_000))

        settings.mode = .grid
        settings.padCountH = 3
        settings.padCountV = 2
        settings.pitchV = 2_000_000
        let grid = HorizontalPoolPackage(uuid: "k", name: "K").appendingGeneratedPads(
            settings: settings,
            padstackJSON: ["parameter_set": ["pad_diameter": 1]]
        )
        let gridByName = Dictionary(uniqueKeysWithValues: grid.pads.values.map { ($0.name, $0) })
        XCTAssertEqual(Set(gridByName.keys), ["A1", "A2", "B1", "B2", "C1", "C2"])
        XCTAssertEqual(gridByName["A1"]?.placement.shift, HorizontalPoint(x: -1_000_000, y: 1_000_000))
        XCTAssertEqual(gridByName["C2"]?.placement.shift, HorizontalPoint(x: 1_000_000, y: -1_000_000))
        XCTAssertEqual(gridByName["A1"]?.parameterSet["pad_diameter"], 600_000)
        XCTAssertEqual(HorizontalFootprintGeneratorSettings.bgaLetter(20), "Y")
        XCTAssertEqual(HorizontalFootprintGeneratorSettings.bgaLetter(21), "AA")
        XCTAssertEqual(HorizontalFootprintGeneratorSettings.bgaLetter(22), "AB")
    }

    // MARK: - DXF

    func testDXFImportReadsLinesArcsAndPolylines() {
        let dxf = """
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        8
        0
        10
        0.0
        20
        0.0
        11
        10.0
        21
        0.0
        0
        ARC
        10
        0.0
        20
        0.0
        40
        5.0
        50
        0.0
        51
        90.0
        0
        LWPOLYLINE
        90
        3
        70
        1
        10
        0.0
        20
        0.0
        42
        1.0
        10
        2.0
        20
        0.0
        10
        2.0
        20
        2.0
        0
        CIRCLE
        10
        5.0
        20
        5.0
        40
        1.0
        0
        ENDSEC
        0
        EOF
        """
        let imported = HorizontalDXFImporter.parse(dxf)
        XCTAssertEqual(imported.lines.count, 1 + 2, "the line plus two straight polyline edges")
        XCTAssertEqual(imported.arcs.count, 1 + 1 + 2, "the arc, the bulged edge, two half circles")
        XCTAssertEqual(imported.lines.first?.1, HorizontalPoint(x: 10_000_000, y: 0))
        let arc = imported.arcs[0]
        XCTAssertEqual(arc.from, HorizontalPoint(x: 5_000_000, y: 0))
        XCTAssertEqual(Int(arc.to.x.rounded()), 0)
        XCTAssertEqual(Int(arc.to.y.rounded()), 5_000_000)
        // A bulge of 1 is a semicircle: its centre is the chord midpoint.
        let bulged = imported.arcs[1]
        XCTAssertEqual(bulged.center, HorizontalPoint(x: 1_000_000, y: 0))
        XCTAssertEqual(bulged.from, HorizontalPoint(x: 0, y: 0))

        let drawing = HorizontalPoolDrawing().adding(imported, layer: 20, width: 100_000)
        XCTAssertEqual(drawing.lines.count, 3)
        XCTAssertEqual(drawing.arcs.count, 4)
        XCTAssertTrue(drawing.lines.values.allSatisfy { $0.layer == 20 && $0.width == 100_000 })
        XCTAssertTrue(drawing.arcs.values.allSatisfy { drawing.junctions[$0.center] != nil })
    }

    // MARK: - Parametric tables

    func testParametricTablesLoadAndFormat() throws {
        let json: JSONDictionary = ["tables": [
            "resistors": ["display_name": "Resistors", "columns": [
                ["name": "value", "display_name": "Value", "type": "quantity", "unit": "Ω", "use_si": true, "digits": 2],
                ["name": "tolerance", "display_name": "Tolerance", "type": "quantity", "unit": "%", "use_si": false],
                ["name": "package", "display_name": "Package", "type": "enum", "items": ["0402", "0603"]],
            ]],
        ]]
        try HorizontalHorizonJSONWriter.data(json).write(to: poolURL.appendingPathComponent("tables.json"))
        let tables = HorizontalPoolParametricTables.load(poolURLs: [poolURL])
        XCTAssertEqual(tables.map(\.name), ["resistors"])
        let table = try XCTUnwrap(tables.first)
        XCTAssertEqual(table.columns.map(\.name), ["value", "tolerance", "package"])
        XCTAssertEqual(table.columns[2].items, ["0402", "0603"])
        XCTAssertEqual(table.columns[0].format("4700"), "4.7 kΩ")
        XCTAssertEqual(table.columns[0].format("0.001"), "1 mΩ")
        XCTAssertEqual(table.columns[1].format("1"), "1 %")

        XCTAssertEqual(HorizontalPoolParametricTables.parseQuantity("4.7k"), 4_700)
        XCTAssertEqual(HorizontalPoolParametricTables.parseQuantity("4.7 kΩ"), 4_700)
        XCTAssertEqual(try XCTUnwrap(HorizontalPoolParametricTables.parseQuantity("10u")), 10e-6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(HorizontalPoolParametricTables.parseQuantity("22n")), 22e-9, accuracy: 1e-15)
        XCTAssertEqual(HorizontalPoolParametricTables.parseQuantity("100"), 100)
        XCTAssertNil(HorizontalPoolParametricTables.parseQuantity("abc"))
        XCTAssertEqual(HorizontalPoolParametricTables.storedQuantity(4_700), "4700")
        XCTAssertEqual(HorizontalPoolParametricTables.storedQuantity(0.001), "0.001")
    }
}
