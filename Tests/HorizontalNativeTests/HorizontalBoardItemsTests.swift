import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A board built in code for the tests of what is measured on it: the items
/// and their gaps, pads, probes and capacities.
struct BoardGeometryFixture {
    static let mm = 1_000_000.0
    var nets = ["net-a": "A", "net-b": "B", "net-c": "C"]
    var innerLayers = 0
    var tracks = [HorizontalSegment]()
    var vias = [HorizontalMarker]()
    var pads = [HorizontalPolygon]()
    var lines = [HorizontalSegment]()
    var holes = [HorizontalHole]()
    var keepouts = [HorizontalKeepout]()
    var planes = [HorizontalPlane]()
    var packages = [HorizontalPlacement(id: "pkg", position: p(10, 10), angle: 0, mirrored: false, label: "U1", componentID: "comp-u1")]
    var padPositions = [String: HorizontalPoint]()
    var rules: JSONDictionary = [:]
    /// The outline's corners, in mm.
    var outline = (min: (0.0, -20.0), max: (100.0, 40.0))

    static func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    static func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, net: String?, width: Double = 0.2,
                      layer: Int = HorizontalBoardLayers.topCopper) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: width * mm, layer: layer, netID: net)
    }

    static func via(_ id: String, at center: HorizontalPoint, diameter: Double = 0.35, net: String?, layers: [Int]? = nil) -> HorizontalMarker {
        HorizontalMarker(id: id, position: center, size: diameter * mm, holeSize: 0.15 * mm, layer: HorizontalBoardLayers.topCopper,
                         connectedLayers: layers ?? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper], netID: net)
    }

    /// A rectangular pad shape: `id` is "package/pad/pad-id/shape/…".
    static func pad(_ id: String, minX: Double, minY: Double, maxX: Double, maxY: Double, net: String?,
                    layer: Int? = HorizontalBoardLayers.topCopper, name: String = "1") -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [p(minX, minY), p(maxX, minY), p(maxX, maxY), p(minX, maxY)], layer: layer,
                          netID: net, metadata: ["Pad": name])
    }

    /// Copper clearance `clearance` mm between everything.
    static func clearanceRules(_ clearance: Double) -> JSONDictionary {
        let nm = Int(clearance * mm)
        let kinds = ["track", "pad", "pad_th", "via", "plane", "hole_pth"]
        var pairs = [JSONDictionary]()
        for a in kinds {
            for b in kinds { pairs.append(["types": [a, b], "clearance": nm]) }
        }
        return ["clearance_copper": ["rule-cu": ["enabled": true, "order": 0, "layer": 10000, "match_1": ["mode": "all"],
                                                 "match_2": ["mode": "all"], "clearances": pairs] as JSONDictionary] as JSONDictionary]
    }

    var board: HorizontalBoard {
        let p = Self.p
        let ring = HorizontalPolygon(
            id: "outline",
            vertices: [p(outline.min.0, outline.min.1), p(outline.max.0, outline.min.1), p(outline.max.0, outline.max.1), p(outline.min.0, outline.max.1)],
            layer: HorizontalBoardLayers.outline)
        var stackup = [HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 200_000)]
        if innerLayers > 0 {
            stackup += (1...innerLayers).map { HorizontalBoardStackupLayer(layer: -$0, copperThickness: 35_000, substrateThickness: 200_000) }
        }
        stackup.append(HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 200_000))
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/geometry.hprj"), uuid: "b", name: "geometry", grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: stackup, userLayers: [], junctions: [:], junctionNetIDs: [:],
            netDetails: nets.reduce(into: [:]) { $0[$1.key] = HorizontalNetDetails(id: $1.key, name: $1.value) },
            tracks: tracks, netTies: [], lines: lines, arcs: [], connectionLines: [], airwires: [],
            polygons: [ring], planes: planes, keepouts: keepouts, dimensions: [], decals: [], holes: holes,
            vias: vias, viaHoles: [], packages: packages, packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty)
        board.packagePadPositions = padPositions
        board.takeRules(rules)
        return board
    }
}

