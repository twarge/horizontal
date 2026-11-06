import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Renders a real project's 3D scene offscreen, with every component
/// highlighted and a few selected, then a few highlighted and lit, the way
/// the app would draw it. Opt-in: set
/// HORIZONTAL_SCENE_SMOKE_PROJECT to a project path. Run with
/// METAL_DEVICE_WRAPPER_TYPE=1 in the environment and Metal's API validation
/// layer checks every draw, which is how a degenerate mesh gets a message
/// instead of a crash.
final class BoardSceneRenderSmokeTests: XCTestCase {
    @MainActor
    func testTheSceneRendersWithEverythingHighlighted() async throws {
        guard let path = ProcessInfo.processInfo.environment["HORIZONTAL_SCENE_SMOKE_PROJECT"], !path.isEmpty else {
            throw XCTSkip("set HORIZONTAL_SCENE_SMOKE_PROJECT to a project path to render its 3D scene")
        }
        let url = URL(fileURLWithPath: path)
        let snapshot = try HorizontalDispatchSession.readSnapshot(url: url)
        let project = try HorizontalDispatchSession.project(from: snapshot, url: url)
        let board = try XCTUnwrap(project.board, "the project has no board")

        let cache = BoardSceneSceneCache()
        let scene: BoardSceneEntities = await withCheckedContinuation { continuation in
            if let ready = cache.scene(for: board, onReady: { built in continuation.resume(returning: built) }) {
                continuation.resume(returning: ready)
            }
        }
        let componentIDs = Set(board.packages.compactMap(\.componentID))
        XCTAssertFalse(componentIDs.isEmpty, "the board places no components")

        func render() async throws {
            _ = try await BoardSceneOffscreenRenderer.render(
                scene,
                camera: horizonSceneCameraState(for: .defaultPerspective, board: board),
                projection: .perspective,
                size: CGSize(width: 640, height: 480),
                background: BoardSceneColor(red: 0, green: 0, blue: 0)
            )
        }

        // Plain, highlighted, then selected as well: each is a render pass the
        // app makes, and each has to survive the validation layer.
        try await render()
        scene.applyHighlight(componentIDs: componentIDs)
        try await render()
        scene.applySelection(componentIDs: Set(componentIDs.prefix(3)))
        try await render()
        // As many as light their surroundings: each a point light as well.
        let lit = Set(componentIDs.sorted().prefix(BoardSceneEntities.highlightLightBudget))
        scene.applyHighlight(componentIDs: lit)
        XCTAssertEqual(scene.highlightLights.count, lit.count)
        try await render()
        scene.applyHighlight(componentIDs: [])
        scene.applySelection(componentIDs: [])
        try await render()
        XCTAssertEqual(scene.markCount, 0, "clearing removes every box")
    }
}
