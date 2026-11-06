import XCTest
#if canImport(HorizontalStepImporter)
import HorizontalStepImporter
#endif
@testable import HorizontalNative

/// The STEP export's copper and its leaving out of low components, both off
/// unless asked for. The board is the Gerber fixture's four layers, its
/// substrate 0.9 mm and every copper layer 35 µm, cut to a 20 by 10 mm
/// outline; its component models are boxes this test writes with the board
/// exporter itself.
final class HorizontalSTEPExportTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [HorizontalPoint] {
        [point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1)]
    }

    private var outline: HorizontalPolygon {
        HorizontalPolygon(id: "outline", vertices: square(0, 0, 20, 10), layer: HorizontalBoardLayers.outline)
    }

    private func track(_ id: String, layer: Int) -> HorizontalSegment {
        HorizontalSegment(id: id, from: point(2, 5), to: point(8, 5), width: 200_000, layer: layer, netID: nil)
    }

    /// A track on each of the four copper layers.
    private var fourLayerBoard: HorizontalBoard {
        Fixture.board(
            tracks: [Fixture.top, Fixture.inner1, Fixture.inner2, Fixture.bottom].map { track("t\($0)", layer: $0) },
            polygons: [outline]
        )
    }

    private var directory: URL!

    override func setUpWithError() throws {
        #if !canImport(HorizontalStepImporter)
        throw XCTSkip("HorizontalStepImporter unavailable")
        #endif
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalSTEPExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct Export {
        var text: String
        var report: HorizontalExportBackend.STEPExportReport
        var zRange: ClosedRange<Double>
    }

    private func export(_ board: HorizontalBoard, _ configure: (inout HorizontalSTEPExportSettings) -> Void = { _ in }) throws -> Export {
        let project = Fixture.project(board: board)
        var settings = HorizontalExportSettings(project: project).boardSTEP
        configure(&settings)
        let url = directory.appendingPathComponent("\(UUID().uuidString).step")
        let report = try HorizontalExportBackend.exportBoardSTEP(project: project, settings: settings, to: url)
        return Export(text: try String(contentsOf: url, encoding: .utf8), report: report, zRange: try zRange(of: url))
    }

    /// How low and how high the file's geometry reaches.
    private func zRange(of url: URL) throws -> ClosedRange<Double> {
        var mesh = HNStepMesh()
        XCTAssertTrue(url.path.withCString { HNStepImport($0, &mesh) }, "the export reads back")
        defer { HNStepMeshFree(&mesh) }
        let vertices = UnsafeBufferPointer(start: mesh.vertices, count: Int(mesh.vertexCount))
        let z = vertices.map { Double($0.z) }
        return try XCTUnwrap(z.min())...(try XCTUnwrap(z.max()))
    }

    /// A box model `height` mm tall standing on its origin, written as a STEP
    /// file: `width` by `depth`, from y = 0.
    private func boxModel(_ name: String, width: Double = 1, depth: Double = 1, height: Double) throws -> URL {
        let url = directory.appendingPathComponent("\(name).step")
        let outline = [
            HNStepPoint(x: -width / 2, y: 0), HNStepPoint(x: width / 2, y: 0),
            HNStepPoint(x: width / 2, y: depth), HNStepPoint(x: -width / 2, y: depth)
        ]
        let written = url.path.withCString { path in
            name.withCString { label in
                outline.withUnsafeBufferPointer { HNStepExportBoard(path, $0.baseAddress, 4, nil, 0, height, label) }
            }
        }
        XCTAssertTrue(written, "the \(name) model is written")
        return url
    }

    private func package(_ refdes: String, at x: Double, model url: URL, angle: Int = 0, bottom: Bool = false) -> HorizontalPlacement {
        HorizontalPlacement(
            id: refdes, position: point(x, 5), angle: angle, mirrored: bottom, label: refdes,
            model3D: HorizontalPackage3DModel(
                id: refdes, filename: url.lastPathComponent, fileURL: url,
                x: 0, y: 0, z: 0, roll: 0, pitch: 0, yaw: 0, heightTop: 0, heightBottom: 0
            )
        )
    }

    // MARK: Copper

    /// Copper is off unless asked for, as is leaving out small components,
    /// whose size is 2 mm: the file is the board body, 0.9 mm thick, with no
    /// copper part.
    func testCopperIsLeftOutByDefault() throws {
        let settings = HorizontalExportSettings(project: Fixture.project(board: fourLayerBoard)).boardSTEP
        XCTAssertEqual(settings.copperLayers, .none)
        XCTAssertFalse(settings.omitSmallComponents)
        XCTAssertEqual(settings.minimumComponentSizeMM, 2)

        let export = try export(fourLayerBoard)
        XCTAssertFalse(export.text.contains("Copper"))
        XCTAssertEqual(export.zRange.lowerBound, 0, accuracy: 1e-4)
        XCTAssertEqual(export.zRange.upperBound, 0.9, accuracy: 1e-4)
    }

    /// Top and bottom copper stand on the board's faces, one part each
    /// named for its layer, 35 µm proud of them; the inner layers stay out.
    func testTopAndBottomCopperStandOnTheBoardFaces() throws {
        let export = try export(fourLayerBoard) { $0.copperLayers = .outer }
        XCTAssertTrue(export.text.contains("'Top Copper'"))
        XCTAssertTrue(export.text.contains("'Bottom Copper'"))
        XCTAssertFalse(export.text.contains("'Inner 1'"))
        XCTAssertFalse(export.text.contains("'Inner 2'"))
        XCTAssertEqual(export.zRange.lowerBound, -0.035, accuracy: 1e-4)
        XCTAssertEqual(export.zRange.upperBound, 0.935, accuracy: 1e-4)
        XCTAssertEqual(HorizontalExportBackend.stepExportNote(
            HorizontalSTEPExportSettings(filename: "x", labelPrefix: "", include3DModels: false, copperLayers: .outer),
            report: export.report
        ), " (with top and bottom copper)")
    }

    /// All layers puts each inner layer inside the board, under the
    /// substrate of the layers above it.
    func testAllCopperLayersPutTheInnerLayersInsideTheBoard() throws {
        let layers = HorizontalExportBackend.stepCopperLayers(
            for: fourLayerBoard, selection: .all, boardThickness: 0.9, holes: []
        )
        XCTAssertEqual(layers.map(\.layer), [Fixture.top, Fixture.inner1, Fixture.inner2, Fixture.bottom])
        for (layer, z) in zip(layers, [0.9, 0.565, 0.265, -0.035]) {
            XCTAssertEqual(layer.z, z, accuracy: 1e-9, "layer \(layer.layer)")
            XCTAssertEqual(layer.thickness, 0.035, accuracy: 1e-9)
        }

        let export = try export(fourLayerBoard) { $0.copperLayers = .all }
        for name in ["Top Copper", "Inner 1", "Inner 2", "Bottom Copper"] {
            XCTAssertTrue(export.text.contains("'\(name)'"), name)
        }
        XCTAssertEqual(export.zRange.lowerBound, -0.035, accuracy: 1e-4)
        XCTAssertEqual(export.zRange.upperBound, 0.935, accuracy: 1e-4)
    }

    /// A layer's copper is one: a fill, a track over it and a via's ring are
    /// a single slab, less the via's drill and a slot's, round and long as
    /// they are and no smaller. With no holes given, as when the board
    /// leaves out holes under the minimum diameter, the copper is whole.
    func testCopperIsMadeOneAndDrilled() throws {
        let fill = HorizontalPlaneFragment(paths: [square(1, 1, 9, 9)], orphan: false)
        let plane = HorizontalPlane(
            id: "p", netID: "gnd", polygonID: "p/polygon", layer: Fixture.top, priority: 0,
            fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: [fill]
        )
        let via = HorizontalMarker(
            id: "v", position: point(5, 5), size: 600_000, holeSize: 300_000, layer: nil,
            connectedLayers: [Fixture.top, Fixture.bottom]
        )
        let slot = HorizontalHole(
            id: "slot", position: point(5, 3), diameter: 500_000, length: 2_000_000, shape: .slot, plated: true
        )
        let board = Fixture.board(tracks: [track("t", layer: Fixture.top)], vias: [via], polygons: [outline], planes: [plane], holes: [slot])

        let drilled = HorizontalExportBackend.stepCopperLayers(
            for: board, selection: .outer, boardThickness: 0.9, holes: board.viaHoles + board.holes
        )
        let top = try XCTUnwrap(drilled.first { $0.layer == Fixture.top })
        XCTAssertEqual(top.fragments.count, 1, "the fill, the track and the ring are one")
        let paths = try XCTUnwrap(top.fragments.first)
        XCTAssertEqual(paths.count, 3, "an outline and two holes")
        let holes = paths.dropFirst().sorted { HorizontalPolygonBoolean.area($0) < HorizontalPolygonBoolean.area($1) }
        // The drill's 0.15 mm radius, and the 3 µm the copper is shrunk by.
        let drillArea = HorizontalPolygonBoolean.area(holes[0]) / 1e12
        XCTAssertGreaterThan(drillArea, Double.pi * 0.15 * 0.15)
        XCTAssertLessThan(drillArea, Double.pi * 0.154 * 0.154)
        let slotXs = holes[1].map(\.x)
        XCTAssertGreaterThanOrEqual((slotXs.max()! - slotXs.min()!) / 1e6, 2, "the slot is as long as it is")
        let bottom = try XCTUnwrap(drilled.first { $0.layer == Fixture.bottom })
        XCTAssertEqual(bottom.fragments.map(\.count), [2], "the via's ring, drilled")

        let whole = HorizontalExportBackend.stepCopperLayers(for: board, selection: .outer, boardThickness: 0.9, holes: [])
        XCTAssertEqual(whole.first { $0.layer == Fixture.top }?.fragments.map(\.count), [1])
    }

    /// Copper drawn round is round in the file: a via's ring, a 32-gon to
    /// the Gerber writer, is a slab with a round wall in and out on each
    /// side, where its chords made 64 flat walls. The board, a slab with
    /// its drill, is seven faces; each ring is four.
    func testRoundCopperIsWrittenRound() throws {
        let via = HorizontalMarker(
            id: "v", position: point(5, 5), size: 600_000, holeSize: 300_000, layer: nil,
            connectedLayers: [Fixture.top, Fixture.bottom]
        )
        let export = try export(Fixture.board(vias: [via], polygons: [outline])) { $0.copperLayers = .outer }
        XCTAssertTrue(export.text.contains("'Top Copper'"))
        XCTAssertTrue(export.text.contains("'Bottom Copper'"))
        XCTAssertEqual(export.text.components(separatedBy: "ADVANCED_FACE(").count - 1, 7 + 2 * 4)
    }

    // MARK: Small components

    /// Asked to, the export leaves out the models smaller than the size in
    /// every dimension, on either side and however turned: an 0402, but not
    /// an 0805 as long as the size, a QFN as wide as it is flat, or a part
    /// standing taller than its footprint. Not asked, or asked for a smaller
    /// size, it keeps them all.
    func testSmallComponentsAreLeftOutWhenAsked() throws {
        let chip0402 = try boxModel("0402", width: 1, depth: 0.5, height: 0.35)
        let chip0805 = try boxModel("0805", width: 2, depth: 1.25, height: 0.6)
        let qfn = try boxModel("qfn", width: 4, depth: 4, height: 0.8)
        let post = try boxModel("post", width: 1, depth: 1, height: 3)
        var board = Fixture.board(polygons: [outline])
        board.packages = [
            package("R1", at: 2, model: chip0402),
            package("R2", at: 3, model: chip0402, bottom: true),
            // An eighth of a turn, which turns its box on the board, not in
            // its file.
            package("R3", at: 4, model: chip0402, angle: 8_192),
            package("C1", at: 6, model: chip0805),
            package("U1", at: 10, model: qfn),
            package("J1", at: 16, model: post)
        ]

        let omitting = try export(board) { $0.omitSmallComponents = true }
        XCTAssertEqual(omitting.report.omittedComponentCount, 3)
        for refdes in ["C1", "U1", "J1"] {
            XCTAssertTrue(omitting.text.contains("'\(refdes)'"), "\(refdes) is kept")
        }
        for refdes in ["R1", "R2", "R3"] {
            XCTAssertFalse(omitting.text.contains("'\(refdes)'"), "\(refdes) is left out")
        }
        XCTAssertEqual(omitting.zRange.upperBound, 0.9 + 0.05 + 3, accuracy: 1e-3, "J1 stands 3 mm off the top")
        XCTAssertEqual(HorizontalExportBackend.stepExportNote(
            HorizontalSTEPExportSettings(filename: "x", labelPrefix: "", omitSmallComponents: true),
            report: omitting.report
        ), " (with component models, 3 smaller than 2 mm left out)")

        let keeping = try export(board)
        XCTAssertEqual(keeping.report.omittedComponentCount, 0)
        for refdes in ["R1", "R2", "R3", "C1", "U1", "J1"] {
            XCTAssertTrue(keeping.text.contains("'\(refdes)'"), "\(refdes) is kept")
        }

        let smallerSize = try export(board) {
            $0.omitSmallComponents = true
            $0.minimumComponentSizeMM = 0.9
        }
        XCTAssertEqual(smallerSize.report.omittedComponentCount, 0)
        XCTAssertTrue(smallerSize.text.contains("'R1'"))
    }
}
