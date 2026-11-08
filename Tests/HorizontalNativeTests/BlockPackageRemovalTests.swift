import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A sub-block's component has a board package for each instance of the
/// block, under the flat uuid that instance gives it. Removing the component
/// — through the MCP, or by deleting its symbol on the block's sheet — or
/// removing an instance takes those packages off the board, as Horizon EDA's
/// board loader would. One left behind anyway is reported by check and can be
/// removed by its own id.
final class BlockPackageRemovalTests: XCTestCase {
    private var archive: HorizontalProjectArchive!
    private var project: HorizontalProject!
    private let channelID = "0c0c0c0c-1111-4222-8333-444455556666"
    private var resistor = ""
    private var first = ""
    private var second = ""

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("block-packages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)

        let poolURL = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let pin = HorizontalPoolItemFactory.newUUID()
        unit.pins = [pin: HorizontalUnitPin(id: pin, primaryName: "1")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [pin: HorizontalSymbolPin(id: pin, position: .zero, length: 2_500_000)]
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shape: HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        let pad = HorizontalPoolItemFactory.newUUID()
        package.pads[pad] = HorizontalPad(id: pad, name: "1", padstackID: padstack.uuid,
                                          placement: HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false))
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [pad: HorizontalPartPadMapEntry(gateID: gate, pinID: pin)]
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        // R1 inside Channel, drawn on its sheet, and two instances of Channel.
        try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        resistor = try XCTUnwrap(try apply([
            ["op": "ensure_component", "refdes": "R1", "part": part.uuid],
            ["op": "place_symbol", "component": "R1", "gate": gate, "x_mm": 10, "y_mm": 10],
        ], block: "Channel").first?["component"] as? String)
        first = try XCTUnwrap(try apply([["op": "add_block_instance", "block": "Channel", "refdes": "I1"]]).first?["block_instance"] as? String)
        second = try XCTUnwrap(try apply([["op": "add_block_instance", "block": "Channel", "refdes": "I2"]]).first?["block_instance"] as? String)

        // Each instance's R1 on the board, and a track off I1's pad, written
        // as Horizon writes one (place_track names a block's own components).
        try apply([
            ["op": "place_component", "component": flat(first), "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": flat(second), "x_mm": 20, "y_mm": 10],
        ])
        var board = try boardJSON()
        let firstPackage = try XCTUnwrap(board.dictionaryMap("packages").first { $0.value.string("component") == flat(first) }?.key)
        let junction = "55555555-2222-4333-8444-555566667777"
        var junctions = board.dictionaryMap("junctions")
        junctions[junction] = ["position": [15_000_000, 10_000_000]]
        board["junctions"] = junctions
        board["tracks"] = ["66666666-2222-4333-8444-555566667777": [
            "from": ["junc": NSNull(), "pad": "\(firstPackage)/\(pad)"], "to": ["junc": junction, "pad": NSNull()],
            "layer": 0, "width": 200_000, "width_from_net_class": false, "locked": false,
        ]]
        try putBoard(board)
        XCTAssertEqual(Set(try packageComponents()), [flat(first), flat(second)])
        XCTAssertEqual(try boardJSON().dictionaryMap("tracks").count, 1)
    }

    /// The flat uuid of R1 in `instance`, which its package names.
    private func flat(_ instance: String) -> String {
        HorizontalBlockFlattener.flattenedID([instance, resistor])
    }

