import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Horizon's copper clearance checks, on boards built here: each finding's
/// pair, layer, distance, clearance and rule.
final class HorizontalBoardClearanceCheckTests: XCTestCase {
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

    /// A square pad of `size` mm centred on `center`.
    private func pad(_ id: String, at center: HorizontalPoint, size: Double = 1, net: String?,
                     layer: Int? = HorizontalBoardLayers.topCopper) -> HorizontalPolygon {
        let half = mm(size) / 2
        return HorizontalPolygon(
            id: id,
            vertices: [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                       HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)],
            layer: layer,
            netID: net,
            metadata: ["Pad": "1"]
        )
    }

    private func via(_ id: String, at center: HorizontalPoint, diameter: Double = 0.6, net: String?) -> HorizontalMarker {
        HorizontalMarker(id: id, position: center, size: mm(diameter), holeSize: mm(0.3), layer: top,
                         connectedLayers: [top, bottom], netID: net)
    }

    /// A 40 mm square outline, its corner at the origin.
    private let outline = HorizontalPolygon(
        id: "outline",
        vertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 40_000_000, y: 0),
                   HorizontalPoint(x: 40_000_000, y: 40_000_000), HorizontalPoint(x: 0, y: 40_000_000)],
        layer: HorizontalBoardLayers.outline
    )

    private let nets = ["net-a": "A", "net-b": "B", "net-c": "C", "net-d": "D"]

    /// Track to pad 0.2 mm, track to via 0.15 mm, the rest Horizon's 0.1 mm;
    /// track to the board edge 0.3 mm and to an unplated hole 0.25 mm.
    private let rules: JSONDictionary = [
        "clearance_copper": [
            "rule-cu": [
                "enabled": true, "order": 0, "layer": 10000,
                "match_1": ["mode": "all"], "match_2": ["mode": "all"],
                "clearances": [
                    ["types": ["track", "pad"], "clearance": 200_000],
                    ["types": ["track", "via"], "clearance": 150_000],
                ],
            ] as JSONDictionary,
        ] as JSONDictionary,
        "clearance_copper_other": [
            "rule-other": [
                "enabled": true, "order": 0, "layer": 10000,
                "match": ["mode": "all"],
                "clearances": [
                    ["types": ["track", "board_edge"], "clearance": 300_000],
                    ["types": ["track", "hole_npth"], "clearance": 250_000],
                ],
            ] as JSONDictionary,
        ] as JSONDictionary,
    ]

    private func makeBoard(
        tracks: [HorizontalSegment] = [],
        netTies: [HorizontalSegment] = [],
        pads: [HorizontalPolygon] = [],
        vias: [HorizontalMarker] = [],
        holes: [HorizontalHole] = [],
        planes: [HorizontalPlane] = [],
        junctionNetIDs: [String: String] = [:],
        rules: JSONDictionary? = nil
    ) -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/clearance.hprj"), uuid: "b", name: "clearance",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: junctionNetIDs,
            netDetails: nets.reduce(into: [:]) { $0[$1.key] = HorizontalNetDetails(id: $1.key, name: $1.value) },
            tracks: tracks, netTies: netTies, lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [outline], planes: planes, keepouts: [], dimensions: [], decals: [], holes: holes,
            vias: vias, viaHoles: [], packages: [HorizontalPlacement(id: "pkg", position: p(10, 10), angle: 0, mirrored: false,
                                                                     label: "U1", componentID: "comp-u1")],
            packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.takeRules(rules ?? self.rules)
        return board
    }

    private func assertNumbers(
        _ finding: HorizontalClearanceFinding?, distance: Double, clearance: Double, rule: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let finding else {
            return XCTFail("no finding", file: file, line: line)
        }
        XCTAssertEqual(finding.distance, mm(distance), accuracy: 1, file: file, line: line)
        XCTAssertEqual(finding.clearance, mm(clearance), file: file, line: line)
        XCTAssertEqual(finding.ruleID, rule, file: file, line: line)
    }

    /// A track too close to a pad, another to a via and a third to the board
    /// edge: one finding each, naming both, with the distance on the copper,
    /// the clearance the rule asks and the rule.
    func testATrackTooCloseToAPadAViaAndTheEdgeGetsOneFindingEach() {
        let board = makeBoard(
            tracks: [
                // The pad's top edge is at y = 10.5; this track's copper at 10.62.
                track("t-pad", p(8, 10.72), p(12, 10.72), net: "net-b"),
                // The via's copper reaches y = 20.3; this track's at 20.4.
                track("t-via", p(17, 20.5), p(23, 20.5), net: "net-b"),
                // The edge is y = 0; this track's copper at 0.2.
                track("t-edge", p(30, 0.3), p(35, 0.3), net: "net-d"),
            ],
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a")],
            vias: [via("v1", at: p(20, 20), net: "net-c")]
        )

        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.count, 3, findings.map(\.title).joined(separator: "\n"))

        let padFinding = findings.first { $0.check == .copper && $0.second.type == .pad }
        assertNumbers(padFinding, distance: 0.12, clearance: 0.2, rule: "rule-cu")
        XCTAssertEqual(padFinding?.first.id, "t-pad")
        XCTAssertEqual(padFinding?.first.type, .track)
        XCTAssertEqual(padFinding?.second.id, "pkg/pad/p1")
        XCTAssertEqual(padFinding?.second.label, "Pad U1.1")
        XCTAssertEqual(padFinding?.second.componentID, "comp-u1")
        XCTAssertEqual(padFinding?.layers, [top])
        XCTAssertEqual(padFinding?.layer, top)
        XCTAssertEqual(padFinding?.title, "Track (B) near Pad U1.1 (A)")
        XCTAssertEqual(padFinding?.detail, "0.120 mm apart on Top Copper, where the rules ask 0.200 mm (Copper clearance: All / All · Any layer).")
        // Between the two at x = 10, where they come nearest along the pad's edge.
        if let location = padFinding?.location {
            XCTAssertEqual(location.y, mm(10.56), accuracy: 1)
            XCTAssertTrue((mm(9.5)...mm(10.5)).contains(location.x))
        }

        let viaFinding = findings.first { $0.second.type == .via }
        assertNumbers(viaFinding, distance: 0.1, clearance: 0.15, rule: "rule-cu")
        XCTAssertEqual(viaFinding?.first.id, "t-via")
        XCTAssertEqual(viaFinding?.second.id, "v1")
        XCTAssertEqual(viaFinding?.layers, [top], "the track is on the top only")
        XCTAssertEqual(viaFinding?.location.x ?? 0, mm(20), accuracy: 1)
        XCTAssertEqual(viaFinding?.location.y ?? 0, mm(20.35), accuracy: 1)

        let edgeFinding = findings.first { $0.check == .boardEdge }
        assertNumbers(edgeFinding, distance: 0.2, clearance: 0.3, rule: "rule-other")
        XCTAssertEqual(edgeFinding?.first.id, "t-edge")
        XCTAssertEqual(edgeFinding?.second.type, .boardEdge)
        XCTAssertEqual(edgeFinding?.title, "Track (D) near the board edge")
        XCTAssertFalse(edgeFinding?.outsideBoard ?? true)
    }

    /// The same copper a little further apart: nothing, and copper at exactly
    /// the clearance passes, as Horizon's overlap of offset polygons does.
    func testAClearBoardHasNoFindings() {
        let board = makeBoard(
            tracks: [
                track("t-pad", p(8, 10.8), p(12, 10.8), net: "net-b"),        // exactly 0.2 mm
                track("t-via", p(17, 20.6), p(23, 20.6), net: "net-b"),       // 0.2 mm, 0.15 asked
                track("t-edge", p(30, 0.4), p(35, 0.4), net: "net-d"),        // exactly 0.3 mm
                track("t-diagonal", p(25, 25), p(30, 30), net: "net-a"),
            ],
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a")],
            vias: [via("v1", at: p(20, 20), net: "net-c")]
        )
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board).map(\.title), [])
    }

    /// Copper of one net isn't checked against itself, nor copper on no net
    /// against other copper on none; it is against copper on a net.
    func testOneNetAndNoNetAreLeftAlone() {
        let board = makeBoard(
            tracks: [
                track("same", p(8, 10.6), p(12, 10.6), net: "net-a"),
                track("loose-1", p(20, 10), p(25, 10), net: nil),
                track("loose-2", p(20, 10.25), p(25, 10.25), net: nil),
                track("netted", p(20, 10.5), p(25, 10.5), net: "net-b"),
            ],
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a")]
        )
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.map { [$0.first.id, $0.second.id] }, [["loose-2", "netted"]])
        assertNumbers(findings.first, distance: 0.05, clearance: 0.1, rule: "rule-cu")
        XCTAssertEqual(findings.first?.title, "Track (no net) near Track (B)")
    }

    /// The routing offset is the router's margin, not a clearance: a track
    /// inside it but outside the clearance passes.
    func testTheRoutingOffsetIsNotChecked() {
        var rules = self.rules
        var copper = rules["clearance_copper"] as! JSONDictionary
        var rule = copper["rule-cu"] as! JSONDictionary
        rule["routing_offset"] = 500_000
        copper["rule-cu"] = rule
        rules["clearance_copper"] = copper
        let board = makeBoard(
            tracks: [track("t-pad", p(8, 10.85), p(12, 10.85), net: "net-b")],
            pads: [pad("pkg/pad/p1/shape/s1", at: p(10, 10), net: "net-a")],
            rules: rules
        )
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board).count, 0)
    }

    /// Two vias of two nets span both layers: one finding, both layers.
    func testViasCloseOnEveryLayerAreOneFindingWithBothLayers() {
        let board = makeBoard(vias: [via("v1", at: p(20, 20), net: "net-a"), via("v2", at: p(20.65, 20), net: "net-b")])
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.count, 1)
        assertNumbers(findings.first, distance: 0.05, clearance: 0.1, rule: "rule-cu")
        XCTAssertEqual(findings.first?.layers, [top, bottom])
        XCTAssertEqual(findings.first?.detail, "0.050 mm apart on Top Copper, Bottom Copper, where the rules ask 0.100 mm (Copper clearance: All / All · Any layer).")
    }

    /// A rule for one layer gives its clearance there; the finding's numbers
    /// are for the layer that asks the most.
    func testALayerRuleGivesItsLayerItsClearance() {
        var rules = self.rules
        var copper = rules["clearance_copper"] as! JSONDictionary
        copper["rule-bottom"] = [
            "enabled": true, "order": -1, "layer": bottom,
            "match_1": ["mode": "all"], "match_2": ["mode": "all"],
            "clearances": [["types": ["via", "via"], "clearance": 300_000]],
        ] as JSONDictionary
        rules["clearance_copper"] = copper
        let board = makeBoard(vias: [via("v1", at: p(20, 20), net: "net-a"), via("v2", at: p(20.8, 20), net: "net-b")],
                              rules: rules)
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.count, 1)
        // 0.2 mm apart: fine on top (0.1 mm), too close on the bottom (0.3 mm).
        assertNumbers(findings.first, distance: 0.2, clearance: 0.3, rule: "rule-bottom")
        XCTAssertEqual(findings.first?.layers, [bottom])
        XCTAssertEqual(findings.first?.layer, bottom)
    }

    /// An unplated hole asks what the copper-to-other rule gives, of copper
    /// on any net or none.
    func testCopperNearAnUnplatedHole() {
        let board = makeBoard(
            tracks: [track("t-hole", p(15, 15.65), p(20, 15.65), net: nil)],
            holes: [HorizontalHole(id: "h1", position: p(17, 15), diameter: mm(1), plated: false)]
        )
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.check, .hole)
        XCTAssertEqual(findings.first?.first.id, "t-hole")
        XCTAssertEqual(findings.first?.second.type, .holeNPTH)
        XCTAssertEqual(findings.first?.title, "Track (no net) near Hole")
        assertNumbers(findings.first, distance: 0.05, clearance: 0.25, rule: "rule-other")
    }

    /// Copper outside the board is too close to its edge however far away.
    func testCopperOutsideTheBoard() {
        let board = makeBoard(tracks: [track("out", p(50, 50), p(55, 50), net: "net-a")])
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.check, .boardEdge)
        XCTAssertTrue(findings.first?.outsideBoard ?? false)
        XCTAssertEqual(findings.first?.distance, 0)
        XCTAssertTrue(findings.first?.detail.hasPrefix("Outside the board on Top Copper") ?? false)
    }

    /// A plane's fill is copper: a track of another net near its edge, and a
    /// pad of another net it covers far from any edge, are both too close; a
    /// pad of its own net under it is not.
    func testAFillIsCopper() {
        let fill = HorizontalPlaneFragment(paths: [[p(5, 5), p(35, 5), p(35, 35), p(5, 35)]], orphan: false)
        let plane = HorizontalPlane(id: "plane-gnd", netID: "net-a", polygonID: "poly", layer: top, priority: 0,
                                    fillStyle: "solid", minWidth: mm(0.2), keepOrphans: false, fragments: [fill])
        let board = makeBoard(
            tracks: [track("t-near", p(10, 4.85), p(20, 4.85), net: "net-b")],
            pads: [pad("pkg/pad/under/shape/s", at: p(20, 20), net: "net-c"),
                   pad("pkg/pad/own/shape/s", at: p(25, 25), net: "net-a")],
            planes: [plane]
        )
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        XCTAssertEqual(findings.count, 2, findings.map(\.title).joined(separator: "\n"))
        let near = findings.first { $0.first.id == "t-near" }
        assertNumbers(near, distance: 0.05, clearance: 0.1, rule: "rule-cu")
        XCTAssertEqual(near?.second.type, .plane)
        let under = findings.first { $0.first.id == "pkg/pad/under" }
        assertNumbers(under, distance: 0, clearance: 0.1, rule: "rule-cu")
        XCTAssertEqual(under?.title, "Pad U1.1 (C) near Plane (A)")
    }

    /// A net tie's copper meets both nets it ties; neither is reported.
    func testANetTieIsNotCheckedAgainstTheNetsItTies() {
        let board = makeBoard(
            tracks: [track("t-a", p(10, 10), p(12, 10), net: "net-a"), track("t-b", p(12.5, 10), p(15, 10), net: "net-b")],
            netTies: [HorizontalSegment(id: "tie", from: p(12, 10), to: p(12.5, 10), width: mm(0.2), layer: top,
                                        netID: "net-a", fromJunctionID: "j1", toJunctionID: "j2")],
            junctionNetIDs: ["j1": "net-a", "j2": "net-b"]
        )
        // The tie, on A, ends on B's track; the tracks are 0.3 mm apart.
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board).map(\.title), [])
        // Untied, the tie touches B's track.
        var untied = board
        untied.junctionNetIDs = [:]
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: untied).map(\.title), ["Track (B) near Net tie (A)"])
        // A tie the design has, which the board's junctions don't say.
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(
            board: untied, tiedNets: [HorizontalBoardClearanceCheck.netPairKey("net-b", "net-a")]).count, 0)
    }
}

