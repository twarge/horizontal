import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Loading the new-document template through the real project loader.
///
/// The template's job is to be a project the full pipeline accepts silently: a
/// board, a schematic with one sheet, a default net class, and not a single
/// diagnostic. A diagnostic on a brand-new document would greet every File >
/// New with a warning about a project the user hasn't touched yet.
final class HorizontalNewProjectLoadTests: XCTestCase {
    func testTemplateLoadsCleanlyWithBoardAndSchematic() throws {
        let packageURL = try writtenTemplate()

        let project = try HorizontalProject.load(from: packageURL)

        XCTAssertEqual(project.diagnostics.map(\.message), [])
        XCTAssertNotNil(project.board)
        XCTAssertNotNil(project.schematic)
        XCTAssertEqual(project.schematic?.sheets.count, 1)
        XCTAssertEqual(project.schematic?.sheets.first?.name, "Sheet 1")
        XCTAssertEqual(project.schematic?.netClasses.map(\.name), ["Default"])
        XCTAssertTrue(project.poolParts.isEmpty)
        // The project pool is there for parts placed from a library.
        XCTAssertEqual(project.poolDirectory, "pool")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("pool/pool.json").path))
    }

    /// Horizon keeps a project's pool at `pool/` when the project file does
    /// not say otherwise; documents made before new projects carried a pool
    /// name none, and placing a library part into them must still find it.
    func testAProjectFileWithoutAPoolDirectoryDefaultsToPool() throws {
        let packageURL = try writtenTemplate()
        let projectFileURL = packageURL.appendingPathComponent("Untitled.hprj")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: projectFileURL)) as? [String: Any])
        json.removeValue(forKey: "pool_directory")
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: projectFileURL)

        let project = try HorizontalProject.load(from: packageURL)
        XCTAssertEqual(project.poolDirectory, "pool")
    }

    func testTemplateBoardHasTheStockTwoLayerStackup() throws {
        let packageURL = try writtenTemplate()

        let board = try XCTUnwrap(HorizontalProject.load(from: packageURL).board)

        XCTAssertEqual(board.stackupLayers.map(\.layer), [0, -100])
        XCTAssertEqual(board.stackupLayers.map(\.copperThickness), [35_000, 35_000])
        XCTAssertTrue(board.tracks.isEmpty)
        XCTAssertTrue(board.packages.isEmpty)
    }

    /// A new board is a 50 mm square, the middle of its left edge at the
    /// origin, with a GND plane over each side of it: three polygons of the
    /// one square, and a power net for the planes, which take their settings
    /// from the rules. A via in its middle, its net set to GND, gives them
    /// copper of their net to keep, and they come poured.
    func testTemplateBoardIsA50MillimetreSquareWithGroundPlanesOnBothSides() throws {
        let board = try XCTUnwrap(HorizontalProject.load(from: writtenTemplate()).board)
        let square = [HorizontalPoint(x: 0, y: -25_000_000), HorizontalPoint(x: 50_000_000, y: -25_000_000),
                      HorizontalPoint(x: 50_000_000, y: 25_000_000), HorizontalPoint(x: 0, y: 25_000_000)]

        XCTAssertEqual(board.polygons.map(\.layer), [HorizontalBoardLayers.outline])
        XCTAssertEqual(board.polygons.first?.vertices, square)
        XCTAssertEqual(board.physicalBounds, HorizontalRect(points: square))

        let ground = try XCTUnwrap(board.netDetails.values.first { $0.name == "GND" })
        XCTAssertTrue(ground.isPower)
        XCTAssertEqual(board.netDetails.count, 1)
        XCTAssertEqual(board.planes.map(\.layer).sorted { ($0 ?? 0) > ($1 ?? 0) },
                       [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper])
        for plane in board.planes {
            XCTAssertEqual(plane.netID, ground.id)
            XCTAssertEqual(plane.fallbackPolygon?.vertices, square)
            XCTAssertEqual(plane.priority, 0)
            XCTAssertTrue(plane.fromRules)
            // One fill, kept by the via: the square less the rules' 0.25 mm
            // clearance to the board's edge and the pour's two 5 µm twiddles
            // (Horizon's `plane_update.cpp`).
            XCTAssertEqual(plane.fragments.map(\.orphan), [false])
            XCTAssertEqual(plane.fragments.first?.paths.count, 1, "a fill with no holes")
            let fill = HorizontalRect(points: plane.fragments.first?.paths.first ?? [])
            XCTAssertEqual([fill.minX, fill.minY, fill.maxX, fill.maxY], [260_000, -24_740_000, 49_740_000, 24_740_000])
        }

        XCTAssertEqual(board.vias.count, 1)
        let via = try XCTUnwrap(board.vias.first)
        XCTAssertEqual(via.position, HorizontalPoint(x: 25_000_000, y: 0))
        XCTAssertEqual(via.netSetID, ground.id)
        XCTAssertEqual(via.netID, ground.id)
        XCTAssertTrue(via.fromRules)
        XCTAssertEqual(via.size, 500_000)
        XCTAssertEqual(via.holeSize, 200_000)
        XCTAssertEqual(via.padstackID, HorizontalProjectArchive.horizonPoolTentedCircularVia)
    }

    /// The template has no pour to fill its planes; the project the app hands
    /// out has them poured, as a pour of its board fills them, so pouring it
    /// again, by hand or on its own, changes nothing.
    func testANewProjectsPlanesArePouredAsAPourFillsThem() throws {
        let template = try XCTUnwrap(HorizontalProject.load(from: writtenTemplate(poured: false)).board)
        XCTAssertEqual(template.planes.count, 2)
        XCTAssertTrue(template.planes.allSatisfy { $0.fragments.isEmpty })

        let board = try XCTUnwrap(HorizontalProject.load(from: writtenTemplate()).board)
        var unpoured = board
        for index in unpoured.planes.indices {
            unpoured.planes[index].fragments = []
        }
        let poured = HorizontalBoardPlaneUpdater.pour(in: unpoured, cache: HorizontalPlanePourCache())
        XCTAssertTrue(poured.isComplete)
        for plane in board.planes {
            let again = try XCTUnwrap(poured.board.planes.first { $0.id == plane.id })
            XCTAssertFalse(plane.fragments.isEmpty)
            XCTAssertEqual(plane.fragments.map(\.paths), again.fragments.map(\.paths), plane.id)
            XCTAssertEqual(plane.fragments.map(\.orphan), again.fragments.map(\.orphan), plane.id)
        }
        XCTAssertEqual(try HorizontalProjectJSONApplicator.planeCacheData(board: poured.board),
                       try HorizontalProjectJSONApplicator.planeCacheData(board: board),
                       "a pour writes the planes file the new project has")
    }

    /// The rules results sidebar has nothing to say about a new board's rules:
    /// every family whose last rule must match everything has one that does.
    func testTemplateRulesPassTheRulesCheck() throws {
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        let archive = try HorizontalProjectArchive.completeProject(from: packageURL)

        let rules = try HorizontalProjectJSONApplicator.boardRules(in: project, from: archive)
        let context = HorizontalBoardRuleContext(board: project.board, netClasses: project.schematic?.netClasses ?? [])

        XCTAssertEqual(HorizontalBoardRulesValidator.validateAll(rules: rules, context: context).map(\.title), [])
        for kind in HorizontalBoardRuleKind.visibleCases where kind.needsMatchAll {
            XCTAssertEqual(kind.instances(in: rules, context: context).count, 1, kind.title)
        }
    }

    /// What a new board's rules give it, from rules rather than from Horizon's
    /// fallbacks for a board with none (a 0 wide track, 0.1 mm everywhere).
    func testTemplateRulesGiveANewBoardItsClearancesAndWidths() throws {
        let board = try XCTUnwrap(HorizontalProject.load(from: writtenTemplate()).board)
        let rules = board.rules

        for layer in [0, -100] {
            let track = try XCTUnwrap(rules.trackWidth(net: nil, layer: layer))
            XCTAssertEqual(track.widths, HorizontalRuleTrackWidth.Widths(min: 125_000, max: 10_000_000, def: 250_000))
        }

        let copper = rules.clearanceCopper(net1: nil, net2: nil, layer: 0)
        XCTAssertFalse(copper.id.isEmpty)
        for first in HorizontalPatchType.allCases {
            for second in HorizontalPatchType.allCases {
                XCTAssertEqual(copper.clearance(first, second), 125_000, "\(first) / \(second)")
            }
        }

        let other = rules.clearanceCopperOther(net: nil, layer: -100)
        XCTAssertFalse(other.id.isEmpty)
        for copper in [HorizontalPatchType.track, .pad, .padTH, .via, .plane] {
            XCTAssertEqual(other.clearance(copper: copper, nonCopper: .boardEdge), 250_000, "\(copper)")
            XCTAssertEqual(other.clearance(copper: copper, nonCopper: .holeNPTH), 150_000, "\(copper)")
            XCTAssertEqual(other.clearance(copper: copper, nonCopper: .text), 125_000, "\(copper)")
        }

        let keepout = rules.clearanceCopperKeepout(net: nil, keepoutClass: "")
        XCTAssertFalse(keepout.id.isEmpty)
        XCTAssertEqual(keepout.clearance(.track), 0)

        // The router keeps 0.025 mm beyond each, where Horizon's is 0.05 mm.
        XCTAssertEqual([copper.routingOffset, other.routingOffset, keepout.routingOffset], [25_000, 25_000, 25_000])

        XCTAssertEqual(rules.planeRules.count, 1)
        XCTAssertEqual(board.ruleParameters["solder_mask_expansion"], 70_000)
    }

    func testTemplateCanvasesGetTheEmptyContentRegion() throws {
        // An empty document must never hand the canvases empty bounds: the fit
        // renders at one nanometer per pixel and the input transforms map every
        // click to the origin, so a brand-new project looked frozen. The new
        // board has its outline to fit; a blank one, and the empty sheet, the
        // region an empty canvas gets.
        let project = try HorizontalProject.load(from: writtenTemplate())
        XCTAssertEqual(project.schematic?.sheets.first?.bounds, .emptyContentCanvasRegion)
        let bounds = try XCTUnwrap(project.board?.bounds)
        XCTAssertLessThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 50_000_000)
        XCTAssertLessThan(bounds.width, HorizontalRect.emptyContentCanvasRegion.width, "it fits the board, not the empty region")

        let blank = try HorizontalProject.load(from: writtenTemplate(blankBoard: true))
        XCTAssertEqual(blank.board?.bounds, .emptyContentCanvasRegion)
    }

    func testBlockEditsApplyToATemplateProject() throws {
        // The block-level patchers throw when `nets` / `components` are absent
        // instead of creating them, so the template must ship both — otherwise
        // the first rename or net-class assignment on a new document fails.
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        let blockURL = try XCTUnwrap(
            project.blockFilename.map { project.baseURL.appendingPathComponent($0) }
        )

        XCTAssertNoThrow(
            try HorizontalProjectJSONApplicator.apply(
                netClassID: "some-class",
                forNetID: "some-net",
                blockURL: blockURL,
                in: project,
                to: &archive
            )
        )
        XCTAssertNoThrow(
            try HorizontalProjectJSONApplicator.apply(
                componentRefdes: "R1",
                forComponentID: "some-component",
                blockURL: blockURL,
                in: project,
                to: &archive
            )
        )
    }

    // MARK: - Helpers

    private func writtenTemplate(blankBoard: Bool = false, poured: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-new-project-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        let archive = poured
            ? HorizontalProjectArchive.newPouredProject(blankBoard: blankBoard)
            : HorizontalProjectArchive.newProject(blankBoard: blankBoard)
        try archive.write(to: packageURL)
        return packageURL
    }
}
