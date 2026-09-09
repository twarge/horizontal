import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

final class HorizontalDispatchReliabilityTests: XCTestCase {
    private var url: URL!
    private var handle = 0

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let opened = try result("open_project", ["path": url.path]) as! JSONDictionary
        handle = opened["handle"] as! Int
        addTeardownBlock { [handle] in
            _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func call(_ method: String, _ values: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = values
        if method != "open_project" { params["handle"] = handle }
        return HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
    }

    private func result(_ method: String, _ values: JSONDictionary = [:]) throws -> Any {
        let response = try call(method, values)
        XCTAssertNil(response["error"], "\(response)")
        return try XCTUnwrap(response["result"])
    }

    private func revision() throws -> String {
        (try result("project_info") as! JSONDictionary)["revision"] as! String
    }

    func testUnnamedUUIDLookupAndStrictSelectors() throws {
        let net = UUID().uuidString.lowercased()
        _ = try result("apply", ["expected_revision": revision(), "operation_id": UUID().uuidString,
                                  "ops": [["op": "ensure_net", "name": "temporary", "id": net], ["op": "rename_net", "net": net, "name": ""]]])
        let found = try result("get_net", ["id": net]) as! JSONDictionary
        XCTAssertEqual(found["name"] as? String, "")
        for params: JSONDictionary in [["name": "", "id": net], ["id": "bad"], [:]] {
            XCTAssertEqual((try call("get_net", params)["error"] as? JSONDictionary)?["code"] as? Int, -32602)
        }
    }

    func testMissingSheetIsNotAnEmptySheet() throws {
        XCTAssertEqual((try result("list_components", ["sheet": 1]) as? [Any])?.count, 0)
        let missing = try call("list_components", ["sheet": 999])
        XCTAssertEqual((missing["error"] as? JSONDictionary)?["code"] as? Int, -32001)
        XCTAssertEqual((((missing["error"] as? JSONDictionary)?["data"] as? JSONDictionary)?["code"] as? String), "NOT_FOUND")
        for params: JSONDictionary in [["sheet": "1"], ["sheet": true], ["shete": 1]] {
            XCTAssertNotNil(try call("list_components", params)["error"])
        }
        XCTAssertNotNil(try call("render_board", ["layers": ["imaginary copper"]])["error"])
    }

    func testOpeningAndReadingDoNotCreateTransactionFiles() throws {
        _ = try result("project_info")
        _ = try result("transaction_status", ["operation_id": "never-issued"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".horizontal-transactions").path))
    }

