import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Manage Buses: rename a member, take a member out (its rippers and the
/// wires ending on them go too, as Horizon drops them), remove a bus. Each
/// is one batch the schematic rail's popover sends, so one undo step.
final class SchematicManageBusesTests: XCTestCase {
    private var fixture: SchematicProjectEditFixture!

    /// Bus D with members D0 and D1, labelled, each member ripped off it, and
    /// a wire from each ripper to a junction below it.
    override func setUpWithError() throws {
        fixture = try SchematicProjectEditFixture(testCase: self)
        try fixture.apply([
            ["op": "ensure_net", "name": "D0"], ["op": "ensure_net", "name": "D1"],
            ["op": "add_bus", "name": "D", "id": "bus"],
            ["op": "add_bus_member", "bus": "bus", "name": "D0", "net": "D0", "id": "d0"],
            ["op": "add_bus_member", "bus": "bus", "name": "D1", "net": "D1", "id": "d1"],
            ["op": "place_bus_label", "bus": "bus", "x_mm": 10, "y_mm": 40],
            ["op": "place_bus_ripper", "bus": "bus", "member": "d0", "x_mm": 15, "y_mm": 30],
            ["op": "place_bus_ripper", "bus": "bus", "member": "d1", "x_mm": 25, "y_mm": 30],
        ])
        let members = try XCTUnwrap(try fixture.blockJSON().dictionaryMap("buses").first?.value.dictionaryMap("members"))
        try fixture.editSheetJSON { sheet in
            var junctions = sheet.dictionaryMap("junctions") as JSONDictionary
            var lines = sheet.dictionaryMap("net_lines") as JSONDictionary
            for (ripperID, ripper) in sheet.dictionaryMap("bus_rippers") {
                let member = ripper.string("bus_member")?.lowercased() ?? ""
                let net = members.first { $0.key.lowercased() == member }?.value.string("net") ?? ""
                let x = members.first { $0.key.lowercased() == member }?.value.string("name") == "D0" ? 15_000_000 : 25_000_000
                let junction = UUID().uuidString.lowercased()
                junctions[junction] = ["position": [x, 20_000_000]] as JSONDictionary
                lines[UUID().uuidString.lowercased()] = [
                    "from": ["bus_ripper": ripperID, "junc": NSNull(), "pin": NSNull(), "port": NSNull()] as JSONDictionary,
                    "to": ["junc": junction, "bus_ripper": NSNull(), "pin": NSNull(), "port": NSNull()] as JSONDictionary,
                    "net": net,
                ] as JSONDictionary
            }
            sheet["junctions"] = junctions
            sheet["net_lines"] = lines
        }
        XCTAssertEqual(try fixture.sheetJSON().dictionaryMap("net_lines").count, 2)
    }

    private var buses: [HorizontalBusDetails] {
        get throws { try fixture.sheet.busDetails }
    }

    private func member(_ name: String) throws -> HorizontalBusDetails.Member {
        try XCTUnwrap(try buses.first?.members.first { $0.name == name })
    }

    func testRenamingAMemberRenamesItInTheBlockAndKeepsItsNet() throws {
        let bus = try XCTUnwrap(try buses.first)
        let d0 = try member("D0")
        let edit = try XCTUnwrap(HorizontalBusCommand.renameMember(bus: bus.id, member: d0.id, name: " DATA0 ").edit(in: try buses))
        XCTAssertEqual(edit.ops.count, 1, "one op, one undo step")
        XCTAssertEqual(edit.actionName, "Rename Bus Member")
        try fixture.apply(edit.ops)

        let renamed = try XCTUnwrap(try buses.first?.members.first { $0.id == d0.id })
        XCTAssertEqual(renamed.name, "DATA0")
        XCTAssertEqual(renamed.netID, d0.netID)
        XCTAssertEqual(try fixture.sheetJSON().dictionaryMap("net_lines").count, 2, "the wiring stays")
        XCTAssertNil(HorizontalBusCommand.renameMember(bus: bus.id, member: d0.id, name: "DATA0").edit(in: try buses), "the name it has")
        XCTAssertNil(HorizontalBusCommand.renameMember(bus: bus.id, member: d0.id, name: "  ").edit(in: try buses), "no name")
        XCTAssertThrowsError(try fixture.apply([["op": "rename_bus_member", "bus": bus.id, "member": d0.id, "name": "D1"]]),
                             "another member's name")
    }

    func testRemovingAMemberTakesItsRipperAndTheWireOnItAndLeavesTheOtherMember() throws {
        let bus = try XCTUnwrap(try buses.first)
        let d0 = try member("D0"), d1 = try member("D1")
        let edit = try XCTUnwrap(HorizontalBusCommand.removeMember(bus: bus.id, member: d0.id).edit(in: try buses))
        XCTAssertEqual(edit.ops.count, 1, "one op, one undo step")
        XCTAssertEqual(edit.actionName, "Remove Bus Member")
        let changes = try fixture.apply(edit.ops)
        XCTAssertEqual(changes.first?["rippers_removed"] as? Int, 1)
        XCTAssertEqual(changes.first?["net_lines_removed"] as? Int, 1)

        XCTAssertEqual(try buses.first?.members.map(\.id), [d1.id])
        let after = try fixture.sheetJSON()
        XCTAssertEqual(after.dictionaryMap("bus_rippers").values.compactMap { $0.string("bus_member")?.lowercased() }, [d1.id.lowercased()])
        let wires = after.dictionaryMap("net_lines").values
        XCTAssertEqual(wires.count, 1, "the D1 ripper's wire stays")
        let d1Ripper = after.dictionaryMap("bus_rippers").keys.first?.lowercased()
        XCTAssertEqual(wires.first?.dictionary("from")?.string("bus_ripper")?.lowercased(), d1Ripper)
        let junctionX = after.dictionaryMap("junctions").values.compactMap { ($0["position"] as? [Any])?.first as? Int }
        XCTAssertFalse(junctionX.contains(15_000_000), "the D0 wire's far junction went with it")
        XCTAssertEqual(after.dictionaryMap("bus_labels").count, 1, "the bus is still labelled")
        XCTAssertNotNil(try fixture.blockJSON().dictionaryMap("nets").values.first { $0.string("name") == "D0" }, "the net stays a net")
    }

    func testRemovingABusTakesItsLabelsRippersAndTheWiresOnTheRippers() throws {
        let bus = try XCTUnwrap(try buses.first)
        let edit = try XCTUnwrap(HorizontalBusCommand.removeBus(bus.id).edit(in: try buses))
        XCTAssertEqual(edit.ops.count, 1, "one op, one undo step")
        XCTAssertEqual(edit.actionName, "Remove Bus")
        let changes = try fixture.apply(edit.ops)
        XCTAssertEqual(changes.first?["net_lines_removed"] as? Int, 2)
        XCTAssertEqual(try buses.count, 0)
        let after = try fixture.sheetJSON()
        XCTAssertEqual(after.dictionaryMap("bus_rippers").count, 0)
        XCTAssertEqual(after.dictionaryMap("bus_labels").count, 0)
        XCTAssertEqual(after.dictionaryMap("net_lines").count, 0, "no wire is left ending on a ripper that is gone")
        XCTAssertNil(HorizontalBusCommand.removeBus(bus.id).edit(in: try buses), "a bus that is gone")
    }
}
