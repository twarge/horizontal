import CoreGraphics
import Foundation
import simd

// The 3D view's camera in plain matrices. The scene is in millimetres with y
// up and the board's centre at the origin; the camera looks down its own -z
// axis, as SceneKit's did and RealityKit's does, so a camera saved by the
// SceneKit view opens where it was.

extension HorizontalSceneCameraState {
    /// The camera's transform, column by column: the layout SceneKit's
    /// SCNMatrix4 kept, so states saved before RealityKit read the same.
    init(matrix: simd_float4x4, orthographicScale: Double? = nil) {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        self.init(transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }, orthographicScale: orthographicScale)
    }

    var matrix: simd_float4x4? {
        guard isValid else {
            return nil
        }
        let t = transform
        return simd_float4x4(columns: (
            SIMD4(t[0], t[1], t[2], t[3]),
            SIMD4(t[4], t[5], t[6], t[7]),
            SIMD4(t[8], t[9], t[10], t[11]),
            SIMD4(t[12], t[13], t[14], t[15])
        ))
    }
}

enum BoardSceneCameraMath {
    /// The vertical field of view, in degrees.
    static let fieldOfView: Float = 38

    /// A camera at `position` looking at `target`, `up` as near its up as it
    /// can be: SceneKit's `look(at:up:localFront:)` with the front at -z.
    static func lookAt(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        var back = position - target
        if simd_length(back) < 1e-6 {
            back = SIMD3(0, 0, 1)
        }
        back = simd_normalize(back)
        var right = simd_cross(up, back)
        if simd_length(right) < 1e-6 {
            // Looking along the up vector: any right will do.
            right = simd_cross(SIMD3(0, 0, 1), back)
            if simd_length(right) < 1e-6 {
                right = SIMD3(1, 0, 0)
            }
        }
        right = simd_normalize(right)
        let trueUp = simd_cross(back, right)
        return simd_float4x4(columns: (
            SIMD4(right, 0),
            SIMD4(trueUp, 0),
            SIMD4(back, 0),
            SIMD4(position, 1)
        ))
    }

    static func position(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    static func right(of matrix: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
    }

    static func up(of matrix: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z))
    }

    /// The way the camera looks.
    static func forward(of matrix: simd_float4x4) -> SIMD3<Float> {
        -simd_normalize(SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
    }

    /// What a camera saved without its target turns about: where it looks
    /// at the board's mid-plane, or, looking along it, the point of its view
    /// nearest the board's centre.
    static func orbitTarget(for matrix: simd_float4x4) -> SIMD3<Float> {
        let position = position(of: matrix)
        let forward = forward(of: matrix)
        if abs(forward.y) > 0.1 {
            let distance = -position.y / forward.y
            if distance > 0.01, distance < 100_000 {
                return position + forward * distance
            }
        }
        let along = max(simd_dot(-position, forward), 1)
        return position + forward * along
    }

    /// The camera's ray through a point of the view, the point given from -1
    /// to 1 on both axes, y up. `orthographicScale` is half the view's height,
    /// as SceneKit had it; nil is a perspective camera.
    static func ray(
        through point: SIMD2<Float>,
        camera matrix: simd_float4x4,
        aspect: Float,
        orthographicScale: Double?
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let position = position(of: matrix)
        let right = right(of: matrix)
        let up = up(of: matrix)
        let forward = forward(of: matrix)
        if let orthographicScale {
            let halfHeight = Float(orthographicScale)
            let origin = position + right * (point.x * halfHeight * aspect) + up * (point.y * halfHeight)
            return (origin, forward)
        }
        let tangent = tan(fieldOfView * .pi / 360)
        let direction = forward + right * (point.x * tangent * aspect) + up * (point.y * tangent)
        return (position, simd_normalize(direction))
    }

    /// The near and far planes for a camera this far from what it looks at:
    /// close enough to keep the depth buffer's precision on the board, where
    /// the layers lie ten microns apart, and far enough to see all of it.
    static func clippingPlanes(distance: Float, sceneSize: Float) -> (near: Float, far: Float) {
        let near = max(min(distance * 0.02, 5), 0.01)
        let far = distance + max(sceneSize, 10) * 4 + 100
        return (near, far)
    }
}

/// The camera the 3D view's gestures move: it orbits a point it looks at,
/// pans across the view and moves toward or away from that point, which is
/// what SceneKit's camera control did with the view's mouse and touches.
struct BoardSceneOrbitCamera: Equatable {
    var matrix: simd_float4x4
    var target: SIMD3<Float>
    /// Half the view's height in millimetres when the camera is orthographic.
    var orthographicScale: Double?

    /// Radians turned per point dragged.
    static let orbitRate: Float = .pi / 360
    static let minimumDistance: Float = 1
    static let maximumDistance: Float = 5_000

    init(matrix: simd_float4x4, target: SIMD3<Float>? = nil, orthographicScale: Double? = nil) {
        self.matrix = matrix
        self.target = target ?? BoardSceneCameraMath.orbitTarget(for: matrix)
        self.orthographicScale = orthographicScale
    }

