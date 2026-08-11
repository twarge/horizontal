import XCTest
@testable import HorizontalNative

/// A pad's label frame must travel with the pad.
///
/// The frame is captured at parse time in BOARD-WORLD coordinates — it records
/// where the label sits, not an offset from the pad — so any transform that
/// moves the pad has to move the frame too. It did not, so moving a component
/// left its pad labels behind at the old location while the copper moved.
///
/// The frame is what positions the label; nothing re-derives it from the moved
/// polygon, so a stale centre is simply wrong on screen rather than degraded.
final class PadLabelFrameTransformTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func pad(labelCenter: HorizontalPoint, angle: Int = 0) -> HorizontalPolygon {
        var polygon = HorizontalPolygon(
            id: "pkg/pad/1",
            vertices: [p(-1000, -1000), p(1000, -1000), p(1000, 1000), p(-1000, 1000)],
            layer: 0,
            netID: "n1"
        )
        polygon.padLabelFrame = PadLabelFrameDescriptor(
            center: labelCenter, halfWidth: 500, halfHeight: 250, angle: angle)
        return polygon
    }

    func testShiftingAPadMovesItsLabelFrame() {
        let moved = HorizontalCanvasModeSupport.shifted(
            pad(labelCenter: p(0, 0)), by: p(3_000, -2_000))

        let frame = try? XCTUnwrap(moved.padLabelFrame)
        XCTAssertEqual(frame?.center.x, 3_000)
        XCTAssertEqual(frame?.center.y, -2_000)
    }

    /// The half-extents are intrinsic to the pad, so a translation must not
    /// touch them — only where the frame sits.
    func testShiftingLeavesTheFramesOwnDimensionsAlone() throws {
        let original = pad(labelCenter: p(0, 0), angle: 16_384)
        let moved = HorizontalCanvasModeSupport.shifted(original, by: p(1_000, 1_000))
        let frame = try XCTUnwrap(moved.padLabelFrame)

        XCTAssertEqual(frame.halfWidth, 500)
        XCTAssertEqual(frame.halfHeight, 250)
        XCTAssertEqual(frame.angle, 16_384, "a translation does not turn the label")
    }

    /// Rotation orbits the centre AND turns the label; positioning it correctly
    /// while leaving it facing the old way would be its own bug.
    func testRotatingAPadOrbitsAndTurnsItsLabelFrame() throws {
        let quarterTurn = 16_384
        let rotated = HorizontalCanvasModeSupport.rotated(
            pad(labelCenter: p(1_000, 0)), around: p(0, 0), by: quarterTurn)
        let frame = try XCTUnwrap(rotated.padLabelFrame)

        XCTAssertEqual(frame.center.x, 0, accuracy: 1)
        XCTAssertEqual(frame.center.y, 1_000, accuracy: 1)
        XCTAssertEqual(frame.angle, quarterTurn)
    }

    /// A pad with no intrinsic frame falls back to the polygon-edge derivation,
    /// and must not acquire one from a transform.
    func testAPadWithoutAFrameStaysWithoutOne() {
        var plain = pad(labelCenter: p(0, 0))
        plain.padLabelFrame = nil

        XCTAssertNil(HorizontalCanvasModeSupport.shifted(plain, by: p(10, 10)).padLabelFrame)
    }
}
