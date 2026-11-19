import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The rules window's list is the rules' priority, first by order first: a
/// rule added goes to the top, as Horizon's Add puts it, where it takes the
/// nets it is made for; a drag moves one, and renumbers the kind's rules in
/// the order the list then shows.
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

    func testAnAddedRuleGoesFirstAndTheRestAreNumberedAfterIt() {
        let rule: JSONDictionary = ["enabled": true, "order": 0, "match": ["mode": "net_class"] as JSONDictionary]
        let added = HorizontalBoardRuleKind.trackWidth.addingRule(rule, id: "new", to: rules())
        XCTAssertEqual(order(added), ["new", "a", "b", "c"])
        let bucket = added.dictionary("track_width") ?? [:]
        XCTAssertEqual(["new", "a", "b", "c"].map { bucket.dictionary($0)?.int("order") }, [0, 1, 2, 3])
        XCTAssertEqual(bucket.dictionary("new")?.dictionary("match")?.string("mode"), "net_class")
        XCTAssertEqual(bucket.dictionary("b")?.bool("enabled"), false, "the rest keep what they state")
        XCTAssertEqual(added.dictionary("via")?.dictionary("v")?.int("order"), 3, "another kind's rules are left alone")
    }

    func testAKindsFirstRuleIsNumberedZero() {
        let added = HorizontalBoardRuleKind.holeSize.addingRule(["enabled": true, "order": 7], id: "h", to: rules())
        XCTAssertEqual(added.dictionary("hole_size")?.dictionary("h")?.int("order"), 0)
        XCTAssertEqual(order(added), ["a", "b", "c"])
    }

    func testAKindThatHoldsOneRuleIsGivenNoOther() {
        let added = HorizontalBoardRuleKind.parameters.addingRule(["enabled": true], id: "p", to: rules())
        XCTAssertEqual(added as NSDictionary, rules() as NSDictionary)
    }

    /// A board with one track width rule, for every net, as a new board has:
    /// a rule added for a net class is the rule of a net put in that class,
    /// and the net's track takes its width. Added after the one for every
    /// net, it took no net, and the class changed nothing.
    func testARuleAddedForANetClassIsTheRuleOfANetPutInThatClass() {
        let null = "00000000-0000-0000-0000-000000000000"
        let fast = "aaaaaaaa-0000-4000-8000-000000000001"
        func rule(_ mode: String, def: Int) -> JSONDictionary {
            ["enabled": true, "order": 0,
             "match": ["mode": mode, "net": null, "net_class": mode == "net_class" ? fast : null, "net_name_regex": ""] as JSONDictionary,
             "widths": ["0": ["min": 100_000, "max": 1_000_000, "def": def] as JSONDictionary] as JSONDictionary]
        }
        let everyNet: JSONDictionary = ["track_width": ["rest": rule("all", def: 200_000)] as JSONDictionary]
        let rules = HorizontalBoardRuleKind.trackWidth.addingRule(rule("net_class", def: 400_000), id: "fast", to: everyNet)

        var track = HorizontalSegment(
            id: "track", from: .zero, to: HorizontalPoint(x: 1_000_000, y: 0), width: 200_000,
            layer: HorizontalBoardLayers.topCopper, netID: "sig")
        track.widthFromRules = true
        var board = HorizontalGerberExportFixture.board(tracks: [track])
        board.netDetails = ["sig": HorizontalNetDetails(id: "sig", name: "SIG", netClassID: "slow", netClassName: "Slow")]
        board.takeRules(rules)
        HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        XCTAssertEqual(board.rules.trackWidth(net: "sig", layer: 0)?.rule.id, "rest")
        XCTAssertEqual(board.tracks.first?.width, 200_000)

        board.netDetails["sig"]?.netClassID = fast
        board.netDetails["sig"]?.netClassName = "Fast"
        HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        XCTAssertEqual(board.rules.trackWidth(net: "sig", layer: 0)?.rule.id, "fast", "the inspector's Rule")
        XCTAssertEqual(board.tracks.first?.width, 400_000)
    }

    func testViaDefinitionsAreNotReordered() {
        let rules: JSONDictionary = [
            "via_definitions": ["enabled": true, "order": -1, "via_definitions": [:] as JSONDictionary] as JSONDictionary,
        ]
        let moved = HorizontalBoardRuleKind.viaDefinitions.movingRules(in: rules, fromOffsets: IndexSet(integer: 0), toOffset: 1)
        XCTAssertEqual(moved.dictionary("via_definitions")?.int("order"), -1)
    }
}
