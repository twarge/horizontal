import XCTest
@testable import HorizontalNative

/// Guards `BoardCanvasView.flipBoardPackage`, the in-place package flip behind the
/// sidebar "Flipped" toggle.
///
/// Horizon's `flip` (board_package.cpp `update_package`) keeps the placement's
/// shift and angle, sets `placement.mirror = flip`, and flips every geometry layer
/// top↔bottom. It is NOT the mirror tool (which inverts the angle). Horizontal
/// bakes the placement into cached geometry at load, so flipping in place must
/// transform the already-baked geometry from the un-mirrored to the mirrored state
/// while leaving the stored shift+angle untouched.
///
/// `applying(to:)` builds geometry as `Rot(angle) · M · p + shift` (mirror before
/// rotation). Conjugating the local-x reflection `M` by `Rot(angle)`, and noting
/// that `HorizontalCanvasModeSupport.mirrored` reflects across the *vertical* line
/// through the center, the in-place flip is exactly: vertical-mirror about the
/// package origin, then rotate by `2·angle` about that origin. This test asserts
/// that composition reproduces a fresh load of the mirrored placement at every
/// angle — orthogonal and arbitrary — which a naive mirror-tool (`-angle`) flip
/// does not.
final class PackageFlipGeometryTests: XCTestCase {
    /// Applies the exact point transform `flipBoardPackage` uses (the same statics
    /// its `mirrored`/`rotated` helpers delegate to).
    private func inPlaceFlip(_ point: HorizontalPoint, center: HorizontalPoint, angle: Int) -> HorizontalPoint {
        HorizontalCanvasModeSupport.rotated(
            HorizontalCanvasModeSupport.mirrored(point, around: center),
            around: center,
            by: 2 * angle
        )
    }

    func testInPlaceFlipMatchesFreshlyLoadedMirroredPlacement() {
        let centers = [
            HorizontalPoint(x: 0, y: 0),
            HorizontalPoint(x: 3_000_000, y: -1_500_000),
        ]
        // Pool-local points (pad/silk offsets relative to the package origin).
        let locals = [
            HorizontalPoint(x: 1_000_000, y: 0),
            HorizontalPoint(x: 0, y: 700_000),
            HorizontalPoint(x: 450_000, y: -250_000),
            HorizontalPoint(x: -380_000, y: 920_000),
        ]
        // Orthogonal turns plus deliberately non-orthogonal angles (45°, and two
        // arbitrary ones) where a `-angle` mirror-tool flip diverges.
        let angles = [0, 8_192, 16_384, 24_576, 32_768, 40_960, 49_152, 57_344, 12_345, 51_111]

        for center in centers {
            for angle in angles {
                let unflipped = HorizontalPlacementTransform(shift: center, angle: angle, mirrored: false)
                let flipped = HorizontalPlacementTransform(shift: center, angle: angle, mirrored: true)
                for local in locals {
                    let baked = unflipped.applying(to: local)        // current cached geometry
                    let expected = flipped.applying(to: local)       // a fresh load with flip on
                    let actual = inPlaceFlip(baked, center: center, angle: angle)
                    XCTAssertEqual(
                        actual.x, expected.x, accuracy: 5.0,
                        "x mismatch angle=\(angle) local=\(local) center=\(center)"
                    )
                    XCTAssertEqual(
                        actual.y, expected.y, accuracy: 5.0,
                        "y mismatch angle=\(angle) local=\(local) center=\(center)"
                    )
                }
            }
        }
    }

    /// Flipping twice is the identity (an involution) — geometry returns home.
    func testInPlaceFlipIsItsOwnInverse() {
        let center = HorizontalPoint(x: 2_000_000, y: 500_000)
        let angle = 12_345
        let local = HorizontalPoint(x: 600_000, y: -400_000)
        let baked = HorizontalPlacementTransform(shift: center, angle: angle, mirrored: false).applying(to: local)
        let once = inPlaceFlip(baked, center: center, angle: angle)
        // angle is preserved across a flip, so the second flip uses the same angle.
        let twice = inPlaceFlip(once, center: center, angle: angle)
        XCTAssertEqual(twice.x, baked.x, accuracy: 5.0)
        XCTAssertEqual(twice.y, baked.y, accuracy: 5.0)
    }

    /// Sanity: the mirror-tool flip (`-angle`, the two readers' recommendation)
    /// genuinely diverges from Horizon's flip at non-zero angles — documenting why
    /// `flipBoardPackage` keeps the angle instead of negating it.
    func testMirrorToolFlipDivergesAtRightAngle() {
        let center = HorizontalPoint(x: 0, y: 0)
        let local = HorizontalPoint(x: 1_000_000, y: 0)
        let angle = 16_384 // 90°
        let horizonFlip = HorizontalPlacementTransform(shift: center, angle: angle, mirrored: true).applying(to: local)
        // mirror tool: negate angle, mirror geometry about the origin, mirror=true.
        let mirrorToolGeometry = HorizontalPlacementTransform(shift: center, angle: -angle, mirrored: true).applying(to: local)
        XCTAssertNotEqual(horizonFlip.y, mirrorToolGeometry.y, accuracy: 0.0,
                          "expected the mirror-tool flip to land the pad on the wrong side at 90°")
    }
}
