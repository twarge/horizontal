import XCTest
@testable import HorizontalNative

/// The info panel's unresolved-package count: a package is resolved when some
/// geometry id is its id, or starts with it and a slash.
final class HorizontalBoardUnresolvedPackageTests: XCTestCase {
    func testUnresolvedPackagesFollowThePrefixRule() {
        let packageIDs = ["PKG-A", "pkg-b", "pkg-c", "a/b"]
        let geometryIDs = ["pkg-a/pad/1", "PKG-B", "pkg-cx/pad/1", "a/b/line/2"]

        // pkg-a by prefix, pkg-b by equality, a/b by a multi-segment prefix;
        // pkg-c only shares characters with "pkg-cx", which is not a prefix.
        XCTAssertEqual(HorizontalBoard.unresolvedPackageCount(packageIDs: packageIDs, geometryIDs: geometryIDs), 1)
        XCTAssertEqual(HorizontalBoard.unresolvedPackageCount(packageIDs: [], geometryIDs: geometryIDs), 0)
        XCTAssertEqual(HorizontalBoard.unresolvedPackageCount(packageIDs: packageIDs, geometryIDs: []), 4)
    }
}
