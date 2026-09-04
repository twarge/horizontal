import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The editor session behind a pool item document: commits serialise in
/// Horizon's format and reach the document, undo restores and re-persists,
/// read-only operation is a no-op, and the pool root resolves from the item.
final class HorizontalPoolItemEditorSessionTests: XCTestCase {
    private var temporaryRoot: URL!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolItemEditorSessionTests-\(UUID().uuidString)", isDirectory: true)
        testDefaults = UserDefaults(suiteName: "HorizontalPoolItemEditorSessionTests-\(UUID().uuidString)")
        HorizontalPoolRegistryStore.defaults = testDefaults
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func write(_ json: JSONDictionary, to relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(json).write(to: url)
        return url
    }

    private static var unitJSON: JSONDictionary { [
        "type": "unit", "uuid": "u1", "name": "Resistor", "manufacturer": "",
        "pins": ["p1": ["primary_name": "1", "direction": "passive", "swap_group": 1, "names": []]],
    ] }

    @MainActor
    private func makeSession() throws -> (HorizontalPoolItemEditorSession, URL) {
        _ = try write(["type": "pool", "uuid": "pool-1", "name": "Test Pool"], to: "pool/pool.json")
        let itemURL = try write(Self.unitJSON, to: "pool/units/resistor.json")
        let session = try HorizontalPoolItemEditorSession(
            itemURL: itemURL,
            poolURL: HorizontalPoolLibrary.poolRoot(forItemURL: itemURL),
            category: .unit,
            data: try Data(contentsOf: itemURL)
        )
        return (session, itemURL)
    }

    @MainActor
    func testCommitPersistsHorizonFormatBytesAndRegistersUndo() throws {
        let (session, _) = try makeSession()
        XCTAssertEqual(session.title, "Resistor")
        XCTAssertEqual(session.poolName, "Test Pool")
        var persisted = [Data]()
        session.persist = { persisted.append($0) }
        let undoManager = UndoManager()

        guard case .unit(var unit) = session.model else {
            return XCTFail("expected a unit")
        }
        unit.name = "Resistor, generic"
        session.commit(.unit(unit), actionName: "Rename Unit", undoManager: undoManager, isReadOnly: false)

        XCTAssertEqual(session.model.name, "Resistor, generic")
        XCTAssertEqual(persisted.count, 1)
        let written = try XCTUnwrap(persisted.last)
        XCTAssertEqual(written, session.lastSerializedData)
        XCTAssertTrue(String(decoding: written, as: UTF8.self).hasPrefix("{\n    \"manufacturer\": \"\",\n    \"name\": \"Resistor, generic\","))
        XCTAssertNotEqual(written.last, 0x0A)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Rename Unit")

        undoManager.undo()
        XCTAssertEqual(session.model.name, "Resistor")
        XCTAssertEqual(persisted.count, 2, "undo re-persists the restored model")
        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(session.model.name, "Resistor, generic")
        XCTAssertEqual(persisted.count, 3)
    }

    /// A canvas records its own undo step for every edit; the model update
    /// that follows must persist but not add a second entry.
    @MainActor
    func testCanvasCommitsPersistWithoutRegisteringUndo() throws {
        let (session, _) = try makeSession()
        var persisted = [Data]()
        session.persist = { persisted.append($0) }
        let undoManager = UndoManager()

        guard case .unit(var unit) = session.model else {
            return XCTFail("expected a unit")
        }
        unit.name = "Silent"
        session.commit(.unit(unit), actionName: "Edit", undoManager: undoManager, isReadOnly: false, registersUndo: false)

        XCTAssertEqual(session.model.name, "Silent")
        XCTAssertEqual(persisted.count, 1)
        XCTAssertFalse(undoManager.canUndo)
    }

    @MainActor
    func testUnchangedAndReadOnlyCommitsAreIgnored() throws {
        let (session, _) = try makeSession()
        var persisted = 0
        session.persist = { _ in persisted += 1 }
        let undoManager = UndoManager()

        session.commit(session.model, actionName: "Nothing", undoManager: undoManager, isReadOnly: false)
        XCTAssertEqual(persisted, 0)
        XCTAssertFalse(undoManager.canUndo)

        guard case .unit(var unit) = session.model else {
            return XCTFail("expected a unit")
        }
        unit.name = "Changed"
        session.commit(.unit(unit), actionName: "Rename Unit", undoManager: undoManager, isReadOnly: true)
        XCTAssertEqual(session.model.name, "Resistor")
        XCTAssertEqual(persisted, 0)
        XCTAssertFalse(undoManager.canUndo)
    }

    @MainActor
    func testSessionWithoutAPoolFallsBackToTheItemsDirectory() throws {
        let itemURL = try write(Self.unitJSON, to: "loose/resistor.json")
        let session = try HorizontalPoolItemEditorSession(
            itemURL: itemURL,
            poolURL: HorizontalPoolLibrary.poolRoot(forItemURL: itemURL),
            category: .unit,
            data: try Data(contentsOf: itemURL)
        )
        XCTAssertEqual(session.poolURL.lastPathComponent, "loose")
        XCTAssertEqual(session.libraryItem.url, itemURL.standardizedFileURL)
        XCTAssertEqual(session.libraryItem.category, .unit)
    }

