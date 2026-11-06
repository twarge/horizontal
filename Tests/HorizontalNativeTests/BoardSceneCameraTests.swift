import simd
import XCTest
@testable import HorizontalNative

/// The 3D view's camera: the presets, the saved state, the gestures' orbit,
/// pan and zoom, and the ray a click casts.
final class BoardSceneCameraTests: XCTestCase {
    private let mm = 1_000_000.0

    private func board(width: Double = 80, depth: Double = 100) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: "cam", name: "Camera", url: URL(fileURLWithPath: "/tmp/camera"))
        board.polygons.append(HorizontalPolygon(id: "outline", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: width * mm, y: 0),
            HorizontalPoint(x: width * mm, y: depth * mm), HorizontalPoint(x: 0, y: depth * mm),
        ], layer: HorizontalBoardLayers.outline))
        return board
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    /// A saved state is SceneKit's SCNMatrix4, m11 to m44: the matrix's
    /// columns one after another, the translation last. States saved by the
    /// SceneKit view open where they were.
    func testTheSavedTransformKeepsSceneKitsLayout() throws {
        var transform = [Float](repeating: 0, count: 16)
        transform[0] = 1; transform[5] = 1; transform[10] = 1; transform[15] = 1
        transform[12] = 3; transform[13] = 4; transform[14] = 5
        let state = HorizontalSceneCameraState(transform: transform)
        let matrix = try XCTUnwrap(state.matrix)
        assertEqual(BoardSceneCameraMath.position(of: matrix), SIMD3(3, 4, 5))
        XCTAssertEqual(HorizontalSceneCameraState(matrix: matrix).transform, transform)
    }

    func testThePresetsLookAtTheBoardFromTheirSide() throws {
        let board = board()
        let top = try XCTUnwrap(horizonSceneCameraState(for: .top, board: board).matrix)
        assertEqual(BoardSceneCameraMath.forward(of: top), SIMD3(0, -1, 0), "top looks down")
        assertEqual(BoardSceneCameraMath.up(of: top), SIMD3(0, 0, -1), "with the board's +y up the view")
        let bottom = try XCTUnwrap(horizonSceneCameraState(for: .bottom, board: board).matrix)
        assertEqual(BoardSceneCameraMath.forward(of: bottom), SIMD3(0, 1, 0), "bottom looks up")
        let perspective = horizonSceneCameraState(for: .defaultPerspective, board: board)
        XCTAssertNil(perspective.orthographicScale)
        let matrix = try XCTUnwrap(perspective.matrix)
        let position = BoardSceneCameraMath.position(of: matrix)
        assertEqual(simd_normalize(-position), BoardSceneCameraMath.forward(of: matrix), "the default looks at the board's centre")
        XCTAssertEqual(simd_length(position), 240, accuracy: 0.01, "from 2.4 board sizes away")
        XCTAssertEqual(horizonSceneCameraState(for: .top, board: board).orthographicScale ?? 0, 160, accuracy: 1e-9)
    }

    func testACameraWithoutATargetTurnsAboutWhereItLooksAtTheBoard() throws {
        let matrix = try XCTUnwrap(horizonSceneCameraState(for: .defaultPerspective, board: board()).matrix)
        assertEqual(BoardSceneCameraMath.orbitTarget(for: matrix), .zero, accuracy: 1e-3)
        // Looking along the board, at its height: the nearest point to its centre.
        let level = BoardSceneCameraMath.lookAt(position: SIMD3(0, 0, 50), target: SIMD3(10, 0, 0), up: SIMD3(0, 1, 0))
        let target = BoardSceneCameraMath.orbitTarget(for: level)
        XCTAssertEqual(target.y, 0, accuracy: 1e-4)
    }

    func testOrbitingKeepsTheDistanceAndTheTarget() throws {
        let start = try XCTUnwrap(horizonSceneCameraState(for: .defaultPerspective, board: board()).matrix)
        var camera = BoardSceneOrbitCamera(matrix: start)
        let distance = camera.distance
        camera.orbit(dx: 120, dy: -45)
        XCTAssertEqual(camera.distance, distance, accuracy: 1e-2)
        assertEqual(camera.target, .zero, accuracy: 1e-3)
        assertEqual(simd_normalize(camera.target - camera.position), BoardSceneCameraMath.forward(of: camera.matrix), accuracy: 1e-3, "still looking at it")
        // A drag to the right turns the board to the right: the camera goes left.
        var turned = BoardSceneOrbitCamera(matrix: BoardSceneCameraMath.lookAt(position: SIMD3(0, 0, 100), target: .zero, up: SIMD3(0, 1, 0)))
        turned.orbit(dx: 20, dy: 0)
        XCTAssertLessThan(turned.position.x, 0)
        // A drag down tips the board's far edge up: the camera goes up.
        var tipped = BoardSceneOrbitCamera(matrix: BoardSceneCameraMath.lookAt(position: SIMD3(0, 0, 100), target: .zero, up: SIMD3(0, 1, 0)))
        tipped.orbit(dx: 0, dy: 20)
        XCTAssertGreaterThan(tipped.position.y, 0)
    }

    func testPanningMovesTheTargetWithTheCameraAndTheBoardWithTheDrag() throws {
        var camera = BoardSceneOrbitCamera(matrix: BoardSceneCameraMath.lookAt(position: SIMD3(0, 0, 100), target: .zero, up: SIMD3(0, 1, 0)))
        camera.pan(dx: 10, dy: 10)
        XCTAssertLessThan(camera.position.x, 0, "drag right, camera left, board right")
        XCTAssertGreaterThan(camera.position.y, 0, "drag down, camera up, board down")
        assertEqual(camera.target - camera.position, SIMD3(0, 0, -100), accuracy: 1e-3, "the target moved with it")
    }

    func testZoomingStopsShortOfTheTargetAndScalesOrthographicCameras() {
        var camera = BoardSceneOrbitCamera(matrix: BoardSceneCameraMath.lookAt(position: SIMD3(0, 0, 100), target: .zero, up: SIMD3(0, 1, 0)))
        camera.zoom(magnification: 0.5)
        XCTAssertEqual(camera.distance, 55, accuracy: 1e-3)
        for _ in 0..<40 {
            camera.zoom(magnification: 0.9)
        }
        XCTAssertGreaterThanOrEqual(camera.distance, BoardSceneOrbitCamera.minimumDistance)
        var orthographic = BoardSceneOrbitCamera(matrix: camera.matrix, orthographicScale: 100)
        orthographic.zoom(magnification: log(2))
        XCTAssertEqual(orthographic.orthographicScale ?? 0, 50, accuracy: 1e-6)
    }

    func testAClickCastsItsRayThroughThePointItIsAt() {
        let matrix = BoardSceneCameraMath.lookAt(position: SIMD3(0, 100, 0), target: .zero, up: SIMD3(0, 0, -1))
        let center = BoardSceneCameraMath.ray(through: .zero, camera: matrix, aspect: 1.5, orthographicScale: nil)
        assertEqual(center.direction, SIMD3(0, -1, 0))
        // The top edge of the view, perspective: up by half the field of view.
        let top = BoardSceneCameraMath.ray(through: SIMD2(0, 1), camera: matrix, aspect: 1.5, orthographicScale: nil)
        let angle = acos(simd_dot(top.direction, center.direction)) * 180 / .pi
        XCTAssertEqual(angle, BoardSceneCameraMath.fieldOfView / 2, accuracy: 1e-3)
        XCTAssertLessThan(top.direction.z, 0, "the view's top is the board's +y, scene -z")
        // Orthographic: parallel rays, the top edge half the scale away.
        let orthographic = BoardSceneCameraMath.ray(through: SIMD2(1, 1), camera: matrix, aspect: 1.5, orthographicScale: 20)
        assertEqual(orthographic.direction, SIMD3(0, -1, 0))
        assertEqual(orthographic.origin, SIMD3(30, 100, -20))
    }

    func testARayMeetsABoxWhereItEntersIt() {
        let hit = BoardSceneEntities.intersection(origin: SIMD3(0, 10, 0), direction: SIMD3(0, -1, 0), boxMin: SIMD3(-1, 0, -1), boxMax: SIMD3(1, 2, 1))
        XCTAssertEqual(hit ?? -1, 8, accuracy: 1e-6)
        XCTAssertNil(BoardSceneEntities.intersection(origin: SIMD3(5, 10, 0), direction: SIMD3(0, -1, 0), boxMin: SIMD3(-1, 0, -1), boxMax: SIMD3(1, 2, 1)))
        XCTAssertNil(BoardSceneEntities.intersection(origin: SIMD3(0, -10, 0), direction: SIMD3(0, -1, 0), boxMin: SIMD3(-1, 0, -1), boxMax: SIMD3(1, 2, 1)), "behind")
        XCTAssertEqual(BoardSceneEntities.intersection(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0), boxMin: SIMD3(-1, 0, -1), boxMax: SIMD3(1, 2, 1)) ?? -1, 0, "from inside")
    }
}
