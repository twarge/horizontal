import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// place_decal, the dispatch side of Design ▸ Place Decal…: a decal from the
/// pools a project draws from goes on the board as Horizon's
/// BoardDecal::serialize writes one, its pool item cached into the project
/// pool, which is where the loader draws a decal from, and it reads back as it
/// was placed — on a disk project and on a document open in the app alike.
@MainActor
final class HorizontalDispatchPlaceDecalTests: XCTestCase {
    private let mm = 1_000_000.0
    private let decalID = "5e0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
    private var root: URL!
    private var packageURL: URL!
    private var decalData = Data()
    private var handle = 0
    private var liveHandle: Int?

    /// The decal: an L of top silkscreen, a 2 mm line along x from its origin
    /// and a 1 mm one up y, as BoardPlaceDecalTests draws it.
    private func decalJSON(uuid: String, name: String) -> [String: Any] {
        let mm = Int(self.mm)
        return [
            "type": "decal",
            "uuid": uuid,
            "name": name,
            "junctions": [
                "a": ["position": [0, 0]],
                "b": ["position": [2 * mm, 0]],
                "c": ["position": [0, mm]],
            ],
            "lines": [
                "x": ["from": "a", "to": "b", "layer": HorizontalBoardLayers.topSilkscreen, "width": 100_000],
                "y": ["from": "a", "to": "c", "layer": HorizontalBoardLayers.topSilkscreen, "width": 100_000],
            ],
            "polygons": [String: Any](),
            "arcs": [String: Any](),
            "texts": [String: Any](),
        ]
    }

