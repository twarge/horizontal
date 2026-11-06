import XCTest
@testable import HorizontalNative

/// The Gerber set's drill files sort holes by the copper they run through, as
/// Horizon's GerberExporter does: the through holes in one file, or plated and
/// unplated in two, and each blind or buried via span in a file of its own.
/// Each file says which in KiCad's Excellon comments, `; #@! TF.FileFunction`,
/// its copper numbered as the Gerbers number it. Every hole went in the one
/// file, the blind and buried vias drilled through the whole board.
final class HorizontalDrillFileSpanTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func via(_ id: String, at position: HorizontalPoint, layers: [Int]) -> HorizontalMarker {
        HorizontalMarker(id: id, position: position, size: 600_000, holeSize: 300_000, layer: nil, connectedLayers: layers)
    }

    private var vias: [HorizontalMarker] {
        [
            via("through", at: point(1, 1), layers: [Fixture.top, Fixture.inner1, Fixture.inner2, Fixture.bottom]),
            via("blind-top", at: point(2, 1), layers: [Fixture.top, Fixture.inner1]),
            via("buried", at: point(3, 1), layers: [Fixture.inner1, Fixture.inner2]),
            via("blind-bottom", at: point(4, 1), layers: [Fixture.inner2, Fixture.bottom]),
        ]
    }

    private var holes: [HorizontalHole] {
        [
            HorizontalHole(id: "plated", position: point(5, 1), diameter: 1_000_000, plated: true),
            HorizontalHole(id: "mounting", position: point(6, 1), diameter: 3_200_000, plated: false),
        ]
    }

    /// The drill files written for `board`, by file name.
    private func drillFiles(_ board: HorizontalBoard, mode: HorizontalGerberDrillMode) throws -> [String: String] {
        let project = Fixture.project(board: board)
        var settings = HorizontalExportSettings(project: project).gerber
        settings.prefix = "fixture"
        settings.zipOutput = false
        settings.drillMode = mode
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalDrillFileSpanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = [String: String]()
        for url in try HorizontalExportBackend.exportGerber(project: project, settings: settings, to: directory)
            where url.pathExtension == "drl" {
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    private func lines(_ file: String) -> [String] {
        file.split(separator: "\n").map(String.init)
    }

    /// The file's `.FileFunction`, nil when it states none.
    private func fileFunction(_ file: String) -> String? {
        let prefix = "; #@! TF.FileFunction,"
        return lines(file).first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private func drills(_ file: String, at position: HorizontalPoint) -> Bool {
        lines(file).contains(String(format: "X%.4fY%.4f", position.x / 1_000_000, position.y / 1_000_000))
    }

    func testBlindAndBuriedViasGoInFilesOfTheirOwn() throws {
        let vias = vias
        let files = try drillFiles(Fixture.board(vias: vias, holes: holes), mode: .merged)

        XCTAssertEqual(Set(files.keys), [
            "fixture Drills.drl",
            "fixture Top-Inner 1 Drills.drl",
            "fixture Inner 1-Inner 2 Drills.drl",
            "fixture Inner 2-Bottom Drills.drl",
        ])
        let through = try XCTUnwrap(files["fixture Drills.drl"])
        for position in [point(1, 1), point(5, 1), point(6, 1)] {
            XCTAssertTrue(drills(through, at: position), "the through file drills \(position)")
        }
        let spans = [
            ("fixture Top-Inner 1 Drills.drl", vias[1], "Plated,1,2,Blind"),
            ("fixture Inner 1-Inner 2 Drills.drl", vias[2], "Plated,2,3,Buried"),
            ("fixture Inner 2-Bottom Drills.drl", vias[3], "Plated,3,4,Blind"),
        ]
        for (name, via, function) in spans {
            let file = try XCTUnwrap(files[name])
            XCTAssertFalse(drills(through, at: via.position), "\(via.id) drilled through the board")
            XCTAssertTrue(drills(file, at: via.position), name)
            XCTAssertEqual(lines(file).filter { $0.hasPrefix("X") }.count, 1, "\(name) holds only \(via.id)")
            XCTAssertEqual(fileFunction(file), function, name)
        }
    }

    /// A merged file holding plated and unplated holes has no function the
    /// spec gives; split, each file has its own. One holding plated holes
    /// alone is plated through.
    func testThroughFilesStateTheirPlating() throws {
        let merged = try drillFiles(Fixture.board(vias: [vias[0]], holes: holes), mode: .merged)
        XCTAssertNil(fileFunction(try XCTUnwrap(merged["fixture Drills.drl"])))

        let individual = try drillFiles(Fixture.board(vias: [vias[0]], holes: holes), mode: .individual)
        XCTAssertEqual(fileFunction(try XCTUnwrap(individual["fixture Drills.drl"])), "Plated,1,4,PTH")
        XCTAssertEqual(fileFunction(try XCTUnwrap(individual["fixture NPTH Drills.drl"])), "NonPlated,1,4,NPTH")

        let platedOnly = try drillFiles(Fixture.board(vias: [vias[0]], holes: [holes[0]]), mode: .merged)
        XCTAssertEqual(fileFunction(try XCTUnwrap(platedOnly["fixture Drills.drl"])), "Plated,1,4,PTH")
    }

    /// Plated and unplated holes go apart unless asked otherwise, so each
    /// file states its function, as the spec asks; Horizon merges them.
    func testTheDefaultSplitsPlating() throws {
        let project = Fixture.project(board: Fixture.board(holes: holes))
        var settings = HorizontalExportSettings(project: project).gerber
        XCTAssertEqual(settings.drillMode, .individual)
        settings.prefix = "fixture"
        settings.zipOutput = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalDrillFileSpanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = try HorizontalExportBackend.exportGerber(project: project, settings: settings, to: directory)
        let functions = try written.filter { $0.pathExtension == "drl" }.map { try fileFunction(String(contentsOf: $0, encoding: .utf8)) }
        XCTAssertEqual(Set(functions), ["Plated,1,4,PTH", "NonPlated,1,4,NPTH"])
    }

    /// A two-layer board's through holes run from L1 to L2.
    func testATwoLayerBoardDrillsFromL1ToL2() throws {
        var board = Fixture.board(holes: [holes[0]])
        board.stackupLayers.removeAll { $0.layer != Fixture.top && $0.layer != Fixture.bottom }
        let files = try drillFiles(board, mode: .individual)
        XCTAssertEqual(fileFunction(try XCTUnwrap(files["fixture Drills.drl"])), "Plated,1,2,PTH")
    }

    /// The attributes are comments in the header, after M48 and before the
    /// units; drill files are always positive.
    func testTheAttributesLeadTheHeader() throws {
        let file = try XCTUnwrap(try drillFiles(Fixture.board(holes: [holes[0]]), mode: .merged)["fixture Drills.drl"])
        // A test isn't the app, which alone has a version to name.
        let header = lines(file).filter { !$0.hasPrefix("; #@! TF.GenerationSoftware,") }
        XCTAssertEqual(Array(header.prefix(5)), [
            "M48",
            "; #@! TF.SameCoordinates",
            "; #@! TF.FileFunction,Plated,1,4,PTH",
            "; #@! TF.FilePolarity,Positive",
            "METRIC,TZ",
        ])
    }

    /// The export settings list the board's blind and buried spans, upper
    /// first, each with Horizon's name for its file in the PTH file's style.
    /// A suffix someone changed is kept while its span is on the board, and a
    /// span the board no longer has goes.
    func testTheSettingsNameEachSpansFile() {
        let board = Fixture.board(vias: vias)
        var settings = HorizontalExportSettings(project: Fixture.project(board: board))
        XCTAssertEqual(settings.gerber.spanDrills, [
            HorizontalGerberSpanDrillFile(span: HorizontalViaSpan(start: Fixture.top, end: Fixture.inner1), suffix: " Top-Inner 1 Drills.drl"),
            HorizontalGerberSpanDrillFile(span: HorizontalViaSpan(start: Fixture.inner1, end: Fixture.inner2), suffix: " Inner 1-Inner 2 Drills.drl"),
            HorizontalGerberSpanDrillFile(span: HorizontalViaSpan(start: Fixture.inner2, end: Fixture.bottom), suffix: " Inner 2-Bottom Drills.drl"),
        ])

        settings.gerber.spanDrills[0].suffix = "-blind.txt"
        settings.refreshBoardLayers(from: Fixture.board(vias: [vias[0], vias[1]]))
        XCTAssertEqual(settings.gerber.spanDrills, [
            HorizontalGerberSpanDrillFile(span: HorizontalViaSpan(start: Fixture.top, end: Fixture.inner1), suffix: "-blind.txt"),
        ])
    }
}
