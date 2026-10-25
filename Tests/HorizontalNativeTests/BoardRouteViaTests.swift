import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The via a route drops with `v`, as Horizon's router drops one: `v` arms it,
/// the next click lays the route and drops it at the end of what it laid, and
/// the route goes on from it on the far layer. Its shape is the first enabled
/// via rule's that takes the route's net, and it is written so that it goes
/// on taking its shape from the rules.
///
/// Before, `v` dropped the via at once at the route's last point, so a route
/// started on a pad got its via in the pad; every route via took the padstack
/// and size of the board's first via definition or first via, whatever the
/// rules said; and a board with neither, as a new one is, got no via at all.
final class BoardRouteViaTests: XCTestCase {
    private let gnd = "6d1f3c2a-0b4e-4f6a-8c1d-2e3f4a5b6c7d"
    private let boardVia = HorizontalBoardViaTemplate(padstackID: "board-via", diameter: 450_000, holeDiameter: 250_000)

    private func rule(
        order: Int,
        match: [String: Any] = ["mode": "all"],
        padstack: String,
        diameter: Int = 500_000,
        hole: Int = 200_000,
        enabled: Bool = true
    ) -> [String: Any] {
        [
            "enabled": enabled,
            "order": order,
            "match": match,
            "padstack": padstack,
            "parameter_set": ["via_diameter": diameter, "hole_diameter": hole]
        ]
    }

    private func routeVia(net: String?, rules: [String: Any], template: HorizontalBoardViaTemplate? = nil) -> HorizontalBoardViaTemplate? {
        BoardTrackRouting.routeVia(
            netID: net,
            rules: HorizontalBoardRules(rules: ["via": rules], netDetails: [:]),
            template: template ?? boardVia
        )
    }

    func testTheFirstRuleThatTakesTheNetShapesItsVia() throws {
        let rules: [String: Any] = [
            "r-gnd": rule(order: 0, match: ["mode": "net", "net": gnd], padstack: "gnd-via", diameter: 800_000, hole: 400_000),
            "r-all": rule(order: 1, padstack: "small-via")
        ]
        let ground = try XCTUnwrap(routeVia(net: gnd.uppercased(), rules: rules))
        XCTAssertEqual(ground.padstackID, "gnd-via")
        XCTAssertEqual(ground.diameter, 800_000)
        XCTAssertEqual(ground.holeDiameter, 400_000)
        XCTAssertTrue(ground.fromRules, "so it goes on taking its shape from the rules")
        XCTAssertEqual(ground.parameterSet, ["via_diameter": 800_000, "hole_diameter": 400_000])

        let other = try XCTUnwrap(routeVia(net: "another-net", rules: rules))
        XCTAssertEqual(other.padstackID, "small-via", "a net the first rule does not take falls to the next")
        XCTAssertEqual(other.diameter, 500_000)
        XCTAssertNotEqual(other.padstackID, boardVia.padstackID, "and never to the board's own vias")
    }

    func testADisabledRuleTakesNoNet() throws {
        let rules: [String: Any] = [
            "r-off": rule(order: 0, padstack: "off-via", enabled: false),
            "r-on": rule(order: 1, padstack: "on-via")
        ]
        XCTAssertEqual(routeVia(net: gnd, rules: rules)?.padstackID, "on-via")
    }

    /// Horizon drops no via where the rules give none: a rule that takes the
    /// net but names no padstack, or no rule that takes it.
    func testWhereTheRulesGiveNoPadstackThereIsNoVia() {
        let nullPadstack: [String: Any] = ["r": rule(order: 0, padstack: "00000000-0000-0000-0000-000000000000")]
        XCTAssertNil(routeVia(net: gnd, rules: nullPadstack))
        let otherNet: [String: Any] = ["r": rule(order: 0, match: ["mode": "net", "net": gnd], padstack: "gnd-via")]
        XCTAssertNil(routeVia(net: "another-net", rules: otherNet), "not the board's own via's shape")
    }

