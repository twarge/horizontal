import Foundation
import HorizontalProjectIO
import SceneKit
import XCTest
@testable import HorizontalNative

/// Renders a real project's 3D scene offscreen, with every component
/// highlighted and a few selected, the way the app would draw it. Opt-in: set
/// HORIZONTAL_SCENE_SMOKE_PROJECT to a project path. Run with
/// METAL_DEVICE_WRAPPER_TYPE=1 in the environment and Metal's API validation
/// layer checks every draw, which is how a degenerate geometry — the kind that
/// aborts the app inside SceneKit — gets a message instead of a crash.
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
        let nodes: BoardSceneNodes = await withCheckedContinuation { continuation in
            if let ready = cache.nodes(for: board) { built in continuation.resume(returning: built) } {
                continuation.resume(returning: ready)
            }
        }
        let componentIDs = Set(board.packages.compactMap(\.componentID))
        XCTAssertFalse(componentIDs.isEmpty, "the board places no components")

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = nodes.scene
        renderer.pointOfView = nodes.cameraNode
        renderer.autoenablesDefaultLighting = true
        let size = CGSize(width: 640, height: 480)

        // Plain, highlighted, then selected as well: each is a render pass the
        // app makes, and each has to survive the validation layer.
        _ = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .none)
        nodes.applyHighlight(componentIDs: componentIDs)
        _ = renderer.snapshot(atTime: 0.1, with: size, antialiasingMode: .none)
        nodes.applySelection(componentIDs: Set(componentIDs.prefix(3)))
        _ = renderer.snapshot(atTime: 0.2, with: size, antialiasingMode: .none)
        nodes.applyHighlight(componentIDs: [])
        nodes.applySelection(componentIDs: [])
        _ = renderer.snapshot(atTime: 0.3, with: size, antialiasingMode: .none)
        let marks = nodes.scene.rootNode.childNodes(passingTest: { node, _ in node.name == "highlight" || node.name == "selection" })
        XCTAssertTrue(marks.isEmpty, "clearing removes every box")
    }
}
