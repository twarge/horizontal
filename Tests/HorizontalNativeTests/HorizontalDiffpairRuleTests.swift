import Foundation
import XCTest
@testable import HorizontalNative

/// The diffpair rule, read at last: the first enabled one by order whose net
/// class is the pair's (its primary's) and whose layer is the route's or any,
/// and what the route inspector shows of it for a net in a pair.
@MainActor
final class HorizontalDiffpairRuleTests: XCTestCase {
    private let tx = "11111111-1111-4111-8111-111111111111"
    private let txn = "22222222-2222-4222-8222-222222222222"
    private let other = "33333333-3333-4333-8333-333333333333"
    private let fast = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let plain = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private var details: [String: HorizontalNetDetails] {
        [tx: HorizontalNetDetails(id: tx, name: "TX+", netClassID: fast, netClassName: "Fast", diffpairID: txn, isDiffpairPrimary: true),
         // The secondary's own class is another: the pair's is the primary's.
         txn: HorizontalNetDetails(id: txn, name: "TX-", netClassID: plain, netClassName: "Plain", diffpairID: tx),
         other: HorizontalNetDetails(id: other, name: "CLK", netClassID: plain, netClassName: "Plain")]
    }

    private var rulesJSON: JSONDictionary {
        ["diffpair": [
            "r-any": ["enabled": true, "order": 2, "net_class": fast.uppercased(), "layer": 10000,
                      "track_width": 120_000, "track_gap": 100_000, "via_gap": 300_000],
            "r-top": ["enabled": true, "order": 1, "net_class": fast, "layer": 0,
                      "track_width": 150_000, "track_gap": 150_000, "via_gap": 250_000],
            "r-off": ["enabled": false, "order": 0, "net_class": fast, "layer": 10000,
                      "track_width": 1, "track_gap": 1, "via_gap": 1],
        ] as JSONDictionary,
         "clearance_copper": [
            "c": ["enabled": true, "order": 0, "layer": 10000, "routing_offset": 0,
                  "match_1": ["mode": "all"], "match_2": ["mode": "all"],
                  "clearances": [["types": ["track", "track"], "clearance": 125_000]]],
         ] as JSONDictionary]
    }

    func testThePairsRuleIsItsPrimarysClassOnTheLayer() {
        let rules = HorizontalBoardRules(rules: rulesJSON, netDetails: details)
        XCTAssertEqual(rules.diffpairRules.map(\.id), ["r-off", "r-top", "r-any"], "by order")
        XCTAssertEqual(rules.diffpair(net: tx, layer: 0)?.id, "r-top")
        XCTAssertEqual(rules.diffpair(net: txn.uppercased(), layer: 0)?.id, "r-top", "the secondary by its primary's class")
        XCTAssertEqual(rules.diffpair(net: tx, layer: -100)?.id, "r-any")
        let rule = rules.diffpair(net: txn, layer: -100)
        XCTAssertEqual(rule?.trackWidth, 120_000)
        XCTAssertEqual(rule?.trackGap, 100_000)
        XCTAssertEqual(rule?.viaGap, 300_000)
        XCTAssertEqual(rule?.pitch, 220_000)
        XCTAssertNil(rules.diffpair(net: other, layer: 0), "no rule takes its class")
        XCTAssertNil(rules.diffpair(net: nil, layer: 0))
    }

    func testTheRouteInspectorShowsThePairAndItsRule() throws {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/pair-rule.hprj"), uuid: "b", name: "pair rule",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: details,
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: HorizontalRect(points: [.zero]), bounds: HorizontalRect(points: [.zero])
        )
        board.rules = HorizontalBoardRules(rules: rulesJSON, netDetails: details)
        func state(net: String, layer: Int) -> HorizontalRouteInspectorState {
            HorizontalRouteInspectorModel().makeState(HorizontalRouteInspectorInput(
                board: board, netClasses: [HorizontalNetClass(id: fast, name: "Fast"), HorizontalNetClass(id: plain, name: "Plain")],
                layer: layer, netID: net, width: 150_000, widthSource: .fallback, hasStarted: true, isRouterMode: false,
                route: [], connecting: [], via: nil, viaArmed: false, customVia: false, rulesRevision: 0))
        }
        let secondary = try XCTUnwrap(state(net: txn, layer: 0).diffpair)
        XCTAssertEqual(secondary.partnerName, "TX+")
        XCTAssertFalse(secondary.isPrimary)
        XCTAssertEqual(secondary.rule?.id, "r-top")
        XCTAssertEqual(secondary.ruleBrief, "Net class Fast on Top Copper")
        XCTAssertEqual(secondary.clearance, 125_000)
        XCTAssertEqual(secondary.gap, 150_000)
        XCTAssertNil(secondary.gapWarning)

        // On the bottom the rule's gap is under the clearance, which wins.
        let bottom = try XCTUnwrap(state(net: tx, layer: -100).diffpair)
        XCTAssertEqual(bottom.ruleBrief, "Net class Fast on any layer")
        XCTAssertEqual(bottom.gap, 125_000)
        XCTAssertNotNil(bottom.gapWarning)

        XCTAssertNil(state(net: other, layer: 0).diffpair, "in no pair")
    }
}
