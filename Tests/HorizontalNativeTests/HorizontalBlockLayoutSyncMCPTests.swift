import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Block instances kept laid out alike through MCP: a batch's edit of one
/// instance made in the others as only those changes in the board file,
/// previewed by a dry run and written by its commit; sync: false and a
/// batch that disagrees with itself; and sync_block_layout.
final class HorizontalBlockLayoutSyncMCPTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var client: BlockLayoutDispatchClient!
    private let mm = 1_000_000.0

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        try fixture.saveToDisk()
        client = try BlockLayoutDispatchClient(path: fixture.url.path)
    }

    override func tearDown() {
        client?.close()
        fixture?.remove()
        super.tearDown()
    }

    private func boardOnDisk() throws -> JSONDictionary {
        let project = try HorizontalProject.load(from: fixture.url)
        let url = project.baseURL.appendingPathComponent(try XCTUnwrap(project.boardFilename))
        return try JSONHelper.loadDictionary(from: url)
    }

    private func position(_ instance: Int, _ refdes: String, in board: JSONDictionary) throws -> HorizontalPoint {
        let package = try XCTUnwrap(board.dictionaryMap("packages").values.first {
            $0.string("component")?.lowercased() == fixture.flat(fixture.instances[instance], refdes)
        })
        let shift = try XCTUnwrap(package.dictionary("placement")?["shift"] as? [Any])
        return HorizontalPoint(x: JSONHelper.doubleValue(shift[0]), y: JSONHelper.doubleValue(shift[1]))
    }

    private func move(_ instance: Int, _ refdes: String, x: Double, y: Double) -> JSONDictionary {
        ["op": "place_component", "component": fixture.flat(fixture.instances[instance], refdes), "x_mm": x, "y_mm": y]
    }

    func testABatchsEditOfOneInstanceIsMadeInTheOthers() throws {
        let before = try boardOnDisk()
        let result = try XCTUnwrap(try client.result("apply", ["ops": [move(0, "R2", x: 5, y: 3)]]) as? JSONDictionary)
        XCTAssertEqual(result.dictionary("synced")?["instances"] as? [String], ["I2", "I3"])
        let after = try boardOnDisk()
        XCTAssertEqual(try position(0, "R2", in: after), HorizontalPoint(x: 5 * mm, y: 3 * mm))
        XCTAssertEqual(try position(1, "R2", in: after), HorizontalPoint(x: 25 * mm, y: 3 * mm))
        XCTAssertEqual(try position(2, "R2", in: after), HorizontalPoint(x: 45 * mm, y: 3 * mm))
        // Nothing else in the file changed.
        for key in Set(before.keys).union(after.keys) where key != "packages" {
            XCTAssertTrue((before[key] as? NSObject)?.isEqual(after[key]) ?? (before[key] == nil && after[key] == nil), key)
        }
        let changed = after.dictionaryMap("packages").filter { key, value in
            !((before.dictionaryMap("packages")[key] as NSDictionary?)?.isEqual(to: value) ?? false)
        }
        XCTAssertEqual(changed.count, 3, "the three R2s")
    }

    func testSyncFalseEditsOnlyWhatTheBatchNames() throws {
        let result = try XCTUnwrap(try client.result("apply", ["ops": [move(0, "R2", x: 5, y: 3)], "sync": false]) as? JSONDictionary)
        XCTAssertNil(result["synced"])
        XCTAssertEqual(try position(1, "R2", in: try boardOnDisk()), HorizontalPoint(x: 25 * mm, y: 0))
    }

    func testADryRunShowsTheSyncAndItsCommitWritesIt() throws {
        let dry = try XCTUnwrap(try client.result("apply", ["ops": [move(0, "R3", x: 10, y: -2)], "dry_run": true]) as? JSONDictionary)
        XCTAssertEqual(dry.dictionary("synced")?["instances"] as? [String], ["I2", "I3"])
        XCTAssertEqual(try position(1, "R3", in: try boardOnDisk()), HorizontalPoint(x: 30 * mm, y: 0), "a dry run writes nothing")
        let digest = try XCTUnwrap(dry.string("plan_digest"))
        let revision = try XCTUnwrap(dry.string("before_revision"))
        let commit = try XCTUnwrap(try client.result("apply", [
            "plan_digest": digest, "expected_revision": revision, "operation_id": UUID().uuidString,
        ]) as? JSONDictionary)
        XCTAssertEqual(commit.string("status"), "committed")
        XCTAssertEqual(try position(1, "R3", in: try boardOnDisk()), HorizontalPoint(x: 30 * mm, y: -2 * mm))
        XCTAssertEqual(try position(2, "R3", in: try boardOnDisk()), HorizontalPoint(x: 50 * mm, y: -2 * mm))
    }

    func testABatchThatDisagreesWithItselfIsRefused() throws {
        let response = try client.call("apply", ["ops": [move(0, "R2", x: 5, y: 3), move(1, "R2", x: 25, y: -3)]])
        let error = try XCTUnwrap(response["error"] as? JSONDictionary)
        XCTAssertEqual(error.dictionary("data")?.dictionary("details")?.string("reason") ?? error.dictionary("data")?.string("reason"),
                       "block_sync_conflict", "\(error)")
        XCTAssertEqual(try position(0, "R2", in: try boardOnDisk()), HorizontalPoint(x: 5 * mm, y: 0), "nothing was written")
    }

    func testSyncBlockLayoutLaysAnInstanceOutAsAnotherIs() throws {
        // I2's parts moved apart, on their own.
        _ = try client.result("apply", ["ops": [move(1, "R2", x: 25, y: 6), move(1, "R3", x: 30, y: 9)], "sync": false])
        let listed = try XCTUnwrap(try client.result("list_block_instances") as? [JSONDictionary])
        XCTAssertEqual(listed.first { $0.string("refdes") == "I1" }?.dictionary("board")?["in_sync_with"] as? [String], ["I3"])

        let result = try XCTUnwrap(try client.result("sync_block_layout", ["source": "I1", "targets": ["I2"]]) as? JSONDictionary)
        XCTAssertEqual(result["instances"] as? [String], ["I2"])
        let board = try boardOnDisk()
        XCTAssertEqual(try position(1, "R2", in: board), HorizontalPoint(x: 25 * mm, y: 0))
        XCTAssertEqual(try position(1, "R3", in: board), HorizontalPoint(x: 30 * mm, y: 0))
        let again = try XCTUnwrap(try client.result("list_block_instances") as? [JSONDictionary])
        XCTAssertEqual(again.first { $0.string("refdes") == "I1" }?.dictionary("board")?["in_sync_with"] as? [String], ["I2", "I3"])
    }
}