    init(state: HorizontalSceneCameraState) {
        self.init(matrix: state.matrix ?? matrix_identity_float4x4, orthographicScale: state.orthographicScale)
    }

    var state: HorizontalSceneCameraState {
        HorizontalSceneCameraState(matrix: matrix, orthographicScale: orthographicScale)
    }

    var position: SIMD3<Float> {
        BoardSceneCameraMath.position(of: matrix)
    }

    var distance: Float {
        simd_length(position - target)
    }

    /// Turns the camera about its target: across about the scene's up,
    /// up and down about its own right. `dx` and `dy` are points dragged,
    /// y down, and the board follows the drag.
    mutating func orbit(dx: Float, dy: Float) {
        let yaw = simd_quatf(angle: -dx * Self.orbitRate, axis: SIMD3(0, 1, 0))
        let right = BoardSceneCameraMath.right(of: matrix)
        let pitch = simd_quatf(angle: -dy * Self.orbitRate, axis: right)
        let rotation = yaw * pitch
        let offset = rotation.act(position - target)
        var rotated = simd_float4x4(rotation) * matrix
        rotated.columns.3 = SIMD4(target + offset, 1)
        matrix = rotated
    }

    /// Slides the camera and its target across the view, the board moving
    /// with the drag: `dx` and `dy` in points, y down.
    mutating func pan(dx: Float, dy: Float) {
        let reach = orthographicScale.map { max(Float($0), 1) } ?? max(distance, 1)
        let scale = reach * 0.0015
        let right = BoardSceneCameraMath.right(of: matrix)
        let up = BoardSceneCameraMath.up(of: matrix)
        let move = right * (-dx * scale) + up * (dy * scale)
        matrix.columns.3 += SIMD4(move, 0)
        target += move
    }

    /// Moves toward the target (or, orthographic, magnifies) by
    /// `magnification`: positive closer, as a pinch outward.
    mutating func zoom(magnification: Float) {
        guard magnification != 0, magnification.isFinite else {
            return
        }
        if let scale = orthographicScale {
            orthographicScale = min(max(scale * exp(-Double(magnification)), 1), 5_000)
            return
        }
        let offset = position - target
        let length = max(simd_length(offset), 0.0001)
        let newLength = length - length * magnification * 0.9
        guard newLength >= Self.minimumDistance, newLength <= Self.maximumDistance else {
            return
        }
        matrix.columns.3 = SIMD4(target + offset / length * newLength, 1)
    }
}

/// The camera a preset puts the view at.
func horizonSceneCameraState(
    for preset: HorizontalBoard3DViewPreset,
    board: HorizontalBoard
) -> HorizontalSceneCameraState {
    let dimensions = horizonSceneBoardDimensions(for: board)
    let maxDimension = max(dimensions.width, dimensions.depth)
    let distance = Float(max(maxDimension * 2.4, 18))
    let position: SIMD3<Float>
    let up: SIMD3<Float>

    switch preset {
    case .defaultPerspective:
        let axisDistance = distance / 3.0.squareRoot().float
        position = SIMD3(-axisDistance, axisDistance, axisDistance)
        up = SIMD3(0, 1, 0)
    case .top:
        position = SIMD3(0, distance, 0)
        up = SIMD3(0, 0, -1)
    case .bottom:
        position = SIMD3(0, -distance, 0)
        up = SIMD3(0, 0, 1)
    case .side:
        position = SIMD3(-distance, 0, 0)
        up = SIMD3(0, 1, 0)
    case .frontLeft:
        position = SIMD3(0, 0, distance)
        up = SIMD3(0, 1, 0)
    case .backRight:
        position = SIMD3(distance, 0, 0)
        up = SIMD3(0, 1, 0)
    }

    let matrix = BoardSceneCameraMath.lookAt(position: position, target: .zero, up: up)
    let orthographicScale = preset.projection == .orthogonal
        ? horizonSceneDefaultOrthographicScale(for: board)
        : nil
    return HorizontalSceneCameraState(matrix: matrix, orthographicScale: orthographicScale)
}

func horizonSceneDefaultOrthographicScale(for board: HorizontalBoard) -> Double {
    let dimensions = horizonSceneBoardDimensions(for: board)
    return max(dimensions.width, dimensions.depth) * 1.6
}

func horizonSceneBoardDimensions(for board: HorizontalBoard) -> (width: Double, depth: Double) {
    let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
    let width = max(bodyBounds.width / 1_000_000.0, 10)
    let depth = max(bodyBounds.height / 1_000_000.0, 10)
    return (width, depth)
}