    /// A board whose rules say nothing about vias, and whose pool names no
    /// default via, still gets a via: the shape its own vias have. One whose
    /// via rules were all removed states none, and gets none, as in Horizon.
    func testRulesSayingNothingOfViasTakeTheBoardsOwnViaAndNoViaRulesGiveNone() throws {
        let unstated = HorizontalBoardRules(rules: [:], netDetails: [:])
        XCTAssertFalse(unstated.statesViaRules)
        let via = try XCTUnwrap(BoardTrackRouting.routeVia(netID: gnd, rules: unstated, template: boardVia))
        XCTAssertEqual(via, boardVia)
        XCTAssertFalse(via.fromRules)
        XCTAssertNil(BoardTrackRouting.routeVia(netID: gnd, rules: unstated, template: nil))
        XCTAssertNil(routeVia(net: gnd, rules: [:]), "via rules all removed: none, not the board's own via")
    }

    /// Writes a project as Horizontal's template wrote one before it gave a
    /// new board Horizon's via rule: no via rules, no vias, no definitions,
    /// and the stock pool's default via. Returns its URL.
    private func oldTemplateProject(rules: [String: Any] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-old-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        let pool = HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia)
        try HorizontalProjectArchive.newProject(pool: pool).write(to: url)
        let boardURL = url.appendingPathComponent("board.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        json["rules"] = rules
        try JSONSerialization.data(withJSONObject: json).write(to: boardURL)
        return url
    }

