import XCTest
@testable import HorizontalNative

/// The clip-silkscreen-to-solder-mask mode: silkscreen within the clearance
/// of a mask opening is cut away, everything else is left untouched.
final class HorizontalSilkscreenClipperTests: XCTestCase {
    private let mm = 1_000_000.0

    /// An empty board with one 2 × 2 mm pad mask opening at the origin.
    private func board() -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(
            uuid: "board",
            name: "Silk",
            url: URL(fileURLWithPath: "/tmp/silk")
        )
        board.packagePads.append(HorizontalPolygon(
            id: "pkg/pad/p1/shape/s1/layer/10",
            vertices: [
                HorizontalPoint(x: -mm, y: -mm),
                HorizontalPoint(x: mm, y: -mm),
                HorizontalPoint(x: mm, y: mm),
                HorizontalPoint(x: -mm, y: mm),
            ],
            layer: HorizontalBoardLayers.topMask
        ))
        return board
    }

    private func line(_ id: String, from: HorizontalPoint, to: HorizontalPoint, layer: Int = HorizontalBoardLayers.topSilkscreen) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 0.2 * mm, layer: layer)
    }

    private func covers(_ fragments: [[[HorizontalPoint]]], _ point: HorizontalPoint) -> Bool {
        fragments.contains { fragment in
            guard let outer = fragment.first, contains(outer, point) else {
                return false
            }
            return !fragment.dropFirst().contains { contains($0, point) }
        }
    }

    private func contains(_ polygon: [HorizontalPoint], _ point: HorizontalPoint) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    func testALineAcrossAPadLosesTheOpeningAndItsClearance() throws {
        var board = board()
        board.lines.append(line("across", from: HorizontalPoint(x: -5 * mm, y: 0), to: HorizontalPoint(x: 5 * mm, y: 0)))
        board.lines.append(line("far", from: HorizontalPoint(x: -5 * mm, y: 4 * mm), to: HorizontalPoint(x: 5 * mm, y: 4 * mm)))

        let clipping = HorizontalSilkscreenClipping(clearance: 0.1 * mm)
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: clipping))

        XCTAssertNil(layer.object("far"), "a line nowhere near an opening is left alone")
        let across = try XCTUnwrap(layer.object("across"))
        XCTAssertEqual(across.fragments.count, 2, "the opening splits the line in two")
        XCTAssertTrue(covers(across.fragments, HorizontalPoint(x: -4 * mm, y: 0)))
        XCTAssertTrue(covers(across.fragments, HorizontalPoint(x: 4 * mm, y: 0)))
        XCTAssertFalse(covers(across.fragments, HorizontalPoint(x: 0, y: 0)), "over the pad")
        XCTAssertFalse(covers(across.fragments, HorizontalPoint(x: 1.05 * mm, y: 0)), "inside the clearance")
        XCTAssertTrue(covers(across.fragments, HorizontalPoint(x: 1.2 * mm, y: 0)), "just beyond the clearance")

        // Both silkscreen layers come back; the bottom one has no openings.
        let both = HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        XCTAssertEqual(Set(both.keys), [HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen])
        XCTAssertTrue(both[HorizontalBoardLayers.bottomSilkscreen]?.clipped.isEmpty ?? false)
    }

    func testALineEntirelyOverAPadVanishes() throws {
        var board = board()
        board.lines.append(line("inside", from: HorizontalPoint(x: -0.5 * mm, y: 0), to: HorizontalPoint(x: 0.5 * mm, y: 0)))
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: HorizontalSilkscreenClipping(clearance: 0)))
        let inside = try XCTUnwrap(layer.object("inside"))
        XCTAssertTrue(inside.fragments.isEmpty)
    }

    func testTextAndTheOtherSideAreHandled() throws {
        var board = board()
        board.texts.append(HorizontalText(
            id: "label",
            text: "R1",
            position: HorizontalPoint(x: 0, y: 0),
            size: 1.5 * mm,
            layer: HorizontalBoardLayers.topSilkscreen,
            width: 0.15 * mm
        ))
        board.lines.append(line("bottom", from: HorizontalPoint(x: -5 * mm, y: 0), to: HorizontalPoint(x: 5 * mm, y: 0), layer: HorizontalBoardLayers.bottomSilkscreen))
        let clipping = HorizontalSilkscreenClipping(clearance: 0.1 * mm)
        let top = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: clipping))
        let label = try XCTUnwrap(top.object("label"), "text over the pad is clipped")
        XCTAssertFalse(covers(label.fragments, HorizontalPoint(x: 0, y: 0)))

        // The bottom line only meets bottom mask openings, and there are none.
        let bottom = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.bottomSilkscreen, board: board, clipping: clipping))
        XCTAssertNil(bottom.object("bottom"))
        XCTAssertNil(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topCopper, board: board, clipping: clipping))
    }

    func testBridgedContourKeepsHolesOpen() {
        let outer = [
            HorizontalPoint(x: -3 * mm, y: -3 * mm),
            HorizontalPoint(x: 3 * mm, y: -3 * mm),
            HorizontalPoint(x: 3 * mm, y: 3 * mm),
            HorizontalPoint(x: -3 * mm, y: 3 * mm),
        ]
        let hole = [
            HorizontalPoint(x: -mm, y: -mm),
            HorizontalPoint(x: mm, y: -mm),
            HorizontalPoint(x: mm, y: mm),
            HorizontalPoint(x: -mm, y: mm),
        ]
        let contour = HorizontalSilkscreenClipper.bridgedContour([outer, hole])
        XCTAssertEqual(contour.count, outer.count + hole.count + 2)
        XCTAssertTrue(contains(contour, HorizontalPoint(x: 2.5 * mm, y: 2.5 * mm)), "the ring is filled")
        XCTAssertFalse(contains(contour, HorizontalPoint(x: 0, y: 0)), "the hole stays open")
        XCTAssertTrue(HorizontalSilkscreenClipper.bridgedContour([]).isEmpty)
    }

    func testCapsuleCoversTheStroke() {
        let capsule = HorizontalSilkscreenClipper.capsule(from: HorizontalPoint(x: 0, y: 0), to: HorizontalPoint(x: 2 * mm, y: 0), width: 0.4 * mm)
        XCTAssertTrue(contains(capsule, HorizontalPoint(x: mm, y: 0.15 * mm)))
        XCTAssertTrue(contains(capsule, HorizontalPoint(x: -0.15 * mm, y: 0)), "round cap")
        XCTAssertFalse(contains(capsule, HorizontalPoint(x: mm, y: 0.3 * mm)))
        XCTAssertFalse(contains(capsule, HorizontalPoint(x: -0.25 * mm, y: 0)))
    }

    @MainActor
    func testPreferenceProducesTheClippingInNanometres() {
        let defaults = UserDefaults(suiteName: "HorizontalSilkscreenClipperTests-\(UUID().uuidString)")!
        let settings = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertNil(settings.silkscreenClipping, "off by default")
        settings.clipSilkscreenToSolderMaskBinding().wrappedValue = true
        settings.silkscreenMaskClearanceBinding().wrappedValue = 0.25
        XCTAssertEqual(settings.silkscreenClipping?.clearance, 250_000)

        let reloaded = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertEqual(reloaded.silkscreenClipping?.clearance, 250_000)
        reloaded.resetSilkscreenClipping()
        XCTAssertNil(reloaded.silkscreenClipping)
        XCTAssertEqual(reloaded.silkscreenMaskClearanceMillimetres, HorizontalSilkscreenClipping.defaultClearanceMM)
    }
}