/// How long the check takes on a real board. Asserts nothing about the time,
/// as `RouterIndexBenchmarkTests` doesn't: the numbers are written out.
final class HorizontalBoardClearanceCheckBenchmarkTests: XCTestCase {
    func testRandiShort() throws {
        let path = ProcessInfo.processInfo.environment["HORIZONTAL_GOLDEN_BOARD"]
            ?? "/Users/kornack/Repositories/board b/Board B Horizon/Board B.hprj"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real board available")
        }
        let board = try XCTUnwrap(HorizontalProject.load(from: URL(fileURLWithPath: path)).board)
        let start = DispatchTime.now().uptimeNanoseconds
        let findings = HorizontalBoardClearanceCheck.run(board: board)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        var report = """
        tracks \(board.tracks.count), pads \(board.packagePads.count), vias \(board.vias.count), \
        planes \(board.planes.count) (\(board.planes.reduce(0) { $0 + $1.fragments.reduce(0) { $0 + $1.paths.reduce(0) { $0 + $1.count } } }) fill points), \
        holes \(board.holes.count + board.packageHoles.count)
        check: \(String(format: "%.1f", elapsed)) ms, \(findings.count) findings

        """
        for finding in findings.prefix(40) {
            report += "\(finding.check.rawValue): \(finding.title) — \(finding.detail)\n"
        }
        try? report.write(toFile: "/tmp/clearance-check-bench.txt", atomically: true, encoding: .utf8)
    }
}

