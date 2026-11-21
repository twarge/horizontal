import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Clearance findings that are one problem come out of the rules check as
/// one: the check's pairs that are alike and run within a quarter of a
/// millimetre of each other, folded into the worst of them.
final class BoardClearanceFindingsMergeTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func mm(_ value: Double) -> Double { value * 1_000_000 }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, net: String?, width: Double = 0.2) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: mm(width), layer: top, netID: net)
    }

    private func square(_ id: String, at center: HorizontalPoint, size: Double, layer: Int, net: String? = nil,
                        pad: String? = nil) -> HorizontalPolygon {
        let half = mm(size) / 2
        return HorizontalPolygon(
            id: id,
            vertices: [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                       HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)],
            layer: layer, netID: net, metadata: pad.map { ["Pad": $0] } ?? [:])
    }

    /// A 1 mm square pad of U1 named `name`, and the opening 0.05 mm wider
    /// each way that bares it in the top mask.
    private func barePad(_ name: String, at center: HorizontalPoint, net: String?) -> [HorizontalPolygon] {
        [square("pkg/pad/\(name)/shape/s1", at: center, size: 1, layer: top, net: net, pad: name),
         square("pkg/pad/\(name)/shape/mask", at: center, size: 1.1, layer: HorizontalBoardLayers.topMask, pad: name)]
    }

    private func silk(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: mm(0.1), layer: HorizontalBoardLayers.topSilkscreen)
    }

    private let nets = ["net-a": "A", "net-b": "B", "net-c": "C"]

    /// Copper 0.1 mm apart, as Horizon asks where no rule does, and
    /// silkscreen 0.15 mm from bare copper of any kind.
    private let rules: JSONDictionary = [
        "clearance_silkscreen_exposed_copper": ["enabled": true, "pads_only": false,
                                                "clearance_top": 150_000, "clearance_bottom": 150_000] as JSONDictionary,
    ]

    private func makeBoard(
        tracks: [HorizontalSegment] = [],
        pads: [HorizontalPolygon] = [],
        planes: [HorizontalPlane] = [],
        lines: [HorizontalSegment] = [],
        polygons: [HorizontalPolygon] = []
    ) -> HorizontalBoard {
        let outline = HorizontalPolygon(id: "outline", vertices: [p(0, 0), p(40, 0), p(40, 40), p(0, 40)],
                                        layer: HorizontalBoardLayers.outline)
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/merge.hprj"), uuid: "b", name: "merge",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:],
            netDetails: nets.reduce(into: [:]) { $0[$1.key] = HorizontalNetDetails(id: $1.key, name: $1.value) },
            tracks: tracks, netTies: [], lines: lines, arcs: [], connectionLines: [], airwires: [],
            polygons: [outline] + polygons, planes: planes, keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [HorizontalPlacement(id: "pkg", position: p(10, 10), angle: 0, mirrored: false,
                                                                    label: "U1", componentID: "comp-u1")],
            packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.takeRules(rules)
        return board
    }

    private func checked(_ board: HorizontalBoard, _ check: HorizontalClearanceFinding.Check,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [HorizontalClearanceFinding] {
        try XCTUnwrap(HorizontalBoardRulesCheck.run(board: board), file: file, line: line).clearance.filter { $0.check == check }
    }

    // MARK: On a board

    /// Silkscreen beside a track where it runs out of its net's plane, both
    /// bare in one opening of the mask, is too close to the plane's copper
    /// and to the track's: two pairs to the check, a few microns apart in
    /// what they say, and one finding, the nearer pair's, that names the
    /// other and is highlighted as far as both run.
    func testSilkscreenBesideATrackAndItsNetsPlaneIsOneFinding() throws {
        // The fill's top edge is at y = 10.4; the track's copper reaches 10.39.
        let fill = HorizontalPlaneFragment(paths: [[p(5, 5), p(10, 5), p(10, 10.4), p(5, 10.4)]], orphan: false)
        let plane = HorizontalPlane(id: "plane-gnd", netID: "net-a", polygonID: "poly", layer: top, priority: 0,
                                    fillStyle: "solid", minWidth: mm(0.2), keepOrphans: false, fragments: [fill])
        let board = makeBoard(
            tracks: [track("t-gnd", p(9.5, 10.29), p(10.6, 10.29), net: "net-a")],
            planes: [plane],
            // Its ink's lower edge is at y = 10.5.
            lines: [silk("silk", p(9.2, 10.55), p(10.6, 10.55))],
            polygons: [square("opening", at: p(10, 10), size: 2, layer: HorizontalBoardLayers.topMask)])

        let pairs = HorizontalBoardClearanceCheck.run(board: board).filter { $0.check == .silkscreen }
        XCTAssertEqual(Set(pairs.map(\.second.id)), ["plane-gnd", "t-gnd"], "the check finds each pair")
        XCTAssertTrue(pairs.allSatisfy { $0.also.isEmpty })

        let findings = try checked(board, .silkscreen)
        XCTAssertEqual(findings.count, 1, findings.map(\.title).joined(separator: "\n"))
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.first.id, "silk")
        XCTAssertEqual(finding.second.id, "plane-gnd", "the nearer of the two")
        XCTAssertEqual(finding.distance, mm(0.1), accuracy: 2)
        XCTAssertEqual(finding.title, "Line near the exposed copper of Plane (A)")
        XCTAssertEqual(finding.also.map(\.second.id), ["t-gnd"])
        XCTAssertEqual(finding.also.first?.distance ?? 0, mm(0.11), accuracy: 2)
        XCTAssertEqual(finding.detail,
                       "0.100 mm apart on Top Silkscreen, where the rules ask 0.150 mm (Silkscreen – exposed copper: 0.150 mm on the top side). "
                           + "Also too close there: Track (A), 0.110 mm apart.")

        // Both pairs' stretches, the track's edge past the end of the fill among them.
        let own = try XCTUnwrap(pairs.first { $0.second.id == "plane-gnd" }), other = try XCTUnwrap(pairs.first { $0.second.id == "t-gnd" })
        XCTAssertEqual(finding.highlights, own.violation + other.violation)
        XCTAssertGreaterThan(try XCTUnwrap(finding.highlights.flatMap { $0 }.filter { abs($0.y - mm(10.39)) < 1 }.map(\.x).max()), mm(10.5))

        // One row in the sidebar and one marker on the canvas, about both.
        let results = try XCTUnwrap(HorizontalBoardRulesCheck.run(board: board))
        let listed = results.all.filter { $0.kind == .clearanceSilkscreenExposedCopper }
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.objectIDs, ["silk", "plane-gnd", "t-gnd"])
        XCTAssertEqual(listed.first?.netIDs, ["net-a"])
        XCTAssertEqual(listed.first?.showsPlane, true)
        let markers = HorizontalCanvasWarning.markers(boardFindings: listed)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.position, finding.location)
        XCTAssertEqual(markers.first?.highlights, finding.highlights)
        XCTAssertEqual(markers.first?.messages, ["\(finding.title): \(finding.detail)"])
    }

    /// A line over two bare pads 0.2 mm apart is one finding where the pads
    /// are one net's, and one for each where they are two nets': a pad of
    /// another net is another thing to be clear of.
    func testSilkscreenOverTwoPadsIsOneFindingOnlyWhereTheyAreOneNets() throws {
        // The pads' top edges are at y = 10.5; the ink's lower edge at 10.6.
        let line = silk("silk", p(9.8, 10.65), p(11.4, 10.65))
        let oneNet = makeBoard(pads: barePad("1", at: p(10, 10), net: "net-a") + barePad("2", at: p(11.2, 10), net: "net-a"),
                               lines: [line])
        let one = try checked(oneNet, .silkscreen)
        XCTAssertEqual(one.count, 1, one.map(\.title).joined(separator: "\n"))
        XCTAssertEqual(Set(one.flatMap(\.pairs).map(\.second.label)), ["Pad U1.1", "Pad U1.2"])
        XCTAssertTrue(one[0].detail.hasSuffix("Also too close there: \(one[0].also[0].second.name), 0.100 mm apart."), one[0].detail)

        let twoNets = makeBoard(pads: barePad("1", at: p(10, 10), net: "net-a") + barePad("2", at: p(11.2, 10), net: "net-b"),
                                lines: [line])
        let two = try checked(twoNets, .silkscreen)
        XCTAssertEqual(two.map(\.second.label).sorted(), ["Pad U1.1", "Pad U1.2"])
        XCTAssertTrue(two.allSatisfy { $0.also.isEmpty })
    }

    /// The same line too close to pads of one net 5 mm apart is in two
    /// places, and a finding at each.
    func testTheSameTwoThingsTooCloseFarApartAreAFindingEach() throws {
        let board = makeBoard(pads: barePad("1", at: p(10, 10), net: "net-a") + barePad("2", at: p(15, 10), net: "net-a"),
                              lines: [silk("silk", p(9.8, 10.65), p(15.2, 10.65))])
        let findings = try checked(board, .silkscreen)
        XCTAssertEqual(findings.map(\.second.label).sorted(), ["Pad U1.1", "Pad U1.2"])
        XCTAssertTrue(findings.allSatisfy { $0.also.isEmpty })
    }

    /// A track that turns a corner round a pad, 0.05 mm from it on one side
    /// and 0.06 mm on the next, is two segments too close to the pad and
    /// one finding, the nearer segment's, saying the other is there too.
    func testATrackTurningACornerRoundAPadIsOneFinding() throws {
        // The pad's top edge is at y = 10.5 and its right edge at x = 10.5;
        // the track's copper at y = 10.55 above it and x = 10.56 beside it.
        let board = makeBoard(
            tracks: [track("t1", p(8, 10.65), p(10.66, 10.65), net: "net-b"),
                     track("t2", p(10.66, 10.65), p(10.66, 8), net: "net-b")],
            pads: [square("pkg/pad/1/shape/s1", at: p(10, 10), size: 1, layer: top, net: "net-a", pad: "1")])
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board).filter { $0.check == .copper }.map(\.first.id).sorted(), ["t1", "t2"])

        let findings = try checked(board, .copper)
        XCTAssertEqual(findings.count, 1, findings.map(\.title).joined(separator: "\n"))
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.title, "Track (B) near Pad U1.1 (A)")
        XCTAssertEqual(finding.first.id, "t1", "the nearer of the two")
        XCTAssertEqual(finding.also.map(\.first.id), ["t2"])
        XCTAssertEqual(finding.detail,
                       "0.050 mm apart on Top Copper, where the rules ask 0.100 mm (no rule, Horizon's). "
                           + "Also too close there: Track (B), 0.060 mm apart.")
        let ruleFinding = HorizontalBoardRuleFinding(finding)
        XCTAssertEqual(ruleFinding.objectIDs, ["t1", "pkg/pad/1", "t2"])
        XCTAssertEqual(ruleFinding.netIDs, ["net-b", "net-a"])
        XCTAssertEqual(ruleFinding.componentIDs, ["comp-u1"])
        // Framed on both, with the room a finding is given round it: above
        // the pad, where the one segment is nearest, and beside it.
        XCTAssertGreaterThanOrEqual(finding.region.maxY, finding.firstPoint.y + mm(1.5) - 1)
        XCTAssertLessThanOrEqual(finding.region.minY, finding.also[0].secondPoint.y - mm(1.5) + 1)
        XCTAssertGreaterThanOrEqual(finding.region.maxX, finding.also[0].firstPoint.x + mm(1.5) - 1)
    }

    // MARK: Pairs as the check gives them

    private func object(_ id: String, net: String?, type: HorizontalPatchType = .track, label: String = "Track") -> HorizontalClearanceFinding.Object {
        .init(type: type, id: id, label: label, netID: net, netName: net?.uppercased())
    }

    /// Track `id` of net a, `distance` mm above a track of net b from
    /// x = `from` to `to` mm, on the top unless told otherwise.
    private func pair(_ id: String, from: Double, to: Double, distance: Double = 0.05, nets: (String, String) = ("a", "b"),
                      layers: [Int] = [HorizontalBoardLayers.topCopper], rule: String? = nil) -> HorizontalClearanceFinding {
        HorizontalClearanceFinding(
            check: .copper, first: object(id, net: nets.0), second: object("other-\(id)", net: nets.1),
            layers: layers, layer: layers[0], distance: mm(distance), clearance: mm(0.1), ruleID: rule, ruleBrief: "",
            location: p(from, distance / 2), firstPoint: p(from, distance), secondPoint: p(from, 0),
            violation: [[p(from, distance), p(to, distance)], [p(from, 0), p(to, 0)]])
    }

    /// The worst pair of a problem stands for it, with the others worst
    /// first; findings stay in the order they came, the folded ones gone.
    func testTheWorstPairStandsForTheProblemInItsPlace() {
        let near = pair("near", from: 0, to: 1, distance: 0.02), far = pair("far", from: 1.1, to: 2, distance: 0.08)
        let middling = pair("middling", from: 2.1, to: 3, distance: 0.05)
        let elsewhere = pair("elsewhere", from: 0, to: 1, nets: ("c", "d"))

        let merged = HorizontalBoardClearanceCheck.merged([far, elsewhere, near, middling])
        XCTAssertEqual(merged.map(\.id), [elsewhere.id, near.id])
        XCTAssertEqual(merged[1].also.map(\.id), [middling.id, far.id])
        XCTAssertEqual(merged[1].pairs.map(\.id), [near.id, middling.id, far.id])
        XCTAssertEqual(merged[1].detail.components(separatedBy: "Also too close there: ").last,
                       "Track (A) and Track (B), 0.050 mm apart; Track (A) and Track (B), 0.080 mm apart.")
        XCTAssertTrue(merged[0].also.isEmpty)
    }

    /// Findings joined a quarter of a millimetre at a time are one as far
    /// as the chain runs, and no further; past the first few, the rest are
    /// counted.
    func testFindingsJoinedInAChainAreOne() {
        let chain = (0..<6).map { pair("link-\($0)", from: Double($0) * 1.2, to: Double($0) * 1.2 + 1, distance: 0.05 + Double($0) / 1000) }
        // 0.3 mm past the last link.
        let apart = pair("apart", from: 7.3, to: 8)
        let merged = HorizontalBoardClearanceCheck.merged(chain + [apart])
        XCTAssertEqual(merged.map(\.id), [chain[0].id, apart.id])
        XCTAssertEqual(merged[0].also.count, 5)
        XCTAssertTrue(merged[0].detail.hasSuffix("; and 2 more."), merged[0].detail)
        XCTAssertEqual(merged[0].highlights.count, 12)
    }

    /// Pairs on other layers, under another rule or between other nets are
    /// other problems, however near; the nets may be either way round.
    func testOnlyFindingsAlikeAreOne() {
        let one = pair("one", from: 0, to: 1)
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged([one, pair("bottom", from: 0, to: 1, layers: [HorizontalBoardLayers.bottomCopper])]).count, 2)
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged([one, pair("ruled", from: 0, to: 1, rule: "rule-1")]).count, 2)
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged([one, pair("other", from: 0, to: 1, nets: ("a", "c"))]).count, 2)
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged([one, pair("turned", from: 0, to: 1, nets: ("b", "a"))]).count, 1)

        // What has no net is alike by its kind and label, not by being netless.
        var hole = pair("hole", from: 0, to: 1), another = pair("another", from: 0, to: 1)
        hole.second = object("h1", net: nil, type: .holeNPTH, label: "Hole J1")
        another.second = object("h2", net: nil, type: .holeNPTH, label: "Hole J1")
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged([hole, another]).count, 1)
        another.second.label = "Hole J2"
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged([hole, another]).count, 2)
    }

    /// Merged findings merged again are the same findings.
    func testMergingAgainChangesNothing() {
        let findings = [pair("near", from: 0, to: 1, distance: 0.02), pair("far", from: 1.1, to: 2, distance: 0.08),
                        pair("elsewhere", from: 0, to: 1, nets: ("c", "d"))]
        let merged = HorizontalBoardClearanceCheck.merged(findings)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(HorizontalBoardClearanceCheck.merged(merged), merged)
    }

    // MARK: MCP

    /// `check` gives a problem as one error, the pairs it stands for in its
    /// `also` and its detail.
    func testCheckListsThePairsAFindingStandsFor() throws {
        let merged = HorizontalBoardClearanceCheck.merged([pair("near", from: 0, to: 1, distance: 0.02), pair("far", from: 1.1, to: 2, distance: 0.08)])
        let messages = HorizontalDispatchChecks.clearanceMessages(merged)
        XCTAssertEqual(messages.count, 1)
        let json = try XCTUnwrap(messages.first?.json)
        XCTAssertEqual(json.dictionary("first")?.string("id"), "near")
        XCTAssertEqual(json.double("distance_mm") ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertTrue(json.string("detail")?.contains("Also too close there: Track (A) and Track (B), 0.080 mm apart.") ?? false, "\(json)")
        let also = try XCTUnwrap(json["also"] as? [JSONDictionary])
        XCTAssertEqual(also.count, 1)
        XCTAssertEqual(also[0].dictionary("first")?.string("id"), "far")
        XCTAssertEqual(also[0].dictionary("second")?.string("id"), "other-far")
        XCTAssertEqual(also[0].double("distance_mm") ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(also[0].double("x_mm") ?? 0, 1.1, accuracy: 1e-9)
        XCTAssertNil(HorizontalDispatchChecks.clearanceJSON(pair("alone", from: 0, to: 1))["also"])
    }
}
