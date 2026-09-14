import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The parts of the App Intents surface that do not need Siri to check: which
/// document counts as the one in front when there is no window system to ask,
/// what the pane choices mean, and that the one intent left does what it says
/// against a registered document.
final class HorizontalIntentTests: XCTestCase {
    /// Every canvas alone and every combination, because "show me the schematic
    /// and the board" is one request.
    func testThePaneChoicesMapToPanes() {
        XCTAssertEqual(HorizontalPaneChoice.schematic.panes, [.schematic])
        XCTAssertEqual(HorizontalPaneChoice.board.panes, [.board])
        XCTAssertEqual(HorizontalPaneChoice.threeD.panes, [.threeD])
        XCTAssertEqual(HorizontalPaneChoice.schematicAndBoard.panes, [.schematic, .board])
        XCTAssertEqual(HorizontalPaneChoice.schematicAndThreeD.panes, [.schematic, .threeD])
        XCTAssertEqual(HorizontalPaneChoice.boardAndThreeD.panes, [.board, .threeD])
        XCTAssertEqual(HorizontalPaneChoice.everything.panes, [.schematic, .board, .threeD])
        XCTAssertEqual(Set(HorizontalPaneChoice.allCases.map(\.panes)).count, HorizontalPaneChoice.allCases.count,
                       "no two choices mean the same thing")
    }

    /// With nothing open a request has nothing to act on, and says so.
    @MainActor
    func testWithNothingOpenThereIsNoTarget() {
        XCTAssertThrowsError(try HorizontalCommandTarget.current()) { error in
            XCTAssertEqual("\(error)", "\(HorizontalCommandError.noProjectOpen)")
        }
    }

    /// With more than one document open and no window system to ask — the
    /// iPad — the one whose scene most recently came to the front is the one
    /// a request acts on; and when that document closes, the choice falls
    /// back rather than dangling. (On the Mac the document controller is
    /// asked first; in a test process it has no documents and defers.)
    @MainActor
    func testTheDocumentMostRecentlyInFrontIsTheOneActedOn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = HorizontalDispatchSession.shared
        var handles: [Int] = []
        defer {
            for handle in handles {
                session.unregisterLive(handle: handle)
            }
        }
        for name in ["First", "Second"] {
            let url = root.appendingPathComponent("\(name).horizontal")
            try HorizontalProjectArchive.newProject().write(to: url)
            let project = try HorizontalProject.load(from: url)
            let archive = try HorizontalProjectArchive.snapshot(from: url)
            let document = HorizontalLiveDocument(url: url, title: name, project: project, archive: archive)
            handles.append(session.registerLive(document))
        }

        XCTAssertEqual(try HorizontalCommandTarget.current().handle, handles[0], "nothing noted: the first one registered")
        session.noteLiveDocumentInFront(handle: handles[1])
        XCTAssertEqual(try HorizontalCommandTarget.current().handle, handles[1])
        session.noteLiveDocumentInFront(handle: handles[1] + 1_000)
        XCTAssertEqual(try HorizontalCommandTarget.current().handle, handles[1],
                       "a handle that is not a live document changes nothing")
        XCTAssertEqual(HorizontalCommandTarget.target(handle: handles[0])?.handle, handles[0],
                       "a workspace that knows its handle gets its own document")
        XCTAssertNil(HorizontalCommandTarget.target(handle: handles[1] + 1_000))

        session.unregisterLive(handle: handles.removeLast())
        XCTAssertEqual(try HorizontalCommandTarget.current().handle, handles[0])
    }

    /// "Start listening in Horizontal": the intent reaches the voice control
    /// of the document in front, which the workspace attached by handle, and
    /// says so when there is none.
    @MainActor
    func testStartListeningReachesTheAttachedControl() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let project = try HorizontalProject.load(from: url)
        let archive = try HorizontalProjectArchive.snapshot(from: url)
        let document = HorizontalLiveDocument(url: url, title: "Untitled", project: project, archive: archive)
        let session = HorizontalDispatchSession.shared
        let handle = session.registerLive(document)
        defer { session.unregisterLive(handle: handle) }

        do {
            _ = try await StartListeningIntent().perform()
            XCTFail("no workspace has attached a control")
        } catch let error as HorizontalCommandError {
            XCTAssertEqual(error.message, "Voice control is not available for Untitled.")
        }

        final class SilentEngine: HorizontalSpeechEngine {
            var started = 0
            func start(contextualStrings: [String]) -> AsyncStream<HorizontalSpeechEvent> {
                started += 1
                return AsyncStream { $0.yield(.listening) }
            }
            func stop() {}
        }
        let engine = SilentEngine()
        HorizontalVoiceControl.makeEngine = { engine }
        defer { HorizontalVoiceControl.makeEngine = nil }
        let control = HorizontalVoiceControl()
        control.attach(handle: handle)
        defer { control.detach() }
        XCTAssertTrue(HorizontalVoiceControl.control(forHandle: handle) === control)

        _ = try await StartListeningIntent().perform()
        XCTAssertTrue(control.isListening)
        XCTAssertEqual(engine.started, 1)
        _ = try await StopListeningIntent().perform()
        XCTAssertFalse(control.isListening)
    }

    /// The intent, run the way Shortcuts runs it — perform() on a value with
    /// its parameter set — against a document registered the way the
    /// workspace registers it.
    @MainActor
    func testShowPanesActsOnTheLiveDocument() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let project = try HorizontalProject.load(from: url)
        let archive = try HorizontalProjectArchive.snapshot(from: url)
        let document = HorizontalLiveDocument(url: url, title: "Untitled", project: project, archive: archive)
        var selection = HorizontalLiveSelection(panes: ["schematic"])
        document.selection = { selection }
        document.setPanes = { panes in selection.panes = panes.map(\.rawValue).sorted() }
        let session = HorizontalDispatchSession.shared
        let handle = session.registerLive(document)
        defer { session.unregisterLive(handle: handle) }

        let show = ShowPanesIntent()
        show.choice = .boardAndThreeD
        _ = try await show.perform()
        XCTAssertEqual(selection.panes, ["board", "threeD"])
        show.choice = .everything
        _ = try await show.perform()
        XCTAssertEqual(selection.panes, ["board", "schematic", "threeD"])
    }
}
