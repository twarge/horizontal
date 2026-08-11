import Foundation
import XCTest
@testable import HorizontalNative

/// Release builds — including anything archived for distribution — must be
/// read-only regardless of stored preferences, and must not offer a toggle.
/// Debug builds keep the preference so the editing paths stay developable.
final class HorizontalReadOnlyBuildTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "horizontal-readonly-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    func testForcedFlagMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertFalse(
            HorizontalOperationDefaults.isReadOnlyOperationForced,
            "Debug keeps the preference so editing can be developed and tested"
        )
        #else
        XCTAssertTrue(
            HorizontalOperationDefaults.isReadOnlyOperationForced,
            "Release/archive builds ship read-only"
        )
        #endif
    }

    func testStoredPreferenceCannotUnlockAReleaseBuild() throws {
        // The exact escape this guards: a value left behind by an earlier Debug
        // run, or written with `defaults write`, must not unlock a shipped build.
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)

        let readOnly = HorizontalOperationDefaults.readOnlyOperation(defaults: defaults)

        #if DEBUG
        XCTAssertFalse(readOnly, "Debug honours an explicit opt-out")
        #else
        XCTAssertTrue(readOnly, "Release ignores the stored preference entirely")
        #endif
    }

    func testUnsetPreferenceIsReadOnlyOnEveryConfiguration() throws {
        // Read-only is the safe default everywhere, so a fresh install never
        // starts out able to overwrite a project.
        let defaults = try isolatedDefaults()
        defaults.removeObject(forKey: HorizontalOperationDefaults.readOnlyOperationKey)

        XCTAssertTrue(HorizontalOperationDefaults.readOnlyOperation(defaults: defaults))
    }

    // The document's write guard itself isn't reachable from a test:
    // FileDocumentWriteConfiguration has no public initializer. It is a single
    // `guard !HorizontalOperationDefaults.readOnlyOperation()` on the same flag
    // covered above.

    func testRefusalMessageDoesNotPointAtAToggleThatIsAbsent() {
        let message = HorizontalProjectDocumentError.readOnlyOperation.errorDescription ?? ""

        #if DEBUG
        XCTAssertTrue(message.contains("Settings"), "Debug can point the user at the toggle")
        #else
        XCTAssertFalse(
            message.contains("Settings"),
            "Release has no toggle, so the message must not send the user looking for one"
        )
        #endif
    }
}
