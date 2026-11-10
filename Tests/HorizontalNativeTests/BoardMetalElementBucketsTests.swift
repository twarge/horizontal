import XCTest
@testable import HorizontalNative

/// Every bucket batch is named and listed, so the scene verifier, which walks
/// `batchKeyPaths` and names what differs from `namedBatches`, misses none.
final class BoardMetalElementBucketsTests: XCTestCase {
    func testEveryBatchIsListedAndNamed() {
        XCTAssertEqual(BoardMetalElementBuckets.batchKeyPaths.count, BoardMetalElementBuckets().namedBatches().count)
    }
}
