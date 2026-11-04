#if os(macOS)
import Metal
import SwiftUI
import XCTest
@testable import HorizontalNative

@MainActor
final class HorizontalMetalMovePatchTests: XCTestCase {
    func testEndingPreviewRestoresBaseWhenSceneKeyAlreadyMatches() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
        let base = line(y: 0)
        let placed = line(y: 1_250_000)

        // The base scene can arrive while the previous move is still being
        // patched. Its key then stays the same when the interaction ends.
        update(layer, line: base, key: 1)
        update(layer, line: base, key: 1, patch: placed)
        update(layer, line: placed, key: 2, patch: line(y: 2_500_000))
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 4).first?.from.y, 2_500_000)
        update(layer, line: placed, key: 2)
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 4).first?.from.y, 1_250_000)
    }

    func testCancellingPreviewRestoresUnchangedBaseAndSelectionBuffers() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        for group in [0, 4] {
            let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
            let base = line(y: 0, group: group)
            update(layer, line: base, key: 1, patch: line(y: 1_250_000, group: group))
            update(layer, line: base, key: 1)
            XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: group).first?.from.y, 0)
        }
    }

    /// A turn during a move (122) rides the translation patches: each is where
    /// the move puts its run of the resident scene, turn and shift together,
    /// and the buffers apply only what changed since the last one.
    func testTurnedTranslationPatchesPlaceTheResidentRunFromTheBase() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
        let base = line(y: 0)
        func placed(x: Double, y: Double, angle: Int) -> HorizontalMetalBufferPatches {
            var patches = HorizontalMetalBufferPatches()
            patches.lineTranslationPatches = [.init(compositeGroup: 4, start: 0, count: 1, delta: .init(x: x, y: y), angle: angle)]
            return patches
        }
        func resident() -> (from: SIMD2<Float>, to: SIMD2<Float>)? {
            layer.residentLineEndpoints(compositeGroup: 4).first
        }

        update(layer, line: base, key: 1, patches: placed(x: 1_000_000, y: 0, angle: 0))
        XCTAssertEqual(resident()?.from, SIMD2(1_000_000, 0))
        XCTAssertEqual(resident()?.to, SIMD2(3_500_000, 0))
        // A quarter turn anticlockwise about the origin, then the shift.
        update(layer, line: base, key: 1, patches: placed(x: 1_000_000, y: 0, angle: 16_384))
        XCTAssertEqual(resident()?.from, SIMD2(1_000_000, 0))
        XCTAssertEqual(resident()?.to, SIMD2(1_000_000, 2_500_000))
        update(layer, line: base, key: 1, patches: placed(x: 0, y: 0, angle: 32_768))
        XCTAssertEqual(resident()?.from, SIMD2(0, 0))
        XCTAssertEqual(resident()?.to, SIMD2(-2_500_000, 0))
        update(layer, line: base, key: 1, patches: placed(x: 0, y: 5_000_000, angle: -16_384))
        XCTAssertEqual(resident()?.from, SIMD2(0, 5_000_000))
        XCTAssertEqual(resident()?.to, SIMD2(0, 2_500_000))
        // A plain shift again, and the base once the move is over.
        update(layer, line: base, key: 1, patches: placed(x: 5_000_000, y: 0, angle: 0))
        XCTAssertEqual(resident()?.from, SIMD2(5_000_000, 0))
        XCTAssertEqual(resident()?.to, SIMD2(7_500_000, 0))
        update(layer, line: base, key: 1)
        XCTAssertEqual(resident()?.from, SIMD2(0, 0))
        XCTAssertEqual(resident()?.to, SIMD2(2_500_000, 0))
    }

    /// A text a turn redraws is written over the translation that also covers
    /// it, on every pass, so the translation's own work on it never shows.
    func testRedrawPatchesLandOverTheTranslationsTheyOverlap() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
        let base = line(y: 0)
        func frame(shift: Double) -> HorizontalMetalBufferPatches {
            var patches = HorizontalMetalBufferPatches()
            patches.lineTranslationPatches = [.init(compositeGroup: 4, start: 0, count: 1, delta: .init(x: shift, y: 0), angle: 16_384)]
            var redrawn = line(y: 7_500_000)
            redrawn.from.x += shift
            redrawn.to.x += shift
            patches.lineRedrawPatches = [.init(compositeGroup: 4, start: 0, primitives: [redrawn])]
            return patches
        }
        update(layer, line: base, key: 1, patches: frame(shift: 0))
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 4).first?.from, SIMD2(0, 7_500_000))
        update(layer, line: base, key: 1, patches: frame(shift: 1_250_000))
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 4).first?.from, SIMD2(1_250_000, 7_500_000))
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 4).first?.to, SIMD2(3_750_000, 7_500_000))
        update(layer, line: base, key: 1)
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 4).first?.from, SIMD2(0, 0))
    }

    private func line(y: Double, group: Int = 4) -> HorizontalMetalLinePrimitive {
        .init(from: .init(x: 0, y: y), to: .init(x: 2_500_000, y: y),
              color: HorizontalMetalRGBA(Color.yellow), width: 0, minimumWidth: 1,
              compositeGroup: group)
    }

    private func update(_ layer: HorizontalMetalCanvasLayer,
                        line: HorizontalMetalLinePrimitive, key: Int,
                        patch: HorizontalMetalLinePrimitive? = nil,
                        patches given: HorizontalMetalBufferPatches? = nil) {
        var patches = given ?? HorizontalMetalBufferPatches()
        if let patch {
            patches.linePatches = [.init(compositeGroup: patch.compositeGroup, start: 0, primitives: [patch])]
        }
        _ = layer.update(
            HorizontalMetalCanvasLayerContent(
                minimumLineWidth: 1, gridLineWidth: 1,
                triangles: [], triangleKey: key, lines: [line], lineKey: key,
                handles: [], handleKey: key, anchoredRects: [], anchoredRectKey: key,
                bufferPatches: patches, bufferPatchKey: patches.hashValue),
            frame: HorizontalMetalCanvasFrame(
                bounds: .init(points: [.init(x: -10_000_000, y: -10_000_000), .init(x: 10_000_000, y: 10_000_000)]),
                viewportSize: SIMD2(800, 600)),
            loadProfileID: nil)
    }
}
#endif
