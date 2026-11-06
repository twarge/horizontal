import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Horizon's board rules checks beyond copper clearance, on boards built here:
/// track width, hole size, copper to keepout, same net, silkscreen to exposed
/// copper, connectivity, preflight, plane fill order, net ties and height
/// restrictions; Horizontal's own copper checks; and where they surface.
final class HorizontalBoardRulesCheckTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func mm(_ value: Double) -> Double { value * 1_000_000 }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, net: String?, width: Double = 0.2,
                       layer: Int = HorizontalBoardLayers.topCopper) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: mm(width), layer: layer, netID: net)
    }

    private func square(_ center: HorizontalPoint, _ size: Double) -> [HorizontalPoint] {
        let half = mm(size) / 2
        return [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)]
    }

    /// A square pad of `size` mm centred on `center`.
    private func pad(_ id: String, at center: HorizontalPoint, size: Double = 1, net: String?,
                     layer: Int? = HorizontalBoardLayers.topCopper) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: square(center, size), layer: layer, netID: net, metadata: ["Pad": "1"])
    }

    private func via(_ id: String, at center: HorizontalPoint, diameter: Double = 0.6, net: String?) -> HorizontalMarker {
        HorizontalMarker(id: id, position: center, size: mm(diameter), holeSize: mm(0.3), layer: top,
                         connectedLayers: [top, bottom], netID: net)
    }

    private func polygon(_ id: String, _ vertices: [HorizontalPoint], layer: Int) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: vertices, layer: layer)
    }

    private func plane(_ id: String, net: String?, outline: [HorizontalPoint], priority: Int = 0,
                       fragments: [[[HorizontalPoint]]]? = nil, layer: Int = HorizontalBoardLayers.topCopper) -> HorizontalPlane {
        HorizontalPlane(
            id: id, netID: net, polygonID: "\(id)-polygon", layer: layer, priority: priority, fillStyle: "solid",
            minWidth: 0, keepOrphans: false,
            fragments: (fragments ?? [[outline]]).map { HorizontalPlaneFragment(paths: $0, orphan: false) },
            fallbackPolygon: HorizontalPolygon(id: "\(id)-polygon", vertices: outline, layer: layer))
    }

    /// A 40 mm square outline, its corner at the origin.
    private let outline = HorizontalPolygon(
        id: "outline",
        vertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 40_000_000, y: 0),
                   HorizontalPoint(x: 40_000_000, y: 40_000_000), HorizontalPoint(x: 0, y: 40_000_000)],
        layer: HorizontalBoardLayers.outline
    )

    private let nets = ["net-a": "A", "net-b": "B", "net-c": "C"]

    private let package = HorizontalPlacement(id: "pkg", position: HorizontalPoint(x: 10_000_000, y: 10_000_000),
                                              angle: 0, mirrored: false, label: "U1", componentID: "comp-u1")

    private func makeBoard(
        tracks: [HorizontalSegment] = [],
        netTies: [HorizontalSegment] = [],
        lines: [HorizontalSegment] = [],
        airwires: [HorizontalSegment] = [],
        polygons: [HorizontalPolygon]? = nil,
        pads: [HorizontalPolygon] = [],
        vias: [HorizontalMarker] = [],
        holes: [HorizontalHole] = [],
        viaHoles: [HorizontalHole] = [],
        packageHoles: [HorizontalHole] = [],
        planes: [HorizontalPlane] = [],
        keepouts: [HorizontalKeepout] = [],
        packages: [HorizontalPlacement]? = nil,
        packagePolygons: [HorizontalPolygon] = [],
        packageTexts: [HorizontalText] = [],
        texts: [HorizontalText] = [],
        junctions: [String: HorizontalPoint] = [:],
        junctionNetIDs: [String: String] = [:],
        rules: JSONDictionary = [:]
    ) -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/rules-check.hprj"), uuid: "b", name: "rules",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_600_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: junctionNetIDs,
            netDetails: nets.reduce(into: [:]) { $0[$1.key] = HorizontalNetDetails(id: $1.key, name: $1.value) },
            tracks: tracks, netTies: netTies, lines: lines, arcs: [], connectionLines: [], airwires: airwires,
            polygons: polygons ?? [outline], planes: planes, keepouts: keepouts, dimensions: [], decals: [], holes: holes,
            vias: vias, viaHoles: viaHoles, packages: packages ?? [package],
            packagePads: pads, packageHoles: packageHoles,
            packagePolygons: packagePolygons, packageLines: [], packageArcs: [], packageTexts: packageTexts, texts: texts,
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.takeRules(rules)
        return board
    }

    private func findings(_ board: HorizontalBoard, _ kind: HorizontalBoardRuleKind?) -> [HorizontalBoardRuleFinding] {
        let results = HorizontalBoardRulesCheck.run(board: board)
        return (results?.all ?? []).filter { $0.kind == kind }
    }

    /// The checks of one kind of rule only, the rest off.
    private func only(_ rules: JSONDictionary) -> JSONDictionary {
        var all: JSONDictionary = [
            "preflight_checks": ["enabled": false],
            "board_connectivity": ["enabled": false],
            "net_ties": ["enabled": false],
            "height_restrictions": ["enabled": false],
            "clearance_silkscreen_exposed_copper": ["enabled": false],
        ]
        all.merge(rules) { _, new in new }
        return all
    }

    private let matchAll: JSONDictionary = ["mode": "all"]

    // MARK: Track width

    func testATrackOutsideItsRulesWidthsIsAnError() {
        let rules = only([
            "track_width": [
                "a-only": ["enabled": true, "order": 0, "match": ["mode": "net", "net": "net-a"],
                           "widths": ["0": ["min": 300_000, "max": 500_000, "def": 400_000]]] as JSONDictionary,
                "all": ["enabled": true, "order": 1, "match": matchAll,
                        "widths": ["0": ["min": 100_000, "max": 1_000_000, "def": 200_000]]] as JSONDictionary,
            ] as JSONDictionary,
        ])
        let board = makeBoard(tracks: [
            track("narrow-a", p(1, 1), p(5, 1), net: "net-a", width: 0.2),
            track("ok-a", p(1, 2), p(5, 2), net: "net-a", width: 0.4),
            track("ok-b", p(1, 3), p(5, 3), net: "net-b", width: 0.2),
            track("wide-b", p(1, 4), p(5, 4), net: "net-b", width: 1.5),
            // A layer the rule leaves out has Horizon's 0.1 to 10 mm.
            track("bottom-b", p(1, 5), p(5, 5), net: "net-b", width: 0.05, layer: bottom),
        ], rules: rules)

        let found = findings(board, .trackWidth)
        XCTAssertEqual(Set(found.flatMap(\.objectIDs)), ["narrow-a", "wide-b", "bottom-b"], found.map(\.message).joined(separator: "\n"))
        let narrow = found.first { $0.objectIDs == ["narrow-a"] }
        XCTAssertEqual(narrow?.message, "Track width 0.200 mm is less than 0.300 mm")
        XCTAssertEqual(narrow?.ruleID, "a-only", "the first rule by order that takes the net")
        XCTAssertEqual(narrow?.level, .error)
        XCTAssertEqual(narrow?.location, p(3, 1))
        XCTAssertEqual(found.first { $0.objectIDs == ["wide-b"] }?.message, "Track width 1.500 mm is greater than 1.000 mm")
    }

    // MARK: Hole size

    func testHolesOutsideTheirRulesDiametersAreErrors() {
        let rules = only([
            "hole_size": [
                "all": ["enabled": true, "order": 0, "match": matchAll,
                        "diameter_min": 250_000, "diameter_max": 3_000_000] as JSONDictionary,
            ] as JSONDictionary,
        ])
        let board = makeBoard(
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), size: 6, net: "net-a", layer: nil)],
            vias: [via("v1", at: p(20, 20), net: "net-b")],
            holes: [HorizontalHole(id: "mount", position: p(30, 30), diameter: mm(3.2), plated: false)],
            viaHoles: [HorizontalHole(id: "v1/hole", position: p(20, 20), diameter: mm(0.2), plated: true)],
            packageHoles: [HorizontalHole(id: "pkg/pad/p1/hole/h1", position: p(10, 10), diameter: mm(1), plated: true)],
            rules: rules)

        let found = findings(board, .holeSize)
        XCTAssertEqual(found.map(\.message).sorted(), [
            "Hole diameter 3.200 mm is greater than 3.000 mm",
            "Via diameter 0.200 mm is less than 0.250 mm",
        ])
        XCTAssertEqual(found.first { $0.objectIDs == ["v1/hole"] }?.netIDs, ["net-b"], "a via's hole is on its net")
    }

    // MARK: Keepouts

    private func keepout(_ id: String, _ ring: [HorizontalPoint], layer: Int = HorizontalBoardLayers.topCopper,
                         allLayers: Bool = false, types: [String] = ["track", "pad", "pad_th", "via", "plane", "hole_pth"],
                         keepoutClass: String = "") -> HorizontalKeepout {
        HorizontalKeepout(id: id, polygonID: "\(id)-polygon", polygon: polygon("\(id)-polygon", ring, layer: layer),
                          keepoutClass: keepoutClass, allCopperLayers: allLayers, exposedCopperOnly: false,
                          copperPatchTypes: types)
    }

    func testCopperNearOrInAKeepoutIsAnErrorByTheKeepoutRule() {
        // Keepout from x 10 to 14, y 10 to 14 on the top.
        let ring = [p(10, 10), p(14, 10), p(14, 14), p(10, 14)]
        let rules = only([
            "clearance_copper_keepout": [
                "rule": ["enabled": true, "order": 0, "match": matchAll,
                         "match_keepout": ["mode": "all"], "clearances": ["track": 300_000]] as JSONDictionary,
            ] as JSONDictionary,
        ])
        let board = makeBoard(
            tracks: [
                // 0.2 mm off the keepout's left side: inside the 0.3 mm.
                track("near", p(9.7, 11), p(9.7, 13), net: "net-a"),
                // Through it.
                track("through", p(8, 12), p(16, 12), net: "net-b"),
                // 1 mm off: clear.
                track("clear", p(8.9, 15), p(8.9, 20), net: "net-a"),
                // On the bottom, which the keepout leaves alone.
                track("under", p(11, 11), p(13, 13), net: "net-a", layer: bottom),
            ],
            // A pad across the keepout's right edge, its corners outside: the
            // rule asks nothing of a pad, so only the overlap counts.
            pads: [HorizontalPolygon(id: "pkg/pad/p1/shape/s1",
                                     vertices: [p(13, 12), p(14, 11), p(15, 12), p(14, 13)],
                                     layer: top, netID: "net-c", metadata: ["Pad": "1"])],
            // A via, which this keepout doesn't list.
            vias: [via("v1", at: p(12, 10.5), net: "net-a")],
            keepouts: [keepout("k", ring, types: ["track", "pad"])],
            rules: rules)

        let found = findings(board, .clearanceCopperKeepout).compactMap(\.clearance)
        XCTAssertEqual(Set(found.map(\.first.id)), ["near", "through", "pkg/pad/p1"], found.map(\.title).joined(separator: "\n"))
        let near = found.first { $0.first.id == "near" }
        XCTAssertEqual(near?.distance ?? 0, mm(0.2), accuracy: 1)
        XCTAssertEqual(near?.clearance, mm(0.3))
        XCTAssertEqual(near?.ruleID, "rule")
        XCTAssertEqual(near?.check, .keepout)
        XCTAssertEqual(found.first { $0.first.id == "through" }?.distance, 0)
        let padFinding = found.first { $0.first.id == "pkg/pad/p1" }
        XCTAssertEqual(padFinding?.distance, 0, "the pad crosses the edge")
        XCTAssertEqual(padFinding?.clearance, 0)
    }

    func testAKeepoutRuleTakesOnlyItsKeepoutClass() {
        let ring = [p(10, 10), p(14, 10), p(14, 14), p(10, 14)]
        let rules = only([
            "clearance_copper_keepout": [
                "rf": ["enabled": true, "order": 0, "match": matchAll,
                       "match_keepout": ["mode": "keepout_class", "keepout_class": "rf"],
                       "clearances": ["track": 1_000_000]] as JSONDictionary,
            ] as JSONDictionary,
        ])
        let near = track("near", p(9.5, 11), p(9.5, 13), net: "net-a")
        let classed = makeBoard(tracks: [near], keepouts: [keepout("k", ring, allLayers: true, keepoutClass: "rf")], rules: rules)
        XCTAssertEqual(findings(classed, .clearanceCopperKeepout).count, 1)
        let other = makeBoard(tracks: [near], keepouts: [keepout("k", ring, allLayers: true, keepoutClass: "")], rules: rules)
        XCTAssertEqual(findings(other, .clearanceCopperKeepout).count, 0, "no rule takes it, so none is asked")
    }

    // MARK: Same net

    func testSameNetCopperOfTwoKindsMustKeepWhatTheRuleNames() {
        let rules = only([
            "clearance_same_net": [
                "rule": ["enabled": true, "order": 0, "match": matchAll, "layer": 10000,
                         "clearances": [["types": ["pad", "via"], "clearance": 300_000]]] as JSONDictionary,
            ] as JSONDictionary,
        ])
        let board = makeBoard(
            pads: [
                pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                pad("pkg/pad/p2/shape/s1", at: p(20, 10), size: 2, net: "net-a"),
                pad("pkg/pad/p3/shape/s1", at: p(30, 10), net: "net-a"),
            ],
            vias: [
                // 0.2 mm from p1's right edge (10.5), its copper at 10.7.
                via("near", at: p(11, 10), net: "net-a"),
                // In p2, far from its edges.
                via("in-pad", at: p(20, 10), net: "net-a"),
                // As near p3, but on another net.
                via("other-net", at: p(31, 10), net: "net-b"),
            ],
            rules: rules)

        let found = findings(board, .clearanceSameNet).compactMap(\.clearance)
        XCTAssertEqual(Set(found.map { "\($0.first.id)|\($0.second.id)" }), ["pkg/pad/p1|near", "pkg/pad/p2|in-pad"],
                       found.map(\.title).joined(separator: "\n"))
        let near = found.first { $0.second.id == "near" }
        XCTAssertEqual(near?.distance ?? 0, mm(0.2), accuracy: 1)
        XCTAssertEqual(near?.clearance, mm(0.3))
        XCTAssertEqual(near?.check, .sameNet)
        XCTAssertEqual(found.first { $0.second.id == "in-pad" }?.distance, 0)

        // Pairs the rule doesn't name aren't checked at all.
        var unnamed = rules
        unnamed["clearance_same_net"] = ["rule": ["enabled": true, "order": 0, "match": matchAll, "layer": 10000,
                                                  "clearances": [["types": ["pad", "pad_th"], "clearance": 300_000]]] as JSONDictionary]
        var quiet = board
        quiet.takeRules(unnamed)
        XCTAssertEqual(findings(quiet, .clearanceSameNet).count, 0)
    }

    // MARK: Silkscreen

    func testSilkscreenMustKeepClearOfCopperTheMaskLeavesBare() {
        let rules = only([
            "clearance_silkscreen_exposed_copper": ["enabled": true, "pads_only": true,
                                                    "clearance_top": 150_000, "clearance_bottom": 400_000] as JSONDictionary,
        ])
        let board = makeBoard(
            lines: [
                // 0.1 mm above the pad's top edge (10.5), its ink 0.05 mm wide each side.
                HorizontalSegment(id: "near", from: p(9, 10.65), to: p(11, 10.65), width: mm(0.1), layer: HorizontalBoardLayers.topSilkscreen),
                // 0.45 mm off: clear of 0.15 mm.
                HorizontalSegment(id: "clear", from: p(9, 11), to: p(11, 11), width: mm(0.1), layer: HorizontalBoardLayers.topSilkscreen),
                // Over a covered pad, which the mask hides.
                HorizontalSegment(id: "covered", from: p(19, 10), to: p(21, 10), width: mm(0.1), layer: HorizontalBoardLayers.topSilkscreen),
                // On the bottom, 0.3 mm off its pad: inside the bottom's 0.4 mm.
                HorizontalSegment(id: "bottom", from: p(29, 10.8), to: p(31, 10.8), width: 0, layer: HorizontalBoardLayers.bottomSilkscreen),
            ],
            pads: [
                pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                pad("pkg/pad/p1/shape/mask", at: p(10, 10), size: 1.1, net: nil, layer: HorizontalBoardLayers.topMask),
                pad("pkg/pad/p2/shape/s1", at: p(20, 10), net: "net-a"),
                pad("pkg/pad/p3/shape/s1", at: p(30, 10), net: "net-b", layer: bottom),
                pad("pkg/pad/p3/shape/mask", at: p(30, 10), size: 1.1, net: nil, layer: HorizontalBoardLayers.bottomMask),
            ],
            texts: [HorizontalText(id: "on-pad", text: "X", position: p(10, 10), size: mm(0.5), layer: HorizontalBoardLayers.topSilkscreen,
                                   width: mm(0.1))],
            rules: rules)

        let found = findings(board, .clearanceSilkscreenExposedCopper).compactMap(\.clearance)
        XCTAssertEqual(Set(found.map { "\($0.first.id)|\($0.second.id)" }),
                       ["near|pkg/pad/p1", "on-pad|pkg/pad/p1", "bottom|pkg/pad/p3"], found.map(\.title).joined(separator: "\n"))
        let near = found.first { $0.first.id == "near" }
        XCTAssertEqual(near?.distance ?? 0, mm(0.1), accuracy: 2)
        XCTAssertEqual(near?.clearance, mm(0.15))
        XCTAssertEqual(near?.layer, HorizontalBoardLayers.topSilkscreen)
        XCTAssertEqual(found.first { $0.first.id == "bottom" }?.clearance, mm(0.4), "the bottom's own clearance")
        XCTAssertEqual(found.first { $0.first.id == "on-pad" }?.distance, 0)
        XCTAssertEqual(found.first { $0.first.id == "on-pad" }?.first.type, .text)
    }

    /// A package told to omit its silkscreen draws none, so none of it is
    /// near anything.
    func testAPackagesOmittedSilkscreenIsNotChecked() {
        let rules = only([
            "clearance_silkscreen_exposed_copper": ["enabled": true, "pads_only": true,
                                                    "clearance_top": 150_000, "clearance_bottom": 150_000] as JSONDictionary,
        ])
        var board = makeBoard(
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                   pad("pkg/pad/p1/shape/mask", at: p(10, 10), size: 1.1, net: nil, layer: HorizontalBoardLayers.topMask)],
            rules: rules)
        board.packageLines = [HorizontalSegment(id: "pkg/line/l1", from: p(9, 10), to: p(11, 10), width: mm(0.1),
                                                layer: HorizontalBoardLayers.topSilkscreen)]
        XCTAssertEqual(findings(board, .clearanceSilkscreenExposedCopper).compactMap(\.clearance?.first.label), ["Line of U1"])
        board.packages[0].omitSilkscreen = true
        XCTAssertEqual(findings(board, .clearanceSilkscreenExposedCopper).count, 0)
    }

    func testSilkscreenNearExposedTrackCountsUnlessPadsOnly() {
        var rules = only([
            "clearance_silkscreen_exposed_copper": ["enabled": true, "pads_only": false,
                                                    "clearance_top": 150_000, "clearance_bottom": 150_000] as JSONDictionary,
        ])
        let board = makeBoard(
            tracks: [track("t", p(5, 5), p(9, 5), net: "net-a")],
            lines: [HorizontalSegment(id: "silk", from: p(6, 5.2), to: p(8, 5.2), width: 0, layer: HorizontalBoardLayers.topSilkscreen)],
            // A mask opening drawn over the track.
            polygons: [outline, polygon("opening", square(p(7, 5), 2), layer: HorizontalBoardLayers.topMask)],
            rules: rules)
        XCTAssertEqual(findings(board, .clearanceSilkscreenExposedCopper).compactMap(\.clearance?.second.id), ["t"])

        rules["clearance_silkscreen_exposed_copper"] = ["enabled": true, "pads_only": true,
                                                        "clearance_top": 150_000, "clearance_bottom": 150_000] as JSONDictionary
        var padsOnly = board
        padsOnly.takeRules(rules)
        XCTAssertEqual(findings(padsOnly, .clearanceSilkscreenExposedCopper).count, 0)
    }

    // MARK: Connectivity

    func testANetInMoreThanOnePieceOfCopperIsAnError() {
        let rules = only(["board_connectivity": ["enabled": true]])
        let joined = makeBoard(
            tracks: [
                track("t1", p(10, 10), p(14, 10), net: "net-a"),
                // To a via, and on from it on the bottom.
                track("t2", p(14, 10), p(18, 14), net: "net-a"),
                track("t3", p(18, 14), p(20, 10), net: "net-a", layer: bottom),
            ],
            pads: [
                pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                pad("pkg/pad/p2/shape/s1", at: p(20, 10), net: "net-a", layer: bottom),
            ],
            vias: [via("v", at: p(18, 14), net: "net-a")],
            rules: rules)
        XCTAssertEqual(findings(joined, .boardConnectivity).map(\.message), [])

        var apart = joined
        apart.packagePads.append(pad("pkg/pad/p3/shape/s1", at: p(30, 30), net: "net-a"))
        let found = findings(apart, .boardConnectivity)
        XCTAssertEqual(found.map(\.message), ["Net A has 2 unconnected groups"])
        XCTAssertEqual(found.first?.location, square(p(30, 30), 1)[0], "it points at the smaller group")

        // A fill joins what is inside it.
        var filled = apart
        filled.planes = [plane("gnd", net: "net-a", outline: square(p(20, 20), 30))]
        XCTAssertEqual(findings(filled, .boardConnectivity).map(\.message), [])

        // A fill of two fragments is two pieces unless something joins them.
        var split = joined
        split.planes = [plane("gnd", net: "net-a", outline: square(p(30, 30), 8),
                              fragments: [[square(p(28, 30), 1)], [square(p(32, 30), 1)]])]
        XCTAssertEqual(findings(split, .boardConnectivity).map(\.message), ["Net A has 3 unconnected groups"])
    }

    func testAShortedPadsRuleJoinsAPackagesPadsOfItsNet() {
        let pads = [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                    pad("pkg/pad/p2/shape/s1", at: p(12, 10), net: "net-a")]
        let apart = makeBoard(pads: pads, rules: only(["board_connectivity": ["enabled": true]]))
        XCTAssertEqual(findings(apart, .boardConnectivity).count, 1)

        let shorted = makeBoard(pads: pads, rules: only([
            "board_connectivity": ["enabled": true],
            "shorted_pads": ["rule": ["enabled": true, "order": 0, "match": matchAll,
                                      "match_component": ["mode": "component", "component": "comp-u1"]] as JSONDictionary] as JSONDictionary,
        ]))
        XCTAssertEqual(findings(shorted, .boardConnectivity).count, 0)
    }

    // MARK: Preflight

    func testPreflightFindsWhatHorizonsDoes() {
        var board = makeBoard(
            tracks: [track("orphan", p(1, 1), p(2, 1), net: nil)],
            lines: [HorizontalSegment(id: "edge-line", from: p(0, 0), to: p(5, 0), width: 0, layer: HorizontalBoardLayers.outline)],
            airwires: [
                HorizontalSegment(id: "a1", from: p(5, 5), to: p(6, 6), width: 0, layer: nil, netID: "net-a"),
                HorizontalSegment(id: "a2", from: p(7, 7), to: p(8, 8), width: 0, layer: nil, netID: "net-a"),
                HorizontalSegment(id: "b1", from: p(9, 9), to: p(9, 9), width: 0, layer: nil, netID: "net-b"),
            ],
            polygons: [outline, polygon("copper", square(p(20, 20), 2), layer: top)],
            planes: [plane("empty", net: "net-c", outline: square(p(30, 30), 4), fragments: [])],
            packageTexts: [HorizontalText(id: "pkg/text/t1", text: "U1", position: p(10, 12), size: mm(1),
                                          layer: HorizontalBoardLayers.bottomSilkscreen, fromSmash: true)],
            rules: [:])
        board.unplacedObjects = [HorizontalUnplacedObject(id: "comp-r1", label: "R1", subtitle: "Package", componentID: "comp-r1")]
        board.checkFacts.componentsWithoutPart = [.init(id: "comp-x1", label: "X1")]

        let found = findings(board, .preflightChecks)
        XCTAssertEqual(Set(found.map(\.message)), [
            "2 airwires of net A",
            "Zero length airwire of net B",
            "Plane of net C on layer \(HorizontalBoardLayers.name(for: top)) has no fragments",
            "Component X1 has no part",
            "Component R1 is not placed",
            "Component X1 is not placed",
            "Text for U1 should be on layer \(HorizontalBoardLayers.name(for: HorizontalBoardLayers.topSilkscreen)), but is on \(HorizontalBoardLayers.name(for: HorizontalBoardLayers.bottomSilkscreen))",
            "Track on layer \(HorizontalBoardLayers.name(for: top)) has no net",
            "Polygon on layer \(HorizontalBoardLayers.name(for: top)) is not a keepout or a plane",
            "Line on outline layer. Use polygons to define board outline.",
        ], found.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(found.first { $0.check == "text_layer" }?.level, .warning)
        XCTAssertTrue(found.filter { $0.check != "text_layer" }.allSatisfy { $0.level == .error })

        var off = board
        off.takeRules(["preflight_checks": ["enabled": false]])
        XCTAssertEqual(findings(off, .preflightChecks).count, 0)
    }

    /// A plane keeps only fill that joins copper of its net: on a net with
    /// none on the board it pours nothing however often it is poured, and
    /// the finding says so rather than asking for a pour. Board K's N12V Raw
    /// and P12V Filtered planes, whose nets lost their pins, read "pour the
    /// planes" after every Update All Planes.
    func testAnEmptyPlaneOnANetWithNoCopperSaysAPourWontFillIt() {
        let board = makeBoard(
            pads: [pad("pkg/pad/p1/shape/s", at: p(10, 10), net: "net-a")],
            planes: [
                plane("unpinned", net: "net-c", outline: square(p(30, 30), 4), fragments: []),
                plane("unpoured", net: "net-a", outline: square(p(10, 10), 4), fragments: []),
            ],
            rules: [:])
        let found = findings(board, .preflightChecks).filter { $0.check == "plane_no_fragments" }
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first { $0.objectIDs == ["unpinned"] }?.detail,
                       "Its net has no pads, tracks or vias on the board, so all the plane pours is orphaned copper, which it doesn't keep; pouring again changes nothing.")
        XCTAssertEqual(found.first { $0.objectIDs == ["unpoured"] }?.detail,
                       "Nothing of it is poured: pour the planes, or the plane's outline holds no copper.")
    }

    func testPreflightChecksTheBoardOutline() {
        func outlineFindings(_ polygons: [HorizontalPolygon]) -> [String] {
            findings(makeBoard(polygons: polygons), .preflightChecks).map(\.message)
        }
        XCTAssertEqual(outlineFindings([]), ["Found no outline polygons"])
        XCTAssertEqual(outlineFindings([outline]), [])
        let cutout = polygon("cutout", square(p(20, 20), 4), layer: HorizontalBoardLayers.outline)
        XCTAssertEqual(outlineFindings([outline, cutout]), [], "a cutout inside the outline")
        let apart = polygon("apart", square(p(60, 60), 4), layer: HorizontalBoardLayers.outline)
        XCTAssertEqual(outlineFindings([outline, apart]), ["No outline polygon encloses all others"])
        let crossing = polygon("crossing", square(p(22, 20), 4), layer: HorizontalBoardLayers.outline)
        XCTAssertEqual(outlineFindings([outline, cutout, crossing]), ["Hole intersects other hole"])
        var doubled = outline
        doubled.vertices = outline.vertices + [outline.vertices[3]]
        XCTAssertEqual(outlineFindings([doubled]), ["Zero-length edge"])
    }

    // MARK: Plane fill order

    func testOverlappingPlanesMustFillInAnOrderThatKeepsEach() {
        let big = square(p(20, 20), 20), small = square(p(20, 20), 4)
        func messages(_ planes: [HorizontalPlane]) -> [String] {
            findings(makeBoard(planes: planes), .plane).map(\.message)
        }
        let layer = HorizontalBoardLayers.name(for: top)
        // The one inside fills first: a lower number.
        XCTAssertEqual(messages([plane("big", net: "net-a", outline: big, priority: 1),
                                 plane("small", net: "net-b", outline: small, priority: 0)]), [])
        XCTAssertEqual(messages([plane("big", net: "net-a", outline: big, priority: 0),
                                 plane("small", net: "net-b", outline: small, priority: 0)]),
                       ["Plane A enclosing plane B on layer \(layer) needs higher fill order than enclosed plane"])
        let left = square(p(15, 20), 10), right = square(p(22, 20), 10)
        XCTAssertEqual(messages([plane("l", net: "net-a", outline: left, priority: 2),
                                 plane("r", net: "net-b", outline: right, priority: 2)]),
                       ["Plane A overlapping plane B of fill order 2 on layer \(layer)"])
        XCTAssertEqual(messages([plane("l", net: "net-a", outline: left, priority: 1),
                                 plane("r", net: "net-b", outline: right, priority: 2)]), [])
        let same = findings(makeBoard(planes: [plane("one", net: "net-a", outline: big), plane("two", net: "net-b", outline: big)]), .plane)
        XCTAssertEqual(same.map(\.message), ["Plane outline A is identical to plane outline B on layer \(layer)"])
        XCTAssertEqual(same.first?.level, .warning)
        // Planes on different layers never meet.
        XCTAssertEqual(messages([plane("t", net: "net-a", outline: big), plane("b", net: "net-b", outline: big, layer: bottom)]), [])
    }

    // MARK: Net ties

    func testANetTieMustBeDrawnAndMeetBothItsNets() {
        let tieRules = only(["net_ties": ["enabled": true]])
        let pads = [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                    pad("pkg/pad/p2/shape/s1", at: p(12, 10), net: "net-b")]
        func tie(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint) -> HorizontalSegment {
            HorizontalSegment(id: id, from: a, to: b, width: mm(0.3), layer: top, netID: "net-a")
        }
        func facts(_ board: inout HorizontalBoard, drawn: [String]) {
            board.checkFacts.hasBlock = true
            board.checkFacts.blockNetTies = [
                HorizontalNetTieDetails(id: "nt-ab", primaryID: "net-a", secondaryID: "net-b", primaryName: "A", secondaryName: "B"),
                HorizontalNetTieDetails(id: "nt-ac", primaryID: "net-a", secondaryID: "net-c", primaryName: "A", secondaryName: "C"),
            ]
            board.checkFacts.netTieBlockIDs = Dictionary(uniqueKeysWithValues: drawn.map { ($0, "nt-ab") })
        }

        var good = makeBoard(netTies: [tie("t", p(10, 10), p(12, 10))], pads: pads, rules: tieRules)
        facts(&good, drawn: ["t"])
        XCTAssertEqual(findings(good, .netTies).map(\.message), ["Net tie for nets A and C not present on board"])

        // One end short of B's pad (which starts at 11.5).
        var short = makeBoard(netTies: [tie("t", p(10, 10), p(11, 10))], pads: pads, rules: tieRules)
        facts(&short, drawn: ["t"])
        XCTAssertEqual(findings(short, .netTies).filter { $0.check != "not_on_board" }.map(\.message),
                       ["Net tie for nets A and B does not connect net B"])

        // Its end only grazing B's pad.
        var grazing = makeBoard(netTies: [tie("t", p(10, 10), p(11.4, 10))], pads: pads, rules: tieRules)
        facts(&grazing, drawn: ["t"])
        let grazed = findings(grazing, .netTies).filter { $0.check != "not_on_board" }
        XCTAssertEqual(grazed.map(\.message), ["Net tie for nets A and B connects net B with insufficient area"])
        XCTAssertEqual(grazed.first?.level, .warning)

        // Across B's copper twice.
        var twice = makeBoard(netTies: [tie("t", p(10, 10), p(12, 10))],
                              pads: pads + [pad("pkg/pad/p4/shape/s1", at: p(11.2, 10), size: 0.2, net: "net-b")], rules: tieRules)
        facts(&twice, drawn: ["t"])
        XCTAssertEqual(findings(twice, .netTies).filter { $0.check == "connects_more_than_once" }.count, 2)
    }

    // MARK: Height restrictions

    func testAPackageTallerThanItsHeightRestrictionIsAnError() {
        func package(_ id: String, at center: HorizontalPoint, height: Double?) -> HorizontalPlacement {
            var placement = HorizontalPlacement(id: id, position: center, angle: 0, mirrored: false, label: id.uppercased(),
                                                componentID: "comp-\(id)")
            placement.model3D = height.map {
                HorizontalPackage3DModel(id: "m", filename: "m.step", fileURL: URL(fileURLWithPath: "/tmp/m.step"),
                                         x: 0, y: 0, z: 0, roll: 0, pitch: 0, yaw: 0, heightTop: mm($0), heightBottom: 0)
            }
            return placement
        }
        let packages = [package("u1", at: p(10, 10), height: 5), package("u2", at: p(14, 10), height: 2),
                        package("u3", at: p(18, 10), height: nil), package("u4", at: p(30, 30), height: 9),
                        package("u5", at: p(10, 30), height: 9)]
        let outlines = packages.prefix(4).map { polygon("\($0.id)/polygon/o", square($0.position, 2), layer: HorizontalBoardLayers.topPackage) }
        var board = makeBoard(
            polygons: [outline, polygon("hr-area", [p(5, 5), p(20, 5), p(20, 15), p(5, 15)], layer: HorizontalBoardLayers.topPackage),
                       polygon("hr-wrong", square(p(30, 5), 2), layer: HorizontalBoardLayers.topSilkscreen)],
            packages: packages, packagePolygons: Array(outlines),
            rules: only(["height_restrictions": ["enabled": true]]))
        board.checkFacts.heightRestrictions = [
            HorizontalHeightRestriction(id: "hr", polygonID: "hr-area", height: mm(3)),
            HorizontalHeightRestriction(id: "hr2", polygonID: "hr-wrong", height: mm(3)),
        ]

        let found = findings(board, .heightRestrictions)
        XCTAssertEqual(Set(found.map(\.message)), [
            "package U1 top height (5 mm) exceeds height restriction of 3 mm",
            "package U3 has no 3D model",
            "package U5 has no package outlines",
            "ignored height restriction not in package layer",
        ], found.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(found.first { $0.check == "too_tall" }?.level, .error)
        XCTAssertEqual(found.first { $0.check == "too_tall" }?.componentIDs, ["comp-u1"])
    }

    // MARK: Copper

    func testCopperJoiningTwoNetsAndAPlaneOverAPadAreReported() {
        let board = makeBoard(
            tracks: [track("bridge", p(10, 10), p(14, 10), net: nil)],
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a"),
                   pad("pkg/pad/p2/shape/s1", at: p(14, 10), net: "net-b"),
                   pad("pkg/pad/p3/shape/s1", at: p(30, 30), net: "net-b")],
            planes: [plane("gnd", net: "net-a", outline: square(p(30, 30), 6))])
        let found = findings(board, nil)
        XCTAssertEqual(Set(found.map(\.check)), ["short", "plane_over_pad"], found.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(found.first { $0.check == "short" }?.message, "Copper joins A and B")
        XCTAssertEqual(found.first { $0.check == "plane_over_pad" }?.message,
                       "The A plane on \(HorizontalBoardLayers.name(for: top)) covers U1.1 (B)")
    }

    // MARK: Where they surface

    /// Every kind the rules window marks "Check" has a check here, and none
    /// it doesn't mark does.
    func testTheRulesWindowSaysCheckOnlyOfKindsHorizontalChecks() {
        let checked: Set<HorizontalBoardRuleKind> = [
            .clearanceCopper, .clearanceCopperOther, .clearanceCopperKeepout, .clearanceSameNet,
            .clearanceSilkscreenExposedCopper, .heightRestrictions, .trackWidth, .holeSize, .plane,
            .shortedPads, .netTies, .preflightChecks, .boardConnectivity,
        ]
        XCTAssertEqual(Set(HorizontalBoardRuleKind.allCases.filter(\.checksInHorizontal)), checked)
        XCTAssertTrue(HorizontalBoardRuleKind.visibleCases.contains(.heightRestrictions), "it has a check, so it is listed")
        for kind in HorizontalBoardRuleKind.allCases where kind.checksInHorizontal {
            XCTAssertTrue(kind.canCheck, "\(kind) is one Horizon checks too")
        }
    }

    func testTheResultsSidebarListsEveryFindingByKindAndBadgesErrorsRed() {
        let warning = HorizontalBoardRuleFinding(kind: .plane, level: .warning, check: "identical", title: "t", message: "w",
                                                 location: p(1, 1), region: HorizontalRect(points: [p(0, 0), p(2, 2)]))
        let error = HorizontalBoardRuleFinding(kind: .trackWidth, level: .error, check: "too_narrow", title: "t", message: "e",
                                               location: p(3, 3))
        let unplaced = HorizontalBoardRuleFinding(kind: .preflightChecks, level: .error, check: "not_placed", title: "t", message: "u")
        var state = HorizontalBoardRulesResultState(ruleTitle: "Design Rules", messages: [], clearanceFindings: [],
                                                    boardFindings: [warning], schematicFindings: [])
        XCTAssertFalse(state.hasNoIssues)
        XCTAssertEqual(state.badgeCount, 1)
        XCTAssertEqual(state.badgeColor, .orange)
        state.boardFindings = [warning, unplaced, error]
        XCTAssertEqual(state.badgeColor, .red)
        XCTAssertEqual(state.errorCount, 2)
        XCTAssertEqual(state.warningCount, 1)
        // Sections in the rules window's order of kinds.
        XCTAssertEqual(state.boardFindingSections.map(\.title), [
            HorizontalBoardRuleKind.trackWidth.title, HorizontalBoardRuleKind.plane.title, HorizontalBoardRuleKind.preflightChecks.title,
        ])
        // A marker where each one with a place is, red for an error.
        let markers = HorizontalCanvasWarning.markers(boardFindings: state.allBoardFindings)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.first { $0.position == p(3, 3) }?.isError, true)
        XCTAssertEqual(markers.first { $0.position == p(1, 1) }?.isError, false)
        state.boardFindings = []
        XCTAssertTrue(state.hasNoIssues)
    }

    // MARK: Rules and the loader

    func testTheRulesOfTheNewKindsParseAsHorizonsDo() {
        let rules = HorizontalBoardRules(rules: [
            "hole_size": ["h": ["enabled": true, "order": 3, "match": matchAll, "diameter_min": 1, "diameter_max": 2] as JSONDictionary] as JSONDictionary,
            "clearance_same_net": ["s": ["enabled": true, "order": 0, "match": matchAll, "layer": 0,
                                         "clearances": [["types": ["via", "pad"], "clearance": 5]]] as JSONDictionary] as JSONDictionary,
            "shorted_pads": ["sp": ["enabled": true, "order": 0, "match": matchAll,
                                    "match_component": ["mode": "part", "part": "PART-1"]] as JSONDictionary] as JSONDictionary,
            "clearance_silkscreen_exposed_copper": ["enabled": true, "clearance_top": 7, "clearance_bottom": 9] as JSONDictionary,
            "net_ties": ["enabled": false],
        ], netDetails: [:])
        XCTAssertEqual(rules.holeSize(net: "x")?.diameterMin, 1)
        XCTAssertEqual(rules.clearanceSameNet(net: nil, layer: 0).clearance(.pad, .via), 5, "either way round")
        XCTAssertNil(rules.clearanceSameNet(net: nil, layer: 0).clearance(.pad, .padTH), "a pair it doesn't name")
        XCTAssertNil(rules.clearanceSameNet(net: nil, layer: -100).clearance(.pad, .via), "another layer's rule: none")
        XCTAssertNotNil(rules.shortedPads(componentID: "c", partID: "part-1", net: nil))
        XCTAssertNil(rules.shortedPads(componentID: "c", partID: "part-2", net: nil))
        XCTAssertEqual(rules.clearanceSilkscreenExposedCopper.clearanceBottom, 9)
        XCTAssertFalse(rules.clearanceSilkscreenExposedCopper.padsOnly, "Horizon's default")
        XCTAssertFalse(rules.checksNetTies)
        XCTAssertTrue(rules.checksPreflight, "on where the file says nothing, as Horizon never reads it")
        XCTAssertTrue(rules.checksBoardConnectivity)
    }

    func testTheLoaderKeepsWhatTheChecksReadOfTheBlockAndTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func vertex(_ x: Int, _ y: Int) -> JSONDictionary { ["type": "line", "position": [x, y]] }
        let board: JSONDictionary = [
            "type": "board", "uuid": "b", "name": "b",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [1_000_000, 0]]] as JSONDictionary,
            "net_ties": ["T1": ["net_tie": "NT1", "from": "j1", "to": "j2", "layer": 0, "width": 200_000]] as JSONDictionary,
            "polygons": ["P1": ["layer": 40, "vertices": [vertex(0, 0), vertex(1_000_000, 0), vertex(1_000_000, 1_000_000)]]] as JSONDictionary,
            "height_restrictions": ["HR1": ["polygon": "P1", "height": 3_000_000]] as JSONDictionary,
        ]
        let block: JSONDictionary = [
            "type": "block", "uuid": "blk", "name": "top",
            "nets": ["N1": ["name": "VIN"], "N2": ["name": "VOUT"]] as JSONDictionary,
            "net_ties": ["NT1": ["net_primary": "N1", "net_secondary": "N2"]] as JSONDictionary,
            "components": ["C1": ["refdes": "R1", "value": "10k"], "C2": ["refdes": "U2", "value": "x", "part": "PART"]] as JSONDictionary,
        ]
        let boardURL = root.appendingPathComponent("board.json"), blockURL = root.appendingPathComponent("block.json")
        try JSONSerialization.data(withJSONObject: board).write(to: boardURL)
        try JSONSerialization.data(withJSONObject: block).write(to: blockURL)
        var diagnostics = [HorizontalDiagnostic]()
        let loaded = try HorizontalBoard.load(from: boardURL, blockURL: blockURL, planesURL: nil, poolURL: nil, diagnostics: &diagnostics)

        let facts = loaded.checkFacts
        XCTAssertTrue(facts.hasBlock)
        XCTAssertEqual(facts.componentsWithoutPart, [.init(id: "c1", label: "R1")])
        XCTAssertEqual(facts.blockNetTies, [HorizontalNetTieDetails(id: "nt1", primaryID: "n1", secondaryID: "n2",
                                                                     primaryName: "VIN", secondaryName: "VOUT")])
        XCTAssertEqual(facts.netTieBlockIDs, ["t1": "nt1"])
        XCTAssertEqual(facts.heightRestrictions, [HorizontalHeightRestriction(id: "HR1", polygonID: "p1", height: 3_000_000)])
    }

    /// MCP `check` reports each kind under its rule, at Horizon's level, and
    /// leaves out the preflight findings it already states its own way.
    func testMCPCheckGivesEachKindItsCategory() {
        let findings = [
            HorizontalBoardRuleFinding(kind: .trackWidth, level: .error, check: "too_narrow", title: "Track narrower than its rule allows",
                                       message: "Track width 0.100 mm is less than 0.200 mm", location: p(1, 2), objectIDs: ["t"], ruleID: "r"),
            HorizontalBoardRuleFinding(kind: .plane, level: .warning, check: "identical", title: "Plane outlines are identical", message: "m"),
            HorizontalBoardRuleFinding(kind: .preflightChecks, level: .error, check: "airwire", title: "Airwire", message: "Airwire of net A"),
            HorizontalBoardRuleFinding(kind: .preflightChecks, level: .error, check: "track_no_net", title: "Track has no net", message: "n"),
            HorizontalBoardRuleFinding(kind: nil, level: .error, check: "short", title: "Copper joins two nets", message: "s"),
        ]
        let messages = HorizontalDispatchChecks.ruleMessages(findings)
        XCTAssertEqual(messages.map(\.category), ["track_width", "plane", "preflight_checks"])
        XCTAssertEqual(messages.map(\.level), ["error", "warning", "error"])
        let width = messages[0].json
        XCTAssertEqual(width["check"] as? String, "too_narrow")
        XCTAssertEqual(width["x_mm"] as? Double, 1)
        XCTAssertEqual((width["rule"] as? JSONDictionary)?["id"] as? String, "r")
        XCTAssertTrue((width["detail"] as? String)?.hasPrefix("Track width 0.100 mm is less than 0.200 mm.") ?? false)
    }

    /// The whole pipeline on the new-document template: its GND via gives
    /// its GND planes copper to keep, they come poured, and MCP `check`
    /// finds nothing wrong with it.
    func testMCPCheckRunsTheBoardChecksOnARealProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newPouredProject().write(to: packageURL)
        let project = try HorizontalProject.load(from: packageURL)

        let report = HorizontalDispatchChecks.run(entry: HorizontalDispatchProjectEntry(handle: 1, url: project.baseURL, project: project), full: true)
        let messages = report["messages"] as? [JSONDictionary] ?? []
        XCTAssertEqual(messages.filter { $0.string("level") == "error" }.map { $0.string("title") }, [], "\(messages)")
        XCTAssertEqual(messages.filter { $0.string("category") == "preflight_checks" }.map { $0.string("title") }, [], "\(messages)")
    }
}

extension HorizontalBoardCheckFacts.Component: CustomStringConvertible {
    public var description: String { "\(id) \(label)" }
}
