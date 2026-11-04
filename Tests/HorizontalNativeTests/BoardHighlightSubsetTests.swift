import XCTest
@testable import HorizontalNative

/// A highlight draws what it highlights again over the dimmed board, as the
/// board draws it, so it changes nothing it shows. `BoardHighlightSubset` is
/// what it draws: the highlighted nets' copper and the highlighted
/// components' packages, and nothing else.
final class BoardHighlightSubsetTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func square(_ id: String, at x: Double, layer: Int = 0, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(x, 0), p(x + 600_000, 0), p(x + 600_000, 600_000), p(x, 600_000)],
            layer: layer,
            netID: net
        )
    }

    private func track(_ id: String, net: String?) -> HorizontalSegment {
        HorizontalSegment(id: id, from: p(0, 0), to: p(5_000_000, 0), width: 200_000, layer: 0, netID: net)
    }

    private func makeBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/t.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [track("t-gnd", net: "GND"), track("t-vcc", net: "VCC"), track("t-none", net: nil)],
            netTies: [], lines: [], arcs: [], connectionLines: [],
            airwires: [track("a-gnd", net: "GND"), track("a-vcc", net: "VCC")],
            polygons: [
                square("poly-gnd", at: 0, net: "GND"),
                square("outline", at: 0, layer: HorizontalBoardLayers.outline, net: "GND")
            ],
            planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [
                HorizontalMarker(id: "via-gnd", position: p(0, 0), size: 600_000, layer: 0, netID: "GND"),
                HorizontalMarker(id: "via-vcc", position: p(1_000_000, 0), size: 600_000, layer: 0, netID: "VCC")
            ],
            viaHoles: [
                // A via's drill is "<via id>/hole", as the loader names it.
                HorizontalHole(id: "via-gnd/hole", position: p(0, 0), diameter: 300_000, plated: true),
                HorizontalHole(id: "via-vcc/hole", position: p(1_000_000, 0), diameter: 300_000, plated: true)
            ],
            packages: [
                HorizontalPlacement(id: "pkg1", position: p(0, 0), angle: 0, mirrored: false, label: "U1", componentID: "U1-ID"),
                HorizontalPlacement(id: "pkg2", position: p(9_000_000, 0), angle: 0, mirrored: false, label: "R1", componentID: "r1-id")
            ],
            packagePads: [
                square("pkg1/pad/1", at: 0, net: "GND"),
                square("pkg1/pad/2", at: 1_000_000, net: "VCC"),
                square("pkg2/pad/1", at: 9_000_000, net: "GND"),
                square("pkg2/pad/2", at: 10_000_000, net: "VCC")
            ],
            packageHoles: [],
            packagePolygons: [],
            packageLines: [
                HorizontalSegment(id: "pkg1/line/silk", from: p(0, 0), to: p(1, 1), width: 0, layer: 20),
                HorizontalSegment(id: "pkg2/line/silk", from: p(0, 0), to: p(1, 1), width: 0, layer: 20)
            ],
            packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    func testANetsHighlightIsItsCopperAlone() {
        let subset = BoardHighlightSubset.board(makeBoard(), netIDs: ["gnd"], componentIDs: [])
        XCTAssertEqual(subset.tracks.map(\.id), ["t-gnd"], "ids are matched lowercased")
        XCTAssertEqual(subset.airwires.map(\.id), ["a-gnd"])
        XCTAssertEqual(subset.vias.map(\.id), ["via-gnd"])
        XCTAssertEqual(subset.viaHoles.map(\.id), ["via-gnd/hole"], "a via's hole, on no net of its own, goes with its via")
        XCTAssertEqual(subset.packagePads.map(\.id), ["pkg1/pad/1", "pkg2/pad/1"])
        XCTAssertEqual(subset.polygons.map(\.id), ["poly-gnd"], "the board outline is no copper of the net")
        XCTAssertTrue(subset.packages.isEmpty, "a net's pads are drawn without their packages")
        XCTAssertTrue(subset.packageLines.isEmpty)
    }

    func testAComponentsHighlightIsItsPackageWhole() {
        let subset = BoardHighlightSubset.board(makeBoard(), netIDs: [], componentIDs: ["u1-id"])
        XCTAssertEqual(subset.packages.map(\.id), ["pkg1"])
        XCTAssertEqual(subset.packagePads.map(\.id), ["pkg1/pad/1", "pkg1/pad/2"], "every pad, whatever its net")
        XCTAssertEqual(subset.packageLines.map(\.id), ["pkg1/line/silk"])
        XCTAssertTrue(subset.tracks.isEmpty)
        XCTAssertTrue(subset.vias.isEmpty)
        XCTAssertTrue(subset.airwires.isEmpty)
    }

    func testNothingHighlightedDrawsNothing() {
        let subset = BoardHighlightSubset.board(makeBoard(), netIDs: [], componentIDs: [])
        XCTAssertTrue(subset.tracks.isEmpty)
        XCTAssertTrue(subset.polygons.isEmpty)
        XCTAssertTrue(subset.packagePads.isEmpty)
        XCTAssertTrue(subset.viaHoles.isEmpty)
        XCTAssertTrue(subset.packages.isEmpty)
    }
}
