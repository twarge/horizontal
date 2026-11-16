import XCTest
@testable import HorizontalNative

/// While a route is drawn the cursor snaps to the middle of a track under
/// it, wherever the track lies against the grid.
final class RouteCursorSnapsToTrackTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x, y: y)
    }

    private func index(_ tracks: HorizontalSnapTrack...) -> HorizontalTrackSnapIndex {
        HorizontalTrackSnapIndex(tracks: tracks)
    }

    func testOffGridHorizontalTrackSnapsToItsCentrelineOnTheGridInX() {
        // A track at y = 1 234 567, off a 1 mm grid.
        let track = HorizontalSnapTrack(from: point(0, 1_234_567), to: point(10_000_000, 1_234_567), halfWidth: 100_000)
        let snapped = index(track).snap(
            pointer: point(3_100_000, 1_280_000),
            gridPoint: point(3_000_000, 1_000_000),
            reach: 20_000,
            gridReach: 500_000)
        XCTAssertEqual(snapped, point(3_000_000, 1_234_567))
    }

    func testGridLineTooFarAlongTheTrackGivesThePointUnderThePointer() {
        let track = HorizontalSnapTrack(from: point(0, 1_234_567), to: point(10_000_000, 1_234_567), halfWidth: 100_000)
        let snapped = index(track).snap(
            pointer: point(3_400_000, 1_280_000),
            gridPoint: point(3_000_000, 1_000_000),
            reach: 20_000,
            gridReach: 50_000)
        XCTAssertEqual(snapped, point(3_400_000, 1_234_567))
    }

    func testGridPointOnTheTrackIsKept() {
        let track = HorizontalSnapTrack(from: point(0, 1_000_000), to: point(10_000_000, 1_000_000), halfWidth: 100_000)
        let snapped = index(track).snap(
            pointer: point(3_100_000, 1_050_000),
            gridPoint: point(3_000_000, 1_000_000),
            reach: 20_000,
            gridReach: 500_000)
        XCTAssertEqual(snapped, point(3_000_000, 1_000_000))
    }

    func testDiagonalTrackSnapsToAWholePointExactlyOnIt() throws {
        let track = HorizontalSnapTrack(from: point(123, 457), to: point(5_000_123, 5_000_457), halfWidth: 100_000)
        let snapped = try XCTUnwrap(index(track).snap(
            pointer: point(2_050_000, 2_000_000),
            gridPoint: point(2_000_000, 2_000_000),
            reach: 20_000,
            gridReach: 500_000))
        XCTAssertEqual(snapped.x - 123, snapped.y - 457)
        XCTAssertTrue(snapped.x == 2_000_000 || snapped.y == 2_000_000)
        let segment = HorizontalSegment(id: "t", from: track.from, to: track.to, width: 200_000, layer: 0)
        XCTAssertTrue(BoardTrackRouting.pointLiesOnSegment(snapped, segment))
    }

    func testPointerOffTheCopperAndOutOfReachSnapsToNothing() {
        let track = HorizontalSnapTrack(from: point(0, 1_234_567), to: point(10_000_000, 1_234_567), halfWidth: 100_000)
        XCTAssertNil(index(track).snap(
            pointer: point(3_000_000, 1_400_000),
            gridPoint: point(3_000_000, 1_000_000),
            reach: 20_000,
            gridReach: 500_000))
    }

    func testNearestOfTwoTracksWins() {
        let near = HorizontalSnapTrack(from: point(0, 1_234_567), to: point(10_000_000, 1_234_567), halfWidth: 100_000)
        let far = HorizontalSnapTrack(from: point(0, 1_400_001), to: point(10_000_000, 1_400_001), halfWidth: 100_000)
        let snapped = index(far, near).snap(
            pointer: point(3_000_000, 1_310_000),
            gridPoint: nil,
            reach: 20_000,
            gridReach: 500_000)
        XCTAssertEqual(snapped, point(3_000_000, 1_234_567))
    }

    func testIndexAgreesWithAScanOnADenseBoard() {
        var tracks = [HorizontalSnapTrack]()
        for row in 0..<200 {
            let y = Double(row) * 300_007 + 13
            tracks.append(HorizontalSnapTrack(from: point(0, y), to: point(50_000_000, y), halfWidth: 75_000))
        }
        let all = HorizontalTrackSnapIndex(tracks: tracks)
        for row in stride(from: 0, to: 200, by: 7) {
            let y = Double(row) * 300_007 + 13
            let snapped = all.snap(
                pointer: point(12_345_678, y + 40_000), gridPoint: nil, reach: 10_000, gridReach: 0)
            XCTAssertEqual(snapped, point(12_345_678, y))
        }
    }

    func testSnapTracksAreTheLayersStraightTracksOfTheRoutesNet() {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/snap-tracks.hprj"), uuid: "b", name: "snap",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.tracks = [
            HorizontalSegment(id: "a", from: point(0, 0), to: point(10, 0), width: 4, layer: 0, netID: "n1"),
            HorizontalSegment(id: "b", from: point(0, 5), to: point(10, 5), width: 4, layer: 0, netID: "n2"),
            HorizontalSegment(id: "c", from: point(0, 9), to: point(10, 9), width: 4, layer: -100, netID: "n1"),
            HorizontalSegment(id: "d", from: point(0, 20), to: point(10, 30), width: 4, layer: 0, center: point(0, 30), netID: "n1")
        ]
        XCTAssertEqual(BoardTrackRouting.snapTracks(on: 0, netID: nil, in: board).count, 2)
        XCTAssertEqual(
            BoardTrackRouting.snapTracks(on: 0, netID: "N1", in: board),
            [HorizontalSnapTrack(from: point(0, 0), to: point(10, 0), halfWidth: 2)])
    }
}
