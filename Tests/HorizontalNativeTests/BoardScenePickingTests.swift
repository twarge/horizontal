import simd
import XCTest
@testable import HorizontalNative

/// A click in the 3D view picks the part whose model it lands on first; the
/// board in front of a part hides it, and a part on a hidden group can't be
/// picked. Models drawn as instances of one mesh are picked one by one.
@MainActor
final class BoardScenePickingTests: XCTestCase {
    private func scene(extraParts: Int = 0) -> BoardSceneEntities {
        let board = HorizontalBoard.poolEditorBoard(uuid: "pick", name: "Pick", url: URL(fileURLWithPath: "/tmp/pick"))
        let asset = BoardSceneModelLibrary.shared.boxAsset(
            size: SIMD3(2, 1, 2),
            materials: [BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.5, green: 0.5, blue: 0.5))]
        )
        var description = BoardSceneDescription(board: board, center: .zero, boardThickness: 1.6, boardWidth: 40, boardDepth: 40)
        description.boardBoxMin = SIMD3(-20, -1.1, -20)
        description.boardBoxMax = SIMD3(20, 0.5, 20)
        func placement(_ id: String, at x: Float, y: Float, bottom: Bool = false) -> BoardSceneModelPlacement {
            BoardSceneModelPlacement(
                packageID: id, componentID: "c-\(id)", group: .model, explodeFactor: bottom ? -3 : 3,
                asset: asset, transform: simd_float4x4(translation: SIMD3(x, y, 0))
            )
        }
        // Two of the same model on top (one mesh, two instances), one below.
        description.models = [placement("a", at: -5, y: 1.1), placement("b", at: 5, y: 1.1), placement("under", at: 0, y: -1.7, bottom: true)]
        description.models += (0..<extraParts).map { placement("extra\($0)", at: Float($0) * 3 - 15, y: 1.1) }
        let scene = BoardSceneEntities(description: description)
        scene.applyDisplayOptions(BoardDisplayOptions(), copperColor: .orange, materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil), layerColors: [:])
        return scene
    }

    private func down(atX x: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        (SIMD3(x, 50, 0), SIMD3(0, -1, 0))
    }

    func testAClickFromAbovePicksThePartUnderIt() {
        let scene = scene()
        XCTAssertEqual(scene.statistics.modelDraws, 2, "the two parts on top share one draw")
        XCTAssertEqual(scene.componentID(along: down(atX: -5)), "c-a")
        XCTAssertEqual(scene.componentID(along: down(atX: 5)), "c-b")
        XCTAssertNil(scene.componentID(along: down(atX: 0)), "the board, not the part under it")
        XCTAssertNil(scene.componentID(along: down(atX: 30)), "nothing")
    }

    func testFromBelowThePartUnderneathIsInFront() {
        let scene = scene()
        XCTAssertEqual(scene.componentID(along: (SIMD3(0, -50, 0), SIMD3(0, 1, 0))), "c-under")
    }

    func testHiddenGroupsAndExplodedLayersAreWhereTheViewShowsThem() {
        let scene = scene()
        var options = BoardDisplayOptions()
        options.threeDModelMode = .none
        scene.applyDisplayOptions(options, copperColor: .orange, materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil), layerColors: [:])
        XCTAssertNil(scene.componentID(along: down(atX: -5)), "models hidden")

        options = BoardDisplayOptions()
        options.threeDExplode = 10
        options.threeDBoardBody = false
        scene.applyDisplayOptions(options, copperColor: .orange, materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil), layerColors: [:])
        // Exploded, the top parts ride 30 mm up: a ray level with where they
        // were misses them, one level with where they are now hits.
        XCTAssertNil(scene.componentID(along: (SIMD3(-50, 1.1, 0), SIMD3(1, 0, 0))))
        XCTAssertEqual(scene.componentID(along: (SIMD3(-50, 31.1, 0), SIMD3(1, 0, 0))), "c-a")
    }

    func testMarksFollowTheParts() {
        let scene = scene()
        scene.applyHighlight(componentIDs: ["C-A", "c-under"])
        scene.applySelection(componentIDs: ["c-b"])
        XCTAssertEqual(scene.markCount, 3, "ids match whatever their case")
        scene.applyHighlight(componentIDs: ["c-a"])
        XCTAssertEqual(scene.markCount, 2)
        scene.applyHighlight(componentIDs: [])
        scene.applySelection(componentIDs: [])
        XCTAssertEqual(scene.markCount, 0)
    }

    func testAHighlightLightsTheSideOfTheBoardItsPartIsOn() {
        let scene = scene()
        scene.applyHighlight(componentIDs: ["c-a", "c-under"])
        scene.applySelection(componentIDs: ["c-b"])
        let heights = scene.highlightLights.map { $0.position(relativeTo: nil).y }.sorted()
        XCTAssertEqual(heights.count, 2, "one light a highlighted part, none for the selection")
        XCTAssertLessThan(heights[0], -2.2, "under the part on the bottom, which ends 2.2 mm down")
        XCTAssertGreaterThan(heights[1], 1.6, "over the part on top, which stands 1.6 mm up")
        scene.applyHighlight(componentIDs: [])
        XCTAssertTrue(scene.highlightLights.isEmpty)
    }

    func testPastTheBudgetHighlightsAreBoxesAlone() {
        let budget = BoardSceneEntities.highlightLightBudget
        let scene = scene(extraParts: budget)
        let all = Set((0..<budget).map { "c-extra\($0)" } + ["c-a"])
        scene.applyHighlight(componentIDs: all)
        XCTAssertEqual(scene.markCount, budget + 1)
        XCTAssertTrue(scene.highlightLights.isEmpty, "\(budget + 1) lights would flood the board")
        scene.applyHighlight(componentIDs: all.subtracting(["c-a"]))
        XCTAssertEqual(scene.highlightLights.count, budget, "back within the budget, every part lights again")
    }
}
