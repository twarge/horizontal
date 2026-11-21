import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Copy in one block's schematic, paste in another's: the clipboard carries
/// the circuit, so it lands in whichever block the destination sheet draws.
extension SchematicClipboardTests {
    /// The shared fixture with a block, Channel, whose sheet has a resistor
    /// wired to the block's IN port, a named net and a power net.
    func channelFixture() throws -> (fixture: Fixture, channel: HorizontalProjectSchematic) {
        var fixture = try fixture()
        let part = try XCTUnwrap(try block(fixture.archive).dictionaryMap("components").values.first?.string("part"))
        fixture = try applying([["op": "add_block", "name": "Channel"]], to: fixture)
        let inBlock = try HorizontalCanvasProjectEdit.archive(applying: [
            ["op": "ensure_net", "name": "IN"],
            ["op": "set_net_port", "net": "IN", "port_direction": "input"],
            ["op": "ensure_component", "refdes": "R1", "part": part],
            ["op": "ensure_component", "refdes": "R2", "part": part],
            ["op": "connect", "component": "R1", "pin": "1", "net": "IN"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "MID", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "2", "net": "MID"],
            ["op": "connect", "component": "R2", "pin": "3", "net": "GND", "create_net": true],
            ["op": "place_symbol", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_symbol", "component": "R2", "x_mm": 20, "y_mm": 10],
            ["op": "draw_net_line", "component": "R1", "pin": "2", "to_component": "R2", "to_pin": "2"],
            ["op": "place_net_label", "net": "IN", "x_mm": 5, "y_mm": 10],
            ["op": "place_power_symbol", "net": "GND", "x_mm": 20, "y_mm": 5],
            ["op": "place_text", "text": "Channel", "x_mm": 15, "y_mm": 20]
        ], to: fixture.archive, in: fixture.project, block: "Channel").archive
        var reloaded = try HorizontalProject.loadSnapshot(of: inBlock)
        reloaded.rebaseURLs(onto: fixture.project)
        fixture = Fixture(archive: inBlock, project: reloaded)
        fixture = try applying([
            ["op": "add_block_instance", "id": "a", "block": "Channel", "refdes": "CHA"],
            ["op": "place_block_symbol", "instance": "a", "x_mm": 60, "y_mm": 40]
        ], to: fixture)
        let channel = try XCTUnwrap(fixture.project.schematics.first { !$0.block.isTop })
        return (fixture, channel)
    }

    func testWhatIsCopiedInABlockPastesIntoTheTopSchematic() throws {
        let (fixture, channel) = try channelFixture()
        let source = try XCTUnwrap(channel.schematic.sheets.first)
        XCTAssertEqual(source.symbols.count, 2)
        let clipboard = try HorizontalSchematicClipboardEditor.copy(
            allRefs(source), from: source, schematicURL: channel.schematic.url,
            anchor: .zero, archive: fixture.archive, project: fixture.project
        )
        let top = try XCTUnwrap(fixture.project.schematics.first { $0.block.isTop })
        let paste = try HorizontalSchematicClipboardEditor.prepare(
            HorizontalSchematicClipboard(data: clipboard.data()), at: HorizontalPoint(x: 30_000_000, y: 0),
            sheetID: fixture.sheet.id, schematicURL: top.schematic.url,
            archive: fixture.archive, project: fixture.project
        )
        XCTAssertEqual(paste.sheet.symbols.count, fixture.sheet.symbols.count + 2)
        let topBlock = try block(paste.archive)
        let refdeses = Set(topBlock.dictionaryMap("components").values.compactMap { $0.string("refdes") })
        XCTAssertEqual(refdeses, ["R1", "R2", "R3", "R4"], "the pasted resistors are the top block's own")
        let nets = topBlock.dictionaryMap("nets").values
        let pastedIn = try XCTUnwrap(nets.first { $0.string("name") == "IN" })
        XCTAssertEqual(pastedIn.bool("is_port"), false, "the top block has no ports")
        XCTAssertEqual(nets.filter { $0.string("name") == "GND" }.count, 1, "the block's GND is the top block's")
    }

    func testWhatIsCopiedInTheTopSchematicPastesIntoABlock() throws {
        let (fixture, channel) = try channelFixture()
        let top = try XCTUnwrap(fixture.project.schematics.first { $0.block.isTop })
        let source = fixture.sheet
        let destination = try XCTUnwrap(channel.schematic.sheets.first)
        let clipboard = try HorizontalSchematicClipboardEditor.copy(
            allRefs(source), from: source, schematicURL: top.schematic.url,
            anchor: .zero, archive: fixture.archive, project: fixture.project
        )
        let paste = try HorizontalSchematicClipboardEditor.prepare(
            HorizontalSchematicClipboard(data: clipboard.data()), at: HorizontalPoint(x: 30_000_000, y: 0),
            sheetID: destination.id, schematicURL: channel.schematic.url,
            archive: fixture.archive, project: fixture.project
        )
        XCTAssertEqual(paste.sheet.symbols.count, destination.symbols.count + 2)
        let placed = try paste.placedArchive(.init(shift: .zero, angle: 0, mirrored: false), in: fixture.archive)
        let reloaded = try HorizontalProject.loadSnapshot(of: placed)
        let channelAfter = try XCTUnwrap(reloaded.schematics.first { !$0.block.isTop })
        XCTAssertEqual(channelAfter.schematic.sheets.first?.symbols.count, destination.symbols.count + 2)
        XCTAssertEqual(reloaded.schematics.first { $0.block.isTop }?.schematic.sheets.first?.symbols.count, source.symbols.count)
    }
}