    @discardableResult
    private func apply(_ ops: [JSONDictionary], block: String? = nil) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project, block: block)
        try install(edited.archive)
        return edited.changes
    }

    private func install(_ edited: HorizontalProjectArchive) throws {
        archive = edited
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
    }

    private func boardJSON() throws -> JSONDictionary {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    private func putBoard(_ board: JSONDictionary) throws {
        var edited = try XCTUnwrap(archive)
        try edited.replaceRegularFileData(relativePath: "board.json", with: JSONSerialization.data(withJSONObject: board))
        try install(edited)
    }

    private func packageComponents() throws -> [String] {
        try boardJSON().dictionaryMap("packages").values.compactMap { $0.string("component")?.lowercased() }
    }

    /// The track off I1's pad ends on a junction where the pad was.
    private func assertTrackKeptOnAJunction(file: StaticString = #filePath, line: UInt = #line) throws {
        let tracks = try boardJSON().dictionaryMap("tracks")
        XCTAssertEqual(tracks.count, 1, "the copper stays", file: file, line: line)
        let track = try XCTUnwrap(tracks.values.first)
        XCTAssertNil(track.dictionary("from")?.string("pad"), "no track names a pad that is gone", file: file, line: line)
        XCTAssertNotNil(track.dictionary("from")?.string("junc"), file: file, line: line)
    }

    func testRemovingABlocksComponentTakesEveryInstancesPackageOffTheBoard() throws {
        let changes = try apply([["op": "remove_component", "component": "R1"]], block: "Channel")
        XCTAssertEqual((changes.first?["removed"] as? JSONDictionary)?.int("packages"), 2)
        XCTAssertTrue(try packageComponents().isEmpty, "neither instance's package is left behind")
        try assertTrackKeptOnAJunction()
        XCTAssertEqual(project.board?.packages.count, 0)
    }

    func testDeletingTheSymbolOnTheBlocksSheetTakesEveryInstancesPackageOffTheBoard() throws {
        let schematic = try XCTUnwrap(project.schematics.first { $0.block.uuid == channelID }?.schematic)
        var sheet = try XCTUnwrap(schematic.sheets.first)
        XCTAssertEqual(sheet.symbols.count, 1)
        sheet.symbols = []
        try install(HorizontalCanvasProjectEdit.archive(deletingSelectionFrom: sheet, schematicURL: schematic.url, to: archive, in: project))
        XCTAssertTrue(try packageComponents().isEmpty, "the canvas delete takes every instance's footprint")
        try assertTrackKeptOnAJunction()
    }

    func testRemovingAnInstanceTakesItsPackagesOffTheBoard() throws {
        let changes = try apply([["op": "remove_block_instance", "instance": "I1"]])
        XCTAssertEqual(changes.first?.int("packages"), 1)
        XCTAssertEqual(try packageComponents(), [flat(second)], "the other instance keeps its package")
        try assertTrackKeptOnAJunction()
    }

    func testCheckReportsAPackageWhoseComponentIsGoneAndRemovePlacementTakesItOff() throws {
        // What a delete that missed the board left: a package naming a flat
        // uuid no block gives any more.
        let gone = HorizontalBlockFlattener.flattenedID([first, "33333333-2222-4333-8444-555566667777"])
        var board = try boardJSON()
        var packages = board.dictionaryMap("packages")
        let placed = try XCTUnwrap(packages.first { $0.value.string("component") == flat(second) })
        var orphan = placed.value
        orphan["component"] = gone
        packages.removeValue(forKey: placed.key)
        let orphanPackage = "44444444-2222-4333-8444-555566667777"
        packages[orphanPackage] = orphan
        board["packages"] = packages
        try putBoard(board)

        let report = HorizontalDispatchChecks.run(entry: HorizontalDispatchProjectEntry(handle: 1, url: project.baseURL, project: project), full: true)
        let found = (report["messages"] as? [JSONDictionary] ?? []).filter { $0.string("title") == "Package for a component that no longer exists" }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.string("level"), "error")
        XCTAssertTrue(found.first?.string("detail")?.contains(orphanPackage) == true)
        XCTAssertTrue(found.first?.string("detail")?.contains(gone) == true)

        // Named by the component uuid it draws, eight digits of it.
        let changes = try apply([["op": "remove_placement", "component": String(gone.prefix(8))]])
        XCTAssertEqual(changes.first?.string("package"), orphanPackage)
        XCTAssertEqual(changes.first?.int("removed_packages"), 1)
        XCTAssertEqual(try packageComponents(), [flat(first)], "the live instance's package stays")

        // Named by its own uuid, and refused once it is gone.
        var again = try boardJSON()
        var restored = again.dictionaryMap("packages")
        restored[orphanPackage] = orphan
        again["packages"] = restored
        try putBoard(again)
        XCTAssertEqual(try apply([["op": "remove_placement", "component": orphanPackage]]).first?.int("removed_packages"), 1)
        XCTAssertThrowsError(try apply([["op": "remove_placement", "component": orphanPackage]]))
    }

    // MARK: Orphans the load finds, and the removal the notice offers

    /// Rewrites the Channel block's file as `edit` says: the file a component
    /// deleted from the block without its packages leaves behind.
    private func editChannelBlock(_ edit: (inout JSONDictionary) -> Void) throws {
        let path = try XCTUnwrap(project.blocks.first { $0.uuid == channelID }?.blockFilename)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: path))
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        edit(&block)
        var edited = try XCTUnwrap(archive)
        try edited.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: block))
        try install(edited)
    }

    /// R1 leaves Channel and its two packages stay on the board. Channel keeps
    /// an unplaced second resistor: with no component left anywhere, every
    /// package would look orphaned, which the removal refuses on purpose.
    private func deleteResistorFromChannelWithoutItsPackages() throws {
        let keptID = "77777777-2222-4333-8444-555566667777"
        try editChannelBlock { block in
            var components = block.dictionaryMap("components")
            var kept = components[resistor] ?? JSONDictionary()
            kept["refdes"] = "R2"
            components.removeValue(forKey: resistor)
            components[keptID] = kept
            block["components"] = components
        }
    }

    func testACleanBoardHasNothingToRemoveAndNoNotice() {
        XCTAssertTrue(project.orphanedPackages.packages.isEmpty)
        XCTAssertNil(project.orphanedPackages.diagnosticMessage)
        XCTAssertFalse(project.diagnostics.contains { $0.message.contains("no block has") })
    }

    func testAComponentDeletedWithoutItsPackagesLeavesOrphansThatTheLoadListsButKeepsWhileCopperIsOnThem() throws {
        try deleteResistorFromChannelWithoutItsPackages()
        let orphans = project.orphanedPackages
        XCTAssertEqual(Set(orphans.packages.map(\.componentID)), [flat(first), flat(second)])
        XCTAssertFalse(orphans.canRemove, "the track off I1's pad would lose its copper")
        XCTAssertTrue(orphans.refusal?.contains("on their pads") == true, orphans.refusal ?? "no refusal")
        XCTAssertTrue(project.diagnostics.contains { $0.message.hasPrefix("2 board packages name a component no block has") })
        XCTAssertEqual(try packageComponents().count, 2, "nothing is removed by the load")
    }

    func testOrphansWithNoCopperOnThemAreRemovedAsOneEdit() throws {
        // Without the track off I1's pad, nothing ends on either orphan.
        var board = try boardJSON()
        board["tracks"] = JSONDictionary()
        try putBoard(board)
        try deleteResistorFromChannelWithoutItsPackages()
        let orphans = project.orphanedPackages
        XCTAssertTrue(orphans.canRemove)
        XCTAssertNil(orphans.refusal)

        let changes = try apply(orphans.removalOperations)
        XCTAssertEqual(Set(changes.compactMap { $0.string("package") }), Set(orphans.packages.map(\.id)))
        XCTAssertTrue(try packageComponents().isEmpty, "both orphans leave the board")
        XCTAssertTrue(project.orphanedPackages.packages.isEmpty, "the reload finds nothing left to offer")
        XCTAssertFalse(project.diagnostics.contains { $0.message.contains("no block has") })
    }

    func testOnlyTheOrphanLeavesTheBoardAndTheLivePackageStays() throws {
        // I2's package names a flat uuid no block gives: a delete that missed one instance.
        let gone = HorizontalBlockFlattener.flattenedID([second, "33333333-2222-4333-8444-555566667777"])
        var board = try boardJSON()
        var packages = board.dictionaryMap("packages")
        let secondPackage = try XCTUnwrap(packages.first { $0.value.string("component") == flat(second) }?.key)
        packages[secondPackage]?["component"] = gone
        board["packages"] = packages
        try putBoard(board)

        let orphans = project.orphanedPackages
        XCTAssertEqual(orphans.packages.map(\.componentID), [gone])
        XCTAssertTrue(orphans.canRemove, "the track is on I1's package, which is not an orphan")

        _ = try apply(orphans.removalOperations)
        XCTAssertEqual(try packageComponents(), [flat(first)], "the live instance's package stays")
        let track = try XCTUnwrap(try boardJSON().dictionaryMap("tracks").values.first)
        XCTAssertNotNil(track.dictionary("from")?.string("pad"), "the track keeps its pad")
    }

    func testRemovalIsRefusedWhileABlockFileDidNotLoad() throws {
        // Channel's file is unreadable, so its components are gone from the
        // design and every instance's package looks orphaned. Removing them
        // would delete a layout the file still has.
        let path = try XCTUnwrap(project.blocks.first { $0.uuid == channelID }?.blockFilename)
        var edited = try XCTUnwrap(archive)
        try edited.replaceRegularFileData(relativePath: path, with: Data("{ not json".utf8))
        try install(edited)

        let orphans = project.orphanedPackages
        XCTAssertEqual(orphans.packages.count, 2)
        XCTAssertFalse(orphans.canRemove)
        XCTAssertTrue(orphans.refusal?.contains("did not load") == true, orphans.refusal ?? "no refusal")
        XCTAssertTrue(orphans.refusal?.contains(path) == true, "the refusal names the file")
        XCTAssertEqual(try packageComponents().count, 2, "nothing is removed by the load")
    }

    func testAnIncludedPanelsPackagesAreNotThisBoardsOrphans() throws {
        // The panel's board names components of its own project, which this
        // one does not give. Its packages are on this board's list, but they
        // are not this file's to remove.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-orphans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var child = HorizontalProjectArchive.newProject()
        let panelPackage: JSONDictionary = [
            "component": "99999999-2222-4333-8444-555566667777",
            "placement": ["shift": [1_000_000, 2_000_000], "angle": 0, "mirror": false],
            "fixed": false, "flip": false, "omit_silkscreen": false, "smashed": false, "texts": [String](),
        ]
        try child.replaceRegularFileData(relativePath: "board.json", with: JSONSerialization.data(withJSONObject: [
            "name": "Child",
            "packages": ["88888888-2222-4333-8444-555566667777": panelPackage],
        ]))
        try child.write(to: root.appendingPathComponent("Child.horizontal"))

        var parent = HorizontalProjectArchive.newProject()
        try parent.replaceRegularFileData(relativePath: "board.json", with: JSONSerialization.data(withJSONObject: [
            "name": "Board",
            // Relative to the parent's package, which sits beside the child.
            "included_boards": ["bbbbbbbb-2222-4333-8444-555566667777": ["project_filename": "../Child.horizontal"]],
            "board_panels": ["cccccccc-2222-4333-8444-555566667777": [
                "included_board": "bbbbbbbb-2222-4333-8444-555566667777",
                "placement": ["shift": [0, 0], "angle": 0, "mirror": false],
            ]],
        ]))
        let url = root.appendingPathComponent("Parent.horizontal")
        try parent.write(to: url)

        let loaded = try HorizontalProject.load(from: url)
        XCTAssertFalse(loaded.board?.packages.isEmpty ?? true,
                       "the panel's package is on the board's list, so the case is exercised; diagnostics: \(loaded.diagnostics.map(\.message))")
        XCTAssertTrue(loaded.orphanedPackages.packages.isEmpty, "a panel's package is its own board's to report")
    }

    func testNoPackageIsRemovedFromADesignWithNoComponentsLeft() throws {
        // Every package would look orphaned if the blocks gave no components at
        // all, which is what a file read wrongly looks like too.
        try editChannelBlock { $0["components"] = JSONDictionary() }
        let orphans = project.orphanedPackages
        XCTAssertEqual(orphans.packages.count, 2)
        XCTAssertFalse(orphans.canRemove)
        XCTAssertEqual(orphans.refusal, "the blocks have no components")
    }
}
