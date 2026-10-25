import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A board's default via with no pool installed: the tented Circular via
/// Horizontal ships, horizon-pool's own file under its own uuid
/// (`HorizontalBuiltInPool`).
///
/// With no pool naming a default via, a new board got no via rule, so `v`
/// had no via to drop; and a via whose padstack no pool had was drawn and
/// exported with the rules' mask opening, so a tented via opened the mask on
/// both sides. Now the board's rule names the shipped via, the loader reads
/// its padstack from the copy shipped, and the project pool carries the
/// padstack, cached as Horizon caches an item the project takes from a pool.
final class HorizontalBuiltInViaTests: XCTestCase {
    private let tented = HorizontalProjectArchive.horizonPoolTentedCircularVia
    private let stock = HorizontalProjectArchive.horizonPoolCircularVia
    private var registry: UserDefaults = .standard

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        if !(environment["HORIZON_POOL"] ?? "").isEmpty || !(environment["HORIZONTAL_POOLS"] ?? "").isEmpty {
            throw XCTSkip("a pool is named in the environment")
        }
        // No pools registered, as on a machine without horizon-pool.
        registry = HorizontalPoolRegistryStore.defaults
        HorizontalPoolRegistryStore.defaults = UserDefaults(suiteName: "HorizontalBuiltInViaTests-\(UUID().uuidString)")!
        HorizontalPoolPadstacks.invalidateCaches()
    }

    override func tearDown() {
        HorizontalPoolRegistryStore.defaults = registry
        HorizontalPoolPadstacks.invalidateCaches()
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalBuiltInViaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A new document as File > New makes one with no pools registered, on
    /// disk at `directory/Untitled.horizontal`, its board edited by `edit`.
    private func newDocument(in directory: URL? = nil, edit: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
        let pool = HorizontalProjectDocument.projectPoolTemplate()
        XCTAssertEqual(pool, HorizontalProjectPoolTemplate(), "no pool to include or take a default via from")
        let url = try (directory ?? temporaryRoot()).appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject(pool: pool).write(to: url)
        let boardURL = url.appendingPathComponent("board.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        edit(&json)
        try HorizontalHorizonJSONWriter.data(json).write(to: boardURL)
        return url
    }

    /// The board with one via on its own junction, as Horizon writes one.
    private func addVia(padstack: String, at position: [Int], via: Int, hole: Int) -> (inout [String: Any]) -> Void {
        { json in
            json["junctions"] = ["j": ["position": position]]
            json["vias"] = ["v": [
                "junction": "j", "padstack": padstack, "source": "local", "from_rules": false,
                "parameter_set": ["via_diameter": via, "hole_diameter": hole]
            ]]
        }
    }

    private func cachedPadstack(_ uuid: String, in archive: HorizontalProjectArchive) -> Data? {
        archive.regularFileData(relativePath: "pool/" + HorizontalProjectArchive.cachedPadstackPath(uuid))
    }

    /// The layers an ODB++ job of the project has, by name.
    private func odbLayers(of project: HorizontalProject) throws -> Set<String> {
        let target = try temporaryRoot()
        var settings = HorizontalExportSettings(project: project)
        settings.targetDirectory = target.path
        settings.odb.format = .directory
        settings.odb.directoryName = "odb"
        let status = HorizontalExportBackend.export(sections: [.odb], settings: settings, project: project)
        XCTAssertEqual(status.kind, .success, status.message)
        let steps = target.appendingPathComponent("odb/steps")
        let step = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: steps.path).first)
        return Set(try FileManager.default.contentsOfDirectory(atPath: steps.appendingPathComponent("\(step)/layers").path))
    }

    // MARK: - A new document

    func testANewDocumentsBoardHasAViaRuleWithTheTentedViaAndItsPoolCarriesIt() throws {
        let url = try newDocument()
        let board = try XCTUnwrap(try HorizontalProject.load(from: url).board)
        XCTAssertTrue(board.rules.statesViaRules, "the template writes the rule")
        XCTAssertEqual(board.rules.viaRules.count, 1)
        XCTAssertEqual(board.rules.viaRules.first?.padstackID, tented)
        XCTAssertEqual(board.defaultViaPadstackID, tented)

        let poolURL = url.appendingPathComponent("pool")
        let cached = poolURL.appendingPathComponent(HorizontalProjectArchive.cachedPadstackPath(tented))
        XCTAssertEqual(try Data(contentsOf: cached), HorizontalBuiltInPool.padstackData(tented), "horizon-pool's file, in the project pool's cache")
        XCTAssertEqual(HorizontalPoolPadstacks.padstackName(id: tented, poolURL: poolURL), "Circular via (tented)")
    }

    /// `v` drops a via from the rule, and nothing opens the mask over it: not
    /// the canvas, which draws an opening on each of `maskLayers`, nor the
    /// Gerber and ODB++ files, read back through the board as it saved.
    func testVDropsAViaFromRulesThatIsTentedOnTheCanvasAndInGerberAndODB() throws {
        let url = try newDocument()
        let project = try HorizontalProject.load(from: url)
        var board = try XCTUnwrap(project.board)
        let via = try XCTUnwrap(board.routeVia(netID: nil), "the rule gives a via")
        XCTAssertTrue(via.fromRules)
        XCTAssertEqual(via.padstackID, tented)
        XCTAssertEqual(via.diameter, 500_000)
        XCTAssertEqual(via.holeDiameter, 200_000)

        let start = HorizontalPoint(x: 2_000_000, y: 2_000_000)
        let target = HorizontalPoint(x: 6_000_000, y: 4_000_000)
        let head = BoardTrackRouteHead(
            anchor: start, anchorJunctionID: nil, anchorOnPad: false, netID: nil,
            width: 200_000, layer: HorizontalBoardLayers.topCopper, placesVia: true)
        let laid = BoardTrackRouting.lay(
            BoardTrackRouting.route(from: start, to: target, horizontalFirst: true, cornerStyle: .ninety),
            to: target, endsOnPad: false, via: via, from: head, on: &board)
        XCTAssertEqual(laid.vias, 1)
        let dropped = try XCTUnwrap(board.vias.first)
        XCTAssertEqual(dropped.position, target)
        XCTAssertTrue(dropped.fromRules)
        XCTAssertEqual(dropped.maskLayers, [], "the canvas draws no opening")

        var archive = try HorizontalProjectArchive.completeProject(from: url)
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive))
        var saved = try HorizontalProject.loadSnapshot(of: archive)
        saved.rebaseURLs(onto: project)
        let read = try XCTUnwrap(saved.board?.vias.first)
        XCTAssertEqual(read.padstackID, tented)
        XCTAssertTrue(read.fromRules, "it goes on taking its shape from the rules")
        XCTAssertNil(read.topMaskExpansion)
        XCTAssertNil(read.bottomMaskExpansion)
        XCTAssertEqual(read.maskLayers, [])

        let gerbers = try HorizontalGerberExportFixture.exportGerbers(board: try XCTUnwrap(saved.board))
        XCTAssertNotNil(gerbers[HorizontalBoardLayers.topCopper], "the via's copper is there")
        XCTAssertNotNil(gerbers[HorizontalBoardLayers.bottomCopper])
        XCTAssertNil(gerbers[HorizontalBoardLayers.topMask], "and no opening in either mask")
        XCTAssertNil(gerbers[HorizontalBoardLayers.bottomMask])

        let layers = try odbLayers(of: saved)
        XCTAssertTrue(layers.isSuperset(of: ["signal_top", "signal_bottom"]), "\(layers)")
        XCTAssertTrue(layers.isDisjoint(with: ["mask_top", "mask_bottom"]), "\(layers)")
    }

    /// The tented via the pool lacks, as a board written elsewhere names it:
    /// its padstack is read from the copy shipped, which opens no mask, where
    /// it used to take the rules' opening on both sides.
    func testATentedViaThePoolLacksOpensNoMask() throws {
        let url = try newDocument(edit: addVia(padstack: tented, at: [5_000_000, 5_000_000], via: 500_000, hole: 200_000))
        try FileManager.default.removeItem(at: url.appendingPathComponent("pool/padstacks"))
        let project = try HorizontalProject.load(from: url)
        let via = try XCTUnwrap(project.board?.vias.first)
        XCTAssertNil(via.topMaskExpansion)
        XCTAssertNil(via.bottomMaskExpansion)
        let gerbers = try HorizontalGerberExportFixture.exportGerbers(board: try XCTUnwrap(project.board))
        XCTAssertNil(gerbers[HorizontalBoardLayers.topMask])
        XCTAssertNil(gerbers[HorizontalBoardLayers.bottomMask])
        XCTAssertTrue(try odbLayers(of: project).isDisjoint(with: ["mask_top", "mask_bottom"]))
    }

    /// horizon-pool's untented Circular via, with no pool: its own program
    /// gives the opening, the hole and twice the rules' expansion, not the
    /// via and twice the expansion the loader fell back to.
    func testTheStockViaWithNoPoolOpensTheMaskItsProgramSays() throws {
        let position = HorizontalPoint(x: 5_000_000, y: 5_000_000)
        let url = try newDocument(edit: addVia(padstack: stock, at: [5_000_000, 5_000_000], via: 600_000, hole: 300_000))
        let project = try HorizontalProject.load(from: url)
        let via = try XCTUnwrap(project.board?.vias.first)
        XCTAssertEqual(via.maskDiameter(on: HorizontalBoardLayers.topMask) ?? .nan, 300_000 + 2 * 100_000, accuracy: 1)
        XCTAssertEqual(via.maskDiameter(on: HorizontalBoardLayers.bottomMask) ?? .nan, 300_000 + 2 * 100_000, accuracy: 1)

        let gerbers = try HorizontalGerberExportFixture.exportGerbers(board: try XCTUnwrap(project.board))
        let topMask = try XCTUnwrap(gerbers[HorizontalBoardLayers.topMask])
        XCTAssertTrue(topMask.contains("G36*\nX\(Int64(position.x + 250_000))Y\(Int64(position.y))D02*"), topMask)
        XCTAssertTrue(try odbLayers(of: project).isSuperset(of: ["mask_top", "mask_bottom"]))
    }

    // MARK: - Cached when a board uses it

    /// A board written before the template gave one a via rule, whose pool
    /// carries no via: it gets Horizon's default rule with the tented via,
    /// and its next save caches the padstack into the project pool with the
    /// rule. Saving again caches nothing more, and a padstack nothing has is
    /// left out without stopping the save.
    func testAnOldBoardsNextSaveCachesItsDefaultViaIntoThePool() throws {
        let url = try newDocument { json in json["rules"] = [String: Any]() }
        try FileManager.default.removeItem(at: url.appendingPathComponent("pool/padstacks"))
        let project = try HorizontalProject.load(from: url)
        var board = try XCTUnwrap(project.board)
        XCTAssertFalse(board.rules.statesViaRules)
        XCTAssertEqual(board.rules.viaRules.first?.padstackID, tented)

        var archive = try HorizontalProjectArchive.completeProject(from: url)
        XCTAssertNil(cachedPadstack(tented, in: archive))
        board.vias.append(HorizontalMarker(
            id: "nowhere", position: HorizontalPoint(x: 1_000_000, y: 1_000_000), size: 500_000, holeSize: 200_000,
            layer: nil, padstackID: "1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c"))
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive))
        XCTAssertEqual(cachedPadstack(tented, in: archive), HorizontalBuiltInPool.padstackData(tented))
        XCTAssertNil(cachedPadstack("1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c", in: archive))

        func poolFiles() -> [String: Data?] {
            Dictionary(uniqueKeysWithValues: archive.regularFilePaths.filter { $0.hasPrefix("pool/") }.map { ($0, archive.regularFileData(relativePath: $0)) })
        }
        let pool = poolFiles()
        var saved = try HorizontalProject.loadSnapshot(of: archive)
        saved.rebaseURLs(onto: project)
        try HorizontalProjectJSONApplicator.apply(board: try XCTUnwrap(saved.board), in: saved, to: &archive)
        XCTAssertEqual(poolFiles(), pool, "nothing more to cache")
    }

    /// A via a pool has is cached from that pool, as Horizon caches it, and
    /// the pool's copy of a via Horizontal ships wins over the shipped one.
    func testAViaAPoolHasIsCachedFromThatPool() throws {
        let root = try temporaryRoot()
        let pool = root.appendingPathComponent("horizon-pool", isDirectory: true)
        try FileManager.default.createDirectory(at: pool.appendingPathComponent("padstacks"), withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(["type": "pool", "uuid": "bbbb", "name": "Pool", "pools_included": [String]()])
            .write(to: pool.appendingPathComponent("pool.json"))
        let custom = "5e2a7c1d-3b4f-4e6a-8d9c-0f1e2d3c4b5a"
        let customData = try HorizontalHorizonJSONWriter.data(["type": "padstack", "padstack_type": "via", "uuid": custom, "name": "Custom via"])
        try customData.write(to: pool.appendingPathComponent("padstacks/custom.json"))
        var poolTented = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(HorizontalBuiltInPool.padstackData(tented))) as? [String: Any])
        poolTented["name"] = "Circular via (tented), the pool's"
        let poolTentedData = try HorizontalHorizonJSONWriter.data(poolTented)
        try poolTentedData.write(to: pool.appendingPathComponent("padstacks/via-round-tented.json"))

        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = try newDocument(in: project, edit: addVia(padstack: custom, at: [5_000_000, 5_000_000], via: 500_000, hole: 200_000))
        try FileManager.default.removeItem(at: url.appendingPathComponent("pool/padstacks"))
        XCTAssertEqual(HorizontalPoolPadstacks.basePoolURLs(for: url.appendingPathComponent("pool")).map(\.lastPathComponent), ["horizon-pool"])

        let loaded = try HorizontalProject.load(from: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: try XCTUnwrap(loaded.board), in: loaded, to: &archive))
        XCTAssertEqual(cachedPadstack(custom, in: archive), customData)
        XCTAssertEqual(cachedPadstack(tented, in: archive), poolTentedData)
    }
}
