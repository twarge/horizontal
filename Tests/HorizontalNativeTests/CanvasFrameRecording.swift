#if os(macOS)
import AppKit
import MetalKit
import XCTest
@testable import HorizontalNative

/// Reads what a mounted canvas's Metal renderer measures from: every frame its
/// uniforms are made from, recorded while a test sets them going, and where
/// each puts a world point on the canvas. A frame that puts one somewhere
/// else, even one that is replaced before the next draw, is a view that
/// jumps.
@MainActor
enum CanvasFrameRecording {
    static func renderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer {
            return renderer
        }
        return view.subviews.lazy.compactMap { renderer(in: $0) }.first
    }

    static func screenPoint(_ point: HorizontalPoint, in frame: HorizontalMetalCanvasFrame) -> CGPoint {
        HorizontalCanvasTransform(
            bounds: frame.bounds,
            size: CGSize(width: CGFloat(frame.viewportSize.x), height: CGFloat(frame.viewportSize.y)),
            fitInsets: frame.fitInsets,
            zoom: frame.viewport.zoom,
            pan: frame.viewport.pan,
            mirrored: frame.viewport.mirrored
        ).point(point)
    }

    /// Every recorded frame puts `points` where `settled` did.
    static func assertEveryFrameShows(_ points: [HorizontalPoint], as settled: HorizontalMetalCanvasFrame,
                                      in renderer: HorizontalMetalBackdropView.Renderer, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let frames = renderer.recordedFrames ?? []
        XCTAssertFalse(frames.isEmpty, "The renderer took no frame: \(message)", file: file, line: line)
        for (index, frame) in frames.enumerated() {
            for point in points {
                let shown = screenPoint(point, in: frame)
                let wanted = screenPoint(point, in: settled)
                guard abs(shown.x - wanted.x) > 0.01 || abs(shown.y - wanted.y) > 0.01 else {
                    continue
                }
                XCTFail("Frame \(index + 1) of \(frames.count) drew \(point) at \(shown), not \(wanted): \(message)",
                        file: file, line: line)
                return
            }
        }
    }
}
#endif
