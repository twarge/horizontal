import XCTest
@testable import HorizontalNative

/// Unit tests for the pure board→router-world extractor that feeds the PNS
/// router. No GUI and no C ABI — just the field/net/layer/clearance mapping.
final class HorizontalRouterWorldTests: XCTestCase {

    // MARK: - Fixture

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    /// A two-layer board with the given copper objects. Everything else empty.
    private func makeBoard(
        netDetails: [String: HorizontalNetDetails] = [:],
        rules: HorizontalBoardRules = .empty,
        tracks: [HorizontalSegment] = [],
        vias: [HorizontalMarker] = [],
        packagePads: [HorizontalPolygon] = [],
        polygons: [HorizontalPolygon] = [],
        copperLayers: [Int] = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/test.hprj"),
            uuid: "board",
            name: "test",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: copperLayers.map {
                HorizontalBoardStackupLayer(layer: $0, copperThickness: 35_000, substrateThickness: 1_500_000)
            },
            userLayers: [],
            junctions: [:],
            junctionNetIDs: [:],
            netDetails: netDetails,
            rules: rules,
            tracks: tracks,
            netTies: [],
            lines: [],
            arcs: [],
            connectionLines: [],
            airwires: [],
            polygons: polygons,
            planes: [],
            keepouts: [],
            dimensions: [],
            decals: [],
            holes: [],
            vias: vias,
            viaHoles: [],
            packages: [],
            packagePads: packagePads,
            packageHoles: [],
            packagePolygons: [],
            packageLines: [],
            packageArcs: [],
            packageTexts: [],
            texts: [],
            boardPanels: [],
            physicalBounds: .empty,
            bounds: .empty
        )
    }

    private func netDetails(_ ids: [String]) -> [String: HorizontalNetDetails] {
        Dictionary(uniqueKeysWithValues: ids.map {
            ($0, HorizontalNetDetails(id: $0, name: $0.uppercased(), netClassID: nil, netClassName: nil,
                                   portDirection: nil, powerSymbolStyle: nil))
        })
    }

    private func squarePad(id: String, cx: Double, cy: Double, half: Double, layer: Int?, net: String?) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(cx - half, cy - half), p(cx + half, cy - half),
                       p(cx + half, cy + half), p(cx - half, cy + half)],
            layer: layer,
            netID: net
        )
    }

    // MARK: - Net codes

    func testNetCodesAreDenseSortedAndInvertible() {
        let board = makeBoard(netDetails: netDetails(["bbb", "aaa", "ccc"]))
        let world = HorizontalRouterWorld.extract(from: board)

        XCTAssertEqual(world.netCount, 3)
        // Sorted ascending → deterministic codes.
        XCTAssertEqual(world.codeForNetID["aaa"], 0)
        XCTAssertEqual(world.codeForNetID["bbb"], 1)
        XCTAssertEqual(world.codeForNetID["ccc"], 2)
        XCTAssertEqual(world.netIDForCode[0], "aaa")
        XCTAssertEqual(world.netCode(for: "AAA"), 0, "lookup normalizes case")
        XCTAssertEqual(world.netCode(for: nil), -1)
        XCTAssertEqual(world.netCode(for: "missing"), -1)
    }

    func testNetCodesIncludeNetsReferencedOnlyByObjects() {
        // A track references a net not in netDetails — it must still get a code.
        let board = makeBoard(
            netDetails: netDetails(["aaa"]),
            tracks: [HorizontalSegment(id: "t", from: p(0, 0), to: p(1000, 0), width: 200_000, layer: 0, netID: "zzz")]
        )
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.netCount, 2)
        XCTAssertNotNil(world.codeForNetID["zzz"])
    }

    // MARK: - Tracks

    func testCopperTracksExtractedNonCopperSkipped() {
        let board = makeBoard(
            netDetails: netDetails(["aaa"]),
            tracks: [
                HorizontalSegment(id: "cu", from: p(0, 0), to: p(5000, 0), width: 250_000, layer: 0, netID: "aaa"),
                HorizontalSegment(id: "silk", from: p(0, 0), to: p(1, 0), width: 100_000,
                               layer: HorizontalBoardLayers.topSilkscreen, netID: "aaa"),
                HorizontalSegment(id: "zerowidth", from: p(0, 0), to: p(1, 0), width: 0, layer: 0, netID: "aaa"),
            ]
        )
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.tracks.count, 1)
        let track = world.tracks[0]
        XCTAssertEqual(track.layer, 0)
        XCTAssertEqual(track.width, 250_000)
        XCTAssertEqual(track.netCode, world.netCode(for: "aaa"))
        XCTAssertFalse(track.center != nil)
        // Stable id maps back to the Horizon segment id.
        XCTAssertEqual(world.segmentIDForTrackID[track.id], "cu")
    }

    func testArcTrackCarriesCenter() {
        let board = makeBoard(
            netDetails: netDetails(["aaa"]),
            tracks: [HorizontalSegment(id: "a", from: p(0, 0), to: p(1000, 1000),
                                    width: 200_000, layer: 0, center: p(1000, 0), netID: "aaa")]
        )
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.tracks.count, 1)
        XCTAssertEqual(world.tracks[0].center, p(1000, 0))
    }

    // MARK: - Pads

    func testSMDPadIsSingleLayerSolid() {
        let board = makeBoard(
            netDetails: netDetails(["aaa"]),
            packagePads: [squarePad(id: "pkg/pad/1", cx: 0, cy: 0, half: 500, layer: 0, net: "aaa")]
        )
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.solids.count, 1)
        let solid = world.solids[0]
        XCTAssertEqual(solid.layerMin, 0)
        XCTAssertEqual(solid.layerMax, 0)
        XCTAssertEqual(solid.netCode, world.netCode(for: "aaa"))
        XCTAssertGreaterThanOrEqual(solid.points.count, 4)
    }

    func testLayerlessPadSpansAllCopper() {
        let board = makeBoard(
            netDetails: netDetails(["aaa"]),
            packagePads: [squarePad(id: "pkg/pad/1", cx: 0, cy: 0, half: 500, layer: nil, net: "aaa")]
        )
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.solids.count, 1)
        XCTAssertEqual(world.solids[0].layerMin, HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(world.solids[0].layerMax, HorizontalBoardLayers.topCopper)
    }

    func testNonCopperPadSkipped() {
        let board = makeBoard(
            packagePads: [squarePad(id: "pkg/pad/1", cx: 0, cy: 0, half: 500,
                                    layer: HorizontalBoardLayers.topPaste, net: nil)]
        )
        XCTAssertEqual(HorizontalRouterWorld.extract(from: board).solids.count, 0)
    }

    // MARK: - Vias

    func testViaExtractedWithLayerSpan() {
        let board = makeBoard(
            netDetails: netDetails(["aaa"]),
            vias: [HorizontalMarker(id: "v1", position: p(1000, 2000), size: 600_000, holeSize: 300_000,
                                 layer: nil, connectedLayers: [0, -100], netID: "aaa")]
        )
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.vias.count, 1)
        let via = world.vias[0]
        XCTAssertEqual(via.layerStart, 0, "top is the max horizon layer")
        XCTAssertEqual(via.layerEnd, -100, "bottom is the min horizon layer")
        XCTAssertEqual(via.diameter, 600_000)
        XCTAssertEqual(via.drill, 300_000)
        XCTAssertEqual(world.markerIDForViaID[via.id], "v1")
    }

    // MARK: - Outline

    func testOutlinePolygonBecomesContour() {
        let outline = HorizontalPolygon(
            id: "outline",
            vertices: [p(0, 0), p(10_000, 0), p(10_000, 10_000), p(0, 10_000)],
            layer: HorizontalBoardLayers.outline,
            netID: nil
        )
        let board = makeBoard(polygons: [outline])
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.contours.count, 1)
        XCTAssertTrue(world.contours[0].closed)
        XCTAssertGreaterThanOrEqual(world.contours[0].points.count, 4)
    }

    // MARK: - Copper layer count & clearance matrix

    func testCopperLayerCountFromStackup() {
        let board = makeBoard(copperLayers: [0, -1, -2, -100]) // 4-layer
        XCTAssertEqual(HorizontalRouterWorld.extract(from: board).copperLayerCount, 4)
    }

    func testClearanceMatrixIsSquareSymmetricAndDefaultedWithEmptyRules() {
        let board = makeBoard(netDetails: netDetails(["aaa", "bbb"]))
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.netCount, 2)
        XCTAssertEqual(world.clearanceTable.count, 4)
        for value in world.clearanceTable {
            XCTAssertEqual(value, Int64(HorizontalRuleClearanceCopper.defaultClearance))
        }
    }

    func testClearanceMatrixReflectsACopperRule() {
        let nets = netDetails(["aaa", "bbb"])
        let rulesJSON: [String: Any] = [
            "clearance_copper": [
                "r0": [
                    "enabled": true, "order": 0, "layer": 10000,
                    "match_1": ["mode": "all"], "match_2": ["mode": "all"],
                    "clearances": [["types": ["track", "track"], "clearance": 250_000]],
                ],
            ],
        ]
        let board = makeBoard(netDetails: nets, rules: HorizontalBoardRules(rules: rulesJSON, netDetails: nets))
        let world = HorizontalRouterWorld.extract(from: board)
        XCTAssertEqual(world.netCount, 2)
        let a = world.netCode(for: "aaa")
        let b = world.netCode(for: "bbb")
        XCTAssertEqual(world.clearanceTable[a * world.netCount + b], 250_000)
        XCTAssertEqual(world.clearanceTable[b * world.netCount + a], 250_000, "matrix is symmetric")
    }
}
