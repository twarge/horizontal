import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The channel the schematic's bus and net-tie tools write through.
///
/// Those objects live in the block as much as on a sheet, which the sheet
/// applier cannot reach, so the tools hand the automation channel's own edit
/// operations to `HorizontalCanvasProjectEdit` and the document adopts the
/// archive that comes back. Two things have to hold for that to be a tool and
/// not a trapdoor: the operations the tools build have to be accepted, and the
/// reloaded sheet has to publish what the pickers read back — otherwise the
/// second use of a tool cannot see what the first one made.
final class HorizontalCanvasProjectEditTests: XCTestCase {
    private var root: URL!
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-canvas-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }

        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        project = try HorizontalProject.load(from: url)
    }

    /// Applies operations the way a tool does, and reloads the way the
    /// document does.
    @discardableResult
    private func apply(_ operations: [JSONDictionary]) throws -> HorizontalSchematicSheet {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: operations, to: archive, in: project)
        archive = edited.archive
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        return try XCTUnwrap(project.schematic?.sheets.first)
    }

    private func netID(_ name: String, in sheet: HorizontalSchematicSheet) throws -> String {
        try XCTUnwrap(sheet.netDetails.values.first { $0.name == name }?.id)
    }

    /// The label tool's sequence: make the bus, then name it on the sheet.
    /// The picker the ripper tool opens next reads `busDetails`, so that is
    /// what the assertion looks at rather than the file.
    func testPlacingABusLabelCreatesTheBusAndPublishesIt() throws {
        // The tools name the sheet by the id the canvas holds, so the test
        // does too: a uuid the editor has to resolve, not the default first
        // sheet it would fall back to.
        let sheetID = try XCTUnwrap(project.schematic?.sheets.first?.id)
        let sheet = try apply([["op": "add_bus", "name": "DATA", "id": "bus-1"],
                               ["op": "place_bus_label", "bus": "bus-1", "sheet": sheetID,
                                "x_mm": 10, "y_mm": 10]])

        XCTAssertEqual(sheet.busDetails.map(\.name), ["DATA"], "the picker sees the bus the tool made")
        XCTAssertEqual(sheet.busDetails.first?.members, [], "a new bus is empty until a ripper puts a net in it")
        XCTAssertEqual(sheet.busLabels.count, 1, "and the sheet draws the label")
        XCTAssertEqual(sheet.busLabels.first?.text, "B:DATA")
    }

    /// The ripper tool's sequence: put the net in the bus under its own name,
    /// then take it off at a point.
    func testPlacingARipperAddsTheMemberAndDrawsIt() throws {
        var sheet = try apply([["op": "ensure_net", "name": "SDA"],
                               ["op": "add_bus", "name": "I2C", "id": "bus-1"],
                               ["op": "place_bus_label", "bus": "bus-1", "x_mm": 10, "y_mm": 10]])
        let sda = try netID("SDA", in: sheet)

        sheet = try apply([["op": "add_bus_member", "bus": "bus-1", "name": "SDA", "net": sda, "id": "member-1"],
                           ["op": "place_bus_ripper", "bus": "bus-1", "member": "member-1", "x_mm": 20, "y_mm": 10]])

        let members = try XCTUnwrap(sheet.busDetails.first?.members)
        XCTAssertEqual(members.map(\.name), ["SDA"])
        XCTAssertEqual(members.first?.netID, sda, "the member carries the net, which is what the tool matches on")
        XCTAssertFalse(sheet.busRipperLines.isEmpty, "and the sheet draws the ripper")
        XCTAssertEqual(sheet.busRipperTexts.first?.text, "SDA")
    }

    /// The tie tool's sequence, and the reason it checks first: a second tie
    /// between the same two nets is not what drawing a second symbol means.
    func testTyingNetsPublishesTheTieAndDrawsOneSymbolPerPlacement() throws {
        var sheet = try apply([["op": "ensure_net", "name": "AGND"], ["op": "ensure_net", "name": "DGND"]])
        let analog = try netID("AGND", in: sheet)
        let digital = try netID("DGND", in: sheet)

        sheet = try apply([
            ["op": "add_net_tie", "primary": analog, "secondary": digital, "id": "tie-1"],
            ["op": "place_net_tie", "net_tie": "tie-1",
             "from": ["x_mm": 10, "y_mm": 10], "to": ["x_mm": 12.54, "y_mm": 10]]
        ])

        let tie = try XCTUnwrap(sheet.netTieDetails.first)
        XCTAssertEqual(sheet.netTieDetails.count, 1)
        XCTAssertEqual(Set([tie.primaryName, tie.secondaryName]), ["AGND", "DGND"])
        XCTAssertEqual(sheet.netTies.count, 1, "one symbol for one placement")

        // The second placement reuses the tie the tool found rather than
        // making another, which is what the canvas's own lookup is for.
        XCTAssertEqual(
            Set([tie.primaryID, tie.secondaryID].compactMap { $0 }),
            Set([analog, digital]),
            "the lookup matches on the pair of nets, so it has to report both"
        )
        sheet = try apply([["op": "place_net_tie", "net_tie": tie.id,
                            "from": ["x_mm": 30, "y_mm": 10], "to": ["x_mm": 32.54, "y_mm": 10]]])
        XCTAssertEqual(sheet.netTieDetails.count, 1, "still one tie")
        XCTAssertEqual(sheet.netTies.count, 2, "drawn twice")
    }

    /// A refused operation leaves the archive alone and says why, because the
    /// tool puts that message in front of the user.
    func testARefusedOperationChangesNothingAndExplainsItself() throws {
        let before = archive
        XCTAssertThrowsError(
            try HorizontalCanvasProjectEdit.archive(
                applying: [["op": "place_bus_label", "bus": "nothing-by-that-name", "x_mm": 1, "y_mm": 1]],
                to: archive,
                in: project
            )
        ) { error in
            XCTAssertFalse(HorizontalCanvasProjectEdit.message(for: error).isEmpty)
        }
        XCTAssertEqual(archive.regularFilePaths.sorted(), before?.regularFilePaths.sorted())
    }
}
