import XCTest
@testable import HorizontalNative

final class SchematicMetalOwnerTests: XCTestCase {
    func testNoPopulateLinesBelongToTheirSymbol() {
        XCTAssertEqual(
            schematicMetalSymbolID(forGeometryID: "symbol-id/nopopulate/0"),
            "symbol-id"
        )
        XCTAssertEqual(
            schematicMetalSymbolID(forGeometryID: "block-id/symbol-id/nopopulate/1"),
            "block-id/symbol-id"
        )
    }

    func testStandardSymbolGeometryStillResolvesToItsOwner() {
        XCTAssertEqual(
            schematicMetalSymbolID(forGeometryID: "symbol-id/pin/pin-id"),
            "symbol-id"
        )
        XCTAssertEqual(
            schematicMetalSymbolID(forGeometryID: "symbol-id/text/text-id"),
            "symbol-id"
        )
    }
}
