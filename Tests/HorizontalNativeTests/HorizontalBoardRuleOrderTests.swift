import XCTest
@testable import HorizontalNative

/// The rules window's list is dragged into the rules' priority: a move
/// renumbers the kind's rules in the order the list then shows.
final class HorizontalBoardRuleOrderTests: XCTestCase {
    private let context = HorizontalBoardRuleContext(board: nil, netClasses: [])

    private func rules() -> JSONDictionary {
        [
            "track_width": [
                "a": ["enabled": true, "order": 0, "match": ["mode": "net"] as JSONDictionary] as JSONDictionary,
                "b": ["enabled": false, "order": 1, "match": ["mode": "net_class"] as JSONDictionary] as JSONDictionary,
                "c": ["enabled": true, "order": 5, "match": ["mode": "all"] as JSONDictionary] as JSONDictionary,
            ] as JSONDictionary,
            "via": [
                "v": ["enabled": true, "order": 3] as JSONDictionary,
            ] as JSONDictionary,
        ]
    }

    private func order(_ rules: JSONDictionary) -> [String] {
        HorizontalBoardRuleKind.trackWidth.instances(in: rules, context: context).map(\.id)
    }

    func testDraggingTheLastRuleToTheTopRenumbersEveryRule() {
        let moved = HorizontalBoardRuleKind.trackWidth.movingRules(in: rules(), fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(order(moved), ["c", "a", "b"])
        let bucket = moved.dictionary("track_width") ?? [:]
        XCTAssertEqual(bucket.dictionary("c")?.int("order"), 0)
        XCTAssertEqual(bucket.dictionary("a")?.int("order"), 1)
        XCTAssertEqual(bucket.dictionary("b")?.int("order"), 2)
    }

    func testDraggingDownLandsAboveTheRowDroppedOn() {
        // List's offsets: the first row dropped before the third lands second.
        let moved = HorizontalBoardRuleKind.trackWidth.movingRules(in: rules(), fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(order(moved), ["b", "a", "c"])
    }

    func testAMoveKeepsEachRuleAndLeavesOtherKindsAlone() {
        let moved = HorizontalBoardRuleKind.trackWidth.movingRules(in: rules(), fromOffsets: IndexSet(integer: 1), toOffset: 3)
        let bucket = moved.dictionary("track_width") ?? [:]
        XCTAssertEqual(bucket.dictionary("b")?.bool("enabled"), false)
        XCTAssertEqual(bucket.dictionary("b")?.dictionary("match")?.string("mode"), "net_class")
        XCTAssertEqual(moved.dictionary("via")?.dictionary("v")?.int("order"), 3)
    }

    func testViaDefinitionsAreNotReordered() {
        let rules: JSONDictionary = [
            "via_definitions": ["enabled": true, "order": -1, "via_definitions": [:] as JSONDictionary] as JSONDictionary,
        ]
        let moved = HorizontalBoardRuleKind.viaDefinitions.movingRules(in: rules, fromOffsets: IndexSet(integer: 0), toOffset: 1)
        XCTAssertEqual(moved.dictionary("via_definitions")?.int("order"), -1)
    }
}