    private func viaRules(in archive: HorizontalProjectArchive) throws -> [String: Any]? {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json["rules"] as? [String: Any])?["via"] as? [String: Any]
    }

    /// The board `v` gave no via on, then a custom one: it gets the via rule
    /// Horizon would have given it, with the pool's default via tented, so a
    /// route's via is the rules', and the board's next save writes the rule.
    func testABoardWrittenWithNoViaRulesGetsHorizonsDefaultRuleWrittenOnItsNextSave() throws {
        let url = try oldTemplateProject()
        let project = try HorizontalProject.load(from: url)
        let board = try XCTUnwrap(project.board)
        XCTAssertFalse(board.rules.statesViaRules)
        XCTAssertNil(board.viaTemplate)
        XCTAssertEqual(board.defaultViaPadstackID, HorizontalProjectArchive.horizonPoolTentedCircularVia, "the stock via, tented")
        let rule = try XCTUnwrap(board.rules.viaRules.first)
        XCTAssertEqual(board.rules.viaRules.count, 1)
        XCTAssertEqual(rule.padstackID, HorizontalProjectArchive.horizonPoolTentedCircularVia)
        XCTAssertEqual(try HorizontalProject.load(from: url).board?.rules.viaRules.first?.id, rule.id, "the same rule on every load")

        let via = try XCTUnwrap(board.routeVia(netID: gnd))
        XCTAssertTrue(via.fromRules, "from rules, not custom")
        XCTAssertEqual(via.padstackID, HorizontalProjectArchive.horizonPoolTentedCircularVia)
        XCTAssertEqual(via.diameter, 500_000)
        XCTAssertEqual(via.holeDiameter, 200_000)

        // Opening it writes nothing; its next save, of anything, writes the rule.
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        XCTAssertNil(try viaRules(in: archive))
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let written = try XCTUnwrap(try viaRules(in: archive))
        XCTAssertEqual(Array(written.keys), [rule.id])
        let entry = try XCTUnwrap(written[rule.id] as? [String: Any])
        XCTAssertEqual(entry["padstack"] as? String, HorizontalProjectArchive.horizonPoolTentedCircularVia)
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["order"] as? Int, 0)
        let match = try XCTUnwrap(entry["match"] as? [String: Any])
        XCTAssertEqual(match["mode"] as? String, "all")
        XCTAssertEqual(match["net"] as? String, HorizontalProjectArchive.nullUUID)
        XCTAssertEqual(match["net_class"] as? String, HorizontalProjectArchive.nullUUID)
        XCTAssertEqual(match["net_name_regex"] as? String, "")
        let parameters = try XCTUnwrap(entry["parameter_set"] as? [String: Any])
        XCTAssertEqual(parameters["via_diameter"] as? Int, 500_000)
        XCTAssertEqual(parameters["hole_diameter"] as? Int, 200_000)

        // Read back, the rule is the file's, and saving again leaves it be.
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        let read = try XCTUnwrap(reloaded.board)
        XCTAssertTrue(read.rules.statesViaRules)
        XCTAssertEqual(read.rules.viaRules.map(\.id), [rule.id])
        try HorizontalProjectJSONApplicator.apply(board: read, in: reloaded, to: &archive)
        XCTAssertEqual(try viaRules(in: archive)?.count, 1)
    }

    /// A board whose via rules were all removed in the Rules editor states an
    /// empty set, and it stays empty: no rule comes back on load or on save.
    func testABoardWhoseViaRulesWereAllRemovedKeepsNone() throws {
        let url = try oldTemplateProject(rules: ["via": [String: Any]()])
        let project = try HorizontalProject.load(from: url)
        let board = try XCTUnwrap(project.board)
        XCTAssertTrue(board.rules.statesViaRules)
        XCTAssertTrue(board.rules.viaRules.isEmpty)
        XCTAssertNil(board.routeVia(netID: gnd))
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try viaRules(in: archive)?.count, 0)
    }

    /// The Rules editor starts a new via rule with the board's default via,
    /// as Horizon's starts one with the pool's, where it was left blank.
    func testTheRulesEditorStartsANewViaRuleWithTheDefaultVia() throws {
        let board = try XCTUnwrap(HorizontalProject.load(from: try oldTemplateProject()).board)
        let rule = HorizontalBoardRuleKind.via.defaultRule(context: HorizontalBoardRuleContext(board: board, netClasses: []), order: 0)
        XCTAssertEqual(rule["padstack"] as? String, HorizontalProjectArchive.horizonPoolTentedCircularVia)
    }

    func testRulesSharingAnOrderAreTakenByID() {
        let rules: [String: Any] = ["b": rule(order: 0, padstack: "b-via"), "a": rule(order: 0, padstack: "a-via")]
        XCTAssertEqual(routeVia(net: gnd, rules: rules)?.padstackID, "a-via", "whatever order the file's map comes back in")
    }

    // MARK: - Laid by a click

    private let padCenter = HorizontalPoint(x: 10_000_000, y: 10_000_000)
    private let groundVia = HorizontalBoardViaTemplate(
        padstackID: "gnd-via", diameter: 800_000, holeDiameter: 400_000, fromRules: true,
        parameterSet: ["via_diameter": 800_000, "hole_diameter": 400_000])

    /// A two-layer board with nothing on it but what a route lays.
    private func emptyBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/route-via.hprj"), uuid: "b", name: "route-via",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    /// The head of a route started on a ground test pad, as the first click
    /// leaves it, with `v` pressed.
    private func headOnThePad(placesVia: Bool = true) -> BoardTrackRouteHead {
        BoardTrackRouteHead(
            anchor: padCenter, anchorJunctionID: nil, anchorOnPad: true, netID: gnd,
            width: 200_000, layer: HorizontalBoardLayers.topCopper, placesVia: placesVia)
    }

    private func legs(from: HorizontalPoint, to: HorizontalPoint) -> [BoardTrackSegmentSpec] {
        BoardTrackRouting.route(from: from, to: to, horizontalFirst: true, cornerStyle: .ninety)
    }

    private func touches(_ tracks: [HorizontalSegment], _ point: HorizontalPoint) -> Bool {
        tracks.contains { $0.from == point || $0.to == point }
    }

    /// The case that went wrong: a route from a pad with `v` pressed got its
    /// via in the pad, at once, before the route went anywhere.
    func testTheArmedViaGoesWhereTheClickTakesTheRouteNotInThePadItStartedOn() throws {
        var board = emptyBoard()
        let target = HorizontalPoint(x: 15_000_000, y: 12_000_000)
        let laid = BoardTrackRouting.lay(
            legs(from: padCenter, to: target), to: target, endsOnPad: false, via: groundVia,
            from: headOnThePad(), on: &board)

        XCTAssertEqual(laid.vias, 1)
        XCTAssertEqual(laid.segments, 2, "the two legs of a 90° route")
        let via = try XCTUnwrap(board.vias.first)
        XCTAssertEqual(via.position, target, "at the end of what the click laid")
        XCTAssertFalse(board.vias.contains { $0.position == padCenter }, "and none in the pad")
        XCTAssertEqual(via.padstackID, "gnd-via")
        XCTAssertEqual(via.size, 800_000)
        XCTAssertEqual(via.holeSize, 400_000)
        XCTAssertTrue(via.fromRules)
        XCTAssertEqual(via.netID, gnd)
        XCTAssertEqual(via.netSetID, gnd)
        XCTAssertEqual(via.connectedLayers, [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper])
        XCTAssertEqual(board.viaHoles.map(\.position), [target])
        XCTAssertEqual(board.viaHoles.first?.diameter, 400_000)

        XCTAssertTrue(board.tracks.allSatisfy { $0.layer == HorizontalBoardLayers.topCopper && $0.netID == gnd })
        XCTAssertTrue(touches(board.tracks, padCenter), "the route leaves the pad")
        XCTAssertTrue(touches(board.tracks, target), "and reaches the via")
        XCTAssertFalse(board.junctions.values.contains(padCenter), "the pad takes the route with no junction on it")

        XCTAssertEqual(laid.head.anchor, target, "the route goes on from the via")
        XCTAssertEqual(laid.head.layer, HorizontalBoardLayers.bottomCopper, "on the far side")
        XCTAssertFalse(laid.head.placesVia, "the via is dropped, not armed for the next click too")
        XCTAssertFalse(laid.head.anchorOnPad)
        let junction = try XCTUnwrap(laid.head.anchorJunctionID)
        XCTAssertEqual(board.junctions[junction], target, "from the via's junction")
        XCTAssertEqual(board.junctionNetIDs[junction], gnd)

        // The next click lays on the bottom from the via, and drops no via.
        let next = HorizontalPoint(x: 15_000_000, y: 18_000_000)
        let more = BoardTrackRouting.lay(
            legs(from: target, to: next), to: next, endsOnPad: false, via: groundVia, from: laid.head, on: &board)
        XCTAssertEqual(more.vias, 0)
        XCTAssertEqual(board.vias.count, 1)
        let bottom = board.tracks.filter { $0.layer == HorizontalBoardLayers.bottomCopper }
        XCTAssertTrue(touches(bottom, target), "the bottom leg leaves the via")
        XCTAssertTrue(touches(bottom, next))
        XCTAssertEqual(board.junctions.values.filter { $0 == target }.count, 1, "the via and both legs share one junction")
    }

    /// A click on the end of the route itself, with a via armed, drops it
    /// there: on the track or via the route began from.
    func testAClickOnTheEndOfTheRouteDropsTheArmedViaThere() throws {
        var board = emptyBoard()
        let trackEnd = HorizontalPoint(x: 4_000_000, y: 4_000_000)
        board.junctions["end"] = trackEnd
        board.junctionNetIDs["end"] = gnd
        var head = headOnThePad()
        head.anchor = trackEnd
        head.anchorJunctionID = "end"
        head.anchorOnPad = false

        let laid = BoardTrackRouting.lay([], to: trackEnd, endsOnPad: false, via: groundVia, from: head, on: &board)
        XCTAssertEqual(laid.segments, 0)
        XCTAssertEqual(laid.vias, 1)
        XCTAssertEqual(board.vias.first?.position, trackEnd)
        XCTAssertEqual(laid.head.anchorJunctionID, "end", "on the junction already there")
        XCTAssertEqual(board.junctions.count, 1)
        XCTAssertEqual(laid.head.layer, HorizontalBoardLayers.bottomCopper)
    }

    /// No via goes in a pad: not in the one the route starts on, nor in one a
    /// click ends it on. And with no via to drop, the armed one stays armed.
    func testNoViaGoesInAPadAndNoneIsDroppedWithoutAShape() throws {
        var board = emptyBoard()
        for endsOnPad in [true, false] {
            let onPad = BoardTrackRouting.lay([], to: padCenter, endsOnPad: endsOnPad, via: groundVia, from: headOnThePad(), on: &board)
            XCTAssertEqual(onPad.vias + onPad.segments, 0)
            XCTAssertEqual(onPad.head, headOnThePad(), "still armed, on the pad")
            XCTAssertTrue(board.vias.isEmpty && board.junctions.isEmpty)
        }

        let otherPad = HorizontalPoint(x: 20_000_000, y: 10_000_000)
        let ended = BoardTrackRouting.lay(
            legs(from: padCenter, to: otherPad), to: otherPad, endsOnPad: true, via: groundVia, from: headOnThePad(), on: &board)
        XCTAssertEqual(ended.vias, 0)
        XCTAssertTrue(board.vias.isEmpty, "the pad it ends on takes the route")
        XCTAssertEqual(ended.head.layer, HorizontalBoardLayers.topCopper)

        var unshaped = emptyBoard()
        let target = HorizontalPoint(x: 15_000_000, y: 10_000_000)
        let laid = BoardTrackRouting.lay(
            legs(from: padCenter, to: target), to: target, endsOnPad: false, via: nil, from: headOnThePad(), on: &unshaped)
        XCTAssertEqual(laid.vias, 0)
        XCTAssertTrue(laid.head.placesVia)
        XCTAssertEqual(laid.head.layer, HorizontalBoardLayers.topCopper)
    }

    /// Without `v`, a click lays the route as it always has.
    func testWithoutAViaArmedAClickOnlyLaysTheRoute() {
        var board = emptyBoard()
        let target = HorizontalPoint(x: 15_000_000, y: 12_000_000)
        let laid = BoardTrackRouting.lay(
            legs(from: padCenter, to: target), to: target, endsOnPad: false, via: groundVia,
            from: headOnThePad(placesVia: false), on: &board)
        XCTAssertEqual(laid.vias, 0)
        XCTAssertTrue(board.vias.isEmpty)
        XCTAssertEqual(laid.segments, 2)
        XCTAssertEqual(laid.head.anchor, target)
        XCTAssertEqual(laid.head.layer, HorizontalBoardLayers.topCopper)
        XCTAssertNotNil(laid.head.anchorJunctionID)
    }

    // MARK: - Written

    /// A new board's via rule, and the via a route drops from it, through the
    /// writer the canvas saves with. The writer used to give every new via
    /// the board's via template's padstack and skip writing any when the
    /// board had none, as a new board has not.
    func testARouteViaIsWrittenWithItsRulesPadstackAndKeepsTakingItFromTheRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-route-via-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        let defaultVia = "1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c"
        try HorizontalProjectArchive.newProject(pool: HorizontalProjectPoolTemplate(defaultViaUUID: defaultVia)).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        var board = try XCTUnwrap(project.board)
        XCTAssertTrue(board.vias.isEmpty)
        XCTAssertNil(board.viaTemplate, "no via to copy a shape from, which is the case that got no via")
        let via = try XCTUnwrap(board.routeVia(netID: nil), "the new board's via rule gives one")
        XCTAssertEqual(via.padstackID, defaultVia)
        XCTAssertTrue(via.fromRules)

        // What the canvas drops: the via, at a junction of its own.
        let position = HorizontalPoint(x: 5_000_000, y: 3_000_000)
        board.junctions["route-junction"] = position
        board.vias.append(HorizontalMarker(
            id: "route-via", position: position, size: via.diameter, holeSize: via.holeDiameter, layer: nil,
            connectedLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper],
            padstackID: via.padstackID, fromRules: via.fromRules, parameterSet: via.parameterSet
        ))
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)

        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try XCTUnwrap((json["vias"] as? [String: Any])?["route-via"] as? [String: Any])
        XCTAssertEqual(entry["padstack"] as? String, defaultVia)
        XCTAssertEqual(entry["source"] as? String, "rules")
        XCTAssertEqual(entry["from_rules"] as? Bool, true)
        let parameters = try XCTUnwrap(entry["parameter_set"] as? [String: Any])
        XCTAssertEqual(parameters["via_diameter"] as? Int, 500_000)
        XCTAssertEqual(parameters["hole_diameter"] as? Int, 200_000)

        let reloaded = try HorizontalProject.loadSnapshot(of: archive)
        let read = try XCTUnwrap(reloaded.board?.vias.first { $0.id == "route-via" })
        XCTAssertEqual(read.position, position)
        XCTAssertEqual(read.padstackID, defaultVia)
        XCTAssertTrue(read.fromRules)
        XCTAssertEqual(read.size, 500_000)
    }
}