/// The board's items as the checks measure them: a gap between two of them
/// is the gap `check` reports for the pair.
final class HorizontalBoardItemsTests: XCTestCase {
    private typealias Fixture = BoardGeometryFixture
    private let mm = BoardGeometryFixture.mm
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { Fixture.p(x, y) }

    private func gap(_ first: String, _ second: String, in board: HorizontalBoard) -> Double? {
        HorizontalDispatchPlanCheck.gap(first, second, in: HorizontalBoardItems(board: board))
    }

    /// A via Ø0.35 at (46.75, 2.625) and a 0.2 mm track of another net along
    /// y = 2.2796 are 0.070 mm apart, which the rules' 0.125 mm makes a
    /// finding; with the track at y = 2.2 they are 0.150 mm apart and it is
    /// none.
    func testAViaAndATrackAreAsFarApartAsTheCheckSays() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        fixture.vias = [Fixture.via("v", at: p(46.75, 2.625), net: "net-a")]
        fixture.tracks = [Fixture.track("t", p(45, 2.2796), p(48, 2.2796), net: "net-b")]
        let close = fixture.board
        let finding = try XCTUnwrap(HorizontalBoardClearanceCheck.run(board: close).first { $0.check == .copper })
        XCTAssertEqual(finding.distance, 0.0704 * mm, accuracy: 2)
        XCTAssertEqual(finding.clearance, 0.125 * mm)
        XCTAssertEqual(try XCTUnwrap(gap("v", "t", in: close)), finding.distance, accuracy: 2)