/// The camera moved toward or away from what it looks at by `factor` — 2 is
/// twice as close — about the board's centre, since the camera does not
/// record what it was looking at. Orthographic cameras scale instead.
func horizonSceneCameraState(zooming current: HorizontalSceneCameraState?, by factor: Double, board: HorizontalBoard,
                             projection: HorizontalBoardSceneProjection) -> HorizontalSceneCameraState {
    let start = current.flatMap { $0.isValid ? $0 : nil } ?? horizonSceneCameraState(for: .defaultPerspective, board: board)
    guard factor > 0, var matrix = start.matrix else {
        return start
    }
    let moved = BoardSceneCameraMath.position(of: matrix) / Float(factor)
    matrix.columns.3 = SIMD4(moved, 1)
    let orthographicScale = start.orthographicScale.map { $0 / factor }
    return HorizontalSceneCameraState(
        matrix: matrix,
        orthographicScale: projection == .orthogonal ? (orthographicScale ?? horizonSceneDefaultOrthographicScale(for: board) / factor) : nil
    )
}

/// A camera looking at `rect` — a rectangle on the board, in board units —
/// from the direction the camera looks now, or from the default perspective
/// when there is no camera yet, from far enough that the rectangle fills a
/// good part of the view. What "zoom to C50" means in the 3D pane.
func horizonSceneCameraState(
    framing rect: HorizontalRect,
    board: HorizontalBoard,
    current: HorizontalSceneCameraState?,
    projection: HorizontalBoardSceneProjection
) -> HorizontalSceneCameraState {
    let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
    let target = BoardSceneFactory.scenePoint(rect.center, center: bodyBounds.center, y: BoardSceneFactory.boardTopHeight)
    let sizeMM = max(rect.width, rect.height) / BoardSceneFactory.unitsPerMillimeter
    let distance = Float(max(sizeMM * 2.2, 6))
    // The camera's own +z axis points back at it from what it looks at, so
    // keeping that axis keeps the view's direction and only moves the camera.
    var direction = simd_normalize(SIMD3<Float>(-1, 1, 1))
    var up = SIMD3<Float>(0, 1, 0)
    if let current, let matrix = current.matrix {
        let backward = SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let length = simd_length(backward)
        if length > 0.0001 {
            direction = backward / length
            up = SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        }
    }
    let position = target + direction * distance
    let matrix = BoardSceneCameraMath.lookAt(position: position, target: target, up: up)
    let orthographicScale: Double? = projection == .orthogonal ? max(sizeMM * 0.8, 2) : nil
    return HorizontalSceneCameraState(matrix: matrix, orthographicScale: orthographicScale)
}

/// The camera slid along the board, not turned or zoomed, so that `rect` — a
/// rectangle on the board, in board units — is in view, or nil when all of it
/// is already, or when there is no camera yet to keep. Spotlight moves the 3D
/// pane this way when L wasn't pressed there: the camera looks at the
/// rectangle's middle, as far along its line of sight as it looked at the
/// board before, so the view keeps its angle and its zoom. The view is taken
/// as no wider than it is tall, which only ever moves it when it needn't.
func horizonSceneCameraState(
    revealing rect: HorizontalRect,
    board: HorizontalBoard,
    current: HorizontalSceneCameraState?
) -> HorizontalSceneCameraState? {
    guard let current, let matrix = current.matrix else {
        return nil
    }
    let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
    func scenePoint(_ point: HorizontalPoint) -> SIMD3<Float> {
        BoardSceneFactory.scenePoint(point, center: bodyBounds.center, y: BoardSceneFactory.boardTopHeight)
    }
    let position = BoardSceneCameraMath.position(of: matrix)
    let forward = simd_normalize(BoardSceneCameraMath.forward(of: matrix))
    let right = simd_normalize(BoardSceneCameraMath.right(of: matrix))
    let up = simd_normalize(BoardSceneCameraMath.up(of: matrix))
    let tangent = tan(BoardSceneCameraMath.fieldOfView * .pi / 360)
    let corners = [
        HorizontalPoint(x: rect.minX, y: rect.minY), HorizontalPoint(x: rect.maxX, y: rect.minY),
        HorizontalPoint(x: rect.minX, y: rect.maxY), HorizontalPoint(x: rect.maxX, y: rect.maxY),
    ].map(scenePoint)
    let inView = corners.allSatisfy { corner in
        let offset = corner - position
        let depth = simd_dot(offset, forward)
        guard depth > 0 else {
            return false
        }
        let half = current.orthographicScale.map { Float($0) } ?? depth * tangent
        return abs(simd_dot(offset, right)) <= half && abs(simd_dot(offset, up)) <= half
    }
    guard !inView else {
        return nil
    }
    let target = scenePoint(rect.center)
    // How far the camera looked: to where its line of sight meets the board,
    // or to the target when it looks along the board or away from it.
    var distance = simd_length(position - target)
    if abs(forward.y) > 1e-4 {
        let along = (target.y - position.y) / forward.y
        if along > 0 {
            distance = along
        }
    }
    var moved = matrix
    moved.columns.3 = SIMD4(target - forward * distance, 1)
    return HorizontalSceneCameraState(matrix: moved, orthographicScale: current.orthographicScale)
}

private extension Double {
    var float: Float { Float(self) }
}
