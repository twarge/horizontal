import XCTest
@testable import HorizontalNative

/// Tests the pure pad-label geometry extracted from BoardCanvasView. The
/// descriptor path is the fix for the "labels at odd angles on roundrect/
/// circular pads" bug — it uses the pad's intrinsic rotation instead of scoring
/// rendered polygon edges.
final class BoardPadLabelLayoutTests: XCTestCase {
    private let mm = 1_000_000.0

    func testDescriptorFrameForRectangularPad() {
        let descriptor = PadLabelFrameDescriptor(
            center: HorizontalPoint(x: 100, y: 200), halfWidth: 2 * mm, halfHeight: 1 * mm, angle: 0)
        let frame = BoardPadLabelLayout.frame(fromDescriptor: descriptor)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame!.width, 4 * mm, accuracy: 1)
        XCTAssertEqual(frame!.height, 2 * mm, accuracy: 1)
        XCTAssertEqual(frame!.angle, 0)
        XCTAssertEqual(frame!.center.x, 100, accuracy: 1)
        XCTAssertEqual(frame!.axis.x, 1, accuracy: 0.001)
        XCTAssertEqual(frame!.axis.y, 0, accuracy: 0.001)
    }

    func testDescriptorFrameForCircularPadIsHorizontal() {
        // Equal half-extents (circular pad): the descriptor path must give a
        // stable horizontal label rather than an arbitrary angle — the bug the
        // extraction documents and guards against.
        let descriptor = PadLabelFrameDescriptor(
            center: .zero, halfWidth: 1 * mm, halfHeight: 1 * mm, angle: 0)
        let frame = BoardPadLabelLayout.frame(fromDescriptor: descriptor)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame!.angle, 0)
        XCTAssertEqual(frame!.axis.x, 1, accuracy: 0.001)
        XCTAssertEqual(frame!.axis.y, 0, accuracy: 0.001)
    }

    func testDescriptorFrameForRotatedPadKeepsLongAxis() {
        // A 2:1 pad rotated 90° (16384 Horizon units): the label follows the
        // pad's long axis (now vertical), not flipped into near-square handling.
        let descriptor = PadLabelFrameDescriptor(
            center: .zero, halfWidth: 2 * mm, halfHeight: 1 * mm, angle: 16_384)
        let frame = BoardPadLabelLayout.frame(fromDescriptor: descriptor)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame!.angle, 16_384)
        XCTAssertEqual(frame!.width, 4 * mm, accuracy: 1)
        XCTAssertEqual(frame!.height, 2 * mm, accuracy: 1)
    }

    func testDescriptorRejectsDegenerate() {
        XCTAssertNil(BoardPadLabelLayout.frame(fromDescriptor:
            PadLabelFrameDescriptor(center: .zero, halfWidth: 0, halfHeight: 1 * mm, angle: 0)))
    }

    func testVerticesFrameForAxisAlignedRectangle() {
        let vertices = [
            HorizontalPoint(x: -2000, y: -1000),
            HorizontalPoint(x: 2000, y: -1000),
            HorizontalPoint(x: 2000, y: 1000),
            HorizontalPoint(x: -2000, y: 1000),
        ]
        let frame = BoardPadLabelLayout.frame(forVertices: vertices)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame!.angle, 0)
        XCTAssertEqual(frame!.width, 4000, accuracy: 1)
        XCTAssertEqual(frame!.height, 2000, accuracy: 1)
    }

    // MARK: - Golden geometry

    /// Parsed once: padAngle/config -> (drawAngle, upper, lower).
    private static let golden: [String: (Int, HorizontalPoint, HorizontalPoint)] = {
        var table = [String: (Int, HorizontalPoint, HorizontalPoint)]()
        for line in PadLabelFrameGoldenData.rows.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 7, let angle = Int(f[0]), let config = Int(f[1]),
                  let draw = Int(f[2]), let ux = Double(f[3]), let uy = Double(f[4]),
                  let lx = Double(f[5]), let ly = Double(f[6]) else { continue }
            table["\(angle):\(config)"] = (
                draw,
                HorizontalPoint(x: ux, y: uy),
                HorizontalPoint(x: lx, y: ly)
            )
        }
        return table
    }()

    /// Asserts the layout still produces the recorded geometry. Compares against
    /// measured output rather than against a copy of the original implementation.
    private func assertMatchesGolden(
        halfWidth: Double,
        halfHeight: Double,
        angle: Int,
        config: Int,
        mirrored: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let descriptor = PadLabelFrameDescriptor(
            center: .zero, halfWidth: halfWidth, halfHeight: halfHeight,
            angle: angle, mirrored: mirrored)
        guard let frame = BoardPadLabelLayout.frame(fromDescriptor: descriptor) else {
            return XCTFail("no frame for angle \(angle)", file: file, line: line)
        }
        guard let expected = Self.golden["\(angle):\(config)"] else {
            return XCTFail("no golden row for \(angle):\(config)", file: file, line: line)
        }

        XCTAssertEqual(
            ((frame.angle % 65_536) + 65_536) % 65_536, expected.0,
            "draw angle for pad angle \(angle) config \(config)", file: file, line: line)

        // The renderer places the rows at center ± normal * height/4; the flip is
        // carried by `normal`, not by a separate sign on the offset.
        let offset = frame.height * BoardPadLabelLayout.rowOffsetFraction
        let upper = frame.center + frame.normal * offset
        let lower = frame.center - frame.normal * offset
        XCTAssertEqual(upper.x, expected.1.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(upper.y, expected.1.y, accuracy: 1, file: file, line: line)
        XCTAssertEqual(lower.x, expected.2.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(lower.y, expected.2.y, accuracy: 1, file: file, line: line)
    }

    func testFrameMatchesGoldenGeometryAcrossAngles() {
        for angle in stride(from: 0, to: 65_536, by: 512) {
            assertMatchesGolden(halfWidth: 2 * mm, halfHeight: 1 * mm, angle: angle, config: 0)
            assertMatchesGolden(halfWidth: 1 * mm, halfHeight: 2 * mm, angle: angle, config: 1)
            assertMatchesGolden(halfWidth: 1 * mm, halfHeight: 1 * mm, angle: angle, config: 2)
            assertMatchesGolden(halfWidth: 1 * mm, halfHeight: 0.95 * mm, angle: angle, config: 3)
            assertMatchesGolden(halfWidth: 2 * mm, halfHeight: 1 * mm, angle: angle, config: 4, mirrored: true)
        }
    }

    func testGoldenTableCoversTheWholeSweep() {
        XCTAssertEqual(Self.golden.count, 640, "128 angles x 5 configurations")
    }

    func testReadabilityFlipRotates180AndKeepsPadNameOnUpperHalf() {
        // 180° is squarely inside Horizon's flip window (16384, 49152].
        let descriptor = PadLabelFrameDescriptor(
            center: .zero, halfWidth: 2 * mm, halfHeight: 1 * mm, angle: 32_768)
        let frame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor: descriptor))

        // Drawn at 180 + 180 = 0, i.e. upright rather than upside down.
        XCTAssertEqual(frame.angle, 0)

        let offset = frame.height * BoardPadLabelLayout.rowOffsetFraction
        let upper = frame.center + frame.normal * offset
        let lower = frame.center - frame.normal * offset
        // Pad name still on the visually-upper half after the flip.
        XCTAssertGreaterThan(upper.y, lower.y)
        XCTAssertEqual(upper.y, 0.5 * mm, accuracy: 1)
        XCTAssertEqual(lower.y, -0.5 * mm, accuracy: 1)
    }

    func testUnflippedAngleKeepsPadNameOnUpperHalf() {
        let descriptor = PadLabelFrameDescriptor(
            center: .zero, halfWidth: 2 * mm, halfHeight: 1 * mm, angle: 0)
        let frame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor: descriptor))
        let offset = frame.height * BoardPadLabelLayout.rowOffsetFraction
        XCTAssertGreaterThan(
            (frame.center + frame.normal * offset).y,
            (frame.center - frame.normal * offset).y)
    }

    func testRotatedNonSquarePadRunsTextAlongLongAxisAtPlacementAngle() {
        // 2:1 pad rotated 30°: the label runs along the pad's long axis, i.e. at
        // the pad's own placement angle, with the un-swapped extents.
        let angle = 5_461 // 30°
        let descriptor = PadLabelFrameDescriptor(
            center: HorizontalPoint(x: 7 * mm, y: -3 * mm),
            halfWidth: 2 * mm, halfHeight: 1 * mm, angle: angle)
        let frame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor: descriptor))
        XCTAssertEqual(frame.angle, angle)
        XCTAssertEqual(frame.width, 4 * mm, accuracy: 1)
        XCTAssertEqual(frame.height, 2 * mm, accuracy: 1)
        XCTAssertEqual(frame.center.x, 7 * mm, accuracy: 1)

        // Tall pad at the same angle: text turns 90° so it still runs the long way
        // (30° + 90° = 120°), then the readability flip takes it to 300° so it is
        // not drawn upside down. Either way the text runs along the pad's long axis.
        let tall = PadLabelFrameDescriptor(
            center: .zero, halfWidth: 1 * mm, halfHeight: 2 * mm, angle: angle)
        let tallFrame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor: tall))
        XCTAssertEqual(tallFrame.angle, angle + 16_384 + 32_768)
        XCTAssertEqual(tallFrame.width, 4 * mm, accuracy: 1)
        XCTAssertEqual(tallFrame.height, 2 * mm, accuracy: 1)
        let longAxisRadians = Double(angle + 16_384) / 65_536 * 2 * .pi
        let alignment = tallFrame.axis.x * cos(longAxisRadians) + tallFrame.axis.y * sin(longAxisRadians)
        XCTAssertEqual(abs(alignment), 1, accuracy: 0.001)
    }

    func testCurvedPadOutlineDoesNotDriveTheAngleWhenDescriptorIsPresent() {
        // A 3:1 obround/roundrect pad at 0°. Its tessellated outline offers dozens
        // of corner chords, and the fallback heuristic happily picks one of them;
        // the descriptor path must stay locked to the pad's placement angle.
        let halfWidth = 3.0 * mm
        let halfHeight = 1.0 * mm
        var outline = [HorizontalPoint]()
        for index in 0..<36 {
            let theta = Double(index) / 36 * 2 * .pi
            let capCenter = cos(theta) >= 0 ? halfWidth - halfHeight : -(halfWidth - halfHeight)
            outline.append(HorizontalPoint(
                x: capCenter + cos(theta) * halfHeight,
                y: sin(theta) * halfHeight))
        }

        let descriptorFrame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor:
            PadLabelFrameDescriptor(center: .zero, halfWidth: halfWidth, halfHeight: halfHeight, angle: 0)))
        XCTAssertEqual(descriptorFrame.angle, 0)
        XCTAssertEqual(descriptorFrame.width, 2 * halfWidth, accuracy: 1)
        XCTAssertEqual(descriptorFrame.height, 2 * halfHeight, accuracy: 1)

        // Documents the bug the descriptor path exists to avoid: the fallback
        // lands on some chord angle, not on the pad's axis.
        let fallback = try! XCTUnwrap(BoardPadLabelLayout.frame(
            forVertices: outline, padText: "12", netText: "GND"))
        XCTAssertNotEqual(fallback.angle, descriptorFrame.angle)
    }

    func testCircularPadStaysHorizontalAndFollowsQuarterTurns() {
        for angle in [0, 16_384, 32_768, 49_152] {
            let frame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor:
                PadLabelFrameDescriptor(center: .zero, halfWidth: 1 * mm, halfHeight: 1 * mm, angle: angle)))
            // Square bbox: Horizon's almost-square rule spins quarter turns away,
            // so a round pad on an axis-aligned package reads horizontally.
            XCTAssertEqual(frame.angle, 0, "circular pad at \(angle)")
            XCTAssertEqual(frame.axis.x, 1, accuracy: 0.001)
            XCTAssertEqual(frame.axis.y, 0, accuracy: 0.001)
        }

        // …but a round pad on a package rotated off-axis tilts with the package,
        // exactly as Horizon does (the label angle is the pad's placement angle).
        let tilted = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor:
            PadLabelFrameDescriptor(center: .zero, halfWidth: 1 * mm, halfHeight: 1 * mm, angle: 8_192)))
        XCTAssertEqual(tilted.angle, 8_192)
    }

    func testMirroredPadInvertsPlacementAngle() {
        // Bottom-side pad: `draw_bitmap_text_box` inverts the angle and drops mirror.
        let frame = try! XCTUnwrap(BoardPadLabelLayout.frame(fromDescriptor:
            PadLabelFrameDescriptor(
                center: .zero, halfWidth: 2 * mm, halfHeight: 1 * mm,
                angle: 5_461, mirrored: true)))
        XCTAssertEqual(frame.angle, 65_536 - 5_461)
    }

    func testFittedTextSizeUsesHorizonMargin() {
        let frame = PadLabelFrame(center: .zero, axis: HorizontalPoint(x: 1, y: 0),
                                  normal: HorizontalPoint(x: 0, y: 1),
                                  width: 4 * mm, height: 2 * mm, angle: 0)
        let size = BoardPadLabelLayout.fittedTextSize("12", frame: frame, mode: .full)
        let metrics = HorizontalOutlineTextRenderer.textSize("12", font: .simplex, size: size)
        // Horizon: sc = min(scale_x, scale_y) * .75 — the fitted text fills 75% of
        // whichever dimension is binding.
        let fill = max(metrics.width / frame.width, metrics.height / frame.height)
        XCTAssertEqual(fill, BoardPadLabelLayout.fitMargin, accuracy: 0.001)
    }

    /// Every copper pad on a real board must carry an intrinsic descriptor —
    /// through-hole, via and mechanical padstacks included — so the polygon-edge
    /// heuristic is never what orients a pad label.
    func testEveryCopperPadOnRealBoardCarriesALabelDescriptor() throws {
        let base = URL(fileURLWithPath: "/Users/kornack/Repositories/coriander/Coriander Horizon")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("Coriander board not available")
        }
        var diagnostics = [HorizontalDiagnostic]()
        let board = try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )

        let copperPads = board.packagePads.filter { HorizontalBoardLayers.isCopper($0.layer ?? 10_000) }
        XCTAssertFalse(copperPads.isEmpty)
        let missing = copperPads.filter { $0.padLabelFrame == nil }
        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count)/\(copperPads.count) copper pads have no label descriptor, e.g. \(missing.prefix(3).map(\.id))")

        // And every descriptor must produce a usable frame.
        for pad in copperPads.prefix(4_000) {
            guard let descriptor = pad.padLabelFrame else { continue }
            XCTAssertNotNil(
                BoardPadLabelLayout.frame(fromDescriptor: descriptor),
                "degenerate descriptor for \(pad.id)")
        }
    }

    func testFittedTextSizeScalesWithFrameAndRejectsEmpty() {
        func frame(width: Double, height: Double) -> PadLabelFrame {
            PadLabelFrame(center: .zero, axis: HorizontalPoint(x: 1, y: 0),
                          normal: HorizontalPoint(x: 0, y: 1), width: width, height: height, angle: 0)
        }
        let small = BoardPadLabelLayout.fittedTextSize("12", frame: frame(width: 1000, height: 500), mode: .full)
        let large = BoardPadLabelLayout.fittedTextSize("12", frame: frame(width: 4000, height: 2000), mode: .full)
        XCTAssertGreaterThan(small, 0)
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(BoardPadLabelLayout.fittedTextSize("", frame: frame(width: 4000, height: 2000), mode: .full), 0)
    }
}
