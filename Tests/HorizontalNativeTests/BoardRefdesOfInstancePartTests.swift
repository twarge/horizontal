import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A refdes set on the board is the flattened component's: a top block
/// component's own, or, for a part of a block instance, that instance's in
/// the top block's mapping. The block the part is drawn in is not given a
/// component under the board's flat uuid, whichever sheet the schematic
/// pane shows. The design is `BlockLayoutFixture`'s: Channel's R1, R2 and
/// R3, used as I1 and I2.
final class BoardRefdesOfInstancePartTests: XCTestCase {
    private var fixture: BlockLayoutFixture!

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func block(named name: String) throws -> HorizontalProjectBlock {
        try XCTUnwrap(fixture.project.blocks.first { $0.displayName == name })
    }

    private func topBlock() throws -> HorizontalProjectBlock {
        try XCTUnwrap(fixture.project.blocks.first(where: \.isTop))
    }

    private func json(of block: HorizontalProjectBlock, in archive: HorizontalProjectArchive? = nil) throws -> JSONDictionary {
        let path = try XCTUnwrap(block.blockFilename)
        let data = try XCTUnwrap((archive ?? fixture.archive).regularFileData(relativePath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    /// The refdes one instance path's mapping gives a component, nil where
    /// the mapping does not name it.
    private func mappedRefdes(_ path: [String], _ component: String) throws -> String? {
        let mappings = try json(of: try topBlock()).dictionaryMap("block_instance_mappings")
        let key = path.joined(separator: "/").lowercased()
        let mapping = mappings.first { $0.key.lowercased() == key }?.value
        return mapping?.dictionaryMap("components").first { $0.key.lowercased() == component.lowercased() }?.value.string("refdes")
    }

    func testAnInstancePartsRefdesIsKeptInItsInstancesMapping() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let (i1, i2) = (fixture.instances[0], fixture.instances[1])
        let r2 = try XCTUnwrap(fixture.components["R2"])
        let flat = fixture.flat(i1, "R2")

        let target = try XCTUnwrap(fixture.project.boardRefdesTarget(forComponent: flat.uppercased()), "an id in either case")
        XCTAssertEqual(target, .instance(block: fixture.channelID, path: [i1.lowercased()], component: r2.lowercased()))
        let edit = try XCTUnwrap(target.instanceOperation(settingRefdes: "R42"))
        try fixture.apply([edit.operation], block: edit.block)

        XCTAssertEqual(try mappedRefdes([i1], r2), "R42")
        XCTAssertNotEqual(try mappedRefdes([i2], r2), "R42", "the other instance keeps its own")
        XCTAssertEqual(try fixture.package(of: flat).componentDetails?.refdes, "R42", "which the board shows")
        XCTAssertNotEqual(try fixture.package(of: fixture.flat(i2, "R2")).componentDetails?.refdes, "R42")

        let channel = try json(of: try block(named: "Channel")).dictionaryMap("components")
        XCTAssertEqual(channel.count, 3, "Channel is R1, R2 and R3 still")
        XCTAssertNil(channel.first { $0.key.lowercased() == flat.lowercased() }, "no component under the board's flat uuid")
        XCTAssertEqual(channel.first { $0.key.lowercased() == r2.lowercased() }?.value.string("refdes"), "R2", "the block's own is left alone")
    }

    /// Channel uses Sub as S1: Sub's resistor in I1 is kept under the path
    /// I1/S1, on Sub.
    func testAPartOfABlockInsideABlockIsKeptUnderItsWholePath() throws {
        fixture = try BlockLayoutFixture(instances: 2, nested: true)
        let i1 = fixture.instances[0]
        let flat = fixture.nestedFlat(i1)
        let sub = try block(named: "Sub")

        let target = try XCTUnwrap(fixture.project.boardRefdesTarget(forComponent: flat))
        XCTAssertEqual(target, .instance(block: sub.uuid.lowercased(), path: [i1.lowercased(), fixture.subInstance.lowercased()],
                                         component: fixture.subResistor.lowercased()))
        let edit = try XCTUnwrap(target.instanceOperation(settingRefdes: "R77"))
        try fixture.apply([edit.operation], block: edit.block)

        XCTAssertEqual(try mappedRefdes([i1, fixture.subInstance], fixture.subResistor), "R77")
        XCTAssertEqual(try fixture.package(of: flat).componentDetails?.refdes, "R77")
        XCTAssertEqual(try json(of: sub).dictionaryMap("components").count, 1, "Sub is its one resistor still")
    }

    func testATopBlockComponentsRefdesIsTheBlocksOwn() throws {
        fixture = try BlockLayoutFixture(instances: 1)
        let connector = try XCTUnwrap(try fixture.apply([
            ["op": "ensure_component", "refdes": "J1", "part": fixture.partID],
        ]).first?["component"] as? String)

        let target = try XCTUnwrap(fixture.project.boardRefdesTarget(forComponent: connector))
        XCTAssertEqual(target, .topBlock(component: connector.lowercased()))
        XCTAssertNil(target.instanceOperation(settingRefdes: "J2"), "no instance's mapping holds it")
    }

    func testAComponentTheDesignLacksIsKeptNowhere() throws {
        fixture = try BlockLayoutFixture(instances: 1)
        XCTAssertNil(fixture.project.boardRefdesTarget(forComponent: "0f0f0f0f-0000-4000-8000-000000000000"))
    }

    /// A design with no block instances is not flattened: its board's
    /// components are the top block's.
    func testWithNoInstancesTheBoardsComponentsAreTheTopBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-refdes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Flat.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        let project = try HorizontalProject.load(from: url)
        XCTAssertNil(project.flattenedBlock)
        XCTAssertEqual(project.boardRefdesTarget(forComponent: "ABCDEF00-0000-4000-8000-000000000000"),
                       .topBlock(component: "abcdef00-0000-4000-8000-000000000000"))
    }

    /// The block file is given a refdes only for a component it has: the
    /// flat uuid of an instance's part is none of Channel's own.
    func testARefdesForAComponentTheBlockLacksAddsNoComponent() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let channel = try block(named: "Channel")
        let blockURL = fixture.project.baseURL.appendingPathComponent(try XCTUnwrap(channel.blockFilename))
        let r2 = try XCTUnwrap(fixture.components["R2"])
        let flat = fixture.flat(fixture.instances[0], "R2")
        var archive = fixture.archive

        try HorizontalProjectJSONApplicator.apply(componentRefdes: "R42", forComponentID: flat, blockURL: blockURL,
                                                  in: fixture.project, to: &archive)
        var components = try json(of: channel, in: archive).dictionaryMap("components")
        XCTAssertEqual(components.count, 3)
        XCTAssertNil(components.first { $0.key.lowercased() == flat.lowercased() })
        XCTAssertEqual(components.first { $0.key.lowercased() == r2.lowercased() }?.value.string("refdes"), "R2")

        try HorizontalProjectJSONApplicator.apply(componentRefdes: "R5", forComponentID: r2.uppercased(), blockURL: blockURL,
                                                  in: fixture.project, to: &archive)
        components = try json(of: channel, in: archive).dictionaryMap("components")
        XCTAssertEqual(components.count, 3)
        XCTAssertEqual(components.first { $0.key.lowercased() == r2.lowercased() }?.value.string("refdes"), "R5", "one it has, in either case")
    }
}
