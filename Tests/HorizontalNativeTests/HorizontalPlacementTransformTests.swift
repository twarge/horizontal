import XCTest
@testable import HorizontalNative

/// Verifies the package/pad placement transform (mirror → rotate → translate,
/// with exact cardinal-angle branches). This math underpins pad geometry,
/// package placement, and the STEP model placement, so a regression here is
/// widely visible.
final class HorizontalPlacementTransformTests: XCTestCase {
    private func tf(shift: HorizontalPoint = .zero, angle: Int = 0, mirrored: Bool = false) -> HorizontalPlacementTransform {
        HorizontalPlacementTransform(shift: shift, angle: angle, mirrored: mirrored)
    }

    private func assertClose(_ a: HorizontalPoint, _ x: Double, _ y: Double, _ message: String = "", accuracy: Double = 1e-6) {
        XCTAssertEqual(a.x, x, accuracy: accuracy, message)
        XCTAssertEqual(a.y, y, accuracy: accuracy, message)
    }

    func testIdentity() {
        assertClose(tf().applying(to: HorizontalPoint(x: 3, y: 5)), 3, 5)
    }

    func testCardinalRotations() {
        let p = HorizontalPoint(x: 1000, y: 0)
        assertClose(tf(angle: 16_384).applying(to: p), 0, 1000, "90° CCW")
        assertClose(tf(angle: 32_768).applying(to: p), -1000, 0, "180°")
        assertClose(tf(angle: 49_152).applying(to: p), 0, -1000, "270°")
    }

    func testArbitraryAngleMatchesTrig() {
        let angle = 8_192 // 45°
        let p = HorizontalPoint(x: 1000, y: 0)
        let r = Double(angle) / 65_536.0 * Double.pi * 2
        assertClose(tf(angle: angle).applying(to: p), 1000 * cos(r), 1000 * sin(r), "45°", accuracy: 1e-3)
    }

    func testMirrorAppliedBeforeRotation() {
        // Mirror-only flips x.
        assertClose(tf(mirrored: true).applying(to: HorizontalPoint(x: 1, y: 2)), -1, 2)
        // Mirror + 90°: mirror (1,0)->(-1,0), then rotate 90° -> (0,-1).
        assertClose(tf(angle: 16_384, mirrored: true).applying(to: HorizontalPoint(x: 1, y: 0)), 0, -1)
    }

    func testShiftAppliedLast() {
        let t = tf(shift: HorizontalPoint(x: 100, y: 200), angle: 16_384)
        // (10,0) rotates to (0,10), then + shift.
        assertClose(t.applying(to: HorizontalPoint(x: 10, y: 0)), 100, 210)
    }

    func testNegativeAngleWraps() {
        // -16384 wraps to 49152 (270°).
        let p = HorizontalPoint(x: 1000, y: 0)
        assertClose(tf(angle: -16_384).applying(to: p), 0, -1000)
    }

    func testComposesConsistentlyForRoundTrip() {
        // Rotating by +90 then by -90 (=270 wrap applied separately) returns origin-relative point.
        let p = HorizontalPoint(x: 137, y: -42)
        let once = tf(angle: 16_384).applying(to: p)
        let back = tf(angle: 49_152).applying(to: once)
        assertClose(back, p.x, p.y, "90° then 270° is identity", accuracy: 1e-6)
    }

    // MARK: - Composition handedness

    /// A mirrored parent flips handedness, so a child's rotation must enter the
    /// parent's frame reversed. Adding the angles instead would rotate nested
    /// content the wrong way on every bottom-side package — the kind of error
    /// that looks correct at 0° and only shows up once something is rotated.
    func testMirroredParentReversesChildRotation() {
        let child = HorizontalPlacementTransform(shift: .zero, angle: 16_384, mirrored: false)

        // Angles are compared modulo a full turn: the composed value may be
        // wrapped into [0, 65536), so -8192 legitimately reads as 57344.
        func turns(_ value: Int) -> Int { ((value % 65_536) + 65_536) % 65_536 }

        let upright = HorizontalPlacementTransform(shift: .zero, angle: 8_192, mirrored: false)
        XCTAssertEqual(turns(upright.accumulated(with: child).angle), turns(8_192 + 16_384))

        let mirrored = HorizontalPlacementTransform(shift: .zero, angle: 8_192, mirrored: true)
        XCTAssertEqual(turns(mirrored.accumulated(with: child).angle), turns(8_192 - 16_384))
    }

    /// Mirroring is a toggle through composition, not a sticky flag.
    func testMirrorTogglesThroughComposition() {
        let mirroredChild = HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: true)
        let uprightParent = HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false)
        let mirroredParent = HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: true)

        XCTAssertTrue(uprightParent.accumulated(with: mirroredChild).mirrored)
        XCTAssertFalse(mirroredParent.accumulated(with: mirroredChild).mirrored)
    }

    // MARK: - Horizon text placement convention

    func testMirroredQuarterTurnPlacesOrientationSpecificTextOnHorizonSide() {
        let symbol = tf(
            shift: HorizontalPoint(x: 238.75, y: 88.75),
            angle: 16_384,
            mirrored: true
        )

        // Reduced from Clove's C86 `90m` placements. The old symbol-file
        // correction has already inverted the mirrored value angle here, just
        // as the schematic loader does before composing the placement.
        let value = tf(
            shift: HorizontalPoint(x: -3.75, y: -3.75),
            angle: 16_384,
            mirrored: true
        )
        let refdes = tf(
            shift: HorizontalPoint(x: 3.75, y: -3.75),
            angle: 16_384,
            mirrored: false
        )

        let placedValue = symbol.accumulatedText(with: value)
        assertClose(placedValue.shift, 235, 85)
        XCTAssertEqual(placedValue.angle, 0)
        XCTAssertFalse(placedValue.mirrored)

        let placedRefdes = symbol.accumulatedText(with: refdes)
        assertClose(placedRefdes.shift, 235, 92.5)
        XCTAssertEqual(placedRefdes.angle, 0)
        XCTAssertTrue(placedRefdes.mirrored)
    }

    func testTextAnchorRotatesBeforeParentMirrorAtEveryCardinalAngle() {
        let point = HorizontalPoint(x: 2, y: 3)
        let expected: [(Int, HorizontalPoint)] = [
            (0, HorizontalPoint(x: -2, y: 3)),
            (16_384, HorizontalPoint(x: 3, y: 2)),
            (32_768, HorizontalPoint(x: 2, y: -3)),
            (49_152, HorizontalPoint(x: -3, y: -2)),
        ]

        for (angle, anchor) in expected {
            let placed = tf(angle: angle, mirrored: true).accumulatedText(
                with: tf(shift: point)
            )
            assertClose(placed.shift, anchor.x, anchor.y, "angle \(angle)")
        }
    }
}
