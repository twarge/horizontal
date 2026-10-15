#if os(macOS)
import SwiftUI
import XCTest
@testable import HorizontalNative

@MainActor
final class HorizontalMetalMovePatchTests: XCTestCase {
    func testEndingPreviewRestoresBaseWhenSceneKeyAlreadyMatches() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let renderer = HorizontalMetalBackdropView.Renderer()
        let base = line(y: 0)
        let placed = line(y: 1_250_000)

        // The base scene can arrive while the previous move is still being
        // patched. Its key then stays the same when the interaction ends.
        update(renderer, line: base, key: 1)
        update(renderer, line: base, key: 1, patch: placed)
        update(renderer, line: placed, key: 2, patch: line(y: 2_500_000))
        XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: 4).first?.from.y, 2_500_000)
        update(renderer, line: placed, key: 2)
        XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: 4).first?.from.y, 1_250_000)
    }

    func testCancellingPreviewRestoresUnchangedBaseAndSelectionBuffers() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        for group in [0, 4] {
            let renderer = HorizontalMetalBackdropView.Renderer()
            let base = line(y: 0, group: group)
            update(renderer, line: base, key: 1, patch: line(y: 1_250_000, group: group))
            update(renderer, line: base, key: 1)
            XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: group).first?.from.y, 0)
        }
    }

    /// A turn during a move (122) rides the translation patches: each is where
    /// the move puts its run of the resident scene, turn and shift together,
    /// and the buffers apply only what changed since the last one.
    func testTurnedTranslationPatchesPlaceTheResidentRunFromTheBase() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let renderer = HorizontalMetalBackdropView.Renderer()
        let base = line(y: 0)
        func placed(x: Double, y: Double, angle: Int) -> HorizontalMetalBufferPatches {
            var patches = HorizontalMetalBufferPatches()
            patches.lineTranslationPatches = [.init(compositeGroup: 4, start: 0, count: 1, delta: .init(x: x, y: y), angle: angle)]
            return patches
        }
        func resident() -> (from: SIMD2<Float>, to: SIMD2<Float>)? {
            renderer.residentLineEndpoints(compositeGroup: 4).first
        }

        update(renderer, line: base, key: 1, patches: placed(x: 1_000_000, y: 0, angle: 0))
        XCTAssertEqual(resident()?.from, SIMD2(1_000_000, 0))
        XCTAssertEqual(resident()?.to, SIMD2(3_500_000, 0))
        // A quarter turn anticlockwise about the origin, then the shift.
        update(renderer, line: base, key: 1, patches: placed(x: 1_000_000, y: 0, angle: 16_384))
        XCTAssertEqual(resident()?.from, SIMD2(1_000_000, 0))
        XCTAssertEqual(resident()?.to, SIMD2(1_000_000, 2_500_000))
        update(renderer, line: base, key: 1, patches: placed(x: 0, y: 0, angle: 32_768))
        XCTAssertEqual(resident()?.from, SIMD2(0, 0))
        XCTAssertEqual(resident()?.to, SIMD2(-2_500_000, 0))
        update(renderer, line: base, key: 1, patches: placed(x: 0, y: 5_000_000, angle: -16_384))
        XCTAssertEqual(resident()?.from, SIMD2(0, 5_000_000))
        XCTAssertEqual(resident()?.to, SIMD2(0, 2_500_000))
        // A plain shift again, and the base once the move is over.
        update(renderer, line: base, key: 1, patches: placed(x: 5_000_000, y: 0, angle: 0))
        XCTAssertEqual(resident()?.from, SIMD2(5_000_000, 0))
        XCTAssertEqual(resident()?.to, SIMD2(7_500_000, 0))
        update(renderer, line: base, key: 1)
        XCTAssertEqual(resident()?.from, SIMD2(0, 0))
        XCTAssertEqual(resident()?.to, SIMD2(2_500_000, 0))
    }

    /// A text a turn redraws is written over the translation that also covers
    /// it, on every pass, so the translation's own work on it never shows.
    func testRedrawPatchesLandOverTheTranslationsTheyOverlap() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let renderer = HorizontalMetalBackdropView.Renderer()
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
        update(renderer, line: base, key: 1, patches: frame(shift: 0))
        XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: 4).first?.from, SIMD2(0, 7_500_000))
        update(renderer, line: base, key: 1, patches: frame(shift: 1_250_000))
        XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: 4).first?.from, SIMD2(1_250_000, 7_500_000))
        XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: 4).first?.to, SIMD2(3_750_000, 7_500_000))
        update(renderer, line: base, key: 1)
        XCTAssertEqual(renderer.residentLineEndpoints(compositeGroup: 4).first?.from, SIMD2(0, 0))
    }

    private func line(y: Double, group: Int = 4) -> HorizontalMetalLinePrimitive {
        .init(from: .init(x: 0, y: y), to: .init(x: 2_500_000, y: y),
              color: HorizontalMetalRGBA(Color.yellow), width: 0, minimumWidth: 1,
              compositeGroup: group)
    }

    private func update(_ renderer: HorizontalMetalBackdropView.Renderer,
                        line: HorizontalMetalLinePrimitive, key: Int,
                        patch: HorizontalMetalLinePrimitive? = nil,
                        patches given: HorizontalMetalBufferPatches? = nil) {
        var patches = given ?? HorizontalMetalBufferPatches()
        if let patch {
            patches.linePatches = [.init(compositeGroup: patch.compositeGroup, start: 0, primitives: [patch])]
        }
        _ = renderer.update(
            bounds: .init(points: [.init(x: -10_000_000, y: -10_000_000), .init(x: 10_000_000, y: 10_000_000)]),
            viewport: CanvasViewport(), fitInsets: .defaultFit, grid: nil,
            backgroundColor: .clear, gridColor: .clear, minimumLineWidth: 1, gridLineWidth: 1,
            showsOriginMark: false, originMarkColor: .clear, layerOpacity: 1,
            triangles: [], triangleKey: key, lines: [line], lineKey: key,
            handles: [], handleKey: key, anchoredRects: [], anchoredRectKey: key,
            screenTriangles: [], screenTriangleKey: 0, screenLines: [], screenLineKey: 0,
            bufferPatches: patches, bufferPatchKey: patches.hashValue,
            visibleCompositeGroups: nil, layerOpacityExemptCompositeGroups: [],
            backingScale: 1, viewportSize: SIMD2(800, 600))
    }
}
#endif
