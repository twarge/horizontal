import XCTest
@testable import HorizontalNative

/// A slot in the Gerber set's drill file is drilled from one end's centre to
/// the other's (G85), as Horizon's ExcellonWriter writes it. It was drilled at
/// its centre alone, which made a round hole of it.
final class HorizontalExcellonSlotTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    /// The drill files written for `holes`, by file name.
    private func drillFiles(holes: [HorizontalHole], mode: HorizontalGerberDrillMode) throws -> [String: String] {
        let project = Fixture.project(board: Fixture.board(holes: holes))
        var settings = HorizontalExportSettings(project: project).gerber
        settings.prefix = "fixture"
        settings.zipOutput = false
        settings.drillMode = mode
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalExcellonSlotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = try HorizontalExportBackend.exportGerber(project: project, settings: settings, to: directory)
        var files = [String: String]()
        for url in written where url.pathExtension == "drl" {
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    private let round = HorizontalHole(id: "round", position: HorizontalPoint(x: 3_000_000, y: 1_000_000), diameter: 1_000_000, plated: true)

    /// A slot 2.8 mm long and 0.8 mm wide stood on end: its ends' centres are
    /// 1 mm either side of its middle.
    func testASlotIsDrilledBetweenItsEnds() throws {
        let slot = HorizontalHole(
            id: "slot", position: point(10, 5), diameter: 800_000, length: 2_800_000, shape: .slot, angle: 16_384, plated: true
        )
        let files = try drillFiles(holes: [round, slot], mode: .merged)

        let drill = try XCTUnwrap(files["fixture Drills.drl"], "\(files.keys)")
        XCTAssertTrue(drill.contains("\nX10.0000Y4.0000G85X10.0000Y6.0000\n"), drill)
        XCTAssertFalse(drill.contains("X10.0000Y5.0000"), "the slot is not drilled at its middle alone")
        XCTAssertTrue(drill.contains("\nX3.0000Y1.0000\n"), "a round hole is a hit")
        XCTAssertTrue(drill.contains("C0.8000"), "the slot's tool is its width")
    }

    /// A non-plated slot goes in the non-plated file, as a slot.
    func testANonPlatedSlotIsDrilledInTheNonPlatedFile() throws {
        let slot = HorizontalHole(
            id: "slot", position: point(0, 0), diameter: 1_000_000, length: 3_000_000, shape: .slot, angle: 0, plated: false
        )
        let files = try drillFiles(holes: [round, slot], mode: .individual)

        let nonPlated = try XCTUnwrap(files["fixture NPTH Drills.drl"], "\(files.keys)")
        XCTAssertTrue(nonPlated.contains("\nX-1.0000Y0.0000G85X1.0000Y0.0000\n"), nonPlated)
        XCTAssertFalse(try XCTUnwrap(files["fixture Drills.drl"]).contains("G85"))
    }

    /// A slot no longer than it is wide is a round hole.
    func testASlotNoLongerThanItIsWideIsAHit() throws {
        let slot = HorizontalHole(
            id: "slot", position: point(5, 5), diameter: 1_000_000, length: 1_000_000, shape: .slot, angle: 0, plated: true
        )
        let drill = try XCTUnwrap(try drillFiles(holes: [slot], mode: .merged)["fixture Drills.drl"])
        XCTAssertFalse(drill.contains("G85"))
        XCTAssertTrue(drill.contains("\nX5.0000Y5.0000\n"))
    }
}
