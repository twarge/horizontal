import simd
import XCTest
@testable import HorizontalNative

/// Package 3D models follow Horizon's face vertex shader: yaw, then pitch,
/// then roll, then the unrotated package-local offset.
final class BoardSceneModelTransformTests: XCTestCase {
    private func model(roll: Int = 0, pitch: Int = 0, yaw: Int = 0, x: Double = 0, y: Double = 0, z: Double = 0) -> HorizontalPackage3DModel {
        HorizontalPackage3DModel(
            id: "m", filename: "m.step", fileURL: URL(fileURLWithPath: "/m.step"),
            x: x, y: y, z: z, roll: roll, pitch: pitch, yaw: yaw, heightTop: 0, heightBottom: 0
        )
    }

    /// simd transforms column vectors: `M * v`.
    private func apply(_ m: simd_float4x4, _ v: SIMD3<Float>) -> SIMD3<Float> {
        m.transformPoint(v)
    }

    /// Horizon's z-up point in the scene's y-up frame, the way the scene
    /// places everything: x stays, z becomes y, y becomes -z.
    private func scene(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        SIMD3(x, z, -y)
    }

    private func assertEqual(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-5, message, file: file, line: line)
    }

    func testConventionsAssumedByTheHelper() {
        let quarter = simd_float4x4(rotationAbout: SIMD3(0, 0, 1), angle: .pi / 2)
        assertEqual(apply(quarter, SIMD3(1, 0, 0)), SIMD3(0, 1, 0), "positive angles turn counter-clockwise")
        let moved = simd_float4x4(translation: SIMD3(5, 0, 0)) * quarter
        assertEqual(apply(moved, SIMD3(1, 0, 0)), SIMD3(5, 1, 0), "a * b applies b first")
    }

    /// The Phoenix MC 1,5 header: pitch 90° and yaw 90°. Upstream turns the
    /// mesh by the yaw first, so Horizon's +x ends up along -y and its +z
    /// along -x.
    func testPitchAndYawComposeYawFirst() {
        let transform = BoardSceneFactory.modelLocalTransform(for: model(pitch: 16384, yaw: 16384))
        assertEqual(apply(transform, scene(1, 0, 0)), scene(0, -1, 0), "+x")
        assertEqual(apply(transform, scene(0, 0, 1)), scene(-1, 0, 0), "+z")
        assertEqual(apply(transform, scene(0, 1, 0)), scene(0, 0, 1), "+y")
    }

    func testSingleAxisRotationsMatchTheShader() {
        // Roll 270°: Horizon's rotation by -270° (+90°) about x takes +y to +z.
        let roll = BoardSceneFactory.modelLocalTransform(for: model(roll: 49152))
        assertEqual(apply(roll, scene(0, 1, 0)), scene(0, 0, 1), "roll")
        // Yaw 90°: rotation by -90° about z takes +x to -y.
        let yaw = BoardSceneFactory.modelLocalTransform(for: model(yaw: 16384))
        assertEqual(apply(yaw, scene(1, 0, 0)), scene(0, -1, 0), "yaw")
        // Pitch 90°: rotation by -90° about y takes +z to -x.
        let pitch = BoardSceneFactory.modelLocalTransform(for: model(pitch: 16384))
        assertEqual(apply(pitch, scene(0, 0, 1)), scene(-1, 0, 0), "pitch")
    }

    func testOffsetIsAddedAfterTheRotationWithoutBeingRotated() {
        let transform = BoardSceneFactory.modelLocalTransform(for: model(yaw: 16384, x: 1_000_000, y: 2_000_000, z: 3_000_000))
        assertEqual(apply(transform, scene(0, 0, 0)), scene(1, 2, 3), "origin lands on the offset, in millimetres")
        assertEqual(apply(transform, scene(1, 0, 0)), scene(1, 1, 3), "rotated point plus the unrotated offset")
    }
}
