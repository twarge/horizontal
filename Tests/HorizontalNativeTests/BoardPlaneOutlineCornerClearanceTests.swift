import XCTest
@testable import HorizontalNative

/// A plane poured on a board with a notch in it keeps the board edge
/// clearance from the notch's corner. The pour goes round that corner in
/// chords, and chords too few cut inside the arc they stand for: the fill
/// then came nearer the corner than the rules allow, and the clearance
/// check, which measures to the corner itself, reported it.
final class BoardPlaneOutlineCornerClearanceTests: XCTestCase {
    private let mm = 1_000_000.0
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    /// A 60 mm board with its upper right quarter cut away, so the outline
    /// has an inside corner at the origin, and a plane of GND all over it.
    private func board(minWidth: Double) -> HorizontalBoard {
        var plane = HorizontalPlane(id: "plane", netID: "gnd", polygonID: "poly", layer: 0, priority: 0, fillStyle: "solid",
                                    minWidth: minWidth, keepOrphans: false, fragments: [])
        plane.fallbackPolygon = HorizontalPolygon(
            id: "poly", vertices: [p(-35, -35), p(35, -35), p(35, 35), p(-35, 35)], layer: 0, netID: "gnd")
        plane.fromRules = false
        plane.settings.minWidth = Int(minWidth)
        let outline = HorizontalPolygon(
            id: "outline", vertices: [p(-30, -30), p(30, -30), p(30, 0), p(0, 0), p(0, 30), p(-30, 30)],
            layer: HorizontalBoardLayers.outline)
        let anchor = HorizontalPolygon(
            id: "anchor/pad/9/shape/a", vertices: [p(-25.5, -25.5), p(-24.5, -25.5), p(-24.5, -24.5), p(-25.5, -24.5)],
            layer: 0, netID: "gnd")
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/notch.hprj"), uuid: "b", name: "t", grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:],
            netDetails: ["gnd": HorizontalNetDetails(id: "gnd", name: "GND")],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [outline], planes: [plane], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [],
            packagePads: [anchor], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty)
    }

    /// The radius of the round the pour cuts at the corner follows the
    /// plane's minimum width, and with it how the chords fall.
    func testAFillClearsTheBoardsInsideCornerAtAnyMinimumWidth() throws {
        var gaps = [Double]()
        for width in stride(from: 0.0, through: 1.0, by: 0.05) {
            var poured = board(minWidth: width * mm)
            poured.planes = HorizontalBoardPlaneUpdater.updateAllPlanes(in: poured).planes
            let fragment = try XCTUnwrap(poured.planes.first?.fragments.first, "the plane pours at \(width) mm")
            let findings = HorizontalBoardClearanceCheck.run(board: poured)
            XCTAssertEqual(findings.map { "\($0.title): \($0.detail)" }, [], "a minimum width of \(width) mm")

            let outer = try XCTUnwrap(fragment.paths.first)
            var nearest = Double.infinity
            for index in outer.indices {
                nearest = min(nearest, HorizontalRouteClearanceProbe.segmentDistance(
                    .zero, .zero, outer[index], outer[(index + 1) % outer.count]))
            }
            gaps.append(nearest)
        }
        // Every width leaves the same gap to within the pour's allowance.
        let least = try XCTUnwrap(gaps.min()), most = try XCTUnwrap(gaps.max())
        XCTAssertLessThan(most - least, 10_000, "the gap to the corner, by minimum width: \(gaps)")
    }
}
