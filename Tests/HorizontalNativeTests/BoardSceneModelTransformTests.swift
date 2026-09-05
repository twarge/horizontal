#if os(macOS)
import SceneKit
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

    /// SceneKit transforms row vectors: `v * M`.
    private func apply(_ m: SCNMatrix4, _ v: SCNVector3) -> SCNVector3 {
        SCNVector3(
            v.x * m.m11 + v.y * m.m21 + v.z * m.m31 + m.m41,
            v.x * m.m12 + v.y * m.m22 + v.z * m.m32 + m.m42,
            v.x * m.m13 + v.y * m.m23 + v.z * m.m33 + m.m43
        )
    }

    /// Horizon's z-up point in SceneKit's y-up frame, the way the scene
    /// places everything: x stays, z becomes y, y becomes -z.
    private func scene(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
        SCNVector3(x, z, -y)
    }

    private func assertEqual(_ actual: SCNVector3, _ expected: SCNVector3, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(actual.x), Double(expected.x), accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(Double(actual.y), Double(expected.y), accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(Double(actual.z), Double(expected.z), accuracy: 1e-5, message, file: file, line: line)
    }

    func testSceneKitConventionsAssumedByTheHelper() {
        let quarter = SCNMatrix4MakeRotation(.pi / 2, 0, 0, 1)
        assertEqual(apply(quarter, SCNVector3(1, 0, 0)), SCNVector3(0, 1, 0), "positive angles turn counter-clockwise")
        let moved = SCNMatrix4Mult(quarter, SCNMatrix4MakeTranslation(5, 0, 0))
        assertEqual(apply(moved, SCNVector3(1, 0, 0)), SCNVector3(5, 1, 0), "Mult(a, b) applies a first")
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
#endif
