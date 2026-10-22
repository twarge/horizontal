import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Horizon's place-net-label tool, as `HorizontalSchematicNetLabelTool` and
/// the wiring upkeep after it put a label down: on a wire, a junction, an
/// unconnected pin or nothing; and a placed label reaching the file.
final class SchematicNetLabelToolTests: XCTestCase {
    private let grid = 1_250_000.0
    private let tolerance = 50_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint { .init(x: x * grid, y: y * grid) }

    private func sheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: grid)
        sheet.netDetails = ["a": HorizontalNetDetails(id: "a", name: "A")]
        return sheet
    }

    private func addWire(_ id: String, from: (String, HorizontalPoint), to: (String, HorizontalPoint), net: String?, to sheet: inout HorizontalSchematicSheet) {
        sheet.junctions[from.0] = from.1
        sheet.junctions[to.0] = to.1
        if let net {
            sheet.junctionNetIDs[from.0] = net
            sheet.junctionNetIDs[to.0] = net
        }
        sheet.netLines.append(HorizontalSegment(id: id, from: from.1, to: to.1, width: 0, layer: nil, netID: net,
                                                schematicFrom: .junction(from.0), schematicTo: .junction(to.0)))
    }

    /// A symbol with one pin `p` whose connection point is `at`.
    private func addSymbol(pinAt at: HorizontalPoint, connection: SchematicConnectionState?, to sheet: inout HorizontalSchematicSheet) {
        sheet.symbols.append(HorizontalPlacement(id: "sym", position: at, angle: 0, mirrored: false, label: "R1",
                                                 componentID: "comp", gateID: "gate"))
        sheet.symbolPins.append(HorizontalSegment(id: "sym/pin/p", from: at, to: at + HorizontalPoint(x: -grid, y: 0),
                                                  width: 0, layer: nil, netID: connection?.netID))
        var connections = [String: SchematicConnectionState]()
        if let connection { connections["gate/p"] = connection }
        sheet.componentInfo["comp"] = SchematicComponentInfo(refdes: "R1", value: "", partID: nil, noPopulate: false,
                                                             gateSuffixes: [:], gateSymbolIDs: [:], altPins: [:],
                                                             connections: connections, details: nil)
    }

    /// The label in hand dropped at `at`, then the canvas's upkeep (less
    /// the merge prompts, which these sheets never need). Returns the
    /// refusal, if any.
    @discardableResult
    private func drop(at at: HorizontalPoint, orientation: String = "right", on sheet: inout HorizontalSchematicSheet) -> String? {
        let original = sheet
        sheet.addNetLabelInHand(labelID: "label", junctionID: "hand", at: at, orientation: orientation)
        let target = sheet.netLabelTarget(at: at, tolerance: tolerance, excludingJunction: "hand")
        if let refusal = sheet.dropNetLabel(labelID: "label", junctionID: "hand", on: target) {
            return refusal
        }
        let touched = sheet.touchedPointKeys(since: original)
        sheet.connectCoincident(at: touched)
        sheet.spreadNets(touching: touched)
        sheet.healNetLines()
        return nil
    }

    private var label: (HorizontalSchematicSheet) -> HorizontalSchematicNetLabel? {
        { $0.netLabels.first { $0.id == "label" } }
    }

    func testALabelOnAWireSplitsItThereAndTakesItsNet() throws {
        var sheet = sheet()
        addWire("w", from: ("j0", point(0, 0)), to: ("j10", point(10, 0)), net: "a", to: &sheet)

        XCTAssertNil(drop(at: point(4, 0), on: &sheet))

        let placed = try XCTUnwrap(label(sheet))
        XCTAssertEqual(placed.netID, "a")
        XCTAssertEqual(placed.text, "A")
        XCTAssertEqual(placed.position, point(4, 0))
        XCTAssertEqual(sheet.netLines.count, 2, "split at the label")
        XCTAssertEqual(Set(sheet.netLines.flatMap { [$0.from, $0.to] }), [point(0, 0), point(4, 0), point(10, 0)])
        let junction = try XCTUnwrap(placed.junctionID)
        XCTAssertEqual(sheet.junctionNetIDs[junction], "a")
        XCTAssertTrue(sheet.netLines.allSatisfy { $0.netID == "a" })
    }

    func testALabelNearAJunctionStandsOnIt() throws {
        var sheet = sheet()
        addWire("w", from: ("j0", point(0, 0)), to: ("j10", point(10, 0)), net: "a", to: &sheet)

        XCTAssertNil(drop(at: point(10, 0) + HorizontalPoint(x: 0, y: 20_000), on: &sheet))

        let placed = try XCTUnwrap(label(sheet))
        XCTAssertEqual(placed.position, point(10, 0))
        XCTAssertEqual(placed.netID, "a")
        XCTAssertEqual(sheet.junctions.values.filter { $0 == point(10, 0) }.count, 1, "one junction there, the label's")
        let junction = try XCTUnwrap(placed.junctionID)
        XCTAssertEqual(sheet.junctions[junction], point(10, 0))
        XCTAssertTrue(sheet.netLines.contains { $0.schematicTo == .junction(junction) || $0.schematicFrom == .junction(junction) },
                      "the wire ends on the label's junction")
    }

    func testALabelOnAFreePinIsWiredOutFromItOnANewNet() throws {
        var sheet = sheet()
        addSymbol(pinAt: point(5, 0), connection: nil, to: &sheet)

        XCTAssertNil(drop(at: point(5, 0), orientation: "right", on: &sheet))

        let placed = try XCTUnwrap(label(sheet))
        XCTAssertEqual(placed.position, point(6, 0), "1.25 mm out the way it reads")
        let netID = try XCTUnwrap(placed.netID)
        XCTAssertNotEqual(netID, "a")
        XCTAssertEqual(sheet.netDetails[netID]?.name, "", "a new net with no name")
        XCTAssertEqual(placed.text, "? plz fix")
        XCTAssertEqual(sheet.componentInfo["comp"]?.connections["gate/p"]?.netID, netID)
        let wire = try XCTUnwrap(sheet.netLines.first)
        XCTAssertEqual(sheet.netLines.count, 1)
        XCTAssertEqual(wire.schematicFrom, .pin("sym/p"))
        XCTAssertEqual(wire.to, point(6, 0))
        XCTAssertEqual(wire.netID, netID)

        // Reading left, it stands to the pin's left.
        var left = self.sheet()
        addSymbol(pinAt: point(5, 0), connection: nil, to: &left)
        drop(at: point(5, 0), orientation: "left", on: &left)
        XCTAssertEqual(label(left)?.position, point(4, 0))
    }

    func testAConnectedPinABusJunctionAndABusLineAreRefused() {
        var connected = sheet()
        addSymbol(pinAt: point(5, 0), connection: .connected("a"), to: &connected)
        XCTAssertNotNil(drop(at: point(5, 0), on: &connected))
        XCTAssertTrue(connected.netLines.isEmpty)

        var bus = sheet()
        bus.junctions["bj"] = point(0, 0)
        bus.junctions["bk"] = point(10, 0)
        bus.warningContext.junctionBusIDs["bj"] = "data"
        bus.warningContext.junctionBusIDs["bk"] = "data"
        bus.netLines = [HorizontalSegment(id: "busline", from: point(0, 0), to: point(10, 0), width: 0, layer: nil,
                                          schematicFrom: .junction("bj"), schematicTo: .junction("bk"))]
        XCTAssertNotNil(drop(at: point(0, 0), on: &bus), "a bus's junction")
        var busLine = bus
        busLine.netLabels.removeAll()
        XCTAssertNotNil(drop(at: point(5, 0), on: &busLine), "a bus line")
        XCTAssertEqual(busLine.netLines.count, 1, "not split")
    }

    func testALabelInEmptySpaceStaysWhereItIsOnNoNet() throws {
        var sheet = sheet()
        XCTAssertNil(drop(at: point(3, 3), on: &sheet))
        let placed = try XCTUnwrap(label(sheet))
        XCTAssertNil(placed.netID)
        XCTAssertEqual(placed.position, point(3, 3))
        XCTAssertEqual(placed.junctionID.flatMap { sheet.junctions[$0] }, point(3, 3), "it stands on a junction for a wire to reach")
    }

    func testTheLabelInHandReadsTheNetUnderTheCursor() {
        var sheet = sheet()
        addWire("w", from: ("j0", point(0, 0)), to: ("j10", point(10, 0)), net: "a", to: &sheet)
        sheet.addNetLabelInHand(labelID: "label", junctionID: "hand", at: point(3, 3), orientation: "right")
        XCTAssertEqual(label(sheet)?.text, "? plz fix")
        sheet.moveNetLabelInHand(labelID: "label", junctionID: "hand", to: point(4, 0), tolerance: tolerance)
        XCTAssertEqual(label(sheet)?.text, "A")
        XCTAssertNil(label(sheet)?.netID, "only shown: nothing is on the net until the click")
        XCTAssertEqual(sheet.junctions["hand"], point(4, 0))
    }

    func testTheRipperInHandIsDrawnAsAPlacedOne() {
        var sheet = sheet()
        sheet.setBusRipperInHand(id: "rip", memberName: "D0", at: point(0, 0), orientation: "up")
        sheet.setBusRipperInHand(id: "rip", memberName: "D0", at: point(2, 0), orientation: "left")
        XCTAssertEqual(sheet.busRipperLines.count, 1, "moved, not added")
        XCTAssertEqual(sheet.busRipperLines.first?.from, point(2, 0))
        XCTAssertEqual(sheet.busRipperLines.first?.to, point(1, 1), "left: up and to the left, as Horizon's connector")
        XCTAssertEqual(sheet.busRipperTexts.map(\.text), ["D0"])
    }

    // MARK: - Writing

    func testAPlacedLabelReachesTheFileWithItsJunction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-net-label-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        let project = try HorizontalProject.load(from: packageURL)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        sheet.netDetails["net-a"] = HorizontalNetDetails(id: "net-a", name: "SDA",
                                                         netClassID: sheet.netClasses.first?.id,
                                                         netClassName: sheet.netClasses.first?.name)
        sheet.addNetLabelInHand(labelID: "label-1", junctionID: "junction-1", at: point(4, 2), orientation: "left")
        sheet.junctionNetIDs["junction-1"] = "net-a"
        sheet.netLabels[0].netID = "net-a"
        // A label with nothing to stand on is not written: Horizon can't load one.
        sheet.netLabels.append(HorizontalSchematicNetLabel(id: "stray", text: "", position: point(9, 9), size: 1, orientation: "right"))

        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet,
                                                  schematicURL: packageURL.appendingPathComponent("top_schematic.json"),
                                                  in: project, to: &archive)

        let data = try XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))
        let schematic = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sheetJSON = try XCTUnwrap((schematic["sheets"] as? [String: Any])?[sheet.id] as? [String: Any])
        let labels = try XCTUnwrap(sheetJSON["net_labels"] as? [String: Any])
        XCTAssertNil(labels["stray"])
        let written = try XCTUnwrap(labels["label-1"] as? [String: Any], "a placed label is a new entry")
        XCTAssertEqual(written["junction"] as? String, "junction-1")
        XCTAssertEqual(written["orientation"] as? String, "left")
        XCTAssertEqual(written["last_net"] as? String, "net-a")
        XCTAssertEqual(written["offsheet_refs"] as? Bool, true)
        XCTAssertEqual(written["show_port"] as? Bool, false)
        XCTAssertEqual((written["size"] as? NSNumber)?.doubleValue, HorizontalSchematicSheet.netLabelDefaultSize)

        try archive.write(to: packageURL)
        let reloaded = try XCTUnwrap(try HorizontalProject.load(from: packageURL).schematic?.sheets.first)
        let label = try XCTUnwrap(reloaded.netLabels.first { $0.id == "label-1" })
        XCTAssertEqual(label.text, "SDA")
        XCTAssertEqual(label.position, point(4, 2))
        XCTAssertEqual(label.orientation, "left")
    }
}