/// MCP `check` reports what the clearance check finds.
final class HorizontalBoardClearanceCheckDispatchTests: XCTestCase {
    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clearance-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        session = HorizontalDispatchSession()
        handle = try session.open(url: root).handle
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = args
        params["handle"] = handle
        if method == "apply" {
            params["expected_revision"] = try session.entry(handle: handle).revision
            params["operation_id"] = UUID().uuidString
        }
        let response = try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
        XCTAssertNil(response["error"], "\(response)")
        return response.dictionary("result") ?? [:]
    }

    /// A two-pin part: 0.8 × 0.9 mm pads 2 mm apart up the package.
    private func resistor() -> (items: [JSONDictionary], part: String) {
        let names = ["A", "B"]
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        let pads = names.map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        for i in pins.indices {
            unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: names[i], direction: .bidirectional, alternateNames: [])
        }
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let gate = entity.gates.keys.first!
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        for i in pins.indices {
            symbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: -Double(i) * 2_540_000),
                                                       length: 2_540_000, orientation: .left)
        }
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = UUID().uuidString.lowercased()
        padstack.shapes[shape] = HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])
        var package = HorizontalPoolItemFactory.newPackage()
        for i in pads.indices {
            package.pads[pads[i]] = HorizontalPad(id: pads[i], name: String(i + 1), padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: Double(i) * 2_000_000), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        for i in pins.indices { part.padMap[pads[i]] = HorizontalPartPadMapEntry(gateID: gate, pinID: pins[i]) }
        return ([unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()], part.uuid)
    }

    func testCheckReportsCopperCloserThanItsClearance() throws {
        let resistor = resistor()
        // R1's pad 1 (GND) spans x 9.6 to 10.4; R2's (SIG) starts 0.2 mm on.
        _ = try call("apply", ["ops": [
            ["op": "ensure_component", "refdes": "R1", "part": resistor.part],
            ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R2", "x_mm": 11, "y_mm": 10],
            ["op": "connect", "component": "R1", "pin": "A", "net": "GND", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "A", "net": "SIG", "create_net": true],
        ] as [JSONDictionary], "pool_items": resistor.items])
        func clearance() throws -> [JSONDictionary] {
            try call("check", ["full": true]).dictionaryArray("messages").filter { $0.string("category") == "clearance" }
        }
        XCTAssertEqual(try clearance().count, 0, "0.2 mm apart, 0.1 mm asked")
        // 0.05 mm apart. Their pads 2, on no net, are as close and not checked.
        _ = try call("apply", ["ops": [["op": "place_component", "component": "R2", "x_mm": 10.85, "y_mm": 10]] as [JSONDictionary]])
        let found = try clearance()
        XCTAssertEqual(found.count, 1, "\(found)")
        let message = try XCTUnwrap(found.first)
        XCTAssertEqual(message.string("level"), "error")
        XCTAssertEqual(message.string("title"), "Copper closer than its clearance")
        XCTAssertEqual(message.string("check"), "copper")
        let pads = [message.dictionary("first"), message.dictionary("second")]
        XCTAssertEqual(Set(pads.compactMap { $0?.string("label") }), ["Pad R1.1", "Pad R2.1"])
        XCTAssertEqual(Set(pads.compactMap { $0?.string("net_name") }), ["GND", "SIG"])
        XCTAssertEqual(pads.compactMap { $0?.string("type") }, ["pad", "pad"])
        XCTAssertEqual(message.string("layer"), "Top Copper")
        XCTAssertEqual(message.double("distance_mm") ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(message.double("clearance_mm") ?? 0, 0.1, accuracy: 1e-6)
        XCTAssertTrue(message.dictionary("rule")?["id"] is NSNull, "no rule: Horizon's 0.1 mm")
        XCTAssertEqual(message.dictionary("rule")?.string("kind"), "clearance_copper")
        XCTAssertEqual(message.double("x_mm") ?? 0, 10.425, accuracy: 1e-6)
        XCTAssertEqual(try call("check").bool("ok"), false)
    }
}
