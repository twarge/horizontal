import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The Pools pane's Other Entities: while components are selected, parts for
/// any entity are listed, and Replace with one for another entity remaps the
/// components onto it (`remap_part`), their pins matched by name, as one
/// edit; a part for their own entity is still a `set_part`.
final class PoolPaneRemapToOtherEntityTests: XCTestCase {
    private func partItem(_ uuid: String, entity: String, isBasePart: Bool = false) -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: "/pool|part|\(uuid)", uuid: uuid, name: uuid.uppercased(), detail: "", tags: "", category: .part,
            poolName: "Pool", poolURL: URL(fileURLWithPath: "/pool"), url: URL(fileURLWithPath: "/pool/parts/\(uuid).json"),
            isBasePart: isBasePart, partEntityID: entity
        )
    }

    func testOtherEntitiesOffersAnotherEntitysPartsAndRemapsOntoThem() throws {
        let block: JSONDictionary = ["components": ["c-r1": ["refdes": "R1", "entity": "e-res", "part": "p-10k"] as JSONDictionary] as JSONDictionary]
        var replacement = try XCTUnwrap(HorizontalPartReplacement(componentIDs: ["c-r1"], block: block))
        let other = partItem("p-opamp", entity: "e-opamp"), same = partItem("p-22k", entity: "e-res")

        XCTAssertFalse(replacement.isCompatible(other))
        XCTAssertTrue(replacement.refusal(for: other)?.contains("Other Entities") == true, "the refusal says how to remap")

        replacement.allowsOtherEntities = true
        XCTAssertTrue(replacement.isCompatible(other))
        XCTAssertFalse(replacement.isCompatible(partItem("p-base", entity: "e-opamp", isBasePart: true)), "a base part still isn't offered")
        XCTAssertNil(replacement.refusal(for: other))
        XCTAssertTrue(replacement.remaps(other))
        XCTAssertFalse(replacement.remaps(same))
        XCTAssertEqual(replacement.actionName(for: other), "Remap Part")
        XCTAssertEqual(replacement.actionName(for: same), "Replace Part")
        XCTAssertEqual(replacement.operations(partID: "p-opamp", entityID: "e-opamp").map { $0.string("op") }, ["remap_part"])
        XCTAssertEqual(replacement.operations(partID: "p-22k", entityID: "e-res").map { $0.string("op") }, ["set_part"])
    }

    func testRemappingKeepsTheConnectionOfEachPinByNameAndRedrawsTheSymbol() throws {
        let fixture = try SchematicProjectEditFixture(testCase: self)
        let target = try fixture.addPart(entityName: "Fuse", pinNames: ["2", "1"])
        try fixture.placeResistors(["R1"])
        try fixture.apply([
            ["op": "connect", "component": "R1", "pin": "1", "net": "IN", "create_net": true],
            ["op": "connect", "component": "R1", "pin": "2", "net": "OUT", "create_net": true],
        ])
        let componentID = try XCTUnwrap(try fixture.symbol("R1").componentID).lowercased()
        var replacement = try XCTUnwrap(HorizontalPartReplacement.current(
            componentIDs: [componentID], archive: fixture.archive, project: fixture.project))
        replacement.allowsOtherEntities = true

        let ops = replacement.operations(partID: target.part, entityID: target.entity)
        XCTAssertEqual(ops.count, 1, "one op, one undo step")
        try fixture.apply(ops)

        let component = try XCTUnwrap(try fixture.blockJSON().dictionaryMap("components").first { $0.key.lowercased() == componentID }?.value)
        XCTAssertEqual(component.string("entity")?.lowercased(), target.entity)
        XCTAssertEqual(component.string("part")?.lowercased(), target.part)
        let sheet = try fixture.sheet
        let symbol = try XCTUnwrap(sheet.symbols.first { $0.componentID?.lowercased() == componentID }, "the gate is still drawn")
        let nets = Dictionary(uniqueKeysWithValues: try fixture.blockJSON().dictionaryMap("nets").map { ($0.key.lowercased(), $0.value.string("name") ?? "") })
        let connections = try XCTUnwrap(sheet.componentInfo[componentID]?.connections)
        var byName = [String: String]()
        for pin in symbol.symbolPinNames {
            if let net = connections[pin.gatePinPath.lowercased()]?.netID { byName[pin.primaryName] = nets[net.lowercased()] }
        }
        XCTAssertEqual(byName, ["1": "IN", "2": "OUT"])
    }
}
