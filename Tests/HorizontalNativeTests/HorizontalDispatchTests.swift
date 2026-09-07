import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The JSON-RPC dispatch layer, driven the way the Python package and the
/// command line tool drive it: JSON text in, JSON text out, against the
/// new-document template written to disk.
final class HorizontalDispatchTests: XCTestCase {
    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        var params = params
        if method == "pool_write", let handle = params["handle"] as? Int {
            params["expected_revision"] = try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
            params["operation_id"] = UUID().uuidString
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let responseJSON = HorizontalDispatch.call(requestJSON)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any])
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        return response
    }

    private func result(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        let response = try call(method, params)
        if let error = response["error"] as? [String: Any] {
            XCTFail("\(method) failed: \(error["message"] ?? error)")
        }
        return try XCTUnwrap(response["result"])
    }

    private func writtenTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-dispatch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }

    private func openTemplate() throws -> Int {
        let summary = try XCTUnwrap(try result("open_project", ["path": try writtenTemplate().path]) as? [String: Any])
        let handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }
        return handle
    }

    func testMalformedRequestsComeBackAsJSONRPCErrors() throws {
        let notJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HorizontalDispatch.call("nope").utf8)) as? [String: Any])
        XCTAssertEqual((notJSON["error"] as? [String: Any])?["code"] as? Int, -32700)

        let noMethod = try call("", [:])
        XCTAssertNotNil(noMethod["error"])

        let unknown = try call("no_such_method")
        let error = try XCTUnwrap(unknown["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        let known = try XCTUnwrap((error["data"] as? [String: Any])?["methods"] as? [String])
        XCTAssertTrue(known.contains("open_project"))

        let missingHandle = try call("list_sheets")
        XCTAssertEqual((missingHandle["error"] as? [String: Any])?["code"] as? Int, -32602)

        let badHandle = try call("list_sheets", ["handle": 999_999])
        XCTAssertEqual((badHandle["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    func testMethodsListsEveryRegisteredMethod() throws {
        let methods = try XCTUnwrap(try result("methods") as? [[String: Any]])
        let names = methods.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), Set(HorizontalDispatchMethods.all.map(\.name)))
        for method in methods {
            XCTAssertFalse((method["summary"] as? String ?? "").isEmpty, "\(method["name"] ?? "") has no summary")
        }
    }

    func testOpeningTheTemplateDescribesAnEmptyBoardAndOneSheet() throws {
        let handle = try openTemplate()
        let summary = try XCTUnwrap(try result("project_info", ["handle": handle]) as? [String: Any])
        XCTAssertEqual(summary["has_board"] as? Bool, true)
        XCTAssertEqual(summary["component_count"] as? Int, 0)
        XCTAssertEqual((summary["diagnostics"] as? [String]) ?? ["missing"], [])

        let sheets = try XCTUnwrap(try result("list_sheets", ["handle": handle]) as? [[String: Any]])
        XCTAssertEqual(sheets.map { $0["name"] as? String }, ["Sheet 1"])

        XCTAssertEqual((try result("list_components", ["handle": handle]) as? [Any])?.count, 0)
        XCTAssertEqual((try result("list_nets", ["handle": handle]) as? [Any])?.count, 0)

        let bom = try XCTUnwrap(try result("bom", ["handle": handle]) as? [String: Any])
        XCTAssertEqual(bom["line_count"] as? Int, 0)

        let board = try XCTUnwrap(try result("board_info", ["handle": handle]) as? [String: Any])
        let stackup = try XCTUnwrap(board["stackup"] as? [[String: Any]])
        XCTAssertEqual(stackup.compactMap { $0["layer"] as? Int }, [0, -100])
    }

    func testOpeningTheSamePathTwiceReusesTheHandle() throws {
        let url = try writtenTemplate()
        let first = try XCTUnwrap(try result("open_project", ["path": url.path]) as? [String: Any])
        let second = try XCTUnwrap(try result("open_project", ["path": url.path]) as? [String: Any])
        XCTAssertEqual(first["handle"] as? Int, second["handle"] as? Int)
        let handle = try XCTUnwrap(first["handle"] as? Int)
        _ = try result("close_project", ["handle": handle])
        let closed = try call("project_info", ["handle": handle])
        XCTAssertNotNil(closed["error"])
    }

    func testCheckOnTheTemplatePasses() throws {
        let handle = try openTemplate()
        let check = try XCTUnwrap(try result("check", ["handle": handle]) as? [String: Any])
        XCTAssertEqual(check["ok"] as? Bool, true)
        let counts = try XCTUnwrap(check["counts"] as? [String: Int])
        XCTAssertEqual(counts["error"], 0)
    }

    func testRenderingTheFirstSheetProducesAPNG() throws {
        let handle = try openTemplate()
        let render = try XCTUnwrap(try result("render_sheet", ["handle": handle, "dpi": 40]) as? [String: Any])
        XCTAssertEqual(render["format"] as? String, "png")
        let width = try XCTUnwrap(render["width"] as? Int)
        let height = try XCTUnwrap(render["height"] as? Int)
        XCTAssertGreaterThan(width, 10)
        XCTAssertGreaterThan(height, 10)
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(render["png_base64"] as? String)))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-dispatch-\(UUID().uuidString).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        let written = try XCTUnwrap(try result("render_board", ["handle": handle, "dpi": 40, "output_path": output.path]) as? [String: Any])
        XCTAssertEqual(written["path"] as? String, output.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testNewProjectWritesATemplatePackageAndPoolWriteAddsItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-dispatch-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let refused = try call("new_project", ["path": root.appendingPathComponent("Nope.hprj").path])
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32602)

        let packageURL = root.appendingPathComponent("Fresh.horizontal")
        let summary = try XCTUnwrap(try result("new_project", ["path": packageURL.path, "name": "Fresh"]) as? [String: Any])
        let handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }
        XCTAssertEqual(summary["has_board"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("pool/pool.json").path))

        let unitID = "6f1d0d3a-1111-4a5b-9c1e-000000000001"
        let pinID = "6f1d0d3a-1111-4a5b-9c1e-000000000002"
        let unit: [String: Any] = [
            "type": "unit", "uuid": unitID, "name": "Thing", "manufacturer": "",
            "pins": [pinID: ["primary_name": "A", "direction": "passive", "names": [], "swap_group": 0]]
        ]
        let written = try XCTUnwrap(try result("pool_write", ["handle": handle, "items": [unit]]) as? [String: Any])
        XCTAssertEqual((written["written"] as? [String])?.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("pool/units/cache/\(unitID).json").path))
        let again = try XCTUnwrap(try result("pool_write", ["handle": handle, "items": [unit]]) as? [String: Any])
        XCTAssertEqual(again["skipped"] as? Int, 1, "identical bytes are not rewritten")

        let bad = try call("pool_write", ["handle": handle, "items": [["type": "gizmo", "uuid": unitID]]])
        XCTAssertEqual((bad["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testExportRefusesADirectoryInsideTheProjectAndWritesOutsideIt() throws {
        let url = try writtenTemplate()
        let summary = try XCTUnwrap(try result("open_project", ["path": url.path]) as? [String: Any])
        let handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }

        let inside = try call("export", ["handle": handle, "sections": ["bom"], "target_directory": url.appendingPathComponent("out").path])
        XCTAssertNotNil(inside["error"], "an export inside the package must be refused")

        let outside = url.deletingLastPathComponent().appendingPathComponent("exports")
        let exported = try XCTUnwrap(try result("export", ["handle": handle, "sections": ["bom", "schematic_pdf"], "target_directory": outside.path]) as? [String: Any])
        XCTAssertEqual(exported["status"] as? String, "success", "\(exported["message"] ?? "")")
        let files = try XCTUnwrap(exported["files"] as? [String])
        XCTAssertTrue(files.contains { $0.hasSuffix(".csv") }, "\(files)")
        XCTAssertTrue(files.contains { $0.hasSuffix(".pdf") }, "\(files)")

        let unknown = try call("export", ["handle": handle, "sections": ["napkin"]])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
    }
}
