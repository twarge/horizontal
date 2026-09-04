import Foundation
import HorizontalProjectIO
import XCTest

/// Byte-level fixtures for the Horizon (nlohmann `dump(4)`) JSON writer. Each
/// rule that differs from Foundation's serializer gets its own test so a
/// regression names the rule it broke.
final class HorizontalHorizonJSONWriterTests: XCTestCase {
    func testNestedObjectsAndArraysUseFourSpaceIndentAndNoTrailingNewline() throws {
        let object: [String: Any] = [
            "name": "R",
            "pins": ["a": ["position": [1, 2]]],
            "tags": ["x", "y"],
        ]

        XCTAssertEqual(
            try HorizontalHorizonJSONWriter.string(object),
            """
            {
                "name": "R",
                "pins": {
                    "a": {
                        "position": [
                            1,
                            2
                        ]
                    }
                },
                "tags": [
                    "x",
                    "y"
                ]
            }
            """
        )
    }

    func testEmptyContainersCollapse() throws {
        XCTAssertEqual(
            try HorizontalHorizonJSONWriter.string(["a": [String: Any](), "b": [Any]()]),
            "{\n    \"a\": {},\n    \"b\": []\n}"
        )
        XCTAssertEqual(try HorizontalHorizonJSONWriter.string([:]), "{}")
    }

    func testKeysSortByByteValue() throws {
        // std::map order: uppercase before lowercase, "_" before letters.
        let object: [String: Any] = ["base": 1, "MPN": 2, "_x": 3, "Z": 4, "a": 5]
        let output = try HorizontalHorizonJSONWriter.string(object)
        let keys = output.split(separator: "\n").compactMap { line -> String? in
            guard let quote = line.firstIndex(of: "\""),
                  let end = line[line.index(after: quote)...].firstIndex(of: "\"") else {
                return nil
            }
            return String(line[line.index(after: quote)..<end])
        }
        XCTAssertEqual(keys, ["MPN", "Z", "_x", "a", "base"])
    }

    func testStringsEscapeLikeNlohmann() throws {
        let object: [String: Any] = [
            "s": "quote\" backslash\\ slash/ tab\t newline\n cr\r bell\u{07} del\u{7F} ω×",
        ]
        XCTAssertEqual(
            try HorizontalHorizonJSONWriter.string(object),
            "{\n    \"s\": \"quote\\\" backslash\\\\ slash/ tab\\t newline\\n cr\\r bell\\u0007 del\u{7F} ω×\"\n}"
        )
    }

    func testBooleansAndNull() throws {
        let object: [String: Any] = ["t": true, "f": false, "n": NSNull()]
        XCTAssertEqual(
            try HorizontalHorizonJSONWriter.string(object),
            "{\n    \"f\": false,\n    \"n\": null,\n    \"t\": true\n}"
        )
    }

    func testIntegersPrintWithoutFractions() throws {
        let object: [String: Any] = ["a": 0, "b": -400000, "c": Int64(1_000_000_000_000), "d": 7]
        XCTAssertEqual(
            try HorizontalHorizonJSONWriter.string(object),
            "{\n    \"a\": 0,\n    \"b\": -400000,\n    \"c\": 1000000000000,\n    \"d\": 7\n}"
        )
    }

    func testFloatsFollowNlohmannFormatting() {
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(50.0), "50.0")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(1.0), "1.0")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(0.5), "0.5")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(-0.25), "-0.25")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(0.0), "0.0")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(0.001), "0.001")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(0.00001), "1e-05")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(123456.789), "123456.789")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(1e14), "100000000000000.0")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(1e15), "1e+15")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(1.5e16), "1.5e+16")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(.nan), "null")
        XCTAssertEqual(HorizontalHorizonJSONWriter.formatFloat(.infinity), "null")
    }

    /// The parity guarantee rests on `JSONSerialization` keeping integer,
    /// float and boolean numbers distinguishable through `NSNumber`. If a
    /// Foundation change ever collapses them this test fails first.
    func testJSONSerializationPreservesNumberKinds() throws {
        let source = "{\n    \"a\": 1,\n    \"b\": 1.0,\n    \"c\": true,\n    \"d\": 50.0,\n    \"e\": 0,\n    \"f\": false\n}"
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        )
        XCTAssertEqual(try HorizontalHorizonJSONWriter.string(object), source)
    }

    func testSwiftNativeValuesSerializeByKind() throws {
        let object: [String: Any] = ["i": 3, "d": 3.0, "b": true, "s": "x"]
        XCTAssertEqual(
            try HorizontalHorizonJSONWriter.string(object),
            "{\n    \"b\": true,\n    \"d\": 3.0,\n    \"i\": 3,\n    \"s\": \"x\"\n}"
        )
    }

    func testDataOutputIsUTF8WithoutTrailingNewline() throws {
        let data = try HorizontalHorizonJSONWriter.data(["ω": "×"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\n    \"ω\": \"×\"\n}")
        XCTAssertNotEqual(data.last, 0x0A)
    }

    func testUnsupportedValuesThrow() {
        XCTAssertThrowsError(try HorizontalHorizonJSONWriter.string(["date": Date()]))
    }
}