    func testRevisionConflictReceiptsAndFrozenReads() throws {
        let initial = try revision()
        let operation = UUID().uuidString
        let params: JSONDictionary = ["expected_revision": initial, "operation_id": operation, "ops": [["op": "ensure_net", "name": "first"]]]
        let frozen = try result("freeze_project") as! JSONDictionary
        let frozenHandle = frozen["handle"] as! Int
        defer { _ = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "close_project", "params": ["handle": frozenHandle]]) }
        let committed = try result("apply", params) as! JSONDictionary
        XCTAssertNotEqual(initial, try revision())
        XCTAssertEqual((try result("apply", params) as? JSONDictionary)?["operation_id"] as? String, operation)
        XCTAssertEqual((try result("transaction_status", ["operation_id": operation]) as? JSONDictionary)?["status"] as? String, "committed")
        let stale = try call("apply", ["expected_revision": initial, "operation_id": UUID().uuidString, "ops": [["op": "ensure_net", "name": "second"]]])
        XCTAssertEqual((stale["error"] as? JSONDictionary)?["code"] as? Int, -32003)
        let pinned = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 3, "method": "list_nets", "params": ["handle": frozenHandle]])
        XCTAssertEqual((pinned["result"] as? [Any])?.count, 0)
        XCTAssertNotNil(committed["after_snapshot_id"])
        let noRevision = try call("apply", ["operation_id": UUID().uuidString, "ops": [["op": "ensure_net", "name": "third"]]])
        XCTAssertEqual((noRevision["error"] as? JSONDictionary)?["code"] as? Int, -32602)
    }

    func testDryRunPlanAndExternalDiskChange() throws {
        let before = try HorizontalProjectArchive.snapshot(from: url)
        let base = try revision()
        let dry = try result("apply", ["expected_revision": base, "dry_run": true, "ops": [["op": "ensure_net", "name": "new"]]]) as! JSONDictionary
        XCTAssertEqual(before, try HorizontalProjectArchive.snapshot(from: url))
        _ = try result("apply", ["expected_revision": base, "operation_id": UUID().uuidString, "ops": dry["normalized_ops"]!, "plan_digest": dry["plan_digest"]!])
        let current = try revision()
        let blockURL = url.appendingPathComponent("top_block.json")
        var block = try JSONHelper.loadDictionary(from: blockURL)
        block["name"] = "external"
        try HorizontalHorizonJSONWriter.data(block).write(to: blockURL)
        let response = try call("apply", ["expected_revision": current, "operation_id": UUID().uuidString, "ops": [["op": "ensure_net", "name": "conflict"]]])
        XCTAssertEqual((response["error"] as? JSONDictionary)?["code"] as? Int, -32003)
        // Reads remain on the old snapshot until explicit reload.
        XCTAssertEqual(current, try revision())
    }

    func testElectricalNotation() {
        for (raw, refdes, value, unit) in [("4k7", "R1", 4700.0, "ohm"), ("100nF", "C1", 1e-7, "F"), ("2.2µF", "C1", 2.2e-6, "F"), ("0R", "R1", 0.0, "ohm"), ("1M", "R1", 1e6, "ohm")] {
            let parsed = HorizontalElectricalValue.parse(raw, refdes: refdes)
            XCTAssertEqual(parsed["status"] as? String, "parsed", raw)
            XCTAssertEqual(parsed["unit"] as? String, unit)
            XCTAssertEqual(parsed["value_si"] as? Double ?? -1, value, accuracy: max(1e-16, value * 1e-12))
        }
        XCTAssertEqual(HorizontalElectricalValue.parse("OPA1612", refdes: "U1")["status"] as? String, "unsupported")
        XCTAssertEqual(HorizontalElectricalValue.parse("10", refdes: "U1")["status"] as? String, "ambiguous")
    }

    /// How people actually write values: a space before the multiplier, either
    /// ohm sign, and the unit in whatever case it came out of a datasheet.
    func testSpacedAndSpelledUnits() {
        // U+03A9 GREEK CAPITAL OMEGA, then U+2126 OHM SIGN.
        for (raw, refdes, value, unit) in [("1 kΩ", "R18", 1000.0, "ohm"), ("1 k\u{2126}", "R18", 1000.0, "ohm"),
                                           ("1 k", "R1", 1000.0, "ohm"), ("100 nF", "C1", 1e-7, "F"),
                                           ("470 Ohms", "R1", 470.0, "ohm"), ("10 uF", "C1", 1e-5, "F"),
                                           ("4.7 mH", "L1", 4.7e-3, "H"), ("1 kΩ ±1%", "R1", 1000.0, "ohm")] {
            let parsed = HorizontalElectricalValue.parse(raw, refdes: refdes)
            XCTAssertEqual(parsed["status"] as? String, "parsed", raw)
            XCTAssertEqual(parsed["unit"] as? String, unit, raw)
            XCTAssertEqual(parsed["value_si"] as? Double ?? -1, value, accuracy: value * 1e-12, raw)
        }
        XCTAssertEqual(HorizontalElectricalValue.parse("1 kΩ ±1%", refdes: "R1")["tolerance_fraction"] as? Double, 0.01)
        // A separated number is still not a decimal point.
        XCTAssertEqual(HorizontalElectricalValue.parse("1 000", refdes: "R1")["status"] as? String, "unsupported")
    }

    /// A part that declares the quantity outright is evidence the notation
    /// does not have to repeat — and the result says where the number is from.
    func testDeclaredParametricValueBacksUpUnreadableNotation() {
        let declared = HorizontalElectricalValue.parse("1k0 5%", refdes: "R18", parametric: ["resistance": "1000"])
        XCTAssertEqual(declared["status"] as? String, "parsed")
        XCTAssertEqual(declared["value_si"] as? Double, 1000)
        XCTAssertEqual(declared["unit"] as? String, "ohm")
        XCTAssertEqual(declared["source"] as? String, "parametric")
        XCTAssertEqual(declared["parametric_key"] as? String, "resistance")

        // Notation that parses is the answer; the table does not override it.
        let text = HorizontalElectricalValue.parse("2k2", refdes: "R18", parametric: ["resistance": "1000"])
        XCTAssertEqual(text["value_si"] as? Double, 2200)
        XCTAssertEqual(text["source"] as? String, "text")

        // A capacitance does not answer for a resistor, and junk is not a number.
        XCTAssertEqual(HorizontalElectricalValue.parse("x", refdes: "R1", parametric: ["capacitance": "1e-7"])["status"] as? String, "unsupported")
        XCTAssertEqual(HorizontalElectricalValue.parse("x", refdes: "R1", parametric: ["resistance": "big"])["status"] as? String, "unsupported")
    }

    /// A project an editor has open cannot be written underneath it, and the
    /// refusal does not depend on the live channel being switched on: the
    /// holder record beside the project is what decides.
    func testDiskEditsRefuseWhileAnotherEditorHoldsTheProject() throws {
        XCTAssertEqual((try result("project_info") as! JSONDictionary)["editable"] as? Bool, true)

        // Another process's record: locked, so it counts as live, and carrying
        // a pid that is not ours, so it counts as somebody else.
        let holders = HorizontalProjectTransaction.transactionDirectory(url).appendingPathComponent("holders")
        try FileManager.default.createDirectory(at: holders, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let lock = holders.appendingPathComponent("\(id).lock")
        let record = holders.appendingPathComponent("\(id).json")
        try Data().write(to: lock)
        try JSONSerialization.data(withJSONObject: ["pid": Int(getpid()) + 1, "name": "Horizontal",
                                                    "project": url.path, "since": "2026-09-08T00:00:00Z"],
                                   options: [.sortedKeys]).write(to: record)
        let descriptor = Darwin.open(lock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }

        let edit: JSONDictionary = ["expected_revision": try revision(), "operation_id": UUID().uuidString,
                                    "ops": [["op": "ensure_net", "name": "VCC"]]]
        let refused = try XCTUnwrap(try call("apply", edit)["error"] as? JSONDictionary)
        XCTAssertEqual(refused["code"] as? Int, -32009)
        XCTAssertEqual((refused["data"] as? JSONDictionary)?["code"] as? String, "DOCUMENT_OPEN")
        XCTAssertTrue((refused["message"] as? String ?? "").contains("Horizontal"), "\(refused)")

        // A dry run still plans, and says what would block the commit.
        var planned = edit
        planned["dry_run"] = true
        let dry = try result("apply", planned) as! JSONDictionary
        XCTAssertEqual((dry["blocked_by"] as? [JSONDictionary])?.first?["name"] as? String, "Horizontal")

        let info = try result("project_info") as! JSONDictionary
        XCTAssertEqual(info["editable"] as? Bool, false)
        XCTAssertEqual((info["held_by"] as? [JSONDictionary])?.count, 1)

        // Once the editor lets go, the same edit commits.
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        var retried = edit
        retried["expected_revision"] = try revision()
        _ = try result("apply", retried)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path), "a released record is forgotten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }
}