    /// The template project, and beside it a pool named horizon-pool holding
    /// the decal, which the project draws from as from a checkout of
    /// horizon-pool beside the projects.
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-dispatch-place-decal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalDispatchPlaceDecalTests-\(UUID().uuidString)"))
        HorizontalPoolRegistryStore.defaults = defaults
        HorizontalPoolLibrary.invalidateCache()
        addTeardownBlock {
            HorizontalPoolRegistryStore.defaults = .standard
            HorizontalPoolLibrary.invalidateCache()
        }

        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        let basePool = root.appendingPathComponent("horizon-pool", isDirectory: true)
        let decals = basePool.appendingPathComponent("decals", isDirectory: true)
        try FileManager.default.createDirectory(at: decals, withIntermediateDirectories: true)
        let poolJSON: [String: Any] = ["type": "pool", "uuid": "0d7c6b5a-4f3e-4d2c-9b1a-8f7e6d5c4b3a", "name": "Test Pool",
                                       "default_via": HorizontalProjectArchive.nullUUID, "pools_included": [String]()]
        try JSONSerialization.data(withJSONObject: poolJSON).write(to: basePool.appendingPathComponent("pool.json"))
        decalData = try JSONSerialization.data(withJSONObject: decalJSON(uuid: decalID, name: "Test Logo"), options: [.sortedKeys])
        try decalData.write(to: decals.appendingPathComponent("test-logo.json"))
    }

    override func tearDown() async throws {
        if let liveHandle { HorizontalDispatchSession.shared.unregisterLive(handle: liveHandle) }
        if handle != 0 {
            _ = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 0, "method": "close_project", "params": ["handle": handle]])
        }
    }

    private func openDisk() throws {
        let opened = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "open_project",
                                              "params": ["path": packageURL.path]])
        handle = try XCTUnwrap((opened["result"] as? JSONDictionary)?.int("handle"), "\(opened)")
    }

    private func revision(_ handle: Int) throws -> String {
        try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
    }

    /// apply_ops on `handle`, at its current revision unless `params` names one.
    private func apply(_ handle: Int, _ params: JSONDictionary) throws -> JSONDictionary {
        var params = params
        params["handle"] = handle
        params["detail"] = "compact"
        if params["expected_revision"] == nil { params["expected_revision"] = try revision(handle) }
        if params["operation_id"] == nil { params["operation_id"] = UUID().uuidString }
        return HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "apply", "params": params])
    }

    private func result(_ response: JSONDictionary, file: StaticString = #filePath, line: UInt = #line) throws -> JSONDictionary {
        if let error = response["error"] as? JSONDictionary {
            XCTFail("apply failed: \(error["message"] ?? error)", file: file, line: line)
        }
        return try XCTUnwrap(response["result"] as? JSONDictionary, file: file, line: line)
    }

    private func errorMessage(_ response: JSONDictionary) -> String? {
        (response["error"] as? JSONDictionary)?.string("message")
    }

    private func boardEntry(_ archive: HorizontalProjectArchive, _ id: String) throws -> JSONDictionary {
        let project = try HorizontalProject.loadSnapshot(of: archive)
        let board = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: XCTUnwrap(project.boardFilename))))
        return try XCTUnwrap(board.dictionaryMap("decals")[id], "no decal \(id) in \(board.dictionaryMap("decals").keys.sorted())")
    }

    private func line(_ decal: HorizontalBoardDecal, from: HorizontalPoint) -> HorizontalSegment? {
        decal.lines.first { $0.from == from || $0.to == from }
    }

    private var cachePath: String { "pool/decals/cache/\(decalID).json" }

    /// A dry run says what it would change and writes nothing; the commit of
    /// it writes the board's entry and the decal cached from horizon-pool,
    /// byte for byte with its provenance, and the board reads it back turned
    /// as it was placed.
    func testAPlacedDecalFromABasePoolIsWrittenCachedAndReadsBack() throws {
        try openDisk()
        let before = try HorizontalProjectArchive.snapshot(from: packageURL)
        let ops: [JSONDictionary] = [["op": "place_decal", "decal": "Test Logo", "x_mm": 10, "y_mm": 20, "angle_deg": 90, "id": "logo"]]
        let dry = try result(try apply(handle, ["ops": ops, "dry_run": true]))
        XCTAssertEqual(dry.bool("dry_run"), true)
        let wouldWrite = try XCTUnwrap(dry["would_write"] as? [String])
        XCTAssertTrue(wouldWrite.contains(cachePath), "\(wouldWrite)")
        XCTAssertTrue(wouldWrite.contains("board.json"), "\(wouldWrite)")
        XCTAssertTrue(wouldWrite.contains("pool/\(HorizontalPoolCacheProvenance.path)"), "\(wouldWrite)")
        let change = try XCTUnwrap((dry["changes"] as? [JSONDictionary])?.first)
        let id = try XCTUnwrap(change.string("id"))
        XCTAssertEqual((dry["handles"] as? JSONDictionary)?.string("logo"), id)
        XCTAssertEqual(change.string("decal"), decalID)
        XCTAssertEqual(change.string("name"), "Test Logo")
        XCTAssertEqual(change.string("pool"), "Test Pool")
        XCTAssertEqual(change["cached"] as? [String], [cachePath])
        let extent = try XCTUnwrap(change["extent_mm"] as? JSONDictionary)
        XCTAssertEqual(extent.double("min_x_mm") ?? 0, 9, accuracy: 1e-9)
        XCTAssertEqual(extent.double("max_x_mm") ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(extent.double("max_y_mm") ?? 0, 22, accuracy: 1e-9)
        XCTAssertEqual(try HorizontalProjectArchive.snapshot(from: packageURL), before, "a dry run writes nothing")

        let committed = try result(try apply(handle, ["plan_digest": try XCTUnwrap(dry.string("plan_digest")),
                                                      "expected_revision": try XCTUnwrap(dry.string("before_revision"))]))
        XCTAssertEqual((committed["changes"] as? [JSONDictionary])?.first?.string("id"), id, "the commit is the dry run")
        XCTAssertEqual(committed.string("undo_name"), "Place Decal")
        let saved = try HorizontalProjectArchive.snapshot(from: packageURL)
        XCTAssertEqual(try boardEntry(saved, id) as NSDictionary, [
            "decal": decalID,
            "placement": ["shift": [10_000_000, 20_000_000], "angle": 16_384, "mirror": false],
            "flip": false,
            "scale": 1,
        ] as NSDictionary)
        XCTAssertEqual(saved.regularFileData(relativePath: cachePath), decalData, "the decal is cached as its pool has it")
        let provenance = try HorizontalPoolCacheProvenance.load(saved.regularFileData(relativePath: "pool/\(HorizontalPoolCacheProvenance.path)"))
        XCTAssertNotNil(provenance.files["decals/cache/\(decalID).json"])

        let project = try HorizontalProject.load(from: packageURL)
        XCTAssertFalse(project.diagnostics.contains { $0.message.contains("decal") }, "\(project.diagnostics.map(\.message))")
        let decal = try XCTUnwrap(project.board?.decals.first { $0.id == id })
        XCTAssertEqual(decal.decalID, decalID)
        XCTAssertEqual(decal.position, HorizontalPoint(x: 10 * mm, y: 20 * mm))
        XCTAssertEqual(decal.angle, 16_384)
        XCTAssertFalse(decal.flip)
        // A quarter turn counterclockwise takes the 2 mm line along x up y.
        let x = try XCTUnwrap(line(decal, from: HorizontalPoint(x: 10 * mm, y: 22 * mm)))
        XCTAssertEqual(Set([x.from, x.to]), [HorizontalPoint(x: 10 * mm, y: 20 * mm), HorizontalPoint(x: 10 * mm, y: 22 * mm)])
        XCTAssertEqual(x.layer, HorizontalBoardLayers.topSilkscreen)
    }

    /// A flip mirrors the decal onto the bottom and inverts its angle in the
    /// file, so it still turns by angle_deg as the top view draws it, and a
    /// scale grows it; a decal the project pool already caches is not
    /// cached again, and one placed twice in a batch is cached once.
    func testFlipScaleAndCachingOnce() throws {
        try openDisk()
        let both = try result(try apply(handle, ["ops": [
            ["op": "place_decal", "decal": decalID, "x_mm": 0, "y_mm": 0],
            ["op": "place_decal", "decal": String(decalID.prefix(8)), "x_mm": 30, "y_mm": 30, "angle_deg": 90, "flip": true, "scale": 2],
        ]]))
        let changes = try XCTUnwrap(both["changes"] as? [JSONDictionary])
        XCTAssertEqual(changes.map { $0["cached"] as? [String] }, [[cachePath], []])
        let flippedID = try XCTUnwrap(changes.last?.string("id"))
        XCTAssertEqual(changes.last?.bool("flip"), true)
        XCTAssertEqual(changes.last?.double("angle_deg"), 90)

        let saved = try HorizontalProjectArchive.snapshot(from: packageURL)
        XCTAssertEqual(try boardEntry(saved, flippedID) as NSDictionary, [
            "decal": decalID,
            "placement": ["shift": [30_000_000, 30_000_000], "angle": 65_536 - 16_384, "mirror": true],
            "flip": true,
            "scale": 2,
        ] as NSDictionary)
        let decal = try XCTUnwrap(try HorizontalProject.load(from: packageURL).board?.decals.first { $0.id == flippedID })
        XCTAssertTrue(decal.flip)
        XCTAssertEqual(decal.scale, 2)
        // Mirrored, the 4 mm line runs along -x, and the quarter turn takes
        // it down y; it is on the bottom silkscreen.
        let x = try XCTUnwrap(line(decal, from: HorizontalPoint(x: 30 * mm, y: 26 * mm)))
        XCTAssertEqual(Set([x.from, x.to]), [HorizontalPoint(x: 30 * mm, y: 30 * mm), HorizontalPoint(x: 30 * mm, y: 26 * mm)])
        XCTAssertEqual(x.layer, HorizontalBoardLayers.bottomSilkscreen)

        let again = try result(try apply(handle, ["ops": [["op": "place_decal", "decal": "test logo", "x_mm": 5, "y_mm": 5]]]))
        XCTAssertEqual((again["changes"] as? [JSONDictionary])?.first?["cached"] as? [String], [])
        XCTAssertFalse((again["would_write"] as? [String] ?? []).contains(cachePath), "an already cached decal is left alone")
    }

    /// A decal in the project pool is placed from there and cached nowhere —
    /// even one pool_items brings in with the same batch, before it is on
    /// disk — and it then outranks a base pool's decal of the same name.
    func testAProjectPoolDecalIsPlacedWithoutCaching() throws {
        try openDisk()
        let ownID = "6f1d2b3c-4d5e-4f60-9b0a-1d2e3f4a5b6c"
        let own = decalJSON(uuid: ownID, name: "Own Logo")
        let placed = try result(try apply(handle, ["pool_items": [own], "ops": [["op": "place_decal", "decal": "Own Logo", "x_mm": 1, "y_mm": 2]]]))
        let change = try XCTUnwrap((placed["changes"] as? [JSONDictionary])?.first)
        XCTAssertEqual(change.string("decal"), ownID)
        XCTAssertEqual(change["cached"] as? [String], [])
        XCTAssertFalse((placed["would_write"] as? [String] ?? []).contains { $0.contains("decals/cache") })
        let decal = try XCTUnwrap(try HorizontalProject.load(from: packageURL).board?.decals.first { $0.id == change.string("id") })
        XCTAssertEqual(decal.name, "Own Logo")
    }

    func testAnUnknownOrAmbiguousDecalAndABadScaleAreRefused() throws {
        try openDisk()
        let unknown = try apply(handle, ["ops": [["op": "place_decal", "decal": "No Such Logo", "x_mm": 0, "y_mm": 0]]])
        XCTAssertTrue(errorMessage(unknown)?.contains("search_pool with kind decal") == true, "\(unknown)")

        let twin = root.appendingPathComponent("horizon-pool/decals/twin.json")
        try JSONSerialization.data(withJSONObject: decalJSON(uuid: "7a2e3c4d-5e6f-4071-8c1b-2e3f4a5b6c7d", name: "Test Logo"))
            .write(to: twin)
        HorizontalPoolLibrary.invalidateCache()
        let ambiguous = try apply(handle, ["ops": [["op": "place_decal", "decal": "Test Logo", "x_mm": 0, "y_mm": 0]]])
        XCTAssertTrue(errorMessage(ambiguous)?.contains("2 decals are called Test Logo") == true, "\(ambiguous)")

        let scale = try apply(handle, ["ops": [["op": "place_decal", "decal": decalID, "x_mm": 0, "y_mm": 0, "scale": 0]]])
        XCTAssertTrue(errorMessage(scale)?.contains("scale must be more than zero") == true, "\(scale)")
        let missing = try apply(handle, ["ops": [["op": "place_decal", "decal": decalID]]])
        XCTAssertTrue(errorMessage(missing)?.contains("x_mm") == true, "\(missing)")
        XCTAssertNil(try HorizontalProjectArchive.snapshot(from: packageURL).regularFileData(relativePath: cachePath))
    }

    /// On a document open in the app, the decal and its cached pool item land
    /// in the document's archive as one undoable step, and the last-saved
    /// project on disk is left as it was; a dry run hands the document nothing.
    func testALiveDocumentTakesTheDecalAndItsCacheAsOneStep() throws {
        let original = try HorizontalProjectArchive.snapshot(from: packageURL)
        let project = try HorizontalProject.load(from: packageURL)
        let document = HorizontalLiveDocument(url: packageURL, title: "Live decal", project: project, archive: original)
        var revision = 0
        var current = project
        var currentArchive = original
        var applied = [String]()
        document.currentProject = { current }
        document.revision = { String(revision) }
        document.archive = { currentArchive }
        document.applyArchive = { edited, name in
            applied.append(name)
            currentArchive = edited
            current = try HorizontalDispatchSession.project(from: HorizontalDispatchSnapshot(archive: edited, baseURL: project.baseURL),
                                                            url: project.url)
            revision += 1
        }
        let live = HorizontalDispatchSession.shared.registerLive(document)
        liveHandle = live

        let ops: [JSONDictionary] = [["op": "place_decal", "decal": "Test Logo", "x_mm": 4, "y_mm": 6]]
        let dry = try result(try apply(live, ["ops": ops, "dry_run": true]))
        XCTAssertEqual(dry.bool("live"), true)
        XCTAssertTrue((dry["would_write"] as? [String] ?? []).contains(cachePath))
        XCTAssertEqual(applied, [], "a dry run hands the document nothing")

        let committed = try result(try apply(live, ["ops": ops]))
        let id = try XCTUnwrap((committed["changes"] as? [JSONDictionary])?.first?.string("id"))
        XCTAssertEqual(applied, ["Place Decal"])
        let entry = try boardEntry(currentArchive, id)
        XCTAssertEqual(entry.string("decal"), decalID)
        XCTAssertEqual(currentArchive.regularFileData(relativePath: cachePath), decalData)
        XCTAssertEqual(current.board?.decals.first { $0.id == id }?.position, HorizontalPoint(x: 4 * mm, y: 6 * mm))
        XCTAssertEqual(try HorizontalProjectArchive.snapshot(from: packageURL), original, "a live edit never writes the saved project")
    }
}
