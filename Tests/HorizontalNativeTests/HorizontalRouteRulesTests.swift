import XCTest
@testable import HorizontalNative

/// The route inspector's model: the track width rules as Horizon looks them
/// up, where a route's width comes from, the clearances a track keeps and the
/// rule each comes from, the edits that change the rules, and the exact
/// distances to what a route passes.
final class HorizontalRouteRulesTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let null = "00000000-0000-0000-0000-000000000000"
    private let power = "11111111-1111-1111-1111-111111111111"

    private var netDetails: [String: HorizontalNetDetails] {
        [
            "vcc": HorizontalNetDetails(id: "vcc", name: "VCC", netClassID: power, netClassName: "Power"),
            "gnd": HorizontalNetDetails(id: "gnd", name: "GND", netClassID: nil, netClassName: nil),
            "sig": HorizontalNetDetails(id: "sig", name: "SIG", netClassID: nil, netClassName: nil),
        ]
    }

    private func match(_ mode: String, netClass: String? = nil, net: String? = nil) -> JSONDictionary {
        ["mode": mode, "net": net ?? null, "net_class": netClass ?? null, "net_name_regex": ""]
    }

    private func widths(_ def: Int, min: Int = 100_000, max: Int = 10_000_000) -> JSONDictionary {
        ["min": min, "max": max, "def": def]
    }

    private var trackWidthRules: JSONDictionary {
        [
            "track_width": [
                "power": ["enabled": true, "order": 0, "match": match("net_class", netClass: power),
                          "widths": ["0": widths(500_000, min: 300_000, max: 2_000_000)]],
                "all": ["enabled": true, "order": 1, "match": match("all"),
                        "widths": ["0": widths(150_000), "-100": widths(250_000)]],
                "off": ["enabled": false, "order": -1, "match": match("all"), "widths": ["0": widths(900_000)]],
            ] as JSONDictionary
        ]
    }

    // MARK: - Track width rules

    func testTrackWidthIsTheFirstEnabledRuleThatTakesTheNet() throws {
        let rules = HorizontalBoardRules(rules: trackWidthRules, netDetails: netDetails)
        XCTAssertEqual(rules.trackWidthRules.map(\.id), ["off", "power", "all"])

        let power = try XCTUnwrap(rules.trackWidth(net: "vcc", layer: top))
        XCTAssertEqual(power.rule.id, "power")
        XCTAssertEqual(power.widths, HorizontalRuleTrackWidth.Widths(min: 300_000, max: 2_000_000, def: 500_000))

        XCTAssertEqual(rules.trackWidth(net: "gnd", layer: top)?.widths.def, 150_000)
        XCTAssertEqual(rules.trackWidth(net: "gnd", layer: bottom)?.widths.def, 250_000)
        // A route with no net yet: only a rule taking every net does.
        XCTAssertEqual(rules.trackWidth(net: nil, layer: top)?.rule.id, "all")
        // A layer the rule leaves out has Horizon's default widths
        // (BoardRules::update_for_board).
        XCTAssertEqual(rules.trackWidth(net: "vcc", layer: bottom)?.widths, .horizonDefault)
        XCTAssertNil(HorizontalBoardRules(rules: nil, netDetails: netDetails).trackWidth(net: "gnd", layer: top))
    }

    func testRulesThatShareAnOrderGoByID() {
        let json: JSONDictionary = [
            "clearance_copper": [
                "b": ["enabled": true, "order": 0, "layer": 10000, "match_1": match("all"), "match_2": match("all"),
                      "clearances": [["types": ["track", "track"], "clearance": 200_000]]],
                "a": ["enabled": true, "order": 0, "layer": 10000, "match_1": match("all"), "match_2": match("all"),
                      "clearances": [["types": ["track", "track"], "clearance": 300_000]]],
            ] as JSONDictionary
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])
        XCTAssertEqual(rules.clearanceCopper(net1: "x", net2: "y", layer: top).id, "a")
        XCTAssertEqual(rules.clearanceCopper(net1: "x", net2: "y", layer: top).clearance(.track, .track), 300_000)
        // No rule: the fallback, which has no id.
        XCTAssertEqual(HorizontalBoardRules.empty.clearanceCopper(net1: nil, net2: nil, layer: top).id, "")
    }

    // MARK: - Where the width comes from

    func testARouteOnAPadTakesTheRulesAndOnATrackTheTracks() {
        let rules = HorizontalBoardRules(rules: trackWidthRules, netDetails: netDetails)
        let track = HorizontalSegment(
            id: "t", from: .zero, to: HorizontalPoint(x: 1_000_000, y: 0), width: 330_000, layer: top, netID: "vcc")
        var ruledTrack = track
        ruledTrack.widthFromRules = true

        // On a pad, the rules', a custom width or not.
        XCTAssertEqual(
            HorizontalRouteWidth.start(explicit: 420_000, onPad: true, startTrack: nil, net: "vcc", layer: top,
                                       rules: rules, tracks: [track]),
            .init(width: 500_000, source: .rule(id: "power")))
        // On a track, the track's; on one whose width is the rules', theirs.
        XCTAssertEqual(
            HorizontalRouteWidth.start(explicit: 420_000, startTrack: track, net: "vcc", layer: top, rules: rules, tracks: [track]),
            .init(width: 330_000, source: .track(id: "t")))
        XCTAssertEqual(
            HorizontalRouteWidth.start(explicit: nil, startTrack: ruledTrack, net: "vcc", layer: top, rules: rules, tracks: [track]),
            .init(width: 500_000, source: .rule(id: "power")))
        // Anywhere else a custom width, then the rules'.
        XCTAssertEqual(
            HorizontalRouteWidth.start(explicit: 420_000, startTrack: nil, net: "vcc", layer: top, rules: rules, tracks: [track]),
            .init(width: 420_000, source: .custom))
        XCTAssertEqual(
            HorizontalRouteWidth.start(explicit: nil, startTrack: nil, net: "vcc", layer: top, rules: rules, tracks: [track]),
            .init(width: 500_000, source: .rule(id: "power")))
        // Without rules: what most of the net's tracks have, then nothing to go on.
        XCTAssertEqual(
            HorizontalRouteWidth.fromRules(net: "vcc", layer: top, rules: .empty, tracks: [track]),
            .init(width: 330_000, source: .existingTracks))
        XCTAssertEqual(
            HorizontalRouteWidth.fromRules(net: "vcc", layer: top, rules: .empty, tracks: []),
            .init(width: 200_000, source: .fallback))

        XCTAssertFalse(HorizontalRouteWidthSource.custom.followsRules)
        XCTAssertFalse(HorizontalRouteWidthSource.track(id: "t").followsRules)
        XCTAssertTrue(HorizontalRouteWidthSource.rule(id: "power").followsRules)
        XCTAssertTrue(HorizontalRouteWidthSource.existingTracks.followsRules)
    }

    // MARK: - Clearances

    private var clearanceRules: JSONDictionary {
        [
            "clearance_copper": [
                "hv": ["enabled": true, "order": 0, "layer": 10000,
                       "match_1": match("net", net: "vcc"), "match_2": match("all"),
                       "clearances": [["types": ["track", "track"], "clearance": 500_000],
                                      ["types": ["pad", "track"], "clearance": 600_000]]],
                "default": ["enabled": true, "order": 1, "layer": 10000,
                            "match_1": match("all"), "match_2": match("all"),
                            "clearances": [["types": ["track", "track"], "clearance": 150_000],
                                           ["types": ["track", "pad"], "clearance": 200_000],
                                           ["types": ["track", "via"], "clearance": 175_000]]],
            ] as JSONDictionary,
            "clearance_copper_other": [
                "edge": ["enabled": true, "order": 0, "layer": 10000, "match": match("all"),
                         "clearances": [["types": ["track", "board_edge"], "clearance": 300_000]]],
            ] as JSONDictionary,
        ]
    }

    func testSpacingListsTheRuleMostOtherNetsGetAndTheOthers() throws {
        let rules = HorizontalBoardRules(rules: clearanceRules, netDetails: netDetails)
        let names = HorizontalRouteRuleNames(netDetails: netDetails, netClasses: [])
        let spacing = HorizontalRouteSpacing.make(
            net: "gnd", layer: top, rules: rules, otherNets: ["sig", "vcc", nil],
            keepoutClasses: [], names: names)

        XCTAssertEqual(spacing.copperRule.id, "default")
        XCTAssertEqual(spacing.copperRule.brief, "All / All · Any layer")
        func row(_ id: String) throws -> HorizontalRouteSpacing.Row {
            try XCTUnwrap(spacing.rows.first { $0.id == id }, id)
        }
        XCTAssertEqual(try row("copper/track").clearance, 150_000)
        XCTAssertEqual(try row("copper/pad").clearance, 200_000)
        XCTAssertEqual(try row("copper/via").clearance, 175_000)
        // What the rule leaves out is RuleClearanceCopper's 0.1 mm.
        XCTAssertEqual(try row("copper/plane").clearance, 100_000)
        XCTAssertEqual(try row("other/board_edge").clearance, 300_000)
        XCTAssertEqual(try row("other/board_edge").rule.id, "edge")

        // VCC gets the HV rule with GND, and says so.
        let other = try XCTUnwrap(spacing.otherCopperRules.first)
        XCTAssertEqual(other.rule.id, "hv")
        XCTAssertEqual(other.rule.brief, "Net VCC / All · Any layer")
        XCTAssertEqual(other.netCount, 1)
        XCTAssertEqual(other.widest, 600_000)

        let empty = HorizontalRouteSpacing.make(
            net: "gnd", layer: top, rules: .empty, otherNets: ["sig"], keepoutClasses: ["shield"], names: names)
        XCTAssertNil(empty.copperRule.id)
        XCTAssertNil(empty.otherRule.id)
        XCTAssertEqual(empty.rows.last?.table, .keepout("shield"))
        XCTAssertEqual(empty.rows.last?.clearance, 0)
    }

    // MARK: - Editing the rules

    func testEditingATrackWidthRuleWidensItsRangeToTakeTheDefault() throws {
        let edited = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .trackWidth(ruleID: "power", layer: top, widths: .init(min: 300_000, max: 2_000_000, def: 2_500_000)),
            to: trackWidthRules, copperLayers: [top, bottom]))
        let rules = HorizontalBoardRules(rules: edited, netDetails: netDetails)
        XCTAssertEqual(rules.trackWidth(net: "vcc", layer: top)?.widths,
                       HorizontalRuleTrackWidth.Widths(min: 300_000, max: 2_500_000, def: 2_500_000))
        // The other layers and rules are as they were.
        XCTAssertEqual(rules.trackWidth(net: "gnd", layer: bottom)?.widths.def, 250_000)

        // The same widths again change nothing; a rule that isn't there neither.
        XCTAssertNil(HorizontalRouteRuleEditing.applying(
            .trackWidth(ruleID: "power", layer: top, widths: .init(min: 300_000, max: 2_000_000, def: 500_000)),
            to: trackWidthRules, copperLayers: [top]))
        XCTAssertNil(HorizontalRouteRuleEditing.applying(
            .trackWidth(ruleID: "nope", layer: top, widths: .horizonDefault), to: trackWidthRules, copperLayers: [top]))
    }

    func testAddingATrackWidthRuleGivesEveryNetTheWidth() throws {
        let edited = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .addTrackWidthRule(layer: bottom, width: 450_000), to: [:], copperLayers: [top, bottom],
            newRuleID: { "new" }))
        let rules = HorizontalBoardRules(rules: edited, netDetails: netDetails)
        let rule = try XCTUnwrap(rules.trackWidthRules.first)
        XCTAssertEqual(rule.id, "new")
        XCTAssertEqual(rule.match.mode, .all)
        XCTAssertEqual(rules.trackWidth(net: "sig", layer: bottom)?.widths.def, 450_000)
        XCTAssertEqual(rules.trackWidth(net: "sig", layer: top)?.widths, .horizonDefault)
        XCTAssertEqual(Set(rule.widths.keys), [top, bottom])
        // After the rules already there.
        let after = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .addTrackWidthRule(layer: top, width: 300_000), to: trackWidthRules, copperLayers: [top], newRuleID: { "new" }))
        XCTAssertEqual((after.dictionary("track_width")?.dictionary("new"))?.int("order"), 2)
    }

    func testEditingAClearanceFindsItsEntryEitherWayRound() throws {
        let edited = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .copperClearance(ruleID: "hv", .track, .pad, 650_000), to: clearanceRules, copperLayers: [top]))
        let entries = try XCTUnwrap(edited.dictionary("clearance_copper")?.dictionary("hv")?["clearances"] as? [JSONDictionary])
        // The file's ["pad", "track"] entry, changed in place.
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { ($0["types"] as? [String]) == ["pad", "track"] }?.int("clearance"), 650_000)

        let added = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .copperClearance(ruleID: "default", .track, .plane, 250_000), to: clearanceRules, copperLayers: [top]))
        let rules = HorizontalBoardRules(rules: added, netDetails: netDetails)
        XCTAssertEqual(rules.clearanceCopper(net1: "gnd", net2: "sig", layer: top).clearance(.plane, .track), 250_000)
        XCTAssertEqual(rules.clearanceCopper(net1: "gnd", net2: "sig", layer: top).clearance(.track, .track), 150_000)

        XCTAssertNil(HorizontalRouteRuleEditing.applying(
            .copperClearance(ruleID: "default", .via, .track, 175_000), to: clearanceRules, copperLayers: [top]),
            "an entry that already has the value")

        let other = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .copperOtherClearance(ruleID: "edge", copper: .track, nonCopper: .holeNPTH, 220_000),
            to: clearanceRules, copperLayers: [top]))
        let otherRule = HorizontalBoardRules(rules: other, netDetails: [:]).clearanceCopperOther(net: "gnd", layer: top)
        XCTAssertEqual(otherRule.clearance(copper: .track, nonCopper: .holeNPTH), 220_000)
        XCTAssertEqual(otherRule.clearance(copper: .track, nonCopper: .boardEdge), 300_000)
    }

    func testAClearanceWithNoRuleGetsACatchAllRule() throws {
        let edited = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .copperClearance(ruleID: nil, .track, .via, 180_000), to: [:], copperLayers: [top], newRuleID: { "made" }))
        let rule = HorizontalBoardRules(rules: edited, netDetails: [:]).clearanceCopper(net1: "a", net2: "b", layer: bottom)
        XCTAssertEqual(rule.id, "made")
        XCTAssertEqual(rule.clearance(.via, .track), 180_000)
        XCTAssertEqual(rule.clearance(.track, .track), 100_000)

        let keepout = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .keepoutClearance(ruleID: nil, keepoutClass: "shield", copper: .track, 400_000), to: [:],
            copperLayers: [top], newRuleID: { "k" }))
        let keepoutRule = HorizontalBoardRules(rules: keepout, netDetails: [:])
            .clearanceCopperKeepout(net: "a", keepoutClass: "shield")
        XCTAssertEqual(keepoutRule.id, "k")
        XCTAssertEqual(keepoutRule.clearance(.track), 400_000)
        XCTAssertEqual(HorizontalBoardRules(rules: keepout, netDetails: [:])
            .clearanceCopperKeepout(net: "a", keepoutClass: "other").id, "", "the rule takes keepouts of its class")
    }

    func testEditingAViaRulesSizeKeepsItsOtherParameters() throws {
        let stated: JSONDictionary = ["via": ["v": [
            "enabled": true, "order": 0, "match": match("all"), "padstack": "ps",
            "parameter_set": ["via_diameter": 500_000, "hole_diameter": 200_000, "via_solder_mask_expansion": 50_000]
        ] as JSONDictionary] as JSONDictionary]
        let rule = try XCTUnwrap(HorizontalBoardRules(rules: stated, netDetails: [:]).via(net: "gnd"))
        let edited = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .viaParameters(rule: rule, diameter: 600_000, holeDiameter: 300_000), to: stated, copperLayers: [top]))
        let parameters = try XCTUnwrap(edited.dictionary("via")?.dictionary("v")?.dictionary("parameter_set"))
        XCTAssertEqual(parameters.int("via_diameter"), 600_000)
        XCTAssertEqual(parameters.int("hole_diameter"), 300_000)
        XCTAssertEqual(parameters.int("via_solder_mask_expansion"), 50_000)
        XCTAssertEqual(edited.dictionary("via")?.dictionary("v")?.string("padstack"), "ps")
        XCTAssertNil(HorizontalRouteRuleEditing.applying(
            .viaParameters(rule: rule, diameter: 500_000, holeDiameter: 200_000), to: stated, copperLayers: [top]))

        // The via rule a board stating none is given at load isn't in its
        // file: the edit writes it, at the new size.
        let given = HorizontalRuleVia.horizonDefault(boardID: "board", padstackID: "ps")
        let written = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .viaParameters(rule: given, diameter: 450_000, holeDiameter: 200_000), to: [:], copperLayers: [top]))
        let reread = try XCTUnwrap(HorizontalBoardRules(rules: written, netDetails: [:]).via(net: nil))
        XCTAssertEqual(reread.id, given.id)
        XCTAssertEqual(reread.padstackID, "ps")
        XCTAssertEqual(reread.parameterSet["via_diameter"], 450_000)

        let added = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .addViaRule(padstackID: "ps", diameter: 500_000, holeDiameter: 250_000), to: [:], copperLayers: [top],
            newRuleID: { "new" }))
        let addedRule = try XCTUnwrap(HorizontalBoardRules(rules: added, netDetails: [:]).via(net: "sig"))
        XCTAssertEqual(addedRule.id, "new")
        XCTAssertEqual(addedRule.parameterSet["hole_diameter"], 250_000)
    }

    @MainActor
    func testTheInspectorSaysWhereTheViaComesFrom() {
        var board = HorizontalGerberExportFixture.board()
        board.netDetails = netDetails
        board.takeRules(trackWidthRules)
        let model = HorizontalRouteInspectorModel()
        func input(via: HorizontalBoardViaTemplate?, custom: Bool) -> HorizontalRouteInspectorInput {
            HorizontalRouteInspectorInput(
                board: board, netClasses: [], layer: top, netID: "gnd", width: 150_000,
                widthSource: .rule(id: "all"), hasStarted: true, isRouterMode: false, route: [],
                connecting: [], via: via, viaArmed: false, customVia: custom, rulesRevision: 0)
        }
        let ruled = board.routeVia(netID: "gnd")
        let fromRules = model.makeState(input(via: ruled, custom: false)).via
        XCTAssertEqual(fromRules.rule?.id, board.rules.viaRules.first?.id)
        XCTAssertEqual(fromRules.ruleBrief, "All")
        XCTAssertEqual(fromRules.diameter, 500_000)
        XCTAssertFalse(fromRules.isCustom)

        var own = ruled
        own?.diameter = 650_000
        let custom = model.makeState(input(via: own, custom: true)).via
        XCTAssertTrue(custom.isCustom)
        XCTAssertEqual(custom.diameter, 650_000)
        XCTAssertEqual(custom.ruleDiameter, 500_000, "what the rules would give")

        let none = model.makeState(input(via: nil, custom: false)).via
        XCTAssertFalse(none.canDrop)
        XCTAssertEqual(none.defaultPadstackID, board.defaultViaPadstackID)
    }

    func testABoardTakesItsRulesWithoutAReload() {
        var board = HorizontalGerberExportFixture.board()
        board.netDetails = netDetails
        board.takeRules(trackWidthRules)
        XCTAssertEqual(board.rules.trackWidth(net: "vcc", layer: top)?.rule.id, "power")
        // A board whose rules state no via rule gets Horizon's, as it does at load.
        XCTAssertEqual(board.rules.viaRules.count, 1)
        var other = HorizontalGerberExportFixture.board()
        other.takeRules(of: board)
        XCTAssertEqual(other.rules, board.rules)
    }

    // MARK: - Nearest

    private func probe(_ items: [HorizontalRouteClearanceProbe.Item]) -> HorizontalRouteClearanceProbe {
        HorizontalRouteClearanceProbe(items: items, cellSize: 500_000)
    }

    private func item(
        _ kind: HorizontalRouteClearanceProbe.Kind, _ id: String, net: String? = nil,
        layer: Int? = nil, shape: HorizontalRouteClearanceProbe.Shape, points: [HorizontalPoint]
    ) -> HorizontalRouteClearanceProbe.Item {
        HorizontalRouteClearanceProbe.Item(
            kind: kind, id: id, netID: net, label: id,
            layerMin: layer ?? bottom, layerMax: layer ?? top,
            box: HorizontalRouteClearanceProbe.bounds(points, growth: 500_000), shape: shape)
    }

    func testNearestMeasuresCopperToCopperWithTheClearanceItNeeds() throws {
        let mm = 1_000_000.0
        func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }
        // A track 1 mm above the route's centreline, 0.2 mm wide.
        let track = item(.track, "track", net: "sig", layer: top,
                         shape: .path([p(0, 1), p(5, 1)], halfWidth: 0.1 * mm), points: [p(0, 1), p(5, 1)])
        let square = [p(2, -1.5), p(3, -1.5), p(3, -0.5), p(2, -0.5)]
        let pad = item(.pad, "pad", net: "vcc", layer: top, shape: .polygon(square), points: square)
        let via = item(.via, "via", net: "gnd", shape: .disc(p(6, 0), radius: 0.25 * mm), points: [p(6, 0)])
        let ownNet = item(.track, "own", net: "gnd", layer: top,
                          shape: .path([p(0, 0.2), p(5, 0.2)], halfWidth: 0.1 * mm), points: [p(0, 0.2), p(5, 0.2)])
        let bottomTrack = item(.track, "below", net: "sig", layer: bottom,
                               shape: .path([p(0, 0), p(5, 0)], halfWidth: 0.1 * mm), points: [p(0, 0), p(5, 0)])
        let start = item(.pad, "start", net: nil, layer: top,
                         shape: .polygon([p(-0.5, -0.5), p(0.5, -0.5), p(0.5, 0.5), p(-0.5, 0.5)]), points: [p(0, 0)])
        let edge = item(.boardEdge, "edge", shape: .path([p(-10, -3), p(10, -3)], halfWidth: 0), points: [p(-10, -3), p(10, -3)])

        let measured = probe([track, pad, via, ownNet, bottomTrack, start, edge]).nearest(
            route: [[p(0, 0), p(5, 0)]], width: 0.2 * mm, layer: top, net: "gnd",
            connecting: [p(0, 0)], radius: 2 * mm
        ) { item in
            switch item.kind {
            case .pad: (0.6 * mm, 0, "pads")
            case .boardEdge: (0.3 * mm, 0, "edge")
            default: (0.15 * mm, 0, "copper")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: measured.map { ($0.objectID, $0) })
        // 1 mm between centrelines less two half widths.
        XCTAssertEqual(try XCTUnwrap(byID["track"]).gap, 0.8 * mm, accuracy: 1)
        // To the pad's edge, 0.5 mm off the centreline, less the route's half width.
        XCTAssertEqual(try XCTUnwrap(byID["pad"]).gap, 0.4 * mm, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(byID["pad"]).margin, -0.2 * mm, accuracy: 1)
        // The route ends 1 mm from the via's centre; its own net's via is
        // passed over, as is its own net's track and what it starts on.
        XCTAssertNil(byID["via"])
        XCTAssertNil(byID["own"])
        XCTAssertNil(byID["start"])
        XCTAssertNil(byID["below"], "the bottom layer's track")
        XCTAssertNil(byID["edge"], "2.9 mm off, beyond the 2 mm looked at")
        // Least margin first.
        XCTAssertEqual(measured.first?.objectID, "pad")
    }

    func testNearestKeepsTheLeastMarginOfEachKindAndTouchingCountsAsZero() throws {
        let mm = 1_000_000.0
        func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }
        let near = item(.track, "near", net: "a", layer: top,
                        shape: .path([p(0, 0.5), p(5, 0.5)], halfWidth: 0.05 * mm), points: [p(0, 0.5), p(5, 0.5)])
        let tight = item(.track, "tight", net: "b", layer: top,
                         shape: .path([p(0, -0.7), p(5, -0.7)], halfWidth: 0.05 * mm), points: [p(0, -0.7), p(5, -0.7)])
        let crossing = item(.via, "crossing", net: "c", shape: .disc(p(2, 0), radius: 0.2 * mm), points: [p(2, 0)])
        let measured = probe([near, tight, crossing]).nearest(
            route: [[p(0, 0), p(5, 0)]], width: 0.1 * mm, layer: top, net: "x", connecting: [], radius: 2 * mm
        ) { item in
            (item.id == "tight" ? 1.0 * mm : 0.1 * mm, 0, "rule")
        }
        // "near" is closer, but "tight" asks for more than it has.
        let tracks = measured.filter { $0.kind == .track }
        XCTAssertEqual(tracks.map(\.objectID), ["tight"])
        let via = try XCTUnwrap(measured.first { $0.kind == .via })
        XCTAssertLessThanOrEqual(via.gap, 0)
        XCTAssertEqual(measured.first?.objectID, "tight")
    }

    func testCopperInsideTheRoutingOffsetIsLegalButFlagged() throws {
        let mm = 1_000_000.0
        func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }
        // 0.2 mm apart, copper to copper: the rules ask 0.15, the router 0.15 + 0.1.
        let track = item(.track, "t", net: "a", layer: top,
                         shape: .path([p(0, 0.3), p(5, 0.3)], halfWidth: 0.05 * mm), points: [p(0, 0.3), p(5, 0.3)])
        let measured = try XCTUnwrap(probe([track]).nearest(
            route: [[p(0, 0), p(5, 0)]], width: 0.1 * mm, layer: top, net: "x", connecting: [], radius: 2 * mm
        ) { _ in (0.15 * mm, 0.1 * mm, "rule") }.first)
        XCTAssertEqual(measured.gap, 0.2 * mm, accuracy: 1)
        XCTAssertGreaterThan(measured.margin, 0)
        XCTAssertTrue(measured.isInsideRoutingOffset)
    }

    func testTheRulesReadTheirRoutingOffsetAndTheRouterKeepsIt() throws {
        var json = clearanceRules
        var copper = try XCTUnwrap(json["clearance_copper"] as? JSONDictionary)
        var rule = try XCTUnwrap(copper["default"] as? JSONDictionary)
        rule["routing_offset"] = 80_000
        copper["default"] = rule
        json["clearance_copper"] = copper
        let rules = HorizontalBoardRules(rules: json, netDetails: netDetails)
        XCTAssertEqual(rules.clearanceCopper(net1: "gnd", net2: "sig", layer: top).routingOffset, 80_000)
        // Left out of the file: RuleClearanceCopper's 0.05 mm, the fallback's too.
        XCTAssertEqual(rules.clearanceCopperOther(net: "gnd", layer: top).routingOffset, 50_000)
        XCTAssertEqual(HorizontalBoardRules.empty.clearanceCopper(net1: nil, net2: nil, layer: top).routingOffset, 50_000)

        let codes = [0: "gnd", 1: "sig"]
        let check = HorizontalRouterClearances(rules: rules, netIDForCode: codes)
        let router = HorizontalRouterClearances(rules: rules, netIDForCode: codes, includesRoutingOffset: true)
        XCTAssertEqual(check.clearance(.track, net: 0, .track, net: 1, on: top), 150_000, "the rules check's number")
        XCTAssertEqual(router.clearance(.track, net: 0, .track, net: 1, on: top), 230_000, "plus the routing offset")
        XCTAssertEqual(router.clearance(.track, net: 0, .boardEdge, net: -1, on: top), 350_000)
        XCTAssertEqual(router.clearance(.track, net: 0, .track, net: 0, on: top), 0, "its own net still touches")
        XCTAssertEqual(router.clearance(.track, net: 0, .keepout("shield"), net: -1, on: top), 0,
                       "no keepout rule: Horizon's router keeps nothing")

        let names = HorizontalRouteRuleNames(netDetails: netDetails, netClasses: [])
        let spacing = HorizontalRouteSpacing.make(
            net: "gnd", layer: top, rules: rules, otherNets: ["sig"], keepoutClasses: [], names: names)
        XCTAssertEqual(spacing.copperRule.routingOffset, 80_000)
        XCTAssertEqual(spacing.otherRule.routingOffset, 50_000)

        let edited = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .routingOffset(table: .copperOther, ruleID: "edge", 20_000), to: json, copperLayers: [top]))
        XCTAssertEqual(HorizontalBoardRules(rules: edited, netDetails: [:]).clearanceCopperOther(net: "gnd", layer: top).routingOffset,
                       20_000)
        let made = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            .routingOffset(table: .copper, ruleID: nil, 0), to: [:], copperLayers: [top], newRuleID: { "made" }))
        let madeRule = HorizontalBoardRules(rules: made, netDetails: [:]).clearanceCopper(net1: "a", net2: "b", layer: top)
        XCTAssertEqual(madeRule.id, "made")
        XCTAssertEqual(madeRule.routingOffset, 0)
        XCTAssertEqual(madeRule.clearance(.track, .track), 100_000, "the fallback's clearances")
    }

    func testTheProbeFindsABoardsPadsByOwnerAndThroughHolePadsByTheirHole() {
        var board = HorizontalGerberExportFixture.board()
        board.packages = [HorizontalPlacement(id: "PKG", position: .zero, angle: 0, mirrored: false, label: "R3")]
        board.packagePads = [HorizontalPolygon(
            id: "PKG/pad/P1/shape/s/layer/0",
            polygonVertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 1, y: 0), HorizontalPoint(x: 1, y: 1)]
                .map { HorizontalPolygonVertex(position: $0) },
            layer: top, netID: "VCC", metadata: ["Pad": "2"])]
        board.packageHoles = [HorizontalHole(id: "PKG/pad/P1/hole/h", position: .zero, diameter: 300_000, plated: true)]
        let items = HorizontalRouteClearanceProbe.items(of: board)
        let pad = items.first { $0.id.hasPrefix("PKG/pad") }
        XCTAssertEqual(pad?.kind, .padThroughHole)
        XCTAssertEqual(pad?.label, "Pad R3.2")
        XCTAssertEqual(pad?.netID, "vcc")
        XCTAssertFalse(items.contains { $0.kind == .hole }, "a plated hole is its pad's")
    }
}
