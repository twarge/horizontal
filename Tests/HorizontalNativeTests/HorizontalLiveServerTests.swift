import Foundation
import HorizontalProjectIO
import Network
import XCTest
@testable import HorizontalNative

/// The live channel end to end inside one process: a document registered the
/// way the workspace view registers it, the loopback listener it starts, and
/// a client speaking newline JSON-RPC with the token from the discovery file.
@MainActor
final class HorizontalLiveServerTests: XCTestCase {
    private var packageURL: URL!
    private var handle: Int?
    private var applied: [(HorizontalProjectArchive, String)] = []

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-live-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
    }

    override func tearDown() async throws {
        if let handle {
            HorizontalDispatchSession.shared.unregisterLive(handle: handle)
        }
    }

    private func registerTemplateDocument() throws -> HorizontalLiveDocument {
        let project = try HorizontalProject.load(from: packageURL)
        let archive = try HorizontalProjectArchive.snapshot(from: packageURL)
        let document = HorizontalLiveDocument(url: packageURL, title: "Live test", project: project, archive: archive)
        var revision = 0
        var current = project
        var currentArchive = archive
        document.currentProject = { current }
        document.revision = { revision }
        document.archive = { currentArchive }
        document.applyArchive = { [weak self] edited, name in
            self?.applied.append((edited, name))
            currentArchive = edited
            current = try HorizontalProject.loadSnapshot(of: edited)
            revision += 1
        }
        var selection = HorizontalLiveSelection(panes: ["board"])
        document.selection = { selection }
        document.setHighlight = { nets, components in
            selection.highlightedNetIDs = nets
            selection.highlightedComponentIDs = components
        }
        handle = HorizontalDispatchSession.shared.registerLive(document)
        return document
    }

    private func discovery() throws -> (port: UInt16, token: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let port = HorizontalLiveServer.port, let token = HorizontalLiveServer.token {
                return (port, token)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        throw XCTSkip("The live listener did not come up (network server entitlement or sandbox).")
    }

    /// One request over a fresh loopback connection, answered on the main
    /// actor while this test's run loop keeps turning.
    private func send(_ request: [String: Any], port: UInt16, token: String?) throws -> [String: Any] {
        var request = request
        if let token {
            request["auth"] = token
        }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self) + "\n"
        let client = LiveClient(port: port)
        client.send(line)
        let deadline = Date().addingTimeInterval(10)
        while client.response == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let response = try XCTUnwrap(client.response, "no response within 10 s")
        client.cancel()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func testListenerAnswersWithTheTokenAndRefusesWithout() throws {
        _ = try registerTemplateDocument()
        let (port, token) = try discovery()

        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: HorizontalLiveServer.discoveryURL)) as? [String: Any]
        XCTAssertEqual(file?["port"] as? Int, Int(port))
        XCTAssertEqual(file?["token"] as? String, token)

        let refused = try send(["jsonrpc": "2.0", "id": 1, "method": "version", "params": [:]], port: port, token: "wrong")
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32001)

        let version = try send(["jsonrpc": "2.0", "id": 2, "method": "version", "params": [:]], port: port, token: token)
        XCTAssertEqual((version["result"] as? [String: Any])?["api"] as? Int, HorizontalDispatch.apiVersion)
    }

    func testLiveDocumentIsListedReadHighlightedAndEdited() throws {
        let document = try registerTemplateDocument()
        let (port, token) = try discovery()

        let state = try send(["jsonrpc": "2.0", "id": 1, "method": "live_state", "params": [:]], port: port, token: token)
        let documents = try XCTUnwrap(state["result"] as? [[String: Any]])
        let mine = try XCTUnwrap(documents.first { $0["handle"] as? Int == handle })
        XCTAssertEqual(mine["live"] as? Bool, true)
        XCTAssertEqual(mine["title"] as? String, "Untitled", "the summary carries the project's own display title")
        XCTAssertEqual((mine["selection"] as? [String: Any])?["panes"] as? [String], ["board"])

        // Opening the same path through the channel returns the live handle.
        let opened = try send(["jsonrpc": "2.0", "id": 2, "method": "open_project", "params": ["path": packageURL.path]], port: port, token: token)
        XCTAssertEqual((opened["result"] as? [String: Any])?["handle"] as? Int, handle)

        let edited = try send(["jsonrpc": "2.0", "id": 3, "method": "apply", "params": ["handle": handle!, "ops": [["op": "ensure_net", "name": "VCC"]]]], port: port, token: token)
        let result = try XCTUnwrap(edited["result"] as? [String: Any], "\(edited)")
        XCTAssertEqual(result["live"] as? Bool, true)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.1, "Apply 1 Edit")
        XCTAssertEqual(try XCTUnwrap(document.archive().regularFileData(relativePath: "top_block.json")).count > 0, true)

        let nets = try send(["jsonrpc": "2.0", "id": 4, "method": "list_nets", "params": ["handle": handle!]], port: port, token: token)
        XCTAssertEqual((nets["result"] as? [[String: Any]])?.map { $0["name"] as? String }, ["VCC"], "the live entry re-reads the document after the edit")

        let highlighted = try send(["jsonrpc": "2.0", "id": 5, "method": "highlight", "params": ["handle": handle!, "nets": ["VCC"]]], port: port, token: token)
        XCTAssertEqual((highlighted["result"] as? [String: Any])?["highlighted_nets"] as? [String], ["VCC"])
        XCTAssertEqual(document.selection().highlightedNetIDs.count, 1)

        let missing = try send(["jsonrpc": "2.0", "id": 6, "method": "highlight", "params": ["handle": handle!, "nets": ["nope"]]], port: port, token: token)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32001)
    }
}

/// A minimal loopback client on Network.framework for the tests above.
private final class LiveClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "live-client-test")
    private var buffer = Data()
    private(set) var response: String?

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
        receive()
    }

    func send(_ line: String) {
        connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data {
                buffer.append(data)
                if let newline = buffer.firstIndex(of: 0x0A) {
                    response = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8)
                    return
                }
            }
            if !isComplete, error == nil {
                receive()
            }
        }
    }
}
