import Foundation
import XCTest
#if canImport(HorizontalStepImporter)
import HorizontalStepImporter
#endif

/// Pins the component-model placement transform.
///
/// `modelLocation` was rewritten from a written specification of the placement
/// (REMEDIATION A3). These golden matrices were captured from the implementation
/// it replaced, so the rewrite is held to the geometry that shipped before it —
/// not merely to itself.
final class StepModelPlacementTests: XCTestCase {
    func testPlacementMatchesGoldenTransforms() throws {
        #if canImport(HorizontalStepImporter)
        var checked = 0
        for line in StepModelPlacementGoldenData.rows.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 18,
                  let bottomFlag = Int(f[0]),
                  let rotation = Double(f[1]), let roll = Double(f[2]),
                  let pitch = Double(f[3]), let yaw = Double(f[4]),
                  let thickness = Double(f[5]) else {
                continue
            }
            let expected = f[6...].compactMap(Double.init)
            guard expected.count == 12 else { continue }

            var actual = [Double](repeating: 0, count: 12)
            HNStepModelPlacement(
                bottomFlag == 1, 12.5, -7.25, rotation,
                0.3, -0.6, 1.25,
                roll, pitch, yaw, thickness,
                &actual
            )

            for index in 0..<12 {
                XCTAssertEqual(
                    actual[index], expected[index], accuracy: 1e-6,
                    "matrix[\(index)] for bottom=\(bottomFlag) rot=\(rotation) "
                    + "roll=\(roll) pitch=\(pitch) yaw=\(yaw) t=\(thickness)"
                )
            }
            checked += 1
        }
        XCTAssertEqual(checked, 224, "every placement combination is covered")
        #else
        throw XCTSkip("HorizontalStepImporter unavailable")
        #endif
    }

    /// The side-dependent lift is the part most likely to be broken by a
    /// well-meaning refactor, so state it independently of the table.
    ///
    /// A top part stands on the far face of the substrate, so it lifts by the
    /// board thickness plus the surface clearance. A bottom part is turned over,
    /// and that half turn about X negates the offset — so its clearance carries
    /// it BELOW z = 0, onto the underside, rather than above it.
    func testTopStandsOnTheSubstrateAndBottomHangsBeneathIt() throws {
        #if canImport(HorizontalStepImporter)
        var top = [Double](repeating: 0, count: 12)
        var bottom = [Double](repeating: 0, count: 12)
        HNStepModelPlacement(false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.6, &top)
        HNStepModelPlacement(true, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.6, &bottom)

        // Row-major 3x4: translation z is index 11.
        XCTAssertEqual(top[11], 1.6 + 0.05, accuracy: 1e-9, "top lifts by thickness + clearance")
        XCTAssertEqual(bottom[11], -0.05, accuracy: 1e-9, "bottom sits clearance BELOW z = 0")
        #else
        throw XCTSkip("HorizontalStepImporter unavailable")
        #endif
    }
}
