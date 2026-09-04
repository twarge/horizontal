import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The board-mode projections: a package, padstack or decal becomes a
/// synthetic board the canvas can edit, and comes back unchanged.
final class HorizontalPoolEntityEditingTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolEntityEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        HorizontalPoolPadstacks.invalidateCaches()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        HorizontalPoolPadstacks.invalidateCaches()
    }

    private static var placement: JSONDictionary { ["shift": [0, 0], "angle": 0, "mirror": false] }

    private static var smdPadstack: JSONDictionary { [
        "type": "padstack", "uuid": "ps-smd", "name": "SMD 1x0.5", "padstack_type": "top",
        "parameter_program": "", "parameter_set": [:], "parameters_required": [], "polygons": [:], "holes": [:],
        "shapes": ["sh-cu": ["placement": placement, "layer": 0, "form": "rectangle",
                             "params": [1_000_000, 500_000], "parameter_class": "pad"]],
    ] }

    private static var package: JSONDictionary { [
        "type": "package", "uuid": "pkg-1", "name": "R0603", "manufacturer": "", "tags": ["resistor"],
        "parameter_program": "", "parameter_set": ["courtyard_expansion": 250_000],
        "models": [:], "default_model": "",
        "junctions": ["j1": ["position": [-1_000_000, 500_000]], "j2": ["position": [1_000_000, 500_000]],
                      "j3": ["position": [0, 500_000]]],
        "lines": ["l1": ["from": "j1", "to": "j2", "width": 100_000, "layer": 20]],
        "arcs": ["a1": ["from": "j1", "to": "j2", "center": "j3", "width": 100_000, "layer": 50]],
        "texts": ["t1": ["origin": "center", "font": "simplex", "text": "$REFDES", "size": 1_000_000, "width": 0,
                         "layer": 20, "from_smash": false,
                         "placement": ["shift": [0, 1_500_000], "angle": 16_384, "mirror": true]]],
        "pads": [
            "pad-1": ["padstack": "ps-smd", "placement": ["shift": [-800_000, 0], "angle": 0, "mirror": false],
                      "name": "1", "parameter_set": [:]],
            "pad-2": ["padstack": "ps-smd", "placement": ["shift": [800_000, 0], "angle": 16_384, "mirror": false],
                      "name": "2", "parameter_set": ["solder_mask_expansion": 50_000]],
        ],
        "polygons": [
            "q-court": ["layer": 60, "parameter_class": "courtyard", "vertices": [
                ["type": "line", "position": [-1_500_000, -800_000], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "line", "position": [1_500_000, -800_000], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "line", "position": [1_500_000, 800_000], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "line", "position": [-1_500_000, 800_000], "arc_center": [0, 0], "arc_reverse": false],
            ]],
            "q-keep": ["layer": 0, "parameter_class": "", "vertices": [
                ["type": "line", "position": [-200_000, -200_000], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "arc", "position": [200_000, -200_000], "arc_center": [0, -200_000], "arc_reverse": true],
                ["type": "line", "position": [0, 200_000], "arc_center": [0, 0], "arc_reverse": false],
            ]],
        ],
        "keepouts": ["k1": ["polygon": "q-keep", "keepout_class": "no-vias", "exposed_cu_only": false,
                            "all_cu_layers": true, "patch_types_cu": ["via"]]],
        "dimensions": ["d1": ["p0": [-1_500_000, -1_200_000], "p1": [1_500_000, -1_200_000],
                              "label_distance": 300_000, "label_size": 1_000_000, "mode": "horizontal"]],
    ] }

    private func makeContext() -> HorizontalPoolEditorContext {
        let items = [
            HorizontalPoolLibraryItem(
                id: "x|padstack|ps-smd", uuid: "ps-smd", name: "SMD 1x0.5", detail: "top", tags: "",
                category: .padstack, poolName: "t", poolURL: temporaryRoot,
                url: temporaryRoot.appendingPathComponent("padstacks/smd.json")
            ),
        ]
        let padstackURL = temporaryRoot.appendingPathComponent("padstacks/smd.json")
        try? FileManager.default.createDirectory(at: padstackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? HorizontalHorizonJSONWriter.data(Self.smdPadstack).write(to: padstackURL)
        return HorizontalPoolEditorContext(poolURL: temporaryRoot, libraryIndex: HorizontalPoolLibraryIndex(items: items))
    }

    private func normalized(_ json: JSONDictionary) throws -> String {
        try HorizontalHorizonJSONWriter.string(json)
    }

    // MARK: - Package

    func testPackageProjectsToABoardAndBack() throws {
        let package = try HorizontalPoolPackage(json: Self.package)
        let context = makeContext()
        let board = package.makeBoard(context: context)

        XCTAssertEqual(board.poolItemID, "pkg-1")
        XCTAssertEqual(board.lines.count, 1)
        XCTAssertEqual(board.arcs.count, 1)
        XCTAssertEqual(board.texts.count, 1)
        XCTAssertEqual(board.polygons.map(\.id), ["q-court"], "the keepout polygon lives on the keepout, not in polygons")
        XCTAssertEqual(board.polygons.first?.parameterClass, "courtyard")
        XCTAssertEqual(board.keepouts.count, 1)
        XCTAssertEqual(board.dimensions.count, 1)
        XCTAssertEqual(board.pads.map(\.name), ["1", "2"])
        XCTAssertTrue(board.packagePads.contains { $0.id.hasPrefix("pkg-1/pad/pad-1/") }, "pads are baked under the package id")
        XCTAssertEqual(board.packagePadPositions["pkg-1/pad-1"]?.x, -800_000)
        // A mirrored text stores the board-side angle convention.
        XCTAssertEqual(board.texts.first?.mirrored, true)
        XCTAssertEqual(board.texts.first?.angle, 32_768 - 16_384)

        let roundTripped = package.applying(board: board)
        XCTAssertEqual(try normalized(roundTripped.json()), try normalized(Self.package))
    }

    func testMovingAPadRebakesOnlyThatPad() throws {
        let package = try HorizontalPoolPackage(json: Self.package)
        let context = makeContext()
        var board = package.makeBoard(context: context)
        let untouched = board.packagePads.filter { $0.id.hasPrefix("pkg-1/pad/pad-2/") }
        XCTAssertFalse(untouched.isEmpty)

        board.pads[0].placement.shift = HorizontalPoint(x: -1_200_000, y: 300_000)
        board.rebakePoolPad(id: "pad-1", context: context)

        let movedPad = board.packagePads.filter { $0.id.hasPrefix("pkg-1/pad/pad-1/") }
        XCTAssertFalse(movedPad.isEmpty)
        let center = HorizontalRect(points: movedPad.flatMap(\.vertices)).center
        XCTAssertEqual(center.x, -1_200_000, accuracy: 1)
        XCTAssertEqual(center.y, 300_000, accuracy: 1)
        XCTAssertEqual(board.packagePadPositions["pkg-1/pad-1"], HorizontalPoint(x: -1_200_000, y: 300_000))
        XCTAssertEqual(board.packagePads.filter { $0.id.hasPrefix("pkg-1/pad/pad-2/") }, untouched)

        let edited = package.applying(board: board)
        XCTAssertEqual(edited.pads["pad-1"]?.placement.shift, HorizontalPoint(x: -1_200_000, y: 300_000))
    }

    func testNewLinesGetJunctionsAndOldJunctionIDsSurvive() throws {
        let package = try HorizontalPoolPackage(json: Self.package)
        var board = package.makeBoard(context: makeContext())
        board.lines.append(HorizontalSegment(
            id: "l2",
            from: HorizontalPoint(x: -1_000_000, y: 500_000),
            to: HorizontalPoint(x: 0, y: -900_000),
            width: 0,
            layer: 20
        ))
        let edited = package.applying(board: board)
        let line = try XCTUnwrap(edited.drawing.lines["l2"])
        XCTAssertEqual(line.from, "j1", "an endpoint on an existing junction keeps its id")
        XCTAssertNotEqual(line.to, "j1")
        XCTAssertEqual(edited.drawing.junctions[line.to], HorizontalPoint(x: 0, y: -900_000))
        XCTAssertEqual(edited.drawing.junctions.count, 4)
    }

    func testNextPadName() {
        var package = HorizontalPoolPackage(uuid: "k", name: "K")
        XCTAssertEqual(package.nextPadName(), "1")
        package.pads["a"] = HorizontalPad(id: "a", name: "1", padstackID: "ps")
        package.pads["b"] = HorizontalPad(id: "b", name: "7", padstackID: "ps")
        XCTAssertEqual(package.nextPadName(), "8")
        package.pads["c"] = HorizontalPad(id: "c", name: "A", padstackID: "ps")
        XCTAssertEqual(package.nextPadName(), "8")
        // The canvas names pads from its own array, before they reach the model.
        XCTAssertEqual(HorizontalPoolPackage.nextPadName(among: []), "1")
        XCTAssertEqual(HorizontalPoolPackage.nextPadName(among: Array(package.pads.values)), "8")
        XCTAssertEqual(HorizontalPoolPackage.nextPadName(among: [HorizontalPad(id: "z", name: "A", padstackID: "ps")]), "")
    }

    /// Apply runs the package's parameter program over its stored polygons
    /// (courtyard expansion) and keeps the result; a package without a
    /// program is returned untouched.
    func testApplyingThePackageParameterProgramRewritesTheCourtyard() throws {
        var json = Self.package
        json["parameter_program"] = "3000000 2000000 set-polygon [ courtyard rectangle 0 0 ]\n"
        let package = try HorizontalPoolPackage(json: json)
        let applied = package.applyingParameterProgram()
        let courtyard = try XCTUnwrap(applied.drawing.polygons["q-court"])
        XCTAssertEqual(courtyard.vertices.count, 4)
        let xs = Set(courtyard.vertices.map { Int($0.position.x) })
        let ys = Set(courtyard.vertices.map { Int($0.position.y) })
        XCTAssertEqual(xs, [-1_500_000, 1_500_000])
        XCTAssertEqual(ys, [-1_000_000, 1_000_000])
        XCTAssertEqual(applied.drawing.polygons["q-keep"], package.drawing.polygons["q-keep"], "other polygons are untouched")
        XCTAssertEqual(applied.pads, package.pads)
        XCTAssertEqual(applied.parameterProgram, package.parameterProgram)

        let untouched = try HorizontalPoolPackage(json: Self.package)
        XCTAssertEqual(untouched.applyingParameterProgram(), untouched)
    }

    // MARK: - Padstack

    private static var throughHolePadstack: JSONDictionary { [
        "type": "padstack", "uuid": "ps-th", "name": "TH", "well_known_name": "", "padstack_type": "through",
        "parameter_program": "get-parameter [ pad_diameter ]\nset-shape [ pad circle ]\nget-parameter [ hole_diameter ]\nset-hole [ hole round ]\n",
        "parameter_set": ["pad_diameter": 1_600_000, "hole_diameter": 800_000],
        "parameters_required": ["hole_diameter", "pad_diameter"],
        "polygons": [:],
        "holes": ["h1": ["placement": placement, "diameter": 700_000, "length": 700_000, "shape": "round",
                         "plated": true, "parameter_class": "hole"]],
        "shapes": [
            "s-top": ["placement": placement, "layer": 0, "form": "circle", "params": [1_500_000], "parameter_class": "pad"],
            "s-bot": ["placement": placement, "layer": -100, "form": "circle", "params": [1_500_000], "parameter_class": "pad"],
            "s-slot": ["placement": ["shift": [2_000_000, 0], "angle": 0, "mirror": false], "layer": 10,
                       "form": "obround", "params": [1_000_000, 500_000], "parameter_class": ""],
        ],
    ] }

    func testPadstackProjectsShapesHolesAndBack() throws {
        let padstack = try HorizontalPoolPadstack(json: Self.throughHolePadstack)
        let board = padstack.makeBoard(context: makeContext())

        XCTAssertEqual(board.padstackShapes.count, 3)
        XCTAssertEqual(board.holes.count, 1)
        XCTAssertEqual(board.holes.first?.parameterClass, "hole")
        let baked = board.packagePads
        XCTAssertEqual(baked.count, 3)
        XCTAssertTrue(baked.contains { $0.id == "pad/ps-th/shape/s-top/layer/0" })
        let slot = try XCTUnwrap(baked.first { $0.id.contains("s-slot") })
        let slotBounds = HorizontalRect(points: slot.vertices)
        XCTAssertEqual(slotBounds.maxX - slotBounds.minX, 1_000_000, accuracy: 1)
        XCTAssertEqual(slotBounds.maxY - slotBounds.minY, 500_000, accuracy: 1)
        XCTAssertEqual(slotBounds.center.x, 2_000_000, accuracy: 1)

        let roundTripped = padstack.applying(board: board)
        XCTAssertEqual(try normalized(roundTripped.json()), try normalized(Self.throughHolePadstack))
    }

    func testApplyingTheParameterProgramRewritesStoredShapes() throws {
        let padstack = try HorizontalPoolPadstack(json: Self.throughHolePadstack)
        let applied = padstack.applyingParameterProgram()
        XCTAssertEqual(applied.shapes["s-top"]?.params, [1_600_000])
        XCTAssertEqual(applied.shapes["s-bot"]?.params, [1_600_000])
        XCTAssertEqual(applied.shapes["s-slot"]?.params, [1_000_000, 500_000], "shapes of another class are untouched")
        XCTAssertEqual(applied.holes["h1"]?.diameter, 800_000)
    }

    func testMovingAShapeRebakesItsPolygon() throws {
        let padstack = try HorizontalPoolPadstack(json: Self.throughHolePadstack)
        var board = padstack.makeBoard(context: makeContext())
        guard let index = board.padstackShapes.firstIndex(where: { $0.id == "s-top" }) else {
            return XCTFail("missing shape")
        }
        board.padstackShapes[index].placement.shift = HorizontalPoint(x: 500_000, y: 0)
        board.rebakePadstackShape(id: "s-top")
        let polygon = try XCTUnwrap(board.packagePads.first { $0.id == "pad/ps-th/shape/s-top/layer/0" })
        XCTAssertEqual(HorizontalRect(points: polygon.vertices).center.x, 500_000, accuracy: 1)
        XCTAssertEqual(board.packagePads.count, 3)
    }

    // MARK: - Decal

    func testDecalRoundTrip() throws {
        let json: JSONDictionary = [
            "type": "decal", "uuid": "d1", "name": "Logo",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [5_000_000, 0]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 150_000, "layer": 20]],
            "arcs": [:],
            "polygons": ["p1": ["layer": 50, "parameter_class": "", "vertices": [
                ["type": "line", "position": [0, 0], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "line", "position": [1, 0], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "line", "position": [0, 1], "arc_center": [0, 0], "arc_reverse": false],
            ]]],
            "texts": ["t1": ["origin": "baseline", "font": "simplex", "text": "OSHW", "size": 1_500_000, "width": 0,
                             "layer": 20, "from_smash": false, "placement": Self.placement]],
        ]
        let decal = try HorizontalPoolDecal(json: json)
        let board = decal.makeBoard(context: makeContext())
        XCTAssertEqual(board.lines.count, 1)
        XCTAssertEqual(board.polygons.count, 1)
        XCTAssertEqual(board.texts.first?.text, "OSHW")
        XCTAssertEqual(try normalized(decal.applying(board: board).json()), try normalized(json))
    }

    // MARK: - Context

    func testPackageLocalPadstacksWinAndAreFlagged() throws {
        let poolPadstack = temporaryRoot.appendingPathComponent("padstacks/shared.json")
        let localDirectory = temporaryRoot.appendingPathComponent("packages/x/padstacks", isDirectory: true)
        try FileManager.default.createDirectory(at: poolPadstack.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(["type": "pool", "uuid": "p"]).write(to: temporaryRoot.appendingPathComponent("pool.json"))
        try HorizontalHorizonJSONWriter.data([
            "type": "padstack", "uuid": "ps-x", "name": "Pool copy", "padstack_type": "top",
            "polygons": [:], "holes": [:], "shapes": [:],
        ]).write(to: poolPadstack)
        try HorizontalHorizonJSONWriter.data([
            "type": "padstack", "uuid": "ps-x", "name": "Local copy", "padstack_type": "top",
            "polygons": [:], "holes": [:], "shapes": [:],
        ]).write(to: localDirectory.appendingPathComponent("local.json"))

        let context = HorizontalPoolEditorContext(
            poolURL: temporaryRoot,
            packageDirectoryURL: temporaryRoot.appendingPathComponent("packages/x", isDirectory: true)
        )
        XCTAssertEqual(context.padstackJSON(id: "ps-x")?["name"] as? String, "Local copy")
        XCTAssertEqual(context.padstackDisplayName(id: "ps-x"), "Local copy")
        let choices = context.padstackChoices()
        XCTAssertEqual(choices.first?.name, "Local copy")
        XCTAssertEqual(choices.first?.isPackageLocal, true)
        XCTAssertEqual(choices.filter { $0.id == "ps-x" }.count, 1, "the pool copy of the same padstack is not listed twice")
    }
}
