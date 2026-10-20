import Foundation
import XCTest
@testable import HorizontalNative

/// The theme picker's write goes out after the view update that delivered
/// it: published within it, SwiftUI warned "Publishing changes from within
/// view updates is not allowed".
@MainActor
final class HorizontalAppThemeTests: XCTestCase {
    func testAPickedThemeTakesEffectOnTheNextTurnOfTheMainQueue() throws {
        let name = "horizontal-theme-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let binding = HorizontalAppearanceSettings(defaults: defaults).appThemeBinding()
        let picked = try XCTUnwrap(HorizontalAppTheme.allCases.first { $0 != binding.wrappedValue })

        binding.wrappedValue = picked
        XCTAssertNotEqual(binding.wrappedValue, picked, "nothing is published within the write")
        let turned = expectation(description: "the main queue turned")
        DispatchQueue.main.async { turned.fulfill() }
        wait(for: [turned], timeout: 1)
        XCTAssertEqual(binding.wrappedValue, picked)
        XCTAssertEqual(HorizontalAppearanceSettings(defaults: defaults).appThemeBinding().wrappedValue, picked, "and it is kept")
    }
}
