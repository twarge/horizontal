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

    private func line(y: Double, group: Int = 4) -> HorizontalMetalLinePrimitive {
        .init(from: .init(x: 0, y: y), to: .init(x: 2_500_000, y: y),
              color: HorizontalMetalRGBA(Color.yellow), width: 0, minimumWidth: 1,
              compositeGroup: group)
    }

    private func update(_ renderer: HorizontalMetalBackdropView.Renderer,
                        line: HorizontalMetalLinePrimitive, key: Int,
                        patch: HorizontalMetalLinePrimitive? = nil) {
        var patches = HorizontalMetalBufferPatches()
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
