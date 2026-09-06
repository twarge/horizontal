import Foundation
import XCTest
@testable import HorizontalNative

/// The per-file view-state record both platforms persist — most recently the
/// pane-split separator positions.
final class HorizontalFileViewStateTests: XCTestCase {
    func testPaneSizeFractionsRoundTrip() throws {
        var state = HorizontalFileViewState.default
        state.visiblePanes = [.schematic, .board, .threeD]
        state.paneSizeFractions = [.schematic: 0.25, .board: 0.5, .threeD: 0.25]

        let decoded = try JSONDecoder().decode(
            HorizontalFileViewState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.visiblePanes, state.visiblePanes)
        XCTAssertEqual(decoded.paneSizeFractions, state.paneSizeFractions)
    }

    func testStoredStateWithoutFractionsDecodesToEvenSplits() throws {
        // A state saved before separator positions existed must keep decoding —
        // an empty map means "even splits", the behavior those saves had.
        let legacyPayload = Data("""
        {"visiblePanes":["schematic","board"],"showsNavigatorSidebar":true,"showsSelectionSidebar":false}
        """.utf8)

        let decoded = try JSONDecoder().decode(HorizontalFileViewState.self, from: legacyPayload)

        XCTAssertEqual(decoded.paneSizeFractions, [:])
        XCTAssertEqual(decoded.visiblePanes, [.schematic, .board])
    }

    @MainActor
    func testStoreRoundTripsThroughDefaults() throws {
        let suiteName = "horizontal-view-state-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = HorizontalFileViewStateStore(defaults: defaults)
        let fileURL = URL(fileURLWithPath: "/tmp/Example.horizontal")

        var state = HorizontalFileViewState.default
        state.paneSizeFractions = [.schematic: 0.7, .board: 0.3]
        store.save(state, for: fileURL)

        XCTAssertEqual(store.load(for: fileURL)?.paneSizeFractions, state.paneSizeFractions)
    }

    /// A new document lives at a temporary path until its first save, and a
    /// project may be renamed or moved: its layout follows the project's
    /// uuid, not its path. State saved by path alone is still found.
    @MainActor
    func testStateFollowsTheProjectIDAcrossPaths() throws {
        let suiteName = "horizontal-view-state-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = HorizontalFileViewStateStore(defaults: defaults)
        let temporaryURL = URL(fileURLWithPath: "/tmp/HorizontalUntitled/abc/Untitled.horizontal")
        let savedURL = URL(fileURLWithPath: "/Users/me/Projects/Test.horizontal")

        var state = HorizontalFileViewState.default
        state.visiblePanes = [.schematic, .board, .threeD]
        state.paneSizeFractions = [.schematic: 0.5, .board: 0.3, .threeD: 0.2]
        store.save(state, for: temporaryURL, projectID: "ABC-123")

        XCTAssertEqual(store.load(for: savedURL, projectID: "abc-123")?.visiblePanes, state.visiblePanes, "found by uuid at the new path")
        XCTAssertEqual(store.load(for: savedURL, projectID: "abc-123")?.paneSizeFractions, state.paneSizeFractions)
        XCTAssertNil(store.load(for: savedURL), "nothing was saved for the path alone")

        // A project with no usable uuid, or state saved before uuids were used, keys by path.
        var legacy = HorizontalFileViewState.default
        legacy.visiblePanes = [.board]
        store.save(legacy, for: savedURL)
        XCTAssertEqual(store.load(for: savedURL, projectID: "unknown-project")?.visiblePanes, [.board])
        XCTAssertEqual(store.load(for: savedURL, projectID: "never-saved")?.visiblePanes, [.board], "the path is the fallback")
        XCTAssertEqual(store.load(for: savedURL, projectID: "abc-123")?.visiblePanes, state.visiblePanes, "the uuid wins over the path")
    }
}
