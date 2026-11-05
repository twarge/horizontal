import XCTest
@testable import HorizontalNative

/// The ODB++ job: its profile, its surfaces and its layers' names. Weevling's
/// export had a profile with no units, no surface and its outline marked a
/// hole, every surface on every layer marked a hole, and layers called
/// layer_id_100 and the like.
final class HorizontalODBExportTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture

    private struct Job {
        var matrix: String
        var profile: String
        var features: [String: String]
    }

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [HorizontalPoint] {
        [point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1)]
    }

    private func line(_ id: String, layer: Int) -> HorizontalSegment {
        HorizontalSegment(id: id, from: point(1, 1), to: point(2, 1), width: 100_000, layer: layer, netID: nil)
    }

    private func export(_ board: HorizontalBoard) throws -> Job {
        let project = Fixture.project(board: board)
        var settings = HorizontalExportSettings(project: project).odb
        settings.format = .directory
        settings.directoryName = "job"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalODBExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jobURL = try HorizontalExportBackend.exportODB(project: project, settings: settings, to: directory)
        let steps = try FileManager.default.contentsOfDirectory(atPath: jobURL.appendingPathComponent("steps").path)
        let stepURL = jobURL.appendingPathComponent("steps").appendingPathComponent(try XCTUnwrap(steps.first))
        let layersURL = stepURL.appendingPathComponent("layers")
        var features = [String: String]()
        for name in try FileManager.default.contentsOfDirectory(atPath: layersURL.path) {
            features[name] = try String(contentsOf: layersURL.appendingPathComponent(name).appendingPathComponent("features"), encoding: .utf8)
        }
        return Job(
            matrix: try String(contentsOf: jobURL.appendingPathComponent("matrix/matrix"), encoding: .utf8),
            profile: try String(contentsOf: stepURL.appendingPathComponent("profile"), encoding: .utf8),
            features: features
        )
    }

    /// Each contour of a features text: whether it is an island and its
    /// points, as `OB` starts it and `OS` continues it.
    private func contours(_ features: String) -> [(island: Bool, points: [HorizontalPoint])] {
        var contours = [(island: Bool, points: [HorizontalPoint])]()
        for line in features.components(separatedBy: "\r\n") {
            let fields = line.split(separator: " ")
            if fields.first == "OB", fields.count == 4 {
                contours.append((fields[3] == "I", []))
            } else if fields.first == "OS", fields.count == 3, let x = Double(fields[1]), let y = Double(fields[2]) {
                contours[contours.count - 1].points.append(HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000))
            }
        }
        return contours
    }

    private func signedArea(_ points: [HorizontalPoint]) -> Double {
        zip(points, points.dropFirst() + points.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
    }

    private func matrixNames(_ matrix: String) -> [String] {
        matrix.components(separatedBy: "\r\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("NAME=") ? String(trimmed.dropFirst("NAME=".count)) : nil
        }
    }

    private func matrixContext(of name: String, in matrix: String) -> String? {
        let blocks = matrix.components(separatedBy: "LAYER {")
        guard let block = blocks.first(where: { $0.contains("NAME=\(name)\r\n") }) else { return nil }
        return block.components(separatedBy: "\r\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("CONTEXT=") }
            .map { String($0.dropFirst("CONTEXT=".count)) }
    }

    // MARK: Profile

    /// The profile is a features file of one surface, in millimetres: the
    /// outline an island, clockwise, its cutout a hole, counterclockwise. The
    /// cutout is listed first, as the loader may list it, and is still the
    /// hole.
    func testProfileIsOneSurfaceOfTheOutlineLessItsCutouts() throws {
        let cutout = HorizontalPolygon(id: "cutout", vertices: square(4, 4, 6, 6), layer: HorizontalBoardLayers.outline)
        let outline = HorizontalPolygon(id: "outline", vertices: square(0, 0, 20, 10), layer: HorizontalBoardLayers.outline)
        let job = try export(Fixture.board(polygons: [cutout, outline]))

        let lines = job.profile.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "UNITS=MM")
        XCTAssertEqual(lines.filter { $0 == "S P 0" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "SE" }.count, 1)

        let contours = contours(job.profile)
        XCTAssertEqual(contours.map(\.island), [true, false])
        XCTAssertEqual(Set(contours[0].points.map { [$0.x, $0.y] }), Set(outline.vertices.map { [$0.x, $0.y] }))
        XCTAssertEqual(Set(contours[1].points.map { [$0.x, $0.y] }), Set(cutout.vertices.map { [$0.x, $0.y] }))
        XCTAssertLessThan(signedArea(contours[0].points), 0, "an island runs clockwise")
        XCTAssertGreaterThan(signedArea(contours[1].points), 0, "a hole runs counterclockwise")
    }

    // MARK: Surfaces

    /// A plane fill with a hole is one surface: an island and its hole. Every
    /// surface was written as a hole alone, which draws nothing.
    func testSurfacesAreIslandsWithTheirHoles() throws {
        let fill = HorizontalPlaneFragment(paths: [square(0, 0, 20, 20), square(5, 5, 10, 10)], orphan: false)
        let plane = HorizontalPlane(
            id: "p", netID: "gnd", polygonID: "p/polygon", layer: Fixture.top, priority: 0,
            fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: [fill]
        )
        let job = try export(Fixture.board(planes: [plane]))

        let signalTop = try XCTUnwrap(job.features["signal_top"])
        XCTAssertEqual(signalTop.components(separatedBy: "S P 0").count - 1, 1)
        let contours = contours(signalTop)
        XCTAssertEqual(contours.map(\.island), [true, false])
        XCTAssertLessThan(signedArea(contours[0].points), 0)
        XCTAssertGreaterThan(signedArea(contours[1].points), 0)
    }

    // MARK: Layers

    /// The layers Horizon has no ODB name for are named as the others are,
    /// documentation is MISC, and the outline is drawn as its edges.
    func testLayersAreNamed() throws {
        let board = Fixture.board(
            lines: [
                line("courtyard", layer: HorizontalBoardLayers.topCourtyard),
                line("package", layer: HorizontalBoardLayers.bottomPackage),
                line("user-unnamed", layer: HorizontalBoardLayers.user1),
                line("user-outline", layer: HorizontalBoardLayers.user2),
            ],
            polygons: [
                HorizontalPolygon(id: "outline", vertices: square(0, 0, 20, 10), layer: HorizontalBoardLayers.outline),
                HorizontalPolygon(id: "notes", vertices: square(30, 0, 40, 10), layer: HorizontalBoardLayers.outlineNotes),
            ],
            dimensions: [HorizontalDimension(
                id: "d", p0: point(0, 0), p1: point(20, 0), labelDistance: -2_000_000, labelSize: 500_000, mode: .distance
            )],
            texts: [HorizontalText(id: "note", text: "NOTE", position: point(5, 5), size: 1_000_000, layer: HorizontalBoardLayers.topNotes)],
            userLayers: [
                HorizontalBoardUserLayer(id: HorizontalBoardLayers.user1, colorLayer: HorizontalBoardLayers.user1, name: "", type: "user", position: nil),
                HorizontalBoardUserLayer(id: HorizontalBoardLayers.user2, colorLayer: HorizontalBoardLayers.user2, name: "Outline", type: "user", position: nil),
            ]
        )
        let job = try export(board)

        let names = matrixNames(job.matrix)
        XCTAssertFalse(job.matrix.contains("layer_id_"), "\(names)")
        for name in ["outline", "outline_notes", "notes_top", "courtyard_top", "package_bottom", "dimensions", "user_1", "outline_2"] {
            XCTAssertTrue(names.contains(name), "\(name) is missing from \(names)")
            XCTAssertNotNil(job.features[name], "\(name) has no features")
        }
        XCTAssertEqual(Set(names).count, names.count, "names are unique")
        XCTAssertEqual(matrixContext(of: "outline", in: job.matrix), "BOARD")
        for name in ["outline_notes", "notes_top", "courtyard_top", "package_bottom", "dimensions", "user_1"] {
            XCTAssertEqual(matrixContext(of: name, in: job.matrix), "MISC", name)
        }

        let outline = try XCTUnwrap(job.features["outline"])
        XCTAssertFalse(outline.contains("S P 0"), "the outline is its edges, not a filled surface")
        XCTAssertEqual(outline.components(separatedBy: "\r\nL ").count - 1, 4)
        XCTAssertTrue(try XCTUnwrap(job.features["dimensions"]).contains("\r\nL 0.000000 0.000000 0.000000 -2.250000 "))
    }
}
