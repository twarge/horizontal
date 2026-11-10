#if os(macOS)
import Metal
import SwiftUI
import XCTest
@testable import HorizontalNative

/// With a key per composite group the canvas layer uploads only the groups
/// whose key changed: what the others hold stays as it was, however the
/// content's own keys changed, and a group that is gone is dropped.
@MainActor
final class HorizontalMetalGroupUploadTests: XCTestCase {
    private func line(y: Double, group: Int) -> HorizontalMetalLinePrimitive {
        .init(from: .init(x: 0, y: y), to: .init(x: 2_500_000, y: y),
              color: HorizontalMetalRGBA(Color.yellow), width: 0, minimumWidth: 1,
              compositeGroup: group)
    }

    private func update(_ layer: HorizontalMetalCanvasLayer, lines: [HorizontalMetalLinePrimitive], key: Int, groupKeys: [Int: Int]?,
                        patches: HorizontalMetalBufferPatches = .empty) {
        _ = layer.update(
            HorizontalMetalCanvasLayerContent(
                minimumLineWidth: 1, gridLineWidth: 1,
                triangles: [], triangleKey: key, lines: lines, lineKey: key,
                handles: [], handleKey: key, anchoredRects: [], anchoredRectKey: key,
                bufferPatches: patches, bufferPatchKey: patches.hashValue,
                groupKeys: groupKeys),
            frame: HorizontalMetalCanvasFrame(
                contentBounds: .init(points: [.init(x: -10_000_000, y: -10_000_000), .init(x: 10_000_000, y: 10_000_000)]),
                viewportSize: SIMD2(800, 600)),
            loadProfileID: nil
        )
    }

    private func ys(_ layer: HorizontalMetalCanvasLayer, _ group: Int) -> [Float] {
        layer.residentLineEndpoints(compositeGroup: group).map(\.from.y)
    }

    func testOnlyGroupsWhoseKeyChangedAreUploaded() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
        update(layer, lines: [line(y: 0, group: 4), line(y: 10, group: 5), line(y: 20, group: 0)], key: 1,
               groupKeys: [4: 40, 5: 50, 0: 1])
        XCTAssertEqual(ys(layer, 4), [0])
        XCTAssertEqual(ys(layer, 5), [10])
        XCTAssertEqual(ys(layer, 0), [20])
        let uploads = layer.residentSceneUploads

        // Group 5 changed and says so; group 4's primitives are given as
        // something else under its old key, which the layer trusts and
        // keeps, and group 0's key is the same.
        update(layer, lines: [line(y: 99, group: 4), line(y: 11, group: 5), line(y: 99, group: 0)], key: 2,
               groupKeys: [4: 40, 5: 51, 0: 1])
        XCTAssertEqual(ys(layer, 4), [0], "an unchanged group isn't uploaded")
        XCTAssertEqual(ys(layer, 5), [11], "a changed one is")
        XCTAssertEqual(ys(layer, 0), [20], "nor are the direct buffers under an unchanged key")
        XCTAssertEqual(layer.residentSceneUploads, uploads + 1)

        // Nothing changed: no upload at all, whatever the content's keys.
        update(layer, lines: [line(y: 0, group: 4), line(y: 11, group: 5), line(y: 20, group: 0)], key: 3,
               groupKeys: [4: 40, 5: 51, 0: 1])
        XCTAssertEqual(layer.residentSceneUploads, uploads + 1)

        // Group 5 gone, group 0 changed.
        update(layer, lines: [line(y: 0, group: 4), line(y: 21, group: 0)], key: 4, groupKeys: [4: 40, 0: 2])
        XCTAssertEqual(ys(layer, 5), [])
        XCTAssertEqual(ys(layer, 4), [0])
        XCTAssertEqual(ys(layer, 0), [21])
    }

    /// When a move's patches end, only the groups they wrote go back to the
    /// base; the others were never patched and stay as they are.
    func testEndingPatchesPutsBackOnlyTheGroupsTheyWrote() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
        let base = [line(y: 0, group: 4), line(y: 10, group: 5)]
        let keys = [4: 40, 5: 50]
        update(layer, lines: base, key: 1, groupKeys: keys)
        var patches = HorizontalMetalBufferPatches()
        patches.lineTranslationPatches = [.init(compositeGroup: 4, start: 0, count: 1, delta: .init(x: 0, y: 1_000_000))]
        update(layer, lines: base, key: 1, groupKeys: keys, patches: patches)
        XCTAssertEqual(ys(layer, 4), [1_000_000], "the patch moved group 4")
        let uploads = layer.residentSceneUploads

        // The move ends: the base again, under the same keys.
        update(layer, lines: base, key: 1, groupKeys: keys)
        XCTAssertEqual(ys(layer, 4), [0], "group 4 is put back")
        XCTAssertEqual(ys(layer, 5), [10])
        XCTAssertEqual(layer.residentSceneUploads, uploads + 1, "in one upload, of the group the patch wrote")
    }

    func testContentWithoutGroupKeysUploadsEveryGroup() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let layer = HorizontalMetalCanvasLayer(device: MTLCreateSystemDefaultDevice())
        update(layer, lines: [line(y: 0, group: 4), line(y: 10, group: 5)], key: 1, groupKeys: [4: 40, 5: 50])
        update(layer, lines: [line(y: 1, group: 4), line(y: 12, group: 5)], key: 2, groupKeys: nil)
        XCTAssertEqual(ys(layer, 4), [1])
        XCTAssertEqual(ys(layer, 5), [12])
        // And keyed again after: every group, as the keys of what is resident
        // are unknown.
        update(layer, lines: [line(y: 2, group: 4), line(y: 13, group: 5)], key: 3, groupKeys: [4: 40, 5: 50])
        XCTAssertEqual(ys(layer, 4), [2])
        XCTAssertEqual(ys(layer, 5), [13])
    }
}
#endif
