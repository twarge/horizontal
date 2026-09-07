import Foundation
import XCTest
@testable import HorizontalNative

/// Plane copper in 3D is drilled like every other copper: the pour treats a
/// plated hole as copper to connect to, so its fill and thermal spokes run
/// across the hole; the board has a hole there.
final class BoardScenePlaneDrillTests: XCTestCase {
    private let mm = 1_000_000.0

    private func square(center: HorizontalPoint, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y + half),
            HorizontalPoint(x: center.x - half, y: center.y + half),
        ]
    }

    private func board(holeAt position: HorizontalPoint) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: "b", name: "B", url: URL(fileURLWithPath: "/tmp/b"))
        var hole = HorizontalHole(
            id: "pkg/pad/p1/hole/h0",
            position: position,
            diameter: 1 * mm,
            length: 1 * mm,
            shape: .round,
            plated: true,
            parameterClass: "hole"
        )
        hole.netID = "gnd"
        board.packageHoles.append(hole)
        return board
    }

    private func area(_ path: [HorizontalPoint]) -> Double {
        abs(HorizontalBoardOutlines.signedArea(path))
    }

    func testAPlatedHoleIsCutOutOfThePlaneCopper() throws {
        let center = HorizontalPoint(x: 5 * mm, y: 5 * mm)
        let drills = BoardSceneFactory.drillCutoutPaths(for: HorizontalBoardLayers.topCopper, board: board(holeAt: center))
        XCTAssertEqual(drills.count, 1)

        let fragment = HorizontalPlaneFragment(paths: [square(center: center, half: 5 * mm)], orphan: false)
        let fragments = BoardSceneFactory.planeSceneFragments(fragment, drillCutouts: drills)
        let paths = try XCTUnwrap(fragments.first).sorted { area($0) > area($1) }
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(paths.count, 2, "the outer and the drill")
        let hole = HorizontalRect(points: paths[1])
        XCTAssertEqual(hole.maxX - hole.minX, 1 * mm, accuracy: 0.02 * mm)
        XCTAssertEqual(hole.maxY - hole.minY, 1 * mm, accuracy: 0.02 * mm)
        XCTAssertEqual(area(paths[0]) - area(paths[1]), 100 * mm * mm - .pi * 0.25 * mm * mm, accuracy: 0.1 * mm * mm)
    }

    func testThePlanesOwnHolesSurviveTheDrillCut() throws {
        let center = HorizontalPoint(x: 5 * mm, y: 5 * mm)
        let drills = BoardSceneFactory.drillCutoutPaths(for: HorizontalBoardLayers.topCopper, board: board(holeAt: center))
        // A thermal gap around some other pad, in the fragment's corner.
        let gap = square(center: HorizontalPoint(x: 8 * mm, y: 8 * mm), half: 1 * mm)
        let fragment = HorizontalPlaneFragment(paths: [square(center: center, half: 5 * mm), gap], orphan: false)
        let paths = try XCTUnwrap(BoardSceneFactory.planeSceneFragments(fragment, drillCutouts: drills).first)
        XCTAssertEqual(paths.count, 3, "the outer, the gap and the drill")
    }

    /// The pour's holes run clockwise and the drills counter-clockwise; the
    /// two must still add up where they overlap, not cancel.
    func testADrillOverlappingAThermalGapHoleStillCutsCopper() throws {
        let center = HorizontalPoint(x: 5 * mm, y: 5 * mm)
        // Thermal gap: a 2 mm square at (7...9, 7...9). Drill: 1 mm across at
        // (7, 8), half inside the gap, half in copper.
        let gap = square(center: HorizontalPoint(x: 8 * mm, y: 8 * mm), half: 1 * mm)
        let drills = BoardSceneFactory.drillCutoutPaths(for: HorizontalBoardLayers.topCopper, board: board(holeAt: HorizontalPoint(x: 7 * mm, y: 8 * mm)))
        let fragment = HorizontalPlaneFragment(paths: [square(center: center, half: 5 * mm), Array(gap.reversed())], orphan: false)
        let paths = try XCTUnwrap(BoardSceneFactory.planeSceneFragments(fragment, drillCutouts: drills).first).sorted { area($0) > area($1) }
        XCTAssertEqual(paths.count, 2, "the gap and the drill merge into one hole")
        let copper = area(paths[0]) - paths.dropFirst().map(area).reduce(0, +)
        let halfDrill = Double.pi * 0.25 * mm * mm / 2
        XCTAssertEqual(copper, 100 * mm * mm - 4 * mm * mm - halfDrill, accuracy: 0.02 * mm * mm)
    }

    func testDrillsAwayFromTheFragmentLeaveItUntouched() {
        let drills = BoardSceneFactory.drillCutoutPaths(for: HorizontalBoardLayers.topCopper, board: board(holeAt: HorizontalPoint(x: 30 * mm, y: 30 * mm)))
        let fragment = HorizontalPlaneFragment(paths: [square(center: HorizontalPoint(x: 5 * mm, y: 5 * mm), half: 5 * mm)], orphan: false)
        XCTAssertEqual(BoardSceneFactory.planeSceneFragments(fragment, drillCutouts: drills), [fragment.paths])
    }
}
