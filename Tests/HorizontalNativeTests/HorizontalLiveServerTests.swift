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
        // The channel ships off; this suite is about what it does once on.
        // Without this the listener never comes up and every test here skips.
        let enabledKey = HorizontalLiveServer.enabledDefaultsKey
        UserDefaults.standard.set(true, forKey: enabledKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: enabledKey) }

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
        document.revision = { String(revision) }
        document.archive = { currentArchive }
        document.applyArchive = { [weak self] edited, name in
            self?.applied.append((edited, name))
            currentArchive = edited
            current = try HorizontalDispatchSession.project(from: HorizontalDispatchSnapshot(archive: edited, baseURL: project.baseURL), url: project.url)
            revision += 1
        }
        var selection = HorizontalLiveSelection(panes: ["board"])
        document.selection = { selection }
        document.setHighlight = { nets, components in
            selection.highlightedNetIDs = nets
            selection.highlightedComponentIDs = components
        }
        document.setPanes = { panes in
            selection.panes = panes.map(\.rawValue).sorted()
        }
        handle = HorizontalDispatchSession.shared.registerLive(document)
        return document
    }

    func testTheChannelIsOffUntilItIsTurnedOn() throws {
        let suite = "horizontal-live-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertFalse(HorizontalLiveServer.isEnabled(defaults: defaults))
        defaults.set(true, forKey: HorizontalLiveServer.enabledDefaultsKey)
        XCTAssertTrue(HorizontalLiveServer.isEnabled(defaults: defaults))
        XCTAssertTrue(HorizontalAppearanceSettings(defaults: defaults).isLiveServerEnabled)
    }

    func testUnsavedPoolAndBlockReadsStayOnTheirCapturedRevision() throws {
        let document = try registerTemplateDocument()
        let diskSession = HorizontalDispatchSession()
        let disk = try diskSession.open(url: packageURL)
        var unit = HorizontalPoolItemFactory.newUnit()
        let pinID = UUID().uuidString.lowercased()
        unit.pins = [pinID: HorizontalUnitPin(id: pinID, primaryName: "LIVE_PIN")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let current = try HorizontalDispatchSession.shared.entry(handle: handle!)
        let edited = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
            "handle": handle!, "expected_revision": current.revision, "operation_id": UUID().uuidString,
            "pool_items": [unit.json(), entity.json()],
            "ops": [["op": "ensure_component", "refdes": "R1", "entity": entity.uuid, "value": "4k7"]]
        ]])
        XCTAssertNil(edited["error"], "\(edited)")
        let request: JSONDictionary = ["jsonrpc": "2.0", "id": 2, "method": "get_component", "auth": "test-token", "params": ["handle": handle!, "refdes": "R1", "include_metadata": true]]
        let prepared = try XCTUnwrap(HorizontalLiveServer.prepareRead(line: HorizontalDispatch.serialize(request, pretty: false), expectedToken: "test-token"))
        let capturedRevision = current.revision
        var updated = document.archive()
        unit.pins[pinID]?.primaryName = "LATER_PIN"
        try updated.replaceRegularFileData(relativePath: "pool/units/cache/\(unit.uuid).json", with: HorizontalHorizonJSONWriter.data(unit.json()))
        try document.applyArchive(updated, "Change pin")
        HorizontalDispatchSession.shared.syncLiveEntries()
        XCTAssertNotEqual(current.revision, capturedRevision)
        let response = try JSONHelper.loadDictionary(from: Data(prepared().utf8))
        let envelope = try XCTUnwrap(response.dictionary("result"))
        let component = try XCTUnwrap(envelope.dictionary("data"))
        XCTAssertEqual(component.dictionaryArray("pins").first?.string("pin"), "LIVE_PIN")
        XCTAssertEqual(component.dictionary("electrical_value")?.double("value_si"), 4700)
        XCTAssertEqual(envelope.dictionary("meta")?.string("revision"), capturedRevision)
        XCTAssertEqual(envelope.dictionary("meta")?.string("source"), "live")
        XCTAssertEqual(disk.index.components.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("pool/units/cache/\(unit.uuid).json").path))
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
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32008)

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

        let edited = try send(["jsonrpc": "2.0", "id": 3, "method": "apply", "params": ["handle": handle!, "expected_revision": mine["revision"]!, "operation_id": UUID().uuidString, "ops": [["op": "ensure_net", "name": "VCC"]]]], port: port, token: token)
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


    /// An edit through this channel is one undo step in the app and nothing
    /// more until the document is written. `save` is what writes it, and the
    /// summary says whether anything is outstanding.
    func testSaveWritesTheDocumentAndReportsWhatWasOutstanding() throws {
        let document = try registerTemplateDocument()
        var saves = 0
        var edited = false
        document.isEdited = { edited }
        document.save = { saves += 1; edited = false }

        let handle = try XCTUnwrap(self.handle)
        func summary() throws -> JSONDictionary {
            let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "project_info", "params": ["handle": handle]])
            return try XCTUnwrap(response["result"] as? JSONDictionary)
        }
        func save() throws -> JSONDictionary {
            let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "save", "params": ["handle": handle]])
            XCTAssertNil(response["error"], "\(response)")
            return try XCTUnwrap(response["result"] as? JSONDictionary)
        }

        XCTAssertEqual(try summary()["unsaved_changes"] as? Bool, false)
        edited = true
        XCTAssertEqual(try summary()["unsaved_changes"] as? Bool, true)

        let saved = try save()
        XCTAssertEqual(saved["saved"] as? Bool, true)
        XCTAssertEqual(saved["had_unsaved_changes"] as? Bool, true)
        XCTAssertEqual(saved["source"] as? String, "live")
        XCTAssertEqual(saved["verified"] as? Bool, true, "the file is checked, not the document's own flag")
        XCTAssertEqual(saved["path"] as? String, packageURL.path)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try summary()["unsaved_changes"] as? Bool, false)

        // Saving a document with nothing outstanding is not an error, and
        // says nothing was written.
        XCTAssertEqual(try save()["saved"] as? Bool, false)
        XCTAssertEqual(saves, 2)


        document.isReadOnly = { true }
        edited = true
        let refused = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 3, "method": "save", "params": ["handle": handle]])
        XCTAssertEqual((refused["error"] as? JSONDictionary)?["code"] as? Int, -32007)
        XCTAssertEqual(saves, 2, "a read-only document is never written")

        // A save that leaves the file disagreeing with the document is the
        // failure this whole path exists to catch, and it is reported rather
        // than dressed up as success.
        document.isReadOnly = { false }
        document.save = { }  // says it saved; writes nothing
        var stale = document.archive()
        try stale.replaceRegularFileData(relativePath: "top_block.json",
                                         with: Data(#"{"type":"block","uuid":"x","nets":{}}"#.utf8))
        try document.applyArchive(stale, "Diverge")
        HorizontalDispatchSession.shared.syncLiveEntries()
        let unverified = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 4, "method": "save", "params": ["handle": handle]])
        let error = try XCTUnwrap(unverified["error"] as? JSONDictionary)
        XCTAssertTrue((error["message"] as? String ?? "").contains("still does not match"), "\(error)")
    }

    /// Undo through the channel drives the document's own stack — the one the
    /// Edit menu drives — so an edit made here and one made by hand undo alike.
    /// `show_panes` says which panes to show and hides the rest — the one
    /// thing `frame` and `show_sheet` could only do as a side effect of going
    /// somewhere. It is what the app's Siri shortcut runs, so it has to answer
    /// with what is showing now.
    func testShowPanesSaysWhichPanesAreUp() throws {
        _ = try registerTemplateDocument()
        let handle = try XCTUnwrap(self.handle)
        func call(_ panes: Any) -> JSONDictionary {
            HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "show_panes",
                                     "params": ["handle": handle, "panes": panes]])
        }

        let both = try XCTUnwrap(call(["schematic", "board"])["result"] as? JSONDictionary)
        XCTAssertEqual(both["panes"] as? [String], ["board", "schematic"])

        // Showing one hides the other: this replaces what is up rather than
        // adding to it, which is what "show me the board" means.
        let board = try XCTUnwrap(call(["board"])["result"] as? JSONDictionary)
        XCTAssertEqual(board["panes"] as? [String], ["board"])

        // A pane can be named the way the app titles it, since that is what a
        // person says.
        XCTAssertEqual((try XCTUnwrap(call(["Schematic"])["result"] as? JSONDictionary))["panes"] as? [String],
                       ["schematic"])

        // Nothing to show is a request with no meaning, and an unknown pane
        // names the ones there are rather than doing nothing quietly.
        XCTAssertNotNil(call([String]())["error"])
        let unknown = try XCTUnwrap(call(["gerber"])["error"] as? JSONDictionary)
        XCTAssertTrue((unknown["message"] as? String ?? "").contains("schematic"), unknown["message"] as? String ?? "")
    }

    func testUndoDrivesTheDocumentsOwnStack() throws {
        let document = try registerTemplateDocument()
        var stack = ["Apply 1 Edit"]
        var redoStack = [String]()
        document.undoActionName = { stack.last }
        document.redoActionName = { redoStack.last }
        document.undo = {
            guard let name = stack.popLast() else { return nil }
            redoStack.append(name)
            return name
        }
        document.redo = {
            guard let name = redoStack.popLast() else { return nil }
            stack.append(name)
            return name
        }
        let handle = try XCTUnwrap(self.handle)
        func call(_ params: JSONDictionary) -> JSONDictionary {
            HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "undo", "params": params])
        }

        // The summary says what is on top, so a caller can tell whether its own
        // edit is still there before reaching for undo.
        let info = try XCTUnwrap((HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "project_info",
                                                            "params": ["handle": handle]])["result"]) as? JSONDictionary)
        XCTAssertEqual(info["can_undo"] as? String, "Apply 1 Edit")
        XCTAssertNil(info["can_redo"] as? String)

        let undone = try XCTUnwrap(call(["handle": handle])["result"] as? JSONDictionary)
        XCTAssertEqual(undone["undone"] as? String, "Apply 1 Edit")
        XCTAssertEqual(undone["can_redo"] as? String, "Apply 1 Edit")
        XCTAssertNil(undone["can_undo"] as? String)

        // Nothing left to undo is said rather than reported as a success.
        let empty = try XCTUnwrap(call(["handle": handle])["error"] as? JSONDictionary)
        XCTAssertTrue((empty["message"] as? String ?? "").contains("nothing to undo"), "\(empty)")

        let redone = try XCTUnwrap(call(["handle": handle, "redo": true])["result"] as? JSONDictionary)
        XCTAssertEqual(redone["redone"] as? String, "Apply 1 Edit")
        XCTAssertNil(redone["undone"] as? String)
        XCTAssertNotNil(try XCTUnwrap(call(["handle": handle, "redo": true])["error"]))
    }

    /// A disk context has nothing held back: its edits committed with their
    /// transaction. Saying so beats an error a caller has to special-case.
    /// A disk edit is a committed transaction, not a step on a stack, so undo
    /// says what to do instead rather than pretending.
    func testUndoingADiskContextExplainsItself() throws {
        let session = HorizontalDispatchSession()
        let entry = try session.open(url: packageURL)
        XCTAssertThrowsError(try HorizontalDispatchMethods.handler(named: "undo")?(session, ["handle": entry.handle])) { error in
            let message = (error as? HorizontalDispatchError)?.message ?? ""
            XCTAssertTrue(message.contains("no undo stack"), message)
            XCTAssertTrue(message.contains("inverse"), message)
        }
    }

    func testSavingADiskContextIsNotAnError() throws {
        let session = HorizontalDispatchSession()
        let entry = try session.open(url: packageURL)
        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "save", "params": ["handle": entry.handle]])
        // The shared dispatcher owns handles, so drive the method directly.
        _ = response
        let result = try XCTUnwrap(try HorizontalDispatchMethods.handler(named: "save")?(session, ["handle": entry.handle]) as? JSONDictionary)
        XCTAssertEqual(result["saved"] as? Bool, false)
        XCTAssertEqual(result["source"] as? String, "disk")
        XCTAssertNotNil(result["note"])
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