        fixture.tracks = [Fixture.track("t", p(45, 2.2), p(48, 2.2), net: "net-b")]
        let clear = fixture.board
        XCTAssertNil(HorizontalBoardClearanceCheck.run(board: clear).first { $0.check == .copper })
        XCTAssertEqual(try XCTUnwrap(gap("v", "t", in: clear)), 0.15 * mm, accuracy: 2)
    }

    /// A 0.2 mm track ending at (50.15, −2.4) is 0.118 mm, at its end cap,
    /// from a 0.2 mm track on the line x − y = 53; ended at x = 50 it clears
    /// the 0.125 mm the rules ask.
    func testATracksEndCapIsMeasuredToADiagonalTrack() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        let diagonal = Fixture.track("d", p(49, -4), p(53, 0), net: "net-b")
        fixture.tracks = [Fixture.track("t", p(48, -2.4), p(50.15, -2.4), net: "net-a"), diagonal]
        let close = fixture.board
        let finding = try XCTUnwrap(HorizontalBoardClearanceCheck.run(board: close).first { $0.check == .copper })
        XCTAssertEqual(finding.distance, 0.1182 * mm, accuracy: 100)
        let measured = try XCTUnwrap(HorizontalShapeGap.between(.path([p(48, -2.4), p(50.15, -2.4)], halfWidth: 0.1 * mm),
                                                                .path([p(49, -4), p(53, 0)], halfWidth: 0.1 * mm)))
        XCTAssertEqual(measured.distance, finding.distance, accuracy: 2)
        // The nearest points are the end cap's and the diagonal's edge.
        XCTAssertEqual(hypot(measured.first.x - measured.second.x, measured.first.y - measured.second.y), measured.distance, accuracy: 2)

        fixture.tracks = [Fixture.track("t", p(48, -2.4), p(50, -2.4), net: "net-a"), diagonal]
        XCTAssertNil(HorizontalBoardClearanceCheck.run(board: fixture.board).first { $0.check == .copper })
        XCTAssertEqual(try XCTUnwrap(gap("t", "d", in: fixture.board)), 0.2243 * mm, accuracy: 100)
    }

    /// The silkscreen rule measures to copper the solder mask leaves bare,
    /// and the opening is wider than the pad: a 0.15 mm line at x = 56.285
    /// is 0.115 mm from a pad whose edge is at 56.475, which passes at
    /// 0.1 mm, and 0.045 mm from the track that enters the pad from the
    /// line's side, bare from the opening's edge at 56.405. With the pad's
    /// edge at 56.55 both pass.
    func testSilkscreenIsMeasuredToTheMaskOpeningNotThePad() throws {
        func board(padEdge: Double) -> HorizontalBoard {
            var fixture = Fixture()
            fixture.rules = ["clearance_silkscreen_exposed_copper": ["enabled": true, "pads_only": false, "clearance_top": 100_000,
                                                                     "clearance_bottom": 100_000] as JSONDictionary]
            fixture.lines = [HorizontalSegment(id: "silk", from: p(56.285, 2), to: p(56.285, 5), width: 0.15 * mm,
                                               layer: HorizontalBoardLayers.topSilkscreen)]
            fixture.pads = [
                Fixture.pad("pkg/pad/p1/shape/s1", minX: padEdge, minY: 3, maxX: padEdge + 0.5, maxY: 3.8, net: "net-a"),
                Fixture.pad("pkg/pad/p1/shape/mask", minX: padEdge - 0.07, minY: 2.93, maxX: padEdge + 0.57, maxY: 3.87, net: nil,
                            layer: HorizontalBoardLayers.topMask),
            ]
            fixture.padPositions = ["pkg/p1": p(padEdge + 0.25, 3.4)]
            fixture.tracks = [Fixture.track("t", p(55, 3.4), p(padEdge + 0.25, 3.4), net: "net-a", width: 0.15)]
            return fixture.board
        }
        let close = HorizontalBoardClearanceCheck.run(board: board(padEdge: 56.475)).filter { $0.check == .silkscreen }
        XCTAssertEqual(close.map(\.second.id), ["t"], close.map(\.title).joined(separator: "\n"))
        XCTAssertEqual(try XCTUnwrap(close.first).distance, 0.045 * mm, accuracy: 2)
        XCTAssertEqual(HorizontalBoardClearanceCheck.run(board: board(padEdge: 56.55)).filter { $0.check == .silkscreen }.count, 0)

        // list_pads says where the opening is, which is what a caller needs
        // to see this coming.
        let pad = try XCTUnwrap(HorizontalDispatchBoardGeometry.pads(of: board(padEdge: 56.475)).first)
        let json = HorizontalDispatchBoardGeometry.json(pad, board: board(padEdge: 56.475), outline: true)
        XCTAssertEqual(json.double("mask_expansion_mm") ?? 0, 0.07, accuracy: 1e-6)
        let opening = try XCTUnwrap((json["mask_opening"] as? [JSONDictionary])?.first?.dictionary("box_mm"))
        XCTAssertEqual(opening.double("min_x_mm") ?? 0, 56.405, accuracy: 1e-6)
        XCTAssertEqual(json.dictionary("at_mm")?.double("x_mm") ?? 0, 56.725, accuracy: 1e-6)
    }

    /// A plane's fill is an item with its holes: a point in a hole of it is
    /// as far from the copper as the hole's edge is.
    func testAPlaneIsMeasuredToItsFillAndNotItsOutline() throws {
        var fixture = Fixture()
        let outer = [p(0, 0), p(10, 0), p(10, 10), p(0, 10)]
        let hole = [p(4, 4), p(6, 4), p(6, 6), p(4, 6)]
        fixture.planes = [HorizontalPlane(id: "plane", netID: "net-a", polygonID: "poly", layer: HorizontalBoardLayers.topCopper, priority: 0,
                                          fillStyle: "solid", minWidth: 0, keepOrphans: false,
                                          fragments: [HorizontalPlaneFragment(paths: [outer, hole], orphan: false)], fallbackPolygon: nil)]
        let items = HorizontalBoardItems(board: fixture.board)
        let plane = try XCTUnwrap(items.items.first { $0.kind == .plane })
        XCTAssertEqual(HorizontalShapeGap.between(.disc(p(5, 5), radius: 0), plane.shape)?.distance ?? -1, 1 * mm, accuracy: 1)
        XCTAssertEqual(HorizontalShapeGap.between(.disc(p(2, 2), radius: 0), plane.shape)?.distance ?? -1, 0, accuracy: 1)
        XCTAssertEqual(HorizontalShapeGap.between(.disc(p(12, 5), radius: 0.5 * mm), plane.shape)?.distance ?? -1, 1.5 * mm, accuracy: 1)
    }

    /// What the rules ask of a pair is what the check asks: nothing of one
    /// net's copper, the copper rule's number between two nets, the
    /// copper-to-other rule's to the board's edge.
    func testRequiredClearanceFollowsTheRules() throws {
        var fixture = Fixture()
        fixture.rules = Fixture.clearanceRules(0.125)
        fixture.vias = [Fixture.via("v", at: p(5, 5), net: "net-a")]
        fixture.tracks = [Fixture.track("same", p(1, 1), p(2, 1), net: "net-a"), Fixture.track("other", p(1, 2), p(2, 2), net: "net-b")]
        let board = fixture.board
        let items = HorizontalBoardItems(board: board)
        func item(_ id: String) throws -> HorizontalBoardItem { try XCTUnwrap(items.items.first { $0.id == id }) }
        let edge = try XCTUnwrap(items.items.first { $0.kind == .boardEdge })
        XCTAssertNil(HorizontalBoardItems.required(try item("v"), try item("same"), layer: 0, rules: board.rules))
        XCTAssertEqual(HorizontalBoardItems.required(try item("v"), try item("other"), layer: 0, rules: board.rules)?.clearance, 0.125 * mm)
        XCTAssertEqual(HorizontalBoardItems.required(try item("v"), try item("other"), layer: 0, rules: board.rules)?.ruleID, "rule-cu")
        XCTAssertEqual(HorizontalBoardItems.required(edge, try item("other"), layer: 0, rules: board.rules)?.kind, .clearanceCopperOther)
    }

    /// A keepout bars the kinds of copper it lists and no other, as the
    /// clearance check and the pour read it: one that lists vias asks
    /// nothing of a track, and one that lists none asks nothing of anything.
    func testAKeepoutAsksOnlyOfTheCopperItLists() throws {
        var fixture = Fixture()
        fixture.vias = [Fixture.via("v", at: p(5, 5), net: "net-a")]
        fixture.tracks = [Fixture.track("t", p(1, 1), p(2, 1), net: "net-a")]
        func keepout(_ id: String, types: [String]) -> HorizontalKeepout {
            let ring = HorizontalPolygon(id: "\(id)-polygon", vertices: [p(0, 0), p(8, 0), p(8, 8), p(0, 8)], layer: HorizontalBoardLayers.topCopper)
            return HorizontalKeepout(id: id, polygonID: ring.id, polygon: ring, keepoutClass: "", allCopperLayers: false,
                                     exposedCopperOnly: false, copperPatchTypes: types)
        }
        fixture.keepouts = [keepout("vias", types: ["via"]), keepout("none", types: [])]
        let board = fixture.board
        let items = HorizontalBoardItems(board: board)
        func item(_ id: String) throws -> HorizontalBoardItem { try XCTUnwrap(items.items.first { $0.id == id }) }
        XCTAssertNotNil(HorizontalBoardItems.required(try item("vias"), try item("v"), layer: 0, rules: board.rules))
        XCTAssertNil(HorizontalBoardItems.required(try item("vias"), try item("t"), layer: 0, rules: board.rules))
        XCTAssertNil(HorizontalBoardItems.required(try item("none"), try item("v"), layer: 0, rules: board.rules))
        XCTAssertNil(HorizontalBoardItems.required(try item("t"), try item("none"), layer: 0, rules: board.rules))
        // So a probe for a via finds only the first in its way.
        let probe = HorizontalBoardProbe(board: board, items: items)
        let blocker = probe.firstViolation(HorizontalBoardProbe.via(at: p(4, 4), diameter: 0.35 * mm, net: "net-b"), layer: 0)
        XCTAssertEqual(blocker, items.items.firstIndex { $0.id == "vias" }.map(HorizontalBoardProbe.Obstacle.item))
        XCTAssertNil(probe.firstViolation(HorizontalBoardProbe.track([p(3, 3), p(4, 3)], width: 0.2 * mm, net: "net-b"), layer: 0))
    }
}
