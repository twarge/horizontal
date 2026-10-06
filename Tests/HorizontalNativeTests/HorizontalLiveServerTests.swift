import CoreGraphics
import Foundation
import HorizontalProjectIO
import ImageIO
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

    /// A live commit hands the app the project it loaded to validate the edit,
    /// leaves the next commit's diagnostics cached, and records a failure so
    /// a client that lost the reply can be told it did not commit.
    func testLiveCommitsReuseTheirLoadAndRecordFailures() throws {
        let document = try registerTemplateDocument()
        var handed: [HorizontalProject] = []
        let fallback = document.applyArchive
        document.applyLoadedArchive = { archive, loaded, name in
            handed.append(loaded)
            try fallback(archive, name)
        }
        let entry = try HorizontalDispatchSession.shared.entry(handle: handle!)
        func apply(_ ops: [JSONDictionary], id: String = UUID().uuidString) -> JSONDictionary {
            HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
                "handle": handle!, "expected_revision": entry.revision, "operation_id": id, "detail": "compact", "ops": ops]])
        }
        XCTAssertNil(apply([["op": "ensure_net", "name": "A"]])["error"])
        XCTAssertEqual(handed.count, 1)
        let reloaded = try HorizontalProject.loadSnapshot(of: document.archive())
        XCTAssertEqual(handed[0].schematics.count, reloaded.schematics.count)
        XCTAssertEqual(handed[0].diagnostics.map(\.message).count, reloaded.diagnostics.map(\.message).count)
        // The document's archive comes back byte for byte, so the snapshot the
        // next commit starts from is the one whose diagnostics are cached.
        XCTAssertEqual(entry.cachedDiagnostics?.snapshotID, entry.snapshot?.id)

        let failedID = UUID().uuidString
        XCTAssertNotNil(apply([["op": "set_value", "component": "NOPE", "value": "1"]], id: failedID)["error"])
        let status = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "transaction_status",
                                              "params": ["handle": handle!, "operation_id": failedID]])
        XCTAssertEqual((status["result"] as? JSONDictionary)?.string("status"), "not_committed")
        XCTAssertEqual(handed.count, 1, "nothing was applied for the failure")
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
        XCTAssertEqual((saved["leftovers"] as? [JSONDictionary])?.count, 0,
                       "an empty list, not a missing key, says the folder was looked at and held none")
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

    /// Billo's 17:04 save left Billo.hprj.sb-ec53240b-ZysDK4 beside the project
    /// file and nothing said so. A save now names any it finds, and leaves it.
    func testASaveNamesASafeSaveLeftoverAndLeavesIt() throws {
        let document = try registerTemplateDocument()
        var edited = true
        document.isEdited = { edited }
        let leftover = packageURL.deletingLastPathComponent()
            .appendingPathComponent(packageURL.lastPathComponent + ".sb-ec53240b-ZysDK4")
        document.save = { edited = false; try? Data("moved aside".utf8).write(to: leftover) }
        let handle = try XCTUnwrap(self.handle)
        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "save", "params": ["handle": handle]])
        let saved = try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)")
        XCTAssertEqual(saved["verified"] as? Bool, true)
        XCTAssertEqual((saved["leftovers"] as? [JSONDictionary])?.map { $0.string("name") }, [leftover.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path), "reported, not deleted")
    }

    /// Field notes item 29: render_viewport drew in the exporter's style, which
    /// has no airwires, so whether the canvas drew the ones check reports could
    /// only be judged by eye. It now draws the canvas's own over the render and
    /// says how they compare with check's; board_info says whose its count is.
    func testRenderViewportDrawsTheCanvasAirwiresAndComparesThemWithCheck() throws {
        let document = try registerTemplateDocument()
        let handle = try XCTUnwrap(self.handle)
        let mm = 1_000_000.0
        let region = HorizontalRect(points: [HorizontalPoint(x: -20 * mm, y: -20 * mm), HorizontalPoint(x: 20 * mm, y: 20 * mm)])
        document.visibleBounds = { $0 == .board ? region : nil }
        func call(_ method: String, _ params: JSONDictionary = [:]) throws -> JSONDictionary {
            let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": method,
                                                    "params": params.merging(["handle": handle]) { $1 }])
            return try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)")
        }

        // No board pane: the airwires drawn are check's, and board_info says
        // there is no canvas to ask.
        let unseen = try XCTUnwrap(try call("render_viewport", ["dpi": 20]).dictionary("airwires"))
        XCTAssertEqual(unseen.string("source"), "connectivity")
        XCTAssertEqual(unseen.int("count"), 0)
        let noCanvas = try XCTUnwrap(try call("board_info").dictionary("airwires"))
        XCTAssertEqual(noCanvas.string("source"), "connectivity")
        XCTAssertTrue(noCanvas["canvas"] is NSNull, "\(noCanvas)")

        // A canvas drawing what check reports — none, on the template — agrees.
        document.drawnAirwires = { HorizontalDrawnAirwires(airwires: [], shown: true) }
        let agreed = try XCTUnwrap(try call("board_info").dictionary("airwires")?.dictionary("canvas"))
        XCTAssertEqual(agreed["matches_check"] as? Bool, true)
        XCTAssertEqual(agreed.int("count"), 0)

        // A canvas drawing one check doesn't report — a stale scene — is named
        // net by net, and drawn across the middle of the render.
        let stale = HorizontalSegment(id: "a1", from: HorizontalPoint(x: -15 * mm, y: 0), to: HorizontalPoint(x: 15 * mm, y: 0),
                                      width: 0, layer: nil)
        document.drawnAirwires = { HorizontalDrawnAirwires(airwires: [stale], shown: true) }
        let rendered = try call("render_viewport", ["dpi": 40])
        let airwires = try XCTUnwrap(rendered.dictionary("airwires"))
        XCTAssertEqual(airwires.string("source"), "canvas")
        XCTAssertEqual(airwires["matches_check"] as? Bool, false)
        XCTAssertEqual(airwires["shown"] as? Bool, true)
        XCTAssertEqual(airwires.int("in_view"), 1, "a straight one counts though its box is flat")
        let difference = try XCTUnwrap((airwires["differences"] as? [JSONDictionary])?.first)
        XCTAssertEqual(difference.int("canvas"), 1)
        XCTAssertEqual(difference.int("check"), 0)
        XCTAssertEqual(difference.int("only_canvas"), 1)
        XCTAssertGreaterThan(try airwirePixels(rendered), 10)

        let bare = try call("render_viewport", ["dpi": 40, "airwires": false])
        XCTAssertEqual(bare.dictionary("airwires")?["drawn"] as? Bool, false)
        XCTAssertEqual(try airwirePixels(bare), 0, "the exporter itself draws none")

        // The same airwire the other way round is the same airwire.
        let reversed = HorizontalSegment(id: "a2", from: stale.to, to: stale.from, width: 0, layer: nil)
        let index = try HorizontalDispatchSession.shared.entry(for: ["handle": handle]).index
        let same = HorizontalDispatchMethods.canvasAirwiresJSON(HorizontalDrawnAirwires(airwires: [reversed], shown: true),
                                                                reported: [stale], index: index)
        XCTAssertEqual(same["matches_check"] as? Bool, true, "\(same)")
    }

    /// Field notes item 34: board_info is one of the reads the live channel
    /// answers off the main actor, from a detached copy with no live document,
    /// so it never gave the canvas's airwires. The copy now takes them along.
    func testBoardInfoReadOffTheMainActorGivesTheCanvasAirwires() throws {
        let document = try registerTemplateDocument()
        let handle = try XCTUnwrap(self.handle)
        let mm = 1_000_000.0
        let stale = HorizontalSegment(id: "a1", from: HorizontalPoint(x: -15 * mm, y: 0), to: HorizontalPoint(x: 15 * mm, y: 0),
                                      width: 0, layer: nil)
        func boardInfo() throws -> JSONDictionary {
            let request: JSONDictionary = ["jsonrpc": "2.0", "id": 1, "method": "board_info", "auth": "test-token", "params": ["handle": handle]]
            let prepared = try XCTUnwrap(HorizontalLiveServer.prepareRead(line: HorizontalDispatch.serialize(request, pretty: false),
                                                                          expectedToken: "test-token"), "board_info takes the off-main path")
            let response = try JSONHelper.loadDictionary(from: Data(prepared().utf8))
            return try XCTUnwrap(response.dictionary("result")?.dictionary("airwires"), "\(response)")
        }

        let hidden = try boardInfo()
        XCTAssertTrue(hidden["canvas"] is NSNull, "a live document with no board pane says so: \(hidden)")
        XCTAssertFalse(hidden.string("note")?.contains("over the files") ?? true)

        document.drawnAirwires = { HorizontalDrawnAirwires(airwires: [stale], shown: true) }
        let canvas = try XCTUnwrap(try boardInfo().dictionary("canvas"))
        XCTAssertEqual(canvas.int("count"), 1)
        XCTAssertEqual(canvas["matches_check"] as? Bool, false)
    }

    /// Field notes items 36 and 37: with the Connections switch off the pane
    /// draws no airwires, so neither does its render unless asked; and a part
    /// of what the pane shows can be rendered, in more detail than the whole.
    func testRenderViewportFollowsTheConnectionsSwitchAndRendersARegion() throws {
        let document = try registerTemplateDocument()
        let handle = try XCTUnwrap(self.handle)
        let mm = 1_000_000.0
        let view = HorizontalRect(points: [HorizontalPoint(x: -20 * mm, y: -20 * mm), HorizontalPoint(x: 20 * mm, y: 20 * mm)])
        document.visibleBounds = { $0 == .board ? view : nil }
        let across = HorizontalSegment(id: "a1", from: HorizontalPoint(x: -15 * mm, y: 0), to: HorizontalPoint(x: 15 * mm, y: 0),
                                       width: 0, layer: nil)
        document.drawnAirwires = { HorizontalDrawnAirwires(airwires: [across], shown: false) }
        func call(_ params: JSONDictionary) throws -> JSONDictionary {
            let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "render_viewport",
                                                    "params": params.merging(["handle": handle]) { $1 }])
            return try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)")
        }

        let off = try call(["dpi": 40])
        XCTAssertEqual(off.dictionary("airwires")?["shown"] as? Bool, false)
        XCTAssertEqual(off.dictionary("airwires")?["drawn"] as? Bool, false)
        XCTAssertEqual(try airwirePixels(off), 0, "the switch is off, so the render draws none")
        let forced = try call(["dpi": 40, "airwires": true])
        XCTAssertEqual(forced.dictionary("airwires")?["drawn"] as? Bool, true)
        XCTAssertGreaterThan(try airwirePixels(forced), 10)

        // A part of the view, asked for past its top edge: clipped to the view,
        // and drawn as large as the whole.
        let whole = try call(["dpi": 40, "airwires": false])
        let part = try call(["dpi": 40, "airwires": false,
                             "region": ["min_x_mm": -10, "min_y_mm": -10, "max_x_mm": 10, "max_y_mm": 30]])
        XCTAssertEqual(part.dictionary("region")?.double("max_y_mm"), 20)
        XCTAssertEqual(part.dictionary("view")?.double("max_y_mm"), 20)
        let wholeDetail = try XCTUnwrap(whole.double("px_per_mm")), partDetail = try XCTUnwrap(part.double("px_per_mm"))
        // 30 mm tall where the view is 40, so 4/3 the detail.
        XCTAssertEqual(partDetail / wholeDetail, 4.0 / 3.0, accuracy: 0.03, "\(wholeDetail) → \(partDetail)")
        XCTAssertEqual(Double(try XCTUnwrap(part.int("height"))), Double(try XCTUnwrap(whole.int("height"))), accuracy: 2)

        let outside = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "render_viewport", "params": [
            "handle": handle, "region": ["min_x_mm": 50, "min_y_mm": 50, "max_x_mm": 60, "max_y_mm": 60]]])
        XCTAssertNotNil(outside["error"], "\(outside)")
    }

    /// Pixels in the airwire colour in the rows through the render's middle.
    private func airwirePixels(_ render: JSONDictionary) throws -> Int {
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(render.string("png_base64"))))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for row in max(0, height / 2 - 3)...min(height - 1, height / 2 + 3) {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let (red, green, blue) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                if blue > 180, red < 80, green < 160 {
                    count += 1
                }
            }
        }
        return count
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