    @MainActor
    func testIndexResolvesCrossReferencesThroughThePool() async throws {
        let (session, _) = try makeSession()
        _ = try write(
            ["type": "symbol", "uuid": "s1", "name": "R", "unit": "u1", "pins": [:]],
            to: "pool/symbols/r.json"
        )
        await session.rebuildIndex()
        XCTAssertEqual(session.index.name(.symbol, uuid: "s1"), "R")
        XCTAssertEqual(session.index.name(.unit, uuid: "u1"), "Resistor")
        XCTAssertEqual(session.libraryItem.poolName, "Test Pool")
    }

    func testPoolRootWalksUpToTheNearestPoolJSON() throws {
        _ = try write(["type": "pool", "uuid": "outer"], to: "outer/pool.json")
        _ = try write(["type": "pool", "uuid": "inner"], to: "outer/nested/inner/pool.json")
        let deep = try write(["type": "unit", "uuid": "u", "name": "U", "pins": [:]], to: "outer/nested/inner/units/a/b.json")
        let shallow = try write(["type": "unit", "uuid": "v", "name": "V", "pins": [:]], to: "outer/units/c.json")
        let loose = try write(["type": "unit", "uuid": "w", "name": "W", "pins": [:]], to: "elsewhere/d.json")

        XCTAssertEqual(HorizontalPoolLibrary.poolRoot(forItemURL: deep)?.lastPathComponent, "inner")
        XCTAssertEqual(HorizontalPoolLibrary.poolRoot(forItemURL: shallow)?.lastPathComponent, "outer")
        XCTAssertNil(HorizontalPoolLibrary.poolRoot(forItemURL: loose))
    }

    func testRegisteredPoolCoversItsItemsBeforeTheWalk() throws {
        _ = try write(["type": "pool", "uuid": "reg"], to: "registered/pool.json")
        let item = try write(["type": "unit", "uuid": "u", "name": "U", "pins": [:]], to: "registered/units/x.json")
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: temporaryRoot.appendingPathComponent("registered", isDirectory: true)))
        XCTAssertEqual(
            HorizontalPoolLibrary.poolRoot(forItemURL: item)?.standardizedFileURL,
            temporaryRoot.appendingPathComponent("registered", isDirectory: true).standardizedFileURL
        )
    }

    func testEditorPoolURLsStartWithTheRootThenIncludedThenRegistered() throws {
        _ = try write(["type": "pool", "uuid": "base-uuid", "name": "Base"], to: "base/pool.json")
        _ = try write(["type": "pool", "uuid": "other-uuid", "name": "Other"], to: "other/pool.json")
        _ = try write(
            ["type": "pool", "uuid": "own-uuid", "name": "Own", "pools_included": ["base-uuid"]],
            to: "own/pool.json"
        )
        let base = temporaryRoot.appendingPathComponent("base", isDirectory: true)
        let other = temporaryRoot.appendingPathComponent("other", isDirectory: true)
        let own = temporaryRoot.appendingPathComponent("own", isDirectory: true)
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: other))
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: base))

        let urls = HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: own).map(\.lastPathComponent)
        XCTAssertEqual(Array(urls.prefix(2)), ["own", "base"], "own pool first, then the pool it includes")
        XCTAssertTrue(urls.contains("other"))
        XCTAssertEqual(Set(urls).count, urls.count, "no duplicates")
    }

    func testPoolItemCategoryDetection() throws {
        XCTAssertEqual(JSONHelper.poolItemCategory(in: try HorizontalHorizonJSONWriter.data(Self.unitJSON)), .unit)
        XCTAssertNil(JSONHelper.poolItemCategory(in: try HorizontalHorizonJSONWriter.data(["type": "pool"])))
        XCTAssertNil(JSONHelper.poolItemCategory(in: try HorizontalHorizonJSONWriter.data(["type": "project"])))
        XCTAssertNil(JSONHelper.poolItemCategory(in: Data("not json".utf8)))
    }

    func testSingleFileArchiveRoundTripsThroughTheDocumentWriter() throws {
        let original = try HorizontalHorizonJSONWriter.data(Self.unitJSON)
        var archive = HorizontalProjectArchive(regularFileData: original, suggestedFilename: "resistor.json")
        let edited = try HorizontalHorizonJSONWriter.data(["type": "unit", "uuid": "u1", "name": "Edited", "pins": [:]])
        archive.root = .regularFile(edited)
        let wrapper = try archive.projectFileWrapper()
        XCTAssertTrue(wrapper.isRegularFile)
        XCTAssertEqual(wrapper.regularFileContents, edited)
    }
}
