import XCTest
@testable import HorizontalNative

/// A board text that is turned, or carried to the other side, draws what it
/// drew before, turned or mirrored: the canvas's Rotate and a package's
/// motion move the strokes rigidly, whichever side the text is on and
/// whether or not its placement is mirrored.
final class BoardTextRigidMotionTests: XCTestCase {
    private typealias Stroke = (HorizontalPoint, HorizontalPoint)

    private func texts() -> [HorizontalText] {
        var texts = [HorizontalText]()
        for layer in [HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen] {
            for mirrored in [false, true] {
                for angle in [0, 16_384, 8_192] {
                    texts.append(HorizontalText(
                        id: "layer \(layer) mirrored \(mirrored) angle \(angle)",
                        text: "F\nL",
                        position: HorizontalPoint(x: 700_000, y: -300_000),
                        size: 1_000_000,
                        layer: layer,
                        angle: angle,
                        mirrored: mirrored,
                        width: 100_000,
                        // So a turn past upright doesn't re-read the text the
                        // other way round, which is not a rigid motion.
                        allowUpsideDown: true
                    ))
                }
            }
        }
        return texts
    }

    private func strokes(_ text: HorizontalText) -> [Stroke] {
        HorizontalOutlineTextRenderer.outlineSegments(for: text)
    }

    private func assertSameStrokes(_ drawn: [Stroke], _ expected: [Stroke], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(drawn.count, expected.count, label, file: file, line: line)
        XCTAssertFalse(expected.isEmpty, label, file: file, line: line)
        func distance(_ a: Stroke, _ b: Stroke) -> Double {
            func gap(_ p: HorizontalPoint, _ q: HorizontalPoint) -> Double { max(abs(p.x - q.x), abs(p.y - q.y)) }
            return min(max(gap(a.0, b.0), gap(a.1, b.1)), max(gap(a.0, b.1), gap(a.1, b.0)))
        }
        for stroke in expected {
            let nearest = drawn.map { distance(stroke, $0) }.min() ?? .infinity
            if nearest > 1 {
                XCTFail("\(label): the stroke \(stroke) is not drawn (nearest is \(nearest) nm off)", file: file, line: line)
                return
            }
        }
    }

    func testRotateTurnsWhatATextDraws() {
        let origin = HorizontalPoint(x: 100_000, y: 50_000)
        for text in texts() {
            for turn in [16_384, -16_384, 32_768] {
                let turned = HorizontalCanvasModeSupport.rotated(text, around: origin, by: turn)
                let expected = strokes(text).map {
                    (HorizontalCanvasModeSupport.rotated($0.0, around: origin, by: turn),
                     HorizontalCanvasModeSupport.rotated($0.1, around: origin, by: turn))
                }
                assertSameStrokes(strokes(turned), expected, "\(text.id) turned \(turn)")
            }
        }
    }

    func testAMotionCarriesWhatATextDraws() {
        for text in texts() {
            for mirrored in [false, true] {
                for turn in [0, 16_384, 49_152] {
                    let motion = HorizontalBoardMotion(
                        HorizontalPlacementTransform(shift: HorizontalPoint(x: 2_000_000, y: 1_000_000), angle: turn, mirrored: mirrored),
                        innerLayerCount: 2
                    )
                    let moved = motion.text(text)
                    let expected = strokes(text).map { (motion.point($0.0), motion.point($0.1)) }
                    assertSameStrokes(strokes(moved), expected, "\(text.id) moved, turn \(turn), mirrored \(mirrored)")
                    if mirrored {
                        XCTAssertNotEqual(moved.readsFromBelow, text.readsFromBelow, "a flip takes the text to the other side")
                    }
                }
            }
        }
    }

    func testMirrorTakesATextToItsMirrorImageOnTheOtherSide() {
        let center = HorizontalPoint(x: 250_000, y: 0)
        for text in texts() {
            let flipped = BoardMirror.mirrored(text, around: center, flippingLayers: 2)
            let expected = strokes(text).map {
                (HorizontalCanvasModeSupport.mirrored($0.0, around: center), HorizontalCanvasModeSupport.mirrored($0.1, around: center))
            }
            assertSameStrokes(strokes(flipped), expected, "\(text.id) mirrored to the other side")
        }
    }
}
